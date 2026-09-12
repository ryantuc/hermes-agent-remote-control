import HermesServeKit
import XCTest

@testable import HermesMobile

/// BUG-100 — the composer's settings shortcuts wiped the chat off the stack.
///
/// `RootView` applies a requested route as an absolute assignment, `path =
/// requested`, which is right for the hub, a `hermes://` deep link, a branch
/// open and the live-session picker — all of which mean "go here instead". The
/// composer's `⋯` shortcuts and the model sheet's Connect affordance mean "go
/// here as well", and used the same channel: Back from the settings screen
/// landed on Home, and `releaseChats` then ran with the chat's key absent and
/// evicted it if it was releasable.
///
/// The fix keeps the one absolute channel and makes the request name the whole
/// stack it wants, so nothing in `RootView` or `requestRoute` changes.
@MainActor
final class ComposerSettingsRouteTests: XCTestCase {

    // MARK: The path the shortcut asks for

    func testAShortcutFromAChatKeepsTheChatUnderneath() {
        let summary = Self.summary("s-1")
        XCTAssertEqual(
            ComposerSettingsRoute.path(from: .existing(summary), to: .settingsScreen(.personality)),
            [.thread(.existing(summary)), .settings, .settingsScreen(.personality)]
        )
    }

    /// The property that actually matters, stated as itself: whatever the
    /// screen, the conversation is still on the stack and Back reaches it.
    func testEveryComposerShortcutLeavesTheChatOnTheStack() {
        let route = ThreadRoute.new(UUID())
        let screens: [AppRoute] = [
            .settingsScreen(.composerActions), .settingsScreen(.personality),
            .settingsScreen(.safety), .settingsScreen(.advanced),
            .settingsScreen(.capabilities), .settingsBackend,
        ]
        for screen in screens {
            let path = ComposerSettingsRoute.path(from: route, to: screen)
            XCTAssertEqual(path.first, .thread(route), "\(screen)")
            XCTAssertEqual(path.last, screen, "\(screen)")
            XCTAssertEqual(
                Array(path.dropFirst().dropLast()), [.settings],
                "Back has to reach the Settings root, then the chat"
            )
            XCTAssertNotNil(
                path.first?.threadRouteKey,
                "releaseChats reads exactly this key; without it the chat is evicted"
            )
        }
    }

    /// A conversation the app cannot name — a draft that has never bound — is
    /// the one case that falls back to the old two-element path. There is
    /// nothing to lose in that state: an unbound draft holding text is not
    /// releasable, and one holding nothing is not worth returning to.
    func testAnUnnameableChatFallsBackToTheOldPath() {
        XCTAssertEqual(
            ComposerSettingsRoute.path(from: nil, to: .settingsBackend),
            [.settings, .settingsBackend]
        )
    }

    // MARK: Which element the app hands it

    /// `route(for:)` answers "how would a deep link reach this chat" and
    /// answers nil for a draft, because `summary` is only ever set at
    /// construction. `openRoute(for:)` answers the navigation question instead.
    func testOpenRouteNamesAnExistingConversation() async {
        let harness = await AppHarness.make()
        let chat = harness.chat(storedID: "s-42")
        if case .existing(let summary)? = harness.app.openRoute(for: chat) {
            XCTAssertEqual(summary.id, "s-42")
        } else {
            XCTFail("an existing conversation is nameable both ways")
        }
        await harness.tearDown()
    }

    /// The case `route(for:)` cannot answer, and the reason this method exists.
    /// A conversation started from Home keeps its `new:<uuid>` identity for the
    /// life of the process — which is exactly the element `RootView` pushed.
    func testOpenRouteNamesADraftConversation() async {
        let harness = await AppHarness.make()
        let id = UUID()
        let chat = harness.app.chat(for: .new(id))
        XCTAssertNil(harness.app.route(for: chat), "a draft has no deep-link identity")
        XCTAssertEqual(harness.app.openRoute(for: chat), .new(id))
        await harness.tearDown()
    }

    /// A chat this model has never cached cannot be named, and saying so is
    /// how the fallback above is reached rather than a wrong element pushed.
    func testAnUncachedChatIsNotNamed() async {
        let harness = await AppHarness.make()
        let stranger = ChatModel(app: harness.app, summary: nil)
        XCTAssertNil(harness.app.openRoute(for: stranger))
        await harness.tearDown()
    }

    // MARK: The key parser the lookup rests on

    func testEveryKeyRoundTrips() {
        let id = UUID()
        let cases: [ThreadRoute.Key] = [.existing("s-1"), .new(id), .bot("scribe")]
        for key in cases {
            XCTAssertEqual(ThreadRoute.Key(rawValue: key.rawValue), key)
        }
    }

    /// A session id containing a colon must survive, because the split is
    /// deliberately capped at one.
    func testASessionIdWithAColonSurvives() {
        let key = ThreadRoute.Key.existing("2026-08-26T12:30:00")
        XCTAssertEqual(ThreadRoute.Key(rawValue: key.rawValue), key)
    }

    func testGarbageIsNotAKey() {
        XCTAssertNil(ThreadRoute.Key(rawValue: "nonsense"))
        XCTAssertNil(ThreadRoute.Key(rawValue: "other:thing"))
        XCTAssertNil(ThreadRoute.Key(rawValue: "new:not-a-uuid"))
    }

    // MARK: Fixture

    private static func summary(_ id: String) -> SessionSummary {
        SessionSummary(json: .object([
            "id": .string(id),
            "title": .string("Scripted thread"),
            "source": .string("ios"),
            "last_active": .number(0),
            "message_count": .number(4),
        ]))
    }
}
