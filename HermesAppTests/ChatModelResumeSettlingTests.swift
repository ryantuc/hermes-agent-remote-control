import Foundation
import HermesServeKit
import XCTest

@testable import HermesMobile

/// Free-standing for the same reason `BotChatResolverTests` keeps its own:
/// `ScriptedBackend.stub` takes a `@Sendable` closure that runs off the main
/// actor, and a helper on a `@MainActor` test class cannot be called inside one.
private enum SettlingWire {
    /// A `session.resume` answer with a caller-chosen key, so a test can prove
    /// *which* id was resumed.
    static func resumeResult(runtime: String, key: String) -> JSONValue {
        .object([
            "session_id": .string(runtime),
            "session_key": .string(key),
            "resumed": .string(key),
            "messages": .array([]),
            "running": .bool(false),
            "status": .string("idle"),
            "watching": .bool(false),
        ])
    }
}

/// BUG-114 — `session.resume` refused 4009 while a disconnect interrupt settles.
///
/// A backend change wrapped the live-reuse fast path in a lock and gave it
/// two ways to refuse. Before it, that path had no guards and always
/// succeeded, so a Wi-Fi blip mid-turn reattached silently. After it, the
/// gateway can answer 4009 `session disconnect interrupt settling` for as long
/// as the WS-orphan reaper takes to finish interrupting the turn.
///
/// The session is alive throughout. The only correct client behaviour is to wait
/// and attach again — which is why these assert on **which id** the retry
/// resumes, not merely that the open succeeded. Resuming a *different* id would
/// mean the error had been misread as session-not-found, whose recovery is
/// re-derivation, and re-derivation is how a second forever-chat gets minted.
@MainActor
final class ChatModelResumeSettlingTests: XCTestCase {

    private func ref(_ profile: String = "scout", _ name: String = "Scout") -> BotThreadRef {
        BotThreadRef(profile: profile, displayName: name)
    }

    /// The whole fix in one assertion: same id, twice, no re-derivation.
    func testSettlingResumeIsRetriedOnTheSameID() async throws {
        let harness = await AppHarness.make()
        try await harness.openSocket()
        harness.app.bots.store.setPin("settling-1", backend: harness.profileID, profile: "scout")

        await harness.backend.failNextRPC(
            "session.resume",
            code: 4009,
            message: "session disconnect interrupt settling"
        )
        await harness.backend.stub("session.resume") { call in
            SettlingWire.resumeResult(runtime: "rt-settled", key: call.sessionID)
        }

        let chat = harness.app.chat(for: .bot(ref()))
        await chat.open()

        // Count attempts against THIS id rather than the total: the resolver has
        // further rungs, and asserting a grand total would pin their behaviour
        // instead of the retry's.
        let onPin = await harness.backend.calls(to: "session.resume")
            .filter { $0.sessionID == "settling-1" }
        XCTAssertEqual(
            onPin.count,
            2,
            "a settling refusal is transient: retry the SAME id rather than re-deriving a new chat"
        )
        // Hoisted: XCTAssert's arguments are autoclosures, which cannot carry an
        // `await`.
        let creates = await harness.backend.callCount("session.create")
        XCTAssertEqual(
            creates,
            0,
            "the session is alive — minting a replacement would strand it"
        )
        // NOT `XCTAssertNil(chat.errorMessage)`. The harness points REST at a
        // port that refuses instantly, so "Could not connect to the server."
        // lands in this same slot at unpredictable moments — asserting the raw
        // optional makes the test a coin flip on timing, and the 750ms retry
        // pause widens the window it can land in. `StopStopsAgentsTests` hit
        // exactly this and solved it the same way: assert on the message you
        // actually care about.
        XCTAssertFalse(
            chat.errorMessage?.localizedCaseInsensitiveContains("settling") ?? false,
            "a transient refusal must not surface as a failed reconnect"
        )

        await harness.tearDown()
    }

    /// The retry is bounded. A gateway stuck in the settling state must
    /// eventually surface rather than spin, and when it does the user gets the
    /// error rather than silence.
    func testAPersistentlySettlingGatewayEventuallySurfaces() async throws {
        let harness = await AppHarness.make()
        try await harness.openSocket()
        harness.app.bots.store.setPin("stuck-1", backend: harness.profileID, profile: "scout")

        // Not `failNextRPC`: this one never clears.
        await harness.backend.failRPC(
            "session.resume",
            code: 4009,
            message: "session disconnect interrupt settling"
        )

        let chat = harness.app.chat(for: .bot(ref()))
        await chat.open()

        let onPin = await harness.backend.calls(to: "session.resume")
            .filter { $0.sessionID == "stuck-1" }
        XCTAssertEqual(
            onPin.count,
            3,
            "one attempt plus exactly two retries — bounded, because an unbounded "
                + "retry is a spinner the user cannot escape. That this returned at all "
                + "is half the assertion: a retry without a limit would hang the open."
        )

        await harness.tearDown()
    }

    /// The other 4009 must not be dragged in. `no pending <key> request` answers
    /// a clarify/sudo/secret prompt that already expired; it is not a resume
    /// refusal and retrying it would be meaningless.
    func testTheExpiredPromptFlavourOf4009IsNotRetried() async throws {
        let harness = await AppHarness.make()
        try await harness.openSocket()
        harness.app.bots.store.setPin("expired-1", backend: harness.profileID, profile: "scout")

        await harness.backend.failRPC(
            "session.resume",
            code: 4009,
            message: "no pending clarify request"
        )

        let chat = harness.app.chat(for: .bot(ref()))
        await chat.open()

        let onPin = await harness.backend.calls(to: "session.resume")
            .filter { $0.sessionID == "expired-1" }
        XCTAssertEqual(
            onPin.count,
            1,
            "the no-pending 4009 is a different error and earns no retry"
        )

        await harness.tearDown()
    }
}
