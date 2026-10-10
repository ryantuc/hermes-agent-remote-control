import Foundation
import HermesServeKit
import XCTest

@testable import HermesMobile

/// BUG-166. Home's Continue strip keeps one running row and the most recent thread (`AppModel.continueRows()`). The running slot went to whichever live session came first out of a dictionary, so with several live sessions where only one was waiting on the person holding the phone, the strip could show a session that needed nothing and leave the waiting one off Home entirely. The registry is the authority on waiting (`WaitingSessions`, BUG-062 C), and a waiting session takes the running slot.
@MainActor
final class ContinueStripWaitingTests: XCTestCase {

    override func tearDown() {
        ApprovalActivityBridge.handler = LiveActivityController.shared
        super.tearDown()
    }

    private func liveRow(_ n: Int, status: String = "working", lastActive: Double) -> JSONValue {
        .object([
            "id": .string("rt-\(n)"), "session_key": .string("stored-\(n)"), "title": .string("Live \(n)"),
            "status": .string(status), "last_active": .number(lastActive),
        ])
    }

    private func makeHarness(activeList: JSONValue) async throws -> AppHarness {
        let harness = await AppHarness.make(handlesServerRequests: true)
        await harness.backend.stub("client.capabilities") { _ in
            .object(["server_requests": .array([.string("approval"), .string("clarify"), .string("sudo"), .string("secret")])])
        }
        await harness.backend.stub("session.active_list") { _ in activeList }
        let controller = LiveActivityController(surface: FakeLiveActivitySurface())
        harness.app.liveActivities = controller
        controller.install(app: harness.app)
        try await harness.openSocket()
        return harness
    }

    /// Nine live sessions, the oldest of them parked on an approval. Before the fix the running slot was `liveStatuses.values.first`, so this failed whenever the dictionary did not happen to put the parked one first (eight times in nine).
    func testTheWaitingSessionTakesTheRunningSlot() async throws {
        let now = Date().timeIntervalSince1970
        let rows = (1...9).map { liveRow($0, lastActive: now - Double($0)) }
        let harness = try await makeHarness(activeList: .object(["sessions": .array(rows)]))
        let joined = await waitUntil { harness.app.liveStatuses.count == 9 }
        XCTAssertTrue(joined, "precondition: the active list never landed")

        await harness.backend.emitServerRequest(id: "srq-parked", method: "approval", sessionID: "rt-9", params: [
            "request_id": .string("queue-parked"), "command": .string("echo synthetic"),
            "choices": .array([.string("once"), .string("deny")]),
        ])
        let registered = await waitUntil { harness.app.liveActivities.waiting.byStoredID["stored-9"] == .approval }
        XCTAssertTrue(registered, "precondition: the registry never recorded the approval against its row")

        let strip = harness.app.continueRows().map(\.id)
        XCTAssertEqual(strip.first, "stored-9", "the session waiting on an answer is not in Home's running slot; the strip shows \(strip)")

        await harness.tearDown()
    }

    /// With nothing waiting, the running slot is the most recently active live session, every time, rather than the dictionary's choice.
    func testWithNothingWaitingTheMostRecentLiveSessionRuns() async throws {
        let now = Date().timeIntervalSince1970
        let rows = (1...9).map { liveRow($0, lastActive: now - Double(10 - $0)) }
        let harness = try await makeHarness(activeList: .object(["sessions": .array(rows)]))
        let joined = await waitUntil { harness.app.liveStatuses.count == 9 }
        XCTAssertTrue(joined, "precondition: the active list never landed")

        XCTAssertEqual(harness.app.continueRows().first?.id, "stored-9")

        await harness.tearDown()
    }
}
