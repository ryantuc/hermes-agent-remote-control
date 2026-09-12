import Foundation
import HermesServeKit
import XCTest

@testable import HermesMobile

/// FEAT-030 — one predicate decides "first run", and a cold launch with
/// nothing signed in lands on Home.
///
/// The inventory found two predicates answering the same question and
/// disagreeing: `RootView.bootstrap` routed the launch on
/// `app.activeProfile != nil`, while Home decided its content on
/// `profiles.isEmpty && demo == nil`. A stored `activeProfileID` that no longer
/// resolved to a row satisfied neither the same way — the launch went to
/// Settings → Backend, and Home, had anyone reached it, would have drawn the
/// ordinary wordmark over a dead composer. These tests pin the single predicate
/// the two now share, in each of the states that used to split them.
///
/// They sit beside `HomeFirstRunTests` rather than inside it: that class is
/// FEAT-003's and its assertions are still true.
@MainActor
final class FirstRunPredicateTests: XCTestCase {

    /// `AppModel.init` reads whatever the host app left in `UserDefaults`, so
    /// every test here starts from a cleared list *and* a cleared active id —
    /// the id is a separate key and the older harnesses do not clear it.
    private func freshModel() -> AppModel {
        UserDefaults.standard.removeObject(forKey: "hermes.activeBackendProfile.v1")
        UserDefaults.standard.removeObject(forKey: "hermes.backendProfiles.v1")
        let app = AppModel()
        app.profiles = []
        return app
    }

    private func profile(name: String = "workstation", address: String = "https://hermes.example.com") -> BackendProfile {
        BackendProfile(name: name, baseURLString: address, authMode: .sessionToken)
    }

    // MARK: The predicate

    func testASignedInBackendIsTheOnlyThingThatEndsFirstRun() {
        let app = freshModel()
        defer { app.profiles = [] }

        XCTAssertNil(app.signedInProfile, "precondition: nothing is configured")
        XCTAssertTrue(app.needsBackend)

        app.addProfile(profile())
        XCTAssertNotNil(
            app.signedInProfile,
            "a profile with a parseable address that has not been signed out is a backend this app can open"
        )
        XCTAssertFalse(app.needsBackend)
    }

    /// The state the two old predicates disagreed about, built the way it
    /// actually occurs: a persisted active id whose row is not in the persisted
    /// list, read by a fresh process.
    ///
    /// Under the old pair this launched into Settings → Backend (because
    /// `activeProfile != nil` was false) while Home would have drawn the
    /// ordinary wordmark (because `profiles.isEmpty` was false). One predicate
    /// now, and it says first run.
    func testADanglingActiveIdReadsAsFirstRunAndIsCleared() {
        let app = freshModel()
        defer { app.profiles = [] }

        let real = profile()
        app.profiles = [real]
        UserDefaults.standard.set(UUID().uuidString, forKey: "hermes.activeBackendProfile.v1")

        let relaunched = AppModel()
        defer { relaunched.profiles = [] }
        XCTAssertNil(relaunched.activeProfile, "precondition: the stored id names no row")
        XCTAssertNil(relaunched.signedInProfile)
        XCTAssertTrue(
            relaunched.needsBackend,
            "an active id that resolves to no row is not a backend; `profiles.isEmpty` said it was one"
        )

        // Reconcile adopts a surviving row rather than merely clearing, so a
        // user who still has a backend is not shown a screen offering to
        // connect the one they already have.
        relaunched.reconcileActiveProfile()
        XCTAssertEqual(relaunched.activeProfileID, real.id)
        XCTAssertFalse(relaunched.needsBackend)
        XCTAssertFalse(
            relaunched.activeProfileID != nil && relaunched.activeProfile == nil,
            "reconcile leaves no dangling id: either it names a row or it is nil"
        )
    }

    /// An address that stopped parsing is not something to connect to either.
    func testAnUnusableAddressIsFirstRun() {
        let app = freshModel()
        defer { app.profiles = [] }

        app.addProfile(profile(name: "broken", address: "not a url at all"))
        XCTAssertNil(app.signedInProfile)
        XCTAssertTrue(
            app.needsBackend,
            "the launch used to activate this and surface 'That backend's address is not usable.' over a screen that offered no way to fix it"
        )
    }

    /// **BUG-119.** Signing out keeps the row and its address, and the app
    /// still comes back to the first-run screen — this launch and the next.
    func testASignedOutProfileIsFirstRunAndStaysSoAcrossALaunch() {
        let app = freshModel()
        defer { app.profiles = [] }

        var stored = profile()
        stored.signedOut = true
        app.profiles = [stored]

        XCTAssertNil(app.signedInProfile)
        XCTAssertTrue(app.needsBackend)

        // A fresh process reading the same defaults must not quietly adopt it.
        let relaunched = AppModel()
        XCTAssertNil(
            relaunched.signedInProfile,
            "`init` adopts `profiles.first` when no active id is stored — a signed-out row must not be what it adopts, or sign-out would undo itself on the next launch"
        )
        XCTAssertTrue(relaunched.needsBackend)
        relaunched.profiles = []
    }

