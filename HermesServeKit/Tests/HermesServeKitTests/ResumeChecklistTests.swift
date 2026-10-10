import XCTest

@testable import HermesServeKit

/// FEAT-037 — a reopened chat showed an empty plan checklist. The backend attaches its own
/// authoritative snapshot, `todo_state: {todos, revision}`, to `session.resume` /
/// `session.activate` (`tui_gateway/tool_progress.py:150-155` `_attach_todo_state`, contract
/// `tui_gateway/contracts/sessions.py:62-66,109`), and the phone read it nowhere. The snapshot is a
/// starting value: the live `tool.complete` path keeps overwriting it, `revision` orders the two,
/// and the same turn-end rule the live path applies (an unfinished plan is dropped once the turn is
/// over) applies to the seed.
final class ResumeChecklistTests: XCTestCase {
    private let session = "a1b2c3d4"

    private func rows(_ items: [(String, String, String)]) -> JSONValue {
        .array(items.map { .object(["id": .string($0.0), "content": .string($0.1), "status": .string($0.2)]) })
    }

    private func snapshot(_ items: [(String, String, String)], revision: Int) -> JSONValue {
        .object(["todos": rows(items), "revision": .number(Double(revision))])
    }

    private var finishedPlan: [(String, String, String)] {
        [("1", "Read the failing test", "completed"), ("2", "Fix the assertion", "completed"),
         ("3", "Re-run the suite", "cancelled")]
    }

    private var activePlan: [(String, String, String)] {
        [("1", "Read the failing test", "completed"), ("2", "Fix the assertion", "in_progress")]
    }

    private func resume(running: Bool, todoState: JSONValue? = nil) -> SessionResumeResult {
        var values: [String: JSONValue] = [
            "session_id": .string(session),
            "running": .bool(running),
            "info": .object(["title": .string("Synthetic plan")]),
        ]
        if let todoState { values["todo_state"] = todoState }
        return SessionAPI.decodeResume(.object(values), requested: "stored")
    }

    private func event(_ type: String, payload: JSONValue = .object([:])) -> GatewayEvent {
        GatewayEvent(type: type, sessionID: session, payload: payload, params: .object([
            "type": .string(type), "session_id": .string(session), "payload": payload,
        ]))
    }

    /// `tool.complete` for the plan tool in the live backend's shape: `payload.update(todo_state)`
    /// puts `todos` and `revision` at the top level (`tool_progress.py:354-358`).
    private func planComplete(_ items: [(String, String, String)], revision: Int, toolID: String) -> GatewayEvent {
        event("tool.complete", payload: .object([
            "tool_id": .string(toolID), "name": .string("todo"),
            "result": .object(["todos": rows(items), "revision": .number(Double(revision))]),
            "todos": rows(items), "revision": .number(Double(revision)),
        ]))
    }

    private func contents(_ engine: TurnEngine) -> [String] {
        engine.state(for: session).activity.todos.items.map(\.content)
    }

    // MARK: The acceptance

    func testAReopenedChatShowsTheChecklistAsItFinished() {
        let engine = TurnEngine()
        engine.applyResumeProjection(sessionID: session, result: resume(running: false, todoState: snapshot(finishedPlan, revision: 4)),
                                     trailingUserTexts: [])
        let plan = engine.state(for: session).activity.todos
        XCTAssertEqual(plan.items.map(\.content), ["Read the failing test", "Fix the assertion", "Re-run the suite"])
        XCTAssertEqual(plan.items.map(\.status), [.completed, .completed, .cancelled])
        XCTAssertTrue(plan.isFinished)
    }

    func testAReopenedRunningTurnShowsItsPlanInProgress() {
        let engine = TurnEngine()
        engine.applyResumeProjection(sessionID: session, result: resume(running: true, todoState: snapshot(activePlan, revision: 2)),
                                     trailingUserTexts: [])
        let plan = engine.state(for: session).activity.todos
        XCTAssertEqual(plan.items.count, 2)
        XCTAssertEqual(plan.current?.content, "Fix the assertion")
    }

