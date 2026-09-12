import Foundation
import XCTest

@testable import HermesMobile

/// **BUG-016 — the transcript goes blank and the reader loses the tail.**
///
/// The report's own summary of what is wrong is one sentence: *"the sentinel is
/// not realized, and no message row is realized either"* — the viewport is
/// sitting outside the region the `LazyVStack` has actually materialised, and
/// nothing in the app ever puts it back. Three separate mechanisms keep it
/// there. The container resizes (keyboard, composer growth, activity strip,
/// notice, banner, rotation) and no scroll trigger fires, because the
/// transcript's only three triggers are content triggers. The bottom sentinel is
/// both the alarm and the fuse, so the flag that would notice can never be set
/// again. And the one manual escape aims a single unverified `scrollTo` at an id
/// inside the lazy stack, resolved against the same estimate that is already
/// wrong.
///
/// The fix is pure judgement wired into the view, and this file is the
/// judgement. `TailLatch` answers "was the reader at the tail before the ground
/// moved" without racing the layout that moved it. `ContainerHeight` answers "is
/// this height news, and has it stopped moving". `Placement.restart` /
/// `forceRestart` answer "the ladder may run again" and "a person is asking, so
/// it runs whatever it was doing". `settleOwed` answers "the ladder is finished,
/// so do the thing a finger drag does".
///
/// Half of the cases below exist because of a review of the first fix and are
/// marked. Each of those is a way that first version was worse
/// than `main` for some reader, and the tests are written so that reverting the
/// fix turns them red rather than merely uncovered.
///
/// **What no test here can do.** None of this asserts a scroll offset — the
/// existing `TranscriptScrollTests` says so in its own header and it is still
/// true. The offset oracle is `HermesUITests/TranscriptTailRetentionUITests`,
/// which reads the app's own published answer (the "Scroll to latest" button
/// renders iff the reader is off the tail), and above that, the phone.
final class TranscriptTailRetentionTests: XCTestCase {

    // MARK: Readings

    /// A reading from a scroll view that was found and answered.
    private func reading(
        touching: Bool = false,
        moved: Bool = false,
        atBottom: Bool = false
    ) -> TranscriptScrollReading {
        TranscriptScrollReading(isTouching: touching, movedOffset: moved, isAtBottom: atBottom)
    }

    /// The scroll view was never found. Says nothing.
    private var unavailable: TranscriptScrollReading { .unavailable }

    // MARK: - TailLatch: was the reader at the tail before the ground moved?

    /// The ordinary case and the one the whole fix turns on. A reader sitting at
    /// the tail raises the keyboard: the sentinel leaves the viewport with no
    /// finger anywhere near the transcript, and the answer to "were they at the
    /// tail" must still be yes, or nothing re-places them.
    func testAGeometryDrivenDepartureStillCountsAsHavingBeenAtTheTail() {
        var latch = TranscriptScroll.TailLatch()
        latch.record(isNearBottom: true, reading: reading())

        // The keyboard rises. The sentinel is gone; no finger did it, and the
        // offset is no longer at the bottom because the container shrank.
        latch.record(isNearBottom: false, reading: reading())

        XCTAssertTrue(
            latch.wasAtTail(isNearBottom: false, reading: reading()),
            "a layout pass moved the reader, so the reader was at the tail and must be put back"
        )
        XCTAssertFalse(latch.leftByHand)
    }

    /// The rule that keeps the fix from being a worse bug than the one it fixes,
    /// quoted from the report: *a reader who scrolled up and then typed must NOT
    /// be yanked.* The departure moved the offset, so every later geometry
    /// change — the keyboard, the composer growing line by line, an activity
    /// strip arriving — leaves them exactly where they put themselves.
    func testAReaderWhoScrolledBackIsNotTreatedAsHavingBeenAtTheTail() {
        var latch = TranscriptScroll.TailLatch()
        latch.record(isNearBottom: true, reading: reading())

        latch.record(isNearBottom: false, reading: reading(moved: true))
        XCTAssertTrue(latch.leftByHand)

        // Now they tap the composer and type until it wraps. Neither is theirs
        // to be undone by.
        XCTAssertFalse(latch.wasAtTail(isNearBottom: false, reading: reading()))
        XCTAssertFalse(latch.wasAtTail(isNearBottom: false, reading: reading()))
    }

    /// And it is a fact, not a window. The flag has no timer in it precisely so
    /// that asking a second later and a minute later give the same answer — a
    /// time-bounded version of this would silently start yanking scrollback
    /// readers as soon as they paused between gestures.
    func testTheByHandDepartureDoesNotExpire() {
        var latch = TranscriptScroll.TailLatch()
        latch.record(isNearBottom: false, reading: reading(moved: true))
        for _ in 0..<1_000 {
            XCTAssertFalse(latch.wasAtTail(isNearBottom: false, reading: reading()))
        }
    }

