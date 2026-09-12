import Foundation
import HermesServeKit
import XCTest

@testable import HermesMobile

/// The one deliberate gap in the mirroring work, closed: on a mirroring
/// backend, a queued prompt that drains after this client's own Stop arrives
/// as a new `message.start` stamped with THIS connection's `origin` — it is
/// this client's turn and must not be presented as "Working in another
/// client".
///
/// The two tests are each other's control: identical staging, one variable —
/// the origin stamped on the drained turn's `message.start`.
@MainActor
final class ForeignTurnOriginTests: XCTestCase {

    /// Stage the scenario end to end: own turn running → a second prompt
    /// submitted (queued server-side behind the turn) → Stop → the cancelled
    /// turn's terminal frame (releases the latch, 2a) → the drain's
    /// `message.start`, stamped with `drainOrigin`. The terminal-then-start
    /// order is the real wire order: the gateway serializes the cancelled
    /// turn's terminal frame before the drained prompt's start.
    private func stageStopThenDrain(harness: AppHarness, drainOrigin: String) async throws -> ChatModel {
        let chat = harness.chat(storedID: "stored-drain")
        await chat.open()
        let bound = await waitUntil { chat.runtimeSessionID != nil }
        XCTAssertTrue(bound, "open() never bound a runtime id")
        chat.errorMessage = nil
        let runtimeID = try XCTUnwrap(chat.runtimeSessionID)

        // This client's own turn.
        chat.draft = "first prompt"
        chat.sendTapped()
        let submitted = await waitUntil { await harness.backend.callCount("prompt.submit") == 1 }
        XCTAssertTrue(submitted, "the first send never reached the backend")
        await harness.backend.emit(
            "message.start", sessionID: runtimeID, origin: ScriptedBackend.transportOrigin
        )
        let busy = await waitUntil { chat.live.isBusy }
        XCTAssertTrue(busy, "the first turn never went busy — the rest of this test proves nothing")
        XCTAssertFalse(chat.isForeignTurn, "a turn this client submitted is its own")

        // A second prompt, queued server-side behind the running turn.
        chat.draft = "queued prompt"
        chat.sendTapped()
        let queued = await waitUntil { await harness.backend.callCount("prompt.submit") == 2 }
        XCTAssertTrue(queued, "the queued send never reached the backend")

        // Stop. `markInterrupted` latches before `session.interrupt` is sent,
        // so the RPC's arrival proves the latch is up.
        chat.stopTapped()
        let stopAcked = await waitUntil { await harness.backend.callCount("session.interrupt") == 1 }
        XCTAssertTrue(stopAcked, "Stop never reached the backend")
        XCTAssertTrue(chat.live.interrupted, "markInterrupted must have latched before the RPC")

        // The cancelled turn's own terminal frame — releases the latch (2a).
        await harness.backend.emit(
            "message.complete",
            sessionID: runtimeID,
            payload: .object(["text": .string("partial"), "status": .string("interrupted")]),
            origin: ScriptedBackend.transportOrigin
        )
        let released = await waitUntil { !chat.live.interrupted }
        XCTAssertTrue(released, "the terminal frame never released the latch")

        // The queued prompt drains: a NEW turn, stamped with `drainOrigin`.
        await harness.backend.emit("message.start", sessionID: runtimeID, origin: drainOrigin)
        let drained = await waitUntil { chat.live.isBusy }
        XCTAssertTrue(drained, "the drained turn never went busy")
        return chat
    }

    /// RED on the current branch — the drained turn is presented as another
    /// client's.
    func testOwnQueuedPromptDrainingAfterAStopIsNotForeign() async throws {
        let harness = await AppHarness.make()
        await harness.backend.setSessionMirroring(true)
        try await harness.openSocket()

        let chat = try await stageStopThenDrain(
            harness: harness, drainOrigin: ScriptedBackend.transportOrigin
        )

        XCTAssertFalse(
            chat.isForeignTurn,
            "the drained queued prompt is THIS client's turn — its message.start carried this connection's own origin, and 'Working in another client' would be a lie"
        )
        XCTAssertEqual(
            chat.statusLineText, "Thinking",
            "no 'Working in another client' prefix on our own drained turn"
        )

        await harness.tearDown()
    }

    /// The control: identical staging, the drain stamped with a DIFFERENT
    /// client's origin — that one IS foreign, before and after the fix. If the
    /// red test above ever passes by claiming everything, this one goes red.
    func testAnotherClientsTurnAfterAStopStaysForeign() async throws {
        let harness = await AppHarness.make()
        await harness.backend.setSessionMirroring(true)
        try await harness.openSocket()

        let chat = try await stageStopThenDrain(harness: harness, drainOrigin: "desktop-transport-9")

        XCTAssertTrue(
            chat.isForeignTurn,
            "a turn stamped with a different connection's origin is another client's — the fix must not claim everything"
        )
        XCTAssertEqual(chat.statusLineText, "Working in another client · Thinking")

        await harness.tearDown()
    }
}
