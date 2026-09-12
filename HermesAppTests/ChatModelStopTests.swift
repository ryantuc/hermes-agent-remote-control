import Foundation
import HermesServeKit
import XCTest

@testable import HermesMobile

/// B3 half one — **Stop during a send must leave a visible sign.**
///
/// `performSend` hands the optimistic bubble to the turn engine *before* it
/// submits (ChatModel.swift, the `appendUserEntry` handoff): the engine's user
/// entry fronts for the bubble so events that beat the submit's own response
/// frame have somewhere to land. `appendUserEntry` claims `isBusy` while it is
/// at it — this client's own optimism, not a turn the backend started — and the
/// `live` setter's reconciliation takes that claim at face value and ends the
/// pre-turn phases with it.
///
/// Everything the user sees when they press Stop in that window follows from
/// there. `sendPhase` is already `.idle`, so `stopTapped` routes to
/// `interrupt()` against a turn that may not exist; `cancelPendingSend` is
/// unreachable; the outbound row stays hidden behind the handed-off entry
/// (`outboundEntries` refuses to render a handed-off row); `isSending` stays
/// true, so the composer stays locked for as long as the submit takes — and
/// `prompt.submit`'s RPC timeout is 1800 s. **Nothing in the transcript says
/// the send was cancelled, because nothing was.**
///
/// The five tests below stage that window, the two paths that must NOT change,
/// and the addressing bug that sits underneath all of it:
///
/// - (a) and (b) park a send inside `prompt.submit` with the handoff already
///   done and press Stop: the verdict must be visible, and it must survive the
///   late ack.
/// - (c) is a **control**, green before and after: cancelling from the stall
///   row, the one pre-handoff path where today's cancel is already visible.
/// - (d) addresses the roster by identity rather than position.
/// - (e) is a **control**, green before and after: Stop while a turn is
///   genuinely running still interrupts that turn and must never cancel the
///   send instead.
final class ChatModelStopTests: XCTestCase {

    // MARK: - Staging

    /// Open a bound chat and park a send inside `prompt.submit`, with the
    /// pre-submit handoff already done — the exact window Stop lands in.
    @MainActor
    private func stageGatedSubmit(
        _ harness: AppHarness,
        storedID: String,
        text: String
    ) async throws -> ChatModel {
        let chat = harness.chat(storedID: storedID)
        await chat.open()
        let bound = await waitUntil { chat.runtimeSessionID != nil }
        XCTAssertTrue(bound, "the chat never bound a runtime session id")
        // `open()` also loads the persisted transcript over REST, which is not
        // scripted and always fails here. Clear it so the assertions below are
        // about the send and nothing else.
        chat.errorMessage = nil

        await harness.backend.gate("prompt.submit")
        chat.draft = text
        chat.sendTapped()
        let submitted = await waitUntil { await harness.backend.callCount("prompt.submit") == 1 }
        XCTAssertTrue(submitted, "the submit never reached the backend — nothing is in flight to stop")

        // The handoff happens before the submit frame is built, so its arrival
        // proves the window is open. Assert it anyway: if the engine is not
        // fronting for the bubble, this is a different scenario and every
        // assertion below would prove nothing.
        XCTAssertNotNil(
            chat.outbound.first?.handedOffEntryID,
            "staging failed: the send never handed its bubble to the engine"
        )
        XCTAssertTrue(
            chat.live.entries.contains(where: { $0.kind == .user }),
            "staging failed: the engine has no user entry fronting for the message"
        )
        return chat
    }

    // MARK: - (a) the visible verdict

