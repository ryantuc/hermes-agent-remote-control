import Foundation
import HermesServeKit
import XCTest

@testable import HermesMobile

/// BUG-007 — "opening a session from Home lands at the top of the transcript".
///
/// `ChatView` appears before the REST transcript arrives, so its `.onAppear`
/// scroll fires against a one-row loading state and does nothing, and
/// `.defaultScrollAnchor(.bottom)` pins only that first empty layout. By the
/// time `applyTranscript` bulk-replaces `history`, the bottom sentinel is far
/// off-screen and has already set `isNearBottom = false` — so the P14 guard
/// reads the transcript's *arrival* as scrollback the reader chose, and
/// declines the one scroll that was needed.
///
/// The fix is a one-shot initial placement that ignores the guard, keyed to the
/// chat so a re-bound `ChatView` places again rather than inheriting the
/// previous chat's latch. `TranscriptScroll.action` is that rule; these tests
/// are the rule, not the scrolling. **No test here can assert a scroll offset**
/// — the real oracle for BUG-007 is a human looking at a phone.
final class TranscriptScrollTests: XCTestCase {

    // MARK: The initial placement ignores the P14 guard

    /// The bug exactly: entries have just arrived, the reader is nowhere near
    /// the bottom (the sentinel left the screen while the list was empty), and
    /// the transcript must still be placed at the tail.
    func testFirstNonEmptyLayoutPlacesEvenWhenTheGuardSaysNo() {
        XCTAssertEqual(
            TranscriptScroll.action(
                placedChat: String?.none,
                currentChat: "chat-a",
                isNonEmpty: true,
                isNearBottom: false
            ),
            .initialPlacement,
            "the transcript's first arrival must not be read as deliberate scrollback"
        )
    }

    /// The short-session case: the sentinel never left the screen, so the guard
    /// would have allowed it anyway — but this is still the placement, not a
    /// follow, so it lands rather than glides.
    func testFirstNonEmptyLayoutPlacesWhenAlreadyAtTheTail() {
        XCTAssertEqual(
            TranscriptScroll.action(
                placedChat: String?.none,
                currentChat: "chat-a",
                isNonEmpty: true,
                isNearBottom: true
            ),
            .initialPlacement
        )
    }

    // MARK: An empty transcript never jumps

    /// A brand-new chat with no stored session: empty stays empty, and no
    /// placement is recorded, so the first message it ever receives is what
    /// gets placed.
    func testEmptyTranscriptNeverScrolls() {
        XCTAssertEqual(
            TranscriptScroll.action(
                placedChat: String?.none,
                currentChat: "chat-new",
                isNonEmpty: false,
                isNearBottom: true
            ),
            TranscriptScroll.Action.none
        )
        XCTAssertEqual(
            TranscriptScroll.action(
                placedChat: String?.none,
                currentChat: "chat-new",
                isNonEmpty: false,
                isNearBottom: false
            ),
            TranscriptScroll.Action.none
        )
        XCTAssertEqual(
            TranscriptScroll.action(
                placedChat: "chat-new",
                currentChat: "chat-new",
                isNonEmpty: false,
                isNearBottom: true
            ),
            TranscriptScroll.Action.none
        )
    }

    // MARK: P14 survives the fix

    /// The whole reason the guard exists: once the transcript has been placed,
    /// a reader who scrolls back during a live turn is never yanked down.
    func testScrollbackIsStillNeverYankedAfterPlacement() {
        XCTAssertEqual(
            TranscriptScroll.action(
                placedChat: "chat-a",
                currentChat: "chat-a",
                isNonEmpty: true,
                isNearBottom: false
            ),
            TranscriptScroll.Action.none,
            "P14 must not be weakened by the initial-placement fix"
        )
    }

    /// And a reader sitting at the tail still follows the stream.
    func testTailIsStillFollowedAfterPlacement() {
        XCTAssertEqual(
            TranscriptScroll.action(
                placedChat: "chat-a",
                currentChat: "chat-a",
                isNonEmpty: true,
                isNearBottom: true
            ),
            .followTail
        )
    }

