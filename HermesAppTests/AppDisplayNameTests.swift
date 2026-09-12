import Foundation
import XCTest

@testable import HermesMobile

/// FEAT-007 / FEAT-025 — the home-screen label.
///
/// `HermesAppTests` is hosted by the app (`TEST_HOST` in `project.yml:184`),
/// so `Bundle.main` inside this process is the app's own bundle and the
/// dictionary read here is the generated `Info.plist` that ships.
final class AppDisplayNameTests: XCTestCase {

    func testAppBundleCarriesTheHARCDisplayName() {
        let name = Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
        XCTAssertEqual(
            name,
            "HARC",
            "the home screen must read HARC; without CFBundleDisplayName it falls back to the product name HermesMobile"
        )
    }
}
