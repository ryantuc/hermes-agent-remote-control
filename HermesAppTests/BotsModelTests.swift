import Foundation
import HermesServeKit
import XCTest

@testable import HermesMobile

/// `profiles.list` wire payloads. Free-standing rather than statics on the
/// test class: `ScriptedBackend.stub` takes a `@Sendable` closure that runs off
/// the main actor, and a helper isolated to a `@MainActor` class cannot be
/// called from inside one.
private enum RosterWire {
    /// One `profiles.list` row. `preferred` is the tri-state: `nil` omits the
    /// key entirely (absent), `.null` sends it null (gone).
    static func profileRow(
        name: String,
        displayName: String = "",
        description: String = "",
        isDefault: Bool = false,
        lastActive: Double? = nil,
        preferred: JSONValue? = nil,
        worker: JSONValue? = nil,
        uiMeta: JSONValue? = nil,
        hasAvatar: Bool = false
    ) -> JSONValue {
        var row: [String: JSONValue] = [
            "name": .string(name),
            "path": .string("/home/\(name)"),
            "is_default": .bool(isDefault),
            "description": .string(description),
            "display_name": .string(displayName),
            "skill_count": .number(0),
            "has_avatar": .bool(hasAvatar),
            "ui_meta_revisions": .object([:]),
        ]
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
        if let preferred { row["preferred_session"] = preferred }
        if let worker { row["worker_session"] = worker }
        if let uiMeta { row["ui_meta"] = uiMeta }
        return .object(row)
    }

    static func preferredRow(
        id: String,
        lastActive: Double,
        preview: String = "the bot's newest line"
    ) -> JSONValue {
        .object([
            "id": .string(id),
            "resolved_id": .string(id),
            "root_title": .string("Bot Chat"),
            "title": .string("Bot Chat"),
            "preview": .string(preview),
            "started_at": .number(lastActive),
            "last_active": .number(lastActive),
            "message_count": .number(9),
        ])
    }
}

/// The Bots roster.
@MainActor
final class BotsModelTests: XCTestCase {

    private func stubRoster(
        _ harness: AppHarness,
        _ rows: [JSONValue],
        botModeProtocol: Bool = true
    ) async {
        await harness.backend.stub("profiles.list") { _ in
            .object([
                "profiles": .array(rows),
                "bot_mode_protocol": .bool(botModeProtocol),
            ])
        }
        // Pin seeding runs after every load; answer it so it does not fall
        // through to the unhandled-method `{}`.
        await harness.backend.stub("session.list") { _ in .object(["sessions": .array([])]) }
    }

    // MARK: Naming

    func testDefaultProfileIsShownAsHermes() {
        XCTAssertEqual(
            BotsModel.displayName(profile: "default", declared: ""),
            "Hermes",
            "\"Default\" is not a name anyone gave this bot; Desktop calls it Hermes and so do we"
        )
        XCTAssertEqual(
            BotsModel.displayName(profile: "default", declared: "Something Else"),
            "Hermes",
            "the default profile is Hermes even when profile.yaml declares a display_name"
        )
        XCTAssertEqual(BotsModel.displayName(profile: "scout", declared: "Scout Prime"), "Scout Prime")
        XCTAssertEqual(BotsModel.displayName(profile: "code-review", declared: ""), "Code Review")
        XCTAssertEqual(BotsModel.displayName(profile: "data_ops", declared: ""), "Data Ops")
        XCTAssertEqual(BotsModel.displayName(profile: "scout", declared: "   "), "Scout")
    }

    // MARK: Roster

