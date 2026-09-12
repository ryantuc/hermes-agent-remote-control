import Foundation
import XCTest

@testable import HermesMobile

/// BUG-021 — a send the backend receives can leave nothing at all on screen.
///
/// The send path paints an optimistic bubble unconditionally, then hides it
/// unconditionally at the handoff, on the promise that the engine renders one
/// in its place. That promise is a lookup: `AppModel.publish` writes `chat.live`
/// only for the chat whose `runtimeSessionID` matches the id being published,
/// and `performSend` captures its session id ONCE, at `ensureSession()`, then
/// crosses two awaits. A `session.resume` landing in that window rebinds the
/// chat and `forget`s the state the handoff appended into — so the hide is
/// permanent, and the ack epilogue then deletes the roster row, which was the
/// message's last copy.
@MainActor
final class ChatModelSendAcknowledgementTests: XCTestCase {

    /// T1 — a send whose session is rebound underneath it still shows the
    /// message.
    ///
    /// Staging note: the rebind has to land BETWEEN the handoff and the ack, not after it.
    /// Parking `session.resume` and releasing it only after
    /// the ack has been observed is too late — by then the handoff is legitimately on
    /// screen, the roster row is legitimately dropped, and the message is then
    /// destroyed by `forget`, which no ack-ordering fix can catch.
    /// Parking `prompt.submit` instead puts the rebind in the window the
    /// mechanism actually names. `applyResume` is the same function whether the
    /// resume arrives from the foreground sweep or from a second `open()`; the
    /// second is deterministic and needs no reconnect.
    func testASendRebornUnderARebindIsStillOnScreen() async throws {
        let harness = await AppHarness.make()
        try await harness.openSocket()
        let chat = harness.chat(storedID: "20260819_020000_rebind")
        await chat.open()
        // REST is unscripted in this harness; clear its connection-refused noise.
        chat.errorMessage = nil

        let firstRuntimeID = try XCTUnwrap(chat.runtimeSessionID)
        await harness.backend.emit("message.start", sessionID: firstRuntimeID)
        let running = await waitUntil { chat.live.isBusy }
        XCTAssertTrue(running, "no running turn — this is the mid-turn send window")

        await harness.backend.stub("prompt.submit") { _ in
            .object(["status": .string("steered")])
        }
        await harness.backend.gate("prompt.submit")
        chat.draft = "acknowledge-test"
        chat.sendTapped()
        let handedOff = await waitUntil { await harness.backend.callCount("prompt.submit") == 1 }
        XCTAssertTrue(handedOff, "the send never reached the backend")

        // Load-bearing: this distinguishes "the fix works" from "the staging
        // never reached the acknowledged state".
        XCTAssertTrue(
            chat.entries.contains { $0.kind == .user && $0.text == "acknowledge-test" },
            "precondition: the message is on screen before the rebind — otherwise this test proves nothing"
        )

        // The rebind, inside the window: forget(R1), reset(R2).
        await chat.open()
        chat.errorMessage = nil
        XCTAssertNotEqual(chat.runtimeSessionID, firstRuntimeID, "the chat never rebound")

        await harness.backend.ungate("prompt.submit")
        await harness.backend.releaseParked()
        let acked = await waitUntil { !chat.isSending }
        XCTAssertTrue(acked, "the steered ack never landed")

        XCTAssertTrue(
            chat.entries.contains { $0.kind == .user && $0.text == "acknowledge-test" },
            "the backend acknowledged this message and the transcript no longer contains it: the handoff hid the roster row, the ack deleted it, and applyResume forgot the engine state the entry lived in"
        )

        await harness.tearDown()
    }

