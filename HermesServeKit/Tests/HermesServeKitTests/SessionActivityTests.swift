import XCTest

@testable import HermesServeKit

/// The typed todo decode and the bounds every collection on the shared activity
/// surface is held to.
final class SessionActivityTests: XCTestCase {

    private func item(_ id: String, _ content: String, _ status: String) -> JSONValue {
        .object(["id": .string(id), "content": .string(content), "status": .string(status)])
    }

    // MARK: Typed decode

    func testDecodesTheWholeListInWireOrder() throws {
        let payload: JSONValue = .object(["todos": .array([
            item("3", "Third", "pending"),
            item("1", "First", "in_progress"),
            item("2", "Second", "completed"),
            item("4", "Fourth", "cancelled"),
        ])])

        let list = try XCTUnwrap(TodoList.parse(payload: payload))
        XCTAssertEqual(list.items.map(\.id), ["3", "1", "2", "4"], "wire order is priority order; never re-sort")
        XCTAssertEqual(list.items.map(\.status), [.pending, .inProgress, .completed, .cancelled])
        XCTAssertEqual(list.total, 4)
        XCTAssertEqual(list.completedCount, 1)
        XCTAssertEqual(list.settledCount, 2, "cancelled counts as settled")
        XCTAssertEqual(list.current?.content, "First")
        XCTAssertTrue(list.isActive)
        XCTAssertFalse(list.isFinished)
    }

    /// The backend deduped already, keeping the last occurrence in its original
    /// position. A second dedupe here with different tie-breaking would silently
    /// reorder the user's plan.
    func testRepeatedIdsAreNotDeduped() throws {
        let payload: JSONValue = .object(["todos": .array([
            item("1", "One", "pending"),
            item("1", "One again", "completed"),
        ])])
        let list = try XCTUnwrap(TodoList.parse(payload: payload))
        XCTAssertEqual(list.items.count, 2)
        XCTAssertEqual(list.items.map(\.content), ["One", "One again"])
    }

    /// **The trap.** An empty array is a SUCCESSFUL parse meaning "the agent
    /// cleared its plan". A parser that returns nil here leaves the checklist on
    /// screen forever the moment the agent empties it.
    func testEmptyArrayParsesSuccessfullyAsAClearedList() throws {
        let list = try XCTUnwrap(
            TodoList.parse(payload: .object(["todos": .array([])])),
            "[] must parse, not fail"
        )
        XCTAssertTrue(list.isEmpty)
        XCTAssertFalse(list.isActive)
        XCTAssertFalse(list.isFinished, "an empty list is not a finished list")
    }

    func testNilOnlyWhenNothingInThePayloadParsed() {
        XCTAssertNil(TodoList.parse(payload: .object([:])))
        XCTAssertNil(TodoList.parse(payload: .object(["todos": .null])))
        XCTAssertNil(TodoList.parse(payload: .object(["todos": .number(3)])))
        XCTAssertNil(TodoList.parse(payload: .object(["result": .string("not json at all")])))
        XCTAssertNil(TodoList.parse(payload: .object(["result": .object(["summary": .object([:])])])),
                     "an object with no todos key is not a todo payload")
    }

    /// Desktop's order: `payload.todos` → `payload.result` → `payload.args`.
    func testPrecedenceTodosThenResultThenArgs() throws {
        let all: JSONValue = .object([
            "todos": .array([item("a", "from todos", "pending")]),
            "result": .object(["todos": .array([item("b", "from result", "pending")])]),
            "args": .object(["todos": .array([item("c", "from args", "pending")])]),
        ])
        XCTAssertEqual(try XCTUnwrap(TodoList.parse(payload: all)).items.first?.content, "from todos")

        let withoutTodos: JSONValue = .object([
            "result": .object(["todos": .array([item("b", "from result", "pending")])]),
            "args": .object(["todos": .array([item("c", "from args", "pending")])]),
        ])
        XCTAssertEqual(try XCTUnwrap(TodoList.parse(payload: withoutTodos)).items.first?.content, "from result")

        let argsOnly: JSONValue = .object([
            "args": .object(["todos": .array([item("c", "from args", "pending")])]),
        ])
        XCTAssertEqual(try XCTUnwrap(TodoList.parse(payload: argsOnly)).items.first?.content, "from args")
    }

