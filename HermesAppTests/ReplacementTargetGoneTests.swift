import Foundation
import XCTest

@testable import HermesMobile
@testable import HermesServeKit

/// A Retry or an Edit & resend names the durable row it replaces (`truncate_before_row_id`). When that row has been compressed away, or deleted on another client, the backend refuses with 4018 "target user message is no longer in session history" (`tui_gateway/methods_prompt.py:288-291`), and the failed bubble's own Retry used to send exactly the same cut, so it failed the same way every time.
@MainActor
final class ReplacementTargetGoneTests: XCTestCase {
    private let storedID = "20261009_target_gone"
    private static let staleMessage = "target user message is no longer in session history"

    private func row(_ id: Int, _ role: String, _ content: String) -> TranscriptMessage {
        TranscriptMessage(json: .object([
            "id": .number(Double(id)), "role": .string(role), "content": .string(content), "timestamp": .number(1_790_000_000),
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
            row(41, "user", "first question"),
            row(42, "assistant", "first answer"),
        ]))
        chat.errorMessage = nil
        XCTAssertEqual(chat.entries.map(\.id), ["rest-41", "rest-42"])
        return (harness, chat)
    }

    /// The backend refuses the cut because row 41 is gone, and the row cannot be found again. The bubble says why, and its Retry sends the text as a new message rather than the same refused cut.
    func testRetryAfterTheTargetRowIsGoneDoesNotRepeatTheRefusedCut() async throws {
        let (harness, chat) = try await chatWithHistory()
        await harness.backend.failNextRPC("prompt.submit", code: 4018, message: Self.staleMessage, data: .object([
            "user_turn_count": .number(3), "segment_ordinal": .number(0), "prefix_user_count": .number(0),
        ]))

        chat.resendPrecedingUserTurn(before: "rest-42")
        let failed = await waitUntil { chat.outbound.first?.failure != nil && !chat.isSending }
        XCTAssertTrue(failed, "the replacement never failed: \(chat.outbound.map(\.failure))")
        let firstParams = await harness.backend.calls(to: "prompt.submit").first?.params
        XCTAssertEqual(firstParams?["truncate_before_row_id"]?.intValue, 41, "precondition: the first attempt was a replacement of row 41")
        let failure = try XCTUnwrap(chat.outbound.first?.failure)
        XCTAssertNotEqual(failure, Self.staleMessage, "the bubble repeats the backend's internal sentence instead of saying what happened and what Retry will do")
        XCTAssertEqual(failure, ChatModel.ReplacementTargetGone.notice)
        let failedID = try XCTUnwrap(chat.outbound.first?.id)

        await harness.backend.stub("prompt.submit") { _ in
            .object(["status": .string("streaming"), "user_row_id": .number(43)])
        }
        chat.retryOutbound(id: failedID)

        let retried = await waitUntil { await harness.backend.callCount("prompt.submit") >= 2 }
        XCTAssertTrue(retried, "the retry never reached prompt.submit: \(chat.errorMessage ?? "no error")")
        let params = await harness.backend.calls(to: "prompt.submit").last?.params
        XCTAssertNil(params?["truncate_before_row_id"], "the retry repeated the cut the backend already refused, so it can only fail the same way again")
        XCTAssertNil(params?["confirm_truncate"], "consent without a target is refused with 4004")
        XCTAssertEqual(params?["text"]?.stringValue, "first question")

        await harness.tearDown()
    }

    /// The control: a 4018 that is not about the replaced row (the backend also uses 4018 for an oversized PDF) leaves the replacement as it was.
    func testAnUnrelated4018KeepsTheReplacement() async throws {
        let (harness, chat) = try await chatWithHistory()
        await harness.backend.failNextRPC("prompt.submit", code: 4018, message: "PDF too large; cap is 32 MB")

        chat.resendPrecedingUserTurn(before: "rest-42")
        let failed = await waitUntil { chat.outbound.first?.failure != nil && !chat.isSending }
        XCTAssertTrue(failed)
        let failedID = try XCTUnwrap(chat.outbound.first?.id)

        await harness.backend.stub("prompt.submit") { _ in
            .object(["status": .string("streaming"), "user_row_id": .number(43)])
        }
        chat.retryOutbound(id: failedID)
        let retried = await waitUntil { await harness.backend.callCount("prompt.submit") >= 2 }
        XCTAssertTrue(retried)
        let params = await harness.backend.calls(to: "prompt.submit").last?.params
        XCTAssertEqual(params?["truncate_before_row_id"]?.intValue, 41, "an unrelated refusal turned the Retry into a plain send")

        await harness.tearDown()
    }
}