    /// Coming back to the tail clears it, however they got there — by dragging
    /// down, by tapping "Scroll to latest", or by a re-placement.
    func testReturningToTheTailRearmsTheRetention() {
        var latch = TranscriptScroll.TailLatch()
        latch.record(isNearBottom: false, reading: reading(moved: true))
        XCTAssertTrue(latch.leftByHand)

        latch.record(isNearBottom: true, reading: reading())
        XCTAssertFalse(latch.leftByHand)
        XCTAssertTrue(latch.wasAtTail(isNearBottom: true, reading: reading()))
    }

    /// A finger on the transcript right now outranks everything. A placement
    /// issued into a live drag fights the reader for the content offset and
    /// loses to it anyway — that is BUG-051's measured mechanism — so the
    /// honest answer while they are scrolling is "leave it alone".
    func testAFingerOnTheTranscriptAlwaysDeclines() {
        var latch = TranscriptScroll.TailLatch()
        latch.record(isNearBottom: true, reading: reading())
        XCTAssertFalse(
            latch.wasAtTail(isNearBottom: true, reading: reading(touching: true)),
            "the reader owns the offset while they are touching it"
        )
        XCTAssertFalse(latch.wasAtTail(isNearBottom: false, reading: reading(touching: true)))
    }

    /// A fresh transcript starts at the tail: `ChatView` initialises
    /// `isNearBottom` true and the initial placement lands there. So the very
    /// first resize a chat ever sees — the keyboard on a session opened and
    /// immediately typed into — is repaired without waiting for a sentinel
    /// callback to have happened first.
    func testAFreshLatchTreatsTheReaderAsBeingAtTheTail() {
        let latch = TranscriptScroll.TailLatch()
        XCTAssertFalse(latch.leftByHand)
        XCTAssertTrue(latch.wasAtTail(isNearBottom: false, reading: reading()))
    }

    /// The ordering hazard the latch exists to sidestep, run both ways round.
    /// The sentinel's `onDisappear` and the container's height preference land
    /// in the same SwiftUI update and nothing promises which arrives first, so
    /// the answer has to be the same whichever does.
    func testTheAnswerDoesNotDependOnWhetherTheSentinelReportedFirst() {
        var early = TranscriptScroll.TailLatch()
        early.record(isNearBottom: true, reading: reading())
        XCTAssertTrue(early.wasAtTail(isNearBottom: true, reading: reading()))

        var late = TranscriptScroll.TailLatch()
        late.record(isNearBottom: true, reading: reading())
        late.record(isNearBottom: false, reading: reading())
        XCTAssertTrue(late.wasAtTail(isNearBottom: false, reading: reading()))
    }

    // MARK: - TailLatch, the review's F3: a finger that moved nothing

    /// **Review F3.** BUG-016's first reproduction — the one the original report
    /// called 100% repeatable — is a long press on an assistant message to raise
    /// the copy menu, then a tap away to dismiss it. A long press holds
    /// `isTracking` true for a second and moves the content offset by nothing at
    /// all. The first version of this branch classified that as a deliberate
    /// departure, which would have excluded the reader from every repair that
    /// followed, on precisely the trigger acceptance rule 4 names.
    func testALongPressThatMovesNothingIsNotADeparture() {
        var latch = TranscriptScroll.TailLatch()
        latch.record(isNearBottom: true, reading: reading())

        // The context menu comes up; the sentinel leaves; the finger is down and
        // has moved nothing.
        latch.record(isNearBottom: false, reading: reading(touching: true, moved: false))

        XCTAssertFalse(latch.leftByHand, "a press that moved no offset did not leave the tail")
        XCTAssertTrue(latch.wasAtTail(isNearBottom: false, reading: reading()))
    }

    /// **Review F3, the repair half.** Classification can still go wrong — a
    /// long press that includes a stray point of drag, or a departure sampled a
    /// beat late. A measurement outranks a classification: if the content offset
    /// is at the bottom of the content, the reader is at the tail, and the flag
    /// is wrong and gets cleared.
    func testAMeasuredOffsetAtTheBottomRepairsAWronglyLatchedFlag() {
        var latch = TranscriptScroll.TailLatch()
        latch.record(isNearBottom: false, reading: reading(moved: true))
        XCTAssertTrue(latch.leftByHand)

        latch.observe(reading: reading(atBottom: true))
        XCTAssertFalse(latch.leftByHand, "the offset says they are at the tail; the flag was stale")
        XCTAssertTrue(latch.wasAtTail(isNearBottom: false, reading: reading()))
    }

