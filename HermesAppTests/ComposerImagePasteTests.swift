import HermesServeKit
import UIKit
import UniformTypeIdentifiers
import XCTest

@testable import HermesMobile

/// BUG-057 defect 2: an image pasted into the composer vanished. The field is a `UITextView` bound to a `String` draft, and its `paste(_:)` only flagged the paste and called `super` (`GrowingComposerField.swift`), so an image either inserted an attachment glyph the draft could not hold or was not offered at all. A paste that carries images now hands them to the composer, which sends them down the photo picker's road (the 64 MB in-memory cap, `AttachmentPick.photoPayload` naming and HEIC conversion, `ChatModel.addAttachment`).
///
/// A named pasteboard stands in for the general one, so no paste-permission prompt can appear. The tests call `takePastedImages()`, the step `paste(_:)` runs before it falls back to `super`, rather than `paste(_:)` itself: `super` reads the general pasteboard, which on a simulator carries whatever the Mac's clipboard holds and can raise the system's paste prompt.
@MainActor
final class ComposerImagePasteTests: XCTestCase {

    private var pasteboard: UIPasteboard!

    override func setUp() {
        pasteboard = UIPasteboard.withUniqueName()
    }

    override func tearDown() {
        UIPasteboard.remove(withName: pasteboard.name)
        pasteboard = nil
    }

    private func png(width: Int = 4, height: Int = 3) -> Data {
        UIGraphicsImageRenderer(size: CGSize(width: width, height: height)).pngData { context in
            UIColor.systemTeal.setFill()
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
    }

    private func field() -> (GrowingComposerField.ComposerTextView, () -> [PastedImage]) {
        let field = GrowingComposerField.ComposerTextView()
        field.pasteboard = pasteboard
        var received: [PastedImage] = []
        field.onPasteImages = { received += $0 }
        return (field, { received })
    }

    func testPastingAnImageHandsItToTheComposerAndInsertsNothing() {
        pasteboard.setData(png(), forPasteboardType: UTType.png.identifier)
        let (field, received) = field()
        XCTAssertTrue(field.takePastedImages(), "a paste carrying an image fell through to the text view (BUG-057)")
        XCTAssertEqual(received().count, 1, "a pasted image reached nothing (BUG-057)")
        XCTAssertEqual(received().first?.contentType, .png)
        XCTAssertEqual(received().first?.data, png())
        XCTAssertEqual(field.text, "", "the image left something in the text draft")
    }

    func testPasteIsOfferedWhenThePasteboardHoldsOnlyAnImage() {
        pasteboard.setData(png(), forPasteboardType: UTType.png.identifier)
        let (field, _) = field()
        XCTAssertTrue(
            field.canPerformAction(#selector(UIResponderStandardEditActions.paste(_:)), withSender: nil),
            "the edit menu would not offer Paste for an image"
        )
    }

    func testEveryImageOnAMultiItemPasteboardIsHandedOver() {
        pasteboard.items = [
            [UTType.png.identifier: png()],
            [UTType.png.identifier: png(width: 8, height: 6)],
        ]
        let (field, received) = field()
        XCTAssertTrue(field.takePastedImages())
        XCTAssertEqual(received().count, 2)
    }

    /// Text, and text with an image beside it (a selection copied from a web page), is the text view's to paste.
    func testAPasteCarryingTextIsLeftToTheTextView() {
        pasteboard.items = [[UTType.utf8PlainText.identifier: "hello", UTType.png.identifier: png()]]
        let (field, received) = field()
        XCTAssertFalse(field.takePastedImages())
        XCTAssertTrue(received().isEmpty)
    }

    // MARK: - Where the bytes go

    func testAPastedImageIsQueuedAsAnImageUnderAPastedName() throws {
        let outcome = ComposerPaste.payloads(
            for: [PastedImage(data: png(), contentType: .png)],
            limit: ComposerOptionsSheet.fileByteLimit,
            stamp: "1727900000"
        )
        XCTAssertNil(outcome.failure)
        let payload = try XCTUnwrap(outcome.payloads.first)
        XCTAssertEqual(payload.filename, "pasted-1727900000-1.png")
        XCTAssertEqual(payload.mimeType, "image/png")
        XCTAssertTrue(
            AttachmentAPI.isAttachableAsImage(filename: payload.filename, mimeType: payload.mimeType),
            "a pasted PNG would travel as a file, not as an image the model sees"
        )
    }

    func testAnImageOverTheCapIsRefusedWithThePickersOwnWords() {
        let image = PastedImage(data: png(), contentType: .png)
        let outcome = ComposerPaste.payloads(for: [image], limit: 10, stamp: "1")
        XCTAssertTrue(outcome.payloads.isEmpty)
        XCTAssertEqual(outcome.failure, AttachmentPick.tooLargeMessage(bytes: image.data.count, limit: 10))
    }

    func testAnImageWithNoDeclaredTypeIsStillNamedAsAnImage() throws {
        let outcome = ComposerPaste.payloads(
            for: [PastedImage(data: png(), contentType: nil)],
            limit: ComposerOptionsSheet.fileByteLimit,
            stamp: "2"
        )
        let payload = try XCTUnwrap(outcome.payloads.first)
        XCTAssertTrue(AttachmentAPI.isAttachableAsImage(filename: payload.filename, mimeType: payload.mimeType), payload.filename)
    }
}
