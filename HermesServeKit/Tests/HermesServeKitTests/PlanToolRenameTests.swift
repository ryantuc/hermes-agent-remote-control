import XCTest

@testable import HermesServeKit

/// BUG-145 — upstream renamed the plan tool from `todo` to `todo_list` (#97979,
/// `tools/todo_tool.py:381,443`) and registered no alias for the old name. The
/// gateway emits the tool's raw registry name on `tool.start` / `tool.complete`
/// while still attaching `todos` to it, so a client that matches one spelling
/// renders the checklist on exactly half the backends in the field.
///
/// Derived from source, not observed: the backend on this box predates the
/// rename. That is the whole reason both names have to keep working — a phone
/// meets whichever hermes-agent its owner happens to have installed.
///
/// The exact-match rule that `TodoList.toolName`'s doc comment defends is
/// unchanged, and `testASubstringNeighbourStillGetsNothing` is what pins it.
final class PlanToolRenameTests: XCTestCase {
    private let session = "a1b2c3d4"

    private func toolComplete(name: String) -> GatewayEvent {
        let items = JSONValue.array([
            .object(["id": .string("1"), "content": .string("Read the spec"), "status": .string("in_progress")]),
            .object(["id": .string("2"), "content": .string("Write the reducer"), "status": .string("pending")]),
        ])
        let payload = JSONValue.object([
            "tool_id": .string("call_plan"),
            "name": .string(name),
            "result": .object(["todos": items]),
            "todos": items,
            "duration_s": .number(0.01),
        ])
        return GatewayEvent(
            type: "tool.complete",
            sessionID: session,
            payload: payload,
            params: .object([
                "type": .string("tool.complete"),
                "session_id": .string(session),
                "payload": payload,
            ])
        )
    }

    private struct NotAToolComplete: Error {}

    /// Deliberately *throws* rather than returning nil when the projection is
    /// the wrong shape: the nil assertions below must fail for the reason they
    /// name and not because the event stopped decoding at all.
    private func decodedTodos(name: String) throws -> TodoList? {
        guard case .toolComplete(let completion) = HermesEvent.project(toolComplete(name: name)) else {
            throw NotAToolComplete()
        }
        return completion.todos
    }

    // MARK: Decode

    /// The new name. Before this fix the projection handed back `todos == nil`
    /// and every downstream renderer had nothing to draw.
    func testTodoListDecodesItsTodos() throws {
        let todos = try XCTUnwrap(try decodedTodos(name: "todo_list"))
        XCTAssertEqual(todos.items.map(\.content), ["Read the spec", "Write the reducer"])
    }

    /// The regression pin. Every backend the field already has emits `todo`.
    func testTodoStillDecodesItsTodos() throws {
        let todos = try XCTUnwrap(try decodedTodos(name: "todo"))
        XCTAssertEqual(todos.items.map(\.content), ["Read the spec", "Write the reducer"])
    }

    /// Whole names, never a prefix. This is the exact tool the original doc
    /// comment named as the thing a substring match would let through.
    func testASubstringNeighbourStillGetsNothing() throws {
        XCTAssertNil(
            try decodedTodos(name: "todoist_add_task"),
            "a tool whose name merely begins with todo must not drive the checklist"
        )
    }

    func testIsPlanToolIsExactOnBothSpellings() {
        XCTAssertTrue(TodoList.isPlanTool("todo"))
        XCTAssertTrue(TodoList.isPlanTool("todo_list"))
        XCTAssertFalse(TodoList.isPlanTool("todoist_add_task"))
        XCTAssertFalse(TodoList.isPlanTool("todo_lists"))
        XCTAssertFalse(TodoList.isPlanTool(""))
        XCTAssertEqual(TodoList.toolName, "todo", "the canonical display string is unchanged")
    }

    // MARK: The reducer

    /// The half that actually lights the activity strip and the Live Activity:
    /// `TurnEngine.applyTodos` gates on the name a second time, so decoding the
    /// list is not enough on its own.
    func testATodoListCompletionPopulatesThePlan() {
        let engine = TurnEngine()
        engine.apply(toolComplete(name: "todo_list"))
        engine.flush()

        let plan = engine.state(for: session).activity.todos
        XCTAssertEqual(plan.items.map(\.content), ["Read the spec", "Write the reducer"])
        XCTAssertTrue(plan.isActive, "an in-progress item means the strip has progress to show")
    }

    func testATodoCompletionStillPopulatesThePlan() {
        let engine = TurnEngine()
        engine.apply(toolComplete(name: "todo"))
        engine.flush()
        XCTAssertEqual(engine.state(for: session).activity.todos.items.count, 2)
    }
}
