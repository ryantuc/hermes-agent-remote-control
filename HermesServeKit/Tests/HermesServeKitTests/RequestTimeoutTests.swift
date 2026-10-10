import XCTest

@testable import HermesServeKit

/// BUG-098 — `HermesClient`'s request-timeout machine had no tests: every harness answered every
/// request at once, so no suite ever let a reply NOT arrive. This transport answers only what it is
/// told to and can deliver a withheld reply late, which exercises the three branches that matter:
/// the deadline firing (`expire(id:)`), a reply cancelling the deadline (`handle(frame:)`'s
/// `timeoutTask?.cancel()`), and a reply arriving after its call already timed out (dropped, never
/// a second resume of the same continuation, which would trap).
final class RequestTimeoutTests: XCTestCase {
    private actor Transport: GatewayTransport {
        private let onFrame: WebSocketTransport.FrameHandler
        private let onState: WebSocketTransport.StateHandler
        private(set) var state: ConnectionState = .idle
        private(set) var lastCloseCode = 0
        private(set) var disconnects = 0
        private(set) var sent: [JSONValue] = []
        private var answered: Set<String> = []

        init(onFrame: @escaping WebSocketTransport.FrameHandler, onState: @escaping WebSocketTransport.StateHandler) {
            self.onFrame = onFrame
            self.onState = onState
        }

        func connect(url: URL) async throws {
            state = .open
            await onState(.open, 0)
            await onFrame(.event(GatewayEvent(type: "gateway.ready", sessionID: "", payload: .object([:]), params: .null)))
        }

        func disconnect() async {
            disconnects += 1
            state = .closed
            await onState(.closed, 0)
        }

        func send(line: String) async throws {
            let wire = try JSONDecoder().decode(JSONValue.self, from: Data(line.utf8))
            sent.append(wire)
            guard let method = wire["method"]?.stringValue, let id = wire["id"], answered.contains(method) else { return }
            let reply = JSONRPCFrame.response(JSONRPCResponse(id: id, result: .object(["answered": .string(method)]), error: nil))
            Task { await self.onFrame(reply) }
        }

        /// Answer `method` immediately from now on.
        func answer(_ method: String) { answered.insert(method) }

        /// The id the client put on the most recent request for `method`.
        func id(of method: String) -> JSONValue? {
            sent.last { $0["method"]?.stringValue == method }?["id"]
        }

        /// Deliver a reply the transport withheld.
        func deliver(to method: String, result: JSONValue) async {
            guard let id = id(of: method) else { return }
            await onFrame(.response(JSONRPCResponse(id: id, result: result, error: nil)))
        }
    }

    private final class Hub: @unchecked Sendable {
        private let lock = NSLock()
        private var created: [Transport] = []

        func make(_ onFrame: @escaping WebSocketTransport.FrameHandler, _ onState: @escaping WebSocketTransport.StateHandler) -> Transport {
            let transport = Transport(onFrame: onFrame, onState: onState)
            lock.lock(); created.append(transport); lock.unlock()
            return transport
        }

        var transports: [Transport] {
            lock.lock(); defer { lock.unlock() }
            return created
        }
    }

    /// Completion as seen from outside a request task.
    private actor Outcome {
        private(set) var finished = false
        func finish() { finished = true }
    }

    private func connectedClient() async throws -> (HermesClient, Transport) {
        let hub = Hub()
        let client = HermesClient(
            dialer: GatewayDialer(
                getStatus: {
                    ServerStatus(json: .object([
                        "version": .string("test"), "auth_required": .bool(false), "gateway_running": .bool(true),
                    ]))
                },
                webSocketURL: { _ in URL(string: "ws://example.invalid/ws")! }
            ),
            log: nil,
            transportFactory: { hub.make($0, $1) }
        )
        try await client.connect()
        return (client, hub.transports[0])
    }

