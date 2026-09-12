import Foundation

/// Connection state as the UI needs to see it — richer than the transport's own `ConnectionState`,
/// because the reconnect manager lives here (reference-clients.md §7.2).
public enum GatewayConnectionState: Sendable, Equatable {
    case idle
    case connecting
    case open
    case reconnecting(attempt: Int, retryInSeconds: Double)
    /// Escalated after `escalateAfterAttempts` consecutive failures.
    case offline(reason: String)
    /// The credential was rejected; retrying will not help.
    case unauthorized(reason: String)

    public var isOpen: Bool { self == .open }

    public var isBusyConnecting: Bool {
        switch self {
        case .connecting, .reconnecting: return true
        default: return false
        }
    }
}

/// One connect attempt's destination; `protocols` is empty for every dial that carries its
/// credential in the URL instead (FEAT-015).
public struct GatewayDial: Sendable, Equatable {
    public let url: URL
    public let protocols: [String]

    public init(url: URL, protocols: [String] = []) {
        self.url = url
        self.protocols = protocols
    }

    /// True when the credential rides in `Sec-WebSocket-Protocol`, so a failure is worth one retry
    /// down the older path.
    public var carriesTicketProtocol: Bool {
        protocols.contains { $0.hasPrefix(GatewayWSProtocol.ticketPrefix) }
    }
}

/// The two calls the connect machine makes on the auth/REST pair, injected so the dial and
/// reconnect machinery is testable without a live backend.
public struct GatewayDialer: Sendable {
    public var getStatus: @Sendable () async throws -> ServerStatus
    public var webSocketURL: @Sendable (_ authRequired: Bool) async throws -> URL
    /// The FEAT-015 shape, defaulted from `webSocketURL` for a caller that offers no subprotocol.
    public var webSocketDial: @Sendable (
        _ authRequired: Bool, _ preferSubprotocol: Bool
    ) async throws -> GatewayDial

    public init(
        getStatus: @escaping @Sendable () async throws -> ServerStatus,
        webSocketURL: @escaping @Sendable (_ authRequired: Bool) async throws -> URL
    ) {
        self.getStatus = getStatus
        self.webSocketURL = webSocketURL
        self.webSocketDial = { authRequired, _ in
            GatewayDial(url: try await webSocketURL(authRequired))
        }
    }

    public init(
        getStatus: @escaping @Sendable () async throws -> ServerStatus,
        webSocketURL: @escaping @Sendable (_ authRequired: Bool) async throws -> URL,
        webSocketDial: @escaping @Sendable (
            _ authRequired: Bool, _ preferSubprotocol: Bool
        ) async throws -> GatewayDial
    ) {
        self.getStatus = getStatus
        self.webSocketURL = webSocketURL
        self.webSocketDial = webSocketDial
    }

    public init(auth: AuthenticationClient, rest: RestAPI) {
        self.init(
            getStatus: { try await rest.getStatus() },
            webSocketURL: { try await auth.webSocketURL(authRequired: $0) },
            webSocketDial: { try await auth.webSocketDial(authRequired: $0, preferSubprotocol: $1) }
        )
    }
}