    /// The other half of acceptance: an older backend sends no key, and nothing changes.
    func testAnOlderBackendWithoutTheKeyLeavesTheChecklistAsToday() {
        let engine = TurnEngine()
        engine.applyResumeProjection(sessionID: session, result: resume(running: false), trailingUserTexts: [])
        XCTAssertTrue(engine.state(for: session).activity.todos.isEmpty)
    }

    /// An unfinished plan on a session whose turn is over is what the live path drops at turn end
    /// (`dropStaleTodos`), so a reopen does not bring it back either.
    func testAnIdleSessionDoesNotReviveAnUnfinishedPlan() {
        let engine = TurnEngine()
        engine.applyResumeProjection(sessionID: session, result: resume(running: false, todoState: snapshot(activePlan, revision: 2)),
                                     trailingUserTexts: [])
        XCTAssertTrue(engine.state(for: session).activity.todos.isEmpty)
    }

    func testAMalformedSnapshotIsIgnored() {
        for malformed: JSONValue in [
            .null,
            .string("not a snapshot"),
            .object(["todos": .string("not a list"), "revision": .number(3)]),
            .object(["revision": .number(3)]),
        ] {
            let engine = TurnEngine()
            engine.applyResumeProjection(sessionID: session, result: resume(running: true, todoState: malformed),
                                         trailingUserTexts: [])
            XCTAssertTrue(engine.state(for: session).activity.todos.isEmpty, "\(malformed)")
        }
    }

    // MARK: Ordering against the live path

    func testALiveUpdateOverwritesTheSeededPlan() {
        let engine = TurnEngine()
        engine.applyResumeProjection(sessionID: session, result: resume(running: true, todoState: snapshot(activePlan, revision: 2)),
                                     trailingUserTexts: [])
        engine.apply(planComplete([("1", "Read the failing test", "completed"), ("2", "Fix the assertion", "completed"),
                                   ("3", "Open the pull request", "in_progress")], revision: 3, toolID: "call_live"))
        XCTAssertEqual(contents(engine), ["Read the failing test", "Fix the assertion", "Open the pull request"])
    }

    func testANewerSnapshotReplacesAnOlderLivePlan() {
        let engine = TurnEngine()
        engine.apply(event("message.start"))
        engine.apply(planComplete(activePlan, revision: 2, toolID: "call_old"))
        engine.applyResumeProjection(sessionID: session,
                                     result: resume(running: true, todoState: snapshot([("1", "Newer plan", "in_progress")], revision: 3)),
                                     trailingUserTexts: [])
        XCTAssertEqual(contents(engine), ["Newer plan"])
    }

    func testAnOlderSnapshotCannotRollBackANewerLivePlan() {
        let engine = TurnEngine()
        engine.apply(event("message.start"))
        engine.apply(planComplete(activePlan, revision: 5, toolID: "call_new"))
        engine.applyResumeProjection(sessionID: session,
                                     result: resume(running: true, todoState: snapshot([("1", "Older plan", "in_progress")], revision: 4)),
                                     trailingUserTexts: [])
        XCTAssertEqual(contents(engine), ["Read the failing test", "Fix the assertion"])
    }

    /// An empty list at a revision past zero is the agent clearing its plan, not an absent key.
    func testAnEmptySnapshotAtANewerRevisionClearsThePlan() {
        let engine = TurnEngine()
        engine.apply(event("message.start"))
        engine.apply(planComplete(activePlan, revision: 1, toolID: "call_old"))
        engine.applyResumeProjection(sessionID: session, result: resume(running: true, todoState: snapshot([], revision: 2)),
                                     trailingUserTexts: [])
        XCTAssertTrue(engine.state(for: session).activity.todos.isEmpty)
    }

