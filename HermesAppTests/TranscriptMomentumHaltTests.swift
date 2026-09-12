import UIKit
import XCTest

@testable import HermesMobile

/// **BUG-051 — "Scroll to latest" is ignored while a flick is still
/// decelerating: the button animates, nothing moves.**
///
/// The press state runs, so the hit test and the gesture both succeeded
/// (BUG-033's 44 pt target is in and working). What fails is the placement: a
/// discrete `ScrollViewProxy.scrollTo` issued into a decelerating
/// `UIScrollView` is superseded by the deceleration rather than cancelling it.
///
/// So the fix stops the momentum and then places. It does **not** animate: an
/// animated scroll drive inside this transcript is BUG-009's lockup mechanism
/// and BUG-016 measured one animated one-shot wedging the main thread for over
/// 150 s.
///
/// **The coasting itself is device-verified, not asserted here.** `isDragging`
/// and `isDecelerating` are set by real touch delivery; no unit test can put a
/// scroll view into deceleration. What is testable is the judgement — which
/// phases must be stopped — and that the stop is a no-op on a scroll view at
/// rest, which is the property that keeps this change invisible in the ordinary
/// case.
final class TranscriptMomentumHaltTests: XCTestCase {

    // MARK: The judgement

    /// The reported case: the finger has lifted and the transcript is coasting.
    func testADeceleratingScrollViewMustBeStopped() {
        XCTAssertTrue(
            TranscriptMomentum.shouldHalt(isDragging: false, isDecelerating: true),
            "the tap has to win over the flick it interrupts"
        )
    }

    /// The same failure one moment earlier. A finger still down owns the
    /// offset, and a placement issued under it is overwritten by the next touch
    /// delivery.
    func testADraggingScrollViewMustBeStopped() {
        XCTAssertTrue(TranscriptMomentum.shouldHalt(isDragging: true, isDecelerating: false))
    }

    /// A scroll view at rest has no momentum to cancel, and cancelling nothing
    /// is how a fix for a rare state breaks the common one.
    func testAScrollViewAtRestIsLeftAlone() {
        XCTAssertFalse(TranscriptMomentum.shouldHalt(isDragging: false, isDecelerating: false))
    }

    // MARK: The wiring

    /// The whole object, against a real `UIScrollView` sitting still: no stop,
    /// no offset change, and it says so.
    @MainActor
    func testHaltIsANoOpOnAScrollViewThatIsNotMoving() {
        let scrollView = UIScrollView(frame: CGRect(x: 0, y: 0, width: 320, height: 480))
        scrollView.contentSize = CGSize(width: 320, height: 4000)
        scrollView.contentOffset = CGPoint(x: 0, y: 1200)

        let momentum = TranscriptMomentum()
        momentum.scrollView = scrollView

        XCTAssertFalse(momentum.halt(), "nothing was moving, so nothing was stopped")
        XCTAssertEqual(scrollView.contentOffset.y, 1200, accuracy: 0.5,
                       "a no-op must not move the reader")
    }

    /// And with nothing found — a future SwiftUI backing `ScrollView` with
    /// something that is not a `UIScrollView` — the button degrades to exactly
    /// what it does today rather than trapping.
    @MainActor
    func testHaltWithNoScrollViewFoundIsSafe() {
        XCTAssertFalse(TranscriptMomentum().halt())
    }
}