    // MARK: The flag is keyed to the chat, not to the view

    /// `ChatView` is a struct SwiftUI may re-bind to a different `ChatModel`
    /// while keeping the same `@State`. A placement latched for chat A must not
    /// count as chat B's placement, or the second session opened in that view
    /// lands at the top — BUG-007 again, with a harder repro.
    func testRebindingToADifferentChatPlacesAgain() {
        XCTAssertEqual(
            TranscriptScroll.action(
                placedChat: "chat-a",
                currentChat: "chat-b",
                isNonEmpty: true,
                isNearBottom: false
            ),
            .initialPlacement
        )
    }

    /// The key `ChatView` actually passes is `ObjectIdentifier(model)`, so what
    /// the test above assumes has to hold of the real objects: `AppModel` hands
    /// out one `ChatModel` per route, two routes are two distinct instances,
    /// and the same route is the same instance.
    @MainActor
    func testPlacementIsKeyedToTheChatModelTheViewIsBoundTo() async throws {
        let harness = await AppHarness.make()

        let chatA = harness.chat(storedID: "20260812_010101_aaaaaa", title: "A")
        let chatB = harness.chat(storedID: "20260812_020202_bbbbbb", title: "B")
        XCTAssertFalse(chatA === chatB, "precondition: two routes are two chats")

        let placed = ObjectIdentifier(chatA)

        // Still bound to A: the placement stands, so P14 governs.
        XCTAssertEqual(
            TranscriptScroll.action(
                placedChat: placed,
                currentChat: ObjectIdentifier(chatA),
                isNonEmpty: true,
                isNearBottom: false
            ),
            TranscriptScroll.Action.none
        )

        // Re-bound to B: A's latch does not carry over.
        XCTAssertEqual(
            TranscriptScroll.action(
                placedChat: placed,
                currentChat: ObjectIdentifier(chatB),
                isNonEmpty: true,
                isNearBottom: false
            ),
            .initialPlacement,
            "a ChatView re-bound to another chat must place that chat too"
        )

        await harness.tearDown()
    }

    // MARK: The latch records the OUTCOME, not the intention
    //
    // The rule above answers "what should happen now, given that this chat has
    // or has not been placed". `TranscriptScroll.Placement` answers the other
    // half — *when* a chat counts as placed — and that half cannot be a
    // decision, because the scroll it decides on is issued from inside the body
    // update the rows arrived in, before those rows are laid out. A
    // `proxy.scrollTo` there can simply fail to move the view, and a latch
    // recorded at that instant records an intention that never happened.

    /// The failure the placement fix could otherwise bake in: the first scroll
    /// missed, and asking again after the layout must produce **another
    /// attempt**, not `.none`. Latching on the decision would have marked the
    /// chat placed and left the transcript at the top forever.
    func testAMissedPlacementIsAttemptedAgainAfterLayout() {
        var placement = TranscriptScroll.Placement<String>()
        XCTAssertEqual(
            placement.decide(chat: "chat-a", isNonEmpty: true, isNearBottom: false),
            .initialPlacement
        )
        XCTAssertEqual(
            placement.decide(chat: "chat-a", isNonEmpty: true, isNearBottom: false, afterLayout: true),
            .initialPlacement,
            "the sentinel is still off screen, so the scroll did not place the view"
        )
    }

    /// And the first attempt may not settle on the guard alone. `isNearBottom`
    /// read that early describes the layout that came *before* the transcript
    /// arrived — while the content was one progress row, shorter than the
    /// viewport, so the sentinel was on screen and the flag `true` no matter
    /// where the scroll actually ended up. One attempt therefore always lands
    /// after a layout has happened.
    func testTheFirstAttemptCannotSettleOnAStaleGuardReading() {
        var placement = TranscriptScroll.Placement<String>()
        XCTAssertEqual(
            placement.decide(chat: "chat-a", isNonEmpty: true, isNearBottom: true),
            .initialPlacement
        )
        XCTAssertEqual(
            placement.decide(chat: "chat-a", isNonEmpty: true, isNearBottom: true, afterLayout: true),
            .initialPlacement,
            "a `true` this early is the old layout's reading, not evidence the scroll took"
        )
        XCTAssertNil(placement.placedChat, "nothing may be latched before an attempt is judged")
    }

