import XCTest

/// **BUG-040 — the model selector goes under the keyboard when the draft is
/// long.** Reported from the phone: "typing 17 lines … pushes the bottom of the
/// composer underneath the keyboard such that model selections cannot be made".
///
/// **This is the only test in the project that measures against a real
/// keyboard.** Everything else about this defect is arithmetic — heights
/// modelled in a `UIWindow` with published figures standing in for the keyboard
/// — and arithmetic cannot tell you whether the keyboard is where you think it
/// is. `XCUIApplication` can: the keyboard is an element with a frame, the
/// model pill is an element with a frame, and BUG-040 is one inequality between
/// them.
///
/// It shares BUG-016's harness route (`transcript-long`), which seeds sixty
/// transcript rows and skips the network bootstrap entirely — no backend, no
/// profile, no sign-in — and adds `-hermesScreenshotDraft`, which fills the
/// draft without typing sixteen lines a keystroke at a time. The keyboard is
/// still raised by a real tap.
///
/// A separate file from `TranscriptBlankingUITests` on purpose: that one is
/// BUG-016's harness and belongs to whoever is still working on it.
final class ComposerReachabilityUITests: XCTestCase {

    private var app: XCUIApplication!

    /// Past any cap on any phone, in one launch argument — and deliberately
    /// **wrapped rather than newline-separated**, because the draft travels as
    /// a single `argv` entry and a wrapping paragraph asks nothing of how the
    /// harness handles embedded newlines. The cap is about laid-out lines
    /// either way (`GrowingComposerFieldTests.testWrappedTextCapsAtTheSameHeight`).
    private static let longDraft = String(
        repeating: "the quick brown fox jumps over the lazy dog. ", count: 24
    )

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments += [
            "-hermesScreenshotRoute", "transcript-long",
            "-hermesScreenshotDraft", Self.longDraft,
        ]
        app.launch()
    }

    override func tearDown() {
        app = nil
    }

    private var composerField: XCUIElement { app.textViews.firstMatch }

    /// The pill that opens the model drawer. Matched on its accessibility
    /// label, which `ComposerView` builds as "Model: <slug>".
    ///
    /// Deliberately not `app.buttons`: this harness route has no backend, and a
    /// pill with nothing to write to renders as a read-only value rather than a
    /// control (`ComposerPill.isInteractive`). Its *position* is the whole point
    /// here, and that does not depend on whether it is tappable today.
    private var modelPill: XCUIElement {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "label BEGINSWITH 'Model: '"))
            .firstMatch
    }

    /// The screen, and the line the keyboard's top edge draws across it.
    ///
    /// **Throws `XCTSkip` when there is no on-screen keyboard**, which is what a
    /// simulator with a hardware keyboard connected gives you: `app.keyboards`
    /// still matches an element, parked below the bottom of the screen, and
    /// every inequality against it is trivially true. A test that quietly passes
    /// in that state is worse than no test, so it says so instead.
    private func keyboardTop() throws -> CGFloat {
        let screen = app.windows.firstMatch.frame
        let keyboard = app.keyboards.firstMatch
        guard keyboard.waitForExistence(timeout: 10), keyboard.frame.minY < screen.maxY else {
            throw XCTSkip("""
                no on-screen keyboard: `app.keyboards` is at \(app.keyboards.firstMatch.frame) against \
                a \(screen) screen. The simulator has a hardware keyboard connected — turn it off \
                (Simulator ▸ I/O ▸ Keyboard ▸ Connect Hardware Keyboard) and this test measures the \
                real thing. Everything it would assert is trivially true without it
                """)
        }
        return keyboard.frame.minY
    }

    /// A field that has actually grown. Without this the harness can seed
    /// nothing, the composer sits at one line, and both tests below pass on a
    /// screen the defect cannot appear on.
    private func fullDraftField() -> XCUIElement {
        let field = composerField
        XCTAssertTrue(field.waitForExistence(timeout: 20), "the composer field never appeared")
        XCTAssertGreaterThan(field.frame.height, 60, """
            the composer is \(field.frame.height) pt — a line or two, so `-hermesScreenshotDraft` did \
            not reach it and nothing below this is about a long draft
            """)
        return field
    }

    /// **The reported failure, as an inequality.** With a full draft and the
    /// keyboard up, the model selector must be above the keyboard.
    func testTheModelSelectorStaysAboveTheKeyboardWithAFullDraft() throws {
        let field = fullDraftField()
        field.tap()
        let line = try keyboardTop()
        // Let the growth and the keyboard-driven relayout settle.
        Thread.sleep(forTimeInterval: 1.5)

        XCTAssertTrue(modelPill.waitForExistence(timeout: 5), "the model pill is not on the screen at all")
        let pill = modelPill.frame
        print("""
            [reachability] field \(field.frame) · model pill \(pill) · keyboard top \(line) \
            · screen \(app.windows.firstMatch.frame)
            """)

        XCTAssertLessThanOrEqual(pill.maxY, line, """
            the model selector ends at \(pill.maxY) and the keyboard starts at \(line) — it is behind \
            the keyboard, which is BUG-040 exactly: the user cannot change models without deleting \
            their draft
            """)
        XCTAssertTrue(pill.height > 0 && pill.width > 0, "the model selector has no area to tap")
    }

    /// The rest of the control row goes with it. Send is the other end of the
    /// same row, and a composer you cannot send from is worse than one you
    /// cannot change models in.
    func testSendStaysAboveTheKeyboardWithAFullDraft() throws {
        let field = fullDraftField()
        field.tap()
        let line = try keyboardTop()
        Thread.sleep(forTimeInterval: 1.5)

        let send = app.buttons["Send"]
        XCTAssertTrue(send.waitForExistence(timeout: 5), "no Send control on the screen")
        print("[reachability] send \(send.frame) · keyboard top \(line)")
        XCTAssertLessThanOrEqual(send.frame.maxY, line, """
            Send ends at \(send.frame.maxY) against a keyboard starting at \(line) (BUG-040)
            """)
        XCTAssertTrue(send.isHittable, "Send is not hittable with a full draft and the keyboard up")
    }
}
