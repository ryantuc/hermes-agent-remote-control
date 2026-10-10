import Foundation
import XCTest

@testable import HermesMobile
@testable import HermesServeKit

/// A replacing send (Retry or Edit & resend) cuts the target turn and everything after it (`truncate_before_row_id`). Two ways that went wrong: a failed replacement retried after newer turns were sent cut those newer turns too, and an edit begun while its turn ran lost its target when the end-of-turn reload renamed the turn.
@MainActor
final class EditRetryTailTests: XCTestCase {
    private let storedID = "20261003_edit_retry"

    private func row(_ id: Int, _ role: String, _ content: String) -> TranscriptMessage {
        TranscriptMessage(json: .object([
            "id": .number(Double(id)), "role": .string(role), "content": .string(content), "timestamp": .number(1_790_000_000),
        ]))
    }

    private func boundChat() async throws -> (AppHarness, ChatModel, String) {
        let harness = await AppHarness.make()
        try await harness.openSocket()
        let chat = harness.chat(storedID: storedID)
        await chat.open()
        let bound = await waitUntil { chat.runtimeSessionID != nil }
        XCTAssertTrue(bound)
        let sid = try XCTUnwrap(chat.runtimeSessionID)
        return (harness, chat, sid)
    }

    /// A bound chat whose transcript holds one finished turn: user row 41, assistant row 42.
    private func chatWithHistory() async throws -> (AppHarness, ChatModel, String) {
        let (harness, chat, sid) = try await boundChat()
        chat.applyTranscript(TranscriptPage(sessionID: storedID, messages: [
            row(41, "user", "first question"),
            row(42, "assistant", "first answer"),
        ]))
        chat.errorMessage = nil
        XCTAssertEqual(chat.entries.map(\.id), ["rest-41", "rest-42"])
        return (harness, chat, sid)
    }

    private func finishTurn(_ harness: AppHarness, _ chat: ChatModel, sid: String, reply: String) async {
        await harness.backend.emitAssistantText(reply, sessionID: sid)
        await harness.backend.emit("message.complete", sessionID: sid, payload: .object([
            "text": .string(reply), "status": .string("complete"),
        ]))
        _ = await waitUntil { !chat.live.isBusy && chat.live.entries.contains { $0.kind == .assistant } }
    }

    // MARK: A failed replacement retried later

    /// The person retries turn 41, the submit fails before any cut (4009), they send a newer question and get its answer, then tap Retry on the failed bubble. The cut must not take the newer turn with it.
    func testRetryingAFailedReplacementAfterANewerTurnDoesNotCutIt() async throws {
        let (harness, chat, sid) = try await chatWithHistory()
        await harness.backend.failNextRPC("prompt.submit", code: 4009, message: "session busy")

        chat.resendPrecedingUserTurn(before: "rest-42")
        let failed = await waitUntil { chat.outbound.first?.failure != nil && !chat.isSending }
        XCTAssertTrue(failed, "the first replacement never failed: \(chat.outbound.map(\.failure))")
        let failedID = try XCTUnwrap(chat.outbound.first?.id)
        let firstParams = await harness.backend.calls(to: "prompt.submit").first?.params
        XCTAssertEqual(firstParams?["truncate_before_row_id"]?.intValue, 41, "precondition: the first attempt was a replacement")

        await harness.backend.stub("prompt.submit") { _ in
            .object(["status": .string("streaming"), "user_row_id": .number(43)])
        }
        chat.draft = "a newer question"
        chat.sendTapped()
        let newerSent = await waitUntil { await harness.backend.callCount("prompt.submit") == 2 }
        XCTAssertTrue(newerSent)
        _ = await waitUntil { !chat.isSending }
        await finishTurn(harness, chat, sid: sid, reply: "a newer answer")

        chat.retryOutbound(id: failedID)

        let retried = await waitUntil { await harness.backend.callCount("prompt.submit") == 3 }
        XCTAssertTrue(retried, "the retry never reached prompt.submit: \(chat.errorMessage ?? "no error")")
        let params = await harness.backend.calls(to: "prompt.submit").last?.params
        XCTAssertNil(params?["truncate_before_row_id"], "the retry cut from row 41, which deletes the newer turn and its answer")
        XCTAssertNil(params?["confirm_truncate"], "consent without a target is refused with 4004")
        XCTAssertEqual(params?["text"]?.stringValue, "first question")
        _ = await waitUntil { !chat.isSending }
        XCTAssertTrue(chat.entries.contains { $0.kind == .user && $0.text == "a newer question" },
                      "the newer question left the screen: \(chat.entries.map(\.text))")
        XCTAssertTrue(chat.entries.contains { $0.kind == .assistant && $0.text == "a newer answer" },
                      "the newer answer left the screen: \(chat.entries.map(\.text))")
        XCTAssertNotNil(chat.errorMessage, "a replacement that went out as a plain message must say so")

        await harness.tearDown()
    }

