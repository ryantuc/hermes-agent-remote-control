import XCTest

/// BUG-016's escape hatch, and only the escape hatch.
///
/// This is test 3 of the `TranscriptTailRetentionUITests` fixture,
/// landed on its own. The other three tests in that fixture pin the BUG-016
/// defect itself, which is not fixed and whose fix cannot be declared
/// complete on simulator evidence anyway — the exit requirement is keyed to the
/// fully-blank signature a device reports and the simulator has only ever
/// produced moved-not-blank. Landing them now would hold the suite red for a
/// defect nobody is fixing yet. This one is different: it is red
/// because of a separate, measured, one-line defect in the recovery path, and
/// it goes green when that line changes.
///
/// **The oracle is the tail-retention invariant, not blankness.** The committed
/// `TranscriptBlankingUITests` asserts "the recovery button is on screen while
/// zero transcript rows are hittable", and both halves of that are unsound:
/// `isHittable` is false for any element whose centre lies outside the viewport,
/// and one row of the `transcript-long` fixture — an eight-paragraph answer — is
/// taller than the transcript viewport once the keyboard is up, so a screen full
/// of readable text reports zero hittable rows. Here the app publishes the fact
/// itself: "Scroll to latest" renders under `if !isNearBottom`, and `isNearBottom`
/// is written only by the bottom sentinel's realisation callbacks. Button absent
/// means the sentinel is on screen means the reader is at the tail. One button
/// query, no element enumeration — which matters, because an expensive query
/// times out against a wedged main thread, which is exactly the state under test.
///
/// It is also distinct from `testScrollToLatestAlwaysRecoversTheTranscript`,
/// which recovers from a *swipe* with the keyboard down. The stall is specific
/// to the keyboard-raised state.
///
/// **THIS TEST NEEDS A FRESH SIMULATOR AND PASSES VACUOUSLY WITHOUT ONE.**
/// Measured at two separate commits: on a long-lived build
/// simulator (an iPhone 17 Pro) raising the keyboard does not move the
/// reader at all — the transcript scroll view stays `402x684@0` and the
/// composer is pushed to `@874`, below the 852 pt screen, so keyboard avoidance
/// never engages. On a simulator created fresh from the same device type and
/// runtime, the identical build gives `402x383@0` with the composer at `@539`
/// and the reader off the tail: the original readings byte for byte. The
/// difference is per-simulator keyboard state, not the tree — the same commit
/// gives both answers. Without the off-tail precondition this test's `guard`
/// returns early and it reports success having exercised nothing, which is why
/// that early return prints a line saying so. Create one with:
///
///     xcrun simctl create <name> ///       com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro ///       com.apple.CoreSimulator.SimRuntime.iOS-26-3
final class TranscriptTailRecoveryUITests: XCTestCase {

    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = true
        app = XCUIApplication()
    }

    override func tearDown() { app = nil }

    private var rowQuery: XCUIElementQuery {
        app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'transcript row'"))
    }
    private var scrollToLatest: XCUIElement { app.buttons["Scroll to latest"] }
    private var composer: XCUIElement { app.textViews.firstMatch }

    /// The whole oracle: the bottom sentinel is on screen, so the reader is at
    /// the tail.
    private var isAtTail: Bool { !scrollToLatest.exists }

    private func waitForTranscript(file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(rowQuery.firstMatch.waitForExistence(timeout: 40),
                      "the seeded transcript never appeared", file: file, line: line)
    }

    /// Tap the composer until the software keyboard is actually up. One tap is
    /// not reliable on a cold app: the first test of a run can tap while the
    /// transcript's first layout is still in flight and the tap is swallowed.
    @discardableResult
    private func focusComposer(file: StaticString = #filePath, line: UInt = #line) -> Bool {
        XCTAssertTrue(composer.waitForExistence(timeout: 30), "the composer field never appeared",
                      file: file, line: line)
        for _ in 1...4 {
            composer.tap()
            if app.keyboards.firstMatch.waitForExistence(timeout: 8) {
                Thread.sleep(forTimeInterval: 2.0)
                return true
            }
        }
        XCTFail("the software keyboard never came up", file: file, line: line)
        return false
    }

    /// Once the reader is off the tail, does the one manual escape work? One tap
    /// must be enough, and it must return within the test's patience — measured,
    /// the animated recovery wedged the main thread for over 150 s,
    /// three times on three runs.
    func testScrollToLatestRecoversFromTheKeyboardRaise() {
        app.launchArguments += ["-hermesScreenshotRoute", "transcript-long"]
        app.launch()
        waitForTranscript()
        XCTAssertTrue(isAtTail, "the fixture should land at the tail")

        focusComposer()
        guard !isAtTail else {
            // BUG-016 did not reproduce this run, so there is nothing to
            // recover from and this test has nothing to say. Not a pass of the
            // recovery path — a run where its precondition never arrived.
            print("BUG016TAIL | the keyboard left the reader at the tail this run — nothing to recover from")
            return
        }

        scrollToLatest.tap()
        Thread.sleep(forTimeInterval: 2.0)
        let recoveredInOne = isAtTail
        var taps = 1
        while !isAtTail && taps < 4 {
            scrollToLatest.tap()
            Thread.sleep(forTimeInterval: 1.5)
            taps += 1
        }
        print("BUG016TAIL | recovery: firstTapWorked=\(recoveredInOne) tapsNeeded=\(taps) recovered=\(isAtTail)")
        XCTAssertTrue(recoveredInOne, """
            the recovery button did not work on the first tap — it took \(taps) taps and \
            \(isAtTail ? "eventually reached" : "never reached") the tail. This is the second half \
            of what makes BUG-016 bad: the escape hatch is not deterministic.
            """)
    }
}
