import Foundation
import HermesServeKit
import XCTest

@testable import HermesMobile

/// One `session.active_list` row. Free-standing because `ScriptedBackend.stub`
/// runs its closure off the main actor and this class is `@MainActor`.
private enum LiveWire {
    static func liveRow(
        id: String,
        key: String,
        title: String,
        status: String = "working"
    ) -> JSONValue {
        .object([
            "id": .string(id),
            "session_key": .string(key),
            "title": .string(title),
            "preview": .string("…"),
            "status": .string(status),
            "last_active": .number(Date().timeIntervalSince1970),
        ])
    }
}

/// Sessions mode stays clean.
///
/// REST cannot leak a Bot Chat: `GET /api/sessions` hard-wires
/// `include_hidden=False` and a Bot Chat is born hidden. `session.active_list`
/// can, and does — it applies no hidden filter and no
/// profile filter at all, and a Bot Chat whose kickoff is still streaming
/// carries `title == "Bot Chat"` from the create's `pending_title` placeholder
/// (`tui_gateway/server.py:9365-9373`). So the leak is exactly one row wide and
/// it is a *running* one, which is the row Home's Continue strip promotes to
/// the top of the screen.
@MainActor
final class BotsLeakFilterTests: XCTestCase {

    /// The running Bot Chat goes; the ghost `HubGhostSessionTests` depends on
    /// stays. Both arrive through the same unfiltered `session.active_list`.
    func testARunningBotChatIsExcludedWhileTheGhostSurvives() async throws {
        let harness = await AppHarness.make()
        try await harness.openSocket()

        await harness.backend.stub("session.active_list") { _ in
            .object(["sessions": .array([
                LiveWire.liveRow(id: "rt-bot", key: "stored-bot", title: "Bot Chat"),
                LiveWire.liveRow(id: "rt-ghost", key: "stored-ghost", title: "Desktop run"),
            ])])
        }
        await harness.app.refreshThreads(force: true)

        XCTAssertTrue(
            harness.app.isLiveWorking("stored-bot"),
            "precondition: the Bot Chat really is live, so this is a filter and not an absence"
        )
        XCTAssertFalse(
            harness.app.hubSessions.contains { $0.id == "stored-bot" },
            "a bot's forever-chat appeared in the Sessions hub titled \"Bot Chat\" — Bots mode's "
                + "plumbing showing up as a conversation the user never started"
        )
        XCTAssertTrue(
            harness.app.hubSessions.contains { $0.id == "stored-ghost" },
            "the filter must be exactly one title wide; a working session with no persisted row "
                + "is the whole point of BUG-028"
        )
        XCTAssertFalse(harness.app.continueRows().contains { $0.id == "stored-bot" })
        XCTAssertEqual(
            harness.app.continueRows().first?.id,
            "stored-ghost",
            "Home's Continue strip promotes the running session — it must promote the real one"
        )

        await harness.tearDown()
    }

    /// After the first compression the title moves off the row that is live, so
    /// the title check alone stops working. The pin is the other half.
    func testAPinnedBotChatIsExcludedEvenWithoutTheTitle() async throws {
        let harness = await AppHarness.make()
        try await harness.openSocket()
        harness.app.bots.store.setPin("stored-compressed", backend: harness.profileID, profile: "scout")

        await harness.backend.stub("session.active_list") { _ in
            .object(["sessions": .array([
                LiveWire.liveRow(id: "rt-c", key: "stored-compressed", title: ""),
            ])])
        }
        await harness.app.refreshThreads(force: true)

        XCTAssertFalse(
            harness.app.hubSessions.contains { $0.id == "stored-compressed" },
            "compression moves the title from the root to the tip and leaves the root NULL, so a "
                + "filter keyed on the title alone stops catching a chat the moment it is compressed"
        )

        await harness.tearDown()
    }

    /// A pin belongs to the backend that minted it. It must not silence a row
    /// on a different one.
    func testAnotherBackendsPinDoesNotFilterThisBackendsRows() async throws {
        let harness = await AppHarness.make()
        try await harness.openSocket()
        harness.app.bots.store.setPin("stored-elsewhere", backend: UUID(), profile: "scout")

        await harness.backend.stub("session.active_list") { _ in
            .object(["sessions": .array([
                LiveWire.liveRow(id: "rt-x", key: "stored-elsewhere", title: "A real conversation"),
            ])])
        }
        await harness.app.refreshThreads(force: true)

        XCTAssertTrue(
            harness.app.hubSessions.contains { $0.id == "stored-elsewhere" },
            "session ids are only meaningful on the state.db that minted them; a pin from another "
                + "machine colliding with this one's id would hide a real conversation"
        )

        await harness.tearDown()
    }

    /// The filter is an exact-title match, not a prefix or a contains.
    func testATitleThatMerelyMentionsBotChatIsKept() async throws {
        let harness = await AppHarness.make()
        try await harness.openSocket()

        await harness.backend.stub("session.active_list") { _ in
            .object(["sessions": .array([
                LiveWire.liveRow(id: "rt-1", key: "stored-1", title: "Bot Chat notes"),
                LiveWire.liveRow(id: "rt-2", key: "stored-2", title: "bot chat"),
            ])])
        }
        await harness.app.refreshThreads(force: true)

        XCTAssertTrue(harness.app.hubSessions.contains { $0.id == "stored-1" })
        XCTAssertTrue(
            harness.app.hubSessions.contains { $0.id == "stored-2" },
            "the canonical title is the exact string the UNIQUE index protects; a case-insensitive "
                + "or substring match would hide the user's own conversations"
        )

        await harness.tearDown()
    }
}
