import Foundation
import XCTest

@testable import HermesMobile
@testable import HermesServeKit

/// Which replacements may answer a deep-cut refusal (4033) with `confirm_deep_truncate`. Edit & resend may: while the composer holds the edit, its banner says Send replaces the message and everything after it, so the person agreed to remove the turns on screen. Retry may not: nothing on its button says the later turns go, so its 4033 is shown, not answered.
@MainActor
final class DeepCutConsentTests: XCTestCase {
    private let storedID = "20261030_deep_cut"

    private func row(_ id: Int, _ role: String, _ content: String) -> TranscriptMessage {
        TranscriptMessage(json: .object([
            "id": .number(Double(id)), "role": .string(role), "content": .string(content), "timestamp": .number(1_790_000_000),
        ]))
    }

    /// A bound chat with two finished turns: user 41, assistant 42, user 43, assistant 44.
    private func chatWithTwoTurns() async throws -> (AppHarness, ChatModel) {
        let harness = await AppHarness.make()
        try await harness.openSocket()
        let chat = harness.chat(storedID: storedID)
        await chat.open()
        let bound = await waitUntil { chat.runtimeSessionID != nil }
        XCTAssertTrue(bound)
        chat.applyTranscript(TranscriptPage(sessionID: storedID, messages: [
            row(41, "user", "first question"),
            row(42, "assistant", "first answer"),
            row(43, "user", "second question"),
            row(44, "assistant", "second answer"),
        ]))
        chat.errorMessage = nil
        XCTAssertEqual(chat.entries.map(\.id), ["rest-41", "rest-42", "rest-43", "rest-44"])
        return (harness, chat)
    }

    private func refuseNextSubmitAsDeep(_ harness: AppHarness, archivedUserTurns: Int) async {
        await harness.backend.failNextRPC(
            "prompt.submit", code: 4033,
            message: "truncation would archive later user turns; resubmit with confirm_deep_truncate=true if this is intended",
            data: .object(["archived_messages": .number(4), "archived_user_turns": .number(Double(archivedUserTurns))]))
    }

    /// Editing the first of two turns removes both, which the banner said; the refusal is answered once with the flag.
    func testAnEditOfAnEarlierMessageAnswersTheRefusalOnce() async throws {
        let (harness, chat) = try await chatWithTwoTurns()
        await refuseNextSubmitAsDeep(harness, archivedUserTurns: 2)

        XCTAssertTrue(chat.beginEditing(entryID: "rest-41"))
        chat.draft = "first question, corrected"
        chat.sendTapped()

        let resent = await waitUntil { await harness.backend.callCount("prompt.submit") == 2 }
        XCTAssertTrue(resent, "the refusal was never answered: \(chat.errorMessage ?? "no error"), \(chat.outbound.map(\.failure))")
        let calls = await harness.backend.calls(to: "prompt.submit")
        XCTAssertNil(calls.first?.params["confirm_deep_truncate"], "the first attempt must not carry a key an older backend refuses")
        let resend = try XCTUnwrap(calls.last?.params)
        XCTAssertEqual(resend["confirm_deep_truncate"]?.boolValue, true)
        XCTAssertEqual(resend["truncate_before_row_id"]?.intValue, 41)
        XCTAssertEqual(resend["text"]?.stringValue, "first question, corrected")
        _ = await waitUntil { !chat.isSending }
        XCTAssertTrue(chat.outbound.allSatisfy { $0.failure == nil }, "the edit went through and must not show as failed")
        let total = await harness.backend.callCount("prompt.submit")
        XCTAssertEqual(total, 2)

        await harness.tearDown()
    }

    /// Retry on the older reply would remove the later turn too, and nothing said so: the refusal is shown and nothing is resent.
    func testARetryOfAnEarlierTurnShowsTheRefusal() async throws {
        let (harness, chat) = try await chatWithTwoTurns()
        await refuseNextSubmitAsDeep(harness, archivedUserTurns: 2)

        chat.resendPrecedingUserTurn(before: "rest-42")

        let failed = await waitUntil { chat.outbound.first?.failure != nil && !chat.isSending }
        XCTAssertTrue(failed, "the refusal never reached the bubble: \(chat.outbound.map(\.failure))")
        let calls = await harness.backend.calls(to: "prompt.submit")
        XCTAssertEqual(calls.count, 1, "a Retry must not answer the refusal on the person's behalf")
        XCTAssertEqual(calls.first?.params["truncate_before_row_id"]?.intValue, 41, "precondition: the Retry was a replacement")
        XCTAssertNil(calls.first?.params["confirm_deep_truncate"])

        await harness.tearDown()
    }

    /// The backend counts a turn the chat does not show (three against the two on screen): the edit never agreed to that one, so the refusal is shown.
    func testAnEditWhoseCutReachesTurnsTheChatDoesNotShowShowsTheRefusal() async throws {
        let (harness, chat) = try await chatWithTwoTurns()
        await refuseNextSubmitAsDeep(harness, archivedUserTurns: 3)

        XCTAssertTrue(chat.beginEditing(entryID: "rest-41"))
        chat.draft = "first question, corrected"
        chat.sendTapped()

        let failed = await waitUntil { chat.outbound.first?.failure != nil && !chat.isSending }
        XCTAssertTrue(failed, "the refusal never reached the bubble: \(chat.outbound.map(\.failure))")
        let calls = await harness.backend.calls(to: "prompt.submit")
        XCTAssertEqual(calls.count, 1)
        XCTAssertNil(calls.first?.params["confirm_deep_truncate"])

        await harness.tearDown()
    }
}
