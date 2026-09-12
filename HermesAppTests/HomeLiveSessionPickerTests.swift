import Foundation
import HermesServeKit
import XCTest

@testable import HermesMobile

/// One `session.active_list` row. Free-standing because `ScriptedBackend.stub`
/// runs its closure off the main actor and this class is `@MainActor`.
private enum PickerWire {
    static func row(
        id: String,
        key: String,
        title: String,
        status: String = "working",
        lastActive: Double
    ) -> JSONValue {
        .object([
            "id": .string(id),
            "session_key": .string(key),
            "title": .string(title),
            "preview": .string("…"),
            "status": .string(status),
            "last_active": .number(lastActive),
        ])
    }
}

/// FEAT-026 — the Home live dot lists what is running.
///
/// The dot lights because `session.active_list` is non-empty. Tapping it used
/// to open a settings page about Lock Screen cards (FEAT-011, the interim
/// destination); it now opens the sessions themselves.
///
/// Everything here asserts on the **row source and the destination**, never on
/// a view: a Box-hosted test of the sheet would pass on a picker that listed
/// one session out of five, which is exactly the mistake `continueRows()`
/// invites.
@MainActor
final class HomeLiveSessionPickerTests: XCTestCase {

    /// The point of the item. `continueRows()` is capped at one live row plus
    /// one recent one, so the picker cannot be built on it.
    func testThePickerListsEveryRunningSessionWhereContinueCapsAtOne() async throws {
        let harness = await AppHarness.make()
        try await harness.openSocket()
        let now = Date().timeIntervalSince1970

        await harness.backend.stub("session.active_list") { _ in
            .object(["sessions": .array([
                PickerWire.row(id: "rt-a", key: "stored-a", title: "Parser refactor", lastActive: now),
                PickerWire.row(id: "rt-b", key: "stored-b", title: "Nightly sweep", lastActive: now - 10),
                PickerWire.row(id: "rt-c", key: "stored-c", title: "Desktop run", status: "waiting", lastActive: now - 20),
            ])])
        }
        await harness.app.refreshThreads(force: true)

        XCTAssertEqual(
            harness.app.liveActiveIDs,
            ["stored-a", "stored-b", "stored-c"],
            "precondition: all three really are running, so a short list is a cap and not an absence"
        )
        XCTAssertEqual(
            harness.app.continueRows().count,
            1,
            "precondition: the Continue strip shows one live row — the reason it is the wrong source"
        )
        XCTAssertEqual(
            LiveSessionPicker.rows(harness.app).map(\.id),
            ["stored-a", "stored-b", "stored-c"],
            "the dot promises the sessions that are running; a picker built on continueRows() would show one of them"
        )

        await harness.tearDown()
    }

    /// Newest first, so the session the user just left is the first thing their
    /// thumb reaches. `liveStatuses` is a dictionary and has no order at all.
    func testRowsAreOrderedNewestFirst() async throws {
        let harness = await AppHarness.make()
        try await harness.openSocket()
        let now = Date().timeIntervalSince1970

        await harness.backend.stub("session.active_list") { _ in
            .object(["sessions": .array([
                PickerWire.row(id: "rt-old", key: "stored-old", title: "Started this morning", lastActive: now - 3600),
                PickerWire.row(id: "rt-new", key: "stored-new", title: "Started a moment ago", lastActive: now),
                PickerWire.row(id: "rt-mid", key: "stored-mid", title: "Started an hour in", lastActive: now - 60),
            ])])
        }
        await harness.app.refreshThreads(force: true)

        XCTAssertEqual(
            LiveSessionPicker.rows(harness.app).map(\.id),
            ["stored-new", "stored-mid", "stored-old"],
            "wire order is the gateway's business and dictionary order is nobody's — the list is ordered by last_active"
        )

        await harness.tearDown()
    }

