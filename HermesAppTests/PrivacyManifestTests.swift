import Foundation
import XCTest

@testable import HermesMobile

/// The two privacy manifests against the code that ships in each binary.
///
/// App Store Connect refuses an upload (ITMS-91053) when a binary calls a required-reason API that its bundle's `PrivacyInfo.xcprivacy` does not declare. The categories and their symbols are Apple's list for `NSPrivacyAccessedAPIType` (developer.apple.com, Bundle Resources, read 2026-10-09), in the spellings Swift code uses. The source is scanned from disk and the manifests are read from the built bundles, so a new call anywhere in the shipped sources fails here before it fails at upload.
final class PrivacyManifestTests: XCTestCase {

    private struct Category {
        let key: String
        let pattern: String
    }

    private static let categories: [Category] = [
        Category(
            key: "NSPrivacyAccessedAPICategoryFileTimestamp",
            pattern: #"\b(creationDate|modificationDate|fileModificationDate|contentModificationDateKey|contentModificationDate|creationDateKey|getattrlist|getattrlistbulk|fgetattrlist|getattrlistat)\b|\b(stat|fstat|fstatat|lstat)\("#
        ),
        Category(
            key: "NSPrivacyAccessedAPICategorySystemBootTime",
            pattern: #"\b(systemUptime|mach_absolute_time)\b"#
        ),
        Category(
            key: "NSPrivacyAccessedAPICategoryDiskSpace",
            pattern: #"\b(volumeAvailableCapacityKey|volumeAvailableCapacityForImportantUsageKey|volumeAvailableCapacityForOpportunisticUsageKey|volumeTotalCapacityKey|volumeAvailableCapacity|volumeAvailableCapacityForImportantUsage|volumeAvailableCapacityForOpportunisticUsage|volumeTotalCapacity|systemFreeSize|systemSize)\b|\b(statfs|statvfs|fstatfs|fstatvfs)\("#
        ),
        Category(
            key: "NSPrivacyAccessedAPICategoryActiveKeyboards",
            pattern: #"\bactiveInputModes\b"#
        ),
        Category(
            key: "NSPrivacyAccessedAPICategoryUserDefaults",
            pattern: #"\bUserDefaults\b|@AppStorage\b"#
        ),
    ]

    /// The reason each category is declared for: C617.1 is metadata of files inside the app's own container (the transcript recovery cache in Caches), CA92.1 is defaults only this app reads and writes.
    private static let expectedReasons: [String: [String]] = [
        "NSPrivacyAccessedAPICategoryFileTimestamp": ["C617.1"],
        "NSPrivacyAccessedAPICategoryUserDefaults": ["CA92.1"],
    ]

