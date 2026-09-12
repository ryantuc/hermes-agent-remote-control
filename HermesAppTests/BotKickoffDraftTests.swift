import Foundation
import HermesServeKit
import XCTest

@testable import HermesMobile

/// BUG-084 — the mint's kickoff used to overwrite whatever the user had typed
/// while the resolver was running.
///
/// The window is the first open of a bot with no pin, and it spans up to four
/// sequential network round trips. Nothing stops the user typing during it: the
/// composer field is deliberately left editable while the transport is down
/// (`ComposerView`), and the send gate reads only connection state, the sending
/// flag and whether there is a payload — there is no resolving term. So on a
/// slow or waking gateway the ladder finished, `draft = BotsModel.kickoffPrompt`
/// ran unconditionally, and the user's question was replaced by a canned line
/// that then sent as their own bubble.
///
/// The control for these lives next door and is deliberately not touched:
/// `BotChatResolverTests.testMintCreatesHiddenTitledChatThenSendsTheKickoff`
/// still requires the kickoff on an empty composer, because
/// `session.create` alone persists no DB row and a mint that never speaks
/// cannot be found again.
@MainActor
final class BotKickoffDraftTests: XCTestCase {

    private func ref(_ profile: String = "scout", _ name: String = "Scout") -> BotThreadRef {
        BotThreadRef(profile: profile, displayName: name)
    }

    /// The reported failure, staged the way it happens: the mint is parked
    /// mid-flight, the user types, and the resolver then completes.
    func testTypingWhileTheResolverRunsSendsTheUsersTextNotTheKickoff() async throws {
        let harness = await AppHarness.make()
        try await harness.openSocket()

        await harness.backend.stub("session.list") { _ in .object(["sessions": .array([])]) }
        await harness.backend.failRPC("session.resume", code: 4007, message: "no such session")
        await harness.backend.gate("session.create")

        let chat = harness.app.chat(for: .bot(ref()))
        let opening = Task { @MainActor in await chat.open() }

        let reached = await waitUntil { await harness.backend.callCount("session.create") == 1 }
        XCTAssertTrue(reached, "precondition: the open never reached the mint")

        // The user, watching a spinner, starts typing.
        let typed = "what does your deploy script actually do?"
        chat.draft = typed

        await harness.backend.ungate("session.create")
        await harness.backend.releaseParked()
        await opening.value

        let submitted = await waitUntil { await harness.backend.callCount("prompt.submit") == 1 }
        XCTAssertTrue(submitted, "the mint must still speak, so the chat is findable next time")

        let submit = await harness.backend.calls(to: "prompt.submit").first
        XCTAssertEqual(
            submit?.text, typed,
            "the resolver sent its canned kickoff instead of what the user wrote"
        )
        XCTAssertNotEqual(submit?.text, BotsModel.kickoffPrompt)

        XCTAssertTrue(
            chat.entries.contains { $0.kind == .user && $0.text == typed },
            "the user's own message must be the one in the transcript"
        )
        XCTAssertFalse(
            chat.entries.contains { $0.text == BotsModel.kickoffPrompt },
            "a message the user did not write must not appear attributed to them"
        )

        await harness.tearDown()
    }

    /// Exactly one turn either way. The fix must not send the user's text *and*
    /// the kickoff — two prompts for one tap is its own defect.
    func testOnlyOneTurnIsSentWhenTheUserHasTyped() async throws {
        let harness = await AppHarness.make()
        try await harness.openSocket()

        await harness.backend.stub("session.list") { _ in .object(["sessions": .array([])]) }
        await harness.backend.failRPC("session.resume", code: 4007, message: "no such session")
        await harness.backend.gate("session.create")

        let chat = harness.app.chat(for: .bot(ref()))
        let opening = Task { @MainActor in await chat.open() }
        _ = await waitUntil { await harness.backend.callCount("session.create") == 1 }
        chat.draft = "hello"

        await harness.backend.ungate("session.create")
        await harness.backend.releaseParked()
        await opening.value
        _ = await waitUntil { await harness.backend.callCount("prompt.submit") >= 1 }

        let extra = await waitUntil(timeout: 1) {
            await harness.backend.callCount("prompt.submit") > 1
        }
        XCTAssertFalse(extra, "the user's message and the kickoff both went out")

        await harness.tearDown()
    }

    /// Whitespace is not a draft. A composer holding only spaces or a newline
    /// has nothing to preserve, and skipping the kickoff there would leave the
    /// minted chat unpersisted — the failure the kickoff exists to prevent.
    func testAWhitespaceOnlyDraftStillGetsTheKickoff() async throws {
        let harness = await AppHarness.make()
        try await harness.openSocket()

        await harness.backend.stub("session.list") { _ in .object(["sessions": .array([])]) }
        await harness.backend.failRPC("session.resume", code: 4007, message: "no such session")
        await harness.backend.gate("session.create")

        let chat = harness.app.chat(for: .bot(ref()))
        let opening = Task { @MainActor in await chat.open() }
        _ = await waitUntil { await harness.backend.callCount("session.create") == 1 }
        chat.draft = "   \n  "

        await harness.backend.ungate("session.create")
        await harness.backend.releaseParked()
        await opening.value

        let submitted = await waitUntil { await harness.backend.callCount("prompt.submit") == 1 }
        XCTAssertTrue(submitted, "a whitespace-only composer must not suppress the kickoff")
        let submit = await harness.backend.calls(to: "prompt.submit").first
        XCTAssertEqual(submit?.text, BotsModel.kickoffPrompt)

        await harness.tearDown()
    }
}
