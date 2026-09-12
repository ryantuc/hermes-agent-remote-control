import HermesServeKit
import UIKit
import XCTest

@testable import HermesMobile

/// The far-right control in Home's top bar, and the path arithmetic behind the mode switch it performs.
///
/// Both are pure functions and both are asserted directly, for the reason `HomeLiveIndicatorRouteTests` gives: a Box-hosted view test would pass on a control that drew the right glyph and went nowhere, which is exactly the class of bug worth catching here.
@MainActor
final class HomeModeControlTests: XCTestCase {

    // MARK: The toggle

    func testTheControlSwitchesToTheOtherMode() {
        XCTAssertEqual(HomeModeControl.toggled(.sessions), .bots)
        XCTAssertEqual(HomeModeControl.toggled(.bots), .sessions)
    }

    /// **Two modes, so the toggle is an involution.** Stated as a property rather than as two equalities because it is the assumption the single control rests on: one button that reaches every mode is only honest while there are two of them. A third mode arriving later fails here, which is where it should fail.
    func testTogglingTwiceIsIdentityForEveryMode() {
        for mode in AppMode.allCases {
            XCTAssertEqual(HomeModeControl.toggled(HomeModeControl.toggled(mode)), mode,
                           "\(mode.rawValue) does not round-trip — one control can no longer reach every mode")
        }
        XCTAssertEqual(AppMode.allCases.count, 2,
                       "a third mode makes the single toggle control wrong, not just incomplete")
    }

    // MARK: The glyph

    /// The glyph names the **destination**, not the screen it is on.
    func testEachModeDrawsTheGlyphOfWhereTappingGoes() {
        XCTAssertEqual(HomeModeControl.glyph(for: .sessions), .bot,
                       "the Sessions screen's control goes to Bots and must wear the bot glyph")
        XCTAssertEqual(HomeModeControl.glyph(for: .bots), .symbol("terminal"),
                       "the Bots screen's control goes back to Sessions")
    }

    /// Every symbol the control names has to exist. A missing SF Symbol renders as nothing at all — a 44 pt invisible button — and no build error says so.
    func testEverySymbolGlyphResolvesInTheCatalog() {
        for mode in AppMode.allCases {
            guard case .symbol(let name) = HomeModeControl.glyph(for: mode) else { continue }
            XCTAssertNotNil(UIImage(systemName: name),
                            "`\(name)` does not resolve — the \(mode.rawValue) control would draw an empty 44 pt box")
        }
    }

    /// The label names the destination too, so the control reads the same way it looks.
    func testTheLabelNamesTheDestination() {
        XCTAssertEqual(HomeModeControl.accessibilityLabel(for: .sessions), "Bots")
        XCTAssertEqual(HomeModeControl.accessibilityLabel(for: .bots), "Sessions")
    }

    // MARK: Launch mode

    func testTheLaunchModeDefaultsToSessions() {
        XCTAssertEqual(AppMode.launchMode(stored: nil), .sessions)
        XCTAssertEqual(AppMode.launchMode(stored: ""), .sessions)
        XCTAssertEqual(AppMode.launchMode(stored: "Projects"), .sessions,
                       "an unrecognised value must land on Sessions, not crash and not stick")
    }

    func testTheLaunchModeReadsBothStoredValues() {
        XCTAssertEqual(AppMode.launchMode(stored: "Sessions"), .sessions)
        XCTAssertEqual(AppMode.launchMode(stored: "Bots"), .bots)
    }

    /// Not `hermes.hub.mode`: that key already exists, already means Sessions-vs-Projects grouping, and its consumer is an if/else whose `else` is the Sessions history — so a "Bots" written into it renders the Sessions history under a Bots selection on an app that has merely been upgraded.
    func testTheLaunchModeKeyIsNotTheHubsGroupingKey() {
        XCTAssertNotEqual(AppMode.launchModeStorageKey, "hermes.hub.mode")
        XCTAssertEqual(AppMode.launchModeStorageKey, "hermes.app.launchMode")
    }
}

/// The path arithmetic of a mode switch, asserted without hosting `RootView`.
///
/// Two requirements pull against each other and both are pinned here: Bots mode opens to the roster and Back returns to it (so the Bots stack is rooted at the Bots root, and `path` is emptied on the way in), while switching back returns the user to the session or draft they left (so the path that was emptied has to come back).
@MainActor
final class BotsRouteMemoryTests: XCTestCase {

    private func botRef(_ profile: String) -> BotThreadRef {
        BotThreadRef(profile: profile, displayName: profile.capitalized)
    }

