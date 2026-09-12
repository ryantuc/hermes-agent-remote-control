import XCTest

@testable import HermesServeKit

/// D3 fan-out attribution: `origin` on a session event frame names the
/// connection whose turn it is, and `message.start` is where the engine reads
/// it into `turnStartedLocally`. Closes the branch's one deliberate gap — a
/// queued prompt draining after a Stop arrived stamped with OUR origin and
/// was still presented as another client's turn.
final class TurnOriginTests: XCTestCase {
    private let session = "a1b2c3d4"
    private let selfOrigin = "conn-self"
    private let peerOrigin = "conn-desktop"

    /// A `message.start` in the D3 wire shape: `origin` rides on the event's
    /// **params**, beside `type` and `session_id` — never inside the payload
    /// (D3-SPEC item 9) — and `message.start` still has no payload key at all.
    private func start(origin: String?) -> GatewayEvent {
        var params: [String: JSONValue] = [
            "type": .string("message.start"),
            "session_id": .string(session),
        ]
        if let origin { params["origin"] = .string(origin) }
        return GatewayEvent(type: "message.start", sessionID: session, payload: .null, params: .object(params))
    }

    private func complete(status: String, origin: String?) -> GatewayEvent {
        var params: [String: JSONValue] = [
            "type": .string("message.complete"),
            "session_id": .string(session),
        ]
        if let origin { params["origin"] = .string(origin) }
        return GatewayEvent(
            type: "message.complete",
            sessionID: session,
            payload: .object(["text": .string("partial stale"), "status": .string(status)]),
            params: .object(params)
        )
    }

    // MARK: Wire shape

    /// Pins the D3 frame shape end to end at the codec: `origin` decodes on
    /// `params` (kept whole by `GatewayEvent`), not on the payload — and a
    /// `message.start` stamped this way still has a `.null` payload. GREEN
    /// before the fix; it is the contract pin that fails first if the field
    /// ever moves.
    func testOriginDecodesOnEventParams() throws {
        let line = #"{"jsonrpc":"2.0","method":"event","params":{"type":"message.start","session_id":"a1b2c3d4","origin":"conn-self"}}"#
        guard case .event(let event) = try JSONRPCCodec.decodeFrame(line) else {
            return XCTFail("expected an event frame")
        }
        XCTAssertEqual(event.type, "message.start")
        XCTAssertEqual(event.sessionID, session)
        XCTAssertTrue(event.payload.isNull, "message.start still has no payload key")
        XCTAssertEqual(
            event.params["origin"]?.coercedString, "conn-self",
            "origin rides on params — the field the engine compares"
        )
    }

    // MARK: Attribution

    /// THE gap in the mirroring work: Stop a local turn, let its terminal frame
    /// release the latch (2a), then drain the queued prompt — a NEW turn,
    /// started by THIS client, arriving with OUR origin and no
    /// `appendUserEntry` to claim it.
    func testOwnOriginMessageStartAfterAStopClaimsTheTurn() {
        let engine = TurnEngine()
        engine.setLocalOrigin(selfOrigin)

        engine.appendUserEntry(sessionID: session, text: "first prompt")
        engine.apply(start(origin: selfOrigin))
        engine.markInterrupted(sessionID: session)
        // The cancelled turn's own terminal frame releases the latch (2a).
        engine.apply(complete(status: "interrupted", origin: selfOrigin))
        XCTAssertFalse(engine.state(for: session).interrupted, "the terminal frame must release the latch")

        // The queued prompt drains: a new turn, stamped with OUR origin.
        engine.apply(start(origin: selfOrigin))
        let state = engine.state(for: session)
        XCTAssertTrue(state.isBusy, "the drained turn is running")
        XCTAssertTrue(
            state.turnStartedLocally,
            "a message.start carrying this connection's own origin is this client's turn — presenting the drained queued prompt as another client's is the gap this closes"
        )
    }

    /// The other direction: a peer's `message.start` disowns a stale local
    /// claim. `appendUserEntry` claims optimistically at the tap and
    /// `removeEntry` (the failed-submit rollback) never clears the claim, so
    /// without origin the desktop's next turn would render as ours.
    func testPeerOriginMessageStartDisownsAStaleLocalClaim() {
        let engine = TurnEngine()
        engine.setLocalOrigin(selfOrigin)

        let entryID = engine.appendUserEntry(sessionID: session, text: "never acknowledged")
        engine.removeEntry(sessionID: session, entryID: entryID)
        XCTAssertTrue(
            engine.state(for: session).turnStartedLocally,
            "the rollback leaves the stale claim — the seam this test stages"
        )

        engine.apply(start(origin: peerOrigin))
        let state = engine.state(for: session)
        XCTAssertTrue(state.isBusy)
        XCTAssertFalse(
            state.turnStartedLocally,
            "a message.start carrying a different connection's origin is another client's turn, whatever stale claim this client held"
        )
    }

    /// The inertness contract, both halves: with no origin on the frame —
    /// every backend without D3 — `message.start` must leave the flag exactly
    /// as it was, claimed or not. GREEN before and after the fix; this is the
    /// guard that keeps the fix from reaching backends that never stamp.
    func testOriginlessMessageStartLeavesTheClaimAlone() {
        let engine = TurnEngine()
        engine.setLocalOrigin(selfOrigin)

        // Claimed: a local send followed by its own unstamped start.
        engine.appendUserEntry(sessionID: session, text: "go")
        engine.apply(start(origin: nil))
        XCTAssertTrue(
            engine.state(for: session).turnStartedLocally,
            "an unstamped start must not disown a local send"
        )

        // Unclaimed: a bare unstamped start on a fresh session stays foreign.
        let other = "ff001122"
        engine.apply(GatewayEvent(type: "message.start", sessionID: other, payload: .null, params: .null))
        XCTAssertFalse(
            engine.state(for: other).turnStartedLocally,
            "an unstamped start must not claim a turn either"
        )
    }

    /// The reserved auto-continue stamp names no client and decides nothing:
    /// the resume projection's claim on an auto-continued turn of OURS must
    /// survive it, and an unclaimed session must not become ours from it.
    /// GREEN before and after; it pins the carve-out.
    func testAutoContinueOriginDecidesNothing() {
        let engine = TurnEngine()
        engine.setLocalOrigin(selfOrigin)

        engine.appendUserEntry(sessionID: session, text: "mine")
        engine.apply(start(origin: "auto_continue"))
        XCTAssertTrue(
            engine.state(for: session).turnStartedLocally,
            "auto_continue must not disown the local claim"
        )

        let other = "ff001122"
        engine.apply(GatewayEvent(
            type: "message.start", sessionID: other, payload: .null,
            params: .object(["origin": .string("auto_continue")])
        ))
        XCTAssertFalse(
            engine.state(for: other).turnStartedLocally,
            "auto_continue must not claim a turn either"
        )
    }

    /// Reconnect rotates the origin: `gateway.ready` on the new socket hands
    /// out a new transport id, `setLocalOrigin` re-arms the comparison, and a
    /// frame still stamped with the OLD id no longer names this connection.
    func testReconnectRotatesTheLocalOrigin() {
        let engine = TurnEngine()
        engine.setLocalOrigin("conn-old")
        engine.apply(start(origin: "conn-old"))
        XCTAssertTrue(
            engine.state(for: session).turnStartedLocally,
            "a message.start carrying this connection's current origin claims the turn"
        )

        engine.setLocalOrigin("conn-new")
        engine.apply(start(origin: "conn-old"))
        XCTAssertFalse(
            engine.state(for: session).turnStartedLocally,
            "after a reconnect the old transport id no longer names this connection"
        )
    }
}
