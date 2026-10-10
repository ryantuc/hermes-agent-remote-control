import Foundation
import XCTest

@testable import HermesServeKit

/// BUG-146 (`RestAPI.sendJSON`) — a 2xx body that is not JSON must not read as an empty success.
///
/// `sendJSON` answered `.null` both for an empty body and for one it could not decode, so a captive portal's 200 page or a cut-off reply looked exactly like a 204. Its callers then filled the gap with a default: `GitAPI.switchBranch` reports the branch it asked for, `makeDirectory` the path it asked for, `AudioAPI.transcribe` an empty transcript, and every toggle in Capabilities and Messaging keeps its new state. `AuthenticationClient.performJSON`, which every GET goes through, already throws for the same body.
final class SendJSONResponseBodyTests: XCTestCase {

    private func data(_ text: String) -> Data { Data(text.utf8) }

    func testAnEmptyBodyIsStillTheEmptySuccess() throws {
        XCTAssertEqual(try RestAPI.sendResponseBody(Data()), .null)
    }

    func testAJSONBodyIsDecoded() throws {
        let json = try RestAPI.sendResponseBody(data(#"{"branch": "main", "ok": true}"#))
        XCTAssertEqual(json["branch"]?.coercedString, "main")
        XCTAssertEqual(json["ok"]?.coercedBool, true)
    }

    /// The shape that matters in the field: something between the phone and the backend answered 200 with a page, and the mutation never arrived.
    func testANonJSONBodyIsAnErrorNotAnEmptySuccess() {
        XCTAssertThrowsError(try RestAPI.sendResponseBody(data("<html><body>Sign in to the hotel Wi-Fi</body></html>"))) { error in
            guard case .malformedResponse = error as? HermesError else {
                return XCTFail("expected malformedResponse, got \(error)")
            }
        }
    }

    func testACutOffJSONBodyIsAnError() {
        XCTAssertThrowsError(try RestAPI.sendResponseBody(data(#"{"branch": "ma"#)))
    }

    /// The error carries a preview of the body, and the body is whatever the far end sent, so the preview is scrubbed the way `performJSON`'s is.
    func testTheBodyPreviewInTheErrorIsRedacted() {
        XCTAssertThrowsError(try RestAPI.sendResponseBody(data("password=hunter2hunter2 is not json"))) { error in
            let text = (error as? HermesError)?.errorDescription ?? "\(error)"
            XCTAssertFalse(text.contains("hunter2hunter2"), "the preview leaked a credential: \(text)")
        }
    }
}
