import XCTest

@testable import HermesServeKit

/// BUG-067 — two holes in the transport state machine.
///
/// A. **A send failure was not treated as a close.** `drainOutbox`'s catch
/// mapped the error, failed the pending calls and cleared the queue, and
/// stopped there: no state change, no transport teardown, no reconnect. Since
/// reconnect arms only from the `.closed` handler or a failed `connect()`, and
/// a silently NAT-dropped socket never sends a close, the client sat there
/// rendering connected chrome over a dead socket with every RPC failing
/// instantly and nothing redialing.
///
/// B. **A disconnect could not stop a dial already in flight.** `disconnect()`
/// cancels `connectTask`, but cancellation is cooperative and `performConnect`
/// had no checkpoints, so a dial parked in the status probe or the ticket mint
/// resumed, finished, and set `.open` against a backend the user had explicitly
/// signed out of.
final class HermesClientSendFailureTests: XCTestCase {

    // MARK: Scripted transport

    /// Mirrors `WebSocketTransport`'s contract closely enough for the connect
    /// machine: `connect` returns once the receive loop would be running, and
    /// `gateway.ready` arrives as a frame.
    private actor Transport: GatewayTransport {
        private let onFrame: WebSocketTransport.FrameHandler
        private let onState: WebSocketTransport.StateHandler

        private(set) var state: ConnectionState = .idle
        private(set) var lastCloseCode: Int = 0
        private(set) var sentLines: [String] = []
        private(set) var disconnectCount = 0
        private var sendError: HermesError?

        init(
            onFrame: @escaping WebSocketTransport.FrameHandler,
            onState: @escaping WebSocketTransport.StateHandler
        ) {
            self.onFrame = onFrame
            self.onState = onState
        }

        func connect(url: URL) async throws {
            state = .open
            await onState(.open, 0)
            await onFrame(.event(GatewayEvent(
                type: "gateway.ready",
                sessionID: "",
                payload: .object(["change_events": .bool(true)]),
                params: .null
            )))
        }

        func disconnect() async {
            disconnectCount += 1
            state = .closed
            await onState(.closed, lastCloseCode)
        }

        func send(line: String) async throws {
            if let sendError { throw sendError }
            sentLines.append(line)
        }

        /// The post-NAT-drop condition: `WebSocketTransport.send` throws
        /// -32000 "gateway not connected" whenever its task is nil or its state
        /// is not `.open`, and **no close ever arrives** to say so.
        func failSends(with error: HermesError) { sendError = error }
    }

    private final class Hub: @unchecked Sendable {
        private let lock = NSLock()
        private var created: [Transport] = []

        func make(
            onFrame: @escaping WebSocketTransport.FrameHandler,
            onState: @escaping WebSocketTransport.StateHandler
        ) -> Transport {
            let transport = Transport(onFrame: onFrame, onState: onState)
            lock.lock()
            created.append(transport)
            lock.unlock()
            return transport
        }

        var transports: [Transport] {
            lock.lock(); defer { lock.unlock() }
            return created
        }
    }

    // MARK: Scripted dialer

    private actor Dialer {
        private(set) var statusCalls = 0
        private(set) var ticketCalls = 0
        private var gateClosed = false
        private var waiters: [CheckedContinuation<Void, Never>] = []

        func closeGate() { gateClosed = true }

        func openGate() {
            gateClosed = false
            for waiter in waiters { waiter.resume() }
            waiters.removeAll()
        }

        func status() async throws -> ServerStatus {
            statusCalls += 1
            if gateClosed {
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    waiters.append(continuation)
                }
            }
            return ServerStatus(json: .object([
                "version": .string("test"),
                "auth_required": .bool(false),
                "gateway_running": .bool(true),
            ]))
        }

