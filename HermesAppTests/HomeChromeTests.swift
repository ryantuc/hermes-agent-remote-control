import HermesServeKit
import SwiftUI
import XCTest

@testable import HermesMobile

/// BUG-063 — the three Home chrome nits, pinned as arithmetic.
///
/// All three are visual, and two of them are the kind of visual that a screenshot cannot settle: "the picker is off-centre" is a claim about two numbers being equal, and "the ring should not shrink the button" is a claim about one number fitting inside another. Those are asserted here. The third — that the mark reads `HERMES AGENT` — is asserted against Desktop's own constant rather than against a preference, because the acceptance is parity and not taste.
///
/// What is deliberately not here: whether any of it looks right. That is a hand check on a device.
@MainActor
final class HomeChromeTests: XCTestCase {

    // MARK: (1) and (2) — the bar's ends

    /// **The defect, stated as the equality that was false.**
    ///
    /// Home's top bar is `[leading] Spacer chips Spacer [trailing]`. Two `Spacer`s split the free space evenly, so what lands at the screen's centre is the midpoint of everything between them — and that is only the bar's own centre when the two ends are the same width. The trailing end grew a second 44 pt control when Bots mode added the mode switch, and nothing grew to match it, so the chips were centred inside a bar 44 pt narrower on the right than the left and sat 22 pt to the left of centre.
    func testTheTopBarEndsWeighTheSameSoTheChipsSitAtTheCentre() {
        XCTAssertEqual(HomeChrome.leadingWidth, HomeChrome.trailingWidth,
                       "the two ends of Home's top bar are unequal, so the Spacers centre the chips somewhere other than the screen's centre — this is BUG-063 (1)")
    }

    /// The count, not only the total, because the two are not the same claim. A single 88 pt leading box would satisfy the equality above and would also give the hamburger an 88 pt hit target, which is a different bug.
    func testEachEndIsWholeHitBoxesRatherThanOneWideOne() {
        XCTAssertEqual(HomeChrome.leadingSlots, HomeChrome.trailingSlots,
                       "the ends must balance as equal numbers of hit boxes; widening one control to fill the gap doubles its tap target")
        XCTAssertEqual(HomeChrome.slotWidth, Hit.min,
                       "a chrome slot narrower than the minimum target would balance the bar by shrinking a control")
    }

    /// A guard on the arithmetic rather than on today's number. If a third trailing control ever lands, this fails and names the reason instead of letting the pill drift back off centre unnoticed.
    func testAddingATrailingControlWithoutAMirrorWouldFailHere() {
        let imagined = CGFloat(HomeChrome.trailingSlots + 1) * HomeChrome.slotWidth
        XCTAssertNotEqual(HomeChrome.leadingWidth, imagined,
                          "this test exists to fail the day a control is added to one end only — if it passes, the mirror was added too and the constants above should have moved")
    }

    // MARK: (3) — the mode control's ring

    /// **The ring is decoration inside the target, not the target.**
    ///
    /// The report asked for a circle so the control stands out. The failure mode worth pinning is the one where somebody satisfies that by making the drawn circle *be* the button: a 34 pt tap target is below the floor, and no visual test would notice.
    func testTheRingFitsInsideTheHitBoxWithoutShrinkingIt() {
        XCTAssertLessThan(HomeModeControl.ringDiameter, Hit.min,
                          "a ring at or above the hit box's size is drawing the target rather than sitting inside it")
        XCTAssertGreaterThan(HomeModeControl.ringDiameter, HomeModeControl.glyphSize,
                             "the ring has to clear the glyph it surrounds")
    }

    /// `strokeBorder` draws inward, so the ring's weight is spent inside `ringDiameter` and the box does not grow. Stated because `stroke` — the one-word change that breaks it — would centre the line on the path and make the drawn circle `ringDiameter + ringWidth` across.
    func testTheRingsWeightIsSpentInsideItsDiameter() {
        XCTAssertLessThanOrEqual(HomeModeControl.ringDiameter + HomeModeControl.ringWidth, Hit.min,
                                 "even drawn outward the ring must not exceed the hit box, or the two top-bar controls stop lining up")
        XCTAssertGreaterThan(HomeModeControl.ringWidth, 0,
                             "a zero-width ring is the defect this item was filed for")
    }

    // MARK: (4) — the wordmark

    /// Desktop's constant, verbatim.
    ///
    /// `apps/desktop/src/components/chat/intro.tsx:147` at `de25a6971d` declares `const WORDMARK = 'HERMES AGENT'`, rendered through an `uppercase` class. Read the running build rather than a checkout, which can be stale.
    ///
    /// The string is asserted rather than the appearance because the acceptance is parity with Desktop, and parity is checkable.
    func testTheWordmarkIsDesktops() {
        XCTAssertEqual(HomeChrome.wordmark, "HERMES AGENT",
                       "the mark on Home is Desktop's WORDMARK constant; changing it here forks the two clients' identity")
    }

    /// The old value, named so a revert is loud. `hermes` was FEAT-007's half-finished rename and is what BUG-063 was filed against.
    func testTheWordmarkIsNoLongerTheLowercaseAppName() {
        XCTAssertNotEqual(HomeChrome.wordmark, "hermes")
        XCTAssertNotEqual(HomeChrome.wordmark, "HermesMobile",
                          "FEAT-007's starting point; if this ever comes back both renames have been undone")
    }

    /// Desktop's `tracking-[0.08em]`. Held as a ratio because the mark draws at 28 pt upright and 20 pt in landscape, and a fixed point value would be 40% too much letter-spacing at the smaller size.
    func testTheWordmarkTracksTheWayDesktopTracksIt() {
        XCTAssertEqual(HomeChrome.wordmarkTrackingRatio, 0.08, accuracy: 0.0001,
                       "Desktop's tracking-[0.08em]")
        XCTAssertEqual(HermesFont.display.size * HomeChrome.wordmarkTrackingRatio, 2.24, accuracy: 0.001,
                       "the upright mark's letter-spacing in points")
        XCTAssertEqual(HermesFont.title.size * HomeChrome.wordmarkTrackingRatio, 1.6, accuracy: 0.001,
                       "the landscape and first-run mark's, which is what the ratio exists to get right")
    }
}
