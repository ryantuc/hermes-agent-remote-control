import XCTest

@testable import HermesServeKit

/// The diagnosis of `TodoActivityLifecycleTests.testAThousandUpdatesDoNotGrowTheState`, red since
/// the BUG-151 fix with `("1000") is greater than ("2")`.
///
/// That test sends a thousand plan-tool completions, each with its OWN `tool_id` and no start.
/// Before the BUG-151 fix, `completeTool` fell back to `toolIndex(..., requireRunning: false)`, which
/// name-matched any settled `todo` card, so all thousand collapsed onto one card. BUG-151 removed
/// that fallback on purpose ("never merges different real IDs",
/// `ToolIdentityCorrelationTests.testIDLessCompletionDoesNotOverwriteEarlierCompletedCall`), so a
/// thousand distinct calls are a thousand cards, exactly as the transcript has them. The bounds the
/// old test was written to protect are all still in force, and are pinned here.
final class TodoCardGrowthTests: XCTestCase {
    private let session = "a1b2c3d4"

    private func planComplete(round: Int) -> GatewayEvent {
        let items: JSONValue = .array((0..<300).map {
            .object(["id": .string("\($0)"), "content": .string("Task \($0) round \(round)"), "status": .string("pending")])
        })
        let payload: JSONValue = .object([
            "tool_id": .string("call_todo_\(round)"), "name": .string("todo"),
            "result": .object(["todos": items]), "todos": items,
        ])
        return GatewayEvent(type: "tool.complete", sessionID: session, payload: payload, params: .object([
            "type": .string("tool.complete"), "session_id": .string(session), "payload": payload,
        ]))
    }

    func testAThousandDistinctPlanCallsAreAThousandBoundedCards() {
        let engine = TurnEngine()
        engine.apply(GatewayEvent(type: "message.start", sessionID: session, payload: .object([:]), params: .object([
            "type": .string("message.start"), "session_id": .string(session),
        ])))
        for round in 0..<1_000 { engine.apply(planComplete(round: round)) }
        engine.flush()

        let state = engine.state(for: session)
        // The shared checklist is one list, capped at the backend's ceiling.
        XCTAssertEqual(state.activity.todos.items.count, SessionActivity.todoItemLimit)
        XCTAssertEqual(state.activity.todos.items.first?.content, "Task 0 round 999", "the newest call's plan")
        // One card per real call, each carrying a capped copy of the plan it reported.
        let cards = state.entries.compactMap(\.tool)
        XCTAssertEqual(cards.count, 1_000)
        XCTAssertEqual(Set(cards.map(\.id)).count, 1_000, "no two real calls were merged")
        XCTAssertTrue(cards.allSatisfy { ($0.todos?.items.count ?? 0) <= SessionActivity.todoItemLimit })
        XCTAssertTrue(cards.allSatisfy { card in
            (card.todos?.items ?? []).allSatisfy { item in item.content.count <= SessionActivity.todoContentLimit }
        })
    }
}
