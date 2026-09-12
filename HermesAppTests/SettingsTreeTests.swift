import XCTest

@testable import HermesMobile

/// FEAT-031 — the Settings root, regrouped.
///
/// The reported complaint was that the panel is disorganised, and
/// the fix is a grouping, so what has to be pinned is the grouping itself: the
/// order of the sections, the membership of each one, and the three behaviours
/// that are not visible in a screenshot — the advanced gate, the disconnected
/// greying, and the fact that no row is reachable from two places any more.
///
/// This is a tree of data rather than a mounted screen on purpose. Every
/// assertion below could in principle be made by hosting `SettingsView` and
/// walking its accessibility elements — except that SwiftUI publishes no
/// accessibility elements to a unit test (measured in `TranscriptSelectionTests`,
/// which had to abandon exactly that approach), so the choice was between this
/// and no coverage at all.
///
/// What is not asserted here: that the rows are drawn, that the greying
/// is 45 % rather than some other number, and that the footer sits under the
/// group rather than over it. Those are hand checks on a device.
final class SettingsTreeTests: XCTestCase {

    private func sections(
        backend: String = "backend.example.invalid",
        connected: Bool = true,
        advanced: Bool = false
    ) -> [SettingsRootSection] {
        SettingsTree.sections(backendNote: backend, isConnected: connected, showAdvanced: advanced)
    }

    private func section(_ title: String, in tree: [SettingsRootSection]) -> SettingsRootSection {
        guard let found = tree.first(where: { $0.title == title }) else {
            XCTFail("no section titled \(title)")
            return SettingsRootSection(title: title, rows: [])
        }
        return found
    }

    // MARK: The order

    /// The governing principle, as an order: whose setting it is, backend
    /// first, then the phone, then the two groups that belong to neither.
    func testSectionsReadBackendAgentPhoneBrowseAbout() {
        XCTAssertEqual(
            sections().map(\.title),
            ["Backend", "Agent", "This phone", "Browse", "About"]
        )
    }

    /// The header names what the rows below it are about. The Backend row
    /// itself carries the profile's display name, so the header carries the
    /// host — repeating the name would say nothing.
    func testTheBackendHeaderNamesTheBackend() {
        XCTAssertEqual(section("Backend", in: sections()).note, "backend.example.invalid")
        XCTAssertEqual(section("Backend", in: sections(backend: "Demo")).note, "Demo")
        XCTAssertEqual(section("Backend", in: sections(backend: "No backend")).note, "No backend")
    }

    // MARK: Membership

    func testBackendHoldsTheBackendScreenAndCommandCenter() {
        let backend = section("Backend", in: sections())
        XCTAssertEqual(backend.rows.map(\.label), ["Backend", "Command Center"])
        XCTAssertEqual(backend.rows.map(\.destination), [.settingsBackend, .commandCenter])
    }

    /// Everything that edits the backend's configuration document, and nothing
    /// that does not. The old tree scattered these across "Chat", "Workspace"
    /// and "Agent", with two device preferences sitting between them.
    func testAgentHoldsEveryConfigDocumentScreen() {
        XCTAssertEqual(
            section("Agent", in: sections()).rows.map(\.label),
            [
                "Model & reasoning", "Personality", "Workspace", "Safety & approvals",
                "Memory & context", "Capabilities", "Messaging",
            ]
        )
    }

    func testThisPhoneHoldsTheDeviceChoices() {
        let phone = section("This phone", in: sections())
        XCTAssertEqual(
            phone.rows.map(\.label),
            ["Appearance", "Chat", "Voice", "Notifications & Live Activities"]
        )
        XCTAssertEqual(
            phone.rows.map(\.destination),
            [
                .settingsAppearance,
                .settingsScreen(.chat),
                .settingsScreen(.voice),
                .settingsScreen(.notifications),
            ]
        )
    }

    func testBrowseHoldsArtifactsAlone() {
        XCTAssertEqual(section("Browse", in: sections()).rows.map(\.label), ["Artifacts"])
    }

    /// HARC is what the app is called on the home screen; Hermes is the
    /// backend, which this screen also reports under its own heading.
    func testAboutIsNamedForTheApp() {
        XCTAssertEqual(section("About", in: sections()).rows.map(\.label), ["About HARC"])
        XCTAssertEqual(
            section("About", in: sections()).rows.map(\.destination),
            [.settingsScreen(.about)]
        )
    }

    // MARK: The three behaviours a screenshot cannot show

    func testAdvancedAppearsOnlyBehindItsGate() {
        XCTAssertFalse(section("Agent", in: sections(advanced: false)).rows.contains {
            $0.label == "Advanced"
        })
        let gated = section("Agent", in: sections(advanced: true))
        XCTAssertEqual(gated.rows.last?.label, "Advanced")
        XCTAssertEqual(gated.rows.last?.destination, .settingsScreen(.advanced))
    }

    /// Greyed and explained, not hidden: a row that vanishes teaches the reader
    /// the app is missing a feature.
    func testDisconnectedGreysTheAgentGroupAndSaysWhy() {
        let offline = sections(connected: false)
        let agent = section("Agent", in: offline)
        XCTAssertFalse(agent.isEnabled)
        XCTAssertEqual(agent.footer, "Connect a backend to change these.")
        XCTAssertEqual(agent.rows.count, 7, "the rows stay on screen")

        for other in offline where other.title != "Agent" {
            XCTAssertTrue(other.isEnabled, "\(other.title) does not need a backend")
            XCTAssertNil(other.footer)
        }
    }

    func testConnectedShowsNoFooterAtAll() {
        for group in sections(connected: true) {
            XCTAssertNil(group.footer, "\(group.title) explains itself only when it cannot act")
            XCTAssertTrue(group.isEnabled)
        }
    }

    // MARK: The two defects the old tree carried in its shape

    /// Appearance existed twice, in two places that computed the same summary
    /// in duplicated code. FEAT-030 removes the
    /// Backend screen's copy; this pins that the root has exactly one.
    func testEveryRowIsReachableFromExactlyOnePlaceInTheRoot() {
        let destinations = sections(advanced: true).flatMap { $0.rows.map(\.destination) }
        XCTAssertEqual(
            destinations.count, Set(destinations).count,
            "a duplicated destination is a row the reader can find twice and trust neither time"
        )
        XCTAssertEqual(destinations.filter { $0 == .settingsAppearance }.count, 1)
    }

    /// Diagnostics is no longer a root row: it belongs to the backend and to
    /// the About screen's Support group, both of which are places a person
    /// goes *because* something is wrong.
    func testDiagnosticsIsNotARootRow() {
        let destinations = sections(advanced: true).flatMap { $0.rows.map(\.destination) }
        XCTAssertFalse(destinations.contains(.settingsDiagnostics))
    }

    /// "Show advanced settings" used to sit under the root's About header with
    /// no header of its own, thirty-eight lines below the row it governs. It is
    /// a row on the About screen now (`AboutSupportEntry.advancedToggle`), so
    /// the root carries no bare switch at all — every root entry pushes a
    /// screen.
    func testTheRootIsNothingButPushRows() {
        for group in sections(advanced: true) {
            XCTAssertFalse(group.rows.isEmpty, "\(group.title) is an empty header")
        }
        XCTAssertTrue(
            AboutSupportEntry.entries().contains(.advancedToggle),
            "the advanced gate has to have landed somewhere"
        )
    }
}
