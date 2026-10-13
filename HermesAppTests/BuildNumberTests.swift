import Foundation
import XCTest

@testable import HermesMobile

/// FEAT-021 — the build number a bundle carries is derived at build time from
/// git, not typed into `project.yml` and then remembered.
///
/// What these can and cannot see: they run against the bundle the test host
/// actually built, so they observe the real stamped value. What they cannot
/// observe is a build made anywhere other than here — the guarantee that a
/// Cmd-R in Xcode stamps too rests on the phase living in
/// `project.yml`, which is the file every generated project comes from.
final class BuildNumberTests: XCTestCase {

    /// `0` is the never-ship sentinel: it is `CURRENT_PROJECT_VERSION` in
    /// `project.yml`, the value a bundle is left carrying when the stamping
    /// phase does not run, and it is deliberately a number no real build can
    /// derive. After FEAT-021 the number is `git rev-list --count HEAD`, which
    /// is at least 1 in any git checkout, so a bundle reporting 0 means the
    /// phase did not run at all.
    ///
    /// This is not the upload floor. That is a separate constant,
    /// `ACCEPTED_BUILD_FLOOR` in `scripts/stamp-build-number.sh`, which names
    /// the highest build App Store Connect has processed an upload of for the
    /// current `MARKETING_VERSION` — processed, not approved, because every
    /// upload has to carry a higher build string than any earlier one it
    /// processed whether or not App Review approved that build. They are
    /// different concepts. They coincided at 0 until the first processed
    /// upload, 1.0.0 (3) on 2026-10-13, raised the floor to 3: raise it after
    /// each processed upload and leave the sentinel at 0 forever. The
    /// script's guard tests the derived commit count, and the sentinel is
    /// caught here, by reading the number the built bundle actually carries.
    func testTheBuildNumberIsDerivedRatherThanHandSet() {
        let raw = AppVersion.build ?? ""
        guard let number = Int(raw) else {
            return XCTFail("CFBundleVersion must be a plain integer, saw \"\(raw)\"")
        }
        XCTAssertGreaterThan(
            number,
            0,
            "CFBundleVersion is still the unstamped sentinel (\(number)): scripts/stamp-build-number.sh did not stamp this bundle"
        )
    }

    /// FEAT-002's first rule, now that a script writes the number rather than a
    /// person: an extension whose version disagrees with its host app does not
    /// embed, so both plists must come out of one build carrying one number.
    func testTheLiveActivityExtensionCarriesTheSameVersionAsTheApp() throws {
        let extensionBundle = try XCTUnwrap(Self.embeddedExtensionBundle(), "no .appex is embedded in the test host")
        XCTAssertEqual(
            extensionBundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String,
            AppVersion.build,
            "the Live Activity extension's build number must match the app's"
        )
        XCTAssertEqual(
            extensionBundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
            AppVersion.marketing,
            "the Live Activity extension's marketing version must match the app's"
        )
    }

    /// The reader FEAT-002 shipped was written when the build number was a
    /// single digit. A derived number is three or four, and every surface that
    /// shows it must still read as a version rather than as a serial number.
    func testTheVersionReaderFormatsADerivedBuildNumber() {
        XCTAssertEqual(AppVersion.display(marketing: "1.0.0", build: "259"), "1.0.0 (259)")
        XCTAssertEqual(AppVersion.display(marketing: "1.0.0", build: "12345"), "1.0.0 (12345)")
    }

    /// The first `.appex` under the host app's PlugIns directory, if there is
    /// one. Found by extension rather than by name so a later rename of the
    /// target does not turn this into a test that quietly stops looking.
    private static func embeddedExtensionBundle() -> Bundle? {
        guard let plugIns = Bundle.main.builtInPlugInsURL else { return nil }
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: plugIns,
            includingPropertiesForKeys: nil
        )) ?? []
        guard let appex = contents.first(where: { $0.pathExtension == "appex" }) else { return nil }
        return Bundle(url: appex)
    }
}
