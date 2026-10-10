import Foundation
import HermesServeKit
import XCTest

@testable import HermesMobile

/// What the Bots roster does between polls: the pin seeding it repeats (BUG-082), the avatar cache it keeps (BUG-083), the unread watermark it writes when a turn lands (BUG-094), and the groups footnote it derives from the default profile (BUG-146).
@MainActor
final class BotsRosterUpkeepTests: XCTestCase {

    private func stubRoster(_ harness: AppHarness, _ rows: [JSONValue]) async {
        await harness.backend.stub("profiles.list") { _ in
            .object(["profiles": .array(rows), "bot_mode_protocol": .bool(true)])
        }
    }

    /// The pin-seeding lookups sent for one profile: `session.list` carrying a `title`, scoped to that profile.
    private func titleLookups(_ harness: AppHarness, profile: String) async -> Int {
        await harness.backend.calls(to: "session.list").filter {
            $0.params["title"] != nil && $0.params["profile"]?.coercedString == profile
        }.count
    }

    // MARK: BUG-082 — seeding is not retried on every poll

    /// A bot nobody has talked to has no Bot Chat, so the seeding lookup can never succeed; it was re-sent for every such bot on every 5 s poll for as long as the roster was on screen.
    func testABotWithNoChatIsNotLookedUpOnEveryPoll() async throws {
        let harness = await AppHarness.make()
        try await harness.openSocket()
        await stubRoster(harness, [
            // A current backend answers the title question itself: `canonical_session: null` is "there is no Bot Chat".
            UpkeepWire.row(name: "fresh", canonical: .null),
            // An older backend says nothing either way, so the phone asks once.
            UpkeepWire.row(name: "legacy"),
        ])
        await harness.backend.stub("session.list") { _ in .object(["sessions": .array([])]) }

        for _ in 0..<3 { await harness.app.bots.refresh() }

        let fresh = await titleLookups(harness, profile: "fresh")
        XCTAssertEqual(
            fresh,
            0,
            "the backend already looked the Bot Chat up by title and said there is none; asking again is a round trip per bot per poll that can only repeat the answer"
        )
        let legacy = await titleLookups(harness, profile: "legacy")
        XCTAssertEqual(
            legacy,
            1,
            "a backend that does not answer by title gets one lookup per profile, not one per poll — three polls sent \(legacy)"
        )

        await harness.tearDown()
    }

    /// A pin is still seeded where seeding can work, and once a lookup succeeds the profile is pinned and never asked about again.
    func testSeedingStillPinsAnOlderBackendsChatOnce() async throws {
        let harness = await AppHarness.make()
        try await harness.openSocket()
        await stubRoster(harness, [UpkeepWire.row(name: "legacy")])
        await harness.backend.stub("session.list") { _ in
            .object(["sessions": .array([
                .object(["id": .string("seeded-1"), "resolved_id": .string("seeded-1"), "title": .string("Bot Chat")]),
            ])])
        }

        for _ in 0..<3 { await harness.app.bots.refresh() }

        XCTAssertEqual(harness.app.bots.store.pin(backend: harness.profileID, profile: "legacy"), "seeded-1")
        let lookups = await titleLookups(harness, profile: "legacy")
        XCTAssertEqual(lookups, 1)

        await harness.tearDown()
    }

    // MARK: BUG-083 — the avatar cache notices a new avatar

    /// A bot that gains an avatar on Desktop kept its monogram on the phone until a relaunch: the empty answer was cached for the life of the process and the roster's `has_avatar` flipping to true was never read as news.
    func testAnAvatarAddedElsewhereIsFetchedAfterTheRosterSaysSo() async throws {
        let harness = await AppHarness.make()
        try await harness.openSocket()
        await harness.backend.stub("session.list") { _ in .object(["sessions": .array([])]) }

        await stubRoster(harness, [UpkeepWire.row(name: "scout", canonical: .null, hasAvatar: false)])
        await harness.app.bots.refresh()
        await harness.backend.stub("profiles.get_asset") { _ in .object(["found": .bool(false)]) }
        let before = await harness.app.bots.avatarData(for: "scout")
        XCTAssertNil(before, "precondition: no avatar yet")

        let bytes = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        let encoded = "data:image/png;base64," + bytes.base64EncodedString()
        await harness.backend.stub("profiles.get_asset") { _ in
            .object(["found": .bool(true), "mime": .string("image/png"), "data": .string(encoded)])
        }
        await stubRoster(harness, [UpkeepWire.row(name: "scout", canonical: .null, hasAvatar: true)])
        await harness.app.bots.refresh()

        let after = await harness.app.bots.avatarData(for: "scout")
        XCTAssertEqual(
            after,
            bytes,
            "the roster now says this bot has an avatar and the phone still answers from a cached 'none' — the face added on Desktop never appears until a relaunch"
        )

        await harness.tearDown()
    }

    // MARK: BUG-094 — the watermark stays in the server's clock