    /// The repair only ever forgives. It must not be able to *set* the flag, or
    /// it would become a second, worse classifier running on a different clock.
    func testTheMeasuredRepairNeverSetsTheFlag() {
        var latch = TranscriptScroll.TailLatch()
        latch.observe(reading: reading(moved: true, atBottom: false))
        XCTAssertFalse(latch.leftByHand)
        latch.observe(reading: reading(touching: true))
        XCTAssertFalse(latch.leftByHand)
    }

    /// And a measured bottom outranks a standing classification at decision time
    /// too, not only through `observe`.
    func testAMeasuredBottomOutranksAStandingClassification() {
        var latch = TranscriptScroll.TailLatch()
        latch.record(isNearBottom: false, reading: reading(moved: true))
        XCTAssertTrue(latch.leftByHand)
        XCTAssertTrue(latch.wasAtTail(isNearBottom: false, reading: reading(atBottom: true)))
    }

    /// A press that moved nothing while the offset is *not* at the bottom — the
    /// reader long-pressing a message they scrolled back to — still leaves the
    /// earlier by-hand decision standing.
    func testAPressDoesNotLaunderAnEarlierDeliberateDeparture() {
        var latch = TranscriptScroll.TailLatch()
        latch.record(isNearBottom: false, reading: reading(moved: true))
        latch.record(isNearBottom: false, reading: reading(touching: true, moved: false))
        XCTAssertTrue(latch.leftByHand, "the drag that took them there has not been undone")
    }

    // MARK: - TailLatch, the review's F2: no scroll view, no licence

    /// **Review F2, and the worst defect the review found.** `scrollView` is a
    /// weak reference populated only by BUG-051's superview walk. When it is
    /// nil, "the reader is not driving" is not a measurement — it is silence.
    /// The first version read that silence as a measured no, so `leftByHand`
    /// could never latch, `wasAtTail` returned true forever, and every container
    /// resize re-placed every reader including one deliberately in scrollback.
    ///
    /// `main`'s behaviour with no scroll view is *no re-placement at all*. That
    /// is the degradation this must have, and it is what these two assert.
    func testAnUnavailableReadingIsNeverALicenceToReplace() {
        var latch = TranscriptScroll.TailLatch()
        latch.record(isNearBottom: true, reading: unavailable)
        latch.record(isNearBottom: false, reading: unavailable)

        XCTAssertTrue(latch.leftByHand, "nothing measured this departure, so it is not ours to undo")
        XCTAssertFalse(
            latch.wasAtTail(isNearBottom: false, reading: unavailable),
            "with no scroll view the honest answer is to leave the reader alone"
        )
    }

    /// The whole failing sequence, end to end, because the property that matters
    /// is not one call's answer but that a reader in scrollback is never yanked
    /// when the probe has failed.
    func testWithNoScrollViewNoResizeEverReplacesTheReader() {
        var latch = TranscriptScroll.TailLatch()
        latch.record(isNearBottom: true, reading: unavailable)
        latch.record(isNearBottom: false, reading: unavailable)

        for resize in 0..<50 {
            XCTAssertFalse(
                latch.wasAtTail(isNearBottom: false, reading: unavailable),
                "resize \(resize) re-placed a reader nothing had measured"
            )
        }
    }

    /// It still follows a reader who is demonstrably at the tail, because that
    /// answer needs no scroll view: the sentinel is on screen.
    func testAnUnavailableReadingStillFollowsAReaderAtTheTail() {
        var latch = TranscriptScroll.TailLatch()
        latch.record(isNearBottom: false, reading: unavailable)
        XCTAssertTrue(latch.wasAtTail(isNearBottom: true, reading: unavailable))
    }

    // MARK: - ContainerHeight: is this height news, and has it stopped moving?

    /// The first height a transcript ever reports is its resting size, not a
    /// resize. Placing on it would fight the initial placement ladder for the
    /// same frames.
    func testTheFirstHeightIsNotAResize() {
        var heights = TranscriptScroll.ContainerHeight()
        XCTAssertNil(heights.arm(height: 684, wasAtTail: true))
        XCTAssertEqual(heights.last, 684)
        XCTAssertNil(heights.pending)
    }

    /// The measured BUG-016 trigger: one tap on the composer, nothing typed, and
    /// the transcript's scroll view goes from 684 pt to 383 pt (three runs of
    /// three). That is the resize the transcript never had a
    /// trigger for.
    func testTheKeyboardRaiseEarnsAPlacement() {
        var heights = TranscriptScroll.ContainerHeight()
        _ = heights.arm(height: 684, wasAtTail: true)
        let token = heights.arm(height: 383, wasAtTail: true)
        XCTAssertNotNil(token, "684 -> 383 is the reproduction; it must earn a re-placement")
        XCTAssertEqual(heights.pending, token)
    }

