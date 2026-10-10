import XCTest

@testable import HermesServeKit

/// The `manage_connections` card. The backend opens it with a session-scoped `connection.request` EVENT (`tui_gateway/agent_callbacks.py:176`; payload `ConnectionRequestPayload`, `tui_gateway/contracts/connectors_operation.py:140-156`), moves it with `connection.update` (`:171-183`; emitter `tui_gateway/methods_connectors.py:398-426`) and restores it on resume as `pending_connection` (`tui_gateway/contracts/sessions.py:106-108`, `server.py:3144-3148`). The agent's tool blocks until the operation settles or its 300 s deadline passes, and the client ignored every one of these frames, so a phone-driven turn showed "Working" for up to five minutes with nothing to answer.
final class ConnectionRequestTests: XCTestCase {
    private let session = "a1b2c3d4"

    private func event(_ type: String, session sid: String? = nil, payload: JSONValue) -> GatewayEvent {
        let sid = sid ?? session
        return GatewayEvent(type: type, sessionID: sid, payload: payload, params: .object([
            "type": .string(type), "session_id": .string(sid), "payload": payload,
        ]))
    }

    private func target(_ name: String, state: String, url: String? = nil, kind: String = "connector") -> JSONValue {
        var row: [String: JSONValue] = [
            "name": .string(name), "kind": .string(kind), "action": .string("connect"), "state": .string(state),
        ]
        if let url { row["connect_url"] = .string(url) }
        return .object(row)
    }

    /// `ConnectionOperation.request_payload` (`tools/connectors/operation.py:240-252`).
    private func requestPayload(op: String = "op-1", seq: Int? = 1, targets: [JSONValue]) -> JSONValue {
        var payload: [String: JSONValue] = [
            "op_id": .string(op), "deadline_at": .number(1_900_000_000), "timeout_seconds": .number(300),
            "targets": .array(targets), "tool_call_id": .string("call_9"),
        ]
        if let seq { payload["seq"] = .number(Double(seq)) }
        return .object(payload)
    }

    /// `methods_connectors._connection_update` (`:398-426`): the full snapshot plus `settled` and the owner.
    private func updatePayload(op: String = "op-1", seq: Int? = 2, settled: Bool = false,
                               targets: [JSONValue], owner: JSONValue? = nil) -> JSONValue {
        var payload: [String: JSONValue] = [
            "op_id": .string(op), "deadline_at": .number(1_900_000_000), "targets": .array(targets),
            "settled": .bool(settled), "settled_at": settled ? .number(1_899_999_999) : .null,
            "settled_by": settled ? .string("continue") : .null,
        ]
        if let seq { payload["seq"] = .number(Double(seq)) }
        payload["owner"] = owner ?? .object(["type": .string("session"), "session_id": .string(session)])
        return .object(payload)
    }

    private func openCard(_ engine: TurnEngine, seq: Int? = 1) {
        engine.apply(event("message.start", payload: .object([:])))
        engine.apply(event("connection.request", payload: requestPayload(seq: seq, targets: [
            target("github", state: "pending", url: "https://connect.example.com/github?state=abc"),
            target("linear", state: "pending"),
        ])))
    }

    // MARK: Opening

    func testARequestOpensTheCardOnItsSession() throws {
        let engine = TurnEngine()
        openCard(engine)

        let card = try XCTUnwrap(engine.state(for: session).connection, "the card the agent is blocked on never opened")
        XCTAssertEqual(card.opID, "op-1")
        XCTAssertEqual(card.sessionID, session)
        XCTAssertEqual(card.targets.map(\.name), ["github", "linear"])
        XCTAssertEqual(card.targets.first?.connectURL?.absoluteString, "https://connect.example.com/github?state=abc")
        XCTAssertTrue(card.targets[0].canOpen)
        XCTAssertFalse(card.targets[1].canOpen, "a row with no link has nothing to open")
        XCTAssertEqual(card.unresolvedTargets.count, 2)
        XCTAssertFalse(engine.isQuiescent(sessionID: session), "a session waiting on the person must not be swept")
    }

    /// The card is answered in the chat, never by the approval sheet, so it must not claim the blocking-prompt slot.
    func testTheCardIsNotABlockingPrompt() {
        let engine = TurnEngine()
        openCard(engine)
        XCTAssertNotNil(engine.state(for: session).connection)
        XCTAssertFalse(engine.state(for: session).hasBlockingPrompt)
    }

    /// Desktop's link rule (`apps/desktop/src/lib/connector-tools.ts:180-195`): HTTPS only, no embedded credentials.
    func testOnlyASafeLinkIsOffered() {
        XCTAssertNil(ConnectionTarget(json: target("a", state: "pending", url: "http://connect.example.com/x")).connectURL)
        XCTAssertNil(ConnectionTarget(json: target("b", state: "pending", url: "https://user:pw@connect.example.com/x")).connectURL)
        XCTAssertNil(ConnectionTarget(json: target("c", state: "pending", url: "javascript:alert(1)")).connectURL)
        XCTAssertNotNil(ConnectionTarget(json: target("d", state: "pending", url: "https://connect.example.com/x")).connectURL)
    }

