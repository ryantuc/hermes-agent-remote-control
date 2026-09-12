import Foundation
import HermesServeKit
import XCTest

@testable import HermesMobile

/// BUG-006 — the agent's `todo` list rendered as a generic ⚒ card full of raw
/// INPUT/OUTPUT JSON and there was no tracker anywhere, so the one thing the
/// user wanted to see — the plan — was the one thing they could not read.
///
/// The strip itself is a view and this target has no UI tests, so what is
/// asserted here is the state the view renders: that a `todo` completion on the
/// wire reaches the open chat's `live.activity`, that the transcript card
/// carries the typed list `ToolCardView` branches on, and that the retention
/// rules hold end to end through the real `AppModel` publish funnel rather than
/// only inside the engine.
final class TodoStatusStripTests: XCTestCase {

    private static func todoRows(_ rows: [(String, String, String)]) -> JSONValue {
        .array(rows.map { row in
            .object([
                "id": .string(row.0),
                "content": .string(row.1),
                "status": .string(row.2),
            ])
        })
    }

    /// The gateway's own `tool.complete` shape: the parsed result object plus
    /// the attached full list.
    private static func todoPayload(_ rows: [(String, String, String)], toolID: String) -> JSONValue {
        let items = todoRows(rows)
        return .object([
            "tool_id": .string(toolID),
            "name": .string("todo"),
            "result": .object(["todos": items]),
            "todos": items,
            "duration_s": .number(0.01),
        ])
    }

    @MainActor
    private func openChat(_ harness: AppHarness, storedID: String) async throws -> (ChatModel, String) {
        let chat = harness.chat(storedID: storedID)
        await chat.open()
        let bound = await waitUntil { chat.runtimeSessionID != nil }
        XCTAssertTrue(bound, "open() never bound a runtime id — nothing after this proves anything")
        return (chat, try XCTUnwrap(chat.runtimeSessionID))
    }

    /// The whole point of the bug: the plan has to arrive somewhere the strip
    /// can draw it, and the transcript card has to stop being raw JSON.
    @MainActor
    func testTheAgentsPlanReachesTheOpenChatsActivity() async throws {
        let harness = await AppHarness.make()
        try await harness.openSocket()
        let (chat, runtimeID) = try await openChat(harness, storedID: "20260814_010000_todo")

        await harness.backend.emit("message.start", sessionID: runtimeID)
        await harness.backend.emit("tool.complete", sessionID: runtimeID, payload: Self.todoPayload([
            ("1", "Read the failing test", "completed"),
            ("2", "Fix the assertion", "in_progress"),
            ("3", "Re-run the suite", "pending"),
        ], toolID: "call_todo_1"))

        let arrived = await waitUntil { chat.live.activity.todos.items.count == 3 }
        XCTAssertTrue(arrived, "the todo list never reached ChatModel.live.activity — the strip has nothing to draw")

        let plan = chat.live.activity.todos
        XCTAssertEqual(plan.items.map(\.content),
                       ["Read the failing test", "Fix the assertion", "Re-run the suite"],
                       "wire order is priority order")
        XCTAssertEqual(plan.current?.content, "Fix the assertion")
        XCTAssertEqual(plan.settledCount, 1)
        XCTAssertTrue(plan.isActive)

        // The transcript card carries the typed list, which is what makes
        // `ToolCardView` collapse it to one row instead of printing
        // `{"todos": [...]}` at the reader.
        let card = try XCTUnwrap(chat.entries.compactMap(\.tool).last)
        XCTAssertEqual(card.name, "todo")
        XCTAssertEqual(card.todos?.items.count, 3, "no typed list on the card → the raw JSON card renders")

        await harness.tearDown()
    }

    /// A finished plan is the most useful thing on screen right after the work
    /// is done, so it lingers — collapsed — and the NEXT turn is what retires
    /// it. No timer is involved anywhere in that sentence.
    @MainActor
    func testAFinishedPlanLingersUntilTheNextTurnStarts() async throws {
        let harness = await AppHarness.make()
        try await harness.openSocket()
        let (chat, runtimeID) = try await openChat(harness, storedID: "20260814_010100_todo")

        await harness.backend.emit("message.start", sessionID: runtimeID)
        await harness.backend.emit("tool.complete", sessionID: runtimeID, payload: Self.todoPayload([
            ("1", "Read the failing test", "completed"),
            ("2", "Re-run the suite", "completed"),
        ], toolID: "call_todo_1"))
        let arrived = await waitUntil { chat.live.activity.todos.items.count == 2 }
        XCTAssertTrue(arrived, "the todo list never arrived")

        await harness.backend.emit("message.complete", sessionID: runtimeID, payload: .object([
            "text": .string("All done."),
            "status": .string("complete"),
        ]))
        let settled = await waitUntil { !chat.live.isBusy }
        XCTAssertTrue(settled, "the turn never settled")
        XCTAssertTrue(chat.live.activity.todos.isFinished,
                      "a FINISHED plan must survive turn end — dropping it here is the bug this rule exists for")

        await harness.backend.emit("message.start", sessionID: runtimeID)
        let retired = await waitUntil { chat.live.activity.todos.isEmpty }
        XCTAssertTrue(retired, "the next turn starting is the only thing that clears a finished plan")

        await harness.tearDown()
    }