    /// A height republished unchanged spends nothing. Preferences are recomputed
    /// for reasons that have nothing to do with this view, and a hook that acted
    /// on every republication would be a pump with no trigger at all.
    func testARepeatedHeightEarnsNothing() {
        var heights = TranscriptScroll.ContainerHeight()
        _ = heights.arm(height: 684, wasAtTail: true)
        XCTAssertNil(heights.arm(height: 684, wasAtTail: true))
        XCTAssertNil(heights.arm(height: 684.2, wasAtTail: true), "sub-point noise is not a resize")
        XCTAssertNil(heights.pending)
    }

    /// And a placement cannot cause the change that causes another placement: a
    /// scroll writes the content offset and never the scroll view's frame, so
    /// the height after a repair is the height before it, and that is the case
    /// above. This states the loop closure as its own test because it is the one
    /// property that makes the hook safe to have at all.
    func testAPlacementCannotFeedTheHookThatIssuedIt() {
        var heights = TranscriptScroll.ContainerHeight()
        _ = heights.arm(height: 684, wasAtTail: true)
        let token = heights.arm(height: 383, wasAtTail: true)
        XCTAssertNotNil(token)
        XCTAssertTrue(heights.fire(token: token!))

        // The repair happens. The container is still 383 pt tall.
        XCTAssertNil(heights.arm(height: 383, wasAtTail: true))
        XCTAssertNil(heights.pending)
    }

    /// One keyboard raise is one height change per frame of the raise animation.
    /// They must produce **one** placement, and it must be the last one — the
    /// same debounce rule BUG-050 established for the chrome, for the same
    /// reason: K placements resolve the lazy stack's estimate K times and land
    /// somewhere slightly different each time, which is a pump.
    func testABurstOfHeightsCoalescesIntoOnePlacement() {
        var heights = TranscriptScroll.ContainerHeight()
        _ = heights.arm(height: 684, wasAtTail: true)

        let frames: [CGFloat] = [640, 590, 520, 450, 383]
        var tokens: [Int] = []
        for height in frames {
            if let token = heights.arm(height: height, wasAtTail: true) { tokens.append(token) }
        }
        XCTAssertEqual(tokens.count, 5, "every frame of the animation is a real change")

        // Only the last hop does anything; the four before it were superseded.
        var fired = 0
        for token in tokens {
            if heights.fire(token: token) { fired += 1 }
        }
        XCTAssertEqual(fired, 1, "five height changes inside one animation must produce ONE placement")
        XCTAssertNil(heights.pending)
    }

    /// A hop that already fired never fires twice.
    func testAFiredTokenIsSpent() {
        var heights = TranscriptScroll.ContainerHeight()
        _ = heights.arm(height: 684, wasAtTail: true)
        let token = heights.arm(height: 383, wasAtTail: true)!
        XCTAssertTrue(heights.fire(token: token))
        XCTAssertFalse(heights.fire(token: token))
    }

    /// A resize found off the tail records the new height — so the *next* change
    /// is measured against reality — and schedules nothing.
    func testAResizeOffTheTailRecordsTheHeightAndSchedulesNothing() {
        var heights = TranscriptScroll.ContainerHeight()
        _ = heights.arm(height: 684, wasAtTail: true)
        XCTAssertNil(heights.arm(height: 383, wasAtTail: false))
        XCTAssertEqual(heights.last, 383, "the height still moved, whoever was watching")
        XCTAssertNil(heights.pending)
    }

    /// But it does not *cancel* a pending one. The resize this hook exists to
    /// repair is precisely what clears the tail flag, so a later frame of the
    /// same animation reading "off the tail" must not be allowed to disarm the
    /// repair the first frame armed. `ChromeReassert` draws the same line.
    func testAnOffTailReportDoesNotDisarmARepairAlreadyArmed() {
        var heights = TranscriptScroll.ContainerHeight()
        _ = heights.arm(height: 684, wasAtTail: true)
        let token = heights.arm(height: 500, wasAtTail: true)!
        XCTAssertNil(heights.arm(height: 383, wasAtTail: false))
        XCTAssertTrue(heights.fire(token: token), "the repair survives a frame that read off-tail")
    }

    /// A zero height is a view on its way out of the hierarchy. Acting on it
    /// would place against nothing, and *recording* it would make the next real
    /// height look like a 684 pt resize.
    func testAZeroHeightIsIgnoredEntirely() {
        var heights = TranscriptScroll.ContainerHeight()
        _ = heights.arm(height: 684, wasAtTail: true)
        XCTAssertNil(heights.arm(height: 0, wasAtTail: true))
        XCTAssertEqual(heights.last, 684, "a degenerate report must not become the baseline")
        XCTAssertNil(heights.arm(height: 684, wasAtTail: true), "so the real height is still not news")
    }

    // MARK: - The review's F4: two drivers, one placement per change

