import XCTest
@testable import HermesServeKit

final class SharedSessionRecoveryTests: XCTestCase {
    private func event(_ type: String, text: String = "", seq: Int = 0) -> GatewayEvent {
        let payload: JSONValue = .object(["text": .string(text), "name": .string("search"), "tool_id": .string("t")])
        return GatewayEvent(type: type, sessionID: "s", payload: payload, params: .object([
            "type": .string(type), "session_id": .string("s"), "payload": payload, "seq": .number(Double(seq))
        ]))
    }

    private func resume(_ extra: [String: JSONValue] = [:]) -> SessionResumeResult {
        var inflight: [String: JSONValue] = ["user": .string("continue"), "assistant": .string("BeforeAfter"), "streaming": .bool(true)]
        inflight.merge(extra) { _, new in new }
        return SessionAPI.decodeResume(.object(["session_id": .string("s"), "running": .bool(true), "inflight": .object(inflight)]), requested: "stored")
    }

    func testResumeRecognizesOriginalBeforeAssistantAndTools() {
        let history = [ChatEntry(id: "u", kind: .user, text: "continue"),
                       ChatEntry(id: "a", kind: .assistant, text: "Before"),
                       ChatEntry(id: "t", kind: .tool)]
        let engine = TurnEngine()
        engine.applyResumeProjection(sessionID: "s", result: resume(), trailingUserTexts: [], history: history)
        XCTAssertEqual(engine.state(for: "s").entries.map(\.text), ["After"])
        engine.apply(event("message.complete", text: "BeforeAfter"))
        XCTAssertEqual(engine.state(for: "s").entries.map(\.text), ["After"])
    }

    func testSameWordsInEarlierTurnDoNotEraseNewPrompt() {
        let history = [ChatEntry(id: "u", kind: .user, text: "continue", timestamp: Date(timeIntervalSince1970: 10)),
                       ChatEntry(id: "a", kind: .assistant, text: "Before")]
        let engine = TurnEngine()
        engine.applyResumeProjection(sessionID: "s", result: resume(["started_at": .number(20)]), trailingUserTexts: [], history: history)
        XCTAssertEqual(engine.state(for: "s").entries.first?.text, "continue")
        XCTAssertEqual(engine.state(for: "s").entries.first?.kind, .user)
    }

    func testIdenticalCorrectionsAreMatchedByOccurrence() {
        let history = [ChatEntry(id: "u", kind: .user, text: "continue"),
                       ChatEntry(id: "c", kind: .user, text: "again", noticeKind: "correction")]
        let result = resume(["corrections": .array([.string("again"), .string("again")]),
                             "correction_offsets": .array([.number(0), .number(6)])])
        let engine = TurnEngine()
        engine.applyResumeProjection(sessionID: "s", result: result, trailingUserTexts: [], history: history)
        let entries = engine.state(for: "s").entries
        XCTAssertEqual(entries.map(\.text), ["Before", "again", "After"])
        XCTAssertEqual(entries.filter { $0.kind == .user }.count, 1)
    }

    func testCorrectionOffsetsUseServerUnicodeCodePoints() {
        let result = resume(["assistant": .string("😀A"), "corrections": .array([.string("note")]),
                             "correction_offsets": .array([.number(1)])])
        let engine = TurnEngine()
        engine.applyResumeProjection(sessionID: "s", result: result, trailingUserTexts: ["continue"])
        XCTAssertEqual(engine.state(for: "s").entries.map(\.text), ["😀", "note", "A"])
    }

    func testAggregateCompletionDoesNotRepeatSealedText() {
        let engine = TurnEngine()
        engine.apply(event("message.start"))
        engine.apply(event("message.delta", text: "Before"))
        engine.apply(event("tool.start"))
        engine.apply(event("tool.complete"))
        engine.apply(event("reasoning.delta", text: "after tool"))
        engine.apply(event("message.delta", text: "After"))
        engine.apply(event("message.complete", text: "BeforeAfter"))
        let entries = engine.state(for: "s").entries
        XCTAssertEqual(entries.filter { $0.kind == .assistant }.map(\.text), ["Before", "After"])
        XCTAssertEqual(entries.last?.reasoning, "after tool")
        XCTAssertFalse(engine.state(for: "s").isBusy)
    }