    /// Stop lands between the handoff and the ack. The message must come back
    /// as a bubble marked cancelled, the composer must unlock, and — half one's
    /// policy — no `session.interrupt` may go out for a turn the backend has
    /// not told us about.
    @MainActor
    func testStopDuringAGatedSubmitLeavesACancelledBubble() async throws {
        let harness = await AppHarness.make()
        try await harness.openSocket()
        let chat = try await stageGatedSubmit(
            harness, storedID: "20260808_090000_stopa", text: "rewrite the migration"
        )

        chat.stopTapped()

        XCTAssertTrue(
            chat.entries.contains(where: { $0.status == "error" && $0.errorText.contains("Cancelled") }),
            """
            Stop during the submit window left NO sign of itself in the transcript. \
            The handoff's optimistic `isBusy` already reset `sendPhase` to `.idle` \
            through the `live` setter's reconciliation, so `stopTapped` routed to \
            `interrupt()` and `cancelPendingSend` never ran; the outbound row is \
            still hidden behind the handed-off engine entry. The user pressed Stop \
            and the app said nothing at all. Rendered rows: \
            \(chat.entries.map { "\($0.kind)/\($0.status)" })
            """
        )
        XCTAssertFalse(
            chat.isSending,
            """
            the composer is still locked after Stop. `isSending` is only cleared by \
            `performSend`'s defer, and that task is parked inside `prompt.submit` — \
            whose RPC timeout is 1800 s. Stop must unlock the composer in the frame \
            of the tap.
            """
        )
        XCTAssertEqual(
            chat.sendPhase, .idle,
            "the send contract must be over once the user cancels the send"
        )

        // Half one's policy, pinned: before the ack there is no turn this client
        // knows about, so there is nothing to interrupt. Bounded negative wait —
        // `stopTapped`'s interrupt branch dials the RPC from a detached `Task`,
        // so asserting the count immediately would pass for the wrong reason.
        let interrupted = await waitUntil(timeout: 1) {
            await harness.backend.callCount("session.interrupt") > 0
        }
        XCTAssertFalse(
            interrupted,
            """
            Stop before the ack dialled `session.interrupt` against a turn the \
            backend never reported starting, and armed the interrupt latch with it \
            — which then drops `message.start` and the deltas of any turn the \
            server runs anyway for the whole grace window.
            """
        )

        // The parked submit lands after the verdict. The RPC cannot be aborted
        // (`HermesClient.request` has no cancellation handler), so the pipeline
        // resumes — and must not undo what the user decided.
        await harness.backend.ungate("prompt.submit")
        await harness.backend.releaseParked()
        let dropped = await waitUntil(timeout: 1) { chat.outbound.isEmpty }
        XCTAssertFalse(
            dropped,
            """
            the late ack removed the message from the roster, so the cancel left no \
            trace anywhere. The cancelled bubble is the only record that the user \
            cancelled; an ack that arrives afterwards must not delete it.
            """
        )
        XCTAssertEqual(
            chat.outbound.first?.failure?.contains("Cancelled"), true,
            "the cancelled verdict must survive the late ack"
        )
        let interruptedLater = await waitUntil(timeout: 1) {
            await harness.backend.callCount("session.interrupt") > 0
        }
        XCTAssertFalse(interruptedLater, "nothing about the late ack should produce an interrupt")

        await harness.tearDown()
    }

    // MARK: - (b) the reclaim

    /// The reclaim is what makes (a) possible: `outboundEntries` refuses to
    /// render a handed-off row, so a failure stamped without taking the engine
    /// entry back is stamped on an invisible bubble.
    @MainActor
    func testStopDuringAGatedSubmitReclaimsTheEngineEntry() async throws {
        let harness = await AppHarness.make()
        try await harness.openSocket()
        let chat = try await stageGatedSubmit(
            harness, storedID: "20260808_090000_stopb", text: "delete the stale branches"
        )

        chat.stopTapped()

        XCTAssertNil(
            chat.outbound.first?.handedOffEntryID,
            """
            the cancelled send's engine entry was never reclaimed. An orphaned \
            handed-off user entry keeps fronting for the bubble, so `outboundEntries` \
            renders nothing for it and any failure stamped on the roster is invisible \
            — the text sits on screen looking exactly like a message that was sent.
            """
        )
        XCTAssertFalse(
            chat.live.entries.contains(where: { $0.kind == .user }),
            """
            the phantom user entry the handoff appended is still in the turn engine \
            after the cancel. It claims `isBusy` for a turn that was never started.
            """
        )
        XCTAssertEqual(
            chat.outbound.count, 1,
            "the message itself must stay on the roster — a cancel is never a silent deletion"
        )

        await harness.backend.ungate("prompt.submit")
        await harness.backend.releaseParked()
        await harness.tearDown()
    }

    // MARK: - (c) CONTROL — the pre-handoff cancel, already visible