    /// The same for an Edit & resend: the edit fails, a newer turn is sent, Retry on the failed edit must not cut the newer turn.
    func testRetryingAFailedEditAfterANewerTurnDoesNotCutIt() async throws {
        let (harness, chat, sid) = try await chatWithHistory()
        await harness.backend.failNextRPC("prompt.submit", code: 4009, message: "session busy")
        XCTAssertTrue(chat.beginEditing(entryID: "rest-41"))
        chat.draft = "first question, corrected"
        chat.sendTapped()
        let failed = await waitUntil { chat.outbound.first?.failure != nil && !chat.isSending }
        XCTAssertTrue(failed)
        let failedID = try XCTUnwrap(chat.outbound.first?.id)

        chat.draft = "a newer question"
        chat.sendTapped()
        _ = await waitUntil { await harness.backend.callCount("prompt.submit") == 2 }
        _ = await waitUntil { !chat.isSending }
        await finishTurn(harness, chat, sid: sid, reply: "a newer answer")

        chat.retryOutbound(id: failedID)

        let retried = await waitUntil { await harness.backend.callCount("prompt.submit") == 3 }
        XCTAssertTrue(retried)
        let params = await harness.backend.calls(to: "prompt.submit").last?.params
        XCTAssertNil(params?["truncate_before_row_id"], "the retried edit cut from row 41, which deletes the newer turn")
        XCTAssertEqual(params?["text"]?.stringValue, "first question, corrected")
        _ = await waitUntil { !chat.isSending }
        XCTAssertTrue(chat.entries.contains { $0.kind == .user && $0.text == "a newer question" },
                      "the newer question left the screen: \(chat.entries.map(\.text))")

        await harness.tearDown()
    }

    /// Guard: with nothing new after the target, Retry on a failed replacement still replaces (it is what the person agreed to when it was composed).
    func testRetryingAFailedReplacementWithNothingNewStillReplaces() async throws {
        let (harness, chat, _) = try await chatWithHistory()
        await harness.backend.failNextRPC("prompt.submit", code: 4009, message: "session busy")

        chat.resendPrecedingUserTurn(before: "rest-42")
        let failed = await waitUntil { chat.outbound.first?.failure != nil && !chat.isSending }
        XCTAssertTrue(failed)
        let failedID = try XCTUnwrap(chat.outbound.first?.id)

        chat.retryOutbound(id: failedID)

        let retried = await waitUntil { await harness.backend.callCount("prompt.submit") == 2 }
        XCTAssertTrue(retried)
        let params = await harness.backend.calls(to: "prompt.submit").last?.params
        XCTAssertEqual(params?["truncate_before_row_id"]?.intValue, 41)
        XCTAssertEqual(params?["confirm_truncate"]?.boolValue, true)

        await harness.tearDown()
    }

    // MARK: An edit across the end-of-turn reload

    /// The person sends a message, taps Edit on it while the turn still runs, the turn ends and the reload renames the live entry `rest-7`. Send must still replace row 7.
    func testAnEditBegunDuringTheTurnSurvivesTheEndOfTurnReload() async throws {
        let (harness, chat, sid) = try await boundChat()
        await harness.backend.stub("prompt.submit") { _ in
            .object(["status": .string("streaming"), "user_row_id": .number(7)])
        }
        chat.draft = "summarise the repo"
        chat.sendTapped()
        _ = await waitUntil { await harness.backend.callCount("prompt.submit") == 1 }
        _ = await waitUntil { !chat.isSending }
        let sent = try XCTUnwrap(chat.live.entries.first { $0.kind == .user })
        XCTAssertTrue(chat.beginEditing(entryID: sent.id))
        chat.draft = "summarise the repo, briefly"

        await finishTurn(harness, chat, sid: sid, reply: "Here is a summary.")
        // The reload the turn end triggers; REST is dead in this harness, so the test installs the page it would fetch.
        chat.applyTranscript(TranscriptPage(sessionID: storedID, messages: [
            row(7, "user", "summarise the repo"),
            row(8, "assistant", "Here is a summary."),
        ]))
        XCTAssertFalse(chat.entries.contains { $0.id == sent.id }, "precondition: the reload renamed the turn")

        chat.sendTapped()

        let submitted = await waitUntil { await harness.backend.callCount("prompt.submit") == 2 }
        XCTAssertTrue(submitted, "the edit never went out: \(chat.errorMessage ?? "no error")")
        let params = await harness.backend.calls(to: "prompt.submit").last?.params
        XCTAssertEqual(params?["text"]?.stringValue, "summarise the repo, briefly")
        XCTAssertEqual(params?["truncate_before_row_id"]?.intValue, 7)
        XCTAssertNil(chat.editingEntryID)
        XCTAssertEqual(chat.draft, "")

        await harness.tearDown()
    }

    /// The same when the ack named no row (an older backend): the reloaded row is found by its text, the rule the retry path's content lookup uses.
    func testAnEditWhoseTurnHadNoRowIsFoundByTextAfterTheReload() async throws {
        let (harness, chat, sid) = try await boundChat()
        chat.draft = "summarise the repo"
        chat.sendTapped()
        _ = await waitUntil { await harness.backend.callCount("prompt.submit") == 1 }
        _ = await waitUntil { !chat.isSending }
        let sent = try XCTUnwrap(chat.live.entries.first { $0.kind == .user })
        XCTAssertNil(sent.rowID, "precondition: the default stub's ack names no row")
        XCTAssertTrue(chat.beginEditing(entryID: sent.id))
        chat.draft = "summarise the repo, briefly"

        await finishTurn(harness, chat, sid: sid, reply: "Here is a summary.")
        chat.applyTranscript(TranscriptPage(sessionID: storedID, messages: [
            row(7, "user", "summarise the repo"),
            row(8, "assistant", "Here is a summary."),
        ]))

        chat.sendTapped()

        let submitted = await waitUntil { await harness.backend.callCount("prompt.submit") == 2 }
        XCTAssertTrue(submitted, "the edit never went out: \(chat.errorMessage ?? "no error")")
        let params = await harness.backend.calls(to: "prompt.submit").last?.params
        XCTAssertEqual(params?["truncate_before_row_id"]?.intValue, 7)

        await harness.tearDown()
    }
}