    /// **Review F4.** A notice, an error, a blocking prompt or an activity-strip
    /// line arriving changes `bottomChrome` *and* shortens the transcript, so
    /// both drivers see one event. `reassertTailAcrossChrome` is BUG-050's
    /// coalescer and is already correct for that case — it reads the near-bottom
    /// flag synchronously, before the layout that clears it. Letting the height
    /// hook fire as well turns the one placement BUG-050 engineered into two
    /// drivers and up to six scrolls, on a scroll view whose whole problem is
    /// that resolving its estimate repeatedly lands somewhere different each
    /// time.
    func testTheHeightHookStandsDownWhileTheChromeCoalescerIsArmed() {
        XCTAssertFalse(
            TranscriptScroll.heightHookShouldPlace(wasAtTail: true, chromeReassertPending: true),
            "one change, one placement — and the chrome path owns this one"
        )
    }

    /// The four events that are not chrome at all — the keyboard, the composer's
    /// own growth, the connection banner, rotation — leave the chrome coalescer
    /// idle, and they are the whole reason this hook exists.
    func testTheHeightHookPlacesWhenNoChromeChangeIsPending() {
        XCTAssertTrue(
            TranscriptScroll.heightHookShouldPlace(wasAtTail: true, chromeReassertPending: false)
        )
    }

    /// And standing down never becomes a way to place a reader who was not at
    /// the tail.
    func testTheHeightHookStillDeclinesOffTheTail() {
        XCTAssertFalse(
            TranscriptScroll.heightHookShouldPlace(wasAtTail: false, chromeReassertPending: false)
        )
        XCTAssertFalse(
            TranscriptScroll.heightHookShouldPlace(wasAtTail: false, chromeReassertPending: true)
        )
    }

    // MARK: - Placement.restart: the ladder may run again

    /// The height hook's restart. It re-opens the bounded ladder, which is the
    /// machinery that already existed for exactly this problem and was wired
    /// only to the cold open.
    func testRestartingReopensTheLadderForAPlacedChat() {
        var placement = placedLadder(for: "chat-a")
        XCTAssertEqual(placement.placedChat, "chat-a")

        placement.restart(chat: "chat-a")
        XCTAssertNil(placement.placedChat)
        XCTAssertEqual(placement.attempts, 0, "the re-opened ladder gets its whole budget")
        XCTAssertEqual(
            placement.decide(chat: "chat-a", isNonEmpty: true, isNearBottom: false),
            .initialPlacement,
            "and it ignores the P14 guard, which the geometry change is what falsified"
        )
    }

    /// The guard that keeps a keyboard raise during a cold open from resetting
    /// that open's own placement to attempt zero halfway through. A ladder in
    /// flight is already doing this job.
    func testRestartingIsANoOpWhileALadderIsStillRunning() {
        var placement = TranscriptScroll.Placement<String>()
        XCTAssertEqual(
            placement.decide(chat: "chat-a", isNonEmpty: true, isNearBottom: false),
            .initialPlacement
        )
        XCTAssertEqual(placement.attempts, 1)

        placement.restart(chat: "chat-a")
        XCTAssertEqual(placement.attempts, 1, "the in-flight ladder is untouched")

        XCTAssertEqual(
            placement.decide(chat: "chat-a", isNonEmpty: true, isNearBottom: false, afterLayout: true),
            .initialPlacement,
            "and it continues from where it was rather than starting over"
        )
        XCTAssertEqual(placement.attempts, 2)
    }

    /// Restarting a chat this view has never placed does nothing either — the
    /// key is what makes that safe, the same way it is what stops chat A's latch
    /// counting as chat B's.
    func testRestartingAnotherChatDoesNothing() {
        var placement = placedLadder(for: "chat-a")
        placement.restart(chat: "chat-b")
        XCTAssertEqual(placement.placedChat, "chat-a")
    }

    // MARK: - The review's F1: a tap is not a layout event

    /// **Review F1, and the regression this pins.** Standing down for an
    /// in-flight ladder is right for the height hook and wrong for a person.
    /// While a ladder is running `placedChat` is nil, so `restart` does nothing;
    /// `decide` then finds an unjudged attempt outstanding and returns `.none`,
    /// and the ↓ tap does **nothing at all**. That window is the ~400 ms after
    /// every chat open and after every debounced resize — exactly when a reader
    /// reaches for the button, because the resize is what made them reach for
    /// it. This is that state, and the assertion is the defect.
    func testTheButtonMustNotBeANoOpInsideTheLadderWindow() {
        var placement = TranscriptScroll.Placement<String>()
        _ = placement.decide(chat: "chat-a", isNonEmpty: true, isNearBottom: false)

        // What the height hook's restart does here, and why it is not enough.
        var viaRestart = placement
        viaRestart.restart(chat: "chat-a")
        XCTAssertEqual(
            viaRestart.decide(chat: "chat-a", isNonEmpty: true, isNearBottom: false),
            TranscriptScroll.Action.none,
            "precondition: this is the no-op the review found"
        )

        // What the button does.
        var viaForce = placement
        viaForce.forceRestart(chat: "chat-a")
        XCTAssertEqual(
            viaForce.decide(chat: "chat-a", isNonEmpty: true, isNearBottom: false),
            .initialPlacement,
            "a tap moves the transcript in the frame it happened in, whatever the ladder was doing"
        )
    }

