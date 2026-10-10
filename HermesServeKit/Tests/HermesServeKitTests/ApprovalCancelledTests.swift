import XCTest

@testable import HermesServeKit

/// `approval.cancelled` — the backend's notice that it deny-resolved pending approvals itself, on an
/// interrupt, an orphan reap or a teardown (#106678). Live source: contract
/// `tui_gateway/contracts/events.py:418-435` (`ApprovalCancelledPayload`: `session_id`,
/// `stored_session_id`, `reason`, `cancelled_count`, `request_ids`), emitter
/// `tui_gateway/session_lifecycle.py:469-498`, sent through `_broadcast_global_event`
/// (`tui_gateway/server.py:725-741`), whose `_event_frame(event, "", payload)` leaves the envelope's
/// `session_id` EMPTY, so the session is named only inside the payload. `request_ids` omits entries
/// without an id, so `cancelled_count` can exceed it. The client ignored the event, so a card for an
/// approval the backend had already denied could stay on screen.
final class ApprovalCancelledTests: XCTestCase {
    private let session = "a1b2c3d4"
    private let elsewhere = "ffff0000"

    private func cancelled(in sessionID: String? = nil, ids: [String], count: Int? = nil) -> GatewayEvent {
        let payload: JSONValue = .object([
            "session_id": .string(sessionID ?? session),
            "stored_session_id": .string("20261002_120000_abcdef"),
            "reason": .string("interrupt"),
            "cancelled_count": .number(Double(count ?? ids.count)),
            "request_ids": .array(ids.map { .string($0) }),
        ])
        return GatewayEvent(type: "approval.cancelled", sessionID: "", payload: payload, params: .object([
            "type": .string("approval.cancelled"), "session_id": .string(""), "payload": payload,
        ]))
    }

    private func scoped(_ type: String, payload: JSONValue = .object([:])) -> GatewayEvent {
        GatewayEvent(type: type, sessionID: session, payload: payload, params: .object([
            "type": .string(type), "session_id": .string(session), "payload": payload,
        ]))
    }

    private func legacyApproval(id: String?, command: String) -> GatewayEvent {
        var payload: [String: JSONValue] = ["command": .string(command), "description": .string("synthetic")]
        if let id { payload["request_id"] = .string(id) }
        return scoped("approval.request", payload: .object(payload))
    }

    // MARK: The engine (approvals held in turn state)

    func testACancelledApprovalLeavesTheQueue() {
        let engine = TurnEngine()
        engine.apply(scoped("message.start"))
        engine.apply(legacyApproval(id: "aaa", command: "rm -rf build"))
        engine.apply(legacyApproval(id: "bbb", command: "git push --force"))
        XCTAssertEqual(engine.state(for: session).pendingApprovals.count, 2)

        let routed = engine.apply(cancelled(ids: ["aaa"]))

        XCTAssertEqual(routed, session, "the payload's session_id routes the broadcast")
        XCTAssertEqual(engine.state(for: session).pendingApprovals.map(\.command), ["git push --force"])
        XCTAssertTrue(engine.state(for: session).needsInput)

        engine.apply(cancelled(ids: ["bbb"]))
        XCTAssertTrue(engine.state(for: session).pendingApprovals.isEmpty)
        XCTAssertFalse(engine.state(for: session).needsInput)
    }

    /// The approval the resume payload replayed (BUG-066) is withdrawn the same way.
    func testAHydratedApprovalIsWithdrawnToo() {
        let engine = TurnEngine()
        let result = SessionAPI.decodeResume(.object([
            "session_id": .string(session), "running": .bool(true),
            "pending_approval": .object(["command": .string("rm -rf build"), "request_id": .string("aaa")]),
        ]), requested: "stored")
        engine.applyResumeProjection(sessionID: session, result: result, trailingUserTexts: [])
        XCTAssertEqual(engine.state(for: session).pendingApprovals.count, 1)

        engine.apply(cancelled(ids: ["aaa"]))

        XCTAssertTrue(engine.state(for: session).pendingApprovals.isEmpty)
        XCTAssertFalse(engine.state(for: session).needsInput)
    }

