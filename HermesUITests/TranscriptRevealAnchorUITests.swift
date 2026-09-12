import XCTest

/// **BUG-122 — `Show N earlier messages` does not keep the reader's place, measured.**
///
/// `EarlierMessagesRow` carried the claim that "content added above the viewport under `.defaultScrollAnchor(.bottom)` leaves the rows the reader is looking at where they are, so revealing never moves the reader." A device falsified it. This file is the instrument that says how, rather than a second assumption about why.
///
/// **The discriminator, and why it needs no content-offset reading.** Two rows are named on every run: the `Show N earlier messages` button, which sits at the very top of the content and therefore moves with it, and `transcript row 250 — question`, the oldest entry the initial window holds and so the row directly under the button. If the reveal leaves the content offset alone — the mechanism BUG-122 infers — then the button keeps its screen position and every retained row is pushed *down* by exactly the height of the block that was inserted above it. If the offset is compensated, the opposite: the retained row keeps its screen position and the button leaves the top of the screen. The two cases are distinguishable from screen frames alone, and the difference between them is the prepended height, which the run prints.
///
/// **The fixture, and the one coupling this file deliberately does not have.** `-hermesScreenshotRoute transcript-windowed` seeds fifty entries past two windows with no backend (`ChatModel.seedWindowedDemoTranscript`), so the reveal row is on screen at the top on open and one tap still leaves a count behind. The two rows this measures are named by the fixture itself — *window edge* is the oldest entry the initial window holds, *reveal edge* the oldest that one tap adds — rather than by an index computed from `TranscriptScroll.Window.size`, because BUG-123's candidate knob is that number and a UI suite that silently staged nothing after somebody lowered it would be worse than no suite at all.
///
/// **What a green here does not prove.** The simulator is not the phone: it does not stage BUG-016's blank and its layout costs are not the device's. What it does prove is arithmetic — where a named row is before a reveal and where it is after — and that is the whole of what BUG-122 is a report of.
final class TranscriptRevealAnchorUITests: XCTestCase {

    /// The fixture's shape, restated so a failure names the number that moved.
    private enum Fixture {
        static let route = "transcript-windowed"
        /// The oldest entry the initial window holds — the row directly under
        /// the reveal row, and the one whose screen position is the verdict.
        static let anchorRow = "window edge"
        /// The oldest entry one tap on the reveal row adds.
        static let revealedRow = "reveal edge"
    }

    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = true
        app = XCUIApplication()
        app.launchArguments += ["-hermesScreenshotRoute", Fixture.route]
    }

    override func tearDown() { app = nil }

    private var transcript: XCUIElement { app.scrollViews.firstMatch }
    private var earlier: XCUIElement { app.buttons["hermes.transcript.earlier"] }
    private var anchor: XCUIElement { row(Fixture.anchorRow) }
    private var revealed: XCUIElement { row(Fixture.revealedRow) }

    /// A row by the marker the fixture wrote into it. `CONTAINS` rather than an
    /// exact subscript, so neither the row's index nor a label that ever gains
    /// a prefix or a suffix turns this instrument into a silent no-match.
    private func row(_ marker: String) -> XCUIElement {
        app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", marker)).firstMatch
    }

    /// Drag the transcript down until the reveal row is on screen, which is the
    /// only state the affordance can be tapped from and the state the defect
    /// was reported from.
    ///
    /// The window is two hundred rows and a row is tens of points, so the top
    /// of it is thousands of points above the tail — `TranscriptBlankingUITests`
    /// already records that four swipes may not clear even the sixty-row
    /// fixture. Fast swipes, in batches, with the batch printed so a run that
    /// ran out of them says how far it got rather than looking like the row was
    /// missing.
    @discardableResult
    private func scrollToTheReveal(limit: Int = 96) -> Int {
        var swipes = 0
        while swipes < limit {
            if earlier.exists && earlier.isHittable { return swipes }
            print("BUG122 | SCROLLING | swipes=\(swipes) earlierExists=\(earlier.exists)")
            for _ in 0..<6 {
                transcript.swipeDown(velocity: .fast)
                swipes += 1
            }
        }
        return swipes
    }

    /// Read a frame only once the layout has stopped moving, so a reading is
    /// never taken between the reveal and a correction that follows it.
    private func settledFrame(_ element: XCUIElement, tries: Int = 12) -> CGRect {
        var last = element.frame
        for _ in 0..<tries {
            Thread.sleep(forTimeInterval: 0.5)
            let now = element.frame
            if abs(now.minY - last.minY) < 0.5 { return now }
            last = now
        }
        return last
    }

    private func attach(_ name: String) {
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    // MARK: The measurement

    func testRevealingEarlierMessagesLeavesTheReaderWhereTheyWere() {
        app.launch()

        XCTAssertTrue(
            app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'transcript row'"))
                .firstMatch.waitForExistence(timeout: 60),
            "the seeded 450-entry transcript never appeared"
        )

        let swipes = scrollToTheReveal()
        XCTAssertTrue(
            earlier.exists && earlier.isHittable,
            "the Show N earlier messages row never came on screen after \(swipes) swipes"
        )

        let viewport = transcript.frame
        let earlierBefore = settledFrame(earlier)
        let earlierLabelBefore = earlier.label
        let anchorBefore = settledFrame(anchor)
        attach("bug122-before-reveal")

        print("BUG122 | BEFORE | viewport=\(viewport)"
              + " | label=\(earlierLabelBefore)"
              + " | earlierY=\(earlierBefore.minY)"
              + " | anchorY=\(anchorBefore.minY) hittable=\(anchor.isHittable)"
              + " | revealedRowExists=\(revealed.exists)"
              + " | swipes=\(swipes)")

        XCTAssertTrue(
            anchor.isHittable,
            "the oldest windowed row is not on screen, so this run staged nothing"
        )
        XCTAssertFalse(
            revealed.exists,
            "\(Fixture.revealedRow) is in the tree before the reveal — the window is not what this test assumes"
        )

        earlier.tap()

        XCTAssertTrue(
            revealed.waitForExistence(timeout: 60),
            "one tap on the reveal row never added the block above it"
        )

        let anchorAfter = settledFrame(anchor)
        let earlierAfter = earlier.exists ? earlier.frame : .null
        let earlierLabelAfter = earlier.exists ? earlier.label : "(gone)"
        attach("bug122-after-reveal")

        let anchorShift = anchorAfter.minY - anchorBefore.minY
        let earlierShift = earlierAfter.isNull ? Double.nan : Double(earlierAfter.minY - earlierBefore.minY)

        print("BUG122 | AFTER | label=\(earlierLabelAfter)"
              + " | earlierY=\(earlierAfter.minY) earlierShift=\(earlierShift)"
              + " | anchorY=\(anchorAfter.minY) anchorShift=\(anchorShift) hittable=\(anchor.isHittable)"
              + " | revealedRowY=\(revealed.frame.minY) hittable=\(revealed.isHittable)")
        print("BUG122 | READING | uncompensated-offset means anchorShift == prepended height and earlierShift == 0;"
              + " compensated means anchorShift == 0 and earlierShift == -prepended height")

        // The whole of the fix: the row the reader was looking at is where it
        // was, to within a point.
        XCTAssertEqual(
            Double(anchorShift), 0, accuracy: 2,
            "the reveal moved \(Fixture.anchorRow) by \(anchorShift) pt — the reader's place was not kept"
        )
        // And the block that was revealed is above it rather than under the
        // viewport: the reader continues upward into it by choice.
        XCTAssertFalse(
            revealed.isHittable,
            "the viewport is showing \(Fixture.revealedRow), the top of the newly revealed block"
        )
    }
}