/// The JSON-RPC gateway client: request correlation, event fan-out, connect handshake and reconnect.
public actor HermesClient {
    // MARK: Tunables (reference-clients.md §1.9 timeout table)

    /// Every RPC by default.
    public static let defaultRequestTimeout: TimeInterval = 30
    /// `prompt.submit` only, matching the backend's own agent-turn ceiling; the ack is not turn
    /// completion, which arrives as `message.complete`.
    public static let promptSubmitTimeout: TimeInterval = 1800
    /// Session listing / resume.
    public static let sessionRequestTimeout: TimeInterval = 60
    /// The WHOLE open budget: dial, TLS, the 101 upgrade and the server's opening `gateway.ready`.
    /// One number rather than two, because `connect` returns without awaiting the upgrade, so there
    /// is no separate "open but not ready" moment to budget for.
    public static let handshakeTimeout: TimeInterval = 25
    /// 1s, 2s, 4s, 8s … capped at 15s.
    public static let reconnectCap: TimeInterval = 15
    /// After this many consecutive failures the UI gets a recovery route, not a permanent spinner.
    public static let escalateAfterAttempts = 6

    public static func defaultTimeout(for method: String) -> TimeInterval {
        switch method {
        case "prompt.submit": return promptSubmitTimeout
        case "session.list", "session.resume", "session.activate",
             "session.active_list", "session.branch", "session.compress":
            return sessionRequestTimeout
        default: return defaultRequestTimeout
        }
    }

    // MARK: State

    private struct PendingCall {
        let method: String
        let timeoutSeconds: TimeInterval
        let continuation: CheckedContinuation<JSONValue, Error>
        var timeoutTask: Task<Void, Never>?
    }

    /// How a transport is built — the seam a test replaces with a scripted transport.
    public typealias TransportFactory = @Sendable (
        _ onFrame: @escaping WebSocketTransport.FrameHandler,
        _ onState: @escaping WebSocketTransport.StateHandler
    ) -> any GatewayTransport

    private let dialer: GatewayDialer
    private let transportFactory: TransportFactory
    private let log: ConnectionLog?

    private var transport: (any GatewayTransport)?
    private var pending: [String: PendingCall] = [:]
    private var nextID = 0

    private var outbox: [String] = []
    private var writerTask: Task<Void, Never>?

    private var eventContinuations: [UUID: AsyncStream<GatewayEvent>.Continuation] = [:]
    private var stateContinuations: [UUID: AsyncStream<GatewayConnectionState>.Continuation] = [:]

    private var readyContinuation: CheckedContinuation<Void, Error>?
    private var handshakeTimeoutTask: Task<Void, Never>?
    private var sawReady = false
    /// Set when the transport reports `.closed` after this attempt started dialing; a socket
    /// refused fast enough closes BEFORE `waitForReady` installs its continuation, and without the
    /// latch that close mislabels itself as a handshake timeout a full budget later.
    private var transportClosedSinceConnect = false
    private var transportCloseReason = ""
    /// Latched false the first time a connection was only won by falling back to `?ticket=`;
    /// session-scoped, so a backend upgrade re-enables it at the next launch (FEAT-015).
    private var preferSubprotocolTicket = true
    /// Bumped per transport so callbacks from a superseded socket are ignored.
    private var transportGeneration = 0

    private var connectTask: Task<Void, Error>?
    private var connectInFlight = false
    /// The barrier cancellation is not (BUG-067B): task cancellation is cooperative and
    /// `performConnect` has no checkpoints, so a dial parked in an await would otherwise resume and
    /// set `.open` against a backend the user has already left.
    private var connectEpoch = 0
    private var reconnectTask: Task<Void, Never>?
    private var reconnectAttempt = 0
    private var autoReconnectEnabled = true

    public private(set) var state: GatewayConnectionState = .idle
    /// Last successful `/api/status` probe — the server identity the settings screens display.
    public private(set) var serverStatus: ServerStatus?
    /// The backend broadcasts `sessions.changed`, so polling can be demoted to a slow backstop.
    public private(set) var changeEventsSupported = false
    /// The backend fans a session's events out to every client and accepts `session.resume(watch:)`;
    /// capability detection lives here, on the handshake — never probe by sending the param.
    public private(set) var sessionMirroringSupported = false
    /// This connection's transport id, compared against mirrored frames to tell whose turn is whose.
    public private(set) var transportOrigin = ""

    /// Production entry point.
    public init(auth: AuthenticationClient, rest: RestAPI, log: ConnectionLog? = nil) {
        self.init(dialer: GatewayDialer(auth: auth, rest: rest), log: log)
    }

    /// Seam entry point: everything the connect machine touches, injectable.
    public init(
        dialer: GatewayDialer,
        log: ConnectionLog? = nil,
        transportFactory: @escaping TransportFactory = { onFrame, onState in
            WebSocketTransport(onFrame: onFrame, onState: onState)
        }
    ) {
        self.dialer = dialer
        self.log = log
        self.transportFactory = transportFactory
    }

    /// The whole open budget for one attempt; settable so a timeout test does not take 25 s.
    var handshakeBudget: TimeInterval = HermesClient.handshakeTimeout

    func setHandshakeBudget(_ seconds: TimeInterval) {
        handshakeBudget = seconds
    }

    // MARK: - Streams

    /// A new independent subscription; multiple readers are supported and none steals events.
    public nonisolated func events() -> AsyncStream<GatewayEvent> {
        AsyncStream(bufferingPolicy: .bufferingNewest(2048)) { continuation in
            let id = UUID()
            Task { await self.addEventContinuation(id: id, continuation) }
            continuation.onTermination = { _ in
                Task { await self.removeEventContinuation(id: id) }
            }
        }
    }

    /// Connection state, replaying the current value on subscribe, so a late-mounting view learns
    /// the state without a separate getter.
    public nonisolated func states() -> AsyncStream<GatewayConnectionState> {
        AsyncStream(bufferingPolicy: .bufferingNewest(64)) { continuation in
            let id = UUID()
            Task { await self.addStateContinuation(id: id, continuation) }
            continuation.onTermination = { _ in
                Task { await self.removeStateContinuation(id: id) }
            }
        }
    }

    private func addEventContinuation(id: UUID, _ continuation: AsyncStream<GatewayEvent>.Continuation) {
        eventContinuations[id] = continuation
    }

    private func removeEventContinuation(id: UUID) {
        eventContinuations[id] = nil
    }

    private func addStateContinuation(id: UUID, _ continuation: AsyncStream<GatewayConnectionState>.Continuation) {
        stateContinuations[id] = continuation
        continuation.yield(state)
    }

    private func removeStateContinuation(id: UUID) {
        stateContinuations[id] = nil
    }

    private func setState(_ newState: GatewayConnectionState) {
        guard state != newState else { return }
        state = newState
        for continuation in stateContinuations.values { continuation.yield(newState) }
    }

    private func broadcast(_ event: GatewayEvent) {
        for continuation in eventContinuations.values { continuation.yield(event) }
    }

    // MARK: - Connect

    public func setAutoReconnectEnabled(_ enabled: Bool) {
        autoReconnectEnabled = enabled
        if !enabled {
            reconnectTask?.cancel()
            reconnectTask = nil
        }
    }

    /// Single-flight connect, idempotent while already open or connecting.
    public func connect() async throws {
        // An explicit connect re-arms the keepalive loop that `disconnect()` switched off.
        autoReconnectEnabled = true
        if state.isOpen, transport != nil { return }
        // An explicit dial supersedes a pending backoff; a dial in flight is joined, never raced.
        reconnectTask?.cancel()
        reconnectTask = nil
        do {
            try await runSharedConnect()
        } catch {
            // A failed connect still arms the backoff, unless the credential was rejected:
            // retrying that only burns tickets and the user has to act.
            if case .unauthorized = state {} else {
                scheduleReconnect(reason: HermesError.from(error).localizedDescription)
            }
            throw error
        }
    }

    /// One dial for everyone: `connect()`, `wake()` and the backoff timer all funnel through here,
    /// so two `performConnect`s can never race for `readyContinuation`.
    private func runSharedConnect() async throws {
        if let existing = connectTask {
            try await existing.value
            return
        }
        let task = Task<Void, Error> { [weak self] in
            guard let self else { return }
            try await self.performConnect()
        }
        connectTask = task
        // Cleared on EVERY exit; re-nilling after a `disconnect()` already did is harmless.
        do {
            try await task.value
            connectTask = nil
        } catch {
            connectTask = nil
            throw error
        }
    }

    /// Throws when a `disconnect()` has landed since this dial started (BUG-067B).
    private func abortIfSuperseded(_ epoch: Int) throws {
        guard epoch != connectEpoch else { return }
        throw HermesError.connectionClosed("The connection attempt was superseded by a disconnect.")
    }

    private func performConnect() async throws {
        reconnectTask?.cancel()
        reconnectTask = nil
        connectInFlight = true
        defer { connectInFlight = false }
        connectEpoch += 1
        let epoch = connectEpoch
        setState(.connecting)
        sawReady = false

        // (a) Probe the public status route first: it is the only thing that knows whether this
        // bind is gated, and the answer decides which WS credential to mint (reference §10).
        let status: ServerStatus
        do {
            status = try await dialer.getStatus()
            serverStatus = status
        } catch {
            let mapped = HermesError.from(error)
            await log?.warning("gateway", "status probe failed: \(mapped.localizedDescription)")
            setState(.offline(reason: mapped.localizedDescription))
            throw mapped
        }
        try abortIfSuperseded(epoch)
        await log?.info(
            "gateway",
            "status ok — version \(status.version), auth_required=\(status.authRequired), gateway=\(status.gatewayState)"
        )

        // (b) Mint a FRESH credential: tickets are single-use with a 30 s TTL, so a cached URL is
        // never reusable (reference §2.7). FEAT-015 prefers carrying it in `Sec-WebSocket-Protocol`,
        // latching off for this client's life the first time the older path is what connected.
        let preferSubprotocol = preferSubprotocolTicket && status.authRequired
        let dial: GatewayDial
        do {
            dial = try await dialer.webSocketDial(status.authRequired, preferSubprotocol)
        } catch {
            let mapped = HermesError.from(error)
            if case .missingCredential(let detail) = mapped {
                setState(.unauthorized(reason: detail))
            } else if mapped.isAuthenticationFailure {
                setState(.unauthorized(reason: mapped.localizedDescription))
            } else {
                setState(.offline(reason: mapped.localizedDescription))
            }
            throw mapped
        }
        try abortIfSuperseded(epoch)

        do {
            try await openSocket(dial)
            if dial.carriesTicketProtocol {
                await log?.info("gateway", "connected — ticket carried as a WebSocket subprotocol")
            }
        } catch {
            let first = HermesError.from(error)
            // (b2) The fallback, only ever taken by a dial that moved the ticket into the protocol
            // header. A refusal and a backend older than the feature are indistinguishable from
            // here, and both are fixed by asking again the old way, with a freshly minted ticket.
            guard dial.carriesTicketProtocol else {
                settleFailedConnect(first)
                throw first
            }
            await log?.warning(
                "gateway",
                "subprotocol ticket handshake failed (\(first.localizedDescription)); retrying with the query-parameter ticket"
            )
            setState(.connecting)
            let legacy: GatewayDial
            do {
                legacy = try await dialer.webSocketDial(status.authRequired, false)
            } catch {
                settleFailedConnect(first)
                throw first
            }
            do {
                try await openSocket(legacy)
            } catch {
                let second = HermesError.from(error)
                settleFailedConnect(second)
                throw second
            }
            // It connected the old way, so stop paying for the new one.
            preferSubprotocolTicket = false
            await log?.info("gateway", "connected — ticket carried in the query string (fallback)")
        }

        // The barrier that matters (BUG-067B): everything above is recoverable, but announcing
        // `.open` is not, so a dial that outlived its disconnect closes the socket it just won.
        if connectEpoch != epoch {
            if let transport = transport { await transport.disconnect() }
            transport = nil
            sawReady = false
            await log?.info("gateway", "connect completed after a disconnect; closing the socket it opened")
            throw HermesError.connectionClosed("The connection attempt was superseded by a disconnect.")
        }
        reconnectAttempt = 0
        setState(.open)
        await log?.info("gateway", "connected")
    }

    /// One socket attempt: build the transport, open it, wait for the server's opening frame. Sets
    /// no state, because the caller may still have a second attempt to make.
    private func openSocket(_ dial: GatewayDial) async throws {
        // A close on the previous attempt may already have scheduled a reconnect; this supersedes it.
        reconnectTask?.cancel()
        reconnectTask = nil
        sawReady = false

        await log?.debug(
            "gateway",
            "dialing \(Redaction.url(dial.url))\(dial.carriesTicketProtocol ? " with a ticket subprotocol" : "")"
        )

        let transport = makeTransport()
        self.transport = transport
        transportClosedSinceConnect = false
        transportCloseReason = ""
        do {
            // Returns once the receive loop is running; it does NOT await the upgrade, so the whole
            // open budget is spent under `waitForReady` below.
            try await transport.connect(url: dial.url, protocols: dial.protocols)
        } catch {
            await transport.disconnect()
            self.transport = nil
            throw HermesError.from(error)
        }

        // The server pushes `gateway.ready` on accept, before any client request; waiting for it is
        // what distinguishes a real connection from one accepted and immediately dropped.
        do {
            try await waitForReady()
        } catch {
            let mapped = HermesError.from(error)
            await transport.disconnect()
            self.transport = nil
            let closeCode = await transport.lastCloseCode
            if HermesError.authRejectionCloseCodes.contains(closeCode) {
                throw HermesError.unauthorized(
                    "The gateway rejected the credential (close \(closeCode))."
                )
            }
            throw mapped
        }
    }

    /// The state a connect attempt leaves behind once there is no retry left.
    private func settleFailedConnect(_ error: HermesError) {
        if case .unauthorized(let reason) = error {
            setState(.unauthorized(reason: reason))
        } else {
            setState(.offline(reason: error.localizedDescription))
        }
    }

    /// Every transport carries the generation it was created in, and callbacks from an older one
    /// are dropped: a dead socket's receive loop can still be unwinding while the replacement dials.
    private func makeTransport() -> any GatewayTransport {
        transportGeneration += 1
        let generation = transportGeneration
        return transportFactory(
            { [weak self] frame in
                await self?.handle(frame: frame, generation: generation)
            },
            { [weak self] transportState, closeCode in
                await self?.handle(transportState: transportState, closeCode: closeCode, generation: generation)
            }
        )
    }

    private func waitForReady() async throws {
        if sawReady { return }
        // The socket may already be gone, its close having arrived while no continuation was
        // installed; fail on it now rather than waiting out the budget and blaming a timeout.
        if transportClosedSinceConnect {
            throw HermesError.connectionClosed(
                transportCloseReason.isEmpty ? "The gateway closed the connection." : transportCloseReason
            )
        }
        handshakeTimeoutTask?.cancel()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            if let superseded = readyContinuation {
                // Unreachable while every dial funnels through `runSharedConnect`; if a second
                // concurrent dial ever returns, fail it loudly rather than leaking a hung task.
                readyContinuation = nil
                superseded.resume(throwing: HermesError.connectionClosed("Superseded by a newer connect attempt."))
            }
            readyContinuation = continuation
            let budget = handshakeBudget
            handshakeTimeoutTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(budget * 1_000_000_000))
                guard !Task.isCancelled else { return }
                await self?.finishReady(with: HermesError.handshakeTimedOut)
            }
        }
    }

    private func finishReady(with error: Error?) {
        handshakeTimeoutTask?.cancel()
        handshakeTimeoutTask = nil
        guard let continuation = readyContinuation else { return }
        readyContinuation = nil
        if let error {
            continuation.resume(throwing: error)
        } else {
            continuation.resume()
        }
    }

    /// Tear down deliberately. Stops auto-reconnect; `connect()` restarts it.
    public func disconnect() async {
        autoReconnectEnabled = false
        // Cancelling the task is not enough: moving the epoch is what makes a dial already in
        // flight fail instead of finishing (BUG-067B).
        connectEpoch += 1
        reconnectTask?.cancel()
        reconnectTask = nil
        connectTask?.cancel()
        connectTask = nil
        finishReady(with: HermesError.connectionClosed("Disconnected"))
        failAllPending(HermesError.connectionClosed("The gateway connection closed."))
        // Queued frames die with the socket they were aimed at; replay is a consent hazard.
        outbox.removeAll()
        if let transport = transport { await transport.disconnect() }
        transport = nil
        setState(.idle)
        await log?.info("gateway", "disconnected by request")
    }

    // MARK: - Reconnect

    /// App-lifecycle wake hook: cancel the pending backoff and retry immediately, because after a
    /// device sleep the socket is silently dead and the user is looking at the app (reference §7.2).
    public func wake() async {
        guard autoReconnectEnabled else { return }
        if state.isOpen, let transport = transport, await transport.state == .open { return }
        reconnectTask?.cancel()
        reconnectTask = nil
        reconnectAttempt = 0
        try? await connect()
    }

    private func scheduleReconnect(reason: String) {
        guard autoReconnectEnabled else { return }
        guard reconnectTask == nil, !connectInFlight else { return }
        reconnectAttempt += 1
        let exponent = Double(min(reconnectAttempt - 1, 4))
        let delay = min(Self.reconnectCap, pow(2.0, exponent))
        if reconnectAttempt > Self.escalateAfterAttempts {
            setState(.offline(reason: reason))
        } else {
            setState(.reconnecting(attempt: reconnectAttempt, retryInSeconds: delay))
        }
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await self?.attemptReconnect()
        }
    }

    private func attemptReconnect() async {
        reconnectTask = nil
        guard autoReconnectEnabled else { return }
        // The app foregrounds mid-backoff, `wake()` dials, and this timer fires while that dial is
        // in flight; the flight settles the state either way, so this timer stands down.
        guard connectTask == nil, !connectInFlight else { return }
        do {
            try await runSharedConnect()
        } catch {
            let mapped = HermesError.from(error)
            if case .unauthorized = state {
                // Retrying a rejected credential just burns tickets; the user has to act.
                await log?.warning("gateway", "reconnect halted: \(mapped.localizedDescription)")
                return
            }
            scheduleReconnect(reason: mapped.localizedDescription)
        }
    }

    // MARK: - Requests

    /// Correlate strictly by `id`: methods run on a thread pool and responses can arrive out of
    /// order (jsonrpc-methods §0.6).
    @discardableResult
    public func request(
        _ method: String,
        params: JSONValue? = nil,
        timeout: TimeInterval? = nil
    ) async throws -> JSONValue {
        guard state.isOpen, transport != nil else { throw HermesError.notConnected }
        let effectiveTimeout = timeout ?? Self.defaultTimeout(for: method)
        nextID += 1
        let id = "i\(nextID)"
        let line: String
        do {
            line = try JSONRPCCodec.encodeRequest(id: id, method: method, params: params)
        } catch {
            throw HermesError.from(error)
        }

        // Params are never logged: `sudo.respond` carries a password, `secret.respond` an API key.
        await log?.debug("rpc", "→ \(method) [\(id)]")

        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<JSONValue, Error>) in
            pending[id] = PendingCall(
                method: method,
                timeoutSeconds: effectiveTimeout,
                continuation: continuation,
                timeoutTask: nil
            )
            if effectiveTimeout > 0 {
                pending[id]?.timeoutTask = Task { [weak self] in
                    try? await Task.sleep(nanoseconds: UInt64(effectiveTimeout * 1_000_000_000))
                    guard !Task.isCancelled else { return }
                    await self?.expire(id: id)
                }
            }
            enqueue(line: line)
        }
    }

    private func expire(id: String) {
        guard let call = pending.removeValue(forKey: id) else { return }
        call.timeoutTask?.cancel()
        call.continuation.resume(
            throwing: HermesError.requestTimedOut(
                method: call.method,
                seconds: Int(call.timeoutSeconds.rounded())
            )
        )
    }

    private func fail(id: String, with error: Error) {
        guard let call = pending.removeValue(forKey: id) else { return }
        call.timeoutTask?.cancel()
        call.continuation.resume(throwing: error)
    }

    private func failAllPending(_ error: Error) {
        let calls = pending
        pending.removeAll()
        for (_, call) in calls {
            call.timeoutTask?.cancel()
            call.continuation.resume(throwing: error)
        }
    }

    // MARK: - Outbound serialization

    /// A single writer drains the queue so wire order matches call order — an `approval.respond`
    /// must not overtake the `prompt.submit` that provoked it.
    private func enqueue(line: String) {
        outbox.append(line)
        guard writerTask == nil else { return }
        writerTask = Task { [weak self] in
            await self?.drainOutbox()
        }
    }

    private func drainOutbox() async {
        while !outbox.isEmpty {
            let line = outbox.removeFirst()
            guard let transport = transport else {
                failAllPending(HermesError.notConnected)
                // `approval.respond` is positional FIFO with no request id, so a frame flushed onto
                // the NEXT socket could answer an approval the user never saw.
                outbox.removeAll()
                break
            }
            do {
                try await transport.send(line: line)
            } catch {
                let mapped = HermesError.from(error)
                await log?.warning("rpc", "send failed: \(mapped.localizedDescription)")
                failAllPending(mapped)
                outbox.removeAll()
                // BUG-067A: a send that throws is a socket that is gone, and on a silently
                // NAT-dropped one no close ever arrives to arm a reconnect by itself.
                await failSocket(after: mapped)
                break
            }
        }
        writerTask = nil
    }

    /// The `.closed` teardown reached from the other direction: a send that threw rather than a
    /// close that arrived, so the auth exemption is read off the error instead of a close code.
    private func failSocket(after error: HermesError) async {
        let reason = "The connection dropped (\(error.localizedDescription))."
        let wasLive = state.isOpen || state.isBusyConnecting
        transportClosedSinceConnect = true
        transportCloseReason = reason
        sawReady = false
        finishReady(with: HermesError.connectionClosed(reason))

        // The terminal state is decided BEFORE the transport is torn down, and the order is
        // load-bearing: `disconnect()` fires the close callback, which reads `state.isOpen` to
        // decide whether to arm a backoff.
        if error.isAuthenticationFailure {
            // Redialing a rejected credential only burns tickets, and the user has to act.
            setState(.unauthorized(reason: error.localizedDescription))
        } else if wasLive {
            await log?.warning("gateway", reason)
            scheduleReconnect(reason: reason)
            if state.isOpen {
                // The one thing that must not survive this method is the claim the socket is open.
                setState(.offline(reason: reason))
            }
        } else {
            setState(.idle)
        }

        if let transport = transport { await transport.disconnect() }
        transport = nil
    }

    // MARK: - Inbound

    private func handle(frame: JSONRPCFrame, generation: Int) async {
        guard generation == transportGeneration else { return }
        switch frame {
        case .response(let response):
            guard let id = response.id.coercedString else { return }
            guard let call = pending.removeValue(forKey: id) else { return }
            call.timeoutTask?.cancel()
            if let error = response.error {
                await log?.debug("rpc", "← \(call.method) [\(id)] error \(error.code): \(error.message)")
                // BUG-141: `error.data` rides through; an older backend sends none and it stays nil.
                call.continuation.resume(
                    throwing: HermesError.rpc(code: error.code, message: error.message, data: error.data)
                )
            } else {
                call.continuation.resume(returning: response.result ?? .null)
            }

        case .event(let event):
            if event.type == "gateway.ready" {
                sawReady = true
                changeEventsSupported = event.payload["change_events"]?.coercedBool ?? false
                sessionMirroringSupported = event.payload["session_mirroring"]?.coercedBool ?? false
                transportOrigin = event.payload["origin"]?.coercedString ?? ""
                await log?.info(
                    "gateway",
                    "gateway.ready (change_events=\(changeEventsSupported), "
                        + "session_mirroring=\(sessionMirroringSupported), origin=\(transportOrigin))"
                )
                // BUG-065 — arm the liveness probe HERE, on the frame, never in the connect path:
                // CFNetwork will not service a pong while this frame sits unread, so a ping-gated
                // open self-deadlocks against the server speaking first.
                if let transport = transport { await transport.startKeepalive() }
                finishReady(with: nil)
            }
            broadcast(event)

        case .serverRequest(let id, let method, _):
            // The dialect has no server-to-client requests today; answer defensively so a future
            // one can never leave the agent thread parked.
            await log?.warning("gateway", "unsupported server request: \(method)")
            if let line = try? JSONRPCCodec.encodeResponse(
                id: id,
                result: .object(["ok": .bool(false), "error": .string("unsupported by this client")])
            ) {
                enqueue(line: line)
            }

        case .unknown:
            break
        }
    }

    /// `closeCode` is carried by the close that fired this callback, never re-read from
    /// `self.transport`, which may already be the replacement socket.
    private func handle(transportState: ConnectionState, closeCode: Int, generation: Int) async {
        guard generation == transportGeneration else { return }
        switch transportState {
        case .closed:
            let wasOpen = state.isOpen
            let reason = closeCode == 0
                ? "The connection dropped."
                : "The connection dropped (close \(closeCode))."
            // Latch it: a dial in flight may not have installed its ready continuation yet.
            transportClosedSinceConnect = true
            transportCloseReason = reason
            finishReady(with: HermesError.connectionClosed(reason))
            failAllPending(HermesError.connectionClosed("The gateway connection closed."))
            // Frames queued for the dead socket must not survive to the next one.
            outbox.removeAll()
            sawReady = false
            if HermesError.authRejectionCloseCodes.contains(closeCode) {
                let rejected = "The gateway rejected the credential (close \(closeCode))."
                transportCloseReason = rejected
                await log?.warning("gateway", rejected)
                setState(.unauthorized(reason: rejected))
                return
            }
            if wasOpen || state.isBusyConnecting {
                await log?.warning("gateway", reason)
                scheduleReconnect(reason: reason)
            }

        case .open, .connecting, .idle:
            break
        }
    }

}