    func testRosterSortsByRecencyAcrossBothSessionSources() async throws {
        let harness = await AppHarness.make()
        try await harness.openSocket()
        let now = Date().timeIntervalSince1970

        await stubRoster(harness, [
            // Default profile, oldest — it competes on recency like any other
            // row rather than being pinned to the top.
            RosterWire.profileRow(name: "default", isDefault: true, lastActive: now - 9000),
            RosterWire.profileRow(name: "scout", displayName: "Scout", lastActive: now - 4000),
            RosterWire.profileRow(
                name: "archivist",
                lastActive: now - 100_000,
                // The hidden Bot Chat is invisible to `last_session`; only the
                // pinned lookup sees it, and it is the freshest thing here.
                preferred: RosterWire.preferredRow(id: "pin-arch", lastActive: now - 30)
            ),
        ])
        harness.app.bots.store.setPin("pin-arch", backend: harness.profileID, profile: "archivist")

        await harness.app.bots.refresh()

        XCTAssertEqual(
            harness.app.bots.bots.map(\.profile),
            ["archivist", "scout", "default"],
            "recency is max(preferred_session.last_active, last_session.last_active) — reading "
                + "last_session alone never sees the hidden Bot Chat and sorts the liveliest bot last"
        )
        XCTAssertEqual(harness.app.bots.bots.map(\.displayName), ["Archivist", "Scout", "Hermes"])
        XCTAssertEqual(harness.app.bots.botModeProtocol, true)
        XCTAssertTrue(harness.app.bots.hasLoadedOnce)
        XCTAssertNil(harness.app.bots.error)

        await harness.tearDown()
    }

    func testPreviewPrefersThePinnedChatThenTheProfileDescription() async throws {
        let harness = await AppHarness.make()
        try await harness.openSocket()
        let now = Date().timeIntervalSince1970

        await stubRoster(harness, [
            RosterWire.profileRow(
                name: "scout",
                description: "Reads the news",
                lastActive: now - 500,
                preferred: RosterWire.preferredRow(id: "pin-1", lastActive: now - 60, preview: "on it")
            ),
            RosterWire.profileRow(name: "quiet", description: "Has never said anything"),
        ])
        harness.app.bots.store.setPin("pin-1", backend: harness.profileID, profile: "scout")

        await harness.app.bots.refresh()

        let scout = harness.app.bots.bots.first { $0.profile == "scout" }
        XCTAssertEqual(scout?.preview, "on it", "the forever-chat's newest line wins")
        let quiet = harness.app.bots.bots.first { $0.profile == "quiet" }
        XCTAssertEqual(
            quiet?.preview,
            "Has never said anything",
            "a bot with no conversation falls back to what the profile says it is for"
        )
        XCTAssertEqual(quiet?.lastActive, 0)

        await harness.tearDown()
    }

    /// `.absent` and `.gone` must not collapse. Absent is an old gateway or a
    /// pin we never sent; gone is "that session no longer exists". Neither
    /// retires the pin from the roster — only the resolver's 4007 does.
    func testAGonePreferredSessionDoesNotDropThePin() async throws {
        let harness = await AppHarness.make()
        try await harness.openSocket()

        await stubRoster(harness, [
            RosterWire.profileRow(name: "scout", lastActive: 1_700_000_000, preferred: .null),
        ])
        harness.app.bots.store.setPin("pin-1", backend: harness.profileID, profile: "scout")

        await harness.app.bots.refresh()

        XCTAssertEqual(
            harness.app.bots.store.pin(backend: harness.profileID, profile: "scout"),
            "pin-1",
            "a roster poll is a side channel; retiring a pin on it re-derives — and re-deriving "
                + "is what mints a second forever-chat"
        )
        XCTAssertEqual(
            harness.app.bots.bots.first?.lastActive,
            1_700_000_000,
            "a gone preferred session still leaves last_session's recency to sort on"
        )

        await harness.tearDown()
    }

    func testPreferredSessionIDsCarryEveryPinForThisBackend() async throws {
        let harness = await AppHarness.make()
        try await harness.openSocket()
        harness.app.bots.store.setPin("pin-a", backend: harness.profileID, profile: "scout")
        harness.app.bots.store.setPin("pin-b", backend: harness.profileID, profile: "archivist")
        // Another machine's pin for the same bot name. It must never ride this
        // backend's call — a session id only means something on the state.db
        // that minted it.
        harness.app.bots.store.setPin("pin-elsewhere", backend: UUID(), profile: "scout")

        await stubRoster(harness, [])
        await harness.app.bots.refresh()

        // `.last`, not `.first`: opening the socket already ran one roster
        // refresh, and that one legitimately carried no pins.
        let call = await harness.backend.calls(to: "profiles.list").last
        let sent = call?.params["preferred_session_ids"]?.objectValue ?? [:]
        XCTAssertEqual(sent["scout"]?.coercedString, "pin-a")
        XCTAssertEqual(sent["archivist"]?.coercedString, "pin-b")
        XCTAssertEqual(sent.count, 2, "pins are per backend connection and must not leak across one")

        await harness.tearDown()
    }

