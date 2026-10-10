import Foundation
import XCTest

@testable import HermesMobile

/// The Info.plist facts App Review checks on the built app: every permission prompt has a purpose string, the export-compliance answer is set, no background mode is claimed that the app does not use, and the name and minimum iOS version match the store page.
final class ReviewReadinessTests: XCTestCase {

    private var info: [String: Any] { Bundle.main.infoDictionary ?? [:] }

    /// One purpose string per permission the app asks for; a prompt without one crashes the app at first use.
    func testEveryPermissionTheAppAsksForHasAPurposeString() {
        let keys = [
            "NSCameraUsageDescription",
            "NSPhotoLibraryUsageDescription",
            "NSPhotoLibraryAddUsageDescription",
            "NSMicrophoneUsageDescription",
            "NSSpeechRecognitionUsageDescription",
            "NSFaceIDUsageDescription",
            "NSLocalNetworkUsageDescription",
        ]
        for key in keys {
            let value = (info[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            XCTAssertFalse(value.isEmpty, "\(key) is missing or empty")
        }
    }

    /// Saving to Photos covers videos as well as images, so the add-only prompt has to say so.
    func testThePhotosPromptsNameVideos() {
        XCTAssertTrue((info["NSPhotoLibraryAddUsageDescription"] as? String ?? "").contains("video"))
        XCTAssertTrue((info["NSPhotoLibraryUsageDescription"] as? String ?? "").contains("video"))
    }

    /// The microphone prompt is where the Hermes dictation engine's upload belongs: speech recognition is only asked for by the on-device engine.
    func testTheMicrophonePromptSaysWhereTheHermesEngineSendsTheRecording() {
        XCTAssertTrue((info["NSMicrophoneUsageDescription"] as? String ?? "").contains("your own backend"))
        XCTAssertFalse((info["NSSpeechRecognitionUsageDescription"] as? String ?? "").contains("backend"))
    }

    /// The local-network prompt names what HARC connects to in words a non-developer knows, not the command that starts it.
    func testTheLocalNetworkPromptNamesHermesAgent() {
        let prompt = info["NSLocalNetworkUsageDescription"] as? String ?? ""
        XCTAssertTrue(prompt.contains("Hermes Agent"), prompt)
        XCTAssertFalse(prompt.contains("hermes serve"), prompt)
    }

    /// HTTPS through the system and SHA-256 hashing are exempt, so the answer is false and App Store Connect asks no export questions.
    func testExportComplianceIsAnsweredFalse() {
        XCTAssertEqual(info["ITSAppUsesNonExemptEncryption"] as? Bool, false)
    }

    /// Every notification is scheduled from the open connection; a declared background mode with no use is a rejection reason.
    func testNoBackgroundModeIsDeclared() {
        XCTAssertNil(info["UIBackgroundModes"])
        XCTAssertNil(info["NSBonjourServices"], "the app browses no Bonjour service, so it must not declare one")
    }

    func testTheNameAndMinimumIOSMatchTheStorePage() {
        XCTAssertEqual(info["CFBundleDisplayName"] as? String, "HARC")
        XCTAssertEqual(info["MinimumOSVersion"] as? String, "17.0")
    }
}
