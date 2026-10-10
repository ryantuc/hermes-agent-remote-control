import XCTest
@testable import HermesServeKit

final class OrphanToolCompletionOrderingTests: XCTestCase {
    private let session = "s"

    private func event(_ type: String, _ payload: [String: JSONValue] = [:], seq: Int? = nil) -> GatewayEvent {
        var params: [String: JSONValue] = ["type": .string(type), "session_id": .string(session), "payload": .object(payload)]
        if let seq { params["seq"] = .number(Double(seq)) }
        return GatewayEvent(type: type, sessionID: session, payload: .object(payload), params: .object(params))
    }

    private func complete(_ id: String, seq: Int? = nil) -> GatewayEvent {
        event("tool.complete", ["tool_id": .string(id), "name": .string("web_search"), "result": .string("Found sources")], seq: seq)
    }

    func testResumeWithoutToolStartPlacesNewThinkingAfterCompletedTool() throws {
        let engine = TurnEngine()
        let resume = SessionAPI.decodeResume(.object([
            "session_id": .string(session), "running": .bool(true), "info": .object([:]),
            "inflight": .object(["user": .string("Research"), "assistant": .string("Before"), "streaming": .bool(true)])
        ]), requested: "stored")
        engine.applyResumeProjection(sessionID: session, result: resume, trailingUserTexts: ["Research"])
        XCTAssertFalse(engine.sharedSessionSupported, "This recovery must work on official backends without the optional extension")
        engine.apply(complete("missed-start"))
        engine.apply(event("reasoning.delta", ["text": .string("Evaluate returned sources")]))
        engine.apply(event("message.delta", ["text": .string("After")]))
        engine.flush()
        let entries = engine.state(for: session).entries
        XCTAssertEqual(entries.map(\.kind), [.assistant, .tool, .assistant])
        XCTAssertEqual(entries.map(\.reasoning), ["", "", "Evaluate returned sources"])
        XCTAssertEqual(entries.map(\.text), ["Before", "", "After"])
        XCTAssertFalse(try XCTUnwrap(entries.first).isStreaming)
        engine.apply(event("message.complete", ["text": .string("BeforeAfter")]))
        XCTAssertEqual(engine.state(for: session).entries.filter { $0.kind == .assistant }.map(\.text), ["Before", "After"])
    }

    func testOrphanCompletionsFlushEarlierThinkingAndDoNotCreateEmptySegments() {
        let engine = TurnEngine()
        engine.apply(event("message.start"))
        engine.apply(event("reasoning.delta", ["text": .string("Before tools")]))
        // No explicit flush: the tool frame must preserve the delta boundary itself.
        engine.apply(complete("one"))
        engine.apply(complete("two"))
        engine.apply(event("reasoning.delta", ["text": .string("After tools")]))
        engine.flush()
        let entries = engine.state(for: session).entries
        XCTAssertEqual(entries.map(\.kind), [.assistant, .tool, .tool, .assistant])
        XCTAssertEqual(entries.map(\.reasoning), ["Before tools", "", "", "After tools"])
        XCTAssertEqual(entries.filter { $0.isStreaming }.count, 1)
    }

    func testReplayAfterCheckpointPreservesOrphanCompletionBoundary() throws {
        let before = TurnEngine()
        before.setReplayEpoch("e")
        before.apply(event("message.start", seq: 1))
        before.apply(event("message.delta", ["text": .string("Before")], seq: 2))
        let checkpoint = try XCTUnwrap(before.checkpoint(sessionID: session))
        let disk = try JSONDecoder().decode(TurnCheckpoint.self, from: JSONEncoder().encode(checkpoint))
        let after = TurnEngine()
        after.setReplayEpoch("e")
        XCTAssertTrue(after.beginCheckpointRecovery(disk))
        let tool = complete("one", seq: 3)
        let thought = event("reasoning.delta", ["text": .string("After")], seq: 4)
        let replay = try XCTUnwrap(SessionEventReplay(json: .object([
            "epoch": .string("e"), "truncated": .bool(false), "events": .array([tool.params, thought.params])
        ])))
        XCTAssertTrue(after.finishEventRecovery(sessionID: session, replay: replay, checkpoint: disk))
        after.flush()
        let entries = after.state(for: session).entries
        XCTAssertEqual(entries.map(\.kind), [.assistant, .tool, .assistant])
        XCTAssertEqual(entries.map(\.reasoning), ["", "", "After"])
    }

    func testDuplicateCompletionDoesNotSplitNewerAssistantSegment() {
        let engine = TurnEngine()
        engine.apply(event("message.start"))
        engine.apply(event("message.delta", ["text": .string("Before")]))
        engine.apply(complete("one"))
        engine.apply(event("reasoning.delta", ["text": .string("First")]))
        engine.apply(complete("one"))
        engine.apply(event("reasoning.delta", ["text": .string(" second")]))
        engine.flush()
        let entries = engine.state(for: session).entries
        XCTAssertEqual(entries.map(\.kind), [.assistant, .tool, .assistant])
        XCTAssertEqual(entries.last?.reasoning, "First second")
        XCTAssertEqual(entries.filter { $0.tool?.id == "one" }.count, 1)
    }

    func testPromotedLegacyCompletionRemainsIdempotentAfterCheckpoint() throws {
        let before = TurnEngine()
        before.setReplayEpoch("e")
        before.apply(event("message.start", seq: 1))
        before.apply(event("tool.start", ["name": .string("web_search")], seq: 2))
        let rowID = try XCTUnwrap(before.state(for: session).entries.first?.id)
        before.apply(complete("real", seq: 3))
        before.apply(event("reasoning.delta", ["text": .string("First")], seq: 4))
        let checkpoint = try XCTUnwrap(before.checkpoint(sessionID: session))
        let disk = try JSONDecoder().decode(TurnCheckpoint.self, from: JSONEncoder().encode(checkpoint))
        let after = TurnEngine()
        after.setReplayEpoch("e")
        XCTAssertTrue(after.beginCheckpointRecovery(disk))
        let repeated = complete("real", seq: 5)
        let thought = event("reasoning.delta", ["text": .string(" second")], seq: 6)
        let replay = try XCTUnwrap(SessionEventReplay(json: .object([
            "epoch": .string("e"), "truncated": .bool(false), "events": .array([repeated.params, thought.params])
        ])))
        XCTAssertTrue(after.finishEventRecovery(sessionID: session, replay: replay, checkpoint: disk))
        after.flush()
        let entries = after.state(for: session).entries
        XCTAssertEqual(entries.map(\.kind), [.tool, .assistant])
        XCTAssertEqual(entries.first?.id, rowID)
        XCTAssertEqual(entries.first?.tool?.id, "real")
        XCTAssertEqual(entries.last?.reasoning, "First second")
    }
    func testCompletionOfKnownToolDoesNotSplitNewerAssistantSegment() {
        let engine = TurnEngine()
        engine.apply(event("message.start"))
        engine.apply(event("tool.start", ["tool_id": .string("one"), "name": .string("web_search")]))
        engine.apply(event("reasoning.delta", ["text": .string("First")]))
        engine.apply(complete("one"))
        engine.apply(event("reasoning.delta", ["text": .string(" second")]))
        engine.flush()
        let entries = engine.state(for: session).entries
        XCTAssertEqual(entries.map(\.kind), [.tool, .assistant])
        XCTAssertEqual(entries.last?.reasoning, "First second")
    }
}
