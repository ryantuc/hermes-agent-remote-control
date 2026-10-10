import Foundation
import HermesServeKit
import XCTest

@testable import HermesMobile

/// BUG-062 C, Home's half: a Continue row whose session is waiting on the person holding the phone says "Needs your answer".
///
/// The source is the current-request registry, reached through `LiveActivityController.waiting`, which `reconcile` rewrites from every tracked session's projected prompt fields. Not `session.active_list`: its `waiting` word is never reported for an approval-blocked session (`LiveSessionStatus.needsInput`, reference §5.5), and it moves on a 10 to 30 second poll.
///
/// Specification tests for API the fix adds, so they ride with the fix rather than a red commit; the view's own wiring is `HomeView.waitingKind(for:)`, which these call in the same form.
@MainActor
final class HomeWaitingMarkTests: XCTestCase {

    @MainActor
    private struct Rig {
        let harness: AppHarness
        let controller: LiveActivityController

        func tearDown() async {
            await harness.tearDown()
            ApprovalActivityBridge.handler = LiveActivityController.shared
        }

        /// The expression `HomeView.waitingKind(for:)` evaluates for a row.
        func homeKind(storedID: String) -> ApprovalNotifications.PromptKind? {
            controller.waiting.kind(storedID: storedID, runtimeID: harness.app.liveStatus(forStoredID: storedID)?.id)
        }
    }

    private func makeRig(activeList: JSONValue? = nil) async throws -> Rig {
        let harness = await AppHarness.make(handlesServerRequests: true)
        await harness.backend.stub("client.capabilities") { _ in
            .object(["server_requests": .array([.string("approval"), .string("clarify"), .string("sudo"), .string("secret")])])
        }
        if let activeList {
            await harness.backend.stub("session.active_list") { _ in activeList }
        }
        let controller = LiveActivityController(surface: FakeLiveActivitySurface())
        harness.app.liveActivities = controller
        controller.install(app: harness.app)
        try await harness.openSocket()
        return Rig(harness: harness, controller: controller)
    }

    // MARK: - Through the app

    /// The common case: the phone has the chat, the user went back to Home, and the agent asked something.
    func testAnOpenChatsQuestionMarksItsHomeRowUntilItIsWithdrawn() async throws {
        let rig = try await makeRig()
        let chat = rig.harness.chat(storedID: "stored-parked")
        await chat.open()
        let sid = try XCTUnwrap(chat.runtimeSessionID)

        XCTAssertNil(rig.homeKind(storedID: "stored-parked"), "nothing is open yet")
        await rig.harness.backend.emitServerRequest(id: "srq-home", method: "clarify", sessionID: sid,
                                                    params: ["question": .string("Which branch?")])
        let marked = await waitUntil { rig.homeKind(storedID: "stored-parked") == .clarify }
        XCTAssertTrue(marked, "the registry has a clarify open for this chat and Home does not know")
        XCTAssertEqual(HomeWaitingMark.label(for: .clarify), "Needs your answer")

        await rig.harness.backend.emit("request.cancel", sessionID: sid, payload: .object([
            "id": .string("srq-home"), "method": .string("clarify"), "reason": .string("answered"),
        ]))
        let cleared = await waitUntil { rig.homeKind(storedID: "stored-parked") == nil }
        XCTAssertTrue(cleared, "the question was withdrawn and Home still asks for an answer")

        await rig.tearDown()
    }

    /// A session this phone never opened, started on Desktop and blocked on an approval: the row comes from `session.active_list`, the request from the registry, and the join is that list's runtime id.
    func testALiveOnlyRowIsMarkedThroughTheActiveListJoin() async throws {
        let rig = try await makeRig(activeList: .object(["sessions": .array([.object([
            "id": .string("rt-desk"), "session_key": .string("stored-desk"), "title": .string("Desk work"),
            "status": .string("working"), "last_active": .number(Date().timeIntervalSince1970),
        ])])]))
        let joined = await waitUntil { rig.harness.app.liveStatus(forStoredID: "stored-desk")?.id == "rt-desk" }
        XCTAssertTrue(joined, "precondition: the active list never landed")
        XCTAssertTrue(rig.harness.app.continueRows().contains { $0.id == "stored-desk" }, "precondition: the session is not on the Continue strip")

        await rig.harness.backend.emitServerRequest(id: "srq-desk", method: "approval", sessionID: "rt-desk", params: [
            "request_id": .string("queue-desk"), "command": .string("echo synthetic"),
            "choices": .array([.string("once"), .string("deny")]),
        ])
        let marked = await waitUntil { rig.homeKind(storedID: "stored-desk") == .approval }
        XCTAssertTrue(marked, "the active list reports this session as `working`, and the registry's approval did not reach its row")
        XCTAssertEqual(rig.controller.waiting.byStoredID["stored-desk"], .approval, "reconcile joins through the active list too, not only at render")
        XCTAssertEqual(HomeWaitingMark.label(for: .approval), "Needs your answer")

        await rig.tearDown()
    }

    /// A row that is not waiting keeps its ordinary trailing text.
    func testARowWithNothingOpenIsNotMarked() async throws {
        let rig = try await makeRig()
        let chat = rig.harness.chat(storedID: "stored-idle")
        await chat.open()
        let sid = try XCTUnwrap(chat.runtimeSessionID)
        await rig.harness.backend.emitAssistantText("working", sessionID: sid)
        _ = await waitUntil { rig.harness.app.engine.state(for: sid).isBusy }
        XCTAssertNil(rig.homeKind(storedID: "stored-idle"), "a busy turn is not a question")
        await rig.tearDown()
    }

    // MARK: - The store

    func testAnApprovalWinsWhenTwoRuntimeSessionsShareARow() {
        let waiting = WaitingSessions()
        waiting.update(prompts: ["rt-1": .clarify, "rt-2": .approval]) { _ in ["stored-x"] }
        XCTAssertEqual(waiting.kind(storedID: "stored-x", runtimeID: nil), .approval)
    }

    func testALiveOnlyRowKeyedByItsRuntimeIDIsFound() {
        let waiting = WaitingSessions()
        waiting.update(prompts: ["rt-only": .sudo]) { _ in [] }
        XCTAssertEqual(waiting.kind(storedID: "rt-only", runtimeID: nil), .sudo)
        XCTAssertEqual(waiting.kind(storedID: "stored-y", runtimeID: "rt-only"), .sudo)
        XCTAssertNil(waiting.kind(storedID: "stored-y", runtimeID: nil))
    }

    func testAnEmptyPassClearsEverything() {
        let waiting = WaitingSessions()
        waiting.update(prompts: ["rt-1": .clarify]) { _ in ["stored-1"] }
        waiting.update(prompts: [:]) { _ in [] }
        XCTAssertTrue(waiting.byRuntimeID.isEmpty)
        XCTAssertTrue(waiting.byStoredID.isEmpty)
    }

    func testForgettingASessionDropsIt() {
        let waiting = WaitingSessions()
        waiting.update(prompts: ["rt-1": .clarify]) { _ in [] }
        waiting.forget(runtimeID: "rt-1")
        XCTAssertNil(waiting.kind(storedID: "rt-1", runtimeID: nil))
    }

    // MARK: - The copy

    func testOnlyADesktopRequestIsNotAQuestionForThisPhone() {
        for kind: ApprovalNotifications.PromptKind in [.approval, .clarify, .sudo, .secret] {
            XCTAssertEqual(HomeWaitingMark.label(for: kind), "Needs your answer", "\(kind)")
        }
        XCTAssertEqual(HomeWaitingMark.label(for: .desktop), "Continue in Desktop")
    }
}
