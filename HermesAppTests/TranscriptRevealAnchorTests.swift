import UIKit
import XCTest

@testable import HermesMobile

/// **BUG-122 — `Show N earlier messages` moved the reader to the top of the block it revealed.**
///
/// `EarlierMessagesRow` shipped with the claim that content added above the viewport under `.defaultScrollAnchor(.bottom)` leaves the visible rows where they are. A device falsified it and `TranscriptRevealAnchorUITests` measured the mechanism on the simulator: the content offset does not move across the reveal, so the reveal row keeps its screen position and every row below it is pushed down by the height of the inserted block — the viewport ends up at the top of the newly loaded window.
///
/// The correction is the distance the **bottom sentinel** travelled across the reveal. The sentinel reports its bottom edge in the scroll view's own coordinate space, so it is measured from the viewport and not from the content: inserting rows above the reader moves it down by exactly the height inserted. Moving the content offset down by that same amount puts every visible row back where it was, exactly — a plain stack's heights are real, so nothing here is estimated, and BUG-016's whole point was to stop building on an estimate.
///
/// What is testable is the arithmetic and the wiring. That a reader on a device is where they were is a hand check.
final class TranscriptRevealAnchorTests: XCTestCase {

    // MARK: The arithmetic

    /// The ordinary case: a window of rows goes in above the reader and the
    /// sentinel, measured from the viewport, moves down by their height.
    func testTheShiftIsTheDistanceTheSentinelTravelled() {
        XCTAssertEqual(TranscriptMomentum.revealShift(before: 640, after: 9_240), 8_600)
    }

    /// Zero is this transcript's spelling of *unreported* — the same convention
    /// `TranscriptScroll.Geometry.isNearBottom` guards on. A reading that never
    /// happened is not a measurement of no movement.
    func testAnUnreportedReadingBeforeTheRevealDecidesNothing() {
        XCTAssertNil(TranscriptMomentum.revealShift(before: 0, after: 9_240))
    }

    func testAnUnreportedReadingAfterTheRevealDecidesNothing() {
        XCTAssertNil(TranscriptMomentum.revealShift(before: 640, after: 0))
    }

    /// A sentinel that did not move means the reader did not move, so there is
    /// nothing to put back. This is also what a future SwiftUI that *does*
    /// absorb the prepend would produce, and the correct answer to it is to
    /// leave the offset alone rather than to double the compensation.
    func testASentinelThatDidNotMoveNeedsNoCorrection() {
        XCTAssertNil(TranscriptMomentum.revealShift(before: 640, after: 640))
    }

    /// Upward travel is not this correction's case at all: it means content
    /// left from above the viewport, or something else already compensated and
    /// overshot. Either way, moving the reader further is the wrong repair.
    func testASentinelThatMovedUpIsNotThisCorrectionsCase() {
        XCTAssertNil(TranscriptMomentum.revealShift(before: 9_240, after: 640))
    }

    // MARK: The wiring

    /// The whole object against a real `UIScrollView`: arm with the reading
    /// taken before the rows go in, absorb the one taken after, and the offset
    /// moves by exactly the difference.
    @MainActor
    func testAbsorbingARevealMovesTheOffsetByTheHeightThatWasInserted() {
        let scrollView = UIScrollView(frame: CGRect(x: 0, y: 0, width: 390, height: 700))
        scrollView.contentSize = CGSize(width: 390, height: 12_000)
        scrollView.contentOffset = CGPoint(x: 0, y: 0)

        let momentum = TranscriptMomentum()
        momentum.scrollView = scrollView

        momentum.armReveal(sentinelBottom: 640)
        XCTAssertTrue(momentum.absorbReveal(sentinelBottom: 9_240))
        XCTAssertEqual(scrollView.contentOffset.y, 8_600, accuracy: 0.5,
                       "the reader's rows have to end up where they started")
    }

    /// A sentinel reading that is not the far side of a reveal must not move
    /// anybody. Every layout pass produces one of these; only the reveal arms
    /// the correction.
    @MainActor
    func testASentinelReadingWithNoRevealOutstandingChangesNothing() {
        let scrollView = UIScrollView(frame: CGRect(x: 0, y: 0, width: 390, height: 700))
        scrollView.contentSize = CGSize(width: 390, height: 12_000)
        scrollView.contentOffset = CGPoint(x: 0, y: 4_000)

        let momentum = TranscriptMomentum()
        momentum.scrollView = scrollView

        XCTAssertFalse(momentum.absorbReveal(sentinelBottom: 9_240))
        XCTAssertEqual(scrollView.contentOffset.y, 4_000, accuracy: 0.5)
    }

    /// One arm, one correction. The reveal's layout is followed by a stream of
    /// ordinary sentinel readings, and a second correction against one of them
    /// would move the reader for no reason.
    @MainActor
    func testTheCorrectionIsSingleShot() {
        let scrollView = UIScrollView(frame: CGRect(x: 0, y: 0, width: 390, height: 700))
        scrollView.contentSize = CGSize(width: 390, height: 12_000)
        scrollView.contentOffset = CGPoint(x: 0, y: 0)

        let momentum = TranscriptMomentum()
        momentum.scrollView = scrollView

        momentum.armReveal(sentinelBottom: 640)
        XCTAssertTrue(momentum.absorbReveal(sentinelBottom: 9_240))
        XCTAssertFalse(momentum.absorbReveal(sentinelBottom: 9_240),
                       "the arm is consumed by the reading that answers it")
        XCTAssertEqual(scrollView.contentOffset.y, 8_600, accuracy: 0.5)
    }

    /// And with nothing found — `EnclosingScrollViewReader`'s superview walk is
    /// deliberately fragile introspection — the arm is still consumed and
    /// nothing traps. `ChatView` takes the degraded path in that case, which it
    /// decides before arming.
    @MainActor
    func testAbsorbingWithNoScrollViewFoundIsSafe() {
        let momentum = TranscriptMomentum()
        momentum.armReveal(sentinelBottom: 640)
        XCTAssertFalse(momentum.absorbReveal(sentinelBottom: 9_240))
    }
}
