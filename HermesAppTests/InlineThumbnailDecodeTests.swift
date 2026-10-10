import HermesServeKit
import SwiftUI
import UIKit
import XCTest

@testable import HermesMobile

/// BUG-075 leg B: a `data:image/…` ref on a user turn was base64-decoded and downsampled inside `AttachmentChips.body` (`MessageBubbleView.swift`), on the main thread, on every body pass, so a turn carrying a large screenshot re-decoded it each time the row re-rendered while a reply streamed. The decode now runs once, off the body, and the result is kept for the life of the chip.
@MainActor
final class InlineThumbnailDecodeTests: XCTestCase {

    private func dataURL() -> String {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 40, height: 30)).image { context in
            UIColor.systemOrange.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 40, height: 30))
        }
        return "data:image/png;base64," + image.pngData()!.base64EncodedString()
    }

    private func turn(_ text: String, ref: String) -> ChatEntry {
        ChatEntry(id: "u-thumb", kind: .user, text: text, imageRefs: [ref])
    }

    private func spin(until predicate: () -> Bool, timeout: TimeInterval = 2) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if predicate() { return true }
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        return predicate()
    }

    func testAnInlineImageIsDecodedOnceAndNeverInsideABodyPass() {
        let ref = dataURL()
        let before = InlineThumbnail.decodeCount
        let controller = UIHostingController(rootView: MessageBubbleView(entry: turn("first", ref: ref)))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 800))
        window.rootViewController = controller
        window.makeKeyAndVisible()
        window.layoutIfNeeded()
        controller.view.layoutIfNeeded()

        XCTAssertEqual(InlineThumbnail.decodeCount - before, 0, """
            the image was decoded while the row's body was being evaluated, on the main thread \
            (BUG-075 B); it has to be decoded off the body
            """)
        XCTAssertTrue(spin { InlineThumbnail.decodeCount - before == 1 }, "the image was never decoded at all")

        for index in 0..<6 {
            controller.rootView = MessageBubbleView(entry: turn("render \(index)", ref: ref))
            window.layoutIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        XCTAssertEqual(InlineThumbnail.decodeCount - before, 1, """
            six re-renders of the same turn decoded its image \(InlineThumbnail.decodeCount - before) times
            """)
        window.isHidden = true
    }
}
