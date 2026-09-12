import Foundation
import HermesServeKit
import XCTest

@testable import HermesMobile

/// BUG-055 — the app told the user their backend was called "Sim validation".
///
/// It was not a mode, a status or a build flavour: it was the hard-coded `name` of the backend profile the DEBUG simulator seed harness creates for itself. `BackendProfile.displayName` returns `name` whenever it is non-empty, so that one label won over the host on the Home wordmark, the hub row, the Settings row, the chat header and the profile list — five surfaces naming something the user had never heard of. A Debug build carries the harness onto a device too.
///
/// The fix is that the harness stops naming the profile. An empty name is exactly what a hand-made profile carries, and `displayName` falls back to the host for it, so a seeded profile now reads the same way every other one does. A run that genuinely wants a label passes `-hermesSeedName`.
///
/// This does not clean a device that already has one. Profile names are `UserDefaults` data, so the stored row keeps whatever it was created with; that half is a rename or a delete in Settings → Backend.
@MainActor
final class SeedProfileNameTests: XCTestCase {

    private let url = "https://hermes.example.com"

    func testASeededProfileCarriesNoNameOfItsOwn() {
        let profile = AppModel.seedProfile(from: ["HermesMobile", "-hermesSeedBackend", url])
        XCTAssertEqual(profile?.name, "", """
            the seed harness named its profile "\(profile?.name ?? "<nil>")". \
            `BackendProfile.displayName` prefers `name` over the host, so whatever this string is \
            becomes the backend's name on five user-facing surfaces (BUG-055)
            """)
    }

    /// The point of the empty name, stated as the behaviour it buys rather than
    /// as the field it sets.
    func testASeededProfileIsIdentifiedByItsHostLikeEveryHandMadeOne() {
        let profile = AppModel.seedProfile(from: ["HermesMobile", "-hermesSeedBackend", url])
        XCTAssertEqual(profile?.displayName, "hermes.example.com", """
            a seeded backend draws as "\(profile?.displayName ?? "<nil>")" instead of its host
            """)
        XCTAssertNotEqual(profile?.displayName, "Sim validation", """
            the harness's own name for itself is still what the app shows the user
            """)
    }

    /// A local gateway is `host:port`, and the port is the half that tells two
    /// backends on one machine apart.
    func testTheDisplayedHostKeepsThePort() {
        let profile = AppModel.seedProfile(from: ["HermesMobile", "-hermesSeedBackend", "http://127.0.0.1:9119"])
        XCTAssertEqual(profile?.displayName, "127.0.0.1:9119")
    }

    /// The harness keeps the option of a label — it just has to be asked for.
    func testAnExplicitSeedNameIsHonoured() {
        let profile = AppModel.seedProfile(from: [
            "HermesMobile", "-hermesSeedBackend", url, "-hermesSeedName", "Screenshot run",
        ])
        XCTAssertEqual(profile?.name, "Screenshot run")
        XCTAssertEqual(profile?.displayName, "Screenshot run", """
            an explicitly requested label must still win over the host, or `-hermesSeedName` does \
            nothing
            """)
    }

    // MARK: The rest of the harness's contract, unchanged

    func testAnOrdinaryLaunchSeedsNothing() {
        XCTAssertNil(AppModel.seedProfile(from: ["HermesMobile"]), """
            a launch with no `-hermesSeedBackend` built a profile — every ordinary run of the app \
            would append one
            """)
        XCTAssertNil(AppModel.seedProfile(from: ["HermesMobile", "-hermesSeedBackend"]), """
            a `-hermesSeedBackend` with no value after it must not seed a profile pointing at \
            nothing
            """)
    }

    func testNoUsernameMeansASessionTokenProfile() {
        let profile = AppModel.seedProfile(from: ["HermesMobile", "-hermesSeedBackend", url])
        XCTAssertEqual(profile?.authMode, .sessionToken)
        XCTAssertEqual(profile?.username, "")
        XCTAssertEqual(profile?.providerName, "")
    }

    func testAUsernameMeansAPasswordProfileWithAProvider() {
        let profile = AppModel.seedProfile(from: [
            "HermesMobile", "-hermesSeedBackend", url, "-hermesSeedUsername", "you",
        ])
        XCTAssertEqual(profile?.authMode, .password)
        XCTAssertEqual(profile?.username, "you")
        XCTAssertEqual(profile?.providerName, "basic", "the default provider name is what the harness has always sent")

        let explicit = AppModel.seedProfile(from: [
            "HermesMobile", "-hermesSeedBackend", url,
            "-hermesSeedUsername", "you", "-hermesSeedProvider", "ldap",
        ])
        XCTAssertEqual(explicit?.providerName, "ldap")
    }
}
