import Foundation
import HermesServeKit
import XCTest

@testable import HermesMobile

/// A12 — what the approval surface shows after an answer, with a second
/// approval queued behind it.
///
/// `finishSubmission` (ApprovalSheetView.swift) keeps the sheet up whenever
/// *any* blocking prompt remains. So answering A1 with A2 queued leaves the
/// sheet presented — but presented on **A1**, the approval that was just
/// answered, until the queue advances and ChatView's `onChange(of:
/// promptIdentity)` re-presents. In that window the Allow/Deny buttons belong
/// to a prompt the backend is no longer waiting on, and the head-of-queue guard
/// at ChatModel.swift:694 silently refuses the tap.
///
/// The guard is right and stays: `approval.respond` is positional FIFO with no
/// request id, so answering a non-head approval would consume whatever prompt
/// *is* at the head — a wrong answer to a command the user never read. This is
/// fail-closed and no wrong answer is sent. It is still a dead button on the one
/// surface where the user authorises shell commands on their own machine.
///
/// This target has no UI tests (see README.md), so these assert on the decision
/// the sheet makes and the model it reads — not on pixels.
final class ApprovalQueueTests: XCTestCase {

    /// Answer the head with another approval queued behind it. The surface must
    /// move to the second, not keep rendering the answered first.
    @MainActor
    func testAnsweringOneApprovalWithAnotherQueuedMovesTheSurfaceToTheSecond() async throws {
        let harness = await AppHarness.make()
        try await harness.openSocket()

        let chat = harness.chat(storedID: "20260804_101500_a12queue")
        await chat.open()
        let bound = await waitUntil { chat.runtimeSessionID != nil }
        XCTAssertTrue(bound, "the chat never bound a runtime session id")
        // `open()` loads the transcript over REST, which is not scripted and
        // always fails here. Clear it so the assertions are about approvals.
        chat.errorMessage = nil
        guard let runtimeID = chat.runtimeSessionID else {
            return XCTFail("no runtime session id to address the approvals to")
        }

        // Two approvals, in the order the backend queues them. `approval.request`
        // carries no request id — the queue's order *is* the correlation.
        await harness.backend.emit("approval.request", sessionID: runtimeID, payload: .object([
            "command": .string("git status"),
            "description": .string("read the working tree"),
        ]))
        await harness.backend.emit("approval.request", sessionID: runtimeID, payload: .object([
            "command": .string("rm -rf build"),
            "description": .string("delete the build directory"),
        ]))
        let queued = await waitUntil { chat.live.pendingApprovals.count == 2 }
        XCTAssertTrue(
            queued,
            "both approvals must reach the chat's live state; got \(chat.live.pendingApprovals.count)"
        )

        guard let first = chat.pendingApproval else {
            return XCTFail("no approval at the head of the queue")
        }
        XCTAssertEqual(first.command, "git status", "the head must be the approval that arrived first")
        // What the sheet is rendering at the moment the user taps Allow.
        let presented = BlockingPrompt.approval(first)

        await chat.respond(to: first, choice: .once)

        // The queue advanced …
        XCTAssertEqual(
            chat.pendingApproval?.command,
            "rm -rf build",
            "answering the head must leave the second approval at the head"
        )

        // … and the surface has to advance with it.
        XCTAssertEqual(
            presented.sheetOutcome(head: chat.currentBlockingPrompt),
            .dismiss,
            """
            the approval sheet stayed up on an approval that has already been \
            answered (ApprovalSheetView.finishSubmission). Its Allow and Deny \
            buttons are live and aimed at "\(first.command)", but the backend is \
            now waiting on "\(chat.pendingApproval?.command ?? "—")" — so \
            ChatModel.swift:694 refuses the tap and the user gets a consent \
            surface whose buttons do nothing.
            """
        )

        await harness.tearDown()
    }

    /// The control, and the boundary this fix must not cross.
    ///
    /// When the answer does **not** land, the prompt still holds the head and
    /// the agent is still blocked on it. The sheet must stay — dismissing would
    /// orphan a live consent request to the docked bar. Nothing here is broken
    /// today; it exists so a fix for A12 cannot pass by dismissing
    /// unconditionally.
    @MainActor
    func testAFailedAnswerLeavesTheSurfaceOnTheSamePrompt() async throws {
        let harness = await AppHarness.make()
        try await harness.openSocket()

        let chat = harness.chat(storedID: "20260804_101500_a12failed")
        await chat.open()
        let bound = await waitUntil { chat.runtimeSessionID != nil }
        XCTAssertTrue(bound, "the chat never bound a runtime session id")
        chat.errorMessage = nil
        guard let runtimeID = chat.runtimeSessionID else {
            return XCTFail("no runtime session id to address the approval to")
        }

        await harness.backend.emit("approval.request", sessionID: runtimeID, payload: .object([
            "command": .string("git push --force origin main"),
            "description": .string("force-push the branch"),
        ]))
        let queued = await waitUntil { chat.pendingApproval != nil }
        XCTAssertTrue(queued, "the approval never reached the chat")

        guard let only = chat.pendingApproval else {
            return XCTFail("no approval at the head of the queue")
        }
        let presented = BlockingPrompt.approval(only)

        // The answer does not reach the agent.
        await harness.backend.failRPC("approval.respond", code: -32000, message: "gateway busy")
        await chat.respond(to: only, choice: .once)

        XCTAssertEqual(
            chat.pendingApproval?.id,
            only.id,
            "an answer that failed must leave the approval at the head, still answerable"
        )
        XCTAssertEqual(
            presented.sheetOutcome(head: chat.currentBlockingPrompt),
            .stay,
            """
            the sheet closed on an approval whose answer never landed. The agent \
            is still blocked on "\(only.command)" and the only way back to it is \
            the docked bar — a consent request the user was shown and then had \
            taken away.
            """
        )

        await harness.tearDown()
    }
}
