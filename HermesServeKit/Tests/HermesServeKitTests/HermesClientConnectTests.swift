import XCTest

@testable import HermesServeKit

/// The connect/reconnect machine, driven through the `GatewayDialer` +
/// transport-factory seam. No sockets: every transport is scripted, every
/// close is injected, and the dial can be gated mid-flight to stage the
/// races the audit found (N1, NEW-1).
final class HermesClientConnectTests: XCTestCase {

    // MARK: Scripted transport

    /// Stand-in for `WebSocketTransport`. Mirrors its contract: `connect`
    /// returns once "the receive loop is running"; `gateway.ready` arrives as
    /// a frame; closes arrive through the state callback.
    private actor ScriptedTransport: GatewayTransport {
        enum Dial: Sendable {
            /// connect() returns and `gateway.ready` is delivered.
            case ready
            /// connect() returns; nothing ever arrives (dead upgrade).
            case silent
        }

        let dial: Dial
        private let onFrame: WebSocketTransport.FrameHandler
        private let onState: WebSocketTransport.StateHandler

        private(set) var state: ConnectionState = .idle
        private(set) var lastCloseCode: Int = 0
        private(set) var dialedURLs: [URL] = []
        private(set) var sentLines: [String] = []

        private var gateSends = false
        private var gatedSend: CheckedContinuation<Void, Error>?
        private(set) var gatedSendCount = 0

        init(
            dial: Dial,
            onFrame: @escaping WebSocketTransport.FrameHandler,
            onState: @escaping WebSocketTransport.StateHandler
        ) {
            self.dial = dial
            self.onFrame = onFrame
            self.onState = onState
        }

        func connect(url: URL) async throws {
            dialedURLs.append(url)
            state = .open
            await onState(.open, 0)
            if case .ready = dial {
                await onFrame(.event(GatewayEvent(
                    type: "gateway.ready",
                    sessionID: "",
                    payload: .object(["change_events": .bool(true)]),
                    params: .null
                )))
            }
        }

        func disconnect() async {
            state = .closed
            await onState(.closed, lastCloseCode)
        }

        func send(line: String) async throws {
            if gateSends {
                gatedSendCount += 1
                try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                    gatedSend = c
                }
            }
            sentLines.append(line)
        }

        func setGateSends(_ value: Bool) { gateSends = value }

        func releaseGatedSend() {
            gatedSend?.resume()
            gatedSend = nil
        }