    /// Skip has an edge only from these states (`tools/connectors/contract.py:45-54`); anything else answers 4002.
    func testSkipIsOfferedOnlyWhereTheBackendAllowsIt() {
        for state in ["pending", "initiated", "failed", "expired"] {
            XCTAssertTrue(ConnectionTarget(json: target("x", state: state)).canSkip, state)
        }
        for state in ["connected", "skipped", "not_connected"] {
            XCTAssertFalse(ConnectionTarget(json: target("x", state: state)).canSkip, state)
        }
    }

    // MARK: Updates

    func testAnUpdateMovesTheRowsAndAnOlderFrameDoesNot() throws {
        let engine = TurnEngine()
        openCard(engine)

        engine.apply(event("connection.update", payload: updatePayload(seq: 3, targets: [
            target("github", state: "connected"), target("linear", state: "pending"),
        ])))
        XCTAssertEqual(engine.state(for: session).connection?.targets.first?.state, "connected")

        // A frame whose seq is not higher than the one held is older and moves no row (`connectors_operation.py:145-147`).
        engine.apply(event("connection.update", payload: updatePayload(seq: 2, targets: [
            target("github", state: "initiated"), target("linear", state: "pending"),
        ])))
        let card = try XCTUnwrap(engine.state(for: session).connection)
        XCTAssertEqual(card.targets.first?.state, "connected", "an older frame rolled a row back")
        XCTAssertEqual(card.seq, 3)
        XCTAssertEqual(card.unresolvedTargets.map(\.name), ["linear"])
    }

    func testSettlementClosesTheCard() {
        let engine = TurnEngine()
        openCard(engine)

        engine.apply(event("connection.update", payload: updatePayload(seq: 4, settled: true, targets: [
            target("github", state: "connected"), target("linear", state: "skipped"),
        ])))

        XCTAssertNil(engine.state(for: session).connection, "a settled operation has nothing left to answer")
    }

    func testAnUpdateForAnotherOperationLeavesTheCardAlone() {
        let engine = TurnEngine()
        openCard(engine)

        engine.apply(event("connection.update", payload: updatePayload(op: "op-other", seq: 9, settled: true,
                                                                       targets: [target("slack", state: "skipped")])))

        XCTAssertEqual(engine.state(for: session).connection?.opID, "op-1")
    }

    /// An older backend predates `seq` and `owner`; every frame there is taken as the newer one.
    func testAnOlderBackendWithoutSeqStillMovesTheCard() {
        let engine = TurnEngine()
        openCard(engine, seq: nil)

        var payload = updatePayload(seq: nil, targets: [target("github", state: "connected"), target("linear", state: "pending")])
        if case .object(var object) = payload { object["owner"] = nil; payload = .object(object) }
        engine.apply(event("connection.update", payload: payload))

        XCTAssertEqual(engine.state(for: session).connection?.targets.first?.state, "connected")
    }

    /// Settings → Connectors operations are broadcast to everyone with an account owner and no session (`methods_connectors.py:403-412`).
    func testAnAccountOperationNeverReachesAChat() {
        let engine = TurnEngine()
        let routed = engine.apply(event("connection.update", session: "", payload: updatePayload(
            seq: 1, targets: [target("github", state: "initiated")], owner: .object(["type": .string("account")]))))

        XCTAssertNil(routed)
        XCTAssertTrue(engine.trackedSessionIDs.isEmpty, "an account frame minted state for a session")
    }

    // MARK: Closing with the turn

    func testTheTurnEndClosesTheCard() {
        let engine = TurnEngine()
        openCard(engine)
        engine.apply(event("message.complete", payload: .object(["text": .string("done"), "status": .string("complete")])))
        XCTAssertNil(engine.state(for: session).connection)
    }

    func testAStopClosesTheCardAndItsLateRequestStaysClosed() {
        let engine = TurnEngine()
        openCard(engine)
        engine.markInterrupted(sessionID: session)
        XCTAssertNil(engine.state(for: session).connection, "a Stop leaves no turn to consent for")

        // The cancelled turn's own late request must not re-open a card under the latch (Desktop drops it the same way, `input-requests.ts:55-60`).
        engine.apply(event("connection.request", payload: requestPayload(op: "op-2", targets: [target("github", state: "pending")])))
        XCTAssertNil(engine.state(for: session).connection)
    }

    // MARK: Resume

    func testAResumeRestoresTheCardFromThePendingSnapshot() throws {
        let engine = TurnEngine()
        let result = SessionAPI.decodeResume(.object([
            "session_id": .string(session), "running": .bool(true),
            "pending_connection": requestPayload(op: "op-7", seq: 5, targets: [target("github", state: "initiated")]),
        ]), requested: "20261002_120000_abcdef")
        XCTAssertEqual(result.pendingConnection?.opID, "op-7")

        engine.applyResumeProjection(sessionID: session, result: result, trailingUserTexts: [])

        let card = try XCTUnwrap(engine.state(for: session).connection, "a reopened chat lost the card the agent is still blocked on")
        XCTAssertEqual(card.opID, "op-7")
        XCTAssertEqual(card.seq, 5)
    }

    func testAResumeWithNothingPendingOpensNothing() {
        let result = SessionAPI.decodeResume(.object(["session_id": .string(session), "running": .bool(true)]),
                                             requested: "stored")
        XCTAssertNil(result.pendingConnection)
        let malformed = SessionAPI.decodeResume(.object([
            "session_id": .string(session), "pending_connection": .object(["targets": .array([])]),
        ]), requested: "stored")
        XCTAssertNil(malformed.pendingConnection, "a snapshot with no op_id names nothing a card could answer")
    }
}