    /// The same guarantee from every state the button can be tapped in — mid
    /// ladder, after a ladder settled, after a ladder gave up, and on a chat
    /// the view has only just been re-bound to.
    func testTheButtonAlwaysProducesAPlacementFromAnyLadderState() {
        var midLadder = TranscriptScroll.Placement<String>()
        _ = midLadder.decide(chat: "chat-a", isNonEmpty: true, isNearBottom: false)

        let states: [(String, TranscriptScroll.Placement<String>)] = [
            ("mid-ladder", midLadder),
            ("settled", placedLadder(for: "chat-a")),
            ("exhausted", exhaustedLadder(for: "chat-a")),
            ("fresh", TranscriptScroll.Placement<String>()),
        ]
        for (name, state) in states {
            var placement = state
            placement.forceRestart(chat: "chat-a")
            XCTAssertEqual(
                placement.decide(chat: "chat-a", isNonEmpty: true, isNearBottom: false),
                .initialPlacement,
                "the button did nothing from the \(name) state"
            )
        }
    }

    /// And the tap re-opens the whole budget, so what follows it is the verified
    /// ladder rather than one unchecked shot at an id inside a lazy stack.
    func testTheButtonReopensTheWholeLadderBudget() {
        var placement = exhaustedLadder(for: "chat-a")
        placement.forceRestart(chat: "chat-a")
        XCTAssertEqual(placement.attempts, 0)
        XCTAssertNil(placement.placedChat)
        XCTAssertFalse(placement.settleOwed, "a fresh ladder has not finished, so it owes nothing yet")
    }

    // MARK: - The review's F6: the settle is not the ceiling's consolation prize

    /// Review F6, and the white-canvas case. `took` latches on
    /// `attempts >= minAttempts && isNearBottom`, and `minAttempts` is 2 — so a
    /// single momentary sentinel reading roughly 160 ms into a cold open closes
    /// the ladder for good. If the layout that follows re-estimates and takes
    /// the sentinel away again, the chat is latched, the ceiling is never
    /// reached, no container height changed so direction C never fires, and
    /// every later decision returns `.none`. The first version of this branch
    /// reached the offset settle only through the ceiling, so that path had no
    /// last resort at all.
    ///
    /// Raising `minAttempts` is not available — `TranscriptScrollTests` pins the
    /// two-rung settle and predates this work — so the settle is owed by every
    /// completed first placement instead.
    func testASuccessfulLadderStillOwesTheOffsetSettle() {
        var placement = TranscriptScroll.Placement<String>()
        _ = placement.decide(chat: "chat-a", isNonEmpty: true, isNearBottom: false)
        _ = placement.decide(chat: "chat-a", isNonEmpty: true, isNearBottom: false, afterLayout: true)
        XCTAssertFalse(placement.settleOwed, "nothing is owed while the ladder is still running")

        _ = placement.decide(chat: "chat-a", isNonEmpty: true, isNearBottom: true, afterLayout: true)
        XCTAssertTrue(
            placement.settleOwed,
            "the ladder believed it succeeded, and that belief is exactly what the white canvas is"
        )
    }

    /// The ceiling owes it too, which is the case the first version had.
    func testAnExhaustedLadderOwesTheOffsetSettle() {
        var placement = exhaustedLadder(for: "chat-a")
        XCTAssertTrue(placement.settleOwed)
    }

    /// One-shot. The flag is consumed by the caller, so a placement cannot be
    /// made to write the content offset twice.
    func testTheOffsetSettleIsOwedAtMostOncePerPlacement() {
        var placement = placedLadder(for: "chat-a")
        XCTAssertTrue(placement.takeSettleOwed())
        XCTAssertFalse(placement.takeSettleOwed())
        XCTAssertFalse(placement.settleOwed)
    }

    /// And it is not owed by the ordinary business of a live turn: a hundred
    /// streaming deltas on a placed chat must not reach into UIKit a hundred
    /// times.
    func testFollowingTheStreamNeverOwesASettle() {
        var placement = placedLadder(for: "chat-a")
        _ = placement.takeSettleOwed()
        for delta in 0..<100 {
            _ = placement.decide(chat: "chat-a", isNonEmpty: true, isNearBottom: true)
            XCTAssertFalse(placement.settleOwed, "delta \(delta) asked for a UIKit offset write")
        }
    }