    /// **Control: green before the fix and after.** The stall row's Cancel is
    /// the one cancel path that already works, because it fires before the
    /// handoff — the bubble is still the roster's to render. It is here so a
    /// fix for (a)/(b) cannot pass by breaking the path that was fine.
    ///
    /// It costs ~9–12 s of wall clock: the stall watchdog's 8 s fuse is a
    /// hardcoded `Task.sleep` with no seam, and this test genuinely waits for it.
    @MainActor
    func testCancelFromTheStallRowStaysVisible() async throws {
        let harness = await AppHarness.make()
        try await harness.openSocket()

        // Park the send *before* the handoff: the chat has a durable id and no
        // runtime id, so `ensureSession` stalls inside `session.resume`.
        await harness.backend.gate("session.resume")
        let chat = harness.chat(storedID: "20260808_090000_stall")
        chat.draft = "count the open branches"
        chat.sendTapped()
        let reached = await waitUntil { await harness.backend.callCount("session.resume") == 1 }
        XCTAssertTrue(reached, "the send never reached session.resume")

        let stalled = await waitUntil(timeout: 12) { chat.isSendStalled }
        XCTAssertTrue(stalled, "the 8 s watchdog never raised the stall row")

        chat.cancelStalledSend()

        XCTAssertTrue(
            chat.entries.contains(where: { $0.status == "error" && $0.errorText.contains("Cancelled") }),
            "the stall row's Cancel must leave the message on screen, marked cancelled"
        )
        XCTAssertEqual(chat.outbound.count, 1, "the message is never silently removed")
        XCTAssertEqual(chat.sendPhase, .idle, "the stall row must be gone")
        XCTAssertFalse(chat.isSending, "the composer must unlock")

        await harness.backend.ungate("session.resume")
        await harness.backend.releaseParked()
        await harness.tearDown()
    }

    // MARK: - (d) the roster is addressed by identity, not position

    /// Two bubbles on the roster, both already failed, and the *older* one is
    /// retried. Stop must cancel the retried row — the one actually in flight —
    /// and leave the bystander's own failure alone.
    @MainActor
    func testStopCancelsTheRetriedRowNotTheLastOne() async throws {
        let harness = await AppHarness.make()
        try await harness.openSocket()

        let chat = harness.chat(storedID: "20260808_090000_retry")
        await chat.open()
        let bound = await waitUntil { chat.runtimeSessionID != nil }
        XCTAssertTrue(bound, "the chat never bound a runtime session id")
        chat.errorMessage = nil

        // Row A fails on its image upload, before any handoff.
        // 4300 deliberately: it is neither of the two "stale runtime id" codes
        // (4001/4007) nor -32000, which `HermesError.from` maps to
        // `.notConnected` — both of which would make the failure recoverable.
        await harness.backend.failNextRPC("image.attach_bytes", code: 4300, message: "attach refused")
        chat.addAttachment(data: Data([0x89, 0x50, 0x4E, 0x47]), filename: "shot.png", mimeType: "image/png")
        chat.draft = "what is in this screenshot"
        chat.sendTapped()
        let aFailed = await waitUntil { !chat.isSending && chat.outbound.first?.failure != nil }
        XCTAssertTrue(aFailed, "row A never failed on its upload")
        let rowA = try XCTUnwrap(chat.outbound.first).id

        // Row B fails on a submit that is not one of the safe recoveries.
        await harness.backend.failNextRPC("prompt.submit", code: 4300, message: "the provider refused the turn")
        chat.draft = "list the open branches"
        chat.sendTapped()
        let bFailed = await waitUntil { !chat.isSending && chat.outbound.count == 2 && chat.outbound.last?.failure != nil }
        XCTAssertTrue(bFailed, "row B never failed on its submit")
        let rowB = try XCTUnwrap(chat.outbound.last).id
        let bFailureBefore = chat.outbound.last?.failure

        // Retry the OLDER row and park it in its upload. The newest row is not
        // the one in flight, and it already carries a failure of its own.
        await harness.backend.gate("image.attach_bytes")
        chat.retryOutbound(id: rowA)
        let retried = await waitUntil { await harness.backend.callCount("image.attach_bytes") == 2 }
        XCTAssertTrue(retried, "the retry never reached the backend")

        chat.stopTapped()

        XCTAssertEqual(
            chat.outbound.first(where: { $0.id == rowA })?.failure?.contains("Cancelled"), true,
            """
            Stop did not cancel the row that is actually in flight. `cancelPendingSend` \
            addresses the roster by position (`outbound.indices.last`), which reaches the \
            NEWEST bubble, not the retried one — and here the newest already carries its \
            own failure, so the `failure == nil` guard skips it and today's cancel stamps \
            NOTHING AT ALL. The user pressed Stop and no row anywhere changed. \
            Roster: \(chat.outbound.map { "\($0.text.prefix(12))=\($0.failure ?? "nil")" })
            """
        )
        XCTAssertEqual(
            chat.outbound.first(where: { $0.id == rowB })?.failure, bFailureBefore,
            "the bystander must keep its own failure — a cancel verdict on it would be a lie"
        )
        XCTAssertFalse(chat.isSending, "the composer must unlock")
        XCTAssertEqual(chat.sendPhase, .idle, "the send contract must be over")

        // The parked upload resumes after the verdict. The pipeline must find
        // the row already failed and stop there rather than submitting a turn
        // the user cancelled.
        await harness.backend.ungate("image.attach_bytes")
        await harness.backend.releaseParked()
        let resubmitted = await waitUntil(timeout: 1) {
            await harness.backend.callCount("prompt.submit") > 1
        }
        XCTAssertFalse(
            resubmitted,
            "the cancelled attempt reached prompt.submit anyway — the cancel bought the user nothing"
        )
        XCTAssertEqual(chat.outbound.count, 2, "neither bubble may be dropped by the resumed pipeline")

        await harness.tearDown()
    }

