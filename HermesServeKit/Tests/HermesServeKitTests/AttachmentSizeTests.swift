import HermesServeKit
import XCTest

/// The attachment cap message printed "the upload cap is 67.1 MB" for a 64 MB cap, because it formatted the cap in decimal units while the cap is 64 × 1024 × 1024 bytes, and the image cap message printed its 25 MB cap in binary. A size and the cap it is compared with are now written in the same units, the ones the caps are configured in.
final class AttachmentSizeTests: XCTestCase {
    func testTheCapsReadAsTheNumbersTheyAreConfiguredAs() {
        let file = AttachmentSize.text(64 * 1024 * 1024)
        XCTAssertTrue(file.hasPrefix("64"), "the 64 MB file cap reads \(file)")
        XCTAssertFalse(file.contains("67"), "the 64 MB file cap reads \(file), the decimal conversion")
        let image = AttachmentSize.text(25 * 1024 * 1024)
        XCTAssertTrue(image.hasPrefix("25"), "the 25 MB image cap reads \(image)")
    }

    /// A file just over the cap must read as larger than the cap, in the same units.
    func testASizeJustOverTheCapReadsLargerThanTheCap() {
        let message = AttachmentSize.tooLargeMessage(bytes: 64 * 1024 * 1024 + 2 * 1024 * 1024, limit: 64 * 1024 * 1024)
        XCTAssertTrue(message.hasPrefix("That file is 66"), message)
        XCTAssertTrue(message.hasSuffix("the upload cap is 64 MB."), message)
    }
}
