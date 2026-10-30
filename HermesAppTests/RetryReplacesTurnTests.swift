import Foundation
import XCTest

@testable import HermesMobile
@testable import HermesServeKit

/// Desktop parity at the chat. Retry used to submit the same text as a fresh turn (`ChatModel.resendPrecedingUserTurn`, whose comment said "the protocol has no replace-a-turn call"), so a 429 or a dropped connection left the prompt twice in the transcript and in what the model saw. `prompt.submit` has replaced a turn by durable row on every supported backend (`truncate_before_row_id` + `confirm_truncate`, `tui_gateway/contracts/prompt_voice.py:27-55`, present on current and older backends). Edit & resend is the same submit with the corrected text.
@MainActor
final class RetryReplacesTurnTests: XCTestCase {
    private let storedID = "20261002_retry"

    private func row(_ id: Int, _ role: String, _ content: JSONValue) -> TranscriptMessage {
        TranscriptMessage(json: .object([
            "id": .number(Double(id)), "role": .string(role), "content": content, "timestamp": .number(1_790_000_000),
        ]))
    }

    /// A bound chat whose transcript holds one finished turn: user row 41, assistant row 42.
    private func chatWithHistory() async throws -> (AppHarness, ChatModel) {
        let harness = await AppHarness.make()
        try await harness.openSocket()
        let chat = harness.chat(storedID: storedID)
        await chat.open()
        let bound = await waitUntil { chat.runtimeSessionID != nil }
        XCTAssertTrue(bound)
        chat.applyTranscript(TranscriptPage(sessionID: storedID, messages: [
            row(41, "user", .string("first question")),
            row(42, "assistant", .string("first answer")),
        ]))
        chat.errorMessage = nil
        XCTAssertEqual(chat.entries.map(\.id), ["rest-41", "rest-42"])
        return (harness, chat)
    }

    func testRetryOfAHistoryTurnReplacesItInsteadOfAppending() async throws {
        let (harness, chat) = try await chatWithHistory()

        chat.resendPrecedingUserTurn(before: "rest-42")

        let submitted = await waitUntil { await harness.backend.callCount("prompt.submit") == 1 }
        XCTAssertTrue(submitted, "the retry never reached prompt.submit: \(chat.errorMessage ?? "no error")")
        let params = await harness.backend.calls(to: "prompt.submit").first?.params
        XCTAssertEqual(params?["text"]?.stringValue, "first question")
        XCTAssertEqual(params?["truncate_before_row_id"]?.intValue, 41, "a retry that does not name the turn appends a duplicate")
        XCTAssertEqual(params?["confirm_truncate"]?.boolValue, true)

        let acked = await waitUntil { !chat.isSending }
        XCTAssertTrue(acked)
        XCTAssertFalse(chat.entries.contains { $0.id == "rest-41" || $0.id == "rest-42" },
                       "the replaced turn is still on screen: \(chat.entries.map(\.id))")
        XCTAssertEqual(chat.entries.filter { $0.kind == .user && $0.text == "first question" }.count, 1,
                       "the prompt shows twice: \(chat.entries.map(\.text))")

        await harness.tearDown()
    }

    /// The most common retry is of the turn just sent from this phone, which lives in the engine, not the REST history; its row comes from the submit's own ack.
    func testRetryOfALiveTurnUsesTheRowItsAckNamed() async throws {
        let harness = await AppHarness.make()
        try await harness.openSocket()
        let chat = harness.chat(storedID: storedID)
        await chat.open()
        let bound = await waitUntil { chat.runtimeSessionID != nil }
        XCTAssertTrue(bound)
        let sid = try XCTUnwrap(chat.runtimeSessionID)
        await harness.backend.stub("prompt.submit") { _ in
            .object(["status": .string("streaming"), "user_row_id": .number(7)])
        }

        chat.draft = "summarise the repo"
        chat.sendTapped()
        _ = await waitUntil { await harness.backend.callCount("prompt.submit") == 1 }
        _ = await waitUntil { !chat.isSending }
        await harness.backend.emitAssistantText("Here is a summary.", sessionID: sid)
        await harness.backend.emit("message.complete", sessionID: sid, payload: .object([
            "text": .string("Here is a summary."), "status": .string("complete"),
        ]))
        let settled = await waitUntil { !chat.live.isBusy && chat.live.entries.contains { $0.kind == .assistant } }
        XCTAssertTrue(settled)
        let reply = try XCTUnwrap(chat.live.entries.last { $0.kind == .assistant })

        chat.resendPrecedingUserTurn(before: reply.id)

        let resent = await waitUntil { await harness.backend.callCount("prompt.submit") == 2 }
        XCTAssertTrue(resent)
        let params = await harness.backend.calls(to: "prompt.submit").last?.params
        XCTAssertEqual(params?["truncate_before_row_id"]?.intValue, 7)
        XCTAssertEqual(params?["text"]?.stringValue, "summarise the repo")
        _ = await waitUntil { !chat.isSending }
        XCTAssertFalse(chat.entries.contains { $0.id == reply.id }, "the replaced reply is still on screen")
        XCTAssertEqual(chat.entries.filter { $0.kind == .user }.count, 1, "\(chat.entries.map(\.text))")

        await harness.tearDown()
    }

