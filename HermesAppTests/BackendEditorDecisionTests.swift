import Foundation
import HermesServeKit
import XCTest

@testable import HermesMobile

/// FEAT-030 — the backend editor's decisions.
///
/// Three defects were reported against this form: the add-a-backend section
/// felt clunky, the authentication-method row wrapped to two lines when it
/// should be one, and nothing on screen said that testing the connection is
/// not a precondition for saving. Each has a decision behind it that can be
/// asserted without hosting a view, and each is one of these tests.
@MainActor
final class BackendEditorDecisionTests: XCTestCase {

    // MARK: The Method row

    /// The row was two lines because nothing constrained the menu's title and
    /// the widest of them — "Session token (loopback)" — needed more room than
    /// the row had beside a label. Short titles are the first of the three
    /// parts of the fix; the other two are layout attributes on the row.
    func testEveryMethodTitleIsShortEnoughToSitOnOneLine() {
        for method in BackendAuthMethod.allCases {
            XCTAssertFalse(method.title.isEmpty)
            XCTAssertLessThanOrEqual(
                method.title.count, 13,
                "\(method.title) is \(method.title.count) characters; the long forms are what wrapped the row"
            )
            XCTAssertFalse(
                method.title.contains("("),
                "a parenthetical belongs in the credential field's footer, beside the field it is about — not in a menu title that has to fit on one line"
            )
        }
        XCTAssertEqual(
            BackendAuthMethod.allCases.map(\.title),
            ["Password", "Bearer token", "Session token", "None"],
            "the menu's order and words are the screen; pin them"
        )
    }

    /// `.auto` is a wire value, not a menu row — the editor decides at typing
    /// time now. A profile still carrying it displays as the credential field
    /// it has always shown.
    func testAutoDisplaysAsSessionTokenRatherThanAsItsOwnRow() {
        XCTAssertEqual(BackendAuthMethod.from(.auto), .sessionToken)
        XCTAssertEqual(BackendAuthMethod.from(.password), .password)
        XCTAssertEqual(BackendAuthMethod.from(.bearer), .bearer)
        XCTAssertEqual(BackendAuthMethod.from(.sessionToken), .sessionToken)
        XCTAssertEqual(BackendAuthMethod.from(.none), .none)
        XCTAssertFalse(
            BackendAuthMethod.allCases.contains { $0.authMode == .auto },
            "'Detect automatically' was a row asking the user to defer a decision the address field now makes for them"
        )
    }

    // MARK: Save

    /// Save depends on the address and the credential. It does **not** depend
    /// on the probe, and it does not depend on the test — which is the whole
    /// point: the two controls used to share one predicate (`isUsable`, URL
    /// parseability alone) so they lit up and went dark together, which reads
    /// as an ordering nothing enforced.
    func testSaveDependsOnTheAddressAndTheCredentialAndNothingElse() {
        let noAddress = BackendSaveDecision.decide(
            addressParses: false,
            method: .password,
            typedCredential: "hunter2",
            hasStoredCredential: false
        )
        XCTAssertFalse(noAddress.isEnabled)
        XCTAssertEqual(noAddress.reason, "Enter the backend's address to save.")

        let noPassword = BackendSaveDecision.decide(
            addressParses: true,
            method: .password,
            typedCredential: "   ",
            hasStoredCredential: false
        )
        XCTAssertFalse(noPassword.isEnabled, "whitespace is not a password")
        XCTAssertEqual(
            noPassword.reason, "Enter the password to save.",
            "a disabled control that does not say what is missing is the clunkiness that was reported"
        )

        let ready = BackendSaveDecision.decide(
            addressParses: true,
            method: .password,
            typedCredential: "hunter2",
            hasStoredCredential: false
        )
        XCTAssertTrue(ready.isEnabled)
        XCTAssertNil(ready.reason)
    }

    /// Editing a saved backend's name must not demand its password again. The
    /// editor never reads a secret back into its field, so a stored credential
    /// has to count.
    func testAStoredCredentialSatisfiesSave() {
        let decision = BackendSaveDecision.decide(
            addressParses: true,
            method: .password,
            typedCredential: "",
            hasStoredCredential: true
        )
        XCTAssertTrue(decision.isEnabled)
        XCTAssertNil(decision.reason)
    }

    /// `.none` sends no credential by definition, so there is nothing to be
    /// missing.
    func testNoAuthenticationNeedsNoCredential() {
        let decision = BackendSaveDecision.decide(
            addressParses: true,
            method: .none,
            typedCredential: "",
            hasStoredCredential: false
        )
        XCTAssertTrue(decision.isEnabled)
        XCTAssertNil(decision.reason)
    }

    func testEachMethodNamesItsOwnMissingCredential() {
        XCTAssertEqual(
            BackendSaveDecision.decide(addressParses: true, method: .bearer, typedCredential: "", hasStoredCredential: false).reason,
            "Enter the access token to save."
        )
        XCTAssertEqual(
            BackendSaveDecision.decide(addressParses: true, method: .sessionToken, typedCredential: "", hasStoredCredential: false).reason,
            "Enter the session token to save."
        )
    }

    /// The sentence under Save, which is the answer to "must I test first".
    func testSaveCarriesTheSentenceThatAnswersTheQuestion() {
        XCTAssertEqual(
            BackendSaveDecision.caption,
            "Save connects right away. Testing first is optional.",
            "the form has to say clearly that testing is not a precondition; this is that indication and it is on screen in every state"
        )
    }

