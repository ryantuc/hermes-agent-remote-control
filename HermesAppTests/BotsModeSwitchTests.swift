import Foundation
import HermesServeKit
import XCTest

@testable import HermesMobile

/// What the mode switch may not cost.
///
/// A "switching modes issues no teardown" test is unwritable at this
/// layer, and deliberately so: the mode is `RootView` `@State`; switching it
/// swaps Home's body and touches nothing on `AppModel` — no `activate`, no
/// `teardown`, no `path`, no `ChatModel`. There is no model-layer call to make
/// and therefore nothing for a model-layer test to assert; a test that
/// "switched modes" by calling nothing and then checked that nothing changed
/// would pass against any implementation, including one that tore the socket
/// down. So this class asserts the two properties the switch actually *depends
/// on* — the ones that would make a mode switch lossy if they were untrue.
@MainActor
final class BotsModeSwitchTests: XCTestCase {

    private let scout = BotThreadRef(profile: "scout", displayName: "Scout")

    /// The route is the bot, so re-entering a bot thread — from the roster, the
    /// hub, a deep link, or by leaving and coming back to Bots mode — must land
    /// on the instance that is already there rather than a fresh one.
    func testChatForABotRouteIsTheSameInstanceEveryTime() async throws {
        let harness = await AppHarness.make()
        try await harness.openSocket()

        let first = harness.app.chat(for: .bot(scout))
        first.draft = "half a thought"
        let second = harness.app.chat(for: .bot(BotThreadRef(profile: "scout", displayName: "Scout")))

        XCTAssertTrue(
            first === second,
            "a second lookup built a second ChatModel for the same bot — the draft, the transcript "
                + "and any running turn all live on the instance, so the user would watch their "
                + "conversation reset itself"
        )
        XCTAssertEqual(second.draft, "half a thought")
        XCTAssertTrue(
            harness.app.chat(for: .bot(BotThreadRef(profile: "scout", displayName: "Renamed"))) === first,
            "the cache key is the profile, not the label — renaming a bot must not orphan its thread"
        )
        XCTAssertEqual(first.botProfile, "scout")
        XCTAssertEqual(first.botDisplayName, "Scout")

        await harness.tearDown()
    }

    /// A bot chat is subject to the same retention rule as every other chat,
    /// and that rule is what makes a mode switch safe: nothing can drop a model
    /// holding unsent work, so a typed draft cannot be lost by leaving the
    /// screen the composer was on.
    func testABotChatWithADraftIsNotReleased() async throws {
        let harness = await AppHarness.make()
        try await harness.openSocket()
        harness.app.bots.store.setPin("pin-1", backend: harness.profileID, profile: "scout")

        let chat = harness.app.chat(for: .bot(scout))
        await chat.open()
        XCTAssertNotNil(chat.storedSessionID, "precondition: releasable chats need a stored id")

        chat.draft = "the message the user was in the middle of"
        harness.app.releaseChats(keeping: [])

        XCTAssertTrue(
            harness.app.chat(for: .bot(scout)) === chat,
            "the bot chat was evicted with an unsent draft in it — nothing on disk brings that "
                + "text back, and chat(for:) hands the composer a blank model in its place"
        )
        XCTAssertEqual(harness.app.chat(for: .bot(scout)).draft, "the message the user was in the middle of")

        await harness.tearDown()
    }

    /// The same chat with nothing in it *is* releasable — the retention rule is
    /// a guard on unsent work, not a leak.
    func testAQuietBotChatIsStillEvictable() async throws {
        let harness = await AppHarness.make()
        try await harness.openSocket()
        harness.app.bots.store.setPin("pin-1", backend: harness.profileID, profile: "scout")

        let chat = harness.app.chat(for: .bot(scout))
        await chat.open()
        XCTAssertTrue(chat.isReleasable, "precondition: nothing running, nothing typed")

        let released = harness.app.releaseChats(keeping: [])
        XCTAssertEqual(released, 1)
        XCTAssertFalse(
            harness.app.chat(for: .bot(scout)) === chat,
            "an idle bot chat must be evictable like any other; the session stays alive "
                + "server-side and re-entry resumes it"
        )

        await harness.tearDown()
    }

    /// The bot chat is registered under its bot route AND its stored id, so the
    /// Live Activity's runtime-id lookup finds it — and `route(for:)` sends it
    /// back to the bot route rather than pushing a second identity for it.
    func testABoundBotChatIsReachableByRuntimeIDAndRoutesBackToTheBot() async throws {
        let harness = await AppHarness.make()
        try await harness.openSocket()
        harness.app.bots.store.setPin("pin-1", backend: harness.profileID, profile: "scout")

        let chat = harness.app.chat(for: .bot(scout))
        await chat.open()
        let runtimeID = try XCTUnwrap(chat.runtimeSessionID)

        let found = try XCTUnwrap(
            harness.app.chat(runtimeSessionID: runtimeID),
            "chatDidBind never registered the bot chat, so a Lock Screen card for its turn opens "
                + "Home instead of the conversation"
        )
        XCTAssertTrue(found === chat)
        guard case .bot(let ref)? = harness.app.route(for: found) else {
            return XCTFail("the deep link would push .existing and lose the bot's header")
        }
        XCTAssertEqual(ref.profile, "scout")

        await harness.tearDown()
    }
}
