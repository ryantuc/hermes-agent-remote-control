import Foundation
import HermesServeKit
import XCTest

@testable import HermesMobile

/// Desktop parity at the composer: `/btw <question>` asks on the side through `prompt.btw` (Desktop's own path, `apps/desktop/src/app/session/hooks/use-prompt-actions/slash.ts:555-600`), never as a turn and never through the slash worker, and the `btw.complete` answer appears in the chat. FEAT-040 had listed the command as unavailable on the phone.
@MainActor
final class SideQuestionSlashTests: XCTestCase {
    private func harness() async throws -> (AppHarness, ChatModel) {
        let harness = await AppHarness.make()
        try await harness.openSocket()
        let chat = harness.chat(storedID: "20261002_btw")
        await chat.open()
        let bound = await waitUntil { chat.runtimeSessionID != nil }
        XCTAssertTrue(bound)
        await harness.backend.stub("commands.catalog") { _ in .object([
            "pairs": .array([.array([.string("/btw"), .string("Ask a side question")])]),
        ]) }
        await harness.backend.stub("complete.slash") { _ in .object(["items": .array([]), "replace_from": .number(1)]) }
        await harness.backend.stub("prompt.btw") { _ in .object(["task_id": .string("btw_1a2b3c")]) }
        return (harness, chat)
    }

    private func type(_ text: String, into chat: ChatModel) {
        chat.draft = text
        chat.slashCompletion.update(text: text, selection: NSRange(location: text.utf16.count, length: 0),
            isComposing: false, isPaste: false, isExternal: false,
            scope: chat.slashCompletionScope, api: chat.slashCommandAPI)
    }

    func testBtwAsksOnTheSideWithoutATurn() async throws {
        let (harness, chat) = try await harness()
        let sid = try XCTUnwrap(chat.runtimeSessionID)
        // Mid-turn is exactly when a side question is asked.
        await harness.backend.emit("message.start", sessionID: sid)
        _ = await waitUntil { chat.live.isBusy }

        type("/btw why sqlite and not postgres?", into: chat)
        chat.sendTapped()

        let asked = await waitUntil { await harness.backend.callCount("prompt.btw") == 1 }
        XCTAssertTrue(asked, "the side question never went out: \(chat.errorMessage ?? "no error")")
        let call = await harness.backend.calls(to: "prompt.btw").first
        XCTAssertEqual(call?.params["text"]?.stringValue, "why sqlite and not postgres?")
        XCTAssertEqual(call?.sessionID, sid)
        _ = await waitUntil { !chat.isExecutingSlash }
        let submits = await harness.backend.callCount("prompt.submit")
        XCTAssertEqual(submits, 0, "a side question must not become a turn")
        let execs = await harness.backend.callCount("slash.exec")
        XCTAssertEqual(execs, 0, "the slash worker prints the answer past its capture window (#99065)")
        XCTAssertEqual(chat.draft, "")
        XCTAssertNil(chat.errorMessage)

        await harness.backend.emit("btw.complete", sessionID: sid, payload: .object([
            "task_id": .string("btw_1a2b3c"), "question": .string("why sqlite and not postgres?"),
            "text": .string("The data is local and single-writer."),
        ]))
        let answered = await waitUntil { chat.entries.contains { $0.text.contains("The data is local and single-writer.") } }
        XCTAssertTrue(answered, "the side answer never reached the chat")
        XCTAssertTrue(chat.live.isBusy, "the running turn is untouched")

        await harness.tearDown()
    }

    func testBtwWithoutAQuestionKeepsTheDraft() async throws {
        let (harness, chat) = try await harness()

        type("/btw", into: chat)
        chat.sendTapped()

        _ = await waitUntil { !chat.isExecutingSlash }
        let asked = await harness.backend.callCount("prompt.btw")
        XCTAssertEqual(asked, 0)
        XCTAssertEqual(chat.draft, "/btw")
        XCTAssertEqual(chat.errorMessage, "Use /btw followed by your question.")

        await harness.tearDown()
    }
}
