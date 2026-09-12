import Foundation
import XCTest

@testable import HermesMobile

/// FEAT-002 — the version the app reports about itself.
final class AppVersionTests: XCTestCase {

    func testFormatsMarketingVersionAndBuild() {
        XCTAssertEqual(AppVersion.display(marketing: "1.0.0", build: "2"), "1.0.0 (2)")
    }

    func testAMissingVersionIsUnknownRatherThanZero() {
        XCTAssertEqual(AppVersion.display(marketing: nil, build: nil), AppVersion.unknown)
        XCTAssertEqual(AppVersion.display(marketing: "", build: ""), AppVersion.unknown)
        XCTAssertEqual(AppVersion.unknown, "unknown")
    }

    func testAMissingBuildNumberDropsTheParentheses() {
        XCTAssertEqual(AppVersion.display(marketing: "1.0.0", build: nil), "1.0.0")
        XCTAssertEqual(AppVersion.display(marketing: "1.0.0", build: ""), "1.0.0")
    }

    /// The bundle the tests are hosted by is the shipping app, so this asserts
    /// what `project.yml` actually set. A floor rather than an equality: a
    /// later release bumps past it without editing a test.
    func testTheShippedBundleIsAtOrBeyondTheFirstTrackedRelease() {
        let marketing = AppVersion.marketing ?? ""
        let parts = marketing.split(separator: ".").compactMap { Int($0) }
        XCTAssertEqual(parts.count, 3, "CFBundleShortVersionString must be semver (saw \"\(marketing)\")")
        let major = parts.count > 0 ? parts[0] : 0
        let minor = parts.count > 1 ? parts[1] : 0
        XCTAssertTrue(
            (major, minor) >= (1, 0),
            "the app must ship at or beyond 1.0.0, the first public release (saw \"\(marketing)\")"
        )
        XCTAssertGreaterThan(
            Int(AppVersion.build ?? "0") ?? 0,
            0,
            "CFBundleVersion is still the unstamped sentinel 0 (saw \"\(AppVersion.build ?? "")\")"
        )
    }

    func testCurrentReadsTheHostBundle() {
        XCTAssertEqual(AppVersion.current, AppVersion.display(marketing: AppVersion.marketing, build: AppVersion.build))
    }
}
