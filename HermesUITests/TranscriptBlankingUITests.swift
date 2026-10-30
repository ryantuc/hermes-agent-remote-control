import XCTest

/// **BUG-016 — the transcript goes blank and every message disappears.**
///
/// The highest-severity bug on record, and the only one whose repro is a
/// *gesture*. That is why this target exists: `simctl` cannot inject input at
/// all — no tap, no type, no long-press, no accessibility query — so a probe
/// built on it can screenshot the bug but can never cause it. `xcodebuild test`
/// against a simulator can, needs no macOS Accessibility permission and no
/// signing, and runs headless over SSH.
///
/// **The binding rule for this harness.** A green run here proves nothing until
/// the same test has been shown to go RED on an unfixed build. A harness that
/// has never failed is not an oracle. Reproduce first, fix second, verify third
/// — and the six-row screenshot fixture could not reproduce it, which is why
/// these drive `-hermesScreenshotRoute transcript-long` instead.
///
/// The blank state has a precise signature and it is what these assert against:
/// **the "Scroll to latest" button is on screen while zero transcript rows are
/// hittable.** That combination cannot occur in any healthy state — the button
/// only appears when the bottom sentinel has left the viewport, which means
/// there is content, and content that exists has rows.
final class TranscriptBlankingUITests: XCTestCase {

    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
        // No backend, no profile, no sign-in: the route seeds 60 rows and skips
        // the network bootstrap entirely. The composer on this screen is
        // deliberately typeable while disconnected, which is what makes repro 2
        // reachable without a gateway.
        app.launchArguments += ["-hermesScreenshotRoute", "transcript-long"]
        app.launch()
    }

    override func tearDown() {
        app = nil
    }

    // MARK: Reading the screen

    /// The transcript's rows, matched on the index the fixture writes into
    /// every row's text.
    ///
    /// Matched, never enumerated. This file used to read
    /// `app.staticTexts.allElementsBoundByIndex` and then ask each element
    /// three separate questions (`exists`, `isHittable`, `label`). Since
    /// BUG-058 gave every line of a message its own text view the screen
    /// carries 215+ accessibility elements, and every one of those questions is
    /// its own round trip into the app: measured at roughly 3.2 s each, this
    /// file's four tests spent 7,617 s of a 7,642 s UI phase, 3,242 s of it in
    /// `testLongPressingAResponseAndDismissingKeepsTheTranscript` alone. The
    /// reads below ask for the fewest elements that can answer the question.
    private var rowQuery: XCUIElementQuery {
        app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'transcript row'"))
    }

    /// Up to `limit` hittable transcript rows, searched upwards from the last
    /// row in the transcript.
    ///
    /// **From the bottom, and why that weakens nothing.** Every assertion in
    /// this file is made with the transcript at its tail, so the rows on screen
    /// are the final ones and a passing run finds what it needs in one or two
    /// queries. When the tail cannot answer, the search keeps going all the way
    /// to row zero — so an empty result still means *no row anywhere on this
    /// screen is hittable*, exactly what the enumerating form meant, and the
    /// expensive walk only happens on the path where the test is about to fail.
    private func hittableRows(limit: Int, labelContains needle: String? = nil) -> [XCUIElement] {
        let rows = rowQuery
        let count = rows.count
        guard count > 0 else { return [] }
        var found: [XCUIElement] = []
        for index in stride(from: count - 1, through: 0, by: -1) {
            let row = rows.element(boundBy: index)
            // `isHittable` is false for an element that does not exist, so this
            // is the `exists && isHittable` pair in one query rather than two.
            guard row.isHittable else { continue }
            if let needle, !row.label.contains(needle) { continue }
            found.append(row)
            if found.count == limit { break }
        }
        return found
    }

    private var scrollToLatest: XCUIElement { app.buttons["Scroll to latest"] }

    /// The whole assertion, in the terms the report used.
    private func assertTranscriptIsNotBlank(_ stage: String, file: StaticString = #filePath, line: UInt = #line) {
        let rows = hittableRows(limit: 1)
        if rows.isEmpty && scrollToLatest.exists {
            XCTFail("""
                BUG-016 reproduced at "\(stage)": the transcript is blank. Zero rows are hittable \
                and "Scroll to latest" is on screen, which is the signature — the scroll view \
                still has content and the reader can see none of it.
                """, file: file, line: line)
        }
        XCTAssertFalse(rows.isEmpty, """
            no transcript rows are hittable after "\(stage)" — every message on the screen has \
            gone. (Recovery button present: \(scrollToLatest.exists))
            """, file: file, line: line)
    }

    private func waitForTranscript() {
        let anyRow = app.staticTexts.matching(
            NSPredicate(format: "label BEGINSWITH 'transcript row'")
        ).firstMatch
        XCTAssertTrue(anyRow.waitForExistence(timeout: 20), """
            the seeded transcript never appeared, so nothing below this proves anything. \
            Check that -hermesScreenshotRoute transcript-long still seeds 60 rows
            """)
    }

    // MARK: The control

    /// Nothing has been touched. If this fails the harness is broken, not the
    /// app — and every other test in this file is meaningless.
    func testTheSeededTranscriptIsVisibleToBeginWith() {
        waitForTranscript()
        XCTAssertGreaterThan(hittableRows(limit: 2).count, 1,
                             "the fixture should put several short rows on screen at once")
        assertTranscriptIsNotBlank("launch")
    }

    // MARK: Repro 1 — long-press a response, then tap away

    /// The reported gesture: long-press an assistant message to raise its
    /// context menu, then dismiss the menu by tapping elsewhere.
    func testLongPressingAResponseAndDismissingKeepsTheTranscript() {
        waitForTranscript()
        let target = hittableRows(limit: 1, labelContains: "answer").first
            ?? hittableRows(limit: 1).first
        guard let target else { return XCTFail("no row to long-press") }
        let pressed = target.label

        target.press(forDuration: 1.2)
        // The menu is a system surface; dismissing it is a tap on the dimmed
        // area outside it. The navigation bar is reliably outside.
        app.tap()

        // Give the layout that follows the dismissal a beat to settle before
        // reading — this is a repro, not a race, so a fixed settle is honest
        // here where a `waitForExistence` on the thing being asserted would
        // paper over the very state under test.
        Thread.sleep(forTimeInterval: 1.0)
        assertTranscriptIsNotBlank("long-press \(pressed), then tap away")
    }

    // MARK: Repro 2 — type until the composer wraps

    /// The second reported repro, and the one whose mechanics rule pass-1 code
    /// out: none of the three scroll triggers fires while you type, so a blank
    /// here is the anchor re-deriving its offset when the composer's growth
    /// changes the scroll view's height.
    func testTypingUntilTheComposerWrapsKeepsTheTranscript() {
        waitForTranscript()
        let field = app.textViews.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 10), "the composer field never appeared")
        field.tap()

        // Enough to wrap several times on any phone width. Typed in chunks so
        // the field grows repeatedly rather than once.
        for chunk in 1...6 {
            field.typeText("the quick brown fox jumps over the lazy dog \(chunk) ")
            Thread.sleep(forTimeInterval: 0.3)
        }

        Thread.sleep(forTimeInterval: 1.0)
        assertTranscriptIsNotBlank("typing until the composer wraps")
    }

    // MARK: The recovery path

    /// Direction B of the fix list: whatever else is true, escaping the blank
    /// must be deterministic. If the button is on screen, tapping it must put
    /// rows back.
    func testScrollToLatestAlwaysRecoversTheTranscript() {
        waitForTranscript()
        // Scroll up far enough for the recovery button to appear.
        let transcript = app.scrollViews.firstMatch
        for _ in 0..<4 { transcript.swipeDown() }
        guard scrollToLatest.waitForExistence(timeout: 5) else {
            // Not a failure of the app: on a tall screen four swipes may not
            // leave the sentinel. Nothing to assert.
            return
        }

        scrollToLatest.tap()
        Thread.sleep(forTimeInterval: 1.0)
        assertTranscriptIsNotBlank("tapping Scroll to latest")
    }
}
