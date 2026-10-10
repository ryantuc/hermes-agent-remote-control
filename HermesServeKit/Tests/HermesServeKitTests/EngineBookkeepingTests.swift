import XCTest

@testable import HermesServeKit

/// BUG-146 — two engine bookkeeping findings from a comment review.
///
/// 1. `applyResumeProjection` cleared `state.interrupted` but left the Stop timestamp in
///    `interruptedAt`, and `isQuiescent` refuses any session holding one, so a session that was
///    stopped and then resumed could never be evicted by the idle sweep.
/// 2. `removeEntry` (the rollback of a send whose submit failed hard) cleared the unscoped-event pin
///    whenever it named this session, even when the rolled-back send was not what set it, so the
///    unscoped tail of a turn already running there had nowhere to land.
final class EngineBookkeepingTests: XCTestCase {
    private let session = "a1b2c3d4"
    private let other = "e5f6a7b8"

    /// `session` empty builds an unscoped frame, the legacy shape the pin exists for.
    private func event(_ type: String, session: String = "", payload: JSONValue = .object([:])) -> GatewayEvent {
        var params: [String: JSONValue] = ["type": .string(type), "payload": payload]
        if !session.isEmpty { params["session_id"] = .string(session) }
        return GatewayEvent(type: type, sessionID: session, payload: payload, params: .object(params))
    }

    private func idleResume() -> SessionResumeResult {
        SessionAPI.decodeResume(.object([
            "session_id": .string(session),
            "running": .bool(false),
            "info": .object(["title": .string("Synthetic chat")]),
        ]), requested: "stored")
    }

    // MARK: 1. The Stop timestamp and the resume projection

    func testAResumeAfterAStopLeavesTheSessionEvictable() {
        let engine = TurnEngine()
        engine.appendUserEntry(sessionID: session, text: "Run it")
        engine.apply(event("message.start", session: session))
        engine.markInterrupted(sessionID: session)
        XCTAssertFalse(engine.isQuiescent(sessionID: session), "a fresh Stop holds its latch bookkeeping")

        engine.applyResumeProjection(sessionID: session, result: idleResume(), trailingUserTexts: ["Run it"])

        let state = engine.state(for: session)
        XCTAssertFalse(state.interrupted)
        XCTAssertFalse(state.isBusy)
        XCTAssertTrue(engine.isQuiescent(sessionID: session),
                      "the resume cleared the latch, so it must clear the Stop timestamp that backs it too")
    }

    /// The other half of the same rule: a resume that keeps the current metadata keeps the latch, and
    /// so keeps the timestamp.
    func testAResumeThatKeepsCurrentMetadataKeepsTheLatch() {
        let engine = TurnEngine()
        engine.appendUserEntry(sessionID: session, text: "Run it")
        engine.apply(event("message.start", session: session))
        engine.markInterrupted(sessionID: session)

        engine.applyResumeProjection(sessionID: session, result: idleResume(), trailingUserTexts: ["Run it"],
                                     preserveTranscript: true, preserveCurrentMetadata: true)

        XCTAssertTrue(engine.state(for: session).interrupted)
        XCTAssertFalse(engine.isQuiescent(sessionID: session))
    }

    // MARK: 2. The pin and the rollback of a failed send

    /// A steer under a running turn fails to submit; rolling it back must leave that turn its pin.
    func testRollingBackASteerKeepsTheRunningTurnPinned() {
        let engine = TurnEngine()
        engine.apply(event("message.start", session: session))
        XCTAssertEqual(engine.pinnedSessionID, session)

        let steer = engine.appendUserEntry(sessionID: session, text: "Also check the logs", joiningRunningTurn: true)
        engine.removeEntry(sessionID: session, entryID: steer)

        XCTAssertEqual(engine.pinnedSessionID, session, "the rollback did not set this pin, so it must not take it")
        // The running turn's unscoped tail still lands on it.
        engine.apply(event("message.delta", payload: .object(["text": .string("Still streaming")])))
        engine.flush()
        XCTAssertEqual(engine.state(for: session).entries.last?.text, "Still streaming")
    }

    /// A turn that started on the session after the send was appended owns the pin from then on.
    func testRollingBackAFailedSendLeavesAPinThatAMessageStartSet() {
        let engine = TurnEngine()
        let entry = engine.appendUserEntry(sessionID: session, text: "Hello")
        engine.apply(event("message.start", session: session))

        engine.removeEntry(sessionID: session, entryID: entry)

        XCTAssertEqual(engine.pinnedSessionID, session)
    }

    /// A rollback puts back the pin its own append displaced, rather than leaving nothing pinned.
    func testRollingBackASendRestoresThePinItDisplaced() {
        let engine = TurnEngine()
        engine.apply(event("message.start", session: other))
        let entry = engine.appendUserEntry(sessionID: session, text: "Hello")
        XCTAssertEqual(engine.pinnedSessionID, session)

        engine.removeEntry(sessionID: session, entryID: entry)

        XCTAssertEqual(engine.pinnedSessionID, other, "the other session's running turn keeps its unscoped target")
    }

    /// Unchanged behaviour: rolling back the send that set the pin, with nothing else in play, clears it.
    func testRollingBackTheOnlySendStillUnpins() {
        let engine = TurnEngine()
        let entry = engine.appendUserEntry(sessionID: session, text: "Hello")

        engine.removeEntry(sessionID: session, entryID: entry)

        XCTAssertNil(engine.pinnedSessionID)
        XCTAssertFalse(engine.state(for: session).isBusy)
        XCTAssertTrue(engine.isQuiescent(sessionID: session))
    }

    /// A rollback for an entry that is already gone changes nothing, the pin included.
    func testRollingBackAnUnknownEntryIsANoOp() {
        let engine = TurnEngine()
        engine.appendUserEntry(sessionID: session, text: "Hello")

        engine.removeEntry(sessionID: session, entryID: "\(session)#user999")

        XCTAssertEqual(engine.pinnedSessionID, session)
        XCTAssertEqual(engine.state(for: session).entries.count, 1)
    }
}