    // MARK: - (e) CONTROL — Stop under a running turn still interrupts

    /// **Control: green before the fix and after.** It is the discriminator the
    /// fix turns on. A send issued *while a turn is already running* is a queued
    /// prompt: `live.isBusy` belongs to that running turn, not to this send's
    /// own handoff optimism, and Stop must interrupt the turn exactly as it
    /// always has. Cancelling the queued send instead would strip `isBusy` off a
    /// live turn (the reclaim's `removeEntry` releases it) and take the Stop
    /// button away from a turn that is still streaming.
    @MainActor
    func testStopDuringASendIssuedUnderARunningTurnInterrupts() async throws {
        let harness = await AppHarness.make()
        try await harness.openSocket()

        let chat = harness.chat(storedID: "20260808_090000_running")
        await chat.open()
        let bound = await waitUntil { chat.runtimeSessionID != nil }
        XCTAssertTrue(bound, "the chat never bound a runtime session id")
        chat.errorMessage = nil
        let runtimeID = try XCTUnwrap(chat.runtimeSessionID)

        // This client's own turn, acknowledged and genuinely started.
        chat.draft = "first prompt"
        chat.sendTapped()
        let first = await waitUntil { await harness.backend.callCount("prompt.submit") == 1 }
        XCTAssertTrue(first, "the first send never reached the backend")
        let acked = await waitUntil { chat.outbound.isEmpty && !chat.isSending }
        XCTAssertTrue(acked, "the first send was never acknowledged")
        await harness.backend.emit("message.start", sessionID: runtimeID)
        let busy = await waitUntil { chat.live.isBusy }
        XCTAssertTrue(busy, "the first turn never went busy — the rest of this test proves nothing")

        // A second prompt, issued under that running turn, parked in its submit.
        await harness.backend.gate("prompt.submit")
        chat.draft = "queued prompt"
        chat.sendTapped()
        let second = await waitUntil { await harness.backend.callCount("prompt.submit") == 2 }
        XCTAssertTrue(second, "the queued send never reached the backend")

        chat.stopTapped()

        let interrupted = await waitUntil { await harness.backend.callCount("session.interrupt") == 1 }
        XCTAssertTrue(
            interrupted,
            """
            Stop while a turn is running must interrupt that turn. Routing it to the \
            pre-ack cancel instead leaves the running turn untouched on the backend and \
            takes the Stop button away from it locally — the reclaim releases `isBusy`, \
            so nothing on screen can stop the turn until its next event arrives.
            """
        )
        XCTAssertFalse(
            chat.outbound.contains(where: { ($0.failure ?? "").contains("Cancelled") }),
            "Stop under a running turn must never cancel the queued send instead of interrupting"
        )

        await harness.backend.ungate("prompt.submit")
        await harness.backend.releaseParked()
        await harness.tearDown()
    }
}