    /// The finished-plan linger ends at `message.start`; a snapshot of that same revision taken
    /// later must not bring it back mid-turn.
    func testASnapshotOfThePlanAMessageStartRetiredDoesNotComeBack() {
        let engine = TurnEngine()
        engine.apply(event("message.start"))
        engine.apply(planComplete(finishedPlan, revision: 4, toolID: "call_done"))
        engine.apply(event("message.complete", payload: .object(["status": .string("complete")])))
        engine.apply(event("message.start"))
        XCTAssertTrue(engine.state(for: session).activity.todos.isEmpty, "the linger ended at the next start")
        engine.applyResumeProjection(sessionID: session, result: resume(running: true, todoState: snapshot(finishedPlan, revision: 4)),
                                     trailingUserTexts: [])
        XCTAssertTrue(engine.state(for: session).activity.todos.isEmpty)
    }

    // MARK: Checkpoint recovery (the snapshot predates the replayed suffix)

    private func replayEvent(_ type: String, _ seq: Int, payload: JSONValue = .object([:]), execution: String = "run") -> GatewayEvent {
        GatewayEvent(type: type, sessionID: session, payload: payload, params: .object([
            "session_id": .string(session), "type": .string(type), "seq": .number(Double(seq)),
            "payload": payload, "turn": .object(["id": .string(execution)]),
        ]))
    }

    private func recovered(events: [GatewayEvent], todoState: JSONValue) throws -> TurnEngine {
        let previous = TurnEngine()
        previous.setReplayEpoch("e")
        previous.apply(replayEvent("message.start", 1))
        previous.apply(replayEvent("message.delta", 2, payload: .object(["text": .string("Working")])))
        let checkpoint = try XCTUnwrap(previous.checkpoint(sessionID: session))

        let engine = TurnEngine()
        engine.setReplayEpoch("e")
        XCTAssertTrue(engine.beginCheckpointRecovery(checkpoint))
        let latest = events.compactMap { $0.params["seq"]?.coercedInt }.max() ?? checkpoint.sequence
        let replay = try XCTUnwrap(SessionEventReplay(json: .object([
            "epoch": .string("e"), "truncated": .bool(false), "latest_seq": .number(Double(latest)),
            "events": .array(events.map(\.params)),
        ])))
        let result = SessionAPI.decodeResume(.object([
            "session_id": .string(session), "running": .bool(true),
            "info": .object(["title": .string("Synthetic plan")]),
            "inflight": .object(["user": .string("Plan it"), "assistant": .string("Working"), "streaming": .bool(true),
                                 "turn": .object(["id": .string("run")])]),
            "todo_state": todoState,
        ]), requested: "stored")
        XCTAssertTrue(engine.finishEventRecovery(sessionID: session, replay: replay, checkpoint: checkpoint, resumeSnapshot: result))
        return engine
    }

    /// The checkpoint carries no activity, so after an app restart the snapshot is the only source.
    func testACheckpointRecoverySeedsThePlanFromTheSnapshot() throws {
        let engine = try recovered(events: [], todoState: snapshot(activePlan, revision: 2))
        XCTAssertEqual(contents(engine), ["Read the failing test", "Fix the assertion"])
    }

    func testAReplayedPlanUpdateOutranksAnOlderSnapshot() throws {
        let replayed = replayEvent("tool.complete", 3, payload: .object([
            "tool_id": .string("call_replayed"), "name": .string("todo"),
            "todos": rows([("1", "Replayed plan", "in_progress")]), "revision": .number(6),
        ]))
        let engine = try recovered(events: [replayed], todoState: snapshot([("1", "Snapshot plan", "in_progress")], revision: 5))
        XCTAssertEqual(contents(engine), ["Replayed plan"])
    }

    func testASnapshotDoesNotReviveAPlanAcrossAReplayedTurnBoundary() throws {
        let engine = try recovered(events: [replayEvent("message.complete", 3), replayEvent("message.start", 4, execution: "next")],
                                   todoState: snapshot(finishedPlan, revision: 3))
        XCTAssertTrue(engine.state(for: session).isBusy)
        XCTAssertTrue(engine.state(for: session).activity.todos.isEmpty)
    }
}
