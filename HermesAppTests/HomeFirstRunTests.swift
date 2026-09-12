import Foundation
import HermesServeKit
import XCTest

@testable import HermesMobile

/// FEAT-003 — a cold start with no backend configured.
///
/// The app's core function is a conversation with the user's own
/// `hermes serve`, so on a device where none has been configured there is
/// nothing to talk to. What the first screen said about that was: a decorative
/// wordmark, a "Not connected" banner, and a send that does nothing when
/// tapped. An App Store reviewer cannot exercise any core function from there
/// and is told nothing about why — the 4.2 / 2.1(a) gate — and neither is a
/// first-time user.
///
/// These tests pin the state Home reads to decide, and the sentence it says.
/// They are model-level on purpose: the empty state and the reason under the
/// composer must be driven off ONE predicate, so that "is a backend
/// configured" cannot be answered one way by the explainer and another way by
/// the composer.
@MainActor
final class HomeFirstRunTests: XCTestCase {

    /// A model with no stored profiles. `AppModel.init` loads whatever the host
    /// app left in defaults, so the first thing any test here does is clear
    /// them — the same precaution `AppHarness` takes and for the same reason.
    private func freshModel() -> AppModel {
        let app = AppModel()
        app.profiles = []
        return app
    }

    private func scratchProfile() -> BackendProfile {
        BackendProfile(
            name: "workstation",
            baseURLString: "https://hermes.example.com",
            authMode: .sessionToken
        )
    }

    // MARK: RED-1 — with no profile, Home has something to say

    func testNoConfiguredBackendIsAStateHomeCanSee() {
        let app = freshModel()
        defer { app.profiles = [] }

        XCTAssertTrue(
            app.needsBackend,
            "a device with no backend profile is the first-run state and nothing exposed it — Home had no way to tell 'never set up' apart from 'set up and currently offline', so it showed the same decorative wordmark for both"
        )
    }

    func testTheDeadSendCarriesItsOwnReasonWhenNoBackendExists() throws {
        let app = freshModel()
        defer { app.profiles = [] }

        let reason = try XCTUnwrap(
            app.noBackendSendReason,
            "the send is disabled and the only explanation lives in a banner one row up (C-3-009 item 1) — the control that failed must say why itself"
        )
        XCTAssertFalse(reason.isEmpty, "an empty reason is not a reason")
        XCTAssertTrue(
            reason.lowercased().contains("backend"),
            "the reason must name what is missing; got \(reason)"
        )
        XCTAssertTrue(
            reason.lowercased().contains("connect"),
            "a reason that does not say what to do next leaves the user exactly where they were; got \(reason)"
        )
    }

    // MARK: RED-2 — with a profile, it says nothing

    func testAConfiguredBackendEndsTheFirstRunState() {
        let app = freshModel()
        defer { app.profiles = [] }

        app.addProfile(scratchProfile())

        XCTAssertFalse(
            app.needsBackend,
            "the user has configured a backend — an explainer telling them to configure one would sit over their own working conversation"
        )
        XCTAssertNil(
            app.noBackendSendReason,
            "zero-setup chat is sacred: once a backend exists, every other reason a send is blocked belongs to the connection banner and the composer placeholder, not to a permanent line under the composer"
        )
    }

    /// Adding and then removing the only backend puts the state back. Pins the
    /// predicate to the profile list rather than to a one-shot launch flag.
    func testRemovingTheLastBackendRestoresTheFirstRunState() {
        let app = freshModel()
        defer { app.profiles = [] }

        let profile = scratchProfile()
        app.addProfile(profile)
        XCTAssertFalse(app.needsBackend, "precondition: adding a profile must clear the state")

        app.profiles = []

        XCTAssertTrue(
            app.needsBackend,
            "deleting the last backend leaves the app with nothing to talk to again, and it must say so again"
        )
        XCTAssertNotNil(app.noBackendSendReason, "same state, same reason")
    }

    // MARK: RED-3 — the explainer is one sentence, in one place

    /// The Backend settings footer and Home's first-run state show the same
    /// sentence. This pins the text so that a change to it is a deliberate act
    /// in one file, and so that the two screens cannot drift apart.
    func testTheExplainerIsTheOneSentenceBothScreensShow() {
        XCTAssertEqual(
            AppModel.backendExplainer,
            "Hermes runs on your own computer or server. HARC connects directly to it and adds no service of its own — your backend decides which AI providers and tools see your requests.",
            "this sentence is the app's answer to 'what is this and where does my data go' and it is quoted verbatim from the Backend screen — if it changed, change it in AppModel and here, and nowhere else"
        )
    }
}