        func webSocketURL() async throws -> URL {
            ticketCalls += 1
            return URL(string: "ws://mock.test/ws?ticket=\(ticketCalls)")!
        }
    }

    private func makeClient(dialer: Dialer) -> (HermesClient, Hub) {
        let hub = Hub()
        let client = HermesClient(
            dialer: GatewayDialer(
                getStatus: { try await dialer.status() },
                webSocketURL: { _ in try await dialer.webSocketURL() }
            ),
            log: nil,
            transportFactory: { onFrame, onState in hub.make(onFrame: onFrame, onState: onState) }
        )
        return (client, hub)
    }

    private func waitUntil(timeout: TimeInterval = 5, _ predicate: () async -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await predicate() { return true }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return await predicate()
    }

    private func deadSocketError() -> HermesError {
        HermesError.rpc(code: -32000, message: "gateway not connected")
    }

    // MARK: - A: a send failure is a close

    func testASendFailureMovesTheClientOffOpen() async throws {
        let dialer = Dialer()
        let (client, hub) = makeClient(dialer: dialer)
        try await client.connect()
        let opened = await client.state
        XCTAssertTrue(opened.isOpen, "precondition")

        await hub.transports[0].failSends(with: deadSocketError())

        do {
            _ = try await client.request("session.list")
            XCTFail("the send failed; the request must not resolve")
        } catch {}

        let left = await waitUntil { await client.state.isOpen == false }
        XCTAssertTrue(
            left,
            "the client is still advertising .open over a socket whose send just threw — connected "
                + "chrome, a live dot, and every later RPC failing instantly"
        )

        await client.disconnect()
    }

    /// The half that matters to a user: it redials. Without this the only way
    /// out was backgrounding and foregrounding the app.
    func testASendFailureSchedulesAReconnect() async throws {
        let dialer = Dialer()
        let (client, hub) = makeClient(dialer: dialer)
        try await client.connect()
        let statusCallsBefore = await dialer.statusCalls

        await hub.transports[0].failSends(with: deadSocketError())
        _ = try? await client.request("session.list")

        let redialed = await waitUntil(timeout: 8) { await dialer.statusCalls > statusCallsBefore }
        XCTAssertTrue(redialed, "nothing ever redialed: reconnect arms only from a close that never comes")

        await client.disconnect()
    }

    /// The dead socket is let go of, not left attached. A transport still held
    /// after its send threw is what makes the next `request` fail instantly
    /// instead of queueing behind a redial.
    func testASendFailureTearsDownTheDeadTransport() async throws {
        let dialer = Dialer()
        let (client, hub) = makeClient(dialer: dialer)
        try await client.connect()

        await hub.transports[0].failSends(with: deadSocketError())
        _ = try? await client.request("session.list")

        let torn = await waitUntil { await hub.transports[0].disconnectCount > 0 }
        XCTAssertTrue(torn, "the client kept the dead transport attached")

        await client.disconnect()
    }

    /// The exemption, matching the close handler's treatment of the 4401
    /// family: a rejected credential must not spin the backoff loop, because
    /// retrying only burns tickets and the user has to act.
    func testARejectedCredentialOnSendGoesToUnauthorizedAndDoesNotRedial() async throws {
        let dialer = Dialer()
        let (client, hub) = makeClient(dialer: dialer)
        try await client.connect()
        let statusCallsBefore = await dialer.statusCalls

        await hub.transports[0].failSends(
            with: HermesError.unauthorized("The gateway rejected the credential.")
        )
        _ = try? await client.request("session.list")

        let unauthorized = await waitUntil {
            let state = await client.state
            if case .unauthorized = state { return true }
            return false
        }
        XCTAssertTrue(unauthorized, "a send rejected for auth must say so rather than look like a drop")

        let redialed = await waitUntil(timeout: 3) { await dialer.statusCalls > statusCallsBefore }
        XCTAssertFalse(redialed, "a rejected credential must not be retried")

        await client.disconnect()
    }

    /// The control. An ordinary connected client still sends, and nothing about
    /// the new teardown fires on the happy path.
    func testAnOrdinarySendStillGoesOutAndKeepsTheSocket() async throws {
        let dialer = Dialer()
        let (client, hub) = makeClient(dialer: dialer)
        try await client.connect()

        let pending = Task { _ = try? await client.request("session.list") }
        let sent = await waitUntil { await hub.transports[0].sentLines.isEmpty == false }
        XCTAssertTrue(sent)

        let state = await client.state
        XCTAssertTrue(state.isOpen, "a successful send must not disturb the connection")
        let teardowns = await hub.transports[0].disconnectCount
        XCTAssertEqual(teardowns, 0)

        await client.disconnect()
        await pending.value
    }

    // MARK: - B: a disconnect stops a dial in flight

    /// Sign out while the first dial is parked in the status probe. The dial
    /// then completes — the probe is not cancellation-aware, which is the whole
    /// point — and must not come up `.open` against the backend the user just
    /// left.
    func testADialParkedInTheStatusProbeCannotOpenAfterDisconnect() async throws {
        let dialer = Dialer()
        let (client, hub) = makeClient(dialer: dialer)

        await dialer.closeGate()
        let dialing = Task { try? await client.connect() }
        let parked = await waitUntil { await dialer.statusCalls == 1 }
        XCTAssertTrue(parked, "precondition: the dial never reached the status probe")

        await client.disconnect()
        await dialer.openGate()
        _ = await dialing.value

        let state = await client.state
        XCTAssertFalse(
            state.isOpen,
            "a dial that outlived its disconnect came up open against a backend the user left"
        )
        XCTAssertTrue(
            hub.transports.isEmpty,
            "the superseded dial went on to open a socket after the user signed out"
        )

        // And it stays down: nothing re-arms a connection the user ended.
        let reopened = await waitUntil(timeout: 2) { await client.state.isOpen }
        XCTAssertFalse(reopened)
    }

    /// The control for B: with no intervening disconnect the same parked dial
    /// completes normally. A barrier that also blocked ordinary slow dials
    /// would be worse than the defect.
    func testAParkedDialStillOpensWhenNobodyDisconnects() async throws {
        let dialer = Dialer()
        let (client, _) = makeClient(dialer: dialer)

        await dialer.closeGate()
        let dialing = Task { try? await client.connect() }
        _ = await waitUntil { await dialer.statusCalls == 1 }
        await dialer.openGate()
        _ = await dialing.value

        let state = await client.state
        XCTAssertTrue(state.isOpen, "a slow dial must still connect")
        await client.disconnect()
    }
}