    func testFinalResponseOnlyCompletionStillRenders() {
        let engine = TurnEngine()
        engine.apply(event("message.start"))
        engine.apply(event("message.delta", text: "Before"))
        engine.apply(event("tool.start"))
        engine.apply(event("message.complete", text: "Different final reply"))
        XCTAssertEqual(engine.state(for: "s").entries.filter { $0.kind == .assistant }.map(\.text), ["Before", "Different final reply"])
    }

    func testReplayMergesLiveFramesInSequenceExactlyOnce() throws {
        let engine = TurnEngine()
        engine.setReplayEpoch("epoch")
        engine.apply(event("message.start", seq: 1))
        engine.apply(event("message.delta", text: "A", seq: 2))
        XCTAssertEqual(engine.beginEventRecovery(sessionID: "s"), 2)
        XCTAssertNil(engine.apply(event("message.delta", text: "C", seq: 4)))
        let replay = try XCTUnwrap(SessionEventReplay(json: .object([
            "epoch": .string("epoch"), "truncated": .bool(false),
            "events": .array([event("message.delta", text: "B", seq: 3).params,
                              event("message.delta", text: "C", seq: 4).params])
        ])))
        XCTAssertTrue(engine.finishEventRecovery(sessionID: "s", replay: replay))
        engine.apply(event("message.delta", text: "C", seq: 4))
        engine.flush()
        XCTAssertEqual(engine.state(for: "s").entries.last?.text, "ABC")
    }

    func testTruncatedReplayRequiresSnapshot() throws {
        let engine = TurnEngine()
        engine.setReplayEpoch("epoch")
        engine.apply(event("message.start", seq: 1))
        XCTAssertEqual(engine.beginEventRecovery(sessionID: "s"), 1)
        let replay = try XCTUnwrap(SessionEventReplay(json: .object([
            "epoch": .string("epoch"), "truncated": .bool(true), "events": .array([])
        ])))
        XCTAssertFalse(engine.finishEventRecovery(sessionID: "s", replay: replay))
        engine.setReplayEpoch("replacement")
        XCTAssertNil(engine.beginEventRecovery(sessionID: "s"))
    }

    func testLegacyEventsNeedNoEpochOrSequence() {
        let engine = TurnEngine()
        engine.apply(event("message.start"))
        engine.apply(event("message.delta", text: "old server"))
        engine.apply(event("message.complete", text: "old server"))
        XCTAssertEqual(engine.state(for: "s").entries.last?.text, "old server")
        XCTAssertNil(engine.beginEventRecovery(sessionID: "s"))
    }

    func testOnlyTaggedSteerWrappersAreStripped() {
        let wrapped = "[OUT-OF-BAND USER MESSAGE — context]\nhello\n[/OUT-OF-BAND USER MESSAGE]"
        XCTAssertEqual(SteerDisplay.text(wrapped, kind: "steer"), "hello")
        XCTAssertEqual(SteerDisplay.text(wrapped, kind: ""), wrapped)
        XCTAssertEqual(SteerDisplay.text("hello", kind: "steer"), "hello")
    }
    func testImageOnlyAndImageCaptionResumeDoNotDuplicatePersistedInput() {
        for caption in ["", "look"] {
            let history = [ChatEntry(id: "u", kind: .user, text: caption, imageRefs: ["photo.png"]),
                           ChatEntry(id: "a", kind: .assistant, text: "Before")]
            let engine = TurnEngine()
            engine.applyResumeProjection(sessionID: "s", result: resume(["user": .string(caption + "\n@image:photo.png")]), trailingUserTexts: [], history: history)
            XCTAssertEqual(engine.state(for: "s").entries.map(\.text), ["After"])
            XCTAssertFalse(engine.state(for: "s").entries.contains { $0.kind == .user })
        }
    }
}