    private func waitUntil(timeout: TimeInterval = 5, _ predicate: () async -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await predicate() { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return await predicate()
    }

    func testARequestNobodyAnswersFailsWithItsOwnTimeout() async throws {
        let (client, _) = try await connectedClient()
        let started = Date()
        do {
            _ = try await client.request("session.usage", params: .object(["session_id": .string("s")]), timeout: 0.3)
            XCTFail("an unanswered request must not hang")
        } catch let error as HermesError {
            XCTAssertEqual(error, .requestTimedOut(method: "session.usage", seconds: 0))
        }
        let elapsed = Date().timeIntervalSince(started)
        XCTAssertGreaterThanOrEqual(elapsed, 0.25, "it waited for its deadline")
        XCTAssertLessThan(elapsed, 5)
        await client.disconnect()
    }

    /// The error names the deadline it missed, in whole seconds.
    func testTheTimeoutErrorReportsTheDeadlineInWholeSeconds() async throws {
        let (client, _) = try await connectedClient()
        do {
            _ = try await client.request("config.get", timeout: 1.2)
            XCTFail("an unanswered request must not hang")
        } catch let error as HermesError {
            XCTAssertEqual(error, .requestTimedOut(method: "config.get", seconds: 1))
        }
        await client.disconnect()
    }

    func testAReplyAfterTheTimeoutIsDroppedAndTheClientStaysUsable() async throws {
        let (client, transport) = try await connectedClient()
        do {
            _ = try await client.request("session.title", timeout: 0.2)
            XCTFail("an unanswered request must not hang")
        } catch let error as HermesError {
            XCTAssertEqual(error, .requestTimedOut(method: "session.title", seconds: 0))
        }

        // The withheld reply finally arrives for a call that no longer exists.
        await transport.deliver(to: "session.title", result: .object(["title": .string("late")]))

        let state = await client.state
        XCTAssertEqual(state, .open, "a timeout is not a disconnect")
        let disconnects = await transport.disconnects
        XCTAssertEqual(disconnects, 0)
        await transport.answer("ping")
        let result = try await client.request("ping", timeout: 2)
        XCTAssertEqual(result["answered"], .string("ping"))
        await client.disconnect()
    }

    func testAReplyBeforeTheDeadlineWinsAndTheDeadlineStaysQuiet() async throws {
        let (client, transport) = try await connectedClient()
        let request = Task { try await client.request("session.usage", timeout: 0.4) }
        let sent = await waitUntil { await transport.id(of: "session.usage") != nil }
        XCTAssertTrue(sent)

        await transport.deliver(to: "session.usage", result: .object(["tokens": .number(42)]))
        let result = try await request.value
        XCTAssertEqual(result["tokens"], .number(42))

        // Past the deadline: a timer left armed would fire into a call that already finished.
        try await Task.sleep(nanoseconds: 700_000_000)
        let state = await client.state
        XCTAssertEqual(state, .open)
        await transport.answer("ping")
        let after = try await client.request("ping", timeout: 2)
        XCTAssertEqual(after["answered"], .string("ping"))
        await client.disconnect()
    }

    /// Each deadline belongs to its own call: one expiring neither fails nor answers another, and a
    /// late reply to the expired one cannot land on the one still waiting.
    func testEachDeadlineBelongsToItsOwnRequest() async throws {
        let (client, transport) = try await connectedClient()
        let quick = Task { try await client.request("slow.quick", timeout: 0.2) }
        let patient = Task { try await client.request("slow.patient", timeout: 5) }
        let bothSent = await waitUntil {
            let quickID = await transport.id(of: "slow.quick")
            let patientID = await transport.id(of: "slow.patient")
            return quickID != nil && patientID != nil
        }
        XCTAssertTrue(bothSent)

        let quickOutcome = await quick.result
        guard case .failure(let error) = quickOutcome, let hermes = error as? HermesError else {
            return XCTFail("the quick call must time out")
        }
        XCTAssertEqual(hermes, .requestTimedOut(method: "slow.quick", seconds: 0))

        await transport.deliver(to: "slow.quick", result: .object(["who": .string("quick")]))
        await transport.deliver(to: "slow.patient", result: .object(["who": .string("patient")]))
        let answer = try await patient.value
        XCTAssertEqual(answer["who"], .string("patient"))
        await client.disconnect()
    }

    /// A zero timeout arms no deadline at all; the call waits for its reply however long it takes.
    func testAZeroTimeoutMeansNoDeadline() async throws {
        let (client, transport) = try await connectedClient()
        let outcome = Outcome()
        let request = Task { () -> JSONValue in
            let value = try await client.request("session.compress", timeout: 0)
            await outcome.finish()
            return value
        }
        let sent = await waitUntil { await transport.id(of: "session.compress") != nil }
        XCTAssertTrue(sent)
        // Without its frame on the wire there is no reply to deliver, and a call with no deadline
        // would wait forever; stop here rather than hang the suite.
        guard sent else { return }
        try await Task.sleep(nanoseconds: 400_000_000)
        let early = await outcome.finished
        XCTAssertFalse(early, "nothing may end a call with no deadline before its reply")

        await transport.deliver(to: "session.compress", result: .object(["done": .bool(true)]))
        let result = try await request.value
        XCTAssertEqual(result["done"], .bool(true))
        await client.disconnect()
    }

    /// A disconnect fails every call still waiting, deadline or not, rather than leaving it to time out.
    func testADisconnectFailsAWaitingCallImmediately() async throws {
        let (client, transport) = try await connectedClient()
        let request = Task { try await client.request("session.usage", timeout: 30) }
        let sent = await waitUntil { await transport.id(of: "session.usage") != nil }
        XCTAssertTrue(sent)
        let started = Date()
        await client.disconnect()
        let outcome = await request.result
        guard case .failure(let error) = outcome, let hermes = error as? HermesError else {
            return XCTFail("a disconnect must fail the waiting call")
        }
        XCTAssertEqual(hermes, .connectionClosed("The gateway connection closed."))
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
    }

    /// The default deadlines (reference-clients.md §1.9): the submit ack gets the backend's own turn
    /// ceiling, session listing and resume get a minute, everything else thirty seconds.
    func testTheDefaultDeadlines() {
        XCTAssertEqual(HermesClient.defaultTimeout(for: "prompt.submit"), 1800)
        for method in ["session.list", "session.resume", "session.activate", "session.active_list",
                       "session.branch", "session.compress"] {
            XCTAssertEqual(HermesClient.defaultTimeout(for: method), 60, method)
        }
        for method in ["session.create", "session.interrupt", "config.get", "approval.respond"] {
            XCTAssertEqual(HermesClient.defaultTimeout(for: method), 30, method)
        }
    }
}
