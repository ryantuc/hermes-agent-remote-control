import XCTest
@testable import HermesServeKit

final class ToolIdentityCorrelationTests: XCTestCase {
    private func event(_ type: String, id: String? = nil, result: String? = nil) -> GatewayEvent {
        var payload: [String: JSONValue] = ["name": .string("web_search")]
        if let id { payload["tool_id"] = .string(id) }
        if let result { payload["result"] = .string(result) }
        if type == "tool.output_risk" { payload["risk"] = .string("high") }
        return GatewayEvent(type: type, sessionID: "s", payload: .object(payload), params: .null)
    }

    func testParallelSameNameCallsKeepTheirOwnResults() {
        let engine = TurnEngine()
        engine.apply(event("tool.start", id: "one"))
        engine.apply(event("tool.start", id: "two"))
        engine.apply(event("tool.complete", id: "one", result: "First"))
        engine.apply(event("tool.complete", id: "two", result: "Second"))
        let tools = engine.state(for: "s").entries.compactMap(\.tool)
        XCTAssertEqual(tools.map(\.id), ["one", "two"])
        XCTAssertEqual(tools.map(\.resultText), ["First", "Second"])
        XCTAssertTrue(tools.allSatisfy { !$0.isRunning })
    }

    func testRiskForUnseenExplicitIDWaitsForItsOwnCard() {
        let engine = TurnEngine()
        engine.apply(event("tool.start", id: "one"))
        engine.apply(event("tool.output_risk", id: "two"))
        XCTAssertFalse(engine.state(for: "s").entries.first?.tool?.hasOutputRisk ?? true)
        engine.apply(event("tool.complete", id: "two", result: "Second"))
        let tools = engine.state(for: "s").entries.compactMap(\.tool)
        XCTAssertEqual(tools.map(\.id), ["one", "two"])
        XCTAssertFalse(tools.first?.hasOutputRisk ?? true)
        XCTAssertEqual(tools.last?.outputRisk, "high")
        XCTAssertTrue(tools.first?.isRunning ?? false)
    }

    func testIDLessCompletionDoesNotOverwriteEarlierCompletedCall() {
        let engine = TurnEngine()
        engine.apply(event("tool.complete", result: "First"))
        engine.apply(event("tool.complete", result: "Second"))
        let tools = engine.state(for: "s").entries.compactMap(\.tool)
        XCTAssertEqual(tools.map(\.resultText), ["First", "Second"])
    }

    func testLegacyStartStillAcceptsRealIDRiskAndCompletion() {
        let engine = TurnEngine()
        engine.apply(event("tool.start"))
        engine.apply(event("tool.output_risk", id: "one"))
        engine.apply(event("tool.complete", id: "one", result: "First"))
        let tools = engine.state(for: "s").entries.compactMap(\.tool)
        XCTAssertEqual(tools.count, 1)
        XCTAssertEqual(tools.first?.resultText, "First")
        XCTAssertEqual(tools.first?.outputRisk, "high")
        XCTAssertFalse(tools.first?.isRunning ?? true)
    }

    func testLegacyCompletionLearnsRealIDAndDuplicateKeepsOneRow() throws {
        let engine = TurnEngine()
        engine.apply(event("tool.start"))
        let rowID = try XCTUnwrap(engine.state(for: "s").entries.first?.id)
        engine.apply(event("tool.complete", id: "one", result: "First"))
        engine.apply(event("tool.complete", id: "one", result: "First"))
        let entries = engine.state(for: "s").entries
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries.first?.id, rowID)
        XCTAssertEqual(entries.first?.tool?.id, "one")
    }

    func testStartLearningRealIDPreservesRowAndSeparatesNextCall() throws {
        let engine = TurnEngine()
        engine.apply(event("tool.start"))
        let rowID = try XCTUnwrap(engine.state(for: "s").entries.first?.id)
        engine.apply(event("tool.start", id: "one"))
        engine.apply(event("tool.start", id: "two"))
        let entries = engine.state(for: "s").entries
        XCTAssertEqual(entries.compactMap(\.tool).map(\.id), ["one", "two"])
        XCTAssertEqual(entries.first?.id, rowID)
    }
    func testMissingIDCompletionStillClosesPendingNamedCall() {
        let engine = TurnEngine()
        engine.apply(event("tool.start", id: "one"))
        engine.apply(event("tool.complete", result: "First"))
        let tools = engine.state(for: "s").entries.compactMap(\.tool)
        XCTAssertEqual(tools.map(\.id), ["one"])
        XCTAssertEqual(tools.first?.resultText, "First")
        XCTAssertFalse(tools.first?.isRunning ?? true)
    }
}
