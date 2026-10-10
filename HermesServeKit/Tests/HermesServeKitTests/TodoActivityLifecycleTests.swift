import XCTest

@testable import HermesServeKit

/// BUG-006 — the todo reducer and every lifecycle hook in §4 of the
/// implementation spec, driven through `TurnEngine.apply` the way the wire
/// drives it.
final class TodoActivityLifecycleTests: XCTestCase {
    private let session = "a1b2c3d4"

    // MARK: Wire helpers

    private func event(_ type: String, payload: JSONValue = .object([:])) -> GatewayEvent {
        GatewayEvent(
            type: type,
            sessionID: session,
            payload: payload,
            params: .object([
                "type": .string(type),
                "session_id": .string(session),
                "payload": payload,
            ])
        )
    }

    private func todoItems(_ rows: [(String, String, String)]) -> JSONValue {
        .array(rows.map { row in
            .object([
                "id": .string(row.0),
                "content": .string(row.1),
                "status": .string(row.2),
            ])
        })
    }

    /// A `tool.complete` in the gateway's own shape: the parsed `result` object
    /// plus the attached full list.
    private func todoComplete(
        _ rows: [(String, String, String)],
        toolID: String = "call_todo",
        name: String = "todo"
    ) -> GatewayEvent {
        let items = todoItems(rows)
        return event("tool.complete", payload: .object([
            "tool_id": .string(toolID),
            "name": .string(name),
            "result": .object(["todos": items]),
            "todos": items,
            "duration_s": .number(0.01),
        ]))
    }

    private func drive(_ engine: TurnEngine, _ events: [GatewayEvent]) {
        for event in events { engine.apply(event) }
        engine.flush()
    }

    private var activePlan: [(String, String, String)] {
        [("1", "Read the spec", "in_progress"), ("2", "Write the reducer", "pending")]
    }

    private var finishedPlan: [(String, String, String)] {
        [("1", "Read the spec", "completed"), ("2", "Write the reducer", "cancelled")]
    }

    // MARK: The wire shape end to end

    func testTheTurnScriptMaterializesAndThenSettlesAPlan() throws {
        let engine = TurnEngine()
        for event in try Fixtures.events("todo-lifecycle") { engine.apply(event) }
        engine.flush()

        let state = engine.state(for: session)
        let plan = state.activity.todos
        XCTAssertEqual(plan.items.map(\.content),
                       ["Read the failing test", "Fix the assertion", "Re-run the suite"])
        XCTAssertEqual(plan.items.map(\.status), [.completed, .completed, .cancelled])
        XCTAssertTrue(plan.isFinished, "completed + cancelled is a finished list")
        XCTAssertFalse(state.isBusy, "message.complete ended the turn")
        XCTAssertFalse(plan.isEmpty, "a FINISHED list survives turn end — it is the linger")

        // Each card keeps its own snapshot: the transcript is the only
        // scrollback on a phone, so the earlier plan stays readable in place.
        let cards = state.entries.compactMap(\.tool).filter { $0.name == TodoList.toolName }
        XCTAssertEqual(cards.count, 2)
        XCTAssertEqual(try XCTUnwrap(cards.first?.todos).items.map(\.status),
                       [.inProgress, .pending, .pending])
        XCTAssertEqual(try XCTUnwrap(cards.last?.todos).items.map(\.status),
                       [.completed, .completed, .cancelled])
        // …and the raw result is still on the card, so nothing is lost if the
        // typed view is ever wrong.
        XCTAssertTrue(cards.last?.resultText.contains("Re-run the suite") == true)
    }

    // MARK: The reducer

    func testACompletionReplacesTheWholeListRatherThanMergingIt() {
        let engine = TurnEngine()
        drive(engine, [
            event("message.start"),
            todoComplete([("1", "One", "pending"), ("2", "Two", "pending"), ("3", "Three", "pending")]),
            todoComplete([("9", "Only this now", "in_progress")], toolID: "call_todo_2"),
        ])
        let plan = engine.state(for: session).activity.todos
        XCTAssertEqual(plan.items.map(\.id), ["9"], "the last full list wins; nothing merges")
    }

    /// **The trap, at the reducer.** An empty array is the agent saying it
    /// cleared its plan; it has to clear the strip, not be read as a failed
    /// parse that leaves the old list on screen forever.
    func testAnEmptyUpdateClearsTheList() {
        let engine = TurnEngine()
        drive(engine, [event("message.start"), todoComplete(activePlan)])
        XCTAssertFalse(engine.state(for: session).activity.todos.isEmpty)

        drive(engine, [todoComplete([], toolID: "call_todo_2")])
        XCTAssertTrue(engine.state(for: session).activity.todos.isEmpty)
    }

