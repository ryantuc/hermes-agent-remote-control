import Foundation
import HermesServeKit
import XCTest

@testable import HermesMobile

/// BUG-141 — a `prompt.submit` refused because some other surface owns the
/// conversation.
///
/// The backend has enforced per-session exclusivity unconditionally since
/// 0.21.0, with no way to switch it off, and it labels the refusal in
/// `error.data.reason`. The client parsed that label and discarded it one layer
/// later, so the user got a developer's log sentence and a Retry button that
/// could only ever fail the same way. A probe drove two real gateway processes
/// against one stored conversation and measured the refusal, reason
/// `SESSION_NOT_OWNED`.
///
/// **The load-bearing test here is the reason-less one.** Every user runs their
/// own hermes-agent at whatever version they happen to have, and a 4090 with no
/// `data` — an older backend, or 0.21.0's own fourth unlabelled refusal — must
/// produce byte-for-byte what it produced before this change.
@MainActor
final class ChatModelOwnershipRefusalTests: XCTestCase {

    private let ownedMessage =
        "Session 9f2c already has a live owner (desktop, pid 41288, running 3h12m)."

    /// Open a bound chat with a scripted 4090 waiting for its first submit.
    private func refusedSend(
        reason: String?,
        message: String
    ) async throws -> (harness: AppHarness, chat: ChatModel) {
        let harness = await AppHarness.make()
        try await harness.openSocket()

        let chat = harness.chat(storedID: "20260902_160651_6b5400")
        await chat.open()
        let bound = await waitUntil { chat.runtimeSessionID != nil }
        XCTAssertTrue(bound, "the chat never bound a runtime session id")
        // `open()` also loads the persisted transcript over REST, which is not
        // scripted and always fails here.
        chat.errorMessage = nil

        await harness.backend.failNextRPC(
            "prompt.submit",
            code: 4090,
            message: message,
            data: reason.map { .object(["reason": .string($0)]) }
        )

        chat.draft = "run the database migration"
        chat.sendTapped()
        let settled = await waitUntil { chat.isSending == false }
        XCTAssertTrue(settled, "the send never finished")
        return (harness, chat)
    }

    /// The measured refusal. Plain language replaces the log sentence, and the
    /// row remembers which refusal it was so the view can choose its actions.
    func testSessionNotOwnedGetsPlainLanguageAndKeepsTheLabel() async throws {
        let (harness, chat) = try await refusedSend(
            reason: "SESSION_NOT_OWNED",
            message: ownedMessage
        )

        XCTAssertEqual(chat.outbound.count, 1, "the refused message must stay on screen")
        let row = try XCTUnwrap(chat.outbound.first)
        XCTAssertEqual(
            row.failure,
            "This conversation is open on another device. Close it there, or start a new chat.",
            "the backend's log sentence must not be the user interface"
        )
        XCTAssertEqual(
            row.refusal,
            .sessionNotOwned,
            "the view decides its actions from this; without it 'New chat' cannot be offered"
        )
        XCTAssertEqual(
            chat.outboundRefusal(for: row.id),
            .sessionNotOwned,
            "the accessor the transcript reads must agree with the row"
        )
        XCTAssertEqual(chat.sendPhase, .idle)

        await harness.tearDown()
    }

    /// **The regression pin, and the most important test in this batch.** The
    /// identical refusal with no `data` is what every backend before 0.21.0
    /// sends, and what 0.21.0 itself sends on its unlabelled fourth path. The
    /// bubble must carry the backend's own sentence, exactly as it does today,
    /// and carry no label.
    func testAReasonlessRefusalIsUnchangedFromTodaysBehaviour() async throws {
        let (harness, chat) = try await refusedSend(reason: nil, message: ownedMessage)

        let row = try XCTUnwrap(chat.outbound.first)
        XCTAssertEqual(
            row.failure,
            ownedMessage,
            "no label means no interpretation: the raw message is the old behaviour"
        )
        XCTAssertNil(row.refusal, "absent data must never be read as a refusal we recognised")
        XCTAssertNil(chat.outboundRefusal(for: row.id))

        await harness.tearDown()
    }

    /// Capacity is genuinely transient, so its wording and its Retry are the
    /// ones the app already had. Only the label is new, and it is deliberately
    /// not acted on.
    func testCapacityRefusalKeepsTheBackendsOwnWording() async throws {
        let capacity = "All 4 session slots are in use."
        let (harness, chat) = try await refusedSend(
            reason: "MAX_CONCURRENT_SESSIONS",
            message: capacity
        )

        let row = try XCTUnwrap(chat.outbound.first)
        XCTAssertEqual(row.failure, capacity)
        XCTAssertEqual(row.refusal, .maxConcurrentSessions)

        await harness.tearDown()
    }

    /// The backend cannot read its own ownership bookkeeping. The copy says so
    /// plainly, and the row **keeps its Retry**: the repair happens on the
    /// computer, and when it lands the user's way back to their own message is
    /// that button. An earlier draft suppressed it and made the row terminal —
    /// `retryOutbound` is the only writer that clears `refusal` and the Retry
    /// button is its only caller, so a suppressed Retry meant the row could
    /// never recover even after the backend was fixed.
    func testCoordinationUnavailableIsLabelledAndKeepsItsRetry() async throws {
        let (harness, chat) = try await refusedSend(
            reason: "SESSION_COORDINATION_UNAVAILABLE",
            message: "Hermes could not read C:/Users/x/AppData/Local/hermes/runtime/active_sessions.json"
        )

        let row = try XCTUnwrap(chat.outbound.first)
        XCTAssertEqual(
            row.failure,
            "Hermes can't verify who owns this conversation. This needs attention on the computer running Hermes."
        )
        XCTAssertEqual(row.refusal, .coordinationUnavailable)
        // The row must not be actionless. Retry is what clears the label, so a
        // row that cannot be retried can never leave this state.
        chat.retryOutbound(id: row.id)
        XCTAssertNil(
            chat.outboundRefusal(for: row.id),
            "a coordination refusal must stay retryable — it is the only path out of the state"
        )
        _ = await waitUntil { chat.isSending == false }

        await harness.tearDown()
    }

    /// A retry starts the row clean. Leaving the label behind would keep a
    /// stale "New chat" (or a suppressed Retry) on a row that is trying again.
    func testRetryClearsTheLabelWithTheFailure() async throws {
        let (harness, chat) = try await refusedSend(
            reason: "SESSION_NOT_OWNED",
            message: ownedMessage
        )
        let row = try XCTUnwrap(chat.outbound.first)
        XCTAssertEqual(row.refusal, .sessionNotOwned)

        chat.retryOutbound(id: row.id)
        XCTAssertNil(
            chat.outboundRefusal(for: row.id),
            "the refusal must be cleared alongside the failure it explained"
        )

        _ = await waitUntil { chat.isSending == false }
        await harness.tearDown()
    }

    /// The copy switch on its own, with no backend in the way — including the
    /// nil arm returning its fallback untouched.
    func testFailureTextNilArmReturnsTheFallbackVerbatim() {
        XCTAssertEqual(
            ChatModel.failureText(refusal: nil, fallback: ownedMessage),
            ownedMessage
        )
        XCTAssertEqual(
            ChatModel.failureText(refusal: .maxConcurrentSessions, fallback: ownedMessage),
            ownedMessage
        )
    }
}
