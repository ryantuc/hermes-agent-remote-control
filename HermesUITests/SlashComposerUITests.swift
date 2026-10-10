import XCTest

/// Slash commands typed into the real composer, against the in-app demo backend (`-hermesScreenshotRoute demo-home`), which answers the session, prompt and discovery calls without a network.
///
/// Typing matters here and nothing but this target can do it: a command is a command only when its leading slash was typed, so a draft injected through a launch argument is literal text and proves nothing about these paths.
///
/// The keyboard readings are printed as `[slash-ui]` lines. On a simulator with a hardware keyboard connected there is no on-screen keyboard to read, and the readings say so rather than passing for one.
final class SlashComposerUITests: XCTestCase {

    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments += ["-hermesScreenshotRoute", "demo-home"]
        app.launch()
    }

    override func tearDown() {
        app = nil
    }

    // MARK: Helpers

    private var composerField: XCUIElement { app.textViews.firstMatch }
    private var homeMenu: XCUIElement { app.buttons["Menu"] }
    private var sendButton: XCUIElement { app.buttons["Send"] }
    private var modelSearch: XCUIElement { app.textFields["Search models and providers"] }

    /// The demo route lands in its own conversation first and returns to Home a beat later.
    private func waitForHome() {
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline {
            if homeMenu.exists && homeMenu.isHittable && composerField.exists { break }
            Thread.sleep(forTimeInterval: 0.25)
        }
        XCTAssertTrue(homeMenu.exists, "the demo never reached Home")
        // The route returns to Home after a fixed beat; let any late navigation settle.
        Thread.sleep(forTimeInterval: 1.0)
        XCTAssertTrue(homeMenu.exists, "the demo left Home after landing there")
    }

    private func type(_ text: String) {
        let field = composerField
        XCTAssertTrue(field.waitForExistence(timeout: 10), "no composer")
        field.tap()
        Thread.sleep(forTimeInterval: 0.5)
        field.typeText(text)
        Thread.sleep(forTimeInterval: 0.5)
    }

    private var composerText: String {
        (composerField.value as? String) ?? ""
    }

    private func keyboardUp() -> Bool {
        let keyboard = app.keyboards.firstMatch
        return keyboard.exists && keyboard.frame.minY < app.windows.firstMatch.frame.maxY - 1
    }

    private func elements(labelled text: String) -> XCUIElementQuery {
        // Case-insensitive: autocapitalisation is on in the real composer.
        app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS[c] %@", text))
    }

    /// True once the condition has held for `stable` seconds in a row, false if it never did within `timeout`.
    private func settle(timeout: TimeInterval, stable: TimeInterval = 2, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        var heldSince: Date?
        while Date() < deadline {
            if condition() {
                heldSince = heldSince ?? Date()
                if Date().timeIntervalSince(heldSince!) >= stable { return true }
            } else {
                heldSince = nil
            }
            Thread.sleep(forTimeInterval: 0.25)
        }
        return false
    }

    /// Long-presses Send and picks Send as text from its menu, reporting the keyboard while the menu was up, with a screenshot of the open menu.
    private func sendAsTextByLongPress(_ shot: String) -> (menuKeyboard: Bool, item: Bool) {
        XCTAssertTrue(sendButton.waitForExistence(timeout: 5), "no Send control")
        sendButton.press(forDuration: 1.5)
        let item = app.buttons["Send as text"]
        let offered = item.waitForExistence(timeout: 5)
        let menuKeyboard = keyboardUp()
        snapshot(shot)
        if offered { item.tap() }
        return (menuKeyboard, offered)
    }

    /// A screenshot kept in the result bundle.
    private func snapshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    // MARK: "/model"

    /// "/model" on its own is the model drawer: it opens the drawer the model button opens, sends nothing and opens no conversation.
    func testModelFromHomeOpensTheModelDrawerAndStaysOnHome() {
        waitForHome()
        type("/model")
        sendButton.tap()

        XCTAssertTrue(modelSearch.waitForExistence(timeout: 5), "\"/model\" did not open the model drawer")
        snapshot("c1-home-model-drawer")
        XCTAssertEqual(elements(labelled: "not available in HARC").count, 0)

        // Down off the screen by its top edge, the way a person dismisses it.
        let window = app.windows.firstMatch
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.11))
            .press(forDuration: 0.1, thenDragTo: window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.98)))
        XCTAssertTrue(settle(timeout: 5, stable: 0.5) { !modelSearch.exists }, "the model drawer did not dismiss")

        XCTAssertTrue(homeMenu.waitForExistence(timeout: 5), "\"/model\" left Home for a conversation")
        XCTAssertFalse(composerText.contains("/model"), "the command stayed in the composer after it ran: \(composerText)")
    }

    // MARK: Refusals from Home

    /// A command HARC cannot run is refused on Home, with the refusal line above the composer and the draft kept, as in a conversation.
    func testARefusedCommandFromHomeStaysOnHomeWithItsRefusal() {
        waitForHome()
        type("/new")
        sendButton.tap()

        XCTAssertTrue(elements(labelled: "/new is not available in HARC").firstMatch.waitForExistence(timeout: 5),
                      "the refusal line never showed")
        XCTAssertTrue(homeMenu.exists, "the refusal left Home for a conversation")
        XCTAssertTrue(composerText.contains("/new"), "the refused draft was not kept: \(composerText)")
        snapshot("c1-home-refusal")
    }

    // MARK: Reachability with the list open

    /// The slash list open, in portrait and then landscape, and Send still on screen above the keyboard and tappable. Run it at the largest text size by setting the simulator's content size from outside (`simctl ui <device> content_size accessibility-extra-extra-extra-large`); the size is printed so a run says which it measured.
    func testSendStaysReachableWithTheSlashListOpen() {
        waitForHome()
        type("/")
        let list = app.descendants(matching: .any)["Slash completion suggestions"]
        XCTAssertTrue(list.waitForExistence(timeout: 5), "typing a slash did not open the list")

        for orientation in [UIDeviceOrientation.portrait, .landscapeLeft] {
            XCUIDevice.shared.orientation = orientation
            Thread.sleep(forTimeInterval: 2)
            let screen = app.windows.firstMatch.frame
            let keyboard = app.keyboards.firstMatch
            let keyboardTop = keyboard.exists && keyboard.frame.minY < screen.maxY - 1 ? keyboard.frame.minY : screen.maxY
            let send = sendButton.frame
            print("[slash-ui] reachability \(orientation == .portrait ? "portrait" : "landscape"): screen \(screen) · list \(list.exists ? list.frame : .zero) · send \(send) · keyboard top \(keyboardTop) · field \(composerField.frame)")
            XCTAssertTrue(sendButton.exists && sendButton.isHittable, "Send is not tappable with the slash list open in \(orientation == .portrait ? "portrait" : "landscape")")
            XCTAssertLessThanOrEqual(send.maxY, keyboardTop, "Send is under the keyboard with the slash list open")
            XCTAssertGreaterThanOrEqual(send.minY, screen.minY, "Send is off the top of the screen with the slash list open")
            snapshot("c4-slash-list-\(orientation == .portrait ? "portrait" : "landscape")")
        }
        XCUIDevice.shared.orientation = .portrait
    }

    // MARK: Send as text

    /// From Home, Send as text sends the words and opens the conversation they went to, with the composer empty and no refusal anywhere.
    func testSendAsTextFromHomeSendsTheWordsOnce() {
        waitForHome()
        type("/tmp is full")
        let before = keyboardUp()
        let (menuKeyboard, offered) = sendAsTextByLongPress("c2-home-menu")
        XCTAssertTrue(offered, "the long-press menu did not offer Send as text")
        let afterTap = keyboardUp()

        XCTAssertTrue(settle(timeout: 10, stable: 1) { !homeMenu.exists }, "Send as text from Home did not open the conversation")
        Thread.sleep(forTimeInterval: 1.5)
        let landed = keyboardUp()
        snapshot("c2-home-landed")
        let sent = elements(labelled: "is full").count
        print("[slash-ui] home send-as-text: keyboard before=\(before) menu=\(menuKeyboard) afterTap=\(afterTap) landed=\(landed) · elements labelled 'is full'=\(sent) · composer='\(composerText)'")

        XCTAssertGreaterThan(sent, 0, "the words never appeared in the conversation")
        XCTAssertFalse(composerText.contains("is full"), "the composer kept the words it sent: \(composerText)")
        XCTAssertEqual(elements(labelled: "unavailable").count, 0, "a refusal showed for words sent as text")
        XCTAssertEqual(elements(labelled: "not available in HARC").count, 0)
    }

    /// In a conversation, Send as text must do what Send does for ordinary words: one bubble, an empty composer, no refusal, and the keyboard where Send leaves it.
    func testSendAsTextInAConversationBehavesLikeSend() {
        waitForHome()
        type("hello there")
        sendButton.tap()
        XCTAssertTrue(settle(timeout: 10, stable: 1) { !homeMenu.exists }, "the first message did not open its conversation")
        Thread.sleep(forTimeInterval: 1.5)

        // The plain send this is measured against: in the conversation, with the keyboard up. The demo's replies may still be running, so both sends land the same way, mid-turn.
        type("next words")
        sendButton.tap()
        Thread.sleep(forTimeInterval: 1.5)
        let keyboardAfterSend = keyboardUp()
        let baseline = elements(labelled: "next words").count
        XCTAssertGreaterThan(baseline, 0, "the plain message never appeared")

        if !keyboardUp() { composerField.tap(); Thread.sleep(forTimeInterval: 0.5) }
        composerField.typeText("/tmp is full")
        Thread.sleep(forTimeInterval: 0.5)
        let before = keyboardUp()
        let fieldBefore = composerField.frame
        let (menuKeyboard, offered) = sendAsTextByLongPress("c2-chat-menu")
        XCTAssertTrue(offered, "the long-press menu did not offer Send as text")
        let afterTap = keyboardUp()
        Thread.sleep(forTimeInterval: 1.5)
        let afterSettle = keyboardUp()
        snapshot("c2-chat-after")
        let fieldAfter = composerField.frame
        let sent = elements(labelled: "is full").count
        print("[slash-ui] chat send-as-text: keyboard afterPlainSend=\(keyboardAfterSend) before=\(before) menu=\(menuKeyboard) afterTap=\(afterTap) settled=\(afterSettle) · field before \(fieldBefore) after \(fieldAfter) · 'next words'=\(baseline) 'is full'=\(sent) · composer='\(composerText)'")

        XCTAssertEqual(sent, baseline, "Send as text left \(sent) elements for one message where a plain send leaves \(baseline)")
        XCTAssertFalse(composerText.contains("is full"), "the composer kept the words it sent: \(composerText)")
        XCTAssertEqual(elements(labelled: "unavailable").count, 0, "a refusal showed for words sent as text")
        XCTAssertEqual(afterSettle, keyboardAfterSend, "Send as text left the keyboard \(afterSettle ? "up" : "down") where Send leaves it \(keyboardAfterSend ? "up" : "down")")
        // A context menu on Send took the keyboard away while it was open, so the composer fell to the bottom of the screen and the lifted Send floated where it had been (`c2-chat-menu`).
        XCTAssertTrue(menuKeyboard, "the keyboard was gone while the Send as text menu was open")
    }
}
