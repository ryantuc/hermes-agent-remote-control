import Foundation
import HermesServeKit
import XCTest

@testable import HermesMobile

/// Desktop-parity busy composer.
///
/// While a turn runs (or a send is in flight), the composer slot stays a
/// Send: the backend steers text-only payloads into the live turn and queues
/// attachments for the next one (`display.busy_input_mode`,
/// `_handle_busy_submit`). Stop replaces Send only while the composer is
/// empty; a compact secondary Stop covers the typed-draft case. The status
/// line names what the ack actually said — `queued`, `steered`, `redirected`.
@MainActor
final class ChatModelBusyComposerTests: XCTestCase {

    /// Stage a genuinely running turn the way ChatModelStopTests does: the
    /// first send acknowledges, then `message.start` makes the engine busy.
    /// Returns the runtime id for later emits.
    @discardableResult
    private func stageRunningTurn(_ harness: AppHarness, chat: ChatModel) async throws -> String {
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

    // MARK: S1 — the slot stays Send while busy with a payload

    func testSlotStaysSendWhileBusyWithText() async throws {
        let harness = await AppHarness.make()
        try await harness.openSocket()
        let chat = harness.chat(storedID: "20260813_100000_busysend")
        await chat.open()
        try await stageRunningTurn(harness, chat: chat)

        // Typed mid-turn: the primary slot must read Send...
        chat.draft = "steer the turn"
        XCTAssertFalse(chat.showsStopControl, "a busy turn with text in the composer must keep Send")
        XCTAssertTrue(chat.showsSecondaryStop, "the compact secondary Stop must cover the typed state")
        XCTAssertTrue(chat.canSend, "the busy send must be enabled — that is the whole point")

        // ...and Stop only when the composer empties.
        chat.draft = ""
        XCTAssertTrue(chat.showsStopControl, "an empty composer under a running turn must show Stop")
        XCTAssertFalse(chat.showsSecondaryStop, "no secondary Stop when the primary already is one")

        await harness.tearDown()
    }

    func testSlotStaysSendWhileBusyWithAttachments() async throws {
        let harness = await AppHarness.make()
        try await harness.openSocket()
        let chat = harness.chat(storedID: "20260813_100001_busyattach")
        await chat.open()
        try await stageRunningTurn(harness, chat: chat)

        chat.attachments.append(PendingAttachment(
            filename: "photo.png", mimeType: "image/png", data: Data(), kind: .image
        ))
        XCTAssertFalse(chat.showsStopControl, "an attachment payload under a running turn must keep Send")
        XCTAssertTrue(chat.showsSecondaryStop)
        chat.attachments.removeAll()
        XCTAssertTrue(chat.showsStopControl)

        await harness.tearDown()
    }

    func testSlotShowsStopWhileSendInFlightWithEmptyComposer() async throws {
        let harness = await AppHarness.make()
        try await harness.openSocket()
        let chat = harness.chat(storedID: "20260813_100002_sending")
        await chat.open()
        let bound = await waitUntil { chat.runtimeSessionID != nil }
        XCTAssertTrue(bound, "the chat never bound a runtime session id")

        // Pre-ack (.sending) with an empty composer: the slot is Stop so the
        // user can cancel the unacknowledged attempt.
        await harness.backend.gate("prompt.submit")
        chat.draft = "first prompt"
        chat.sendTapped()
        let sent = await waitUntil { await harness.backend.callCount("prompt.submit") == 1 }
        XCTAssertTrue(sent, "the send never reached the backend")
        XCTAssertTrue(chat.showsStopControl, "an in-flight unacknowledged send with an empty composer must show Stop")
        XCTAssertFalse(chat.showsSecondaryStop)

        await harness.backend.ungate("prompt.submit")
        await harness.backend.releaseParked()
        await harness.tearDown()
    }

    // MARK: S2 — the ack names what the backend did with a busy submit

    func testSteeredAckNamesItselfThenSettlesOnTurnEnd() async throws {
        let harness = await AppHarness.make()
        try await harness.openSocket()
        let chat = harness.chat(storedID: "20260813_100003_steered")
        await chat.open()
        let runtimeID = try await stageRunningTurn(harness, chat: chat)

        await harness.backend.stub("prompt.submit") { _ in
            .object(["status": .string("steered")])
        }
        chat.draft = "do it differently"
        chat.sendTapped()
        let acked = await waitUntil { chat.outbound.isEmpty && !chat.isSending }
        XCTAssertTrue(acked, "the steered send was never acknowledged")
        XCTAssertEqual(chat.sendPhase, .queued)
        XCTAssertEqual(
            chat.statusLineText,
            "Steered — the current turn continues with your message",
            "the status line must say the message entered the live turn, not that it queued"
        )

        // The steered turn ends with no `message.start` of its own — the
        // phase must settle, or the status line promises a queue forever.
        await harness.backend.emit("message.complete", sessionID: runtimeID, payload: .object([
            "status": .string("complete"),
            "text": .string("done"),
        ]))
        let settled = await waitUntil { !chat.live.isBusy && chat.sendPhase == .idle }
        XCTAssertTrue(settled, "the steered turn never settled the queued phase")
        XCTAssertNil(chat.statusLineText, "nothing may keep promising a queue after the turn ends")

        await harness.tearDown()
    }

    /// The regression that made every ack above unreachable in production.
    ///
    /// A running turn republishes its state many times a second as it streams,
    /// and `ChatModel.live` used to read any busy frame as "our turn started"
    /// and end the pre-turn phase. Under a turn that was ALREADY running that
    /// is the other turn's flag, so the phase was gone within a frame or two of
    /// the tap — long before the submit's ack came back over the network — and
    /// the ack had nowhere to land. The user got no acknowledgement at all: the
    /// backend emits no event for a steer or a redirect, so that ack was the
    /// only signal there was.
    ///
    /// One delta is enough to stage it; a real turn emits many a second, which
    /// is why the tests above (which stage a turn and then go quiet) stayed
    /// green while the phone showed nothing. Without the
    /// `phaseAttachedToRunningTurn` guard this test observes `.idle`.
    func testSteeredAckSurvivesTheRunningTurnsOwnStream() async throws {
        let harness = await AppHarness.make()
        try await harness.openSocket()
        let chat = harness.chat(storedID: "20260813_100006_streaming")
        await chat.open()
        let runtimeID = try await stageRunningTurn(harness, chat: chat)

        await harness.backend.stub("prompt.submit") { _ in
            .object(["status": .string("steered")])
        }
        // Hold the ack so the turn's own stream lands first — the ordering the
        // network guarantees in practice and the harness otherwise hides.
        await harness.backend.gate("prompt.submit")
        chat.draft = "do it differently"
        chat.sendTapped()
        let sent = await waitUntil { await harness.backend.callCount("prompt.submit") == 2 }
        XCTAssertTrue(sent, "the busy send never reached the backend")
        XCTAssertEqual(chat.sendPhase, .sending, "precondition: the send is still waiting for its ack")

        await harness.backend.emit("message.delta", sessionID: runtimeID, payload: .object([
            "text": .string("still working on the first thing"),
        ]))
        let painted = await waitUntil { chat.live.entries.contains { $0.isStreaming } }
        XCTAssertTrue(painted, "the delta never painted — the rest of this test proves nothing")
        XCTAssertEqual(chat.sendPhase, .sending,
                       "the running turn's own stream must not end the phase this send is waiting on")

        await harness.backend.ungate("prompt.submit")
        await harness.backend.releaseParked()
        let acked = await waitUntil { !chat.isSending }
        XCTAssertTrue(acked, "the busy send never settled")
        XCTAssertEqual(chat.sendPhase, .queued,
                       "the ack said `steered` and the phase must be there to record it")

        // And the steered lifecycle still closes: no `message.start` of its
        // own is coming, so the turn ending is what settles it.
        await harness.backend.emit("message.complete", sessionID: runtimeID, payload: .object([
            "status": .string("complete"),
            "text": .string("done"),
        ]))
        let settled = await waitUntil { !chat.live.isBusy && chat.sendPhase == .idle }
        XCTAssertTrue(settled, "the steered turn never settled the queued phase")

        await harness.tearDown()
    }

    func testQueuedAckSurvivesDrainGapThenStartEndsPhase() async throws {
        let harness = await AppHarness.make()
        try await harness.openSocket()
        let chat = harness.chat(storedID: "20260813_100004_queued")
        await chat.open()
        let runtimeID = try await stageRunningTurn(harness, chat: chat)

        await harness.backend.stub("prompt.submit") { _ in
            .object(["status": .string("queued")])
        }
        chat.draft = "run this next"
        chat.sendTapped()
        let acked = await waitUntil { chat.outbound.isEmpty && !chat.isSending }
        XCTAssertTrue(acked, "the queued send was never acknowledged")
        XCTAssertEqual(chat.sendPhase, .queued)

        // While the live turn still runs, the live-turn status dominates.
        XCTAssertEqual(chat.statusLineText, "Thinking")

        // The drain gap: the turn ends, the queued prompt is next.
        await harness.backend.emit("message.complete", sessionID: runtimeID, payload: .object([
            "status": .string("complete"),
            "text": .string("done"),
        ]))
        let idle = await waitUntil { !chat.live.isBusy }
        XCTAssertTrue(idle, "the turn never ended")
        XCTAssertEqual(chat.sendPhase, .queued, "a queued ack must survive the drain gap")
        XCTAssertEqual(chat.statusLineText, "Queued — waiting for the turn to start")

        // The queued prompt's own start ends the phase.
        await harness.backend.emit("message.start", sessionID: runtimeID)
        let restarted = await waitUntil { chat.live.isBusy && chat.sendPhase == .idle }
        XCTAssertTrue(restarted, "the queued turn's start never ended the phase")

        await harness.tearDown()
    }

    // MARK: The one ack that promises no turn

    /// `prompt.submit` has a reply that carries no status at all. Type a voice
    /// stop phrase while voice chat is running and the backend consumes it as
    /// the command to end voice chat, answering `{"voice_stopped": true}` with
    /// nothing started (methods_prompt.py:103).
    ///
    /// Every other ack means a turn is coming, so the send path treated this
    /// one as if it did too and parked on "Queued — waiting for the turn to
    /// start" for a turn that never arrives. `PromptAck` has decoded
    /// `voice_stopped` since it was written; nothing had ever read it.
    func testAVoiceStopAckPromisesNoTurn() async throws {
        let harness = await AppHarness.make()
        try await harness.openSocket()
        let chat = harness.chat(storedID: "20260813_100007_voicestop")
        await chat.open()
        let bound = await waitUntil { chat.runtimeSessionID != nil }
        XCTAssertTrue(bound, "the chat never bound a runtime session id")

        await harness.backend.stub("prompt.submit") { _ in
            .object(["voice_stopped": .bool(true)])
        }
        chat.draft = "stop"
        chat.sendTapped()
        let settled = await waitUntil { !chat.isSending }
        XCTAssertTrue(settled, "the send never settled")

        XCTAssertEqual(chat.sendPhase, .idle,
                       "a voice-stop ack starts no turn, so no phase may promise one")
        XCTAssertFalse(chat.live.isBusy,
                       "the handoff's optimistic isBusy has nothing coming to settle it")
        XCTAssertNil(chat.statusLineText,
                     "nothing may sit on 'Queued' or 'Thinking' for a turn the backend never started")
        XCTAssertFalse(chat.entries.contains { $0.kind == .user && $0.text == "stop" },
                       "the phrase was a command, not a prompt — it must not be left in the transcript")

        await harness.tearDown()
    }

    // MARK: S5 — Stop clears the queued phase (the backend clears the queue)

    func testStopWhileQueuedEndsTheQueuedPhase() async throws {
        let harness = await AppHarness.make()
        try await harness.openSocket()
        let chat = harness.chat(storedID: "20260813_100005_stopqueued")
        await chat.open()
        let runtimeID = try await stageRunningTurn(harness, chat: chat)

        await harness.backend.stub("prompt.submit") { _ in
            .object(["status": .string("queued")])
        }
        chat.draft = "run this next"
        chat.sendTapped()
        let acked = await waitUntil { chat.outbound.isEmpty && !chat.isSending }
        XCTAssertTrue(acked, "the queued send was never acknowledged")
        XCTAssertEqual(chat.sendPhase, .queued)

        // Stop: the backend's `session.interrupt` clears the queued prompt
        // (methods_session.py:3021-3025), so the client phase must end with
        // it — no more "Queued" promise for a queue that just got deleted.
        chat.stopTapped()
        XCTAssertEqual(chat.sendPhase, .idle, "Stop must end the queued phase synchronously")
        let interrupted = await waitUntil { await harness.backend.callCount("session.interrupt") == 1 }
        XCTAssertTrue(interrupted, "Stop never reached the backend")
        let cleared = await waitUntil { !chat.live.isBusy && chat.statusLineText == nil }
        XCTAssertTrue(cleared, "after Stop nothing may keep promising a queue")

        // The interrupted turn settles with no residual promise.
        await harness.backend.emit("message.complete", sessionID: runtimeID, payload: .object([
            "status": .string("complete"),
            "text": .string("done"),
        ]))
        let settled = await waitUntil { !chat.live.isBusy }
        XCTAssertTrue(settled, "the interrupted turn never settled")
        XCTAssertEqual(chat.sendPhase, .idle)
        XCTAssertNil(chat.statusLineText)

        await harness.tearDown()
    }
}
