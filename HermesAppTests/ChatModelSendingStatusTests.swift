import Foundation
import HermesServeKit
import XCTest

@testable import HermesMobile

/// BUG-030 — the status line says "Thinking" between handoff and submit-ack
/// because the `live.isBusy` branch precedes the `sendPhase` switch, and
/// `appendUserEntry` claims busy before the ack. "Sending…" is unreachable
/// on the ordinary idle-send path.
///
/// Also carries DESIGN-BUG-021 T5: the steered/redirected copy must be
/// evaluated BEFORE the streaming-bubble guard, because a steer only ever
/// happens while a turn is streaming.
@MainActor
final class ChatModelSendingStatusTests: XCTestCase {

    func testIdleSendSaysSendingUntilAck() async throws {
        let harness = await AppHarness.make()
        try await harness.openSocket()
        let chat = harness.chat(storedID: "20260818_030000_sending")
        await chat.open()
        let bound = await waitUntil { chat.runtimeSessionID != nil }
        XCTAssertTrue(bound, "the chat never bound a runtime session id")

        await harness.backend.gate("prompt.submit")
        chat.draft = "hello"
        chat.sendTapped()
        let sent = await waitUntil { await harness.backend.callCount("prompt.submit") == 1 }
        XCTAssertTrue(sent, "the send never reached the backend")
        XCTAssertEqual(chat.sendPhase, .sending)
        XCTAssertEqual(
            chat.statusLineText,
            "Sending…",
            "ChatModel.statusLineText: the busy branch precedes sendPhase, so an unacked idle send reads as Thinking"
        )

        await harness.backend.ungate("prompt.submit")
        await harness.backend.releaseParked()
        await harness.tearDown()
    }

    func testSteeredStatusSurvivesAStreamingTurn() async throws {
        let harness = await AppHarness.make()
        try await harness.openSocket()
        let chat = harness.chat(storedID: "20260818_030001_steerstream")
        await chat.open()

        chat.errorMessage = nil
        let bound = await waitUntil { chat.runtimeSessionID != nil }
        XCTAssertTrue(bound, "the chat never bound a runtime session id")
        chat.draft = "first prompt"
        chat.sendTapped()
        let first = await waitUntil { await harness.backend.callCount("prompt.submit") == 1 }
        XCTAssertTrue(first, "the first send never reached the backend")
        let acked = await waitUntil { chat.outbound.isEmpty && !chat.isSending }
        XCTAssertTrue(acked, "the first send was never acknowledged")
        let runtimeID = try XCTUnwrap(chat.runtimeSessionID)
        await harness.backend.emit("message.start", sessionID: runtimeID)
        await harness.backend.emit("message.delta", sessionID: runtimeID, payload: .object([
            "text": .string("working on it"),
        ]))
        let streaming = await waitUntil { chat.live.entries.contains(where: { $0.isStreaming }) }
        XCTAssertTrue(streaming, "no streaming bubble — T5 would be vacuous")

        await harness.backend.stub("prompt.submit") { _ in
            .object(["status": .string("steered")])
        }
        chat.draft = "do it differently"
        chat.sendTapped()
        let steered = await waitUntil { chat.outbound.isEmpty && !chat.isSending }
        XCTAssertTrue(steered, "the steered send was never acknowledged")
        XCTAssertEqual(
            chat.statusLineText,
            "Steered — the current turn continues with your message",
            "the streaming-bubble guard sits above the steered branch, so the copy is unreachable exactly when a steer happens"
        )

        await harness.tearDown()
    }

    func testMidTurnInFlightSendStillSaysThinking() async throws {
        let harness = await AppHarness.make()
        try await harness.openSocket()
        let chat = harness.chat(storedID: "20260818_030002_joinedsending")
        await chat.open()

        chat.errorMessage = nil
        let bound = await waitUntil { chat.runtimeSessionID != nil }
        XCTAssertTrue(bound, "the chat never bound a runtime session id")
        chat.draft = "first prompt"
        chat.sendTapped()
        let first = await waitUntil { await harness.backend.callCount("prompt.submit") == 1 }
        XCTAssertTrue(first, "the first send never reached the backend")
        let acked = await waitUntil { chat.outbound.isEmpty && !chat.isSending }
        XCTAssertTrue(acked, "the first send was never acknowledged")
        let runtimeID = try XCTUnwrap(chat.runtimeSessionID)
        await harness.backend.emit("message.start", sessionID: runtimeID)
        let busy = await waitUntil { chat.live.isBusy }
        XCTAssertTrue(busy, "no live turn — a joined send would be vacuous")
        XCTAssertFalse(
            chat.live.entries.contains(where: { $0.isStreaming }),
            "a streaming bubble would nil the status line and hide the joined-send branch"
        )

        await harness.backend.gate("prompt.submit")
        chat.draft = "steer mid-flight"
        chat.sendTapped()
        let sent = await waitUntil { await harness.backend.callCount("prompt.submit") == 2 }
        XCTAssertTrue(sent, "the mid-turn send never reached the backend")
        XCTAssertEqual(chat.sendPhase, .sending)
        XCTAssertEqual(
            chat.statusLineText,
            "Thinking",
            "a joined in-flight send must keep reading as Thinking; dropping !sendJoinedRunningTurn would say Sending…"
        )

        await harness.backend.ungate("prompt.submit")
        await harness.backend.releaseParked()
        await harness.tearDown()
    }
}
