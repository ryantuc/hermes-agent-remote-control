import XCTest

@testable import HermesMobile

/// BUG-029 — a failed attachment load must set the same user-visible
/// `loadFailure` the size-cap path already uses. Both pickers used `continue`.
final class AttachmentPickTests: XCTestCase {
    func testUnreadableFileSetsAMessage() {
        var failure: String?
        let data = AttachmentPick.note(data: nil, into: &failure)
        XCTAssertNil(data)
        XCTAssertEqual(
            failure,
            AttachmentPick.failedToLoadMessage,
            "ComposerOptionsSheet swallows a failed load with bare continue"
        )
    }

    func testReadableFilePassesThrough() {
        var failure: String?
        let payload = Data([1, 2, 3])
        let data = AttachmentPick.note(data: payload, into: &failure)
        XCTAssertEqual(data, payload)
        XCTAssertNil(failure)
    }
}
