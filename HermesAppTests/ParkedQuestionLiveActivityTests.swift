import Foundation
import HermesServeKit
import XCTest

@testable import HermesMobile

/// BUG-062 B. A session parked on a question that is not an approval must say so on the Lock Screen and in the island.
///
/// Before the fix the card for a session stopped on a `clarify`, `sudo` or `secret` request kept painting the turn as running: the action-coloured dot, the progress count, and "Working" in Settings' roster, while the agent waited on the person holding the phone and the backend's timeout ran down.
///
/// The truth source is the current-request registry (`ServerRequests.swift`): `HermesClient` publishes it as `client.server_requests`, `TurnEngine` projects it onto the session's prompt fields, and `AppModel.publish` reconciles the roster. Every test here drives that path with a real JSON-RPC server request on the scripted socket, never by poking turn state.
///
/// These compile against the base and fail on assertions; the specification tests for the API the fix adds ride with the fix.
@MainActor
final class ParkedQuestionLiveActivityTests: XCTestCase {

    private static let waitingLine = "Waiting for your answer"
    private static let desktopLine = "Continue in Desktop"

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

    /// A harness that answers server requests, mirrors every session onto the socket, and records the roster on a fake surface.
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
        harness.app.liveActivities = controller
        controller.install(app: harness.app)
        try await harness.openSocket()
        return Rig(harness: harness, fake: fake, controller: controller, saved: saved)
    }

    /// A chatless turn under way, with its card up, so what follows is a change to a card that already exists.
    private func startTurn(_ rig: Rig, sessionID: String) async throws -> FakeLiveActivityHandle {
        await rig.harness.backend.emitAssistantText("checking the deploy", sessionID: sessionID)
        await rig.harness.backend.emit("tool.start", sessionID: sessionID, payload: .object([
            "tool_id": .string("t-\(sessionID)"), "name": .string("clarify"), "context": .string("Which branch?"),
        ]))
        let carded = await waitUntil { rig.fake.handle(for: sessionID) != nil }
        XCTAssertTrue(carded, "precondition: the turn never put a card up, so nothing below proves anything")
        return try XCTUnwrap(rig.fake.handle(for: sessionID))
    }

    private func detail(_ rig: Rig, sessionID: String) -> String? {
        rig.controller.rosterRows().first { $0.id == sessionID }?.detail
    }

    // MARK: - The card says it is waiting

    /// The headline: a clarify is open on the registry, and the card must stop reading as a running turn.
    func testAClarifyOnTheRegistryPutsWaitingForYourAnswerOnTheCard() async throws {
        let rig = try await makeRig()
        let handle = try await startTurn(rig, sessionID: "cron-clarify")

        await rig.harness.backend.emitServerRequest(id: "srq-clarify", method: "clarify", sessionID: "cron-clarify",
                                                    params: ["question": .string("Which branch?")])
        let open = await waitUntil { rig.harness.app.engine.state(for: "cron-clarify").clarify != nil }
        XCTAssertTrue(open, "precondition: the registry's clarify never reached the engine")

        let said = await waitUntil(timeout: 3) { handle.lastContent?.statusText == Self.waitingLine }
        XCTAssertTrue(said, "a session parked on a clarify still reads as a running turn on the card. Card: \(handle.describeContent)")
        XCTAssertEqual(handle.lastContent?.toolName, "", "the running tool is the question itself; naming it on lock-screen glass says nothing true about the turn")
        XCTAssertEqual(handle.lastContent?.approvalToken, "", "a clarify must never carry an approval token: the card's buttons are approval-only (consent ladder)")
        XCTAssertEqual(detail(rig, sessionID: "cron-clarify"), Self.waitingLine, "Settings' Lock Screen roster still says the session is working")

        await rig.tearDown()
    }

    /// A password and a value are answers too.
    func testASudoOrSecretRequestReadsAsWaitingForYourAnswer() async throws {
        let rig = try await makeRig()
        let sudoCard = try await startTurn(rig, sessionID: "cron-sudo")
        let secretCard = try await startTurn(rig, sessionID: "cron-secret")

        await rig.harness.backend.emitServerRequest(id: "srq-sudo", method: "sudo", sessionID: "cron-sudo")
        await rig.harness.backend.emitServerRequest(id: "srq-secret", method: "secret", sessionID: "cron-secret",
                                                    params: ["prompt": .string("Token"), "env_var": .string("SYNTHETIC_TOKEN")])
        let open = await waitUntil {
            rig.harness.app.engine.state(for: "cron-sudo").sudo != nil
                && rig.harness.app.engine.state(for: "cron-secret").secret != nil
        }
        XCTAssertTrue(open, "precondition: the registry's requests never reached the engine")

        let said = await waitUntil(timeout: 3) {
            sudoCard.lastContent?.statusText == Self.waitingLine && secretCard.lastContent?.statusText == Self.waitingLine
        }
        XCTAssertTrue(said, "sudo: \(sudoCard.describeContent) / secret: \(secretCard.describeContent)")

        await rig.tearDown()
    }

    /// A request only Desktop can answer must not invite an answer this phone cannot give.
    func testADesktopOnlyRequestSaysContinueInDesktop() async throws {
        let rig = try await makeRig()
        let handle = try await startTurn(rig, sessionID: "cron-desktop")

        await rig.harness.backend.emitServerRequest(id: "srq-desktop", method: "vault.save_login", sessionID: "cron-desktop",
                                                    params: ["site": .string("example.invalid")])
        let open = await waitUntil { rig.harness.app.engine.state(for: "cron-desktop").secret?.requiresDesktop == true }
        XCTAssertTrue(open, "precondition: the desktop-only request never reached the engine")

        let said = await waitUntil(timeout: 3) { handle.lastContent?.statusText == Self.desktopLine }
        XCTAssertTrue(said, "Card: \(handle.describeContent)")
        XCTAssertEqual(detail(rig, sessionID: "cron-desktop"), Self.desktopLine)

        await rig.tearDown()
    }

    // MARK: - Timing

    /// The question arrives inside the one-second coalescing window, and nothing follows it, because the agent is blocked on the answer; a coalesced push here is a push that never happens.
    func testAQuestionInsideTheCoalescingWindowStillReachesTheCard() async throws {
        let rig = try await makeRig()
        await rig.harness.backend.emitAssistantText("checking", sessionID: "cron-quick")
        await rig.harness.backend.emitServerRequest(id: "srq-quick", method: "clarify", sessionID: "cron-quick",
                                                    params: ["question": .string("Proceed?")])
        let carded = await waitUntil { rig.fake.handle(for: "cron-quick") != nil }
        XCTAssertTrue(carded, "precondition: no card")
        let handle = try XCTUnwrap(rig.fake.handle(for: "cron-quick"))

        let said = await waitUntil(timeout: 2.5) { handle.lastContent?.statusText == Self.waitingLine }
        XCTAssertTrue(said, "the question landed inside the coalescing window and the card never heard: \(handle.describeContent)")

        await rig.tearDown()
    }

    // MARK: - It stops waiting when the registry says so

    /// Answered on Desktop, or timed out: the backend withdraws the request with `request.cancel`, and the card must stop claiming a question is open.
    func testARequestWithdrawnElsewhereTakesTheWaitingLineOff() async throws {
        let rig = try await makeRig()
        let handle = try await startTurn(rig, sessionID: "cron-withdrawn")

        await rig.harness.backend.emitServerRequest(id: "srq-withdrawn", method: "clarify", sessionID: "cron-withdrawn",
                                                    params: ["question": .string("Which branch?")])
        let waiting = await waitUntil(timeout: 3) { handle.lastContent?.statusText == Self.waitingLine }
        XCTAssertTrue(waiting, "precondition: the card never said it was waiting: \(handle.describeContent)")

        await rig.harness.backend.emit("request.cancel", sessionID: "cron-withdrawn", payload: .object([
            "id": .string("srq-withdrawn"), "method": .string("clarify"), "reason": .string("answered"),
        ]))
        let gone = await waitUntil { rig.harness.app.engine.state(for: "cron-withdrawn").clarify == nil }
        XCTAssertTrue(gone, "precondition: the cancel never reached the engine")

        let cleared = await waitUntil(timeout: 3) { handle.lastContent?.statusText != Self.waitingLine }
        XCTAssertTrue(cleared, "the request is gone from the registry but the card still says it is waiting: \(handle.describeContent)")
        XCTAssertNotEqual(detail(rig, sessionID: "cron-withdrawn"), Self.waitingLine)

        await rig.tearDown()
    }

    // MARK: - The consent ladder is untouched

    /// An approval arriving on a session already parked on a question takes the card with its own copy and buttons; when it goes, the card is parked again, because the question is still open.
    func testAnApprovalOutranksAParkedQuestionAndHandsTheCardBack() async throws {
        let rig = try await makeRig()
        let handle = try await startTurn(rig, sessionID: "cron-both")

        await rig.harness.backend.emitServerRequest(id: "srq-both-q", method: "clarify", sessionID: "cron-both",
                                                    params: ["question": .string("Which branch?")])
        let parked = await waitUntil(timeout: 3) { handle.lastContent?.parkedQuestion == .answer }
        XCTAssertTrue(parked, "precondition: \(handle.describeContent)")

        await rig.harness.backend.emitServerRequest(id: "srq-both-a", method: "approval", sessionID: "cron-both", params: [
            "request_id": .string("queue-both"), "command": .string("echo synthetic"),
            "choices": .array([.string("once"), .string("deny")]),
        ])
        let approval = await waitUntil(timeout: 3) { handle.lastContent?.hasApproval == true }
        XCTAssertTrue(approval, "the approval never took the card: \(handle.describeContent)")
        XCTAssertNil(handle.lastContent?.parkedQuestion, "an approval card carries its own copy; the parked line must not ride under it")
        XCTAssertNotEqual(handle.lastContent?.statusText, Self.waitingLine)
        XCTAssertEqual(detail(rig, sessionID: "cron-both"), "Waiting for your approval")

        await rig.harness.backend.emit("request.cancel", sessionID: "cron-both", payload: .object([
            "id": .string("srq-both-a"), "method": .string("approval"), "reason": .string("timeout"),
        ]))
        let back = await waitUntil(timeout: 3) {
            handle.lastContent?.hasApproval == false && handle.lastContent?.parkedQuestion == .answer
        }
        XCTAssertTrue(back, "the approval went but the still-open question did not get the card back: \(handle.describeContent)")

        await rig.tearDown()
    }

    /// A parked card can fire no intent: the only intents a card carries are an approval's, and a parked snapshot never has a token for them.
    func testAParkedCardCarriesNoApprovalToken() async throws {
        let rig = try await makeRig()
        let handle = try await startTurn(rig, sessionID: "cron-token")
        await rig.harness.backend.emitServerRequest(id: "srq-token", method: "sudo", sessionID: "cron-token")
        let parked = await waitUntil(timeout: 3) { handle.lastContent?.parkedQuestion == .answer }
        XCTAssertTrue(parked, "precondition: \(handle.describeContent)")
        XCTAssertTrue(handle.pushed.allSatisfy { $0.approvalToken.isEmpty }, "a sudo prompt produced an approval token, and with it Deny and Approve buttons")
        await rig.tearDown()
    }
}
