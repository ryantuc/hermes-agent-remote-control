import Foundation
import HermesServeKit
import XCTest

@testable import HermesMobile

/// BUG-020 — a turn parked on a clarify/sudo/secret/approval must not present
/// as "Thinking" with a live Stop. The engine already knows (`hasBlockingPrompt`
/// / `needsInput`); the status line and the interrupt controls did not read it.
@MainActor
final class ChatModelBlockingPromptStatusTests: XCTestCase {

    func testClarifyParkSaysWaitingAndHidesStop() async throws {
        let harness = await AppHarness.make()
        try await harness.openSocket()
        let chat = harness.chat(storedID: "20260818_020000_clarifypark")
        await chat.open()
        let runtimeID = try await stageBusyTurn(harness, chat: chat)

        await harness.backend.emit("clarify.request", sessionID: runtimeID, payload: .object([
            "request_id": .string("q-1"),
            "question": .string("Which file should I edit?"),
            "choices": .array([.string("A"), .string("B")]),
        ]))
        let parked = await waitUntil { chat.hasBlockingPrompt && chat.live.isBusy }
        XCTAssertTrue(parked, "the clarify never parked — the rest of this test proves nothing")

        XCTAssertEqual(
            chat.statusLineText,
            "Waiting for your answer",
            "ChatModel.statusLineText has no hasBlockingPrompt check, so a parked clarify still reads as Thinking"
        )
        XCTAssertFalse(
            chat.showsStopControl,
            "Stop stays live during a blocking prompt and session.interrupt silently destroys the question"
        )
        XCTAssertFalse(
            chat.showsSecondaryStop,
            "the compact Stop is the same control and must hide too"
        )
        XCTAssertFalse(
            chat.showsInterruptControl,
            "the nav-bar Stop reads the same flag"
        )

        await harness.tearDown()
    }

    func testApprovalParkUsesTheSameCopy() async throws {
        let harness = await AppHarness.make()
        try await harness.openSocket()
        let chat = harness.chat(storedID: "20260818_020001_approvalpark")
        await chat.open()
        let runtimeID = try await stageBusyTurn(harness, chat: chat)

        await harness.backend.emit("approval.request", sessionID: runtimeID, payload: .object([
            "command": .string("rm -rf /tmp/scratch"),
            "description": .string("clean the scratch dir"),
        ]))
        let parked = await waitUntil { chat.hasBlockingPrompt }
        XCTAssertTrue(parked, "the approval never arrived")
        XCTAssertEqual(chat.statusLineText, "Waiting for your answer")
        XCTAssertFalse(chat.showsStopControl)

        await harness.tearDown()
    }

    /// Stage a genuinely running turn: first send acks, then message.start.
    @discardableResult
    private func stageBusyTurn(_ harness: AppHarness, chat: ChatModel) async throws -> String {
        chat.errorMessage = nil
        let bound = await waitUntil { chat.runtimeSessionID != nil }
        XCTAssertTrue(bound, "the chat never bound a runtime session id")
        chat.draft = "first prompt"
        chat.sendTapped()
        let sent = await waitUntil { await harness.backend.callCount("prompt.submit") == 1 }
        XCTAssertTrue(sent, "the first send never reached the backend")
        let acked = await waitUntil { chat.outbound.isEmpty && !chat.isSending }
        XCTAssertTrue(acked, "the first send was never acknowledged")
        let runtimeID = try XCTUnwrap(chat.runtimeSessionID)
        await harness.backend.emit("message.start", sessionID: runtimeID)
        let busy = await waitUntil { chat.live.isBusy }
        XCTAssertTrue(busy, "the turn never went busy — the rest of this test proves nothing")
        return runtimeID
    }
}