    /// A profile with no pin gets one `session.list title=` lookup so the NEXT
    /// poll carries a `preferred_session`.
    func testFirstLoadSeedsAPinForAnUnpinnedProfile() async throws {
        let harness = await AppHarness.make()
        try await harness.openSocket()

        await harness.backend.stub("profiles.list") { _ in
            .object([
                "profiles": .array([RosterWire.profileRow(name: "scout")]),
                "bot_mode_protocol": .bool(true),
            ])
        }
        await harness.backend.stub("session.list") { _ in
            .object(["sessions": .array([
                .object([
                    "id": .string("seeded-1"),
                    "resolved_id": .string("seeded-1"),
                    "title": .string("Bot Chat"),
                ]),
            ])])
        }

        await harness.app.bots.refresh()

        XCTAssertEqual(
            harness.app.bots.store.pin(backend: harness.profileID, profile: "scout"),
            "seeded-1",
            "without the seeding lookup the roster can never show a hidden Bot Chat's recency: "
                + "profiles.list only resolves pins the caller supplied"
        )

        await harness.tearDown()
    }

    // MARK: Working

    func testWorkingDotReadsTheRecencyWindows() async throws {
        let harness = await AppHarness.make()
        try await harness.openSocket()
        let now = Date().timeIntervalSince1970

        await stubRoster(harness, [
            RosterWire.profileRow(
                name: "fresh",
                preferred: RosterWire.preferredRow(id: "pin-fresh", lastActive: now - 10)
            ),
            RosterWire.profileRow(
                name: "stale",
                preferred: RosterWire.preferredRow(id: "pin-stale", lastActive: now - 600)
            ),
            RosterWire.profileRow(
                name: "worker",
                worker: .object([
                    "id": .string("w-1"),
                    "source": .string("kanban"),
                    "title": .string("board run"),
                    "last_active": .number(now - 100),
                ])
            ),
        ])
        for name in ["fresh", "stale"] {
            harness.app.bots.store.setPin("pin-\(name)", backend: harness.profileID, profile: name)
        }

        await harness.app.bots.refresh()

        let byName = Dictionary(uniqueKeysWithValues: harness.app.bots.bots.map { ($0.profile, $0) })
        XCTAssertEqual(byName["fresh"]?.isWorking, true, "inside the 90 s chat window")
        XCTAssertEqual(byName["stale"]?.isWorking, false, "600 s is well outside every window")
        XCTAssertEqual(
            byName["worker"]?.isWorking,
            true,
            "a kanban/tool worker heartbeats less often, which is why its window is 150 s"
        )

        await harness.tearDown()
    }

    // MARK: Unread

    /// The first sighting of a bot seeds its watermark. Otherwise a backend
    /// full of months-old bot chats opens as a wall of unread dots on the day
    /// the feature ships.
    func testFirstSightingSeedsTheWatermarkAndIsNotUnread() async throws {
        let harness = await AppHarness.make()
        try await harness.openSocket()

        await stubRoster(harness, [
            RosterWire.profileRow(name: "scout", lastActive: 1_700_000_000),
        ])
        await harness.app.bots.refresh()

        XCTAssertEqual(harness.app.bots.bots.first?.isUnread, false)
        XCTAssertEqual(
            harness.app.bots.store.watermark(backend: harness.profileID, profile: "scout"),
            1_700_000_000
        )

        await harness.tearDown()
    }

