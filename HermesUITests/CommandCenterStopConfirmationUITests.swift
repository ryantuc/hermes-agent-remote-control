import XCTest

/// BUG-032's §4.3 gate, automated rather than left as a manual pass.
///
/// The design named a hand check on the simulator — tap Interrupt, see the
/// alert, tap Cancel — and called it "a gate, not a nicety", because the
/// specific risk is real and silent: a presentation modifier attached inside a
/// `LazyVStack` row belongs to a view the container is free to tear down,
/// including at the moment the alert is asked to appear, and the failure mode
/// is a destructive control that does nothing at all. `HermesAppTests` cannot
/// assert a SwiftUI presentation, and `HermesUITests` could not reach this list
/// because it loads from `sessionAPI.activeList()` behind a screenshot route
/// with no backend — so the list was always empty and the row was never drawn.
///
/// `-hermesDemoLiveSessions` supplies two rows that look exactly like
/// `session.active_list` answered them. Neither id is known to the engine, so
/// both route to `.confirmThenStopUnattended`, which is the case the alert
/// exists for.
///
/// **What this test does and does not prove.** It proves the confirmation
/// appears on a tap, carries the shared copy, and dismisses on Cancel. It does
/// NOT pin the modifier's placement. Measured: moving the
/// presentation inside the `ForEach` as a negative control left this test
/// GREEN, because two rows in a `LazyVStack` are both on screen and neither is
/// ever recycled, so the torn-down-row window the design warns about never
/// opens here. The ScrollView placement is kept because it is correct on first
/// principles and matches `ChatView` and `ComposerView` — not because this test
/// caught the alternative. Do not read it as that guard.
final class CommandCenterStopConfirmationUITests: XCTestCase {

    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = true
        app = XCUIApplication()
        app.launchArguments += [
            "-hermesScreenshotRoute", "commandcenter-live",
            "-hermesDemoLiveSessions",
        ]
        app.launch()
    }

    override func tearDown() { app = nil }

    private var interruptButton: XCUIElement {
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Interrupt '")).firstMatch
    }
    private var alert: XCUIElement { app.alerts["Stop another client's work?"] }

    func testInterruptingAnUnattendedRowAsksFirstAndCancelDismisses() {
        XCTAssertTrue(
            interruptButton.waitForExistence(timeout: 40),
            "the Command Center never drew an Interrupt row — the fixture did not seed"
        )
        // The accessibility label names the row, which is the other half of what
        // the bare control lacked: it read only "Interrupt" to VoiceOver.
        XCTAssertTrue(
            interruptButton.label.contains("Nightly digest")
                || interruptButton.label.contains("Refactor the connect machine"),
            "the Interrupt control must name the session it would stop — got \(interruptButton.label)"
        )

        interruptButton.tap()

        XCTAssertTrue(
            alert.waitForExistence(timeout: 10),
            "the confirmation never appeared. A bare tap on this row kills another client's turn with no way back, and the alert is the only thing standing between a thumb and that — a presentation attached inside the LazyVStack row would fail exactly this way, silently."
        )
        XCTAssertTrue(
            alert.staticTexts["This was started somewhere else — a desktop client or a scheduled run. Stopping it here stops it there too."].exists,
            "the shared copy must be the copy that appears"
        )

        alert.buttons["Cancel"].tap()
        XCTAssertTrue(
            alert.waitForNonExistence(timeout: 10),
            "Cancel did not dismiss the confirmation"
        )
        XCTAssertTrue(
            interruptButton.waitForExistence(timeout: 10),
            "the row should still be there after a cancelled stop"
        )
    }
}