    /// `tool.complete.result` is `json.loads(result)` when parseable and the raw
    /// string otherwise, so both shapes have to decode.
    func testResultDecodesAsObjectAndAsEncodedString() throws {
        let asObject: JSONValue = .object(["result": .object([
            "todos": .array([item("1", "Ship it", "in_progress")]),
            "summary": .object(["total": .number(1)]),
        ])])
        XCTAssertEqual(try XCTUnwrap(TodoList.parse(payload: asObject)).items.first?.content, "Ship it")

        let encoded = #"{"todos":[{"id":"1","content":"Ship it","status":"in_progress"}]}"#
        let asString: JSONValue = .object(["result": .string(encoded)])
        XCTAssertEqual(try XCTUnwrap(TodoList.parse(payload: asString)).items.first?.status, .inProgress)
    }

    /// Strict means a malformed ITEM is dropped, not that the whole list is
    /// rejected — one bad row must not poison the four good ones.
    func testMalformedItemsAreDroppedIndividually() throws {
        let payload: JSONValue = .object(["todos": .array([
            item("1", "Good", "pending"),
            .object(["content": .string("no id"), "status": .string("pending")]),
            .object(["id": .string("2"), "status": .string("pending")]),
            .object(["id": .string("3"), "content": .string("   "), "status": .string("pending")]),
            .string("not an object"),
            .object(["id": .string("4"), "content": .string("bad status"), "status": .string("blocked")]),
            item("5", "Also good", "completed"),
        ])])

        let list = try XCTUnwrap(TodoList.parse(payload: payload))
        XCTAssertEqual(list.items.map(\.id), ["1", "5"])
    }

    /// **The other trap.** An unrecognised status must never render as work in
    /// progress: that list could never reach `isFinished`, so it would never
    /// collapse and would sit above the composer for the rest of the session.
    /// Dropping the item keeps the list able to finish.
    func testAnUnrecognisedStatusCannotLeaveTheListSpinning() throws {
        let payload: JSONValue = .object(["todos": .array([
            item("1", "Done", "completed"),
            item("2", "Who knows", "deferred"),
        ])])
        let list = try XCTUnwrap(TodoList.parse(payload: payload))
        XCTAssertEqual(list.items.count, 1)
        XCTAssertTrue(list.isFinished, "the surviving list still reaches a terminal state")
        XCTAssertNil(list.current)
    }

    /// Ints for `id` are accepted — the gateway emits ints and floats
    /// interchangeably and the payload header says so.
    func testNumericIdsAreCoerced() throws {
        let payload: JSONValue = .object(["todos": .array([
            .object(["id": .number(7), "content": .string("Coerce me"), "status": .string("pending")]),
        ])])
        XCTAssertEqual(try XCTUnwrap(TodoList.parse(payload: payload)).items.first?.id, "7")
    }

    // MARK: Bounds

    /// 1,000 items in one payload; the stored list stays at the cap.
    func testTodoItemsAreCappedOnWrite() throws {
        let payload: JSONValue = .object(["todos": .array(
            (0..<1_000).map { item("\($0)", "Task \($0)", "pending") }
        )])
        let list = try XCTUnwrap(TodoList.parse(payload: payload))
        XCTAssertEqual(list.items.count, SessionActivity.todoItemLimit)
        XCTAssertEqual(list.items.first?.id, "0", "truncation keeps the head — order is priority")
    }

    func testTodoContentIsClampedOnWrite() throws {
        let long = String(repeating: "x", count: 5_000)
        let payload: JSONValue = .object(["todos": .array([item("1", long, "pending")])])
        let content = try XCTUnwrap(TodoList.parse(payload: payload)).items.first?.content ?? ""
        XCTAssertEqual(content.count, SessionActivity.todoContentLimit)
        XCTAssertTrue(content.hasSuffix("…"))
    }