    /// Entries without an id are counted, not named: they go oldest first, and only as many as the
    /// count says.
    func testUnnamedEntriesAreCountedOffTheFrontOfTheQueue() {
        let engine = TurnEngine()
        engine.apply(scoped("message.start"))
        engine.apply(legacyApproval(id: nil, command: "first"))
        engine.apply(legacyApproval(id: nil, command: "second"))
        engine.apply(legacyApproval(id: "ccc", command: "named"))

        engine.apply(cancelled(ids: ["ccc"], count: 2))

        XCTAssertEqual(engine.state(for: session).pendingApprovals.map(\.command), ["second"])
    }

    func testAnotherSessionsCancellationTouchesNothingHere() {
        let engine = TurnEngine()
        engine.apply(scoped("message.start"))
        engine.apply(legacyApproval(id: "aaa", command: "rm -rf build"))

        XCTAssertNil(engine.apply(cancelled(in: elsewhere, ids: ["aaa"])))

        XCTAssertEqual(engine.state(for: session).pendingApprovals.count, 1)
    }

    /// Every client receives the broadcast; one for a session this engine never tracked must not
    /// mint state for it.
    func testACancellationForAnUntrackedSessionCreatesNoState() {
        let engine = TurnEngine()
        XCTAssertNil(engine.apply(cancelled(in: elsewhere, ids: ["aaa"])))
        XCTAssertEqual(engine.trackedSessionCount, 0)
    }

    /// Other prompts are not approvals and stay.
    func testOnlyApprovalsAreWithdrawn() {
        let engine = TurnEngine()
        engine.apply(scoped("message.start"))
        engine.apply(scoped("clarify.request", payload: .object([
            "question": .string("Which branch?"), "request_id": .string("aaa"),
        ])))
        engine.apply(cancelled(ids: ["aaa"]))
        XCTAssertNotNil(engine.state(for: session).clarify)
    }

    // MARK: The client (approvals held as current server requests)

    private actor Transport: GatewayTransport {
        private let onFrame: WebSocketTransport.FrameHandler
        private let onState: WebSocketTransport.StateHandler
        private(set) var state: ConnectionState = .idle
        private(set) var lastCloseCode = 0
        private var replies: [String: JSONValue] = [:]

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
            state = .closed
            await onState(.closed, 0)
        }

        func send(line: String) async throws {
            let wire = try JSONDecoder().decode(JSONValue.self, from: Data(line.utf8))
            guard let method = wire["method"]?.stringValue, let id = wire["id"] else { return }
            let result: JSONValue = method == "client.capabilities"
                ? .object(["server_requests": .array([.string("approval")])])
                : replies[method] ?? .object([:])
            await onFrame(.response(JSONRPCResponse(id: id, result: result, error: nil)))
        }

