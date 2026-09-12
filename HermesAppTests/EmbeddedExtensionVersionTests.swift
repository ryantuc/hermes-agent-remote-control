import Foundation
import XCTest

@testable import HermesMobile

/// BUG-064 — the App Store blocker, from the side that names it.
///
/// `BuildNumberTests` already pins two halves of this: that the *app's*
/// `CFBundleVersion` is derived rather than the hand-set floor, and that the
/// extension agrees with the app. What it never said out loud is the third
/// thing, and the third thing is what actually happened: the embedded
/// `.appex` shipped `project.yml`'s `CURRENT_PROJECT_VERSION` sentinel (then
/// `2`, now `0`), the value that means "the stamping phase did not run on this
/// bundle", while the app carried the git-derived number.
///
/// Why that is a submission blocker and not a cosmetic mismatch: App Store
/// Connect validates that an embedded extension's bundle version matches its
/// host app's, and the sentinel is below every build that can ever be accepted,
/// which is separately an upload-monotonicity rejection. Both are silent until
/// the upload fails.
///
/// The equality assertion alone cannot say which side went wrong, and a build
/// where *both* bundles fell back to the sentinel (the non-git-export case) satisfies
/// it perfectly. This one cannot be satisfied by a degraded build at all.
final class EmbeddedExtensionVersionTests: XCTestCase {

    /// The exact failure signature. `0` is `project.yml`'s never-ship sentinel;
    /// the derived number is `git rev-list --count HEAD`, which is at least 1 in
    /// any checkout. An embedded extension still reporting the sentinel means
    /// `scripts/stamp-build-number.sh` never wrote this bundle.
    func testTheEmbeddedExtensionsBuildNumberIsDerivedRatherThanTheFallback() throws {
        let bundle = try XCTUnwrap(Self.embeddedExtensionBundle(), "no .appex is embedded in the test host")
        let raw = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
        let number = try XCTUnwrap(
            Int(raw),
            "the extension's CFBundleVersion must be a plain integer, saw \"\(raw)\""
        )
        XCTAssertGreaterThan(
            number,
            0,
            "the embedded Live Activity extension is still on project.yml's sentinel (\(number)): "
                + "its stamp never ran, and App Store Connect rejects an extension whose bundle "
                + "version does not match its host app"
        )
    }

    /// The same claim for the app, stated beside it, so a failure says which of
    /// the two bundles went unstamped instead of only that they disagree.
    func testTheHostAppsBuildNumberIsDerivedRatherThanTheFallback() throws {
        let raw = AppVersion.build ?? ""
        let number = try XCTUnwrap(Int(raw), "CFBundleVersion must be a plain integer, saw \"\(raw)\"")
        XCTAssertGreaterThan(number, 0, "the app itself is on the unstamped sentinel (\(number))")
    }

    /// The extension is signed as a child of the app. A mismatch here is the
    /// other way an embed is refused, and it costs one line to say so.
    func testTheEmbeddedExtensionIsAChildBundleOfTheApp() throws {
        let bundle = try XCTUnwrap(Self.embeddedExtensionBundle())
        let host = try XCTUnwrap(Bundle.main.bundleIdentifier)
        let extensionID = try XCTUnwrap(bundle.bundleIdentifier)
        XCTAssertTrue(
            extensionID.hasPrefix(host + "."),
            "\"\(extensionID)\" is not a child of \"\(host)\""
        )
    }

    /// Found by extension rather than by name, the same way `BuildNumberTests`
    /// does it, so a later rename of the target does not turn this into a test
    /// that quietly stops looking.
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