    /// Desktop's degrade (`rewind.ts:285-327`): with no durable address and none found by content, resubmit plainly rather than guess a cut. REST is dead in this harness, so the content lookup cannot answer.
    func testWithoutAKnownRowRetryDegradesToAPlainResend() async throws {
        let harness = await AppHarness.make()
        try await harness.openSocket()
        let chat = harness.chat(storedID: storedID)
        await chat.open()
        _ = await waitUntil { chat.runtimeSessionID != nil }
        let sid = try XCTUnwrap(chat.runtimeSessionID)

        chat.draft = "hello"
        chat.sendTapped()
        _ = await waitUntil { await harness.backend.callCount("prompt.submit") == 1 }
        _ = await waitUntil { !chat.isSending }
        await harness.backend.emitAssistantText("hi", sessionID: sid)
        await harness.backend.emit("message.complete", sessionID: sid, payload: .object([
            "text": .string("hi"), "status": .string("complete"),
        ]))
        _ = await waitUntil { !chat.live.isBusy }
        let reply = try XCTUnwrap(chat.live.entries.last { $0.kind == .assistant })

        chat.resendPrecedingUserTurn(before: reply.id)

        let resent = await waitUntil { await harness.backend.callCount("prompt.submit") == 2 }
        XCTAssertTrue(resent)
        let params = await harness.backend.calls(to: "prompt.submit").last?.params
        XCTAssertNil(params?["truncate_before_row_id"])
        XCTAssertNil(params?["confirm_truncate"], "consent without a target is refused with 4004")

        await harness.tearDown()
    }

    /// A turn with attachments cannot be rebuilt from the transcript; replacing it with its text alone would drop the images from what the model sees.
    func testATurnWithImagesIsResentWithoutACut() async throws {
        let harness = await AppHarness.make()
        try await harness.openSocket()
        let chat = harness.chat(storedID: storedID)
        await chat.open()
        _ = await waitUntil { chat.runtimeSessionID != nil }
        chat.applyTranscript(TranscriptPage(sessionID: storedID, messages: [
            row(51, "user", .array([
                .object(["type": .string("text"), "text": .string("what is this?")]),
                .object(["type": .string("image_url"), "image_url": .object(["url": .string("data:image/png;base64,AAAA")])]),
            ])),
            row(52, "assistant", .string("a cat")),
        ]))
        XCTAssertFalse(chat.canEdit(entryID: "rest-51"))

        chat.resendPrecedingUserTurn(before: "rest-52")

        _ = await waitUntil { await harness.backend.callCount("prompt.submit") == 1 }
        let params = await harness.backend.calls(to: "prompt.submit").first?.params
        XCTAssertNil(params?["truncate_before_row_id"])

        await harness.tearDown()
    }