    /// A ladder re-opened by the ↓ button or by a resize ends the same way, so
    /// the escape hatch has the same last resort the cold open does.
    func testARestartedLadderAlsoEndsInASettle() {
        var placement = placedLadder(for: "chat-a")
        _ = placement.takeSettleOwed()
        placement.forceRestart(chat: "chat-a")

        _ = placement.decide(chat: "chat-a", isNonEmpty: true, isNearBottom: false)
        for _ in 0..<10 {
            _ = placement.decide(chat: "chat-a", isNonEmpty: true, isNearBottom: false, afterLayout: true)
        }
        XCTAssertTrue(placement.settleOwed)
        XCTAssertEqual(placement.attempts, TranscriptScroll.Placement<String>.maxAttempts)
    }

    /// P14 is not weakened by any of it: once the re-opened ladder settles, a
    /// reader who scrolls back during a live turn is left alone exactly as
    /// before. **What this does not establish** is the window *during* the
    /// re-opened ladder, in which `initialPlacement` ignores the guard by
    /// design; the review's F5 records that and it is stated in the report.
    func testP14StillGovernsAfterARestartedLadderSettles() {
        var placement = placedLadder(for: "chat-a")
        placement.restart(chat: "chat-a")
        _ = placement.decide(chat: "chat-a", isNonEmpty: true, isNearBottom: false)
        _ = placement.decide(chat: "chat-a", isNonEmpty: true, isNearBottom: false, afterLayout: true)
        XCTAssertEqual(
            placement.decide(chat: "chat-a", isNonEmpty: true, isNearBottom: true, afterLayout: true),
            .followTail
        )
        XCTAssertEqual(
            placement.decide(chat: "chat-a", isNonEmpty: true, isNearBottom: false),
            TranscriptScroll.Action.none,
            "scrollback is still never yanked"
        )
    }

    /// The ladder is still bounded, and the ceiling still latches — the two
    /// properties the pre-existing `TranscriptScrollTests` depends on.
    func testTheLadderIsStillBounded() {
        var placement = TranscriptScroll.Placement<String>()
        var rungs = 0
        if placement.decide(chat: "chat-a", isNonEmpty: true, isNearBottom: false) == .initialPlacement {
            rungs += 1
        }
        for _ in 0..<50 {
            let action = placement.decide(
                chat: "chat-a", isNonEmpty: true, isNearBottom: false, afterLayout: true
            )
            if action == .initialPlacement { rungs += 1 }
        }
        XCTAssertEqual(rungs, TranscriptScroll.Placement<String>.maxAttempts)
        XCTAssertEqual(placement.placedChat, "chat-a")
    }

    // MARK: - The UIKit half, without a UIScrollView

    /// The three phases that mean a finger — or its momentum — is on the
    /// transcript. All three veto a live re-placement.
    func testEveryPhaseOfATouchCountsAsAFingerOnTheTranscript() {
        XCTAssertTrue(TranscriptMomentum.isUserDriving(isTracking: true, isDragging: false, isDecelerating: false))
        XCTAssertTrue(TranscriptMomentum.isUserDriving(isTracking: true, isDragging: true, isDecelerating: false))
        XCTAssertTrue(TranscriptMomentum.isUserDriving(isTracking: false, isDragging: true, isDecelerating: false))
        XCTAssertTrue(TranscriptMomentum.isUserDriving(isTracking: false, isDragging: false, isDecelerating: true))
        XCTAssertFalse(TranscriptMomentum.isUserDriving(isTracking: false, isDragging: false, isDecelerating: false))
    }

    /// **Review F3, at the predicate.** Only two of those three mean the reader
    /// *moved* anything. `isTracking` alone is a finger resting on the
    /// transcript, which is what a long press is.
    func testOnlyADragOrItsCoastCountsAsMovingTheOffset() {
        XCTAssertFalse(TranscriptMomentum.movedOffset(isDragging: false, isDecelerating: false))
        XCTAssertTrue(TranscriptMomentum.movedOffset(isDragging: true, isDecelerating: false))
        XCTAssertTrue(TranscriptMomentum.movedOffset(isDragging: false, isDecelerating: true))
    }

    /// A long press, as the scroll view reports it: touching, moving nothing,
    /// still at the bottom.
    func testAReadingOfALongPressAtTheTail() {
        let press = TranscriptMomentum.reading(
            isTracking: true, isDragging: false, isDecelerating: false,
            contentOffsetY: 7_316, contentHeight: 8_000, viewportHeight: 684,
            topInset: 0, bottomInset: 0
        )
        XCTAssertTrue(press.isTouching, "a finger is on it, so nothing may fight for the offset")
        XCTAssertFalse(press.movedOffset, "and it has moved nothing, so it is not a departure")
        XCTAssertTrue(press.isAtBottom)
        XCTAssertTrue(press.isAvailable)
    }