    // MARK: The probe's status line

    func testTheStatusLineSaysWhatTheProbeFound() {
        XCTAssertNil(BackendProbeState.idle.statusLine, "an untouched field says nothing")
        XCTAssertEqual(BackendProbeState.probing.statusLine, "Looking for a backend…")
        XCTAssertEqual(
            BackendProbeState.found(version: "0.20.5", authRequired: true).statusLine,
            "Hermes 0.20.5 · sign-in required"
        )
        XCTAssertEqual(
            BackendProbeState.found(version: "0.20.5", authRequired: false).statusLine,
            "Hermes 0.20.5 · no sign-in needed"
        )
        XCTAssertEqual(
            BackendProbeState.found(version: "", authRequired: true).statusLine,
            "Hermes · sign-in required",
            "a backend that answers without naming a version is still a backend that answered"
        )
        XCTAssertEqual(
            BackendProbeState.notFound(reason: "").statusLine,
            "Nothing answered at this address"
        )
        XCTAssertEqual(
            BackendProbeState.notFound(reason: "timed out").statusLine,
            "Nothing answered at this address — timed out"
        )
    }

    func testTheProbeStateKnowsWhichOfItsStatesItIsIn() {
        XCTAssertTrue(BackendProbeState.probing.isProbing)
        XCTAssertFalse(BackendProbeState.idle.isProbing)
        XCTAssertTrue(BackendProbeState.found(version: "0.20.5", authRequired: false).didFind)
        XCTAssertFalse(BackendProbeState.notFound(reason: "timed out").didFind)
        XCTAssertFalse(BackendProbeState.idle.didFind)
    }

    /// The short causes the status line carries, in the words a person uses.
    /// `localizedDescription` is a sentence and a half; the line has room for a
    /// clause.
    func testTheFailureReasonIsAShortCause() {
        XCTAssertEqual(BackendProbeReason.short(for: URLError(.timedOut)), "timed out")
        XCTAssertEqual(BackendProbeReason.short(for: URLError(.cannotConnectToHost)), "connection refused")
        XCTAssertEqual(
            BackendProbeReason.short(for: URLError(.serverCertificateUntrusted)),
            "certificate not trusted"
        )
        XCTAssertEqual(BackendProbeReason.short(for: URLError(.notConnectedToInternet)), "this device is offline")
        XCTAssertEqual(BackendProbeReason.short(for: URLError(.cannotFindHost)), "no such host")
    }

    /// **The probe's error arrives flattened, and this is the pass that reads
    /// it.** `AuthenticationClient.perform` maps anything it does not recognise
    /// to `HermesError.connectFailed(ns.localizedDescription)`, so by the time
    /// the editor sees a refused connection the `URLError.Code` is gone and all
    /// that is left is the sentence. Photographed before it was handled: the
    /// status line read "Nothing answered at this address — Could not connect to
    /// the server.", which says the same thing twice with a capital letter in
    /// the middle.
    func testAFlattenedNetworkErrorIsStillReadAsAShortCause() {
        XCTAssertEqual(
            BackendProbeReason.short(for: HermesError.connectFailed("Could not connect to the server.")),
            "connection refused"
        )
        XCTAssertEqual(
            BackendProbeReason.short(for: HermesError.connectFailed("The request timed out.")),
            "timed out"
        )
        XCTAssertEqual(
            BackendProbeReason.short(for: HermesError.connectFailed("A server with the specified hostname could not be found.")),
            "no such host"
        )
        XCTAssertEqual(
            BackendProbeReason.short(for: HermesError.connectFailed("The certificate for this server is invalid. You might be connecting to a server that is pretending to be …")),
            "certificate not trusted"
        )
    }

    /// Anything unrecognised is kept rather than swallowed — a cause we did not
    /// anticipate is still a cause — but lowered into a clause, because it is
    /// being appended to a sentence that has already started.
    func testAnUnrecognisedCauseIsKeptAsAClause() {
        XCTAssertEqual(
            BackendProbeReason.short(for: HermesError.connectFailed("Something nobody predicted happened.")),
            "something nobody predicted happened"
        )
        XCTAssertEqual(
            BackendProbeReason.short(for: HermesError.missingCredential("Enter the password for you.")),
            "enter the password for you",
            "the text survives; only the sentence punctuation goes"
        )
        XCTAssertEqual(
            BackendProbeReason.short(for: HermesError.connectFailed("HTTP 502: bad gateway")),
            "HTTP 502: bad gateway",
            "an acronym is not a sentence and must not be lowercased"
        )
    }

    // MARK: What the probe cannot know

    /// Stated as a test because it is the limit the UI does not say out loud:
    /// `/api/status` reports whether the backend is gated, never which
    /// credential you hold.
    func testTheSuggestedModeIsAGuessAboutTheGateAndNotAboutTheCredential() {
        let gated = ServerStatus(json: .object([
            "version": .string("0.20.5"),
            "auth_required": .bool(true),
            "auth_flows": .array([.string("cookie")]),
        ]))
        XCTAssertEqual(
            gated.suggestedAuthMode, .password,
            "inside gated mode the route cannot tell bearer from password, and the desktop's rule resolves that by fiat"
        )
        let loopback = ServerStatus(json: .object([
            "version": .string("0.20.5"),
            "auth_required": .bool(false),
        ]))
        XCTAssertEqual(
            loopback.suggestedAuthMode, .sessionToken,
            "and on loopback it cannot tell a session token from none"
        )
    }
}
