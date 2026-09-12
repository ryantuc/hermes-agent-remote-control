import Foundation
import HermesServeKit
import XCTest

@testable import HermesMobile

/// **BUG-099 — a mode switch into Bots evicted every quiet Sessions conversation.**
///
/// `RootView`'s retention driver is `onChange(of: path)`, and it reads only the live path. That is right for a pop — the navigation stack is the honest record of what the user has left — and wrong for a mode switch, because a mode switch does not pop anything. `BotsRouteMemory.enter` *stashes* the Sessions path in `RootView` state and assigns a fresh one, so the `onChange` that fires next arrives with no Sessions keys in `keeping` at all.
///
/// `ChatModel.isReleasable` keeps the limits honest: nothing running, nothing prompted, nothing with a draft or an attachment or unsent work is released, so nothing the user typed is lost. What is lost is every quiet, already-persisted conversation — which is most of them. Coming back out of Bots remounts them cold: a spinner, a transcript refetch, the scroll position gone, sheets closed, and one resume RPC per thrash.
///
/// The fix is a second retention set rather than a wider first one. `bots.setOnScreenRouteKeys` is called from inside `releaseChats` with `keeping`, and it means **visible** — it is what decides whether a bot thread earns an unread dot. A stashed route is retained and not visible, and telling the roster otherwise would silently suppress unread state for a thread nobody is looking at.
final class StashedChatRetentionTests: XCTestCase {

    /// The regression, at the call site's own arithmetic.
    @MainActor
    func testAStashedThreadSurvivesTheSweepThatFollowsAModeSwitch() async throws {
        let harness = await AppHarness.make()
        try await harness.openSocket()

        let storedID = "20260826_120000_bug099"
        let chat = harness.chat(storedID: storedID)
        await chat.open()
        let bound = await waitUntil { chat.runtimeSessionID != nil }
        XCTAssertTrue(bound, "the chat never bound a runtime session id")
        chat.errorMessage = nil
        guard let runtimeID = chat.runtimeSessionID else {
            return XCTFail("no runtime session id to track")
        }

        let routeKey = ThreadRoute.Key.existing(storedID).rawValue

        // The mode switch: `path` is emptied and this route moves to the stash.
        // Exactly what `RootView.onChange(of: path)` now passes.
        harness.app.releaseChats(keeping: [], alsoKeeping: [routeKey])

        XCTAssertTrue(
            harness.app.chat(runtimeSessionID: runtimeID) === chat,
            """
            a Sessions conversation was evicted on the way into Bots mode. It was not closed and it was \
            not popped — it is held in `RootView.stashedSessionsPath` and comes back the moment the user \
            switches modes again. Coming back to a cold remount is BUG-099
            """
        )
        XCTAssertTrue(
            harness.app.engine.trackedSessionIDs.contains(runtimeID),
            "the engine forgot the turn state for a stashed session, so re-entry costs a full resume"
        )

        await harness.tearDown()
    }

    /// The stash must not become an amnesty. A route that is on neither the
    /// live path nor the stash is a route the user genuinely left, and the A8
    /// sweep still has to reclaim it.
    @MainActor
    func testAnUnstashedThreadIsStillReleased() async throws {
        let harness = await AppHarness.make()
        try await harness.openSocket()

        let stashedID = "20260826_120100_bug099_stashed"
        let leftID = "20260826_120200_bug099_left"

        let stashed = harness.chat(storedID: stashedID)
        await stashed.open()
        _ = await waitUntil { stashed.runtimeSessionID != nil }
        stashed.errorMessage = nil

        let left = harness.chat(storedID: leftID)
        await left.open()
        let bound = await waitUntil { left.runtimeSessionID != nil }
        XCTAssertTrue(bound, "the second chat never bound a runtime session id")
        left.errorMessage = nil
        guard let leftRuntimeID = left.runtimeSessionID else {
            return XCTFail("no runtime session id for the abandoned chat")
        }

        harness.app.releaseChats(
            keeping: [],
            alsoKeeping: [ThreadRoute.Key.existing(stashedID).rawValue]
        )

        XCTAssertNil(
            harness.app.chat(runtimeSessionID: leftRuntimeID),
            """
            a conversation that is on neither the live path nor the stash was retained. A8's whole \
            subject is that every chat ever opened stays in memory for the life of the process; \
            BUG-099 narrows that sweep, it does not switch it off
            """
        )

        await harness.tearDown()
    }

    /// Omitting the new argument has to behave exactly as before, because every
    /// other caller and every existing test still omits it.
    @MainActor
    func testTheDefaultIsAnEmptyStashAndTheOldBehaviourIsUnchanged() async throws {
        let harness = await AppHarness.make()
        try await harness.openSocket()

        let chat = harness.chat(storedID: "20260826_120300_bug099_default")
        await chat.open()
        let bound = await waitUntil { chat.runtimeSessionID != nil }
        XCTAssertTrue(bound, "the chat never bound a runtime session id")
        chat.errorMessage = nil
        guard let runtimeID = chat.runtimeSessionID else {
            return XCTFail("no runtime session id to track")
        }

        harness.app.releaseChats(keeping: [])

        XCTAssertNil(
            harness.app.chat(runtimeSessionID: runtimeID),
            "adding `alsoKeeping:` changed what a plain `releaseChats(keeping:)` does"
        )

        await harness.tearDown()
    }

    /// The path arithmetic the call site depends on: `BotsRouteMemory.enter`
    /// really does hand the Sessions routes to the stash rather than dropping
    /// them, so there is something for `alsoKeeping` to carry.
    func testEnteringBotsModeStashesTheSessionsRoutesRatherThanDiscardingThem() {
        let thread = ThreadRoute.new(UUID())
        let transition = BotsRouteMemory.enter(path: [.thread(thread)], remembered: nil)
        XCTAssertEqual(transition.path, [], "the Bots stack is rooted at the roster")
        XCTAssertEqual(transition.stashed, [.thread(thread)], """
            the Sessions route was dropped rather than stashed, which would make `alsoKeeping` a \
            permanently empty set and BUG-099 unfixable at the call site
            """)
        XCTAssertEqual(
            transition.stashed.compactMap(\.threadRouteKey),
            [thread.key],
            "the stashed route no longer yields the retention key `releaseChats` matches on"
        )
    }
}