    /// The address survives the sign-out. That is the whole difference between
    /// the two labels FEAT-030 puts on the screen.
    func testSignOutKeepsTheAddressAndTheName() async throws {
        let app = freshModel()
        defer { app.profiles = [] }

        app.addProfile(profile(name: "workstation"))
        await app.signOut()

        let row = try XCTUnwrap(app.profiles.first, "sign out keeps the backend; remove is the other button")
        XCTAssertEqual(row.name, "workstation")
        XCTAssertEqual(row.baseURLString, "https://hermes.example.com")
        XCTAssertTrue(row.signedOut)
        XCTAssertNil(app.activeProfileID)
        XCTAssertTrue(app.needsBackend)
    }

    /// Adding a backend adopts it even when a stale id is in the way. Before
    /// FEAT-030 the adoption was gated on `activeProfileID == nil`, so a
    /// dangling id meant the *first backend a user added* was saved and never
    /// activated.
    func testAddingABackendAdoptsItOverADanglingId() {
        let app = freshModel()
        defer { app.profiles = [] }

        app.addProfile(profile())
        app.profiles = []
        XCTAssertNotNil(app.activeProfileID, "precondition: the id outlives the row it named")
        XCTAssertNil(app.activeProfile)

        let added = profile(name: "second")
        app.addProfile(added)
        XCTAssertEqual(app.activeProfileID, added.id)
        XCTAssertFalse(app.needsBackend)
    }

    // MARK: The first-run screen's links

    func testTheFirstRunScreenLinksToTheRepository() throws {
        let github = try XCTUnwrap(
            HermesLinks.github,
            "the first-run screen needs a GitHub button; a nil constant draws no row at all"
        )
        XCTAssertEqual(github.scheme, "https")
        XCTAssertEqual(github.host, "github.com")

        let rows = FirstRunLinkRow.visibleRows()
        XCTAssertEqual(rows.first, .github, "GitHub leads the row")
        XCTAssertTrue(
            rows.allSatisfy {
                $0.url(github: HermesLinks.github, privacyPolicy: HermesLinks.privacyPolicy, support: HermesLinks.support) != nil
            },
            "a row with no destination must not be drawn"
        )
    }

    func testHostedLinksAppearOnlyOnceTheyExist() {
        let none = FirstRunLinkRow.visibleRows(github: nil, privacyPolicy: nil, support: nil)
        XCTAssertTrue(none.isEmpty, "three nil URLs draw nothing, not three dead rows")

        let all = FirstRunLinkRow.visibleRows(
            github: URL(string: "https://example.com/repo"),
            privacyPolicy: URL(string: "https://example.com/privacy"),
            support: URL(string: "mailto:support@example.com")
        )
        XCTAssertEqual(all, [.github, .privacyPolicy, .support], "order is fixed: repo, policy, support")
        XCTAssertEqual(all.map(\.title), ["GitHub", "Privacy", "Support"])
    }

    // MARK: The stored shape

    /// A profile written by a build that had never heard of `signedOut` must
    /// still decode.
    ///
    /// The synthesized `init(from:)` throws on a missing key — a property
    /// default does not fill it — and `BackendProfileStore.load` decodes the
    /// whole array with `try?`, so one missing key would have returned an empty
    /// list and taken every backend a person had configured with it. This
    /// is the test that says a field may be added here without that happening.
    func testAProfileWrittenBeforeThisFieldExistedStillDecodes() throws {
        let legacy = """
        {"id":"\(UUID().uuidString)","name":"workstation","baseURLString":"https://hermes.example.com",\
        "authMode":"password","providerName":"local","username":"you","hermesProfile":"",\
        "lastKnownVersion":"0.20.5"}
        """
        let decoded = try JSONDecoder().decode(BackendProfile.self, from: Data(legacy.utf8))
        XCTAssertEqual(decoded.name, "workstation")
        XCTAssertEqual(decoded.username, "you")
        XCTAssertEqual(decoded.authMode, .password)
        XCTAssertEqual(decoded.lastKnownVersion, "0.20.5")
        XCTAssertFalse(decoded.signedOut, "an upgrade must not sign the user out of everything")
        XCTAssertTrue(decoded.isSignedIn)
    }

    /// The first-run mark is the app's own name, not the backend's wordmark.
    func testTheFirstRunMarkIsTheAppName() {
        XCTAssertEqual(HomeChrome.appMark, "HARC")
        XCTAssertFalse(HomeChrome.appTagline.isEmpty)
        XCTAssertEqual(
            HomeChrome.wordmark, "HERMES AGENT",
            "the connected screen keeps Desktop's wordmark — this changes the first-run mark only"
        )
    }
}
