import XCTest
@testable import HermesServeKit

/// Desired behavior; expected to fail on the unchanged trial client.
final class LiveTrialDiagnosticsTests: XCTestCase {
    private func event(_ type: String, _ payload: [String: JSONValue]) throws -> GatewayEvent {
        let frame: JSONValue = .object([
            "jsonrpc": .string("2.0"), "method": .string("event"),
            "params": .object(["type": .string(type), "session_id": .string("trial"), "payload": .object(payload)])
        ])
        guard case .event(let result) = try JSONRPCCodec.decodeFrame(JSONRPCCodec.encodeLine(frame)) else {
            throw NSError(domain: "diagnostic", code: 1)
        }
        return result
    }

    func testPostToolReasoningStaysAfterToolsFollowingResume() throws {
        let engine = TurnEngine()
        let result = SessionAPI.decodeResume(.object([
            "session_id": .string("trial"), "running": .bool(true),
            "info": .object([:]), "inflight": .object([
                "user": .string("Investigate"), "assistant": .string("I will inspect the sources."),
                "streaming": .bool(true)
            ])
        ]), requested: "stored-trial")
        engine.applyResumeProjection(sessionID: "trial", result: result, trailingUserTexts: ["Investigate"])
        engine.apply(try event("tool.start", ["tool_id": .string("tool-1"), "name": .string("web_search")]))
        engine.apply(try event("tool.complete", ["tool_id": .string("tool-1"), "name": .string("web_search"), "result": .string("Found sources")]))
        engine.apply(try event("reasoning.delta", ["text": .string("Now evaluate the returned sources.")]))
        engine.flush()
        let entries = engine.state(for: "trial").entries
        let toolIndex = try XCTUnwrap(entries.firstIndex { $0.kind == .tool })
        let reasoningIndex = try XCTUnwrap(entries.firstIndex { $0.reasoning.contains("Now evaluate") })
        XCTAssertGreaterThan(reasoningIndex, toolIndex, "reasoning received after the tool must not be appended above it")
    }

    func testPersistedSteerIsVisibleUserContent() {
        let row = TranscriptMessage(json: .object([
            "id": .number(44), "role": .string("user"),
            "content": .string("Use the hashtag"), "display_kind": .string("steer")
        ]))
        XCTAssertFalse(row.isHidden)
        XCTAssertFalse(row.isBookkeeping, "a user's mid-turn correction must survive transcript hydration")
    }
}
