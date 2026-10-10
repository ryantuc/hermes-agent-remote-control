import XCTest
@testable import HermesServeKit

final class SharedSessionObserverTests: XCTestCase {
    private func input(_ id: String = "i", _ ref: String = "ref") -> JSONValue {
        .object(["id": .string(id), "ref": .string(ref)])
    }
    private func event(_ type: String = "message.start", execution: String = "run", socket: String = "socket", payload: [String: JSONValue] = [:]) -> GatewayEvent {
        var body: [String: JSONValue] = ["input": .object(["role": .string("user"), "text": .string("hello")]),
            "inputs": .array([input()]), "inputs_complete": .bool(true)]
        body.merge(payload) { _, next in next }
        return GatewayEvent(type: type, sessionID: "s", payload: .object(body), params: .object([
            "type": .string(type), "session_id": .string("s"), "payload": .object(body),
            "turn": .object(["id": .string(execution), "source": .object(["kind": .string("connection"), "socket_id": .string(socket)])])
        ]))
    }
    private func engine() -> TurnEngine {
        let engine = TurnEngine()
        engine.setReplayEpoch("epoch")
        engine.setSharedSession(.object(["version": .number(1), "socket_id": .string("socket")]))
        return engine
    }
    func testStartBeforeOrAfterReplyReconcilesOptimisticOccurrence() {
        for replyFirst in [true, false] {
            let engine = engine()
            let id = engine.appendUserEntry(sessionID: "s", text: "hello")
            engine.registerSubmission(sessionID: "s", ref: "ref", entryID: id)
            let ack = PromptAck(json: .object(["status": .string("streaming"), "submission": .object([
                "input_id": .string("i"), "ref": .string("ref"), "disposition": .string("executing")])]))
            if replyFirst { engine.acknowledgeSubmission(sessionID: "s", ack: ack) }
            engine.apply(event())
            if !replyFirst { engine.acknowledgeSubmission(sessionID: "s", ack: ack) }
            engine.apply(event())
            XCTAssertEqual(engine.state(for: "s").entries.filter { $0.kind == .user }.map(\.text), ["hello"])
            XCTAssertEqual(engine.state(for: "s").turnOwnership, .local)
        }
    }
    func testSocketInequalityDoesNotClaimAnotherClient() {
        let engine = engine()
        engine.apply(event(socket: "old-socket"))
        XCTAssertEqual(engine.state(for: "s").turnOwnership, .unknown)
        XCTAssertFalse(engine.state(for: "s").turnStartedLocally)
    }
    func testReferenceSurvivesSocketChangeButIsNotIdempotency() {
        let engine = engine()
        let id = engine.appendUserEntry(sessionID: "s", text: "hello")
        engine.registerSubmission(sessionID: "s", ref: "ref", entryID: id)
        engine.apply(event(socket: "old-socket"))
        XCTAssertEqual(engine.state(for: "s").turnOwnership, .local)
        engine.apply(event("message.input", payload: ["inputs": .array([input("second")])]))
        XCTAssertEqual(engine.state(for: "s").entries.filter { $0.kind == .user }.count, 2)
        engine.apply(event("message.input", payload: ["inputs": .array([input("second")])]))
        XCTAssertEqual(engine.state(for: "s").entries.filter { $0.kind == .user }.count, 2)
    }
    func testHiddenProjectionAndStaleExecutionDoNotPaint() {
        let engine = engine()
        engine.apply(event(payload: ["input": .null]))
        engine.apply(event("message.delta", execution: "stale", payload: ["text": .string("stale")]))
        engine.flush()
        XCTAssertTrue(engine.state(for: "s").entries.isEmpty)
    }
    func testMergedInputsCollapseOnlyNamedOptimisticRows() {
        let engine = engine()
        for ref in ["one", "two"] {
            let id = engine.appendUserEntry(sessionID: "s", text: ref)
            engine.registerSubmission(sessionID: "s", ref: ref, entryID: id)
        }
        engine.apply(event(payload: ["inputs": .array([input("i1", "one"), input("i2", "two")])]))
        XCTAssertEqual(engine.state(for: "s").entries.filter { $0.kind == .user }.map(\.text), ["hello"])
    }
    func testAbsenceDoesNotCancelAndEpochResetsRevisions() {
        let engine = engine()
        let id = engine.appendUserEntry(sessionID: "s", text: "hello")
        engine.registerSubmission(sessionID: "s", ref: "ref", entryID: id)
        engine.apply(event())
        func stateEvent(_ revision: Int, outcomes: [JSONValue]) -> GatewayEvent {
            event("session.info", payload: ["submission_state": .object([
                "revision": .number(Double(revision)), "queued": .array([]), "queued_complete": .bool(false),
                "outcomes": .array(outcomes)])])
        }
        engine.apply(stateEvent(10, outcomes: []))
        XCTAssertEqual(engine.state(for: "s").submissionDispositions["ref"], "executing")
        let cancelled: JSONValue = .object(["input": input(), "disposition": .string("cancelled")])
        engine.apply(stateEvent(9, outcomes: [cancelled]))
        XCTAssertEqual(engine.state(for: "s").entries.first?.noticeKind, "")
        engine.apply(stateEvent(11, outcomes: [cancelled]))
        XCTAssertEqual(engine.state(for: "s").entries.first?.noticeKind, "cancelled")
        engine.setReplayEpoch("restarted")
        XCTAssertEqual(engine.state(for: "s").submissionRevision, -1)
        XCTAssertTrue(engine.state(for: "s").submissionDispositions.isEmpty)
        XCTAssertNil(engine.state(for: "s").executionID)
    }
    func testFailedReplayKeepsEventsReceivedWhileWaiting() {
        let engine = engine()
        var start = event()
        start = GatewayEvent(type: start.type, sessionID: "s", payload: start.payload,
                             params: .object(["seq": .number(1)]))
        engine.apply(start)
        XCTAssertEqual(engine.beginEventRecovery(sessionID: "s"), 1)
        engine.apply(GatewayEvent(type: "message.delta", sessionID: "s", payload: .object(["text": .string("received")]), params: .object(["seq": .number(3)])))
        XCTAssertFalse(engine.finishEventRecovery(sessionID: "s", replay: nil))
        XCTAssertEqual(engine.state(for: "s").entries.last?.text, "received")
        XCTAssertNil(engine.beginEventRecovery(sessionID: "s"), "a gap must require a snapshot")
    }
}

