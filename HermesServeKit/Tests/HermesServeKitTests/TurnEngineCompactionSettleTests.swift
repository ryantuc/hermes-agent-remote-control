import XCTest

@testable import HermesServeKit

/// A manual compaction on current upstream holds the session `running` for its whole duration and ends with a `session.info` carrying `running: false` and no terminal frame (`tui_gateway/session_compression.py`, `_manual_compress_turn`). A chat resumed mid-compaction took `isBusy` from the resume and had nothing to end it but Stop.
final class TurnEngineCompactionSettleTests: XCTestCase {
    private let session = "c0a1b2c3"

    private func resumedMidCompaction(_ engine: TurnEngine) {
        // The memberwise shape, since the resume result is decoded by `SessionAPI` rather than from one JSON object: a session the gateway reports running, with nothing in flight and no history.
        let result = SessionResumeResult(
            sessionID: session,
            resumed: "20261009_compact",
            sessionKey: "20261009_compact",
            messages: [],
            info: SessionInfo(json: .object(["model": .string("m"), "running": .bool(true)])),
            inflight: nil,
            queued: nil,
            autoContinue: nil,
            running: true,
            status: "working",
            watching: false,
            turnStartedAt: nil,
            pendingApproval: nil,
            pendingClarify: nil,
            todoState: nil,
            pendingConnection: nil
        )
        engine.applyResumeProjection(sessionID: session, result: result, trailingUserTexts: [])
        XCTAssertTrue(engine.state(for: session).isBusy, "precondition: a resume that says running is busy")
    }

    private func sessionInfo(running: Bool) -> GatewayEvent {
        GatewayEvent(
            type: "session.info",
            sessionID: session,
            payload: .object(["model": .string("m"), "running": .bool(running)]),
            params: .null
        )
    }

    /// The defect: the closing `session.info` is the compaction's only end, and the chat stays busy forever.
    func testTheClosingSessionInfoOfACompactionSettlesAChatResumedDuringIt() {
        let engine = TurnEngine()
        resumedMidCompaction(engine)

        engine.apply(sessionInfo(running: false))

        let state = engine.state(for: session)
        XCTAssertFalse(state.isBusy, "the compaction ended with running: false and nothing is streaming, so the chat is not working")
        XCTAssertEqual(state.statusText, "")
        XCTAssertNil(state.turnStartedAt)
    }

    /// A `session.info` that still says running changes nothing.
    func testASessionInfoThatSaysRunningKeepsTheChatBusy() {
        let engine = TurnEngine()
        resumedMidCompaction(engine)
        engine.apply(sessionInfo(running: true))
        XCTAssertTrue(engine.state(for: session).isBusy)
    }

    /// With a reply streaming, the turn's end is its terminal frame, not a `session.info`; a frame saying `running: false` under a live stream is not believed over the stream.
    func testASessionInfoUnderAStreamingReplyDoesNotEndTheTurn() {
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
        XCTAssertTrue(engine.state(for: session).isBusy)

        engine.apply(sessionInfo(running: false))
        XCTAssertTrue(engine.state(for: session).isBusy, "a streaming bubble owns the turn's end")
    }
}
