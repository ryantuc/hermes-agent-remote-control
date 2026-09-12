import XCTest

@testable import HermesMobile

/// BUG-027 — a failed gateway image resolve must be retryable. The chip's
/// `.task` used to skip once `failed` latched, so scrolling away and back
/// never tried again.
final class ImageChipLoadGateTests: XCTestCase {
    func testFailedChipMayLoadAgain() {
        XCTAssertTrue(
            ImageChipLoadGate.shouldLoad(hasThumbnail: false, failed: true),
            "MessageBubbleView.RemoteMediaImage: failed is a one-way latch; .task skips the retry"
        )
    }

    func testSuccessfulChipDoesNotReload() {
        XCTAssertFalse(ImageChipLoadGate.shouldLoad(hasThumbnail: true, failed: false))
        XCTAssertFalse(ImageChipLoadGate.shouldLoad(hasThumbnail: true, failed: true))
    }

    func testFreshChipLoads() {
        XCTAssertTrue(ImageChipLoadGate.shouldLoad(hasThumbnail: false, failed: false))
    }

    func testRetryAdvancesTheTaskToken() {
        let next = ImageChipRetry.advance(token: 0)
        XCTAssertFalse(next.failed, "a tap must clear the latch")
        XCTAssertEqual(next.token, 1, "a tap must change the .task id or the load never re-runs")
        XCTAssertEqual(ImageChipRetry.advance(token: 4).token, 5)
    }
}
