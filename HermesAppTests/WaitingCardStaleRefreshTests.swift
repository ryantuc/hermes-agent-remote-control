import Foundation
import HermesServeKit
import XCTest

@testable import HermesMobile

/// Every push gives a Live Activity a stale date five minutes out (`LiveActivityDerivation.staleWindow`), after which the card greys out as "No longer updating". A session parked on a question sends nothing more until it is answered, and the controller never re-pushed an unchanged snapshot, so a waiting card greyed out at five minutes while the backend keeps a question open for ten (`clarify_timeout` 600 s) and the app was alive and watching it. While the app runs, a waiting card is now re-pushed with a fresh stale date before the old one passes; when the app is suspended nothing re-pushes it, and grey is then the truth.
@MainActor
final class WaitingCardStaleRefreshTests: XCTestCase {
    private static let waitingLine = "Waiting for your answer"

    @MainActor
    private struct Rig {
        let harness: AppHarness
        let fake: FakeLiveActivitySurface
        let controller: LiveActivityController
        let saved: (enabled: Bool, cron: Bool, lockScreen: Bool, island: Bool, policy: LiveActivityShowPolicy)

        func tearDown() async {
            await harness.tearDown()
            LiveActivityPreferences.enabled = saved.enabled
            LiveActivityPreferences.autoStartForCron = saved.cron
            LiveActivityPreferences.lockScreen = saved.lockScreen
            LiveActivityPreferences.island = saved.island
            LiveActivityPreferences.showPolicy = saved.policy
            ApprovalActivityBridge.handler = LiveActivityController.shared
        }
    }

    private func makeRig() async throws -> Rig {
        let saved = (
            enabled: LiveActivityPreferences.enabled,
            cron: LiveActivityPreferences.autoStartForCron,
            lockScreen: LiveActivityPreferences.lockScreen,
            island: LiveActivityPreferences.island,
            policy: LiveActivityPreferences.showPolicy
        )
        LiveActivityPreferences.enabled = true
        LiveActivityPreferences.autoStartForCron = true
        LiveActivityPreferences.lockScreen = true
        LiveActivityPreferences.island = true
        LiveActivityPreferences.showPolicy = .everyTurn

        let harness = await AppHarness.make(handlesServerRequests: true)
        await harness.backend.setSessionMirroring(true)
        await harness.backend.stub("client.capabilities") { _ in
            .object(["server_requests": .array([.string("approval"), .string("clarify"), .string("sudo"), .string("secret")])])
        }
        let fake = FakeLiveActivitySurface()
        let controller = LiveActivityController(surface: fake)
        // Seconds instead of minutes, so the test can watch a refresh happen.
        controller.waitingRefreshInterval = 0.6
        harness.app.liveActivities = controller
        controller.install(app: harness.app)
        try await harness.openSocket()
        return Rig(harness: harness, fake: fake, controller: controller, saved: saved)
    }

    private func startTurn(_ rig: Rig, sessionID: String) async throws -> FakeLiveActivityHandle {
        await rig.harness.backend.emitAssistantText("checking the deploy", sessionID: sessionID)
        await rig.harness.backend.emit("tool.start", sessionID: sessionID, payload: .object([
            "tool_id": .string("t-\(sessionID)"), "name": .string("clarify"), "context": .string("Which branch?"),
        ]))
        let carded = await waitUntil { rig.fake.handle(for: sessionID) != nil }
        XCTAssertTrue(carded, "precondition: the turn never put a card up")
        return try XCTUnwrap(rig.fake.handle(for: sessionID))
    }

    /// The headline: a card parked on a question, with nothing else happening, is pushed again with a later stale date before the old one passes.
    func testAParkedCardIsRepushedWithAFreshStaleDateWhileTheQuestionIsOpen() async throws {
        let rig = try await makeRig()
        let handle = try await startTurn(rig, sessionID: "cron-parked")

        await rig.harness.backend.emitServerRequest(id: "srq-parked", method: "clarify", sessionID: "cron-parked",
                                                    params: ["question": .string("Which branch?")])
        let parked = await waitUntil(timeout: 3) { handle.lastContent?.statusText == Self.waitingLine }
        XCTAssertTrue(parked, "precondition: the card never said it was waiting: \(handle.describeContent)")
        let pushesWhenParked = handle.pushed.count
        let staleWhenParked = try XCTUnwrap(handle.staleDates.last ?? nil, "precondition: the parked push carried no stale date")

        let refreshed = await waitUntil(timeout: 4) { handle.pushed.count > pushesWhenParked }
        XCTAssertTrue(refreshed, "nothing re-pushed the parked card, so it greys out at its stale date while the question is still open")
        let staleAfter = try XCTUnwrap(handle.staleDates.last ?? nil)
        XCTAssertGreaterThan(staleAfter, staleWhenParked, "the re-push did not move the stale date")
        XCTAssertEqual(handle.lastContent?.statusText, Self.waitingLine, "the refresh changed what the card says")

        await rig.tearDown()
    }

    /// The rule on plain values: only a card waiting on a person, and only once its last push is about as old as the interval.
    func testARefreshIsDueOnlyForAWaitingCardNearTheEndOfItsInterval() {
        let now = Date()
        var waiting = LiveActivitySnapshot(title: "Deploy", startedAt: now)
        waiting = ParkedQuestion.applying(.answer, to: waiting)
        let running = LiveActivitySnapshot(title: "Deploy", startedAt: now)
        XCTAssertTrue(LiveActivityController.staleRefreshDue(waiting, lastPushAt: now.addingTimeInterval(-240), interval: 240, now: now))
        XCTAssertFalse(LiveActivityController.staleRefreshDue(waiting, lastPushAt: now.addingTimeInterval(-60), interval: 240, now: now))
        XCTAssertFalse(LiveActivityController.staleRefreshDue(running, lastPushAt: now.addingTimeInterval(-240), interval: 240, now: now),
                       "a running card is not waiting on anyone; its own events keep it fresh")
        XCTAssertFalse(LiveActivityController.staleRefreshDue(waiting, lastPushAt: nil, interval: 240, now: now))
        XCTAssertLessThan(LiveActivityController(surface: FakeLiveActivitySurface()).waitingRefreshInterval, LiveActivityDerivation.staleWindow,
                          "the refresh must land before the stale date it is meant to beat")
    }

    /// The control: a running card with nothing waiting is not re-pushed on a timer; ActivityKit budgets updates, and a turn that is working sends its own events.
    func testARunningCardWithNothingWaitingIsNotRepushed() async throws {
        let rig = try await makeRig()
        let handle = try await startTurn(rig, sessionID: "cron-running")
        _ = await waitUntil(timeout: 1.5) { false }
        let settledCount = handle.pushed.count

        _ = await waitUntil(timeout: 2) { false }
        XCTAssertEqual(handle.pushed.count, settledCount, "a card with nothing waiting was re-pushed with no change: \(handle.describeContent)")

        await rig.tearDown()
    }
}
