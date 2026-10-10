import XCTest

@testable import HermesMobile

/// The backend editor judged a typed token after trimming it but stored it as typed: a pasted token with a trailing newline was written with the newline, which the backend's byte-for-byte comparison will not match, and three spaces typed over a stored token enabled Save and then replaced the working token with spaces.
///
/// The backend's tokens contain no whitespace (its session token is `secrets.token_urlsafe(32)`, `hermes_cli/web_server.py:368`, compared exactly at `:460`; an access token is a JWT), so whitespace in a token field is never part of the token.
@MainActor
final class BackendCredentialInputTests: XCTestCase {
    func testAPastedTokenIsStoredWithoutItsSpacesAndTrailingNewline() {
        XCTAssertEqual(BackendCredentialInput.secretToStore("  Zk3_-9aQ\n", for: .sessionToken), "Zk3_-9aQ",
                       "the session token was stored with the whitespace it was pasted with")
        XCTAssertEqual(BackendCredentialInput.secretToStore("eyJhbGc.eyJzdWI.c2ln \r\n", for: .bearer), "eyJhbGc.eyJzdWI.c2ln",
                       "the access token was stored with the whitespace it was pasted with")
    }

    func testATokenPastedAcrossTwoLinesIsJoined() {
        XCTAssertEqual(BackendCredentialInput.secretToStore("Zk3_-9aQ\nrT7w", for: .sessionToken), "Zk3_-9aQrT7w")
    }

    func testAWhitespaceOnlyTokenKeepsTheStoredOne() {
        XCTAssertNil(BackendCredentialInput.secretToStore("   ", for: .sessionToken),
                     "three spaces typed over a stored session token would replace it")
        XCTAssertNil(BackendCredentialInput.secretToStore("\n\t ", for: .bearer),
                     "a blank pasted line typed over a stored access token would replace it")
        XCTAssertNil(BackendCredentialInput.secretToStore("", for: .bearer))
    }

    /// The control: a password may contain spaces, so it is stored exactly as typed.
    func testAPasswordIsStoredExactlyAsTyped() {
        XCTAssertEqual(BackendCredentialInput.secretToStore(" two words ", for: .password), " two words ")
        XCTAssertNil(BackendCredentialInput.secretToStore("", for: .password))
    }

    /// The control: Save stays available over a stored token when the field holds only whitespace, because that now means "keep the stored token".
    func testSaveStaysAvailableOverAStoredToken() {
        let decision = BackendSaveDecision.decide(addressParses: true, method: .sessionToken, typedCredential: "   ", hasStoredCredential: true)
        XCTAssertTrue(decision.isEnabled)
        let fresh = BackendSaveDecision.decide(addressParses: true, method: .sessionToken, typedCredential: "   ", hasStoredCredential: false)
        XCTAssertFalse(fresh.isEnabled, "with nothing stored, whitespace is not a token")
    }
}
