import Foundation
import XCTest

// `@testable` on the kit as well as the app, for the same reason
// `BranchOrdinalProjectionTests` needs it: `TranscriptPage`'s memberwise
// initialiser is internal to the kit, and these tests hand `applyTranscript` a
// synthetic page.
@testable import HermesMobile
@testable import HermesServeKit

/// BUG-019 — `ChatModel.entries` is `history + live.entries + outboundEntries`
/// with no id-level and no text-level dedup, and `applyTranscript` is the only
/// writer of `history`. It replaced `history` without evicting the live entries
/// the new page supersedes, so a transcript reload landing on a session whose
/// turns the engine is still holding rendered each of them twice — for the life
/// of the process, since nothing else ever evicts a settled live entry.
@MainActor
final class ChatTranscriptDuplicationTests: XCTestCase {

    private func row(_ id: Int, _ role: String, _ text: String) -> TranscriptMessage {
        TranscriptMessage(json: .object([
            "id": .number(Double(id)),
            "role": .string(role),
            "content": .string(text),
            "timestamp": .number(1_787_000_000),
        ]))
    }

    private func page(_ storedID: String, _ messages: [TranscriptMessage]) -> TranscriptPage {
        TranscriptPage(
            sessionID: storedID,
            messages: messages,
            limit: nil,
            offset: 0,
            returned: messages.count
        )
    }

    /// T4 — a reloaded transcript does not double the turn the engine is still
    /// holding.
    func testReloadDoesNotDoubleASettledLiveTurn() async throws {
        let harness = await AppHarness.make()
        try await harness.openSocket()
        let storedID = "20260819_010000_dupe"
        let chat = harness.chat(storedID: storedID)
        await chat.open()

        let runtimeID = try XCTUnwrap(chat.runtimeSessionID)
        await harness.backend.emitAssistantText("the migration finished", sessionID: runtimeID)
        await harness.backend.emit("message.complete", sessionID: runtimeID, payload: .object([
            "status": .string("complete"),
            "text": .string("the migration finished"),
        ]))
        let settled = await waitUntil {
            chat.live.entries.contains { $0.text == "the migration finished" && !$0.isStreaming }
        }
        XCTAssertTrue(settled, "the live turn never settled — the duplication this test is about needs one")

        chat.applyTranscript(page(storedID, [
            row(1, "user", "run the migration"),
            row(2, "assistant", "the migration finished"),
        ]))

        XCTAssertEqual(
            chat.entries.filter { $0.text == "the migration finished" }.count,
            1,
            "history and live.entries both carry the settled turn; `entries` concatenates them with no dedup"
        )
        XCTAssertEqual(
            chat.entries.filter { $0.kind == .user && $0.text == "run the migration" }.count,
            1
        )

        await harness.tearDown()
    }

    /// T5 — the rail for 2.2a's one real risk: the clear must not blank a turn
    /// that is still streaming into an empty transcript, and the engine's
    /// streaming pointer must stay consistent with what is on screen. A
    /// following delta has to extend exactly one bubble, not open a second.
    func testReloadDuringAStreamingTurnLeavesOneCoherentBubble() async throws {
        let harness = await AppHarness.make()
        try await harness.openSocket()
        let storedID = "20260819_010001_midstream"
        let chat = harness.chat(storedID: storedID)
        await chat.open()

        let runtimeID = try XCTUnwrap(chat.runtimeSessionID)
        await harness.backend.emitAssistantText("halfway thro", sessionID: runtimeID)
        let streaming = await waitUntil { chat.live.entries.contains { $0.isStreaming } }
        XCTAssertTrue(streaming, "no streaming turn — the risk this test covers needs one")

        // A page that knows nothing about the turn in flight.
        chat.applyTranscript(page(storedID, [row(1, "user", "start the job")]))

        await harness.backend.emit("message.delta", sessionID: runtimeID, payload: .object([
            "text": .string("ugh. Done."),
        ]))
        await harness.backend.emit("message.complete", sessionID: runtimeID, payload: .object([
            "status": .string("complete"),
            "text": .string("halfway through. Done."),
        ]))
        let done = await waitUntil {
            chat.live.entries.contains { $0.kind == .assistant && !$0.isStreaming && !$0.text.isEmpty }
        }
        XCTAssertTrue(done, "the streaming turn never settled after the reload")

        XCTAssertFalse(chat.entries.isEmpty, "the reload must not leave the transcript with nothing at all")
        XCTAssertEqual(
            chat.entries.filter { $0.kind == .assistant }.count,
            1,
            "the delta after the reload opened a second bubble beside the one that was streaming"
        )
        XCTAssertEqual(
            chat.entries.last { $0.kind == .assistant }?.text,
            "halfway through. Done."
        )
        XCTAssertFalse(chat.entries.contains { $0.isStreaming })

        await harness.tearDown()
    }
}
