import Foundation
import XCTest

@testable import HermesMobile

/// The demo claims no server version. Every surface that prints one puts a "v" in front of it, so a labelled version such as "demo" came out as "Connected · vdemo" in the hub, the screen a reviewer opens most; an empty one is skipped by the hub, the Settings root and the Backend screen's diagnostics row, and About names the demo instead.
@MainActor
final class DemoVersionLabelTests: XCTestCase {

    func testTheDemoBackendReportsNoVersion() async {
        let status = await DemoBackend().status()
        XCTAssertEqual(status.version, "", "a demo version prints with a \"v\" in front of it wherever a version is shown")
    }

    func testAboutNamesTheDemoInsteadOfAVersion() {
        XCTAssertEqual(AboutView.backendVersionLabel(version: "", isDemo: true), "Demo")
        XCTAssertEqual(AboutView.backendVersionLabel(version: "0.21.2", isDemo: false), "v0.21.2")
        XCTAssertEqual(AboutView.backendVersionLabel(version: "", isDemo: false), "Unknown", "a backend that reports no version must not print a bare \"v\"")
    }

    func testTheAdvancedSwitchSaysWhatItShows() {
        XCTAssertEqual(AboutView.advancedSubtitle, "Timeouts, output limits, subagents and other advanced options.")
    }
}