    /// A drag that took the reader into the middle of the transcript.
    func testAReadingOfADragIntoScrollback() {
        let drag = TranscriptMomentum.reading(
            isTracking: true, isDragging: true, isDecelerating: false,
            contentOffsetY: 2_000, contentHeight: 8_000, viewportHeight: 684,
            topInset: 0, bottomInset: 0
        )
        XCTAssertTrue(drag.isTouching)
        XCTAssertTrue(drag.movedOffset)
        XCTAssertFalse(drag.isAtBottom)
    }

    /// The tolerance, because a scroll view placed at the bottom rests a
    /// sub-pixel fraction away from the computed value on a 3x screen.
    func testTheAtBottomTestHasAPointOfSlack() {
        func atBottom(offset: CGFloat) -> Bool {
            TranscriptMomentum.reading(
                isTracking: false, isDragging: false, isDecelerating: false,
                contentOffsetY: offset, contentHeight: 8_000, viewportHeight: 684,
                topInset: 0, bottomInset: 0
            ).isAtBottom
        }
        XCTAssertTrue(atBottom(offset: 7_316))
        XCTAssertTrue(atBottom(offset: 7_315.5), "half a point short is still the bottom")
        XCTAssertTrue(atBottom(offset: 7_400), "and past it is certainly the bottom")
        XCTAssertFalse(atBottom(offset: 7_300))
    }

    /// An unavailable reading is not a reading of anything, and says so.
    func testTheUnavailableReadingAnswersNothing() {
        let nothing = TranscriptScrollReading.unavailable
        XCTAssertFalse(nothing.isAvailable)
        XCTAssertFalse(nothing.isTouching)
        XCTAssertFalse(nothing.movedOffset)
        XCTAssertFalse(nothing.isAtBottom)
    }

    /// The bottom of a long transcript, with no insets: the content is taller
    /// than the viewport and the offset is the difference.
    func testTheBottomOffsetOfATranscriptTallerThanItsViewport() {
        XCTAssertEqual(
            TranscriptMomentum.bottomOffset(
                contentHeight: 8_000, viewportHeight: 684, topInset: 0, bottomInset: 0
            ),
            7_316
        )
    }

    /// The keyboard is a bottom content inset, and the bottom of the content is
    /// that much further down the offset axis. Getting this wrong by the inset
    /// would settle the transcript one keyboard-height short of the tail, which
    /// looks exactly like the bug.
    func testTheBottomInsetIsPartOfTheBottom() {
        XCTAssertEqual(
            TranscriptMomentum.bottomOffset(
                contentHeight: 8_000, viewportHeight: 383, topInset: 0, bottomInset: 233
            ),
            7_850
        )
    }

    /// A short transcript — the two-message chat the report insists must keep
    /// resting above the composer — has content shorter than its viewport, and
    /// its resting offset is the top of the inset range, not a negative scroll
    /// into nothing.
    func testAShortTranscriptRestsAtTheTopOfItsInsetRange() {
        XCTAssertEqual(
            TranscriptMomentum.bottomOffset(
                contentHeight: 200, viewportHeight: 684, topInset: 47, bottomInset: 0
            ),
            -47
        )
    }

    /// The exactly-full case, which is the boundary between the two above.
    func testContentExactlyFillingTheViewportRestsAtZero() {
        XCTAssertEqual(
            TranscriptMomentum.bottomOffset(
                contentHeight: 684, viewportHeight: 684, topInset: 0, bottomInset: 0
            ),
            0
        )
    }

    // MARK: - Helpers

    /// A ladder run to its settled state: two rungs, then the sentinel back on
    /// screen. The shape a chat is in by the time anything wants to restart it.
    private func placedLadder(for chat: String) -> TranscriptScroll.Placement<String> {
        var placement = TranscriptScroll.Placement<String>()
        _ = placement.decide(chat: chat, isNonEmpty: true, isNearBottom: false)
        _ = placement.decide(chat: chat, isNonEmpty: true, isNearBottom: false, afterLayout: true)
        _ = placement.decide(chat: chat, isNonEmpty: true, isNearBottom: true, afterLayout: true)
        return placement
    }

    /// A ladder that spent every rung with the sentinel never coming back — the
    /// white-canvas shape.
    private func exhaustedLadder(for chat: String) -> TranscriptScroll.Placement<String> {
        var placement = TranscriptScroll.Placement<String>()
        _ = placement.decide(chat: chat, isNonEmpty: true, isNearBottom: false)
        for _ in 0..<20 {
            _ = placement.decide(chat: chat, isNonEmpty: true, isNearBottom: false, afterLayout: true)
        }
        return placement
    }
}