    /// The other half: a plan the agent abandoned mid-turn is stale and goes.
    @MainActor
    func testAnUnfinishedPlanIsDroppedWhenTheTurnEnds() async throws {
        let harness = await AppHarness.make()
        try await harness.openSocket()
        let (chat, runtimeID) = try await openChat(harness, storedID: "20260814_010200_todo")

        await harness.backend.emit("message.start", sessionID: runtimeID)
        await harness.backend.emit("tool.complete", sessionID: runtimeID, payload: Self.todoPayload([
            ("1", "Read the failing test", "in_progress"),
            ("2", "Re-run the suite", "pending"),
        ], toolID: "call_todo_1"))
        let arrived = await waitUntil { chat.live.activity.todos.items.count == 2 }
        XCTAssertTrue(arrived, "the todo list never arrived")

        await harness.backend.emit("message.complete", sessionID: runtimeID, payload: .object([
            "text": .string("I stopped here."),
            "status": .string("complete"),
        ]))
        let dropped = await waitUntil { chat.live.activity.todos.isEmpty }
        XCTAssertTrue(dropped, "an unfinished plan the agent stopped working on is stale and must not hang over the composer")

        await harness.tearDown()
    }

    /// `ToolCardView.Family(toolName:)` matches by substring, in order. The
    /// checklist family must be an EXACT match tested first, or a future tool
    /// named something like `todoist_add_task` hijacks the renderer and its
    /// output is drawn as somebody's plan.
    @MainActor
    func testTheTodoFamilyMatchesExactlyAndNeverBySubstring() {
        XCTAssertEqual(ToolCardView.Family(toolName: "todo").glyph, "📋")
        XCTAssertEqual(ToolCardView.Family(toolName: "TODO").glyph, "📋", "the matcher lowercases first")
        // BUG-145: upstream renamed the tool and kept no alias, so the plan
        // card has to answer to both names. Before the fix `todo_list` fell
        // past every substring bucket to `.other` — the card lost its glyph as
        // well as its checklist, on every backend at or past the rename. This
        // is the only app-target coverage of that site; the kit half lives in
        // `HermesServeKitTests/PlanToolRenameTests`.
        XCTAssertEqual(ToolCardView.Family(toolName: "todo_list").glyph, "📋")
        XCTAssertEqual(ToolCardView.Family(toolName: "TODO_LIST").glyph, "📋", "still lowercased first")
        XCTAssertEqual(ToolCardView.Family(toolName: "todoist_add_task").glyph, "⚒",
                       "a substring match here would hand the checklist renderer to an unrelated tool")
        XCTAssertEqual(ToolCardView.Family(toolName: "my_todo").glyph, "⚒")
        // The second name is a whole name too — widening the set must not
        // widen the matching.
        XCTAssertEqual(ToolCardView.Family(toolName: "todo_listing").glyph, "⚒")
        XCTAssertEqual(ToolCardView.Family(toolName: "my_todo_list").glyph, "⚒")
        // The buckets that were already there still resolve the same way.
        XCTAssertEqual(ToolCardView.Family(toolName: "terminal").glyph, "$")
        XCTAssertEqual(ToolCardView.Family(toolName: "read_file").glyph, "▤")
    }

    // MARK: BUG-014 — the header fraction

    /// The todo header passed `count: list.total`, so a running list read
    /// `📋 TASKS 6` and a finished one `📋 TASKS DONE 6` — **the same number in
    /// both states**, with the word "done" carrying the semantics the number
    /// did not. The fraction has to differ, and it has to climb.
    func testTheTodoFractionClimbsAndDiffersBetweenRunningAndFinished() {
        func list(_ settled: Int, of total: Int) -> TodoList {
            TodoList(items: (0..<total).map { index in
                TodoItem(
                    id: "t\(index)",
                    content: "task \(index)",
                    status: index < settled ? .completed : .pending
                )
            })
        }

        let climb = (0...6).map { StripProgress.todos(list($0, of: 6)) }
        XCTAssertEqual(climb, ["0/6", "1/6", "2/6", "3/6", "4/6", "5/6", "6/6"])

        // The defect, stated as an assertion: running and finished must not
        // print the same thing.
        let running = list(3, of: 6)
        let finished = list(6, of: 6)
        XCTAssertFalse(running.isFinished)
        XCTAssertTrue(finished.isFinished)
        XCTAssertNotEqual(StripProgress.todos(running), StripProgress.todos(finished),
                          "the header must not read the same number running and finished")
        XCTAssertEqual(StripProgress.todos(running), "3/6")
    }

    /// A cancelled item is settled — it is done being waited on — which is
    /// exactly what `settledCount` counts and what the sheet subtitle, the
    /// VoiceOver label and the transcript card have all said all along. If the
    /// header counted only `completedCount` it would disagree with four other
    /// surfaces and never reach its denominator on a list with a cancellation.
    func testACancelledTaskCountsAsSettledInTheHeaderFraction() {
        let list = TodoList(items: [
            TodoItem(id: "1", content: "done", status: .completed),
            TodoItem(id: "2", content: "dropped", status: .cancelled),
            TodoItem(id: "3", content: "running", status: .inProgress),
            TodoItem(id: "4", content: "waiting", status: .pending),
        ])
        XCTAssertEqual(StripProgress.todos(list), "2/4")
        XCTAssertEqual(StripProgress.todos(TodoList()), "0/0")
    }
}
