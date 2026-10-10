import Foundation
import HermesServeKit
import XCTest

@testable import HermesMobile

/// FEAT-040's design requires an explicit Send as text path for a literal leading slash. There was none: a typed `/tmp is full` ran as the command `/tmp`, was refused, and kept the draft, and the only way to send it as words was a leading space.
@MainActor
final class ComposerSendAsTextTests: XCTestCase {

    private func harness() async throws -> (AppHarness, ChatModel) {
        let harness = await AppHarness.make()
        try await harness.openSocket()
        let chat = harness.chat(storedID: "20261002_send_as_text")
        await chat.open()
        let bound = await waitUntil { chat.runtimeSessionID != nil }
        XCTAssertTrue(bound)
        await harness.backend.stub("commands.catalog") { _ in .object([
            "pairs": .array([.array([.string("/usage"), .string("Usage")])]),
        ]) }
        await harness.backend.stub("complete.slash") { _ in .object(["items": .array([]), "replace_from": .number(1)]) }
        return (harness, chat)
    }

    private func type(_ text: String, into chat: ChatModel, pasted: Bool = false) {
        chat.draft = text
        chat.slashCompletion.update(
            text: text, selection: NSRange(location: text.utf16.count, length: 0),
            isComposing: false, isPaste: pasted, isExternal: false,
            scope: chat.slashCompletionScope, api: chat.slashCommandAPI
        )
    }

    func testSendAsTextSendsALiteralSlashAsWordsAndRunsNoCommand() async throws {
        let (harness, chat) = try await harness()
        type("/tmp is full of logs again", into: chat)
        XCTAssertTrue(ComposerSendAsText.isOffered(for: chat), "Send would run this as a command, so the choice must be offered")

        ComposerSendAsText.send(chat)

        let submitted = await waitUntil { await harness.backend.callCount("prompt.submit") == 1 }
        XCTAssertTrue(submitted, "Send as text did not send the draft as a prompt")
        let prompts = await harness.backend.calls(to: "prompt.submit")
        XCTAssertEqual(prompts.first?.text, "/tmp is full of logs again")
        let executions = await harness.backend.callCount("slash.exec")
        let dispatches = await harness.backend.callCount("command.dispatch")
        XCTAssertEqual(executions + dispatches, 0, "Send as text ran the command it was meant to bypass")
        XCTAssertEqual(chat.draft, "")
        await harness.tearDown()
    }

    func testItIsNotOfferedForProseOrForADraftThatIsAlreadyLiteral() async throws {
        let (harness, chat) = try await harness()
        type("hello there", into: chat)
        XCTAssertFalse(ComposerSendAsText.isOffered(for: chat))
        type("/tmp/file.txt is missing", into: chat)
        XCTAssertFalse(ComposerSendAsText.isOffered(for: chat), "a path is not a command and already sends as text")
        type("/usage", into: chat, pasted: true)
        XCTAssertFalse(ComposerSendAsText.isOffered(for: chat), "a pasted slash is already literal")
        await harness.tearDown()
    }

    /// Ordinary Send on a typed command still runs the command; only the explicit choice sends words.
    func testOrdinarySendStillRunsTheCommand() async throws {
        let (harness, chat) = try await harness()
        await harness.backend.stub("slash.exec") { _ in .object(["output": .string("ok")]) }
        type("/usage", into: chat)
        chat.sendTapped()
        let finished = await waitUntil { !chat.isExecutingSlash }
        XCTAssertTrue(finished)
        let executions = await harness.backend.callCount("slash.exec")
        XCTAssertEqual(executions, 1)
        let prompts = await harness.backend.callCount("prompt.submit")
        XCTAssertEqual(prompts, 0)
        await harness.tearDown()
    }
}
