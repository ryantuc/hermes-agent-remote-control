import XCTest

/// The transcript stays with a streaming reply and lands at the end of it; a reader who scrolled back is left alone; sending from scrollback goes to the bottom.
///
/// The demo route plays two scripted turns through the real client with no backend: thinking, a plan, three tool cards and a streamed report with a table, each ending in `message.complete`. The oracle is what the person sees: the glass "Scroll to latest" disc, which the app draws only while the bottom sentinel is off the screen, and the frame of the last reply's footer row against the transcript's own frame.
final class TranscriptFollowUITests: XCTestCase {

    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments += ["-hermesScreenshotRoute", "demo-chat"]
        app.launch()
    }

    override func tearDown() { app = nil }

    // MARK: Reading the screen

    private var scrollToLatest: XCUIElement { app.buttons["Scroll to latest"] }
    private var transcript: XCUIElement { app.scrollViews.firstMatch }
    private var composer: XCUIElement { app.textViews.firstMatch }

    /// One per finished reply: the footer row's copy icon, which `MessageActionRow` draws only once a turn is complete.
    private var copyButtons: XCUIElementQuery {
        app.buttons.matching(NSPredicate(format: "label == 'Copy message'"))
    }

    /// Wait until `count` replies have finished.
    private func waitForReplies(_ count: Int, timeout: TimeInterval, file: StaticString = #filePath, line: UInt = #line) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if copyButtons.count >= count { return }
            Thread.sleep(forTimeInterval: 0.5)
        }
        XCTFail("only \(copyButtons.count) of \(count) replies finished within \(Int(timeout)) s", file: file, line: line)
    }

    /// The bottom of the transcript's viewport, in screen points. The dock sits below it; a row under the dock is drawn but out of reach.
    private var viewportBottom: CGFloat { transcript.frame.maxY }

    private func attachScreenshot(_ name: String) {
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    private func assertRestingAtTheEnd(_ stage: String, file: StaticString = #filePath, line: UInt = #line) {
        let footer = copyButtons.element(boundBy: copyButtons.count - 1)
        let footerBottom = footer.frame.maxY
        let disc = scrollToLatest.exists
        print("FOLLOW | \(stage) | disc=\(disc) | footerBottom=\(footerBottom) | viewportBottom=\(viewportBottom) | hittable=\(footer.isHittable)")
        if disc || footerBottom > viewportBottom + 1 { attachScreenshot("SHORT-\(stage)") }
        XCTAssertFalse(disc, """
            \(stage): the reply has finished and "Scroll to latest" is on screen, so the reader is \
            resting above the end of a conversation they were following
            """, file: file, line: line)
        XCTAssertLessThanOrEqual(footerBottom, viewportBottom + 1, """
            \(stage): the last reply's footer ends at \(footerBottom) pt, below the transcript's \
            viewport at \(viewportBottom); the reader has to scroll to see the end of the reply
            """, file: file, line: line)
        XCTAssertTrue(footer.isHittable, "\(stage): the last reply's footer is not reachable", file: file, line: line)
    }

    // MARK: Following lands at the end

    /// Both scripted turns play with nobody touching the screen. After each reply finishes, the footer that appeared with its completion is on screen and the disc is not.
    func testAnUntouchedTranscriptRestsAtTheEndOfEachReply() {
        waitForReplies(1, timeout: 60)
        Thread.sleep(forTimeInterval: 1.5)
        assertRestingAtTheEnd("first reply finished")

        waitForReplies(2, timeout: 90)
        Thread.sleep(forTimeInterval: 1.5)
        assertRestingAtTheEnd("second reply finished")
    }

    // MARK: Scrollback is respected, and a send returns to the bottom

    /// A reader who scrolls back while the second reply streams is not pulled down by the rest of it, and sending a message from there lands at the bottom with the new exchange in view.
    func testAReaderWhoScrolledBackIsLeftAloneAndASendReturnsToTheBottom() throws {
        waitForReplies(1, timeout: 60)
        // The second prompt is sent by the demo's own driver; its bubble is the sign the second reply is under way.
        let secondPrompt = app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'write up the report'")).firstMatch
        XCTAssertTrue(secondPrompt.waitForExistence(timeout: 20), "the second scripted prompt never appeared")

        for _ in 0..<3 { transcript.swipeDown() }
        guard scrollToLatest.waitForExistence(timeout: 3) else {
            throw XCTSkip("the swipes left the reader at the tail this run, so the scrollback and send checks did not run")
        }

        waitForReplies(2, timeout: 90)
        Thread.sleep(forTimeInterval: 1.5)
        if !scrollToLatest.exists { attachScreenshot("YANKED-during-stream") }
        XCTAssertTrue(scrollToLatest.exists, """
            the reader scrolled back while the reply streamed and the transcript pulled them to the \
            bottom anyway; a reader who leaves the tail on purpose must be left where they went
            """)

        composer.tap()
        composer.typeText("hello")
        app.buttons["Send"].tap()
        waitForReplies(3, timeout: 30)
        Thread.sleep(forTimeInterval: 1.5)
        assertRestingAtTheEnd("sent from scrollback")
    }
}
