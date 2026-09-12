import XCTest

@testable import HermesServeKit

/// The six-group Sessions-mode derivation (01-SCREEN-SPECS §3).
final class SessionGroupingTests: XCTestCase {

    private func summary(
        id: String,
        source: String = "cli",
        lastActive: Double = 1_000,
        isActive: Bool = false,
        archived: Bool = false,
        pinned: Bool = false
    ) -> SessionSummary {
        SessionSummary(json: .object([
            "id": .string(id),
            "source": .string(source),
            "last_active": .number(lastActive),
            "is_active": .bool(isActive),
            "archived": .bool(archived),
            "pinned": .bool(pinned),
        ]))
    }

    func testFixedOrderAndMembership() {
        let groups = HistoryGrouping.groups(from: [
            summary(id: "cli-1", source: "cli"),
            summary(id: "tg-1", source: "telegram", lastActive: 500),
            summary(id: "live-1", source: "desktop", isActive: true),
            summary(id: "pin-1", source: "cli", pinned: true),
            summary(id: "cron-1", source: "cron"),
            summary(id: "arch-1", source: "cli", archived: true),
            summary(id: "dc-1", source: "discord", lastActive: 900),
        ])

        XCTAssertEqual(groups.map(\.id), [
            "pinned", "live", "recents", "platform-discord", "platform-telegram", "cron", "archived",
        ])
        XCTAssertEqual(groups[0].sessions.map(\.id), ["pin-1"])
        XCTAssertEqual(groups[1].sessions.map(\.id), ["live-1"])
        XCTAssertEqual(groups[2].sessions.map(\.id), ["cli-1"])
    }

    func testEmptyGroupsAreRemovedNotRenderedAsZero() {
        let groups = HistoryGrouping.groups(from: [summary(id: "only", source: "tui")])
        XCTAssertEqual(groups.map(\.id), ["recents"])
    }

    func testArchivedIsExclusiveEvenWhenPinnedOrLive() {
        let groups = HistoryGrouping.groups(from: [
            summary(id: "both", source: "cli", isActive: true, archived: true, pinned: true)
        ])
        XCTAssertEqual(groups.map(\.id), ["archived"])
    }

    func testPinnedOutranksLive() {
        let groups = HistoryGrouping.groups(from: [
            summary(id: "pl", source: "cli", isActive: true, pinned: true)
        ])
        XCTAssertEqual(groups.map(\.id), ["pinned"])
    }

    func testUnknownSourceLandsInRecentsAndBeautifies() {
        let groups = HistoryGrouping.groups(from: [summary(id: "x", source: "weird_thing")])
        XCTAssertEqual(groups.map(\.id), ["recents"])
        XCTAssertEqual(SessionSource.label("weird_thing"), "Weird Thing")
        XCTAssertEqual(SessionSource.label("bluebubbles"), "iMessage")
        XCTAssertNil(SessionSource.label("  "))
    }

    func testPlatformGroupsOrderByMostRecentActivity() {
        let groups = HistoryGrouping.groups(from: [
            summary(id: "s1", source: "slack", lastActive: 100),
            summary(id: "t1", source: "telegram", lastActive: 900),
            summary(id: "s2", source: "slack", lastActive: 950),
        ])
        XCTAssertEqual(groups.map(\.id), ["platform-slack", "platform-telegram"])
    }

    func testOnlyRecentsIsMixed() {
        XCTAssertTrue(SessionGroup(kind: .recents, title: "Recents", sessions: [], defaultExpanded: true).isMixed)
        XCTAssertFalse(SessionGroup(kind: .platform("telegram"), title: "Telegram", sessions: [], defaultExpanded: false).isMixed)
    }

    /// Our own source tag is first-party: Recents membership, proper label —
    /// without the map entry the fallback beautifier shipped "Ios" (seen live).
    func testOwnSourceTagIsLocalAndLabelledIOS() {
        let groups = HistoryGrouping.groups(from: [summary(id: "x", source: "ios")])
        XCTAssertEqual(groups.map(\.id), ["recents"])
        XCTAssertEqual(SessionSource.label("ios"), "iOS")
    }
}