    /// The fallback contract: a payload the parser cannot understand leaves the
    /// card untyped (so the generic JSON card still renders and the user is
    /// never shown nothing) and leaves the existing plan alone.
    func testAnUnparseableTodoPayloadFallsBackWithoutDamagingTheList() throws {
        let engine = TurnEngine()
        drive(engine, [
            event("message.start"),
            todoComplete(activePlan),
            // Its own card, so the three-tier name correlation cannot fold this
            // completion onto the previous one.
            event("tool.start", payload: .object([
                "tool_id": .string("call_todo_2"),
                "name": .string("todo"),
            ])),
            event("tool.complete", payload: .object([
                "tool_id": .string("call_todo_2"),
                "name": .string("todo"),
                "result": .string("the tool printed prose today"),
            ])),
        ])

        let state = engine.state(for: session)
        XCTAssertEqual(state.activity.todos.items.count, 2, "an unparseable frame is not a clear")
        let card = try XCTUnwrap(state.entries.compactMap(\.tool).last)
        XCTAssertNil(card.todos, "no typed data → the generic card renders")
        XCTAssertFalse(card.resultText.isEmpty, "…and it still has something to show")
    }

    /// `ToolCardView.Family` matches by substring; the checklist must not be.
    func testAToolWhoseNameMerelyContainsTodoDoesNotDriveTheChecklist() {
        let engine = TurnEngine()
        drive(engine, [
            event("message.start"),
            todoComplete(activePlan, toolID: "call_x", name: "todoist_add_task"),
        ])
        let state = engine.state(for: session)
        XCTAssertTrue(state.activity.todos.isEmpty)
        XCTAssertNil(state.entries.compactMap(\.tool).last?.todos)
    }

    // MARK: Lifecycle

    func testTurnEndDropsAnActivePlanAsStale() {
        let engine = TurnEngine()
        drive(engine, [event("message.start"), todoComplete(activePlan)])
        XCTAssertTrue(engine.state(for: session).activity.todos.isActive)

        drive(engine, [event("message.complete", payload: .object(["status": .string("complete")]))])
        XCTAssertTrue(engine.state(for: session).activity.todos.isEmpty,
                      "an unfinished plan the agent stopped working on is stale")
    }

    func testTurnEndKeepsAFinishedPlanUntilTheNextMessageStart() {
        let engine = TurnEngine()
        drive(engine, [event("message.start"), todoComplete(finishedPlan)])
        drive(engine, [event("message.complete", payload: .object(["status": .string("complete")]))])

        let held = engine.state(for: session).activity.todos
        XCTAssertTrue(held.isFinished)
        XCTAssertEqual(held.items.count, 2, "the finished list lingers — with no timer anywhere")

        // The next turn starting is the only thing that retires it.
        drive(engine, [event("message.start")])
        XCTAssertTrue(engine.state(for: session).activity.todos.isEmpty)
    }

    func testAnErrorEventDropsAnActivePlanAndKeepsAFinishedOne() {
        let engine = TurnEngine()
        drive(engine, [event("message.start"), todoComplete(activePlan)])
        drive(engine, [event("error", payload: .object(["message": .string("agent init failed")]))])
        XCTAssertTrue(engine.state(for: session).activity.todos.isEmpty)

        let other = TurnEngine()
        drive(other, [event("message.start"), todoComplete(finishedPlan)])
        drive(other, [event("error", payload: .object(["message": .string("agent init failed")]))])
        XCTAssertEqual(other.state(for: session).activity.todos.items.count, 2)
    }

    /// `session.active_list` said the turn is over and absence is
    /// authoritative — same retention rule as a terminal frame.
    func testSettleFromStatusDropsAnActivePlan() {
        let engine = TurnEngine()
        drive(engine, [event("message.start"), todoComplete(activePlan)])
        engine.settleFromStatus(sessionID: session)
        XCTAssertTrue(engine.state(for: session).activity.todos.isEmpty)
    }