    /// Retry repeats a turn's commands, so off the demo a turn that wrote a file still asks for a hold first.
    func testRetryAfterALiveTurnThatWroteAFileStillAsksFirst() async throws {
        let harness = await AppHarness.make()
        try await harness.openSocket()
        let chat = harness.chat(storedID: storedID)
        await chat.open()
        let bound = await waitUntil { chat.runtimeSessionID != nil }
        XCTAssertTrue(bound)
        let sid = try XCTUnwrap(chat.runtimeSessionID)

        chat.draft = "save the notes"
        chat.sendTapped()
        _ = await waitUntil { await harness.backend.callCount("prompt.submit") == 1 }
        _ = await waitUntil { !chat.isSending }
        await harness.backend.emit("message.start", sessionID: sid)
        await harness.backend.emit("tool.start", sessionID: sid, payload: .object([
            "tool_id": .string("write-1"), "name": .string("write_file"), "context": .string("notes.md"),
        ]))
        await harness.backend.emit("tool.complete", sessionID: sid, payload: .object([
            "tool_id": .string("write-1"), "name": .string("write_file"), "result": .string("Wrote notes.md"), "duration_s": .number(0.1),
        ]))
        await harness.backend.emit("message.delta", sessionID: sid, payload: .object(["text": .string("Saved.")]))
        await harness.backend.emit("message.complete", sessionID: sid, payload: .object([
            "text": .string("Saved."), "status": .string("complete"),
        ]))
        let settled = await waitUntil { !chat.live.isBusy && chat.entries.contains { $0.kind == .assistant && $0.status == "complete" } }
        XCTAssertTrue(settled)
        XCTAssertTrue(chat.entries.contains { $0.tool?.name == "write_file" }, "precondition: the write never reached the transcript: \(chat.entries.map(\.id))")
        let reply = try XCTUnwrap(chat.entries.last { $0.kind == .assistant && $0.status == "complete" })

        XCTAssertTrue(chat.turnMutatedState(before: reply.id), "a live turn that wrote a file must still ask before Retry repeats it")

        await harness.tearDown()
    }

    // MARK: Edit & resend

    func testEditLoadsTheTurnAndSendReplacesIt() async throws {
        let (harness, chat) = try await chatWithHistory()

        XCTAssertTrue(chat.canEdit(entryID: "rest-41"))
        XCTAssertFalse(chat.canEdit(entryID: "rest-42"), "only a user turn is edited")
        XCTAssertTrue(chat.beginEditing(entryID: "rest-41"))
        XCTAssertEqual(chat.draft, "first question")
        XCTAssertEqual(chat.editingEntryID, "rest-41")

        chat.draft = "first question, with the typo fixed"
        chat.sendTapped()

        let submitted = await waitUntil { await harness.backend.callCount("prompt.submit") == 1 }
        XCTAssertTrue(submitted, "\(chat.errorMessage ?? "no error")")
        let params = await harness.backend.calls(to: "prompt.submit").first?.params
        XCTAssertEqual(params?["text"]?.stringValue, "first question, with the typo fixed")
        XCTAssertEqual(params?["truncate_before_row_id"]?.intValue, 41)
        XCTAssertEqual(params?["confirm_truncate"]?.boolValue, true)
        XCTAssertNil(chat.editingEntryID)
        XCTAssertEqual(chat.draft, "")
        _ = await waitUntil { !chat.isSending }
        XCTAssertFalse(chat.entries.contains { $0.id == "rest-41" || $0.id == "rest-42" })

        await harness.tearDown()
    }

    /// The backend refuses a cut while a turn runs (`methods_prompt.py:676-677`, 4009 "session busy"); the edit waits rather than going out as a plain message.
    func testAnEditWhileATurnRunsKeepsTheDraft() async throws {
        let (harness, chat) = try await chatWithHistory()
        let sid = try XCTUnwrap(chat.runtimeSessionID)
        XCTAssertTrue(chat.beginEditing(entryID: "rest-41"))
        chat.draft = "first question, revised"
        await harness.backend.emit("message.start", sessionID: sid)
        _ = await waitUntil { chat.live.isBusy }

        chat.sendTapped()

        XCTAssertEqual(chat.draft, "first question, revised")
        XCTAssertEqual(chat.editingEntryID, "rest-41")
        XCTAssertNotNil(chat.errorMessage)
        let submits = await harness.backend.callCount("prompt.submit")
        XCTAssertEqual(submits, 0)

        await harness.tearDown()
    }

    func testCancellingAnEditClearsTheComposer() async throws {
        let (harness, chat) = try await chatWithHistory()
        XCTAssertTrue(chat.beginEditing(entryID: "rest-41"))
        chat.draft = "half-typed change"

        chat.cancelEditing()

        XCTAssertNil(chat.editingEntryID)
        XCTAssertEqual(chat.draft, "")
        let submits = await harness.backend.callCount("prompt.submit")
        XCTAssertEqual(submits, 0)

        await harness.tearDown()
    }
}
