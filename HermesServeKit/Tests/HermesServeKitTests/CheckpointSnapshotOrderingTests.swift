import XCTest
@testable import HermesServeKit

final class CheckpointSnapshotOrderingTests: XCTestCase {
    private func event(_ type: String, _ seq: Int, payload: JSONValue = .object([:]), execution: String? = nil) -> GatewayEvent {
        var params: [String: JSONValue] = ["session_id": .string("s"), "type": .string(type), "seq": .number(Double(seq)), "payload": payload]
        if let execution { params["turn"] = .object(["id": .string(execution)]) }
        return GatewayEvent(type: type, sessionID: "s", payload: payload, params: .object(params))
    }

    private func replay(_ events: [GatewayEvent], latest: Int) throws -> SessionEventReplay {
        try XCTUnwrap(SessionEventReplay(json: .object(["epoch": .string("e"), "truncated": .bool(false), "latest_seq": .number(Double(latest)), "events": .array(events.map(\.params))])))
    }

    private func makePrevious(execution: String? = "old") -> TurnEngine {
        let engine = TurnEngine()
        engine.setReplayEpoch("e")
        engine.apply(event("message.start", 1, execution: execution))
        engine.apply(event("message.delta", 2, payload: .object(["text": .string("Saved")]), execution: execution))
        return engine
    }

    private func resume(_ fields: [String: JSONValue] = [:]) -> SessionResumeResult {
        var values: [String: JSONValue] = ["session_id": .string("s"), "running": .bool(true), "info": .object(["title": .string("Old title")]), "inflight": .object(["user": .string("Question"), "assistant": .string("Saved"), "streaming": .bool(true), "turn": .object(["id": .string("old")])])]
        values.merge(fields) { _, new in new }
        return SessionAPI.decodeResume(.object(values), requested: "stored")
    }

    private func recovered(_ checkpoint: TurnCheckpoint, events: [GatewayEvent], result: SessionResumeResult) throws -> TurnEngine {
        let engine = TurnEngine()
        engine.setReplayEpoch("e")
        XCTAssertTrue(engine.beginCheckpointRecovery(checkpoint))
        let latest = events.compactMap { $0.params["seq"]?.coercedInt }.max() ?? checkpoint.sequence
        XCTAssertTrue(engine.finishEventRecovery(sessionID: "s", replay: try replay(events, latest: latest), checkpoint: checkpoint, resumeSnapshot: result))
        return engine
    }

    func testOldApprovalDoesNotSurviveReplayedCompletionAndNewExecution() throws {
        let checkpoint = try XCTUnwrap(makePrevious().checkpoint(sessionID: "s"))
        let engine = try recovered(checkpoint, events: [
            event("message.complete", 3, payload: .object(["text": .string("Saved")]), execution: "old"),
            event("message.start", 4, execution: "new"),
            event("message.delta", 5, payload: .object(["text": .string("New")]), execution: "new")
        ], result: resume(["pending_approval": .object(["command": .string("synthetic old approval")]), "turn_started_at": .number(10)]))
        XCTAssertEqual(engine.state(for: "s").executionID, "new")
        XCTAssertTrue(engine.state(for: "s").isBusy)
        XCTAssertTrue(engine.state(for: "s").pendingApprovals.isEmpty)
        XCTAssertFalse(engine.state(for: "s").needsInput)
        XCTAssertNil(engine.state(for: "s").turnStartedAt)
    }

    func testLegacyTurnBoundaryRejectsOldPromptWithoutExecutionIDs() throws {
        let checkpoint = try XCTUnwrap(makePrevious(execution: nil).checkpoint(sessionID: "s"))
        let engine = try recovered(checkpoint, events: [event("message.complete", 3), event("message.start", 4)], result: resume(["inflight": .null, "pending_approval": .object(["command": .string("old")])]))
        XCTAssertTrue(engine.state(for: "s").isBusy)
        XCTAssertTrue(engine.state(for: "s").pendingApprovals.isEmpty)
    }

    func testCurrentApprovalInReplayAndSnapshotIsPresentedOnce() throws {
        let checkpoint = try XCTUnwrap(makePrevious().checkpoint(sessionID: "s"))
        let payload: JSONValue = .object(["command": .string("same command")])
        let engine = try recovered(checkpoint, events: [event("approval.request", 3, payload: payload, execution: "old")], result: resume(["pending_approval": payload]))
        XCTAssertEqual(engine.state(for: "s").pendingApprovals.count, 1)
        XCTAssertTrue(engine.state(for: "s").needsInput)
    }

