import Foundation

/// Connection state for the gateway socket, mirrored by UI.
public enum ConnectionState: String, Sendable {
    case idle
    case connecting
    case open
    case closed
}

/// The transport surface `HermesClient` drives; `WebSocketTransport` is the production conformance
/// and a scripted one makes the connect/reconnect machine testable.
public protocol GatewayTransport: Actor {
    var state: ConnectionState { get }
    var lastCloseCode: Int { get }
    func connect(url: URL) async throws
    /// Open with subprotocols offered in `Sec-WebSocket-Protocol`; the default ignores them.
    func connect(url: URL, protocols: [String]) async throws
    func disconnect() async
    func send(line: String) async throws
    /// Arm the liveness probe on `gateway.ready` and NEVER before: a ping issued during the
    /// handshake deadlocks against the server's own opening frame (BUG-065).
    func startKeepalive() async
    func stopKeepalive() async
}

extension GatewayTransport {
    public func connect(url: URL, protocols: [String]) async throws {
        try await connect(url: url)
    }

    public func startKeepalive() async {}
    public func stopKeepalive() async {}
}

/// The gateway's WebSocket subprotocol names, and the exact set the server accepts a ticket in
/// (FEAT-015). A missing public protocol, or more than one ticket protocol, is refused with 4401 —
/// so an ambiguous offer is worse than no offer. On success the server selects only the public
/// protocol back, because the ticket-bearing one is a credential and is never reflected.
public enum GatewayWSProtocol {
    public static let publicProtocol = "hermes-gateway-v1"
    public static let ticketPrefix = "hermes-gateway-ticket."

    /// The only shape the server accepts: the public protocol, and exactly one ticket protocol.
    public static func offer(ticket: String) -> [String] {
        guard !ticket.isEmpty else { return [] }
        return [publicProtocol, ticketPrefix + ticket]
    }
}

