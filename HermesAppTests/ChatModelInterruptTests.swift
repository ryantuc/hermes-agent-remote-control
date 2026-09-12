import Foundation
import HermesServeKit
import XCTest

@testable import HermesMobile

/// B4 — `ChatModel.interrupt()`.
///
/// The 4001 recovery resumes the durable id, and `applyResume` →
/// `applyResumeProjection` re-seeds the engine with `interrupted = false` —
/// releasing the latch the Stop just set. The retry's failure is then
/// swallowed by `try?`. A Stop can end with no latch, no backend interrupt,
/// and no error anywhere.
final class ChatModelInterruptTests: XCTestCase {

    /// The recovery must not undo the Stop: after resume-and-retry, the
    /// engine's interrupt latch is still set on the runtime id the resume
    /// bound, and a stale event from the cancelled turn is still swallowed.
    @MainActor
    func testStopSurvivesTheStaleRuntimeIDRecovery() async throws {
        let harness = await AppHarness.make()
        try await harness.openSocket()

        let chat = harness.chat(storedID: "20260807_100000_b4stop1")
        await chat.open()
        let bound = await waitUntil { chat.runtimeSessionID != nil }
        XCTAssertTrue(bound, "the chat never bound a runtime session id")
        // `open()` loads the transcript over REST, which is not scripted and
        // always fails here; clear it so errorMessage below is about the Stop.
        chat.errorMessage = nil
        let staleRuntimeID = try XCTUnwrap(chat.runtimeSessionID)

        // A turn is streaming when the user reaches for Stop.
        await harness.backend.emitAssistantText("streamed progress", sessionID: staleRuntimeID)
        let busy = await waitUntil { chat.live.isBusy }
        XCTAssertTrue(busy, "the turn never started at the app layer")

        // The runtime id died server-side: the first session.interrupt fails
        // 4001, the recovery resume mints a fresh id, the retry succeeds.
        await harness.backend.failNextRPC("session.interrupt", code: 4001, message: "session not found")

        await chat.interrupt()

        // Regression pins (green before and after the fix): the recovery made
        // both calls and addressed the retry to the id the resume bound.
        let interrupts = await harness.backend.calls(to: "session.interrupt")
        XCTAssertEqual(interrupts.count, 2, "the 4001 recovery must retry the interrupt after resuming")
        let recoveredRuntimeID = try XCTUnwrap(chat.runtimeSessionID)
        XCTAssertNotEqual(recoveredRuntimeID, staleRuntimeID, "the recovery resume must bind a fresh runtime id")
        XCTAssertEqual(
            interrupts.last?.sessionID,
            recoveredRuntimeID,
            "the retry must address the runtime id the resume just bound"
        )

        // THE defect: applyResume → applyResumeProjection released the latch
        // the Stop set, and nothing re-asserted it.
        XCTAssertTrue(
            chat.live.interrupted,
            "the recovery resume released the Stop's interrupt latch — a stale event arriving now renders as if the user never pressed Stop"
        )

        // The consequence, end to end: a stale origin-less start addressed to
        // the id the chat now holds must still be swallowed (Change 2a: within
        // the grace window the time-based latch decides). Bounded inverted
        // wait — comfortably under the 5 s grace.
        await harness.backend.emit("message.start", sessionID: recoveredRuntimeID)
        let becameBusy = await waitUntil(timeout: 1) { chat.live.isBusy }
        XCTAssertFalse(
            becameBusy,
            "a stale message.start after Stop re-opened the turn — the latch was gone"
        )

        await harness.tearDown()
    }

    /// Both interrupts fail: the user must be told their Stop did not take,
    /// and the local finalisation must stand.
    @MainActor
    func testStopThatNeverLandsTellsTheUser() async throws {
        let harness = await AppHarness.make()
        try await harness.openSocket()

        let chat = harness.chat(storedID: "20260807_101500_b4stop2")
        await chat.open()
        let bound = await waitUntil { chat.runtimeSessionID != nil }
        XCTAssertTrue(bound, "the chat never bound a runtime session id")
        chat.errorMessage = nil
        let staleRuntimeID = try XCTUnwrap(chat.runtimeSessionID)

        await harness.backend.emitAssistantText("streamed progress", sessionID: staleRuntimeID)
        let busy = await waitUntil { chat.live.isBusy }
        XCTAssertTrue(busy, "the turn never started at the app layer")

        // EVERY session.interrupt fails: the first 4001 takes the recovery
        // path, the resume succeeds, and the retry fails too. The backend was
        // never told to stop.
        await harness.backend.failRPC("session.interrupt", code: 4001, message: "session not found")

        await chat.interrupt()

        let interrupts = await harness.backend.callCount("session.interrupt")
        XCTAssertEqual(interrupts, 2, "the recovery must have retried before giving up")
        XCTAssertNotNil(
            chat.errorMessage,
            "both interrupts failed and the user was never told — the turn may still be running on the backend behind a composer that says it stopped"
        )
        XCTAssertTrue(
            chat.live.interrupted,
            "the local Stop must stand even when the backend cannot be reached"
        )

        await harness.tearDown()
    }
}
