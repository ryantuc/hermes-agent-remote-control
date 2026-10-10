import XCTest

@testable import HermesServeKit

/// BUG-074 leg A — the assistant answer had no ceiling. Reasoning is bounded at 256 KB with a head
/// drop (`ChatEntry.appendReasoning`); the streamed answer and its pre-flush `DeltaBuffer.assistant`
/// grew without limit, on the `@Observable` live state, for as long as a stream ran or a stalled
/// flush loop let the buffer fill.
final class AssistantTextBoundTests: XCTestCase {
    private let session = "a1b2c3d4"
    private let chunk = String(repeating: "a", count: 64 * 1024)
    /// Enough 64 KB deltas to go half a megabyte past the ceiling.
    private var overflowingChunks: Int { ChatEntry.textLimit / (64 * 1024) + 8 }

    private func event(_ type: String, payload: JSONValue = .object([:])) -> GatewayEvent {
        GatewayEvent(type: type, sessionID: session, payload: payload, params: .object([
            "type": .string(type), "session_id": .string(session), "payload": payload,
        ]))
    }

    private func delta(_ text: String) -> GatewayEvent {
        event("message.delta", payload: .object(["text": .string(text)]))
    }

    private func answer(_ engine: TurnEngine) -> ChatEntry? {
        engine.state(for: session).entries.last { $0.kind == .assistant }
    }

    /// The flush loop running normally: every delta is applied to the entry as it arrives.
    func testAStreamedAnswerIsBoundedAndKeepsItsTail() throws {
        let engine = TurnEngine()
        engine.apply(event("message.start"))
        for _ in 0..<overflowingChunks {
            engine.apply(delta(chunk))
            engine.flush()
        }
        engine.apply(delta("THE END"))
        engine.flush()

        let entry = try XCTUnwrap(answer(engine))
        XCTAssertLessThanOrEqual(entry.text.utf8.count, ChatEntry.textLimit)
        XCTAssertTrue(entry.text.hasPrefix(ChatEntry.textElision), "the head is what goes, and it says so")
        XCTAssertTrue(entry.text.hasSuffix("aTHE END"), "the newest text is what stays")
        XCTAssertTrue(entry.isStreaming)
    }

    /// The flush loop stalled: every delta lands in the buffer, which must not hold them all.
    func testABufferThatIsNeverFlushedIsBoundedToo() throws {
        let engine = TurnEngine()
        engine.apply(event("message.start"))
        engine.apply(delta("FIRST WORDS "))
        engine.flush()
        for _ in 0..<overflowingChunks { engine.apply(delta(chunk)) }
        engine.apply(delta("THE END"))
        engine.flush()

        let entry = try XCTUnwrap(answer(engine))
        XCTAssertLessThanOrEqual(entry.text.utf8.count, ChatEntry.textLimit)
        XCTAssertTrue(entry.text.hasPrefix(ChatEntry.textElision))
        XCTAssertFalse(entry.text.contains("FIRST WORDS"), "text older than what the buffer dropped goes too")
        XCTAssertTrue(entry.text.hasSuffix("aTHE END"))
    }

    /// The cut never splits a multi-byte character, whatever the alignment of the overflow.
    func testTheHeadDropNeverSplitsACharacter() throws {
        let engine = TurnEngine()
        engine.apply(event("message.start"))
        // Three-byte and four-byte scalars, so the byte budget lands mid-scalar on some cut.
        let wide = String(repeating: "語🙂", count: 64 * 1024 / 7)
        for _ in 0..<overflowingChunks {
            engine.apply(delta(wide))
            engine.flush()
        }
        let entry = try XCTUnwrap(answer(engine))
        XCTAssertLessThanOrEqual(entry.text.utf8.count, ChatEntry.textLimit)
        let body = entry.text.dropFirst(ChatEntry.textElision.count)
        XCTAssertFalse(body.unicodeScalars.contains("\u{FFFD}"), "no replacement character from a split scalar")
        XCTAssertTrue(body.unicodeScalars.allSatisfy { $0 == "語" || $0 == "🙂" })
    }

    /// Below the ceiling nothing changes.
    func testAnAnswerUnderTheCeilingIsUntouched() throws {
        let engine = TurnEngine()
        engine.apply(event("message.start"))
        for index in 0..<4 { engine.apply(delta("part \(index); ")) }
        engine.flush()
        XCTAssertEqual(try XCTUnwrap(answer(engine)).text, "part 0; part 1; part 2; part 3; ")
    }

    /// The bound is on the STREAM; the authoritative final text still replaces it whole.
    func testTheFinalTextStillReplacesABoundedStream() throws {
        let engine = TurnEngine()
        engine.apply(event("message.start"))
        for _ in 0..<overflowingChunks {
            engine.apply(delta(chunk))
            engine.flush()
        }
        engine.apply(event("message.complete", payload: .object([
            "text": .string("The final answer."), "status": .string("complete"),
        ])))
        let entry = try XCTUnwrap(answer(engine))
        XCTAssertEqual(entry.text, "The final answer.")
        XCTAssertFalse(entry.isStreaming)
        XCTAssertEqual(entry.status, "complete")
    }
}
