import XCTest

/// BUG-146 (`ChatSettingsView.swift` `composerActionsValue`), filed by reading: Settings → Chat's "Composer actions" row reads `ComposerQuickAction.enabled`, a plain `UserDefaults` read SwiftUI cannot observe, so after the pushed Composer actions screen changes the set, Back would return to a row still showing the old count.
///
/// Measured, it does not reproduce. On the unchanged screen the row read "1 shown" before the push and "2 shown" after Back: the pop re-evaluates the screen's body, which re-reads the defaults. So `ChatSettingsView` is left as it is and this test is the pin that keeps it true.
///
/// Only this target can drive a push and a pop. `-hermesScreenshotRoute settings-chat` opens Settings → Chat with no backend. The test leaves the stored set as it found it: whatever it adds it removes again before it asserts.
///
/// The companion row, "Transcript", is not tested here because it cannot go stale: `TranscriptPreferences.groupRepeatedCalls` reads an `@Observable` store (`TranscriptPreferences.swift:4-9`, `:54-55`), which SwiftUI tracks.
final class ChatSettingsComposerCountUITests: XCTestCase {

    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments += ["-hermesScreenshotRoute", "settings-chat"]
        app.launch()
    }

    override func tearDown() { app = nil }

    private var composerRow: XCUIElement {
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Composer actions: '")).firstMatch
    }

    /// "Composer actions: 3 shown" → 3.
    private func shownCount(_ label: String) -> Int? {
        let digits = label.drop { !$0.isNumber }.prefix { $0.isNumber }
        return Int(digits)
    }

    private func goBack() {
        let back = app.navigationBars.firstMatch.buttons.element(boundBy: 0)
        XCTAssertTrue(back.waitForExistence(timeout: 10), "no Back button on Composer actions")
        back.tap()
    }

    func testTheComposerActionsCountFollowsAChangeMadeOnThePushedScreen() {
        XCTAssertTrue(composerRow.waitForExistence(timeout: 60), "Settings → Chat never drew the Composer actions row")
        let before = composerRow.label
        guard let countBefore = shownCount(before) else {
            return XCTFail("could not read a count from \(before)")
        }

        composerRow.tap()
        let add = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Add '")).firstMatch
        let remove = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Remove '")).firstMatch
        XCTAssertTrue(add.waitForExistence(timeout: 10) || remove.exists, "Composer actions drew neither an Add nor a Remove control")

        // Add one when one is available, otherwise take one off; either moves the count by one.
        let added: String?
        let expected: Int
        if add.exists {
            added = String(add.label.dropFirst("Add ".count))
            expected = countBefore + 1
            add.tap()
        } else {
            added = nil
            expected = countBefore - 1
            remove.tap()
        }

        goBack()
        XCTAssertTrue(composerRow.waitForExistence(timeout: 10), "Back did not return to Settings → Chat")
        let after = composerRow.label
        print("[w3d-chatsettings] before=\(before) after=\(after) expected=\(expected)")

        // Put the stored set back before asserting, so a red run does not leave the simulator changed.
        composerRow.tap()
        if let name = added {
            let undo = app.buttons["Remove \(name)"]
            if undo.waitForExistence(timeout: 10) { undo.tap() }
        } else {
            let undo = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Add '")).firstMatch
            if undo.waitForExistence(timeout: 10) { undo.tap() }
        }
        goBack()

        XCTAssertEqual(shownCount(after), expected, "the row still reads \(after) after the set changed from \(countBefore) to \(expected)")
    }
}