    /// What "placement took" means: the bottom sentinel is back on screen when
    /// the outcome of an attempt is judged. From that moment the chat is
    /// latched and P14 governs every later delta.
    func testPlacementSettlesOnTheSentinelAndP14GovernsAfterwards() {
        var placement = TranscriptScroll.Placement<String>()
        _ = placement.decide(chat: "chat-a", isNonEmpty: true, isNearBottom: false)
        _ = placement.decide(chat: "chat-a", isNonEmpty: true, isNearBottom: false, afterLayout: true)

        XCTAssertEqual(
            placement.decide(chat: "chat-a", isNonEmpty: true, isNearBottom: true, afterLayout: true),
            .followTail,
            "the sentinel is on screen: the transcript is placed, and this is a follow now"
        )
        XCTAssertEqual(placement.placedChat, "chat-a")

        // P14, unweakened: the reader scrolls back mid-stream and is left alone.
        XCTAssertEqual(
            placement.decide(chat: "chat-a", isNonEmpty: true, isNearBottom: false),
            TranscriptScroll.Action.none
        )
        XCTAssertEqual(
            placement.decide(chat: "chat-a", isNonEmpty: true, isNearBottom: true),
            .followTail
        )
    }

    /// The retry is a ladder, not a loop. A transcript that refuses to report
    /// itself placed costs a fixed number of no-op scrolls and is then latched
    /// regardless — so it can neither spin nor keep fighting a reader who
    /// scrolls up the instant the chat opens.
    func testTheRetryLadderIsBounded() {
        var placement = TranscriptScroll.Placement<String>()
        var attempts = 0

        if placement.decide(chat: "chat-a", isNonEmpty: true, isNearBottom: false) == .initialPlacement {
            attempts += 1
        }
        for _ in 0..<50 {
            let action = placement.decide(
                chat: "chat-a",
                isNonEmpty: true,
                isNearBottom: false,
                afterLayout: true
            )
            if action == .initialPlacement { attempts += 1 }
        }

        XCTAssertEqual(attempts, TranscriptScroll.Placement<String>.maxAttempts)
        XCTAssertEqual(placement.attempts, TranscriptScroll.Placement<String>.maxAttempts)
        XCTAssertEqual(placement.placedChat, "chat-a", "the ceiling latches the chat rather than retrying forever")
        XCTAssertEqual(
            placement.decide(chat: "chat-a", isNonEmpty: true, isNearBottom: false),
            TranscriptScroll.Action.none,
            "and P14 governs once it gives up"
        )
    }

    /// One arrival fires both of `ChatView`'s `onChange` handlers — the entry
    /// count and the last entry's text change together. Those calls happen in
    /// the same update, before any layout, so a budget spent on them would be
    /// spent on scrolls that cannot be judged.
    func testASecondCallInTheSameFrameDoesNotSpendAnAttempt() {
        var placement = TranscriptScroll.Placement<String>()
        XCTAssertEqual(
            placement.decide(chat: "chat-a", isNonEmpty: true, isNearBottom: false),
            .initialPlacement
        )
        XCTAssertEqual(
            placement.decide(chat: "chat-a", isNonEmpty: true, isNearBottom: false),
            TranscriptScroll.Action.none,
            "the attempt already issued has not been judged yet"
        )
        XCTAssertEqual(placement.attempts, 1)
        XCTAssertEqual(
            placement.decide(chat: "chat-a", isNonEmpty: true, isNearBottom: false, afterLayout: true),
            .initialPlacement,
            "and the ladder still has its post-layout attempt"
        )
    }

