import Foundation
import HermesServeKit
import XCTest

@testable import HermesMobile

/// BUG-028 — a running session that has not persisted its first message is
/// invisible on the hub because the live surfaces are `threads ∩ active_list`
/// and `threads` is loaded with `minMessages: 1`. REST is dead in this
/// harness, so `threads` stays empty: a perfect ghost.
@MainActor
final class HubGhostSessionTests: XCTestCase {

    func testWorkingUnpersistedSessionIsVisibleOnTheHub() async throws {
        let harness = await AppHarness.make()
        try await harness.openSocket()

        await harness.backend.stub("session.active_list") { _ in
            .object(["sessions": .array([
                .object([
                    "id": .string("rt-ghost"),
                    "session_key": .string("stored-ghost"),
                    "title": .string("Just started"),
                    "preview": .string("first prompt in flight"),
                    "status": .string("working"),
                    "last_active": .number(Date().timeIntervalSince1970),
                ]),
            ])])
        }
        await harness.app.refreshThreads(force: true)

        XCTAssertTrue(
            harness.app.isLiveWorking("stored-ghost"),
            "precondition: active_list must have landed"
        )
        XCTAssertTrue(
            harness.app.threads.isEmpty,
            "precondition: REST is dead, so threads cannot supply the row"
        )
        XCTAssertTrue(
            harness.app.hasVisibleLiveSession,
            "HomeView.hasLiveSession is threads.contains(isLiveWorking) — a working session with no persisted row never lights the dot"
        )
        XCTAssertEqual(
            harness.app.continueRows().first?.id,
            "stored-ghost",
            "the Continue strip is also threads-gated, so the running session has no row"
        )

        await harness.tearDown()
    }

    func testContinueStripUsesGatewayStatusWord() async throws {
        let harness = await AppHarness.make()
        try await harness.openSocket()

        await harness.backend.stub("session.active_list") { _ in
            .object(["sessions": .array([
                .object([
                    "id": .string("rt-wait"),
                    "session_key": .string("stored-wait"),
                    "title": .string("Parked on a question"),
                    "status": .string("waiting"),
                    "last_active": .number(Date().timeIntervalSince1970),
                ]),
            ])])
        }
        await harness.app.refreshThreads(force: true)

        XCTAssertTrue(harness.app.isLiveWorking("stored-wait"), "waiting counts as live")
        XCTAssertEqual(
            harness.app.liveWorkingLabel(for: "stored-wait"),
            "waiting",
            "HomeView Continue strip used to hardcode working for every live row"
        )

        await harness.tearDown()
    }

    func testDrawerListIncludesUnpersistedWorkingSession() async throws {
        let harness = await AppHarness.make()
        try await harness.openSocket()

        await harness.backend.stub("session.active_list") { _ in
            .object(["sessions": .array([
                .object([
                    "id": .string("rt-ghost"),
                    "session_key": .string("stored-ghost"),
                    "title": .string("Just started"),
                    "status": .string("working"),
                    "last_active": .number(Date().timeIntervalSince1970),
                ]),
            ])])
        }
        await harness.app.refreshThreads(force: true)

        XCTAssertTrue(harness.app.threads.isEmpty, "precondition: REST list is empty")
        XCTAssertTrue(
            harness.app.hubSessions.contains(where: { $0.id == "stored-ghost" }),
            "HistoryGroupList grouped from threads only, so a ghost session had no drawer row"
        )
        let live = HistoryGrouping.groups(from: harness.app.hubSessions).first(where: { $0.kind == .live })
        XCTAssertEqual(live?.sessions.map(\.id), ["stored-ghost"])

        await harness.tearDown()
    }
}