    /// 1,000 rows written into the container; `enforceBounds` holds it at 32 and
    /// spends the terminal rows first.
    func testSubagentRowsAreCappedAndTerminalRowsGoFirst() {
        var activity = SessionActivity()
        for index in 0..<1_000 {
            var row = SubagentRow(id: "agent-\(index)", goal: "goal \(index)")
            // Every other row is finished, so both branches of the drop rule run.
            if index.isMultiple(of: 2) { row.state = .completed }
            activity.subagents.append(row)
            activity.enforceBounds()
        }
        XCTAssertEqual(activity.subagents.count, SessionActivity.subagentLimit)
        XCTAssertEqual(activity.subagents.filter(\.isTerminal).count, 0,
                       "terminal rows are dropped before running ones")
    }

    func testSubagentStreamIsCappedAndDedupedConsecutively() {
        var row = SubagentRow(id: "agent-1")
        for index in 0..<1_000 {
            row.appendStream("line \(index)")
            row.appendStream("line \(index)")  // identical consecutive → collapsed
        }
        XCTAssertEqual(row.stream.count, SessionActivity.streamLimit)
        XCTAssertEqual(row.stream.last, "line 999")
        XCTAssertEqual(Set(row.stream).count, row.stream.count)
    }

    func testStreamLinesAreWhitespaceCollapsedAndClamped() {
        var row = SubagentRow(id: "agent-1")
        row.appendStream("  reading   the\n\n  spec  ")
        XCTAssertEqual(row.stream.last, "reading the spec")
        row.appendStream(String(repeating: "y", count: 900))
        XCTAssertEqual(row.stream.last?.count, SessionActivity.streamLineLimit)
        row.appendStream("   \n  ")
        XCTAssertEqual(row.stream.count, 2, "an all-whitespace line is not an entry")
    }

    func testSubagentGoalAndSummaryAreClampedOnInitAndOnAssignment() {
        let long = String(repeating: "z", count: 900)
        var row = SubagentRow(id: "agent-1", goal: long, summary: long)
        XCTAssertEqual(row.goal.count, SessionActivity.subagentTextLimit)
        XCTAssertEqual(row.summary.count, SessionActivity.subagentTextLimit)
        row.goal = long
        row.summary = long
        XCTAssertEqual(row.goal.count, SessionActivity.subagentTextLimit)
        XCTAssertEqual(row.summary.count, SessionActivity.subagentTextLimit)
    }

    // MARK: The desktop status bug this client must not copy

    /// Desktop falls through anything unrecognised to `running`, so a timed-out
    /// agent never becomes terminal, never prunes and spins forever. Here
    /// `subagent.complete` is terminal by event type and an unknown status maps
    /// to `failed`.
    func testUnrecognisedCompletionStatusBecomesFailedNeverRunning() {
        for status in ["timeout", "error", "", "who knows", "queued"] {
            let state = SubagentRow.State(completeStatus: status)
            XCTAssertEqual(state, .failed, "\(status) must be failed")
            XCTAssertTrue(state.isTerminal)
        }
        XCTAssertEqual(SubagentRow.State(completeStatus: nil), .failed)
        XCTAssertEqual(SubagentRow.State(completeStatus: "completed"), .completed)
        XCTAssertEqual(SubagentRow.State(completeStatus: "interrupted"), .interrupted)
    }

    func testEmptyActivityIsEmpty() {
        var activity = SessionActivity()
        XCTAssertTrue(activity.isEmpty)
        activity.todos = TodoList(items: [TodoItem(id: "1", content: "x", status: .pending)])
        XCTAssertFalse(activity.isEmpty)
        activity.todos = TodoList()
        activity.subagents = [SubagentRow(id: "a")]
        XCTAssertFalse(activity.isEmpty)
    }
}