        /// The server side closing the socket (drop, or credential rejection
        /// with 4401/4403).
        func serverClose(code: Int) async {
            lastCloseCode = code
            state = .closed
            await onState(.closed, code)
        }
    }

    /// Hands one scripted transport per dial, in order, and records them all.
    /// Lock-based because the factory closure is synchronous.
    private final class TransportHub: @unchecked Sendable {
        private let lock = NSLock()
        private var script: [ScriptedTransport.Dial]
        private var created: [ScriptedTransport] = []

        init(script: [ScriptedTransport.Dial]) { self.script = script }

        func make(
            onFrame: @escaping WebSocketTransport.FrameHandler,
            onState: @escaping WebSocketTransport.StateHandler
        ) -> ScriptedTransport {
            lock.lock(); defer { lock.unlock() }
            let dial = script.isEmpty ? ScriptedTransport.Dial.ready : script.removeFirst()
            let transport = ScriptedTransport(dial: dial, onFrame: onFrame, onState: onState)
            created.append(transport)
            return transport
        }

        var transports: [ScriptedTransport] {
            lock.lock(); defer { lock.unlock() }
            return created
        }
    }

    // MARK: Scripted dialer

    /// Counts status probes and ticket mints; the status probe can be failed
    /// once or gated open/closed to freeze a dial mid-flight.
    private actor ScriptedDialer {
        private(set) var statusCalls = 0
        private(set) var ticketCalls = 0
        private var failNextStatus = false
        private var statusGateClosed = false
        private var statusWaiters: [CheckedContinuation<Void, Never>] = []

        func setFailNextStatus() { failNextStatus = true }
        func closeStatusGate() { statusGateClosed = true }

        func openStatusGate() {
            statusGateClosed = false
            for waiter in statusWaiters { waiter.resume() }
            statusWaiters.removeAll()
        }

        func status() async throws -> ServerStatus {
            statusCalls += 1
            if failNextStatus {
                failNextStatus = false
                throw HermesError.httpStatus(code: 503, message: "scripted status failure")
            }
            if statusGateClosed {
                await withCheckedContinuation { statusWaiters.append($0) }
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

    // MARK: Harness

    private func makeClient(
        script: [ScriptedTransport.Dial] = [.ready],
        dialer: ScriptedDialer
    ) -> (HermesClient, TransportHub) {
        let hub = TransportHub(script: script)
        let client = HermesClient(
            dialer: GatewayDialer(
                getStatus: { try await dialer.status() },
                webSocketURL: { _ in try await dialer.webSocketURL() }
            ),
            log: nil,
            transportFactory: { onFrame, onState in
                hub.make(onFrame: onFrame, onState: onState)
            }
        )
        return (client, hub)
    }

    private func waitUntil(
        timeout: TimeInterval = 5,
        _ predicate: () async -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await predicate() { return true }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return await predicate()
    }

    // MARK: Tests

    func testConnectReachesOpenThroughTheSeam() async throws {
        let dialer = ScriptedDialer()
        let (client, hub) = makeClient(dialer: dialer)
        try await client.connect()
        let state = await client.state
        XCTAssertTrue(state.isOpen)
        XCTAssertEqual(hub.transports.count, 1)
        let dialed = await hub.transports[0].dialedURLs
        XCTAssertEqual(dialed.count, 1)
        await client.disconnect()
    }

    /// N1. Foregrounding mid-backoff must join the reconnect dial already in
    /// flight, not race it: two concurrent `performConnect`s fight over
    /// `readyContinuation`, the loser hangs forever, and when the loser is
    /// `connect()`'s own task the client wedges permanently.
    func testForegroundWakeDuringReconnectDialSharesOneFlight() async throws {
        let dialer = ScriptedDialer()
        let (client, hub) = makeClient(script: [.ready, .ready, .ready], dialer: dialer)

        // Dial 1 fails fast and arms the backoff (attempt 1 → ~1 s).
        await dialer.setFailNextStatus()
        do {
            try await client.connect()
            XCTFail("scripted status failure should throw")
        } catch {}

        // Freeze the reconnect timer's dial inside the status probe.
        await dialer.closeStatusGate()
        let reconnectDialing = await waitUntil(timeout: 4) { await dialer.statusCalls == 2 }
        XCTAssertTrue(reconnectDialing, "the backoff timer never redialed")

        // Foreground wake while that dial is mid-flight — the everyday trigger.
        let wakeTask = Task { await client.wake() }
        try? await Task.sleep(nanoseconds: 300_000_000)
        await dialer.openStatusGate()

        let settled = await waitUntil { await client.state.isOpen }
        XCTAssertTrue(settled, "the shared dial should reach .open")
        XCTAssertEqual(
            hub.transports.count, 1,
            "wake() raced the in-flight reconnect dial; the connect machine must single-flight"
        )

        // And the client is not wedged: a later connect() returns promptly.
        let laterConnect = Task { try? await client.connect() }
        let completed = await waitUntil(timeout: 3) { await client.state.isOpen }
        XCTAssertTrue(completed, "connect() after the race must not block forever")
        laterConnect.cancel()
        wakeTask.cancel()
        await client.disconnect()
    }

    /// Close-code classification: 4401/4403 is a credential rejection — the
    /// client surfaces `.unauthorized` and must NOT redial on it.
    func testCredentialRejectionCloseStopsReconnect() async throws {
        let dialer = ScriptedDialer()
        let (client, hub) = makeClient(dialer: dialer)
        try await client.connect()

        await hub.transports[0].serverClose(code: 4401)
        let unauthorized = await waitUntil {
            if case .unauthorized = await client.state { return true }
            return false
        }
        XCTAssertTrue(unauthorized, "a 4401 close must classify as .unauthorized")

        // The shortest backoff is 1 s; give it time to (wrongly) fire.
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        XCTAssertEqual(hub.transports.count, 1, "a rejected credential must not be redialed")
        await client.disconnect()
    }

    /// A plain drop (close code 0) reconnects — and every attempt mints a
    /// fresh ticket, because tickets are single-use with a 30 s TTL.
    func testPlainDropReconnectsWithAFreshTicket() async throws {
        let dialer = ScriptedDialer()
        let (client, hub) = makeClient(script: [.ready, .ready], dialer: dialer)
        try await client.connect()
        let ticketsAfterFirst = await dialer.ticketCalls
        XCTAssertEqual(ticketsAfterFirst, 1)

        await hub.transports[0].serverClose(code: 0)
        let reopened = await waitUntil(timeout: 6) {
            await client.state.isOpen && hub.transports.count == 2
        }
        XCTAssertTrue(reopened, "a plain drop should auto-reconnect")
        let tickets = await dialer.ticketCalls
        XCTAssertEqual(tickets, 2, "each attempt must mint its own ticket")
        let first = await hub.transports[0].dialedURLs
        let second = await hub.transports[1].dialedURLs
        XCTAssertNotEqual(first, second, "a cached ticket URL must never be re-dialed")
        await client.disconnect()
    }

    /// A dead upgrade — socket accepted, `gateway.ready` never arrives — must
    /// surface as `handshakeTimedOut`, not hang.
    func testSilentUpgradeReportsHandshakeTimeout() async throws {
        let dialer = ScriptedDialer()
        let (client, hub) = makeClient(script: [.silent], dialer: dialer)
        await client.setHandshakeBudget(0.3)
        do {
            try await client.connect()
            XCTFail("a silent upgrade must not connect")
        } catch let error as HermesError {
            guard case .handshakeTimedOut = error else {
                return XCTFail("expected handshakeTimedOut, got \(error)")
            }
        }
        XCTAssertEqual(hub.transports.count, 1)
        await client.disconnect()
    }

    /// NEW-1. Frames still queued when the socket dies must never flush onto
    /// the next socket: `approval.respond` is positional FIFO, so a replayed
    /// "once"/"always" could answer an approval the user never saw.
    func testOutboxIsNotReplayedAcrossReconnect() async throws {
        let dialer = ScriptedDialer()
        let (client, hub) = makeClient(script: [.ready, .ready], dialer: dialer)
        try await client.connect()
        let first = hub.transports[0]

        // Park the writer inside send(frame 1) so frames 2 and 3 stay queued.
        await first.setGateSends(true)
        let r1 = Task { _ = try? await client.request("stale.one", timeout: 5) }
        let r2 = Task { _ = try? await client.request("stale.two", timeout: 5) }
        let r3 = Task { _ = try? await client.request("stale.three", timeout: 5) }
        let writerParked = await waitUntil { await first.gatedSendCount == 1 }
        XCTAssertTrue(writerParked, "the writer never reached the gated send")

        // The socket goes away with frames still queued.
        await client.disconnect()
        await first.releaseGatedSend()
        _ = await r1.value; _ = await r2.value; _ = await r3.value

        // Reconnect and send something new.
        try await client.connect()
        XCTAssertEqual(hub.transports.count, 2)
        let second = hub.transports[1]
        let r4 = Task { _ = try? await client.request("fresh.four", timeout: 2) }
        let freshArrived = await waitUntil { await second.sentLines.isEmpty == false }
        XCTAssertTrue(freshArrived, "the fresh request never reached the new socket")
        try? await Task.sleep(nanoseconds: 300_000_000)

        let lines = await second.sentLines
        XCTAssertFalse(
            lines.contains { $0.contains("stale.") },
            "stale outbox frames were replayed onto the next socket: \(lines)"
        )
        XCTAssertEqual(lines.count, 1, "exactly the fresh frame should have gone out")
        r4.cancel()
        await client.disconnect()
    }
}
