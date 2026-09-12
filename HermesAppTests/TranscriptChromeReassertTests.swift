import Foundation
import XCTest

@testable import HermesMobile

/// **BUG-050 — "after a mid-turn send the transcript oscillates, up and down at
/// a constant rate, like breathing."**
///
/// The one mechanism in `ChatView` that can drive a repeating scroll with no
/// finger on the screen is the chrome reassertion: the rows stacked between the
/// transcript and the composer resize the scroll view when they arrive or
/// leave, and the transcript puts a reader who was at the tail back on it. That
/// path had two defects, and these are both of them.
///
/// **1. It fired on transitions that change no height.** The activity strip is
/// one 44 pt line per populated group — 0 pt with neither, 44 with either, 88
/// with both, pinned by `SessionActivityStripLayoutTests`. The chrome value
/// tracked todos and subagents as two independent flags, so a turn that retires
/// its checklist in the same update a subagent appears in read as a change and
/// earned a scroll, while the transcript's height had not moved a point.
///
/// **2. Every firing issued two scrolls, and nothing coalesced them.** One
/// synchronously and one unconditionally 80 ms later, from an uncancelled
/// fire-and-forget `Task`. K transitions produced 2K placements, each resolving
/// the bottom anchor against a `LazyVStack`'s estimated content height, each
/// landing somewhere slightly different. That is a pump.
///
/// No test here can assert a scroll offset — the same honest limit
/// `TranscriptScrollTests` states. These are the rule, not the scrolling; the
/// oracle for the oscillation itself is a person holding the device, and the
/// instrumentation in `TranscriptScrollLog` is what that check reads.
final class TranscriptChromeReassertTests: XCTestCase {

    // MARK: 1 — which transitions actually resize the transcript

    /// **The over-fire, exactly.** The strip shows one 44 pt line whether the
    /// populated group is tasks or agents, so swapping which one it is changes
    /// the flags and changes no height. It must still register as a transition
    /// — instrumentation has to be able to see it — and it must not earn a
    /// scroll.
    func testSwappingTasksForAgentsIsATransitionThatChangesNoHeight() {
        let tasksOnly = TranscriptScroll.Chrome(hasTodos: true, hasAgents: false)
        let agentsOnly = TranscriptScroll.Chrome(hasTodos: false, hasAgents: true)

        XCTAssertNotEqual(tasksOnly, agentsOnly, "the flags differ; the transition is real")
        XCTAssertEqual(tasksOnly.stripGroups, agentsOnly.stripGroups,
                       "one populated group either way — 44 pt either way")
        XCTAssertFalse(
            TranscriptScroll.Chrome.changesHeight(from: tasksOnly, to: agentsOnly),
            "a strip that stays at one line moved nothing; scrolling for it is the pump BUG-050 reports"
        )
    }

    /// The other half of the same rule: a *second* group really is 44 pt more.
    func testGainingASecondStripGroupChangesHeight() {
        XCTAssertTrue(TranscriptScroll.Chrome.changesHeight(
            from: TranscriptScroll.Chrome(hasTodos: true),
            to: TranscriptScroll.Chrome(hasTodos: true, hasAgents: true)
        ))
    }

    /// …and the strip arriving at all.
    func testTheStripArrivingChangesHeight() {
        XCTAssertTrue(TranscriptScroll.Chrome.changesHeight(
            from: TranscriptScroll.Chrome(),
            to: TranscriptScroll.Chrome(hasTodos: true)
        ))
    }

    /// The three rows that are not the strip are each their own height and each
    /// one's arrival or departure is a resize.
    func testNoticeErrorAndPromptEachChangeHeight() {
        let none = TranscriptScroll.Chrome()
        XCTAssertTrue(TranscriptScroll.Chrome.changesHeight(
            from: none, to: TranscriptScroll.Chrome(hasNotice: true)))
        XCTAssertTrue(TranscriptScroll.Chrome.changesHeight(
            from: TranscriptScroll.Chrome(hasError: true), to: none))
        XCTAssertTrue(TranscriptScroll.Chrome.changesHeight(
            from: none, to: TranscriptScroll.Chrome(hasBlockingPrompt: true)))
    }

    /// A notice being replaced by an error is two flags moving and two
    /// different rows — a real resize, not a swap.
    func testTradingANoticeForAnErrorChangesHeight() {
        XCTAssertTrue(TranscriptScroll.Chrome.changesHeight(
            from: TranscriptScroll.Chrome(hasNotice: true),
            to: TranscriptScroll.Chrome(hasError: true)
        ))
    }

    /// The degenerate case, stated so nobody has to wonder.
    func testNoTransitionChangesNoHeight() {
        let chrome = TranscriptScroll.Chrome(hasTodos: true, hasNotice: true)
        XCTAssertFalse(TranscriptScroll.Chrome.changesHeight(from: chrome, to: chrome))
    }

    // MARK: 2 — one scroll per burst

    /// One transition earns one scroll, and the token cannot be spent twice.
    func testOneTransitionEarnsExactlyOneScroll() {
        var reassert = TranscriptScroll.ChromeReassert()
        guard let token = reassert.arm(isNearBottom: true) else {
            return XCTFail("a reader at the tail must get a scheduled reassertion")
        }
        XCTAssertTrue(reassert.fire(token: token))
        XCTAssertFalse(reassert.fire(token: token), "one transition, one scroll — never two")
        XCTAssertNil(reassert.pending, "nothing is left armed after it fires")
    }

    /// **The coalescing.** A chrome that flaps three times in one settle window
    /// earns one scroll, not three and not six.
    func testABurstOfTransitionsCollapsesIntoOneScroll() {
        var reassert = TranscriptScroll.ChromeReassert()
        let tokens = (0..<3).compactMap { _ in reassert.arm(isNearBottom: true) }
        XCTAssertEqual(tokens.count, 3, "every transition arms; only the last one fires")

        let fired = tokens.filter { reassert.fire(token: $0) }
        XCTAssertEqual(fired.count, 1, "three transitions inside one window must produce ONE scroll")
        XCTAssertEqual(fired.first, tokens.last, "and it is the last transition's, not the first's")
    }

    /// P14, unchanged: a reader who scrolled back is never yanked down.
    func testATransitionAwayFromTheTailSchedulesNothing() {
        var reassert = TranscriptScroll.ChromeReassert()
        XCTAssertNil(reassert.arm(isNearBottom: false))
        XCTAssertNil(reassert.pending)
    }

    /// And the resize this exists to repair must not be able to disarm its own
    /// repair: the transition that hides the sentinel arrives *after* the one
    /// that armed, and finding the flag false then must not cancel.
    func testAnArmOffTheTailDoesNotCancelOnePendingFromTheTail() {
        var reassert = TranscriptScroll.ChromeReassert()
        guard let token = reassert.arm(isNearBottom: true) else {
            return XCTFail("the first transition must arm")
        }
        XCTAssertNil(reassert.arm(isNearBottom: false))
        XCTAssertTrue(reassert.fire(token: token), "the decision was made at the tail; it stands")
    }
}