    /// An empty transcript spends nothing: a brand-new chat must not jump, and
    /// must not burn attempts it will need when its first message arrives.
    func testAnEmptyTranscriptSpendsNoAttempts() {
        var placement = TranscriptScroll.Placement<String>()
        XCTAssertEqual(
            placement.decide(chat: "chat-new", isNonEmpty: false, isNearBottom: true),
            TranscriptScroll.Action.none
        )
        XCTAssertEqual(
            placement.decide(chat: "chat-new", isNonEmpty: false, isNearBottom: false, afterLayout: true),
            TranscriptScroll.Action.none
        )
        XCTAssertEqual(placement.attempts, 0)
        XCTAssertNil(placement.placedChat)
        XCTAssertEqual(
            placement.decide(chat: "chat-new", isNonEmpty: true, isNearBottom: true),
            .initialPlacement,
            "the first message it ever receives is what gets placed"
        )
    }

    /// The keying survives the hardening: a `ChatView` re-bound to a second
    /// session runs that session's ladder from the start.
    func testRebindingToAnotherChatRestartsTheLadder() {
        var placement = TranscriptScroll.Placement<String>()
        _ = placement.decide(chat: "chat-a", isNonEmpty: true, isNearBottom: false)
        _ = placement.decide(chat: "chat-a", isNonEmpty: true, isNearBottom: false, afterLayout: true)
        _ = placement.decide(chat: "chat-a", isNonEmpty: true, isNearBottom: true, afterLayout: true)
        XCTAssertEqual(placement.placedChat, "chat-a")

        XCTAssertEqual(
            placement.decide(chat: "chat-b", isNonEmpty: true, isNearBottom: false),
            .initialPlacement
        )
        XCTAssertEqual(
            placement.decide(chat: "chat-b", isNonEmpty: true, isNearBottom: false, afterLayout: true),
            .initialPlacement
        )
        XCTAssertEqual(
            placement.decide(chat: "chat-b", isNonEmpty: true, isNearBottom: true, afterLayout: true),
            .followTail
        )
        XCTAssertEqual(placement.placedChat, "chat-b")
    }

    /// The mutation the review found: delete the one line that records the
    /// latch and every rule test above the fold still passes, while the app
    /// re-enters placement on every delta and yanks a scrolled-back reader
    /// continuously. The latch now lives inside the seam, so this pins it —
    /// a hundred deltas arriving while the reader sits in scrollback must
    /// produce no scroll at all.
    func testAPlacedChatNeverReentersPlacementHoweverManyDeltasArrive() {
        var placement = TranscriptScroll.Placement<String>()
        _ = placement.decide(chat: "chat-a", isNonEmpty: true, isNearBottom: false)
        _ = placement.decide(chat: "chat-a", isNonEmpty: true, isNearBottom: false, afterLayout: true)
        XCTAssertEqual(
            placement.decide(chat: "chat-a", isNonEmpty: true, isNearBottom: true, afterLayout: true),
            .followTail
        )

        for delta in 0..<100 {
            XCTAssertEqual(
                placement.decide(chat: "chat-a", isNonEmpty: true, isNearBottom: false),
                TranscriptScroll.Action.none,
                "delta \(delta) re-entered placement — the reader would be yanked out of scrollback"
            )
        }
        XCTAssertEqual(placement.attempts, 2, "and no further scroll attempts were spent")
    }

    // MARK: The emptiness test the decision is fed

    /// `ChatView` asks `model.hasEntries`, not `!model.entries.isEmpty`, on
    /// every stream delta — `entries` allocates a joined array each read. The
    /// two must agree, or the transcript either never places or places against
    /// nothing.
    @MainActor
    func testHasEntriesAgreesWithTheEntriesItAvoidsBuilding() async throws {
        let harness = await AppHarness.make()
        let chat = harness.chat(storedID: "20260814_030303_cccccc", title: "C")

        XCTAssertTrue(chat.entries.isEmpty, "precondition: a freshly registered chat has no transcript")
        XCTAssertEqual(chat.hasEntries, !chat.entries.isEmpty)

        chat.live.entries = [ChatEntry(id: "e1", kind: .assistant, text: "hello", status: "complete")]
        XCTAssertTrue(chat.hasEntries)
        XCTAssertEqual(chat.hasEntries, !chat.entries.isEmpty)

        chat.live.entries = []
        XCTAssertEqual(chat.hasEntries, !chat.entries.isEmpty)

        await harness.tearDown()
    }
}
