import XCTest

@testable import HermesServeKit

/// FEAT-010 — `turn_started_at` is on the wire and the client ignored it.
///
/// The backend stamps it when a turn begins (`tui_gateway/server.py:8038-8039`,
/// `_start_inflight_turn`) and reports it two ways: on the `info` object every
/// `session.info` / `session.create` / `session.resume` carries
/// (`server.py:5931-5936` builds it, `:5955` emits it) and again at the top
/// level of the live-session payload (`server.py:9549-9554`, `:9574`). Both are
/// epoch seconds as a float, and both are `None` on an idle session.
///
/// Everything here is a decode test, so the whole point is that ABSENCE is
/// ordinary: an older backend never sends the key, and a lazily-resumed
/// session's `info` (`_fallback_session_info`, `server.py:9424-9450`) does not
/// carry it either. There is no `Codable` on this wire; a missing key must
/// decode to nil and leave every other field intact.
final class TurnStartedAtTests: XCTestCase {

    private static let epoch: Double = 1_700_000_123.5

    private func sessionInfoPayload(turnStartedAt: JSONValue?) -> JSONValue {
        var fields: [String: JSONValue] = [
            "model": .string("gpt-5"),
            "provider": .string("openai"),
            "cwd": .string("/Users/you/code"),
            "running": .bool(true),
            "desktop_contract": .number(5),
        ]
        if let turnStartedAt { fields["turn_started_at"] = turnStartedAt }
        return .object(fields)
    }

    // MARK: session.info

    func testSessionInfoDecodesTurnStartedAt() {
        let info = SessionInfo(json: sessionInfoPayload(turnStartedAt: .number(Self.epoch)))

        XCTAssertEqual(
            info.turnStartedAt,
            Date(timeIntervalSince1970: Self.epoch),
            "session.info carries the turn's real start; the client has to read it"
        )
        XCTAssertEqual(info.model, "gpt-5", "the rest of the object still decodes")
    }

    func testSessionInfoWithoutTurnStartedAtDecodesToNil() {
        let info = SessionInfo(json: sessionInfoPayload(turnStartedAt: nil))

        XCTAssertNil(info.turnStartedAt, "a backend older than the key must decode, not fail")
        XCTAssertEqual(info.model, "gpt-5")
        XCTAssertTrue(info.running)
    }

    func testSessionInfoNullTurnStartedAtDecodesToNil() {
        // What an IDLE session answers: the key is present and null.
        let info = SessionInfo(json: sessionInfoPayload(turnStartedAt: .null))

        XCTAssertNil(info.turnStartedAt, "null means idle, not epoch zero")
    }

    func testSessionInfoAcceptsTheNumberAsAString() {
        // The gateway is loose about scalar types everywhere else on this wire;
        // the coercing accessors are the house style and this key uses them.
        let info = SessionInfo(json: sessionInfoPayload(turnStartedAt: .string("1700000123.5")))

        XCTAssertEqual(info.turnStartedAt, Date(timeIntervalSince1970: Self.epoch))
    }

    // MARK: the live-session payload

    private func livePayload(
        turnStartedAt: JSONValue?,
        infoTurnStartedAt: JSONValue? = nil
    ) -> JSONValue {
        var fields: [String: JSONValue] = [
            "session_id": .string("99887766"),
            "session_key": .string("20260817_101500_ab12ef"),
            "info": sessionInfoPayload(turnStartedAt: infoTurnStartedAt),
            "running": .bool(true),
            "status": .string("running"),
            "messages": .array([]),
        ]
        if let turnStartedAt { fields["turn_started_at"] = turnStartedAt }
        return .object(fields)
    }

    func testLiveSessionPayloadDecodesTurnStartedAt() {
        let result = SessionAPI.decodeResume(
            livePayload(turnStartedAt: .number(Self.epoch)),
            requested: "20260817_101500_ab12ef"
        )

        XCTAssertEqual(result.turnStartedAt, Date(timeIntervalSince1970: Self.epoch))
        XCTAssertTrue(result.running, "the rest of the payload still decodes")
    }