    /// Server times here are in 2023 while the phone's clock reads today, which is a phone clock running ahead of the server: the completion stamped "now" from the phone and hid the next real message.
    func testATurnWatchedToTheEndDoesNotHideTheNextMessageWhenThePhoneClockIsAhead() async throws {
        let harness = await AppHarness.make()
        try await harness.openSocket()
        await harness.backend.stub("session.list") { _ in .object(["sessions": .array([])]) }
        let bots = harness.app.bots!

        await stubRoster(harness, [UpkeepWire.row(name: "scout", lastActive: 1_700_000_000)])
        await bots.refresh()

        harness.app.releaseChats(keeping: ["bot:scout"])
        bots.noteBotTurnCompleted(profile: "scout")
        harness.app.releaseChats(keeping: [])

        // The poll after the user backed out carries the turn they watched.
        await stubRoster(harness, [UpkeepWire.row(name: "scout", lastActive: 1_700_000_100)])
        await bots.refresh()
        XCTAssertEqual(bots.bots.first?.isUnread, false, "the reply the user watched land is read")

        // Then the bot says something new.
        await stubRoster(harness, [UpkeepWire.row(name: "scout", lastActive: 1_700_000_500)])
        await bots.refresh()
        XCTAssertEqual(
            bots.bots.first?.isUnread,
            true,
            "the bot spoke after the user left and no dot appeared — the watermark was stamped from the phone's clock, which runs ahead of the server's, so every server time below it reads as already seen"
        )

        await harness.tearDown()
    }

    /// Server times a day ahead of the phone: a phone-clock stamp landed BELOW a watermark already advanced from the server, and the reply the user had just watched lit up as unread.
    func testATurnWatchedToTheEndIsNotUnreadWhenThePhoneClockIsBehind() async throws {
        let harness = await AppHarness.make()
        try await harness.openSocket()
        await harness.backend.stub("session.list") { _ in .object(["sessions": .array([])]) }
        let bots = harness.app.bots!
        let server = Date().timeIntervalSince1970 + 86_400

        await stubRoster(harness, [UpkeepWire.row(name: "scout", lastActive: server)])
        await bots.refresh()

        harness.app.releaseChats(keeping: ["bot:scout"])
        await stubRoster(harness, [UpkeepWire.row(name: "scout", lastActive: server + 100)])
        await bots.refresh()
        XCTAssertEqual(bots.bots.first?.isUnread, false, "precondition: the user is watching")

        bots.noteBotTurnCompleted(profile: "scout")
        harness.app.releaseChats(keeping: [])

        await stubRoster(harness, [UpkeepWire.row(name: "scout", lastActive: server + 100)])
        await bots.refresh()
        XCTAssertEqual(
            bots.bots.first?.isUnread,
            false,
            "nothing new arrived and the dot came on anyway — the completion moved the watermark backwards to the phone's clock, below the server time the user had already seen"
        )

        await harness.tearDown()
    }

    // MARK: BUG-146 — the groups footnote follows the default profile

    func testTheGroupsFootnoteClearsWhenTheDefaultProfileLeavesTheRoster() async throws {
        let harness = await AppHarness.make()
        try await harness.openSocket()
        await harness.backend.stub("session.list") { _ in .object(["sessions": .array([])]) }

        await stubRoster(harness, [
            UpkeepWire.row(name: "default", canonical: .null, isDefault: true, uiMeta: UpkeepWire.groupsMeta),
            UpkeepWire.row(name: "scout", canonical: .null),
        ])
        await harness.app.bots.refresh()
        XCTAssertTrue(harness.app.bots.hasDesktopGroups, "precondition")

        await stubRoster(harness, [UpkeepWire.row(name: "scout", canonical: .null)])
        await harness.app.bots.refresh()
        XCTAssertFalse(
            harness.app.bots.hasDesktopGroups,
            "the footnote is about the default profile's groups, and a roster without a default profile has none to speak of"
        )

        await harness.tearDown()
    }
}

/// `profiles.list` rows; free-standing because `ScriptedBackend.stub` runs its closure off the main actor.
private enum UpkeepWire {
    static let groupsMeta: JSONValue = .object([
        "hermes-bots-groups": .object(["rooms": .object(["standup": .object(["members": .array([])])])]),
    ])

    /// `canonical` nil omits the key (an older backend), `.null` is a current backend's "no Bot Chat".
    static func row(
        name: String,
        canonical: JSONValue? = nil,
        isDefault: Bool = false,
        uiMeta: JSONValue? = nil,
        hasAvatar: Bool = false,
        lastActive: Double? = nil
    ) -> JSONValue {
        var row: [String: JSONValue] = [
            "name": .string(name),
            "path": .string("/home/\(name)"),
            "is_default": .bool(isDefault),
            "description": .string(""),
            "display_name": .string(""),
            "skill_count": .number(0),
            "has_avatar": .bool(hasAvatar),
            "ui_meta_revisions": .object([:]),
        ]
        if let canonical { row["canonical_session"] = canonical }
        if let uiMeta { row["ui_meta"] = uiMeta }
        if let lastActive {
            row["last_session"] = .object([
                "id": .string("last-\(name)"),
                "title": .string("Something else"),
                "preview": .string("visible session preview"),
                "started_at": .number(lastActive),
                "last_active": .number(lastActive),
                "message_count": .number(3),
            ])
        }
        return .object(row)
    }
}
