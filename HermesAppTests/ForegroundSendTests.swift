import XCTest

@testable import HermesMobile

/// BUG-135 — a foreground refresh republishes every open chat. That refresh
/// must not treat an existing `isBusy` bit as acknowledgement of a submit that
/// is still parked inside `prompt.submit`.
final class ForegroundSendTests: XCTestCase {
    @MainActor
    func testForegroundRefreshPreservesAnUnacknowledgedSend() async throws {
        let harness = await AppHarness.make()
        try await harness.openSocket()
        let chat = harness.chat(storedID: "20260831_120000_foreground_send")
        await chat.open()
        let didOpen = await waitUntil { chat.runtimeSessionID != nil }
        XCTAssertTrue(didOpen)
        chat.errorMessage = nil

        await harness.backend.gate("prompt.submit")
        chat.draft = "keep this send visible"
        chat.sendTapped()
        let submitReachedBackend = await waitUntil {
            await harness.backend.callCount("prompt.submit") == 1
        }
        XCTAssertTrue(submitReachedBackend)
        XCTAssertEqual(chat.sendPhase, .sending)
        XCTAssertEqual(chat.statusLineText, "Sending…")

        await harness.app.handleForeground()

        XCTAssertEqual(chat.sendPhase, .sending, "foreground publish discarded the unacknowledged send")
        XCTAssertEqual(chat.statusLineText, "Sending…")
        XCTAssertTrue(chat.isSending, "the composer unlocked while the submit was still awaiting its ack")
        XCTAssertEqual(chat.outbound.count, 1, "the optimistic message row was dropped")

        chat.stopTapped()
        await harness.backend.ungate("prompt.submit")
        await harness.backend.releaseParked()
        await harness.tearDown()
    }

    /// The guard must not cost the ordinary send its `.queued` phase.
    ///
    /// `appendUserEntry` claims `isBusy` optimistically and `publishHandoff`
    /// publishes that claim before `prompt.submit` is issued, so at the ack
    /// `live.isBusy` is true on every send — including this one, where no turn
    /// has started at all. A guard that reads that flag classifies this as a
    /// turn already under way and drops straight to `.idle`, which is BUG-135's
    /// own end state one step later: `.queued` is the only thing left saying an
    /// acknowledged turn has not started, and it is what `isTurnActive` (Stop),
    /// `statusLineText` and `isReleasable` (eviction) read once a publish clears
    /// the optimistic claim.
    @MainActor
    func testAnIdleSendReachesQueuedAtItsAcknowledgement() async throws {
        let harness = await AppHarness.make()
        try await harness.openSocket()
        let chat = harness.chat(storedID: "20260831_120002_idle_send_queued")
        await chat.open()
        let didOpen = await waitUntil { chat.runtimeSessionID != nil }
        XCTAssertTrue(didOpen)
        chat.errorMessage = nil
        let runtimeID = try XCTUnwrap(chat.runtimeSessionID)

        chat.draft = "an ordinary send from an idle session"
        chat.sendTapped()
        let acknowledged = await waitUntil { !chat.isSending }
        XCTAssertTrue(acknowledged, "the send never settled")

        XCTAssertTrue(
            chat.live.isBusy,
            "precondition: the handoff's optimistic claim is up, which is what makes isBusy unusable here"
        )
        XCTAssertFalse(
            chat.live.entries.contains { $0.isStreaming },
            "precondition: no turn has actually started — the backend has only acknowledged the submit"
        )
        XCTAssertEqual(
            chat.sendPhase,
            .queued,
            """
            the acknowledged send left no phase behind. `.queued` is the only \
            state that says a turn was accepted and has not started, and it is \
            what Stop, the status line and the eviction predicate read once a \
            publish clears the handoff's optimistic isBusy.
            """
        )

        // And the turn's own start still retires it — a busy publish with an
        // ack in hand is the start edge, which is the half of the
        // reconciliation BUG-135 deliberately left alone.
        await harness.backend.emit("message.start", sessionID: runtimeID)
        let retired = await waitUntil { chat.sendPhase == .idle }
        XCTAssertTrue(retired, "the turn's own start never ended the queued phase")

        await harness.backend.emit("message.complete", sessionID: runtimeID, payload: .object([
            "status": .string("complete"),
            "text": .string("done"),
        ]))
        await harness.tearDown()
    }

    /// The foreground guard must not create the opposite ordering bug. A real
    /// turn may beat the submit response; the later acknowledgement must retire
    /// the phase because there will be no second start edge.
    ///
    /// Staged with a delta, not a bare `message.start`: a streaming entry is
    /// the signal the optimistic handoff cannot forge, and it is what the ack
    /// epilogue reads.
    @MainActor
    func testMessageStartBeforeAckRetiresThePreservedPhase() async throws {
        let harness = await AppHarness.make()
        try await harness.openSocket()
        let chat = harness.chat(storedID: "20260831_120001_start_before_ack")
        await chat.open()
        let didOpen = await waitUntil { chat.runtimeSessionID != nil }
        XCTAssertTrue(didOpen)
        chat.errorMessage = nil

        await harness.backend.gate("prompt.submit")
        chat.draft = "start can beat the ack"
        chat.sendTapped()
        let submitReachedBackend = await waitUntil {
            await harness.backend.callCount("prompt.submit") == 1
        }
        XCTAssertTrue(submitReachedBackend)

        await harness.app.handleForeground()
        // Re-read after the refresh: `resumeOpenThreads` may rebind the chat to
        // a freshly minted runtime id, and an event addressed to the old one
        // would reach nothing while every assertion below still passed on the
        // handoff's own optimistic state.
        let runtimeID = try XCTUnwrap(chat.runtimeSessionID)
        await harness.backend.emitAssistantText("the turn is already running", sessionID: runtimeID)
        let turnStarted = await waitUntil { chat.live.entries.contains { $0.isStreaming } }
        XCTAssertTrue(turnStarted, "the turn never painted — the rest of this test proves nothing")
        XCTAssertEqual(
            chat.sendPhase,
            .sending,
            "message.start was treated as a submit acknowledgement"
        )

        await harness.backend.ungate("prompt.submit")
        await harness.backend.releaseParked()
        let acknowledged = await waitUntil { !chat.isSending }
        XCTAssertTrue(acknowledged)
        XCTAssertEqual(
            chat.sendPhase,
            .idle,
            "the acknowledgement left a queued phase waiting for a start that already happened"
        )

        await harness.backend.emit("message.complete", sessionID: runtimeID, payload: .object([
            "status": .string("complete"),
            "text": .string("done"),
        ]))
        await harness.tearDown()
    }
}