    /// `session.active_list` applies no hidden filter and no profile filter, so
    /// a running Bot Chat arrives on this list titled "Bot Chat" — Bots mode's
    /// plumbing offered on Sessions Home as a conversation the user never
    /// started.
    func testARunningBotChatIsNotOfferedAsASession() async throws {
        let harness = await AppHarness.make()
        try await harness.openSocket()
        let now = Date().timeIntervalSince1970

        await harness.backend.stub("session.active_list") { _ in
            .object(["sessions": .array([
                PickerWire.row(id: "rt-bot", key: "stored-bot", title: "Bot Chat", lastActive: now),
                PickerWire.row(id: "rt-real", key: "stored-real", title: "Parser refactor", lastActive: now - 5),
            ])])
        }
        await harness.app.refreshThreads(force: true)

        XCTAssertTrue(
            harness.app.isLiveWorking("stored-bot"),
            "precondition: the Bot Chat really is running, so this is a filter and not an absence"
        )
        XCTAssertEqual(
            LiveSessionPicker.rows(harness.app).map(\.id),
            ["stored-real"],
            "the same filter hubSessions and continueRows already make; a bot's forever-chat is not a session Home offers"
        )

        await harness.tearDown()
    }

    /// The pin is the other half of the filter: compression moves the title to
    /// the tip and leaves the row that is live with none.
    func testAPinnedBotChatIsNotOfferedEvenWithoutTheTitle() async throws {
        let harness = await AppHarness.make()
        try await harness.openSocket()
        harness.app.bots.store.setPin("stored-compressed", backend: harness.profileID, profile: "scout")
        let now = Date().timeIntervalSince1970

        await harness.backend.stub("session.active_list") { _ in
            .object(["sessions": .array([
                PickerWire.row(id: "rt-c", key: "stored-compressed", title: "", lastActive: now),
            ])])
        }
        await harness.app.refreshThreads(force: true)

        XCTAssertTrue(LiveSessionPicker.rows(harness.app).isEmpty)

        await harness.tearDown()
    }

    /// The list and the dot must agree about what "running" means. Both are the
    /// `working || waiting` set; an `idle` row in the payload is neither.
    func testAnIdleSessionIsNotOffered() async throws {
        let harness = await AppHarness.make()
        try await harness.openSocket()
        let now = Date().timeIntervalSince1970

        await harness.backend.stub("session.active_list") { _ in
            .object(["sessions": .array([
                PickerWire.row(id: "rt-idle", key: "stored-idle", title: "Finished a while ago", status: "idle", lastActive: now),
                PickerWire.row(id: "rt-live", key: "stored-live", title: "Still going", lastActive: now - 5),
            ])])
        }
        await harness.app.refreshThreads(force: true)

        XCTAssertTrue(
            harness.app.hasVisibleLiveSession,
            "precondition: the dot is lit, so the picker is reachable"
        )
        XCTAssertEqual(
            LiveSessionPicker.rows(harness.app).map(\.id),
            ["stored-live"],
            "liveStatuses carries idle rows too — the picker must list the set the dot is counted from"
        )

        await harness.tearDown()
    }

    /// BUG-054. Opening a picked session **replaces** the stack rather than
    /// pushing onto it, so Back from the conversation is Home and nothing the
    /// user never asked for sits in between.
    func testOpeningARowReplacesTheStackSoBackFromTheChatIsHome() {
        let session = SessionSummary(json: .object([
            "id": .string("stored-a"),
            "title": .string("Parser refactor"),
            "last_active": .number(Date().timeIntervalSince1970),
        ]))
        var path: [AppRoute] = [.commandCenter, .settings]

        LiveSessionPicker.open(session, path: &path)

        XCTAssertEqual(
            path.count,
            1,
            "an absolute jump, not an append — an appended route is a Back button that lands somewhere the user never chose"
        )
        XCTAssertEqual(path.first?.threadRouteKey, "existing:stored-a")
    }
}
