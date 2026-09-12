import XCTest

/// **BUG-016 — the transcript moves out from under the reader, and sometimes
/// takes every message with it.**
///
/// This is the fixture that reproduced the defect
/// three runs out of three on an unmodified tree, landed against the fix it was
/// written to measure. Test 3 of that fixture shipped alone as
/// `TranscriptTailRecoveryUITests`; the rest pin the defect itself and are here.
///
/// **The oracle is tail retention, not blankness, and the app publishes it.**
/// "Scroll to latest" renders under `if !isNearBottom`, and `isNearBottom`'s
/// only writers are the bottom sentinel's realisation callbacks. Button absent
/// means the sentinel is on screen means the reader is at the tail. One query
/// against one button — no element enumeration, which is not a style
/// preference: `app.staticTexts.allElementsBoundByIndex` enumerates every key
/// label once the keyboard is up, and the committed
/// `TranscriptBlankingUITests` was red for that query timing out rather than
/// for the bug. Nothing in this file enumerates the tree at
/// all — see `survey` and `bottomMostRow`.
///
/// The invariant every test below asserts is the same one: **at the tail before
/// a pure geometry change, still at the tail after it.** No message arrives in
/// any of these, nothing streams, and no content changes at any point.
///
/// **What "still at the tail" means here, precisely**, because the first version
/// of this file overstated it. Direction C is a repair after the fact — an 80 ms
/// debounce and then a bounded ladder — so the transcript genuinely does move and
/// is genuinely put back, and a test that read the invariant once in the frame
/// the gesture ended would be asserting something the design does not promise.
/// The honest assertion, and the one `assertStillAtTail` makes, is: the reading
/// taken the instant the gesture ends is **recorded on every run** so a reviewer
/// can see whether the transcript held or was repaired; the repair then has a
/// tight budget rather than a generous one; and from there the reader must be at
/// the tail at **every** poll for a sustained hold, so a transcript that comes
/// back and wanders off again fails rather than being sampled at a lucky moment.
///
/// **Four of these tests can still pass having exercised nothing**, and they say
/// so on stdout when they do. Two of them need the keyboard to shrink the
/// transcript, which the canonical gate simulator does not do; two need a swipe
/// to clear the bottom sentinel. A green count from this file is not evidence on
/// its own — the `BUG016TAIL` lines have to travel with it.
///
/// The two things this cannot prove, both of which belong to a real device.
/// The simulator has only ever produced moved — off the tail with rows still
/// drawn — and never the fully white canvas reported from a device. And
/// BUG-016's off-tail precondition is per-simulator keyboard
/// state: on a simulator whose keyboard avoidance never engages, the transcript
/// does not shrink at all and these tests pass having exercised nothing. That
/// was measured at two different commits (a long-lived build
/// simulator vs a fresh
/// device of the same type and runtime, same build, opposite answers), so the
/// launch survey below prints the scroll view's frame on every run and a
/// reviewer should read it before believing a green.
final class TranscriptTailRetentionUITests: XCTestCase {

    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = true
        app = XCUIApplication()
    }

    override func tearDown() { app = nil }

    private func launch(route: String) {
        app.launchArguments += ["-hermesScreenshotRoute", route]
        app.launch()
    }

    // MARK: Reading the screen

    /// The fixture writes its index into every row, so a row can be named
    /// without knowing anything about the layout.
    private var rowQuery: XCUIElementQuery {
        app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'transcript row'"))
    }
    private var scrollToLatest: XCUIElement { app.buttons["Scroll to latest"] }
    private var composer: XCUIElement { app.textViews.firstMatch }

    /// The whole oracle.
    private var isAtTail: Bool { !scrollToLatest.exists }

    /// The cheap reading. Safe with the keyboard up — one button, one field.
    private func note(_ stage: String) {
        print("BUG016TAIL | \(stage) | atTail=\(isAtTail)"
              + " | composerH=\(composer.exists ? composer.frame.height : -1)")
    }

    /// The diagnostic reading. It asserts nothing and no test's verdict depends
    /// on it — it is the line a reviewer reads before believing a green.
    ///
    /// Counted and sampled, not walked. The previous form took
    /// `rowQuery.allElementsBoundByIndex` and then asked `isHittable` of every
    /// row it got back, which is one round trip into the app per row; at the
    /// ~3.2 s per query this screen costs since BUG-058 (215+ elements, one text
    /// view per line) nine survey calls are most of an hour of gate time for
    /// output nobody asserts on. The same facts are now read with a count, the
    /// two edge rows by index, and a hittability sample over the last eight —
    /// which is where these tests work, since the invariant is tail retention.
    /// `rowsHittable` therefore became `tailHittable`, an honest name for a
    /// sample rather than a total.
    private func survey(_ stage: String) {
        let rows = rowQuery
        let count = rows.count
        let sample = min(count, 8)
        let tailHittable = (0..<sample).filter { rows.element(boundBy: count - 1 - $0).isHittable }.count
        let first = count > 0 ? String(rows.element(boundBy: 0).label.prefix(28)) : "-"
        let last = count > 0 ? String(rows.element(boundBy: count - 1).label.prefix(28)) : "-"
        let scroll = app.scrollViews.firstMatch
        let scrollFrame = scroll.exists
            ? "\(Int(scroll.frame.width))x\(Int(scroll.frame.height))@\(Int(scroll.frame.minY))"
            : "-"
        print("BUG016TAIL | SURVEY \(stage) | atTail=\(isAtTail)"
              + " | rowsInTree=\(count) | tailHittable=\(tailHittable)/\(sample)"
              + " | firstRow=\(first)"
              + " | lastRow=\(last)"
              + " | composerH=\(composer.exists ? composer.frame.height : -1)"
              + " | scrollViews=\(app.scrollViews.count) first=\(scrollFrame)")
    }

    /// The bottom-most transcript row, searched upwards from the last one.
    ///
    /// Upwards because every test in this file works at the tail, so the first
    /// probe usually answers. When `hittableOnly` is set and the tail cannot
    /// answer, the search still runs to row zero, so "nil" keeps meaning *no
    /// row anywhere is on screen*; `hittableOnly: false` is the plain "any row
    /// in the tree at all" that the enumerating form's `?? rows.last` meant.
    private func bottomMostRow(hittableOnly: Bool) -> XCUIElement? {
        let rows = rowQuery
        let count = rows.count
        guard count > 0 else { return nil }
        guard hittableOnly else { return rows.element(boundBy: count - 1) }
        for index in stride(from: count - 1, through: 0, by: -1) {
            let row = rows.element(boundBy: index)
            if row.isHittable { return row }
        }
        return nil
    }

    private func attachScreenshot(_ name: String) {
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

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

    /// How long the repair is given. Direction C is a debounce (80 ms) plus a
    /// bounded ladder (five rungs at 80 ms), so the design budget is under half
    /// a second and this is four times it. It is deliberately **not** generous:
    /// the first version of this file allowed six, which meant a build where the
    /// transcript visibly blanked and snapped back after five seconds passed
    /// every test in it.
    private static let repairBudget: TimeInterval = 2

    /// And how long it then has to **stay** at the tail. This half is the
    /// invariant; the half above is only the latency.
    private static let holdSeconds: TimeInterval = 2

    @discardableResult
    private func settleAtTail(timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if isAtTail { return true }
            Thread.sleep(forTimeInterval: 0.25)
        }
        return isAtTail
    }

    /// **The invariant, in the two parts it actually has.**
    ///
    /// Direction C is a repair after the fact — the transcript really does move
    /// and really is put back — so "still at the tail" cannot honestly be read
    /// once, in the frame the gesture ended. But it also cannot be a six-second
    /// convergence check, which is what the first version of this file asserted
    /// and which a build that blanks for five seconds passes.
    ///
    /// So: the reading taken the instant the gesture ends is **recorded** on
    /// every run, whether or not it is the failing one, so a reviewer can see
    /// from the log whether the transcript held or was repaired. Then the repair
    /// gets a tight budget. Then — and this is the assertion the report's
    /// invariant actually names — the reader has to be at the tail at **every**
    /// poll for the whole hold, so a transcript that arrives, wobbles and leaves
    /// again fails here rather than being sampled at a lucky moment.
    private func assertStillAtTail(_ stage: String, file: StaticString = #filePath, line: UInt = #line) {
        let immediate = isAtTail
        let started = Date()
        let repaired = settleAtTail(timeout: Self.repairBudget)
        let took = Date().timeIntervalSince(started)
        print("BUG016TAIL | retention \(stage) | immediate=\(immediate)"
              + " | settled=\(repaired) after=\(String(format: "%.2f", took))s")

        guard repaired else {
            attachScreenshot("OFF-TAIL-\(stage)")
            XCTFail("""
                BUG-016 reproduced at "\(stage)". The reader was at the tail; a geometry change \
                with no content change put them somewhere else and left them there for \
                \(String(format: "%.1f", Self.repairBudget)) s, with "Scroll to latest" on screen. \
                The transcript moved under a reader who did not touch it.
                """, file: file, line: line)
            return
        }

        let holdUntil = Date().addingTimeInterval(Self.holdSeconds)
        while Date() < holdUntil {
            if !isAtTail {
                attachScreenshot("LOST-TAIL-\(stage)")
                XCTFail("""
                    BUG-016 at "\(stage)": the transcript came back and then left again. The \
                    reader was at the tail, was put back at the tail, and "Scroll to latest" \
                    returned within \(String(format: "%.1f", Self.holdSeconds)) s with nothing \
                    touching the screen. A repair that does not hold is not a repair.
                    """, file: file, line: line)
                return
            }
            Thread.sleep(forTimeInterval: 0.25)
        }
    }

    /// Take the reader off the tail with their own finger, and say so if the
    /// gesture did not manage it — a test whose precondition never arrived is
    /// not a pass of anything, and four of the six tests here could previously
    /// return success having exercised nothing but a `return`.
    private func scrollBackByHand(_ swipes: Int = 4) -> Bool {
        let transcript = app.scrollViews.firstMatch
        for _ in 0..<swipes { transcript.swipeDown() }
        Thread.sleep(forTimeInterval: 1.0)
        if isAtTail {
            print("BUG016TAIL | the swipes left the reader at the tail this run"
                  + " — this run proves nothing and is NOT evidence the guard holds")
            return false
        }
        note("scrolled back by hand")
        return true
    }

    // MARK: 1 — the minimal trigger

    /// Land at the tail of a long transcript and tap the composer. Nothing is
    /// typed, the composer does not grow, no message arrives: the only thing
    /// that changed is that the keyboard is up, and the transcript's scroll view
    /// went from 684 pt to 383 pt.
    ///
    /// Measured red three runs of three, and red again at two later commits.
    /// This is the smallest reproduction anybody has found — smaller than
    /// either reproduction the defect was filed with.
    func testRaisingTheKeyboardKeepsTheReaderAtTheTail() {
        launch(route: "transcript-long")
        waitForTranscript()
        survey("launch")
        XCTAssertTrue(isAtTail, "the fixture should land at the tail — nothing below this proves anything")

        focusComposer()
        note("keyboard raised, nothing typed")
        assertStillAtTail("keyboard raised, nothing typed")
        // The report's discriminator 5, in the only form the simulator can give
        // it. The question is whether the reported content size collapsed or
        // the offset went somewhere the content is not, and the survey answers
        // it without a flick: the scroll view's frame, how many rows the lazy
        // stack has actually realised, and which ones. The reading
        // on an unfixed tree was six rows realised (53 through 58) inside a
        // 402x383 scroll view with the tail row 59 gone — a realised window
        // that did not move up with its container, rather than a collapse.
        // Taken after the assertion, so a query that misbehaves here cannot
        // change what this test reports.
        survey("keyboard raised, nothing typed")
    }

    // MARK: 2 — the discriminator that has to stay green

    /// The same trigger on the six-row fixture, where nothing is unrealised.
    ///
    /// This one **passes today** and is the case fix direction A broke, which is
    /// why A was refuted rather than shipped: deleting
    /// `.defaultScrollAnchor(.bottom)` left the long transcript exactly as red
    /// and turned this from green to red, because the anchor is the only
    /// bottom-pinning mechanism in the view. Acceptance rule 3 is this test.
    func testRaisingTheKeyboardKeepsTheReaderAtTheTailOnAShortTranscript() {
        launch(route: "transcript")
        XCTAssertTrue(app.staticTexts.element(boundBy: 0).waitForExistence(timeout: 40),
                      "the short fixture never appeared")
        Thread.sleep(forTimeInterval: 2.0)
        survey("launch (short)")
        XCTAssertTrue(isAtTail, "the short fixture should land at the tail")

        focusComposer()
        note("keyboard raised on the short transcript")
        assertStillAtTail("keyboard raised on the short transcript")
    }

    // MARK: 3 — repro 2, line by line

    /// The second reproduction from the original report, hit again on a later
    /// build: type until the composer wraps, and the conversation disappears.
    ///
    /// The composer's growth shrinks the transcript by one line's worth at every
    /// wrap, so each line is its own geometry change and each one is its own
    /// question: at the tail, one line taller, still at the tail? The phone
    /// reported a *band* — blank from roughly line 2 through line 7 and back at
    /// line 8 — so a test that only looked at the end state would miss it
    /// entirely. Every line count is read.
    func testGrowingTheComposerLineByLineKeepsTheReaderAtTheTail() {
        launch(route: "transcript-long")
        waitForTranscript()
        survey("launch")
        XCTAssertTrue(isAtTail, "the fixture should land at the tail")
        focusComposer()

        var offTail: [String] = []
        var height = composer.frame.height
        print("BUG016TAIL | line 1 height \(height)")

        for line in 2...6 {
            guard let grown = grow(from: height) else {
                print("BUG016TAIL | composer stopped growing before line \(line) at \(height)")
                break
            }
            height = grown
            note("grew to line \(line) (h=\(height))")
            let immediate = isAtTail
            let settled = settleAtTail(timeout: Self.repairBudget)
            let held = settled && heldAtTail(for: Self.holdSeconds)
            print("BUG016TAIL | retention line \(line) | immediate=\(immediate)"
                  + " | settled=\(settled) | held=\(held)")
            if !held {
                offTail.append("line \(line)")
                attachScreenshot("OFF-TAIL-composer-line-\(line)")
            }
        }

        print("BUG016TAIL | off the tail at: \(offTail)")
        XCTAssertTrue(offTail.isEmpty, """
            BUG-016 reproduced. Growing the composer by one line took the reader off the tail at \
            these line counts: \(offTail). Nothing about the conversation changed at any of them.
            """)
    }

    // MARK: 4 — the rule the fix must not break

    /// A reader who scrolled back to re-read an answer and *then* tapped the
    /// composer must be left exactly where they put themselves.
    ///
    /// This is the failure mode direction C's own risk note names, and it is the
    /// one way a fix for this bug can be worse than the bug: a transcript that
    /// snaps to the bottom every time the keyboard moves is unusable for the
    /// thing people actually do, which is scroll up to read something and quote
    /// it back. The assertion is inverted here on purpose — "Scroll to latest"
    /// must **still be on screen** afterwards.
    func testAReaderWhoScrolledBackIsNotYankedByTheKeyboard() {
        launch(route: "transcript-long")
        waitForTranscript()
        survey("launch")
        XCTAssertTrue(isAtTail, "the fixture should land at the tail")

        guard scrollBackByHand() else { return }

        focusComposer()
        Thread.sleep(forTimeInterval: 3.0)
        note("keyboard raised after scrolling back")
        if isAtTail {
            attachScreenshot("YANKED-after-keyboard-raise")
            XCTFail("""
                the reader scrolled back deliberately and the keyboard raise pulled them to the \
                bottom. A fix for BUG-016 that yanks scrollback has replaced one unusable \
                transcript with another.
                """)
        }
    }

    /// The same rule against a resize that actually happens here.
    ///
    /// The test above was the branch's worst coverage gap, and the reason is
    /// measured: on the canonical gate
    /// simulator the keyboard does not shrink the transcript at all, so the
    /// only automated guard against yanking a reader out of scrollback was a
    /// no-op on the machine that runs the gate. Growing the composer does
    /// shrink it there — that is what the composer-growth test proves, red on
    /// the unfixed tree and green on the fix — so this is the same question
    /// asked with a geometry change the gate can see.
    ///
    /// Three findings of that review meet here and nowhere else: a departure
    /// classified from a stale reading, a scroll view the UIKit probe never
    /// found, and a re-opened ladder that ignores the near-bottom guard while it
    /// runs. Any of the three shows up as the reader being pulled to the bottom
    /// while they are reading something else.
    func testAReaderWhoScrolledBackIsNotYankedByTheComposerGrowing() {
        launch(route: "transcript-long")
        waitForTranscript()
        survey("launch")
        XCTAssertTrue(isAtTail, "the fixture should land at the tail")

        guard scrollBackByHand() else { return }
        focusComposer()

        var yanked: [String] = []
        var height = composer.frame.height
        for line in 2...4 {
            guard let grown = grow(from: height) else {
                print("BUG016TAIL | composer stopped growing before line \(line) at \(height)")
                break
            }
            height = grown
            Thread.sleep(forTimeInterval: 1.5)
            note("grew to line \(line) with the reader in scrollback")
            if isAtTail { yanked.append("line \(line)") }
        }

        print("BUG016TAIL | yanked out of scrollback at: \(yanked)")
        if !yanked.isEmpty { attachScreenshot("YANKED-by-composer-growth") }
        XCTAssertTrue(yanked.isEmpty, """
            the reader scrolled back deliberately and then typed, and the transcript pulled them \
            to the bottom at \(yanked). That is the failure mode the report calls out by name: a \
            fix for BUG-016 that yanks scrollback has replaced one unusable transcript with \
            another.
            """)
    }

    /// Repro 1 — the original report's first trigger, and the one nothing
    /// exercised in either direction.
    ///
    /// Long-press an assistant message to raise its copy menu, then tap away to
    /// dismiss it. This was reported as fully repeatable and acceptance rule
    /// 4 names it. It is also the gesture that broke the first version of this
    /// branch's tail latch: a long press holds `UIScrollView.isTracking` true
    /// for a second while moving the content offset by nothing at all, so
    /// classifying a touch as a departure would have latched the reader out of
    /// every repair that followed — on precisely this trigger.
    func testLongPressingAMessageAndTappingAwayKeepsTheReaderAtTheTail() {
        launch(route: "transcript-long")
        waitForTranscript()
        survey("launch")
        XCTAssertTrue(isAtTail, "the fixture should land at the tail")

        guard let target = bottomMostRow(hittableOnly: true) ?? bottomMostRow(hittableOnly: false) else {
            return XCTFail("no transcript row to long-press")
        }
        let pressed = String(target.label.prefix(28))

        target.press(forDuration: 1.2)
        Thread.sleep(forTimeInterval: 1.0)
        // The menu is a system surface; dismissing it is a tap outside it.
        app.tap()
        Thread.sleep(forTimeInterval: 1.0)
        note("long-pressed \(pressed), then tapped away")
        assertStillAtTail("long-press \(pressed), then tap away")
    }

    // MARK: 5 — first paint of a session that already has a history

    /// The P0 capture: a finished conversation opened as a white void
    /// with the ↓ button floating on it, and neither a drag nor a tap brought it
    /// back. Forty rows were on the backend and none of them were on screen.
    ///
    /// This route is that path's shape offline — the transcript is seeded into
    /// the `ChatModel` **before** `ChatView` is pushed, so `entries.count` and
    /// `entries.last?.text` never change and `.onAppear` is the only placement
    /// trigger that runs, which is exactly what the amendment identified. What it
    /// cannot reproduce is a REST transcript arriving after the push; that stays
    /// on the phone.
    ///
    /// Acceptance rule 1: the first paint must show real rows. A white canvas
    /// with ↓ is a fail even if a later gesture recovers it.
    func testOpeningASessionThatAlreadyHasAHistoryPaintsItsRows() {
        launch(route: "transcript-long")
        waitForTranscript()
        Thread.sleep(forTimeInterval: 2.0)
        survey("first paint")

        let rowsInTree = rowQuery.count
        let onScreen = bottomMostRow(hittableOnly: true)
        if rowsInTree == 0 || !isAtTail {
            attachScreenshot("BLANK-first-paint")
        }
        XCTAssertGreaterThan(rowsInTree, 0, """
            the transcript painted with no rows at all — this is the white canvas. \
            (Scroll to latest present: \(scrollToLatest.exists))
            """)
        XCTAssertNotNil(onScreen, "rows exist in the tree but none of them is on screen")
        XCTAssertTrue(isAtTail, """
            a session with a history opened somewhere other than its tail. The reader is looking \
            at the middle of a conversation they have already had.
            """)
    }

    // MARK: 6 — the escape hatch, from a state the reader can reach

    /// Acceptance rule 2, the ↓ half: whatever else is true, one tap must put
    /// the conversation back, and it must do it now.
    ///
    /// The 150 s main-thread wedge this used to produce was fixed
    /// by de-animating the tap, and `TranscriptTailRecoveryUITests` pins that
    /// from the keyboard-raised state. This is the other approach to the same
    /// button — off the tail by hand, keyboard down — and it asserts the tap is
    /// enough on its own, with a time bound, because a check on a device found
    /// the button working from an ordinary mid-transcript scroll and
    /// doing nothing at all from the blank state.
    func testScrollToLatestRestoresTheTailInOneTap() {
        launch(route: "transcript-long")
        waitForTranscript()
        survey("launch")

        guard scrollBackByHand(6) else { return }

        let started = Date()
        scrollToLatest.tap()
        let recovered = settleAtTail(timeout: 8)
        let elapsed = Date().timeIntervalSince(started)
        print("BUG016TAIL | recovery: recovered=\(recovered) seconds=\(String(format: "%.1f", elapsed))")

        if !recovered { attachScreenshot("NOT-RECOVERED-after-one-tap") }
        XCTAssertTrue(recovered, """
            one tap of "Scroll to latest" did not put the reader back at the tail within 8 s. \
            The escape hatch is the second half of what makes BUG-016 bad; it has to be \
            deterministic.
            """)
        XCTAssertLessThan(elapsed, 8, "the tap must not wedge the app — it once did for 150 s")
    }

    /// Did the reader stay at the tail at **every** poll for this long?
    private func heldAtTail(for seconds: TimeInterval) -> Bool {
        let until = Date().addingTimeInterval(seconds)
        while Date() < until {
            if !isAtTail { return false }
            Thread.sleep(forTimeInterval: 0.25)
        }
        return isAtTail
    }

    // MARK: Growing the composer

    /// Type filler until the field is one line taller, or give up. Returns the
    /// new height so the caller can measure the next line against it.
    private func grow(from height: CGFloat, filler: String = "wxyz ", budget: Int = 14) -> CGFloat? {
        for _ in 0..<budget {
            composer.typeText(filler)
            let now = composer.frame.height
            if now > height + 1 { return now }
        }
        return nil
    }
}