    func testPendingApprovalRaisedBeforeCheckpointComesFromSnapshot() throws {
        let previous = makePrevious()
        previous.apply(event("approval.request", 3, payload: .object(["command": .string("waiting")]), execution: "old"))
        let checkpoint = try XCTUnwrap(previous.checkpoint(sessionID: "s"))
        let engine = try recovered(checkpoint, events: [], result: resume(["pending_approval": .object(["command": .string("waiting")])]))
        XCTAssertEqual(engine.state(for: "s").pendingApprovals.map(\.command), ["waiting"])
    }

    func testNewPromptInReplaySurvivesOldSnapshotAcrossBoundary() throws {
        let checkpoint = try XCTUnwrap(makePrevious().checkpoint(sessionID: "s"))
        let engine = try recovered(checkpoint, events: [event("message.complete", 3, execution: "old"), event("message.start", 4, execution: "new"), event("approval.request", 5, payload: .object(["command": .string("current")]), execution: "new")], result: resume(["pending_approval": .object(["command": .string("old")])]))
        XCTAssertEqual(engine.state(for: "s").pendingApprovals.map(\.command), ["current"])
    }

    func testReplayedSessionInfoOutranksSnapshotAndDoesNotSuppressCurrentPrompt() throws {
        let checkpoint = try XCTUnwrap(makePrevious().checkpoint(sessionID: "s"))
        let engine = try recovered(checkpoint, events: [event("session.info", 3, payload: .object(["title": .string("Fresh title")]), execution: "old")], result: resume(["pending_approval": .object(["command": .string("waiting")])]))
        XCTAssertEqual(engine.state(for: "s").info?.title, "Fresh title")
        XCTAssertEqual(engine.state(for: "s").title, "Fresh title")
        XCTAssertEqual(engine.state(for: "s").pendingApprovals.count, 1)
    }

    private func submissionState(revision: Int, disposition: String) -> JSONValue {
        .object(["revision": .number(Double(revision)), "queued_complete": .bool(true), "queued": .array([]), "outcomes": .array([.object(["input": .object(["id": .string("input"), "ref": .string("ref")]), "disposition": .string(disposition)])])])
    }

    func testSnapshotOutcomeReachesEntryBoundDuringReplay() throws {
        let previous = makePrevious()
        let entry = previous.appendUserEntry(sessionID: "s", text: "Correction", joiningRunningTurn: true)
        previous.registerSubmission(sessionID: "s", ref: "ref", entryID: entry)
        let checkpoint = try XCTUnwrap(previous.checkpoint(sessionID: "s"))
        let input: JSONValue = .object(["input": .object(["role": .string("user"), "text": .string("Correction")]), "inputs": .array([.object(["id": .string("input"), "ref": .string("ref")])])])
        let engine = try recovered(checkpoint, events: [event("message.input", 3, payload: input, execution: "old")], result: resume(["submission_state": submissionState(revision: 8, disposition: "terminal")]))
        let state = engine.state(for: "s")
        XCTAssertEqual(state.entries.filter { $0.kind == .user }.map(\.id), [entry])
        XCTAssertEqual(state.entries.first { $0.id == entry }?.noticeKind, "correction")
        XCTAssertEqual(state.submissionDispositions["ref"], "terminal")
        XCTAssertEqual(state.inputOutcomes["input"], "terminal")
    }

    func testOlderSnapshotCannotRollBackNewerReplayedSubmissionState() throws {
        let checkpoint = try XCTUnwrap(makePrevious().checkpoint(sessionID: "s"))
        let engine = try recovered(checkpoint, events: [event("status.update", 3, payload: .object(["text": .string("Working"), "submission_state": submissionState(revision: 9, disposition: "terminal")]), execution: "old")], result: resume(["submission_state": submissionState(revision: 8, disposition: "unresolved")]))
        XCTAssertEqual(engine.state(for: "s").submissionRevision, 9)
        XCTAssertEqual(engine.state(for: "s").inputOutcomes["input"], "terminal")
    }
}
