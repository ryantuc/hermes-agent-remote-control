import Foundation
import HermesServeKit
import XCTest

@testable import HermesMobile

/// BUG-172, the notification half. The backend deny-resolves pending approvals on its own (a Stop from another client, an orphan reap, an idle reclaim) and says so with `approval.cancelled` (`tui_gateway/contracts/events.py` `ApprovalCancelledPayload`; the envelope's `session_id` is empty and the session is named only in the payload). BUG-168 made the engine withdraw the card; this pins that the phone's local "Hermes needs approval" notification for that session goes with it, and that it stays while another approval in the same session is still open.
///
/// As in `PromptNotificationTests`, a test host is never granted notification authorisation, so what is assertable is the roster `ApprovalNotifications` keeps of what each session is blocked on, which is what `clear(sessionID:)` empties.
@MainActor
final class ApprovalCancelledNotificationTests: XCTestCase {

    override func setUp() {
        super.setUp()
        ApprovalNotifications.resetForTesting()
    }

    override func tearDown() {
        ApprovalNotifications.resetForTesting()
        ApprovalActivityBridge.handler = LiveActivityController.shared
        super.tearDown()
    }

    private func makeHarness() async throws -> AppHarness {
        let harness = await AppHarness.make()
        await harness.backend.setSessionMirroring(true)
        let controller = LiveActivityController(surface: FakeLiveActivitySurface())
        harness.app.liveActivities = controller
        controller.install(app: harness.app)
        try await harness.openSocket()
        // Off screen, the state in which a notification is actually armed.
        ApprovalNotifications.isActiveOverrideForTesting = false
        return harness
    }

    private func approval(_ harness: AppHarness, session: String, id: String, command: String) async {
        await harness.backend.emit("approval.request", sessionID: session, payload: .object([
            "request_id": .string(id),
            "command": .string(command),
            "description": .string("synthetic"),
        ]))
    }

    private func cancel(_ harness: AppHarness, session: String, ids: [String]) async {
        await harness.backend.emit("approval.cancelled", sessionID: "", payload: .object([
            "session_id": .string(session),
            "stored_session_id": .string("20261003_010000_abcdef"),
            "reason": .string("interrupt"),
            "cancelled_count": .number(Double(ids.count)),
            "request_ids": .array(ids.map { .string($0) }),
        ]))
    }

    func testACancelledApprovalTakesItsNotificationWithIt() async throws {
        let harness = try await makeHarness()
        let session = "cancel-notify"
        await harness.backend.emit("message.start", sessionID: session)
        await approval(harness, session: session, id: "aaa", command: "rm -rf build")
        let armed = await waitUntil { ApprovalNotifications.pendingPromptsForTesting[session] == .approval }
        XCTAssertTrue(armed, "precondition: the approval never reached the notification roster")

        await cancel(harness, session: session, ids: ["aaa"])
        let withdrawn = await waitUntil { harness.app.engine.state(for: session).pendingApprovals.isEmpty }
        XCTAssertTrue(withdrawn, "precondition: the engine kept the cancelled approval (BUG-168)")
        let cleared = await waitUntil { ApprovalNotifications.pendingPromptsForTesting[session] == nil }
        XCTAssertTrue(cleared, "the backend cancelled the approval and the phone still holds a \"Hermes needs approval\" notification for it")

        await harness.tearDown()
    }

    func testANotificationStaysWhileAnotherApprovalInTheSessionIsOpen() async throws {
        let harness = try await makeHarness()
        let session = "cancel-one-of-two"
        await harness.backend.emit("message.start", sessionID: session)
        await approval(harness, session: session, id: "aaa", command: "rm -rf build")
        await approval(harness, session: session, id: "bbb", command: "git push --force")
        let queued = await waitUntil { harness.app.engine.state(for: session).pendingApprovals.count == 2 }
        XCTAssertTrue(queued, "precondition: both approvals should be queued")

        let armedBefore = armings(for: session)
        XCTAssertGreaterThan(armedBefore, 0, "precondition: off screen, the open approval should have armed a notification")

        await cancel(harness, session: session, ids: ["aaa"])
        let one = await waitUntil { harness.app.engine.state(for: session).pendingApprovals.count == 1 }
        XCTAssertTrue(one, "precondition: exactly one approval should be withdrawn")
        await settle()
        XCTAssertEqual(ApprovalNotifications.pendingPromptsForTesting[session], .approval,
                       "one approval is still waiting, so its notification must stay")
        // A blanket clear on the event would be re-armed by the very next reconcile, buzzing the phone a second time for an approval it already announced.
        XCTAssertEqual(armings(for: session), armedBefore, "cancelling one of two approvals re-armed the notification for the one still open")

        await harness.tearDown()
    }

    private func armings(for sessionID: String) -> Int {
        ApprovalNotifications.armedForTesting.filter { $0.sessionID == sessionID }.count
    }

    private func settle() async {
        try? await Task.sleep(nanoseconds: 400_000_000)
    }
}
