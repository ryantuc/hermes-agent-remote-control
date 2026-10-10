import Foundation
import HermesServeKit
import XCTest

@testable import HermesMobile

/// A connector sign-in card (`connection.request`) stops the turn on the person until they sign in, skip or continue, up to the backend's 300 s deadline (`tools/connectors/operation.py:14`). The card is deliberately not an approval-sheet prompt, so nothing that announces a waiting turn heard about it: no notification with the phone locked, and the Lock Screen card kept reading as a running turn.
@MainActor
final class ConnectorSignInAlertTests: XCTestCase {
    private static let signInLine = "Waiting for you to sign in"

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
            ApprovalNotifications.resetForTesting()
        }
    }

    private func makeRig(policy: LiveActivityShowPolicy = .everyTurn) async throws -> Rig {
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
        LiveActivityPreferences.showPolicy = policy
        ApprovalNotifications.resetForTesting()
        // A test host is always active, the one state in which nothing is posted.
        ApprovalNotifications.isActiveOverrideForTesting = false

        let harness = await AppHarness.make(handlesServerRequests: true)
        await harness.backend.setSessionMirroring(true)
        let fake = FakeLiveActivitySurface()
        let controller = LiveActivityController(surface: fake)
        harness.app.liveActivities = controller
        controller.install(app: harness.app)
        try await harness.openSocket()
        return Rig(harness: harness, fake: fake, controller: controller, saved: saved)
    }

    private func request(op: String) -> JSONValue {
        .object([
            "op_id": .string(op), "seq": .number(1), "deadline_at": .number(Date().timeIntervalSince1970 + 300),
            "timeout_seconds": .number(300), "tool_call_id": .string("call_1"),
            "targets": .array([
                .object(["name": .string("github"), "kind": .string("connector"), "action": .string("connect"),
                         "state": .string("pending"), "connect_url": .string("https://connect.example.com/gh")]),
            ]),
        ])
    }

    private func armings(_ sessionID: String) -> Int {
        ApprovalNotifications.armedForTesting.filter { $0.sessionID == sessionID }.count
    }

    /// The headline: with the phone locked, a sign-in card raises a notification and the Lock Screen card says it is waiting on the person.
    func testASignInCardRaisesANotificationAndParksTheCard() async throws {
        let rig = try await makeRig()
        let sid = "cron-connect"
        await rig.harness.backend.emitAssistantText("connecting to GitHub", sessionID: sid)
        let carded = await waitUntil { rig.fake.handle(for: sid) != nil }
        XCTAssertTrue(carded, "precondition: the turn never put a card up")
        let handle = try XCTUnwrap(rig.fake.handle(for: sid))
        XCTAssertEqual(armings(sid), 0, "precondition: a running turn alone woke the phone")

        await rig.harness.backend.emit("connection.request", sessionID: sid, payload: request(op: "op-lock"))
        let open = await waitUntil { rig.harness.app.engine.state(for: sid).connection != nil }
        XCTAssertTrue(open, "precondition: the sign-in card never reached the engine")

        let armed = await waitUntil(timeout: 3) { self.armings(sid) > 0 }
        XCTAssertTrue(armed, "the turn is waiting on a sign-in and nothing tells the person with the phone locked")
        let parked = await waitUntil(timeout: 3) { handle.lastContent?.statusText == Self.signInLine }
        XCTAssertTrue(parked, "the Lock Screen card still reads as a running turn while it waits on a sign-in: \(handle.describeContent)")
        XCTAssertEqual(handle.lastContent?.approvalToken, "", "a sign-in must never carry an approval token: the card's buttons are approval-only")

        await rig.tearDown()
    }

    /// Once the operation settles (signed in, skipped, continued or past its deadline), the card stops saying it is waiting.
    func testASettledSignInTakesTheWaitingLineOff() async throws {
        let rig = try await makeRig()
        let sid = "cron-connect-settles"
        await rig.harness.backend.emitAssistantText("connecting to GitHub", sessionID: sid)
        _ = await waitUntil { rig.fake.handle(for: sid) != nil }
        let handle = try XCTUnwrap(rig.fake.handle(for: sid))
        await rig.harness.backend.emit("connection.request", sessionID: sid, payload: request(op: "op-settle"))
        _ = await waitUntil(timeout: 3) { handle.lastContent?.statusText == Self.signInLine }

        await rig.harness.backend.emit("connection.update", sessionID: sid, payload: .object([
            "op_id": .string("op-settle"), "seq": .number(3), "deadline_at": .number(0), "settled": .bool(true),
            "settled_by": .string("continue"), "owner": .object(["type": .string("session"), "session_id": .string(sid)]),
            "targets": .array([]),
        ]))
        let settled = await waitUntil { rig.harness.app.engine.state(for: sid).connection == nil }
        XCTAssertTrue(settled, "precondition: the settled operation never reached the engine")
        let cleared = await waitUntil(timeout: 3) { handle.lastContent?.statusText != Self.signInLine }
        XCTAssertTrue(cleared, "the operation settled but the card still says it is waiting: \(handle.describeContent)")
        let unannounced = await waitUntil(timeout: 3) { !ApprovalNotifications.pendingSignInsForTesting.contains(sid) }
        XCTAssertTrue(unannounced, "the sign-in notification outlived the card it announced")

        await rig.tearDown()
    }

    /// A blocking prompt in the same session takes the notification over, and the sign-in does not re-arm under it.
    func testAPromptOutranksASignInInTheSameSession() async throws {
        let rig = try await makeRig()
        let sid = "cron-connect-prompt"
        await rig.harness.backend.emitAssistantText("connecting to GitHub", sessionID: sid)
        _ = await waitUntil { rig.fake.handle(for: sid) != nil }
        await rig.harness.backend.emit("connection.request", sessionID: sid, payload: request(op: "op-both"))
        let signIn = await waitUntil(timeout: 3) { ApprovalNotifications.pendingSignInsForTesting.contains(sid) }
        XCTAssertTrue(signIn, "precondition: the sign-in was never announced")

        ApprovalNotifications.sync(prompts: [sid: .clarify], signIns: [sid])
        XCTAssertEqual(ApprovalNotifications.pendingPromptsForTesting[sid], .clarify)
        XCTAssertFalse(ApprovalNotifications.pendingSignInsForTesting.contains(sid), "the sign-in kept its place under a prompt that outranks it")
        XCTAssertEqual(ApprovalNotifications.armedForTesting.last, ApprovalNotifications.Armed(sessionID: sid, kind: .clarify),
                       "the prompt did not take the banner over")

        await rig.tearDown()
    }
}