    func testNewActivityAfterTheWatermarkIsUnreadUntilMarkOpened() async throws {
        let harness = await AppHarness.make()
        try await harness.openSocket()

        await stubRoster(harness, [RosterWire.profileRow(name: "scout", lastActive: 1_700_000_000)])
        await harness.app.bots.refresh()
        XCTAssertEqual(harness.app.bots.bots.first?.isUnread, false, "precondition: seeded")

        await stubRoster(harness, [RosterWire.profileRow(name: "scout", lastActive: 1_700_009_999)])
        await harness.app.bots.refresh()
        XCTAssertEqual(
            harness.app.bots.bots.first?.isUnread,
            true,
            "the bot said something after the last time this phone looked"
        )

        harness.app.bots.markOpened("scout")
        XCTAssertEqual(harness.app.bots.bots.first?.isUnread, false, "opening it clears the dot")
        XCTAssertEqual(
            harness.app.bots.store.watermark(backend: harness.profileID, profile: "scout"),
            1_700_009_999
        )
        XCTAssertEqual(
            harness.app.bots.lastOpenedProfile,
            "scout",
            "the per-run route memory (§1.9) — Bots mode reopens the last thread on top"
        )

        await stubRoster(harness, [RosterWire.profileRow(name: "scout", lastActive: 1_700_009_999)])
        await harness.app.bots.refresh()
        XCTAssertEqual(
            harness.app.bots.bots.first?.isUnread,
            false,
            "the watermark is persisted, so a later poll must not resurrect a dot the user cleared"
        )

        await harness.tearDown()
    }

    /// Backing out of a thread the user just read must not mark it unread on
    /// the way out. `releaseChats` publishes the on-screen routes and the
    /// roster keeps the watermark moving while a thread is up.
    func testAnOnScreenBotThreadIsNeverUnread() async throws {
        let harness = await AppHarness.make()
        try await harness.openSocket()

        await stubRoster(harness, [RosterWire.profileRow(name: "scout", lastActive: 1_700_000_000)])
        await harness.app.bots.refresh()

        harness.app.releaseChats(keeping: ["bot:scout"])
        XCTAssertEqual(harness.app.bots.onScreenProfiles, ["scout"])

        await stubRoster(harness, [RosterWire.profileRow(name: "scout", lastActive: 1_700_009_999)])
        await harness.app.bots.refresh()
        XCTAssertEqual(
            harness.app.bots.bots.first?.isUnread,
            false,
            "the user is looking at the thread as the reply lands"
        )

        // Back out. The reply is already read, so nothing is owed.
        harness.app.releaseChats(keeping: [])
        await stubRoster(harness, [RosterWire.profileRow(name: "scout", lastActive: 1_700_009_999)])
        await harness.app.bots.refresh()
        XCTAssertEqual(
            harness.app.bots.bots.first?.isUnread,
            false,
            "leaving a conversation you just read must not mark it unread behind you"
        )

        await harness.tearDown()
    }

    // MARK: Groups

    func testHasDesktopGroupsReadsTheDefaultProfilesUIMeta() async throws {
        let harness = await AppHarness.make()
        try await harness.openSocket()

        await stubRoster(harness, [
            RosterWire.profileRow(
                name: "default",
                isDefault: true,
                uiMeta: .object([
                    "hermes-bots-groups": .object([
                        "rooms": .object(["standup": .object(["members": .array([])])]),
                    ]),
                ])
            ),
            RosterWire.profileRow(name: "scout"),
        ])
        await harness.app.bots.refresh()

        XCTAssertTrue(
            harness.app.bots.hasDesktopGroups,
            "one footnote row — there is no group primitive on this backend to call"
        )

        await stubRoster(harness, [RosterWire.profileRow(name: "default", isDefault: true)])
        await harness.app.bots.refresh()
        XCTAssertFalse(
            harness.app.bots.hasDesktopGroups,
            "with no rooms there is nothing to say, so nothing is said"
        )

        await harness.tearDown()
    }

    // MARK: Errors

    func testARosterFailureSurfacesAnErrorWithoutEmptyingTheList() async throws {
        let harness = await AppHarness.make()
        try await harness.openSocket()

        await stubRoster(harness, [RosterWire.profileRow(name: "scout", lastActive: 1_700_000_000)])
        await harness.app.bots.refresh()
        XCTAssertEqual(harness.app.bots.bots.count, 1, "precondition")

        await harness.backend.failRPC("profiles.list", code: 5061, message: "roster unavailable")
        await harness.app.bots.refresh()

        XCTAssertEqual(harness.app.bots.error, "roster unavailable")
        XCTAssertEqual(
            harness.app.bots.bots.count,
            1,
            "a failed poll blanks the roster only if it overwrites it — the last good list is "
                + "still the best thing to show under the error line"
        )

        await harness.tearDown()
    }
}
