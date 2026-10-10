import XCTest

/// Jumping to an earlier prompt from the conversation's ⋯ menu, on the 60-row fixture: the chosen prompt comes into view, the reader is then in scrollback with the scroll-to-latest disc showing, and the disc returns them to the live end.
final class TranscriptJumpUITests: XCTestCase {

    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments += ["-hermesScreenshotRoute", "transcript-long"]
        app.launch()
    }

    override func tearDown() { app = nil }

    private var scrollToLatest: XCUIElement { app.buttons["Scroll to latest"] }

    private func row(_ index: Int) -> XCUIElement {
        app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'transcript row \(index) '")).firstMatch
    }

    func testJumpingToTheFirstPromptBringsItOnScreenAndTheDiscReturnsToTheEnd() throws {
        throw XCTSkip("the prompt timeline is switched off (ChatChrome.promptTimelineEnabled) until a jump survives reopening the chat")
        XCTAssertTrue(row(59).waitForExistence(timeout: 40), "the seeded transcript never appeared")
        XCTAssertFalse(scrollToLatest.exists, "the fixture should land at the tail")

        app.buttons["Conversation actions"].tap()
        let entry = app.buttons["Jump to a prompt"]
        XCTAssertTrue(entry.waitForExistence(timeout: 5), "the ⋯ menu offers no prompt timeline")
        entry.tap()

        // The first prompt of the fixture is row 0, "question 1"; the list's rows are buttons labelled with the prompt's first line.
        let target = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'transcript row 0 '")).firstMatch
        XCTAssertTrue(target.waitForExistence(timeout: 10), "the prompt list never showed the first prompt")
        target.tap()

        let landed = row(0)
        XCTAssertTrue(landed.waitForExistence(timeout: 5), "row 0 is not in the tree after the jump")
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline, !landed.isHittable { Thread.sleep(forTimeInterval: 0.25) }
        XCTAssertTrue(landed.isHittable, "the chosen prompt did not come on screen")
        XCTAssertTrue(scrollToLatest.waitForExistence(timeout: 3), "after a jump the reader is in scrollback and the disc is their way back")

        scrollToLatest.tap()
        let back = Date().addingTimeInterval(8)
        while Date() < back, scrollToLatest.exists { Thread.sleep(forTimeInterval: 0.25) }
        XCTAssertFalse(scrollToLatest.exists, "one tap of the disc did not return the reader to the live end")
        XCTAssertTrue(row(59).isHittable, "the last row is not on screen after the return")
    }
}
