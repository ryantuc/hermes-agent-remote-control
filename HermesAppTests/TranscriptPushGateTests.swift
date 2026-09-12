import Foundation
import XCTest

@testable import HermesMobile

/// BUG-121, second half — the push into a conversation freezes mid-slide.
///
/// A screenshot catches the transition stopped in the middle of itself: the Home screen's white corner still visible at the top left, the `⋯` trailing button still off the right edge, Back and the title mid-slide — all of it under "Loading conversation…". Nothing about the bar's layout is wrong, which is what `TopBarAlignmentUITests` measured and found identical between the loading and painted states; the bar is simply stopped, because the main thread that drives a `UINavigationController` push is the same thread that lays out the transcript, and the first layout of up to 200 messages holds it for seconds.
///
/// The gate is a rule with two inputs, so it is stated as one and pinned here. What cannot be pinned without a device is that 0.4 s is past the end of the push.
final class TranscriptPushGateTests: XCTestCase {

    /// The case the screenshot caught: a cold open, where the rows are still on their way when the push starts.
    func testAChatWithNothingToDrawIsHeldUntilTheTransitionEnds() {
        XCTAssertTrue(
            TranscriptScroll.PushGate.holds(hadRowsOnAppear: false, transitionEnded: false),
            "a transcript that had nothing to draw when the push began must not start laying rows out during it"
        )
        XCTAssertFalse(
            TranscriptScroll.PushGate.holds(hadRowsOnAppear: false, transitionEnded: true),
            "once the transition is over the hold is released, or the spinner would never end"
        )
    }

    /// The case that must cost nothing: a chat whose rows were already in the model. Its layout was paid before the push began, so holding it would add a wait that fixes nothing.
    func testAChatThatAlreadyHadItsRowsIsNeverHeld() {
        XCTAssertFalse(
            TranscriptScroll.PushGate.holds(hadRowsOnAppear: true, transitionEnded: false),
            "a chat that was already painted must open exactly as it did before this gate existed"
        )
        XCTAssertFalse(
            TranscriptScroll.PushGate.holds(hadRowsOnAppear: true, transitionEnded: true),
            "and it stays unheld afterwards"
        )
    }

    /// The delay is a property of `UINavigationController`'s push, not a taste: 0.35 s is the animation, and the gate has to open after it rather than during it. A value under the animation would reproduce the bug it fixes; a large one would be a spinner nobody asked for.
    func testTheSettleDelayIsPastTheEndOfAPushAndNotAPauseOfItsOwn() {
        XCTAssertGreaterThan(TranscriptScroll.PushGate.settleDelay, 0.35,
                             "a gate that opens during the push is the bug, not the fix")
        XCTAssertLessThanOrEqual(TranscriptScroll.PushGate.settleDelay, 0.6,
                                 "past about half a second the reader is waiting on the gate rather than on the app")
    }
}
