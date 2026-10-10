import SwiftUI
import UIKit
import XCTest

@testable import HermesMobile

/// `QuickLookSheet.body` hung `.task { load }` and `.onDisappear { discard() }` on a `Group` that switches between the spinner and the preview. A `Group` hands its modifiers to each member, so when the load landed and the spinner left, the spinner's `onDisappear` ran `discard()`: the file was deleted, `localURL` cleared, the spinner came back, and its `.task` fetched again, in a loop. `QuickLookFileTests` drive the class without presenting the sheet, so nothing saw it.
///
/// The sheet is hosted in a real window over a `data:` image, which `MediaFileFetch` decodes locally, so no backend is involved.
@MainActor
final class QuickLookSheetLifecycleTests: XCTestCase {

    private static func pngDataURL() throws -> String {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: CGSize(width: 32, height: 24), format: format).image { context in
            UIColor.systemTeal.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 32, height: 24))
        }
        return "data:image/png;base64," + (try XCTUnwrap(image.pngData())).base64EncodedString()
    }

    func testAFinishedLoadStaysOnScreenAndIsNotFetchedAgain() async throws {
        let harness = await AppHarness.make()
        let file = QuickLookFile(path: try Self.pngDataURL())
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        window.rootViewController = UIHostingController(rootView: AnyView(QuickLookSheet(file: file).environment(harness.app)))
        window.makeKeyAndVisible()

        let loaded = await waitUntil { file.writesForTesting >= 1 }
        XCTAssertTrue(loaded, "precondition: the data: image never loaded")
        // Long enough for the spinner to give way to the preview and for any reload loop to go round more than once.
        try? await Task.sleep(nanoseconds: 1_500_000_000)

        XCTAssertEqual(file.writesForTesting, 1, "the sheet fetched and wrote its file \(file.writesForTesting) times: the spinner's onDisappear discarded the finished load and the next .task fetched it again")
        let shown = try XCTUnwrap(file.localURL, "the preview's file was discarded while the sheet was still up")
        XCTAssertTrue(FileManager.default.fileExists(atPath: shown.path), "Quick Look is showing a file that has been deleted")

        // Dismissal still removes it (BUG-081).
        window.rootViewController = UIViewController()
        let discarded = await waitUntil { file.localURL == nil }
        XCTAssertTrue(discarded, "the sheet went and its file stayed")
        XCTAssertFalse(FileManager.default.fileExists(atPath: shown.path), "the sheet went and left its temporary file on disk")

        window.isHidden = true
        await harness.tearDown()
    }
}