    private static var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    }

    /// The sources compiled into the app binary, per `project.yml`: the app, the shared activity types and the kit.
    private static let appSources = ["HermesApp", "HermesActivity", "HermesServeKit/Sources"]

    /// The sources compiled into the widget extension, per `project.yml`.
    private static let extensionSources = [
        "HermesLiveActivity", "HermesActivity", "HermesServeKit/Sources",
        "HermesApp/Design/HermesTokens.swift", "HermesApp/Design/HermesType.swift",
        "HermesApp/Design/SkinPresets.swift", "HermesApp/Design/DesktopThemePalette.swift",
    ]

    // MARK: Required-reason APIs

    func testTheAppManifestDeclaresEveryRequiredReasonAPITheAppCalls() throws {
        let manifest = try Self.manifest(at: Bundle.main.url(forResource: "PrivacyInfo", withExtension: "xcprivacy"), what: "app")
        try assertDeclared(manifest, coversSources: Self.appSources, what: "app")
    }

    func testTheExtensionManifestDeclaresEveryRequiredReasonAPITheExtensionCalls() throws {
        let url = Bundle.main.builtInPlugInsURL?
            .appendingPathComponent("HermesLiveActivity.appex", isDirectory: true)
            .appendingPathComponent("PrivacyInfo.xcprivacy")
        let manifest = try Self.manifest(at: url, what: "Live Activity extension")
        try assertDeclared(manifest, coversSources: Self.extensionSources, what: "Live Activity extension")
    }

    func testEveryDeclaredReasonIsTheOneTheCodeUsesItFor() throws {
        let manifest = try Self.manifest(at: Bundle.main.url(forResource: "PrivacyInfo", withExtension: "xcprivacy"), what: "app")
        for (category, reasons) in Self.declaredReasons(manifest) {
            if let expected = Self.expectedReasons[category] {
                XCTAssertEqual(reasons, expected, "\(category) is declared for \(reasons), not for what the app does with it")
            }
        }
    }

    // MARK: Collection and tracking

    /// The App Privacy answer is "No, we do not collect data from this app"; both manifests must say the same, or the label and the binary disagree.
    func testNeitherManifestTracksOrCollects() throws {
        let app = try Self.manifest(at: Bundle.main.url(forResource: "PrivacyInfo", withExtension: "xcprivacy"), what: "app")
        let appex = try Self.manifest(
            at: Bundle.main.builtInPlugInsURL?
                .appendingPathComponent("HermesLiveActivity.appex", isDirectory: true)
                .appendingPathComponent("PrivacyInfo.xcprivacy"),
            what: "Live Activity extension"
        )
        for (what, manifest) in [("app", app), ("extension", appex)] {
            XCTAssertEqual(manifest["NSPrivacyTracking"] as? Bool, false, "the \(what) manifest must declare no tracking")
            XCTAssertEqual((manifest["NSPrivacyTrackingDomains"] as? [Any])?.count, 0, "the \(what) manifest lists tracking domains")
            XCTAssertEqual((manifest["NSPrivacyCollectedDataTypes"] as? [Any])?.count, 0, "the \(what) manifest declares collected data")
        }
    }

    // MARK: Helpers

    private func assertDeclared(_ manifest: [String: Any], coversSources sources: [String], what: String, file: StaticString = #filePath, line: UInt = #line) throws {
        let used = try Self.usedCategories(in: sources)
        let declared = Set(Self.declaredReasons(manifest).keys)
        for (category, hits) in used.sorted(by: { $0.key < $1.key }) where !declared.contains(category) {
            XCTFail("the \(what) calls a \(category) API with no reason declared in its PrivacyInfo.xcprivacy, which App Store Connect rejects (ITMS-91053): \(hits.prefix(5).joined(separator: "; "))", file: file, line: line)
        }
        for category in declared.subtracting(used.keys).sorted() {
            XCTFail("the \(what) manifest declares \(category) but no shipped source calls it; a stale declaration claims an access the binary does not make", file: file, line: line)
        }
    }

    private static func manifest(at url: URL?, what: String) throws -> [String: Any] {
        let url = try XCTUnwrap(url, "no bundle location for the \(what) manifest")
        let data = try XCTUnwrap(try? Data(contentsOf: url), "the \(what) bundle has no PrivacyInfo.xcprivacy at \(url.path)")
        let plist = try PropertyListSerialization.propertyList(from: data, format: nil)
        return try XCTUnwrap(plist as? [String: Any], "the \(what) manifest is not a dictionary")
    }

    private static func declaredReasons(_ manifest: [String: Any]) -> [String: [String]] {
        let entries = manifest["NSPrivacyAccessedAPITypes"] as? [[String: Any]] ?? []
        var out: [String: [String]] = [:]
        for entry in entries {
            guard let category = entry["NSPrivacyAccessedAPIType"] as? String else { continue }
            out[category] = entry["NSPrivacyAccessedAPITypeReasons"] as? [String] ?? []
        }
        return out
    }

    /// Category → "file:line" of each call, over the Swift files under `paths`; comment lines are skipped so prose about an API does not count as a call.
    private static func usedCategories(in paths: [String]) throws -> [String: [String]] {
        let fm = FileManager.default
        var files: [URL] = []
        for path in paths {
            let url = repositoryRoot.appendingPathComponent(path)
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
                XCTFail("the source path \(url.path) is missing, so this scan cannot vouch for it")
                continue
            }
            if !isDirectory.boolValue {
                files.append(url)
                continue
            }
            let enumerator = fm.enumerator(at: url, includingPropertiesForKeys: nil)
            while let next = enumerator?.nextObject() as? URL {
                if next.pathExtension == "swift" { files.append(next) }
            }
        }
        XCTAssertFalse(files.isEmpty, "no Swift sources found under \(repositoryRoot.path)")
        let expressions = try categories.map { ($0.key, try NSRegularExpression(pattern: $0.pattern)) }
        var used: [String: [String]] = [:]
        for file in Set(files) {
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            for (index, raw) in text.components(separatedBy: .newlines).enumerated() {
                let line = raw.trimmingCharacters(in: .whitespaces)
                if line.hasPrefix("//") || line.hasPrefix("*") || line.hasPrefix("/*") { continue }
                let range = NSRange(line.startIndex..., in: line)
                for (key, expression) in expressions where expression.firstMatch(in: line, range: range) != nil {
                    used[key, default: []].append("\(file.lastPathComponent):\(index + 1)")
                }
            }
        }
        return used
    }
}
