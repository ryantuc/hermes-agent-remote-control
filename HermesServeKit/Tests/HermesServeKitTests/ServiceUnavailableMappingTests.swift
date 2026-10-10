import Foundation
import XCTest

@testable import HermesServeKit

/// FEAT-038 — a 503 is not always the auth gate, so the client must not say "auth provider" for one it cannot attribute.
///
/// Since 0.21.0 the session routes the phone calls answer 503 when `state.db` is unreadable (`hermes_cli/web_routers/sessions.py` `_resolve_session_id`, `_common.py` `corrupt_store_as_status`), and the client mapped every 503 to `.providerUnreachable`, rendered "The backend's auth provider is unreachable: …". The bodies below are the live backend's own, copied from its source.
final class ServiceUnavailableMappingTests: XCTestCase {

    /// `{"detail": <string>}`, FastAPI's `HTTPException` envelope.
    private func body(detail: String) -> Data {
        (try? JSONSerialization.data(withJSONObject: ["detail": detail])) ?? Data()
    }

    /// `corrupt_store_as_status` raises `HTTPException(detail={**detail, "path": key})`, so the sentence is one level down.
    private func body(structured fields: [String: String]) -> Data {
        (try? JSONSerialization.data(withJSONObject: ["detail": fields])) ?? Data()
    }

    private func mapped(_ data: Data, status: Int = 503, file: StaticString = #filePath, line: UInt = #line) -> HermesError? {
        do {
            try AuthenticationClient.validate(status: status, data: data)
            XCTFail("a \(status) must throw", file: file, line: line)
            return nil
        } catch let error as HermesError {
            return error
        } catch {
            XCTFail("expected a HermesError, got \(error)", file: file, line: line)
            return nil
        }
    }

    private func rendered(_ error: HermesError?) -> String {
        error?.errorDescription ?? ""
    }

    /// The store sentences, as the 0.21.0 report quoted one and as the current source spells the others.
    private let storeSentences = [
        "session store unavailable — state.db could not be read",
        "Session store is corrupt (database disk image is malformed). Sessions cannot be read until it is repaired — run `hermes doctor` for diagnosis.",
        "Session store is busy (disk I/O or lock). Retry; the list was not cleared.",
    ]

    func testABrokenSessionStoreDoesNotBlameTheAuthProvider() {
        for sentence in storeSentences {
            let text = rendered(mapped(body(detail: sentence)))
            XCTAssertNil(text.range(of: "auth provider", options: .caseInsensitive), "a store failure blamed the auth provider: \(text)")
            XCTAssertTrue(text.contains(sentence), "the backend's own sentence must survive: \(text)")
        }
    }

    /// The structured shape used to fall through to the raw body, so the user read a JSON object with a local file path in it.
    func testAStructuredStoreDetailShowsItsMessageNotTheEnvelope() {
        let message = "state.db was replaced while Hermes was running — stop Hermes, run `hermes doctor`, then start it again. Do not run `hermes doctor --fix`, which would repair the wrong file in place."
        let data = body(structured: ["error": "state_db_replaced", "message": message, "path": "/Users/someone/.hermes/state.db"])
        let text = rendered(mapped(data))
        XCTAssertTrue(text.contains(message), "the message inside the detail object must be shown: \(text)")
        XCTAssertFalse(text.contains("{"), "the JSON envelope leaked into the sentence: \(text)")
        XCTAssertFalse(text.contains("/Users/someone"), "the store path is not part of the sentence: \(text)")
        XCTAssertNil(text.range(of: "auth provider", options: .caseInsensitive), text)
    }

    /// The acceptance's second half: a genuine gate 503 already names the provider, so it must read once, not "auth provider is unreachable: Auth provider 'nous' unreachable".
    func testTheAuthGatesOwnSentenceReadsOnce() {
        let text = rendered(mapped(body(detail: "Auth provider 'nous' unreachable")))
        XCTAssertTrue(text.contains("Auth provider 'nous' unreachable"), text)
        XCTAssertEqual(text.components(separatedBy: "unreachable").count - 1, 1, "the outage is stated twice: \(text)")
    }

    /// Every gate 503 carries a detail (`request_utils.py` `unreachable_response`, `routes.py` `_http(503, …)`), so an empty one is never the gate and the client knows nothing about why.
    func testAnEmpty503MakesNoClaimItCannotBack() {
        let text = rendered(mapped(Data()))
        XCTAssertNil(text.range(of: "auth provider", options: .caseInsensitive), "an unattributed 503 blamed the auth provider: \(text)")
        XCTAssertFalse(text.trimmingCharacters(in: .whitespaces).hasSuffix(":"), "dangling colon: '\(text)'")
        XCTAssertTrue(text.contains("503"), "the status is the one thing the client does know: \(text)")
    }

    /// The reason the auth case existed: a 503 is "retry", never "sign in again" and never a transport drop.
    func testA503IsNeverASignInFailure() {
        let bodies = storeSentences.map { body(detail: $0) } + [body(detail: "Auth provider 'nous' unreachable"), body(detail: "no auth providers registered"), Data()]
        for data in bodies {
            let error = mapped(data)
            XCTAssertEqual(error?.isAuthenticationFailure, false, "\(String(describing: error))")
            XCTAssertEqual(error?.isTransportFailure, false, "\(String(describing: error))")
        }
    }

    /// A 503 detail reaches the screen and the shareable connection log, so it is scrubbed like every other status's detail.
    func testA503DetailIsRedacted() {
        let text = rendered(mapped(body(detail: "upstream proxy said Authorization: Bearer abcdefghijklmnopqrstuvwx")))
        XCTAssertFalse(text.contains("abcdefghijklmnopqrstuvwx"), "a credential in a 503 detail reached the message: \(text)")
    }

    /// The neighbours keep their mapping.
    func testOtherStatusesAreUnchanged() {
        XCTAssertEqual(mapped(body(detail: "nope"), status: 401), .unauthorized("nope"))
        XCTAssertEqual(mapped(body(detail: "missing"), status: 404), .httpStatus(code: 404, message: "missing"))
        XCTAssertNoThrow(try AuthenticationClient.validate(status: 204, data: Data()))
    }
}