    private func sessionRoute(_ id: String) -> AppRoute {
        .thread(.existing(SessionSummary(json: .object([
            "id": .string(id),
            "title": .string("A session"),
            "last_active": .number(1_700_000_000),
        ]))))
    }

    // MARK: Entering

    func testEnteringBotsWithNoRememberedThreadLandsOnTheRoster() {
        let transition = BotsRouteMemory.enter(path: [], remembered: nil)
        XCTAssertEqual(transition.path, [], "the Bots root is the roster, and the roster is an empty path")
    }

    /// Entering Bots mode restores the last thread on top if there was one.
    func testEnteringBotsWithARememberedThreadPushesItOnTopOfTheRoster() {
        let ref = botRef("ops-bot")
        let transition = BotsRouteMemory.enter(path: [], remembered: ref)
        XCTAssertEqual(transition.path, [.thread(.bot(ref))])
    }

    /// **The reason the roster is underneath and not replaced.** One element on the stack means Back has somewhere to go, and where it goes is the list.
    func testTheRestoredThreadSitsOnAStackBackCanPopToTheRoster() {
        let transition = BotsRouteMemory.enter(path: [], remembered: botRef("ops-bot"))
        XCTAssertEqual(transition.path.count, 1, """
            the restored thread must be one element deep so Back pops to the roster. A deeper path \
            would strand the user, an empty one would not restore anything
            """)
    }

    func testEnteringBotsHoldsTheSessionsPathForTheWayBack() {
        let sessions: [AppRoute] = [sessionRoute("s-1")]
        let transition = BotsRouteMemory.enter(path: sessions, remembered: nil)
        XCTAssertEqual(transition.stashed, sessions,
                       "the Sessions path is put aside, not discarded — switching back has to return to it")
    }

    /// A bot route can legitimately be sitting in a Sessions stack: a Live Activity tap routes one there. It must not be *stashed*, or switching back to Sessions later would put a bot thread behind a Sessions Back button.
    func testABotRouteReachedFromASessionsStackIsNotStashed() {
        let path: [AppRoute] = [sessionRoute("s-1"), .thread(.bot(botRef("ops-bot")))]
        let transition = BotsRouteMemory.enter(path: path, remembered: nil)
        XCTAssertEqual(transition.stashed, [sessionRoute("s-1")])
    }

    // MARK: Leaving

    func testLeavingBotsRestoresTheSessionsPath() {
        let sessions: [AppRoute] = [sessionRoute("s-1")]
        let restored = BotsRouteMemory.leave(path: [.thread(.bot(botRef("ops-bot")))], stashed: sessions)
        XCTAssertEqual(restored, sessions, """
            switching back must return the user to the session they left. Landing them on Home \
            instead is the failure this stash exists to prevent
            """)
    }

    func testLeavingBotsFromTheRosterWithNothingStashedLandsOnHome() {
        XCTAssertEqual(BotsRouteMemory.leave(path: [], stashed: []), [])
    }

    /// The live Bots path is discarded, not merged: neither the roster nor a bot thread belongs in a Sessions stack.
    func testTheBotsPathIsNotCarriedIntoSessionsMode() {
        let restored = BotsRouteMemory.leave(
            path: [.thread(.bot(botRef("ops-bot")))],
            stashed: []
        )
        XCTAssertEqual(restored, [], "a bot thread must not be reachable behind a Sessions Back button")
    }

    // MARK: Round trip

    /// **The property the whole scheme exists for.** Out and back is where the user started.
    func testASessionsPathSurvivesARoundTripThroughBotsMode() {
        for sessions in [[], [sessionRoute("s-1")], [AppRoute.settings, .settingsScreen(.notifications)]] {
            let out = BotsRouteMemory.enter(path: sessions, remembered: botRef("ops-bot"))
            let back = BotsRouteMemory.leave(path: out.path, stashed: out.stashed)
            XCTAssertEqual(back, sessions, "\(sessions) did not survive a round trip through Bots mode")
        }
    }

    // MARK: The route predicate the arithmetic rests on

    func testOnlyABotThreadRouteCountsAsABotThread() {
        XCTAssertTrue(AppRoute.thread(.bot(botRef("ops-bot"))).isBotThread)
        XCTAssertFalse(sessionRoute("s-1").isBotThread)
        XCTAssertFalse(AppRoute.thread(.new(UUID())).isBotThread)
        XCTAssertFalse(AppRoute.settings.isBotThread)
        XCTAssertFalse(AppRoute.commandCenter.isBotThread)
    }
}
