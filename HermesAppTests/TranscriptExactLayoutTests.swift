import XCTest
@testable import HermesMobile

/// BUG-016 — the transcript is a plain stack now, and `isNearBottom` is a
/// measurement rather than a side effect of lazy realisation. These pin the
/// two rules `ChatView` wires up: the near-bottom comparison and the window
/// that bounds what the plain stack lays out.
///
/// As with `TranscriptScrollTests`, no test here can assert a scroll offset —
/// the oracle for the white canvas is a phone.
final class TranscriptExactLayoutTests: XCTestCase {
    private typealias Geometry = TranscriptScroll.Geometry
    private typealias Window = TranscriptScroll.Window

    // MARK: Near-bottom as a measurement

    func testASentinelInsideTheViewportIsNearBottom() {
        XCTAssertEqual(Geometry.isNearBottom(sentinelBottom: 600, viewportHeight: 700), true)
    }

    func testASentinelWithinSlackBelowTheViewportIsStillNearBottom() {
        XCTAssertEqual(
            Geometry.isNearBottom(sentinelBottom: 700 + Geometry.slack, viewportHeight: 700),
            true
        )
    }

    func testASentinelPastTheSlackIsNotNearBottom() {
        XCTAssertEqual(
            Geometry.isNearBottom(sentinelBottom: 700 + Geometry.slack + 1, viewportHeight: 700),
            false
        )
    }

    func testASentinelAScreenBelowIsNotNearBottom() {
        XCTAssertEqual(Geometry.isNearBottom(sentinelBottom: 2400, viewportHeight: 700), false)
    }

    /// Over-scrolled past the end (a bounce): the sentinel is above the
    /// viewport's bottom, which is at the tail, not away from it.
    func testASentinelAboveTheViewportIsNearBottom() {
        XCTAssertEqual(Geometry.isNearBottom(sentinelBottom: -20, viewportHeight: 700), true)
    }

    /// The failure this replaces was a stranded signal. An unreported
    /// measurement must decide nothing rather than decide "not at the tail".
    func testUnreportedMeasurementsDecideNothing() {
        XCTAssertNil(Geometry.isNearBottom(sentinelBottom: 600, viewportHeight: 0))
        XCTAssertNil(Geometry.isNearBottom(sentinelBottom: 0, viewportHeight: 700))
    }

    // MARK: The stack is pinned to the viewport's width

    /// A plain stack reports its widest child; the first gate measured the ↓
    /// button at x = 453 on a 402 pt screen. The stack's width is the
    /// viewport's, not the content's.
    func testTheContentWidthIsTheViewportOnAPhone() {
        XCTAssertEqual(Geometry.contentWidth(viewport: 402), 402)
    }

    func testTheContentWidthCapsInLandscape() {
        XCTAssertEqual(Geometry.contentWidth(viewport: 874), Geometry.maxContentWidth)
    }

    func testAnUnmeasuredViewportPinsNothing() {
        XCTAssertNil(Geometry.contentWidth(viewport: 0))
    }

    // MARK: The window

    func testATranscriptAtOrUnderTheCapIsShownWhole() {
        let entries = Array(0..<Window.size)
        XCTAssertEqual(Window.hiddenCount(total: entries.count, revealed: 0), 0)
        XCTAssertEqual(Window.visible(entries, revealed: 0), entries)
    }

    func testATranscriptOverTheCapHidesItsEarliestEntries() {
        let entries = Array(0..<(Window.size + 50))
        XCTAssertEqual(Window.hiddenCount(total: entries.count, revealed: 0), 50)
        XCTAssertEqual(Window.visible(entries, revealed: 0), Array(50..<(Window.size + 50)))
    }

    func testRevealingLiftsTheCapOneWindowAtATime() {
        let total = Window.size * 2 + 10
        XCTAssertEqual(Window.hiddenCount(total: total, revealed: Window.size), 10)
        XCTAssertEqual(Window.hiddenCount(total: total, revealed: Window.size * 2), 0)
    }

    func testANegativeRevealCountsAsNone() {
        let total = Window.size + 30
        XCTAssertEqual(
            Window.hiddenCount(total: total, revealed: -5),
            Window.hiddenCount(total: total, revealed: 0)
        )
    }
}