    func testLiveSessionPayloadWithoutTurnStartedAtDecodesToNil() {
        let result = SessionAPI.decodeResume(
            livePayload(turnStartedAt: nil),
            requested: "20260817_101500_ab12ef"
        )

        XCTAssertNil(result.turnStartedAt)
        XCTAssertNil(result.info.turnStartedAt)
        XCTAssertEqual(result.sessionID, "99887766")
    }

    // MARK: what the engine does with it

    /// The payload's own key wins over `info`. A lazily-resumed session gets the
    /// reduced `_fallback_session_info` shape, which never carries the key, so
    /// reading `info` alone would lose the start on exactly the resume path
    /// that needs it.
    func testResumeProjectionPrefersThePayloadKeyOverInfo() {
        let engine = TurnEngine()
        let result = SessionAPI.decodeResume(
            livePayload(
                turnStartedAt: .number(Self.epoch),
                infoTurnStartedAt: .number(Self.epoch - 600)
            ),
            requested: "20260817_101500_ab12ef"
        )

        engine.applyResumeProjection(sessionID: "99887766", result: result, trailingUserTexts: [])

        XCTAssertEqual(
            engine.state(for: "99887766").turnStartedAt,
            Date(timeIntervalSince1970: Self.epoch)
        )
    }

    func testResumeProjectionFallsBackToInfoWhenThePayloadIsSilent() {
        let engine = TurnEngine()
        let result = SessionAPI.decodeResume(
            livePayload(turnStartedAt: nil, infoTurnStartedAt: .number(Self.epoch)),
            requested: "20260817_101500_ab12ef"
        )

        engine.applyResumeProjection(sessionID: "99887766", result: result, trailingUserTexts: [])

        XCTAssertEqual(
            engine.state(for: "99887766").turnStartedAt,
            Date(timeIntervalSince1970: Self.epoch)
        )
    }

    /// Adopt-only. Only some of the backend's `session.info` emitters build the
    /// payload with `_session_info`; others relay an `info` dict lifted from a
    /// subprocess frame (`server.py:2017`, `:2050`) that need not mention the
    /// key. One of those must not erase a start a fuller frame established.
    func testSessionInfoWithoutTheKeyDoesNotEraseAKnownStart() {
        let engine = TurnEngine()
        let result = SessionAPI.decodeResume(
            livePayload(turnStartedAt: .number(Self.epoch)),
            requested: "20260817_101500_ab12ef"
        )
        engine.applyResumeProjection(sessionID: "99887766", result: result, trailingUserTexts: [])

        engine.apply(GatewayEvent(
            type: "session.info",
            sessionID: "99887766",
            payload: sessionInfoPayload(turnStartedAt: nil),
            params: .null
        ))

        XCTAssertEqual(
            engine.state(for: "99887766").turnStartedAt,
            Date(timeIntervalSince1970: Self.epoch),
            "a session.info that never mentions the key says nothing about the start"
        )
    }

    /// A `session.info` that DOES carry the key is how a turn this client
    /// started locally learns the backend's own measurement of it.
    func testSessionInfoAdoptsTheStartOntoLiveState() {
        let engine = TurnEngine()

        engine.apply(GatewayEvent(
            type: "session.info",
            sessionID: "99887766",
            payload: sessionInfoPayload(turnStartedAt: .number(Self.epoch)),
            params: .null
        ))

        XCTAssertEqual(
            engine.state(for: "99887766").turnStartedAt,
            Date(timeIntervalSince1970: Self.epoch)
        )
    }

    /// And the turn ending is what clears it, so the NEXT turn does not inherit
    /// this one's age while it waits for its first `session.info`.
    func testATurnEndingClearsTheStart() {
        let engine = TurnEngine()
        let result = SessionAPI.decodeResume(
            livePayload(turnStartedAt: .number(Self.epoch)),
            requested: "20260817_101500_ab12ef"
        )
        engine.applyResumeProjection(sessionID: "99887766", result: result, trailingUserTexts: [])
        XCTAssertNotNil(engine.state(for: "99887766").turnStartedAt)

        engine.settleFromStatus(sessionID: "99887766")

        XCTAssertNil(engine.state(for: "99887766").turnStartedAt)
    }
}