        func receive(_ frame: JSONRPCFrame) async { await onFrame(frame) }
        func reply(_ method: String, _ value: JSONValue) { replies[method] = value }
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
            handlesServerRequests: true,
            transportFactory: { hub.make($0, $1) }
        )
        try await client.connect()
        return (client, hub.transports[0])
    }

    /// The approval server request's params carry the queue entry's `request_id`
    /// (`tui_gateway/contracts/server_requests.py:67-81`, `ApprovalRequestParams.request_id`).
    private func approvalParams(_ requestID: String, in sessionID: String? = nil) -> JSONValue {
        .object([
            "session_id": .string(sessionID ?? session), "request_id": .string(requestID),
            "command": .string("rm -rf build \(requestID)"), "description": .string("synthetic"),
        ])
    }

    func testACancelledApprovalRequestIsRetiredFromTheRegistry() async throws {
        let (client, transport) = try await connectedClient()
        await transport.receive(.serverRequest(id: .string("rpc-1"), method: "approval", params: approvalParams("aaa")))
        await transport.receive(.serverRequest(id: .string("rpc-2"), method: "approval", params: approvalParams("bbb")))
        let before = await client.openServerRequests(sessionID: session)
        XCTAssertEqual(before.count, 2)

        await transport.receive(.event(cancelled(ids: ["aaa"])))

        let after = await client.openServerRequests(sessionID: session)
        XCTAssertEqual(after.map(\.identity.id), [.string("rpc-2")])
        await client.disconnect()
    }

    /// A later snapshot that still lists the cancelled request cannot bring it back.
    func testASnapshotCannotResurrectACancelledApproval() async throws {
        let (client, transport) = try await connectedClient()
        await transport.receive(.serverRequest(id: .string("rpc-1"), method: "approval", params: approvalParams("aaa")))
        await transport.receive(.event(cancelled(ids: ["aaa"])))
        await transport.reply("session.events.since", .object([
            "session_id": .string(session),
            "open_requests": .array([.object([
                "id": .string("rpc-1"), "method": .string("approval"), "params": approvalParams("aaa"),
            ])]),
        ]))

        _ = try await client.request("session.events.since", params: .object([
            "session_id": .string(session), "last_seen": .number(0),
        ]))

        let open = await client.openServerRequests(sessionID: session)
        XCTAssertTrue(open.isEmpty)
        await client.disconnect()
    }

    /// The registry holds every session's requests; a cancellation names one session's.
    func testARegistryCancellationIsScopedToItsSession() async throws {
        let (client, transport) = try await connectedClient()
        await transport.receive(.serverRequest(id: .string("rpc-1"), method: "approval", params: approvalParams("aaa")))
        await transport.receive(.serverRequest(id: .string("rpc-9"), method: "approval", params: approvalParams("zzz", in: elsewhere)))

        await transport.receive(.event(cancelled(in: elsewhere, ids: ["aaa", "zzz"])))

        let here = await client.openServerRequests(sessionID: session)
        let there = await client.openServerRequests(sessionID: elsewhere)
        XCTAssertEqual(here.count, 1, "a session the payload did not name keeps its request")
        XCTAssertTrue(there.isEmpty)
        await client.disconnect()
    }

    /// What the client fans out, in order, so the test can replay it into an engine on its own task.
    private actor Recorder {
        private(set) var events: [GatewayEvent] = []
        func record(_ event: GatewayEvent) { events.append(event) }
        func saw(_ type: String) -> Bool { events.contains { $0.type == type } }
    }

    private func waitUntil(timeout: TimeInterval = 5, _ predicate: () async -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await predicate() { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return await predicate()
    }

    /// End to end: the client's projection reaches the engine, and the card is gone from turn state.
    func testTheEngineLosesTheCardOnceTheClientRetiresIt() async throws {
        let (client, transport) = try await connectedClient()
        let recorder = Recorder()
        let stream = client.events()
        let pump = Task {
            for await event in stream { await recorder.record(event) }
        }
        defer { pump.cancel() }

        // The subscription registers asynchronously; prove it is live before anything that matters
        // is sent, rather than guessing how long that takes.
        var live = false
        for _ in 0..<200 where !live {
            await transport.receive(.event(GatewayEvent(type: "sessions.changed", sessionID: "", payload: .object([:]), params: .null)))
            try await Task.sleep(nanoseconds: 10_000_000)
            live = await recorder.saw("sessions.changed")
        }
        XCTAssertTrue(live, "the event subscription never went live")

        await transport.receive(.serverRequest(id: .string("rpc-1"), method: "approval", params: approvalParams("aaa")))
        await transport.receive(.event(cancelled(ids: ["aaa"])))
        let delivered = await waitUntil { await recorder.saw("approval.cancelled") }
        XCTAssertTrue(delivered)

        let engine = TurnEngine()
        engine.apply(scoped("message.start"))
        for event in await recorder.events { engine.apply(event) }
        XCTAssertTrue(engine.state(for: session).pendingApprovals.isEmpty)
        XCTAssertFalse(engine.state(for: session).needsInput)
        await client.disconnect()
    }
}
