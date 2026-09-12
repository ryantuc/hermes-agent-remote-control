import XCTest

@testable import HermesServeKit

/// A9 — clarify countdown must honour a payload-carried timeout when one
/// exists, and fall back to the kit default when the payload is silent.
///
/// Current backends (`tui_gateway/server.py` `_block`) do **not** put the
/// timeout on the wire; the app layer then falls back to configured
/// `agent.clarify_timeout`. That config path is untested here — this target
/// only covers the decode half.
final class ClarifyTimeoutTests: XCTestCase {

    /// A future backend that adds `timeout` (or `timeout_seconds`) must have
    /// that value land on `wireTimeoutSeconds` and drive `timeoutSeconds`.
    func testPayloadCarriedTimeoutIsDecoded() {
        let withTimeout = projectClarify(payload: .object([
            "request_id": .string("c1"),
            "question": .string("Pick one"),
            "choices": .array([.string("a"), .string("b")]),
            "timeout": .number(120),
        ]))
        XCTAssertEqual(withTimeout.wireTimeoutSeconds, 120,
                       "timeout on the payload must be decoded, not ignored")
        XCTAssertEqual(withTimeout.timeoutSeconds, 120,
                       "timeoutSeconds must prefer the wire value over the default")

        let altKey = projectClarify(payload: .object([
            "request_id": .string("c2"),
            "question": .string("Pick one"),
            "timeout_seconds": .number(45),
        ]))
        XCTAssertEqual(altKey.wireTimeoutSeconds, 45,
                       "timeout_seconds is an accepted alternate key")
        XCTAssertEqual(altKey.timeoutSeconds, 45)
    }

    /// Today's wire shape: question + choices + request_id, no timeout field.
    /// The kit must leave wireTimeoutSeconds nil so the app can fall back to
    /// config, and expose 3600 as the last-resort default.
    func testMissingTimeoutFallsBackToDefault() {
        let event = projectClarify(payload: .object([
            "request_id": .string("c3"),
            "question": .string("Still there?"),
            "choices": .array([.string("yes")]),
        ]))
        XCTAssertNil(event.wireTimeoutSeconds,
                     "current backends omit timeout; wireTimeoutSeconds must stay nil so config can answer")
        XCTAssertEqual(event.timeoutSeconds, ClarifyRequestEvent.defaultTimeoutSeconds)
        XCTAssertEqual(ClarifyRequestEvent.defaultTimeoutSeconds, 3600,
                       "last-resort default must match hermes_cli/config_defaults.py agent.clarify_timeout")
    }

    // MARK: - Helpers

    private func projectClarify(payload: JSONValue) -> ClarifyRequestEvent {
        let params: JSONValue = .object([
            "type": .string("clarify.request"),
            "session_id": .string("sess-1"),
            "payload": payload,
        ])
        let gateway = GatewayEvent(
            type: "clarify.request",
            sessionID: "sess-1",
            payload: payload,
            params: params
        )
        guard case .clarifyRequest(let event) = HermesEvent.project(gateway) else {
            XCTFail("expected .clarifyRequest projection")
            return ClarifyRequestEvent(
                id: "", sessionID: "", question: "", choices: [], multiSelect: false
            )
        }
        return event
    }
}
