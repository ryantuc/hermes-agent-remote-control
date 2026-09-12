import XCTest

@testable import HermesServeKit

/// BUG-068A — after Stop, body events stay latched without a five-second timer.
///
/// Does not touch `testLatchExpiresAndRendersAForeignTurn`: that existing test
/// still covers an unstamped start that arrives after the start-only backstop.
/// These pin the no-timer residue for deltas and the controls around starts.
final class TurnEngineLatchNoTimerTests: XCTestCase {
    private let session = "a1b2c3d4"

    func testAPostStopTailStillDropsAMinuteLaterWithoutAResend() {
        let engine = TurnEngine()
        engine.appendUserEntry(sessionID: session, text: "go")
        engine.apply(GatewayEvent(type: "message.start", sessionID: session, payload: .null, params: .null))
        engine.apply(GatewayEvent(
            type: "message.delta",
            sessionID: session,
            payload: .object(["text": .string("partial")]),
            params: .null
        ))
        engine.flush()
        engine.markInterrupted(sessionID: session, at: Date().addingTimeInterval(-60))

        let before = engine.state(for: session)
        let countBefore = before.entries.count
        let textBefore = before.entries.last { $0.kind == .assistant }?.text

        engine.apply(GatewayEvent(
            type: "message.delta",
            sessionID: session,
            payload: .object(["text": .string(" stale tail after a minute")]),
            params: .null
        ))
        engine.flush()

        let state = engine.state(for: session)
        XCTAssertEqual(state.entries.count, countBefore)
        XCTAssertEqual(state.entries.last { $0.kind == .assistant }?.text, textBefore)
        XCTAssertTrue(state.interrupted, "body events do not clear the latch on a timer")
        XCTAssertFalse(engine.hasPendingDeltas)
    }

    func testAStaleStartInsideTheWindowIsStillDropped() {
        let engine = TurnEngine()
        engine.appendUserEntry(sessionID: session, text: "go")
        engine.apply(GatewayEvent(type: "message.start", sessionID: session, payload: .null, params: .null))
        engine.markInterrupted(sessionID: session)

        engine.apply(GatewayEvent(type: "message.start", sessionID: session, payload: .null, params: .null))
        XCTAssertFalse(engine.state(for: session).isBusy, "a stale same-turn start must stay dropped")
        XCTAssertTrue(engine.state(for: session).interrupted)
    }

    func testAStartAfterTheWindowOpensANewTurnWithoutAResend() {
        let engine = TurnEngine()
        engine.appendUserEntry(sessionID: session, text: "go")
        engine.apply(GatewayEvent(type: "message.start", sessionID: session, payload: .null, params: .null))
        engine.flush()
        engine.markInterrupted(sessionID: session, at: Date().addingTimeInterval(-60))

        engine.apply(GatewayEvent(type: "message.start", sessionID: session, payload: .null, params: .null))
        XCTAssertTrue(engine.state(for: session).isBusy)
        XCTAssertFalse(engine.state(for: session).interrupted)
        engine.apply(GatewayEvent(
            type: "message.delta",
            sessionID: session,
            payload: .object(["text": .string("the desktop's reply")]),
            params: .null
        ))
        engine.flush()
        XCTAssertEqual(
            engine.state(for: session).entries.last { $0.kind == .assistant }?.text,
            "the desktop's reply"
        )
    }

    func testAForeignOriginStartOpensWithoutWaitingForTheClock() {
        let engine = TurnEngine()
        engine.setLocalOrigin("phone")
        engine.appendUserEntry(sessionID: session, text: "go")
        engine.apply(GatewayEvent(type: "message.start", sessionID: session, payload: .null, params: .null))
        engine.markInterrupted(sessionID: session)

        engine.apply(GatewayEvent(
            type: "message.start",
            sessionID: session,
            payload: .null,
            params: .object(["origin": .string("desktop")])
        ))
        XCTAssertTrue(engine.state(for: session).isBusy)
        engine.apply(GatewayEvent(
            type: "message.delta",
            sessionID: session,
            payload: .object(["text": .string("the desktop's reply")]),
            params: .object(["origin": .string("desktop")])
        ))
        engine.flush()
        XCTAssertEqual(
            engine.state(for: session).entries.last { $0.kind == .assistant }?.text,
            "the desktop's reply"
        )
    }

    func testTerminalFrameStillReleasesSoALaterTurnCanRender() {
        let engine = TurnEngine()
        engine.appendUserEntry(sessionID: session, text: "go")
        engine.apply(GatewayEvent(type: "message.start", sessionID: session, payload: .null, params: .null))
        engine.flush()
        engine.markInterrupted(sessionID: session)

        engine.apply(GatewayEvent(
            type: "message.complete",
            sessionID: session,
            payload: .object([
                "text": .string("partial stale full completion"),
                "status": .string("interrupted"),
            ]),
            params: .null
        ))
        XCTAssertFalse(engine.state(for: session).interrupted)

        engine.apply(GatewayEvent(type: "message.start", sessionID: session, payload: .null, params: .null))
        engine.apply(GatewayEvent(
            type: "message.delta",
            sessionID: session,
            payload: .object(["text": .string("a later turn")]),
            params: .null
        ))
        engine.flush()
        XCTAssertEqual(
            engine.state(for: session).entries.last { $0.kind == .assistant }?.text,
            "a later turn"
        )
    }
}
