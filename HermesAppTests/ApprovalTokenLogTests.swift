import Foundation
import HermesServeKit
import XCTest

@testable import HermesMobile

/// The Live Activity controller logs through `os.Logger` with `privacy: .public`, which reaches the unified log in every build, Release included. It wrote the approval token (the value the island's Approve and Deny send back to answer the request) in full when an approval reached a card, and its first eight characters on every island answer. A log line may say whether there is a token and carry a short one-way fingerprint to match lines up, never the token or a piece of it.
@MainActor
final class ApprovalTokenLogTests: XCTestCase {
    /// The fingerprint names no token when there is none, is stable for one token so lines about the same approval match up, and carries none of the token's characters in order.
    func testTheFingerprintIsStableShortAndOneWay() {
        let token = "3F2A1B4C-9D8E-4F70-A1B2-C3D4E5F60718"
        XCTAssertEqual(LiveActivityController.logFingerprint(""), "none")
        // Worked out apart from the app (`printf '%s' <token> | sha256sum`, first four bytes), so a fingerprint that changed scheme or varied between runs fails here.
        XCTAssertEqual(LiveActivityController.logFingerprint(token), "#03203fdf",
                       "the fingerprint must be the token's SHA-256, the same on every run, so log lines about one approval match up")
        XCTAssertNotEqual(LiveActivityController.logFingerprint(token), LiveActivityController.logFingerprint(UUID().uuidString))
        XCTAssertEqual(LiveActivityController.logFingerprint(token).count, 9, "a '#' and eight hex digits")
        // Compared without case: the token is upper-case hex and the fingerprint lower-case, so a case-sensitive check could never fail.
        XCTAssertFalse(LiveActivityController.logFingerprint(token).lowercased().contains(token.prefix(4).lowercased()),
                       "the fingerprint carries the token's leading characters")
    }

    func testNoLogLineCarriesTheApprovalTokenOrAPieceOfIt() async throws {
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
        defer {
            LiveActivityPreferences.enabled = saved.enabled
            LiveActivityPreferences.autoStartForCron = saved.cron
            LiveActivityPreferences.lockScreen = saved.lockScreen
            LiveActivityPreferences.island = saved.island
            LiveActivityPreferences.showPolicy = saved.policy
            ApprovalActivityBridge.handler = LiveActivityController.shared
        }

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

        let sid = "cron-token-log"
        await harness.backend.emitAssistantText("cleaning up", sessionID: sid)
        let carded = await waitUntil { fake.handle(for: sid) != nil }
        XCTAssertTrue(carded, "precondition: the turn never put a card up")
        let handle = try XCTUnwrap(fake.handle(for: sid))

        await harness.backend.emitServerRequest(id: "srq-token-log", method: "approval", sessionID: sid, params: [
            "request_id": .string("queue-token-log"), "command": .string("echo synthetic"),
            "choices": .array([.string("once"), .string("deny")]),
        ])
        let approval = await waitUntil(timeout: 3) { handle.lastContent?.hasApproval == true }
        XCTAssertTrue(approval, "precondition: the approval never reached the card: \(handle.describeContent)")
        let token = try XCTUnwrap(handle.lastContent?.approvalToken)
        XCTAssertFalse(token.isEmpty, "precondition: the card carries no token")

        // An island answer is logged too.
        await controller.denyFromActivity(token: token, session: sid)

        let lines = controller.notesForTesting
        XCTAssertFalse(lines.isEmpty, "precondition: nothing was logged, so nothing below proves anything")
        let leaking = lines.filter { $0.contains(token) || $0.contains(String(token.prefix(8))) }
        XCTAssertEqual(leaking, [], "the approval token, or its first eight characters, reached the log")

        await harness.tearDown()
    }
}