/// Low-level WebSocket transport: text messages, each carrying one or more newline-delimited
/// JSON-RPC frames, since the server coalesces streamed token frames into one message.
public actor WebSocketTransport: GatewayTransport {
    public typealias FrameHandler = @Sendable (JSONRPCFrame) async -> Void
    /// The raw close code rides the callback so the client classifies the close that HAPPENED;
    /// reading `lastCloseCode` later races the transport being replaced.
    public typealias StateHandler = @Sendable (ConnectionState, Int) async -> Void

    private var task: URLSessionWebSocketTask?
    private var session: URLSession
    private var receiveLoop: Task<Void, Never>?
    private(set) public var state: ConnectionState = .idle

    private let onFrame: FrameHandler
    private let onState: StateHandler

    /// Raw close code of the most recent teardown; 4401 and 4403 signal credential rejection
    /// (rest-api-and-auth.md §1.13), the only way to tell "sign in again" from "network died".
    private(set) public var lastCloseCode: Int = 0

    /// Armed by the client on `gateway.ready`, torn down with the socket (BUG-065).
    private var keepalive: KeepaliveMonitor?

    public init(
        sessionConfiguration: URLSessionConfiguration = .default,
        onFrame: @escaping FrameHandler,
        onState: @escaping StateHandler
    ) {
        let config = sessionConfiguration
        // Chat traffic is interactive; do not wait for connectivity silently.
        config.waitsForConnectivity = false
        self.session = URLSession(configuration: config)
        self.onFrame = onFrame
        self.onState = onState
    }

    /// Open the socket carrying its credential in the URL — `?ticket=` or, in loopback, `?token=`.
    public func connect(url: URL) async throws {
        try await connect(url: url, protocols: [])
    }

    /// Open the socket offering `protocols` in `Sec-WebSocket-Protocol`; a gated dial puts the
    /// ticket there instead of in the URL, and an empty `protocols` is the older call (FEAT-015).
    public func connect(url: URL, protocols: [String]) async throws {
        disconnectLocked(sendClose: false)
        lastCloseCode = 0
        await setState(.connecting)

        let task = protocols.isEmpty
            ? session.webSocketTask(with: url)
            : session.webSocketTask(with: url, protocols: protocols)
        task.maximumMessageSize = 32 * 1024 * 1024
        self.task = task

        // The gateway speaks first, so read immediately and let the caller await the opening frame;
        // a failed upgrade or a post-accept rejection surfaces as the receive loop throwing.
        //
        // Deliberately NOT probed with `sendPing`: CFNetwork does not service the pong while an
        // unread server frame sits in the receive queue, so a ping-gated open self-deadlocks.
        //
        // `.open` here means WE ARE READING, not that the upgrade completed; the proof of a live
        // connection is the first frame, which is why the close path has to be observable.
        task.resume()
        startReceiveLoop(task: task)
        await setState(.open)
    }

    public func disconnect() async {
        disconnectLocked(sendClose: true)
        await setState(.closed)
    }

    // MARK: - Keepalive

    /// Start probing this socket; safe to call more than once.
    public func startKeepalive() async {
        guard task != nil, state == .open else { return }
        if keepalive?.isRunning == true { return }
        keepalive?.stop()
        let monitor = KeepaliveMonitor(
            probe: { [weak self] in await self?.probeSocket() ?? false },
            onDead: { [weak self] in await self?.keepaliveDeclaredTheSocketDead() }
        )
        keepalive = monitor
        monitor.start()
    }

    public func stopKeepalive() async {
        keepalive?.stop()
        keepalive = nil
    }

    /// One ping, answered or not, inside a bounded window: on a socket whose peer has silently gone
    /// neither the pong nor a write error arrives, so an undeadlined probe would park forever.
    private func probeSocket() async -> Bool {
        guard let task, state == .open else { return false }
        return await Self.boundedPing(timeout: KeepaliveMonitor.defaultPongTimeout) { answer in
            task.sendPing { error in answer(error == nil) }
        }
    }

    /// One ping raced against a deadline; whichever lands first answers, exactly once. `sleep` is the
    /// deadline's clock, injectable so a test can see what becomes of it.
    static func boundedPing(
        timeout: TimeInterval,
        sleep: @escaping @Sendable (TimeInterval) async -> Void = { seconds in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        },
        ping: @escaping (_ answer: @escaping @Sendable (Bool) -> Void) -> Void
    ) async -> Bool {
        await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            let once = PingOutcome(continuation)
            // Armed BEFORE the ping, so a pong answered synchronously still finds it to cancel: an
            // answered probe must not leave its deadline sleeping out the window (BUG-146).
            once.arm(Task {
                await sleep(timeout)
                guard !Task.isCancelled else { return }
                once.finish(false)
            })
            ping { answered in once.finish(answered) }
        }
    }

    private func keepaliveDeclaredTheSocketDead() async {
        guard state == .open else { return }
        // Straight into the existing teardown: a separate "keepalive failed" route would be a
        // second way to die that nothing downstream was written for.
        await handleClosed()
    }

    /// Resolves a continuation exactly once: the ping completion and the timeout race by design,
    /// and a `CheckedContinuation` traps on a double resume rather than ignoring it. Whichever side
    /// wins also cancels the deadline task, so the loser never outlives the probe.
    private final class PingOutcome: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Bool, Never>?
        private var deadline: Task<Void, Never>?

        init(_ continuation: CheckedContinuation<Bool, Never>) {
            self.continuation = continuation
        }

        /// Hold the deadline; one armed after the outcome is already settled is cancelled at once.
        func arm(_ task: Task<Void, Never>) {
            lock.lock()
            let settled = continuation == nil
            if !settled { deadline = task }
            lock.unlock()
            if settled { task.cancel() }
        }

        func finish(_ answered: Bool) {
            lock.lock()
            let pending = continuation
            continuation = nil
            let timer = deadline
            deadline = nil
            lock.unlock()
            timer?.cancel()
            pending?.resume(returning: answered)
        }
    }

    private func disconnectLocked(sendClose: Bool) {
        keepalive?.stop()
        keepalive = nil
        // A server close may have landed without the receive loop getting to it, so capture the
        // code first: a credential rejection read as a plain drop reconnects forever.
        if let code = task?.closeCode.rawValue, code != 0 { lastCloseCode = code }
        receiveLoop?.cancel()
        receiveLoop = nil
        if let task {
            if sendClose { task.cancel(with: .normalClosure, reason: nil) } else { task.cancel() }
        }
        task = nil
    }

    /// Send one pre-encoded JSON line as a text message.
    public func send(line: String) async throws {
        guard let task, state == .open else {
            throw JSONRPCError(code: -32000, message: "gateway not connected")
        }
        try await task.send(.string(line))
    }

    private func startReceiveLoop(task: URLSessionWebSocketTask) {
        receiveLoop = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    let message = try await task.receive()
                    guard let self else { return }
                    switch message {
                    case .string(let text):
                        for result in JSONRPCCodec.decodeMessage(text) {
                            if case .success(let frame) = result {
                                await self.onFrame(frame)
                            }
                            // Parse failures are dropped; the server never interleaves partial JSON.
                        }
                    case .data(let data):
                        if let text = String(data: data, encoding: .utf8) {
                            for result in JSONRPCCodec.decodeMessage(text) {
                                if case .success(let frame) = result {
                                    await self.onFrame(frame)
                                }
                            }
                        }
                    @unknown default:
                        break
                    }
                } catch {
                    guard let self else { return }
                    await self.handleClosed()
                    return
                }
            }
        }
    }

    private func handleClosed() async {
        keepalive?.stop()
        keepalive = nil
        // Read the code before dropping the task: 4401/4403 decides whether the client
        // re-authenticates or just backs off and retries.
        if let code = task?.closeCode.rawValue, code != 0 { lastCloseCode = code }
        receiveLoop?.cancel()
        receiveLoop = nil
        task = nil
        await setState(.closed)
    }

    private func setState(_ new: ConnectionState) async {
        state = new
        await onState(new, new == .closed ? lastCloseCode : 0)
    }
}