    /// Stop clears the whole surface, finished or not.
    func testStopClearsTheWholeSurfaceUnconditionally() {
        let engine = TurnEngine()
        drive(engine, [event("message.start"), todoComplete(finishedPlan)])
        engine.markInterrupted(sessionID: session)

        let activity = engine.state(for: session).activity
        XCTAssertTrue(activity.isEmpty, "including a finished list, which otherwise lingers")
        XCTAssertTrue(activity.subagents.isEmpty)
    }

    /// The interrupt latch has to cover the reducer too, or a stale completion
    /// from the cancelled turn repopulates the strip the user just cleared.
    func testTheInterruptLatchSwallowsALateTodoCompletion() {
        let engine = TurnEngine()
        drive(engine, [event("message.start"), todoComplete(activePlan)])
        engine.markInterrupted(sessionID: session)

        drive(engine, [todoComplete(activePlan, toolID: "call_late")])
        XCTAssertTrue(engine.state(for: session).activity.todos.isEmpty)
    }

    // MARK: Session bookkeeping rides `SessionTurnState` for free

    func testRebindCarriesTheActivityAndResetAndForgetFreeIt() {
        let engine = TurnEngine()
        drive(engine, [event("message.start"), todoComplete(finishedPlan)])

        engine.rebind(from: session, to: "new-runtime-id")
        XCTAssertTrue(engine.state(for: session).activity.isEmpty)
        XCTAssertEqual(engine.state(for: "new-runtime-id").activity.todos.items.count, 2)

        engine.reset(sessionID: "new-runtime-id")
        XCTAssertTrue(engine.state(for: "new-runtime-id").activity.isEmpty)

        drive(engine, [event("message.start"), todoComplete(finishedPlan)])
        engine.forget(sessionID: session)
        XCTAssertTrue(engine.state(for: session).activity.isEmpty)
    }

    /// v1 is live-only. The REST transcript projection truncates tool results at
    /// 4,000 chars, so a large plan arrives from history as unparseable JSON —
    /// a resume shows nothing until the agent's next `todo` call says otherwise.
    func testResumeNeverRehydratesAPlan() throws {
        let engine = TurnEngine()
        let result = SessionAPI.decodeResume(
            try Fixtures.result("response-session-resume-inflight"),
            requested: "20260731_170500_ab12ef"
        )
        engine.applyResumeProjection(
            sessionID: result.sessionID,
            result: result,
            trailingUserTexts: []
        )
        XCTAssertTrue(engine.state(for: result.sessionID).activity.isEmpty)
    }

    func testReplaceEntriesLeavesTheActivityAlone() {
        let engine = TurnEngine()
        drive(engine, [event("message.start"), todoComplete(activePlan)])
        engine.replaceEntries(sessionID: session, with: [
            ChatEntry(id: "history-1", kind: .user, text: "hello"),
        ])
        XCTAssertEqual(engine.state(for: session).activity.todos.items.count, 2)
        XCTAssertEqual(engine.state(for: session).entries.count, 1)
    }

    /// Activity is derived display state. A session holding nothing but a
    /// lingering finished checklist is still evictable — anything else would
    /// stop the idle sweep reclaiming the chatless sessions BUG-004 exists for.
    func testALingeringChecklistDoesNotBlockQuiescence() {
        let engine = TurnEngine()
        drive(engine, [
            event("message.start"),
            todoComplete(finishedPlan),
            event("message.complete", payload: .object(["status": .string("complete")])),
        ])
        XCTAssertFalse(engine.state(for: session).activity.isEmpty)
        XCTAssertTrue(engine.isQuiescent(sessionID: session))
    }

    // MARK: Growth

    /// A thousand plan updates, each three times the backend's own ceiling.
    /// Neither the stored list nor the transcript may grow without bound.
    func testAThousandUpdatesDoNotGrowTheState() {
        let engine = TurnEngine()
        engine.apply(event("message.start"))
        for round in 0..<1_000 {
            let rows = (0..<300).map { ("\($0)", "Task \($0) round \(round)", "pending") }
            engine.apply(todoComplete(rows, toolID: "call_todo_\(round)"))
        }
        engine.flush()

        let state = engine.state(for: session)
        XCTAssertEqual(state.activity.todos.items.count, SessionActivity.todoItemLimit)
        XCTAssertTrue(state.activity.todos.items.allSatisfy {
            $0.content.count <= SessionActivity.todoContentLimit
        })
        // One card per real call since BUG-151: these are a thousand distinct tool ids.
        XCTAssertEqual(state.entries.count, 1_000, "a thousand distinct plan calls are a thousand cards")
    }
}