    /// Stage a session with a turn already running, the way
    /// `ChatModelBusyComposerTests` does.
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
        XCTAssertTrue(busy, "the turn never went busy - the rest of this test proves nothing")
        return runtimeID
    }

    /// T2 - a steered send labels its own bubble.
    ///
    /// `MessageBubbleView.statusTag` renders "Mid-turn correction" off
    /// `noticeKind`, and until now nothing on the send path ever set it: the
    /// only producer was `applyResumeProjection`, so the label appeared only if
    /// you disconnected and resumed. A steer this client sent itself was
    /// visually identical to an ordinary prompt from the instant the transient
    /// status line moved on.
    func testASteeredSendLabelsItsOwnBubble() async throws {
        let harness = await AppHarness.make()
        try await harness.openSocket()
        let chat = harness.chat(storedID: "20260819_020001_steerlabel")
        await chat.open()
        try await stageRunningTurn(harness, chat: chat)

        await harness.backend.stub("prompt.submit") { _ in
            .object(["status": .string("steered")])
        }
        chat.draft = "do it differently"
        chat.sendTapped()
        let acked = await waitUntil { chat.outbound.isEmpty && !chat.isSending }
        XCTAssertTrue(acked, "the steered send was never acknowledged")

        let bubble = chat.entries.last { $0.kind == .user }
        XCTAssertEqual(bubble?.text, "do it differently")
        XCTAssertEqual(
            bubble?.noticeKind,
            "correction",
            "MessageBubbleView.statusTag renders 'Mid-turn correction' off this, and it is the only acknowledgement of a steer that outlives the status line"
        )

        await harness.tearDown()
    }

    /// T3 - a queued send labels its own bubble. Guards the `isQueued` leg of
    /// `stampAck` against being dropped as "not what BUG-021 was about".
    func testAQueuedSendLabelsItsOwnBubble() async throws {
        let harness = await AppHarness.make()
        try await harness.openSocket()
        let chat = harness.chat(storedID: "20260819_020002_queuelabel")
        await chat.open()
        try await stageRunningTurn(harness, chat: chat)

        await harness.backend.stub("prompt.submit") { _ in
            .object(["status": .string("queued")])
        }
        chat.draft = "and then deploy"
        chat.sendTapped()
        let acked = await waitUntil { chat.outbound.isEmpty && !chat.isSending }
        XCTAssertTrue(acked, "the queued send was never acknowledged")

        let bubble = chat.entries.last { $0.kind == .user }
        XCTAssertEqual(bubble?.text, "and then deploy")
        XCTAssertEqual(
            bubble?.noticeKind,
            "queued",
            "MessageBubbleView.statusTag renders the queued tag off this"
        )

        await harness.tearDown()
    }

    /// T4 - coverage: a send while a clarify is parked still shows and labels
    /// its bubble.
    ///
    /// This is the report's own fixture, kept and RE-PURPOSED. It is NOT the
    /// discriminator the report's amendment took it for, and nobody should
    /// re-derive that: a parked clarify is not a variable the send path reads.
    /// Every consumer of `hasBlockingPrompt` and `needsInput` in the app and
    /// the kit was enumerated at design time, and not one of them is on the
    /// path from `sendTapped` through `performSend`, `appendUserEntry`,
    /// `publishHandoff`, `AppModel.publish`, `outboundEntries` or
    /// `statusLineText`. Staging a clarify changes nothing those functions
    /// branch on, so this would have gone green on unfixed code and
    /// "device-window-specific" would have been the wrong conclusion drawn
    /// from a fixture that never staged the mechanism.
    ///
    /// It is worth keeping as the regression rail for a real user scenario.
    func testASendUnderAParkedClarifyShowsAndLabelsItsBubble() async throws {
        let harness = await AppHarness.make()
        try await harness.openSocket()
        let chat = harness.chat(storedID: "20260819_020003_clarify")
        await chat.open()
        let runtimeID = try await stageRunningTurn(harness, chat: chat)

        await harness.backend.emit("clarify.request", sessionID: runtimeID, payload: .object([
            "request_id": .string("q-1"),
            "question": .string("Which file should I edit?"),
            "choices": .array([.string("A"), .string("B")]),
        ]))
        let parked = await waitUntil { chat.hasBlockingPrompt && chat.live.isBusy }
        XCTAssertTrue(parked, "the clarify never parked - the rest of this test proves nothing")

        await harness.backend.stub("prompt.submit") { _ in
            .object(["status": .string("steered")])
        }
        chat.draft = "use the second one"
        chat.sendTapped()
        let acked = await waitUntil { chat.outbound.isEmpty && !chat.isSending }
        XCTAssertTrue(acked, "the send under a parked clarify was never acknowledged")

        let bubble = chat.entries.last { $0.kind == .user }
        XCTAssertEqual(bubble?.text, "use the second one")
        XCTAssertEqual(bubble?.noticeKind, "correction")
        XCTAssertNotEqual(chat.sendPhase, .stalled, "the ack landed; nothing may read as stalled")

        await harness.tearDown()
    }
}
