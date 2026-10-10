import Foundation
import HermesServeKit
import XCTest

@testable import HermesMobile

@MainActor
final class SlashCommandSendingTests: XCTestCase {
    private func harness() async throws -> (AppHarness, ChatModel) {
        let harness = await AppHarness.make()
        try await harness.openSocket()
        let chat = harness.chat(storedID: "20260920_slash")
        await chat.open()
        let bound = await waitUntil { chat.runtimeSessionID != nil }
        XCTAssertTrue(bound)
        await harness.backend.stub("commands.catalog") { _ in .object([
            "pairs": .array([
                .array([.string("/usage"), .string("Usage")]),
                .array([.string("/write"), .string("Writing skill")]),
                .array([.string("/quick"), .string("Quick command")]),
                .array([.string("/undo"), .string("Restore draft")]),
                .array([.string("/status"), .string("Session status")])
            ]),
            "skills": .object(["/write": .object([:])])
        ]) }
        await harness.backend.stub("complete.slash") { _ in .object(["items": .array([]), "replace_from": .number(1)]) }
        return (harness, chat)
    }

    private func type(_ text: String, into chat: ChatModel, pasted: Bool = false) {
        chat.draft = text
        chat.slashCompletion.update(text: text, selection: NSRange(location: text.utf16.count, length: 0),
            isComposing: false, isPaste: pasted, isExternal: false,
            scope: chat.slashCompletionScope, api: chat.slashCommandAPI)
    }

    func testBackendCommandUsesSlashExecutionAndShowsOutputWithoutPrompt() async throws {
        let (harness, chat) = try await harness()
        await harness.backend.stub("slash.exec") { call in
            .object(["output": .string("Usage for \(call.sessionID)")])
        }
        type("/usage", into: chat)
        chat.sendTapped()
        chat.sendTapped()
        let finished = await waitUntil { !chat.isExecutingSlash }
        XCTAssertTrue(finished)
        let calls = await harness.backend.calls(to: "slash.exec")
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls.first?.params["command"]?.stringValue, "usage")
        XCTAssertEqual(calls.first?.sessionID, chat.runtimeSessionID)
        let prompts = await harness.backend.callCount("prompt.submit")
        XCTAssertEqual(prompts, 0)
        XCTAssertEqual(chat.draft, "")
        XCTAssertTrue(chat.live.entries.contains { $0.text.hasPrefix("Usage for") })
        await harness.tearDown()
    }

    func testSkillFallbackSubmitsExpandedPromptButDisplaysInvocation() async throws {
        let (harness, chat) = try await harness()
        await harness.backend.failRPC("slash.exec", code: 4018, message: "skill command: use command.dispatch for /write")
        await harness.backend.stub("command.dispatch") { call in .object([
            "type": .string("skill"), "message": .string("PRIVATE SCAFFOLD\nTask: \(call.params["arg"]?.stringValue ?? "")"),
            "display": .string("/write keep  spaces\nand lines")
        ]) }
        await harness.backend.gate("prompt.submit")
        type("/write keep  spaces\nand lines", into: chat)
        chat.sendTapped()
        let submitted = await waitUntil { await harness.backend.callCount("prompt.submit") == 1 }
        XCTAssertTrue(submitted)
        let dispatches = await harness.backend.calls(to: "command.dispatch")
        XCTAssertEqual(dispatches.first?.params["arg"]?.stringValue, "keep  spaces\nand lines")
        let prompts = await harness.backend.calls(to: "prompt.submit")
        XCTAssertEqual(prompts.first?.text, "PRIVATE SCAFFOLD\nTask: keep  spaces\nand lines")
        XCTAssertFalse(chat.entries.contains { $0.text.contains("PRIVATE SCAFFOLD") })
        XCTAssertTrue(chat.entries.contains { $0.text == "/write keep  spaces\nand lines" })
        await harness.backend.ungate("prompt.submit")
        await harness.backend.releaseParked()
        await harness.tearDown()
    }

    func testPrefillNeverSubmitsAndPreservesNewerDraft() async throws {
        let (harness, chat) = try await harness()
        await harness.backend.stub("slash.exec") { _ in .object(["type": .string("prefill"), "message": .string("restored draft")]) }
        await harness.backend.gate("slash.exec")
        type("/undo", into: chat)
        chat.sendTapped()
        let arrived = await waitUntil { await harness.backend.callCount("slash.exec") == 1 }
        XCTAssertTrue(arrived)
        chat.draft = "newer text"
        await harness.backend.ungate("slash.exec")
        await harness.backend.releaseParked()
        let finished = await waitUntil { !chat.isExecutingSlash }
        XCTAssertTrue(finished)
        XCTAssertEqual(chat.draft, "newer text")
        XCTAssertTrue(chat.live.entries.contains { $0.text.contains("restored draft") })
        let prompts = await harness.backend.callCount("prompt.submit")
        XCTAssertEqual(prompts, 0)
        await harness.tearDown()
    }

    func testUnavailableCommandPreservesDraftAndDoesNotBecomePrompt() async throws {
        let (harness, chat) = try await harness()
        type("/model", into: chat)
        chat.sendTapped()
        let finished = await waitUntil { !chat.isExecutingSlash }
        XCTAssertTrue(finished)
        XCTAssertEqual(chat.draft, "/model")
        XCTAssertNotNil(chat.errorMessage)
        let executions = await harness.backend.callCount("slash.exec")
        let prompts = await harness.backend.callCount("prompt.submit")
        XCTAssertEqual(executions, 0)
        XCTAssertEqual(prompts, 0)
        await harness.tearDown()
    }

    func testMissingDiscoveryPreservesTypedCommandAndOrdinarySendStillWorks() async throws {
        let (harness, chat) = try await harness()
        await harness.backend.failRPC("commands.catalog", code: -32601, message: "Method not found")
        await harness.backend.failRPC("complete.slash", code: -32601, message: "Method not found")
        type("/unknown", into: chat)
        chat.sendTapped()
        let finished = await waitUntil { !chat.isExecutingSlash }
        XCTAssertTrue(finished)
        XCTAssertEqual(chat.draft, "/unknown")
        XCTAssertNotNil(chat.errorMessage)
        type("ordinary chat", into: chat)
        chat.sendTapped()
        let submitted = await waitUntil { await harness.backend.callCount("prompt.submit") == 1 }
        XCTAssertTrue(submitted)
        await harness.tearDown()
    }

    func testPastedSlashContentIsOrdinaryText() async throws {
        let (harness, chat) = try await harness()
        type("/usage is pasted prose", into: chat, pasted: true)
        chat.sendTapped()
        let submitted = await waitUntil { await harness.backend.callCount("prompt.submit") == 1 }
        XCTAssertTrue(submitted)
        let executions = await harness.backend.callCount("slash.exec")
        XCTAssertEqual(executions, 0)
        let prompts = await harness.backend.calls(to: "prompt.submit")
        XCTAssertEqual(prompts.first?.text, "/usage is pasted prose")
        await harness.tearDown()
    }

    func testStatusUsesDedicatedSessionRPC() async throws {
        let (harness, chat) = try await harness()
        await harness.backend.stub("session.status") { _ in .object(["output": .string("Current session")]) }
        type("/status", into: chat)
        chat.sendTapped()
        let finished = await waitUntil { !chat.isExecutingSlash }
        XCTAssertTrue(finished)
        let calls = await harness.backend.calls(to: "session.status")
        XCTAssertEqual(calls.count, 1)
        let executions = await harness.backend.callCount("slash.exec")
        XCTAssertEqual(executions, 0)
        await harness.tearDown()
    }

    func testTypedDispatchReturnedBySlashExecDoesNotNeedFallback() async throws {
        let (harness, chat) = try await harness()
        await harness.backend.stub("slash.exec") { _ in .object(["type": .string("plugin"), "output": .string("Plugin result")]) }
        type("/quick", into: chat)
        chat.sendTapped()
        let finished = await waitUntil { !chat.isExecutingSlash }
        XCTAssertTrue(finished)
        let fallbacks = await harness.backend.callCount("command.dispatch")
        XCTAssertEqual(fallbacks, 0)
        XCTAssertTrue(chat.live.entries.contains { $0.text == "Plugin result" })
        await harness.tearDown()
    }

    func testQuickAliasResolvesSkillThroughDispatchAndPreservesArguments() async throws {
        let (harness, chat) = try await harness()
        await harness.backend.stub("commands.catalog") { _ in .object([
            "pairs": .array([.array([.string("/quick"), .string("Alias")]), .array([.string("/write"), .string("Skill")])]),
            "categories": .array([.object(["name": .string("User commands"), "pairs": .array([.array([.string("/quick"), .string("Alias")])])])]),
            "skills": .object(["/write": .object([:])])
        ]) }
        await harness.backend.stub("command.dispatch") { call in
            if call.params["name"]?.stringValue == "quick" { return .object(["type": .string("alias"), "target": .string("write")]) }
            return .object(["type": .string("skill"), "message": .string("expanded task"), "display": .string("/write task")])
        }
        await harness.backend.failRPC("slash.exec", code: 4018, message: "skill command: use command.dispatch for /write")
        type("/quick task", into: chat)
        chat.sendTapped()
        let submitted = await waitUntil { await harness.backend.callCount("prompt.submit") == 1 }
        XCTAssertTrue(submitted)
        let dispatches = await harness.backend.calls(to: "command.dispatch")
        XCTAssertEqual(dispatches.map { $0.params["name"]?.stringValue }, ["quick", "write"])
        XCTAssertTrue(dispatches.allSatisfy { $0.params["arg"]?.stringValue == "task" })
        let executions = await harness.backend.calls(to: "slash.exec")
        XCTAssertFalse(executions.contains { $0.params["command"]?.stringValue == "quick task" })
        await harness.tearDown()
    }

    func testWorkerErrorNeverRetriesAnOperationThatMayHaveExecuted() async throws {
        let (harness, chat) = try await harness()
        await harness.backend.failRPC("slash.exec", code: 5030, message: "worker reply lost after execution")
        type("/usage", into: chat)
        chat.sendTapped()
        let finished = await waitUntil { !chat.isExecutingSlash }
        XCTAssertTrue(finished)
        let retries = await harness.backend.callCount("command.dispatch")
        XCTAssertEqual(retries, 0)
        XCTAssertEqual(chat.draft, "/usage")
        XCTAssertTrue(chat.errorMessage?.contains("worker reply lost") == true)
        await harness.tearDown()
    }

    func testCommandReplyAfterBackendSwitchCannotSubmitSkillToNewBackend() async throws {
        let (harness, chat) = try await harness()
        await harness.backend.stub("slash.exec") { _ in .object(["type": .string("skill"), "message": .string("expanded prompt")]) }
        await harness.backend.gate("slash.exec")
        type("/write task", into: chat)
        chat.sendTapped()
        let arrived = await waitUntil { await harness.backend.callCount("slash.exec") == 1 }
        XCTAssertTrue(arrived)
        // A changed namespace is sufficient to invalidate the captured command context.
        let index = try XCTUnwrap(harness.app.profiles.firstIndex { $0.id == harness.profileID })
        harness.app.profiles[index].baseURLString = "http://127.0.0.1:10"
        await harness.backend.ungate("slash.exec")
        await harness.backend.releaseParked()
        let finished = await waitUntil { !chat.isExecutingSlash }
        XCTAssertTrue(finished)
        let prompts = await harness.backend.callCount("prompt.submit")
        XCTAssertEqual(prompts, 0)
        XCTAssertEqual(chat.draft, "/write task")
        await harness.tearDown()
    }

    /// Home promotes its draft on `hasStartedSubmission` and renders no transcript or error row. A command's output and refusals are written to the thread, so the signal must rise in the tap frame for a command exactly as it does for a prompt; keyed on `isSending` alone, a command sent from Home left the user looking at nothing.
    func testCommandSendRaisesTheSignalHomePromotesOnInTheTapFrame() async throws {
        let harness = await AppHarness.make()
        try await harness.openSocket()
        let chat = ChatModel(app: harness.app, summary: nil)
        await harness.backend.gate("session.create")
        type("/usage", into: chat)
        XCTAssertFalse(chat.hasStartedSubmission)
        chat.sendTapped()
        XCTAssertTrue(chat.hasStartedSubmission, "Home must leave for the thread on the tap, before the command's outcome is written there")
        XCTAssertFalse(chat.isSending, "a command is not a prompt, so the old promotion trigger never fired for it")
        await harness.backend.ungate("session.create")
        await harness.backend.releaseParked()
        let finished = await waitUntil { !chat.isExecutingSlash }
        XCTAssertTrue(finished)
        XCTAssertFalse(chat.hasStartedSubmission)
        await harness.tearDown()
    }

    /// Discovery no longer creates sessions, so the late-bind fence is exercised where a session is still created for a command: its Send.
    func testNamedProfileCommandSendCannotBindSessionAfterBackendSwitch() async throws {
        let harness = await AppHarness.make()
        try await harness.openSocket()
        let index = try XCTUnwrap(harness.app.profiles.firstIndex { $0.id == harness.profileID })
        harness.app.profiles[index].hermesProfile = "research"
        let chat = ChatModel(app: harness.app, summary: nil)
        await harness.backend.gate("session.create")
        type("/usage", into: chat)
        chat.sendTapped()
        let arrived = await waitUntil { await harness.backend.callCount("session.create") == 1 }
        XCTAssertTrue(arrived)
        let creates = await harness.backend.calls(to: "session.create")
        XCTAssertEqual(creates.first?.params["profile"]?.stringValue, "research")
        harness.app.profiles[index].baseURLString = "http://127.0.0.1:10"
        await harness.backend.ungate("session.create")
        await harness.backend.releaseParked()
        let finished = await waitUntil { !chat.isExecutingSlash }
        XCTAssertTrue(finished)
        XCTAssertNil(chat.runtimeSessionID)
        XCTAssertEqual(chat.draft, "/usage")
        let executions = await harness.backend.callCount("slash.exec")
        XCTAssertEqual(executions, 0)
        await harness.tearDown()
    }

    /// The backend's `Params` models are `extra="forbid"` and admission answers 4000 for any undeclared key before the handler runs (`tui_gateway/contracts/base.py:35`, `rpc_dispatch.py:27-31`). `complete.slash` declares only text/session_id/profile and `commands.catalog` only session_id/profile, so a `cwd` key makes discovery fail in every chat whose `info` carries a cwd, and then Send cannot find the command in a catalog either.
    func testDiscoveryAndExecutionSendOnlyParamsTheBackendContractDeclares() async throws {
        let (harness, chat) = try await harness()
        await harness.backend.stub("slash.exec") { _ in .object(["output": .string("Usage report")]) }
        type("/us", into: chat)
        let asked = await waitUntil { await harness.backend.callCount("complete.slash") >= 1 }
        XCTAssertTrue(asked)
        type("/usage", into: chat)
        chat.sendTapped()
        let finished = await waitUntil { await harness.backend.callCount("slash.exec") == 1 }
        XCTAssertTrue(finished)
        let settled = await waitUntil { !chat.isExecutingSlash }
        XCTAssertTrue(settled)
        let declared: [String: Set<String>] = [
            "complete.slash": ["text", "session_id", "profile"],
            "commands.catalog": ["session_id", "profile"],
            "slash.exec": ["session_id", "command", "profile"],
            "command.dispatch": ["name", "arg", "session_id", "profile"],
        ]
        for (method, allowed) in declared {
            for call in await harness.backend.calls(to: method) {
                let keys = Set((call.params.objectValue ?? [:]).keys)
                XCTAssertTrue(keys.isSubset(of: allowed),
                              "\(method) sent \(keys.subtracting(allowed).sorted()), which the backend rejects with 4000")
            }
        }
        let catalogs = await harness.backend.callCount("commands.catalog")
        XCTAssertGreaterThan(catalogs, 0, "the assertion above must have had catalog calls to inspect")
        await harness.tearDown()
    }

    /// A session-less named-profile draft discovers through the declared `profile` parameter (`CompleteSlashParams` and `CommandsCatalogParams` both carry it) instead of creating a backend session because the user typed `/`.
    func testNamedProfileDraftDiscoversThroughProfileWithoutCreatingASession() async throws {
        let harness = await AppHarness.make()
        try await harness.openSocket()
        let index = try XCTUnwrap(harness.app.profiles.firstIndex { $0.id == harness.profileID })
        harness.app.profiles[index].hermesProfile = "research"
        let chat = ChatModel(app: harness.app, summary: nil)
        await harness.backend.stub("commands.catalog") { _ in .object([
            "pairs": .array([.array([.string("/usage"), .string("Usage")])])
        ]) }
        await harness.backend.stub("complete.slash") { _ in .object([
            "items": .array([.object(["text": .string("usage"), "meta": .string("Usage")])]),
            "replace_from": .number(1)
        ]) }
        XCTAssertNotNil(chat.slashCommandAPI, "an open connection can discover for a named-profile draft")
        type("/us", into: chat)
        let asked = await waitUntil { await harness.backend.callCount("complete.slash") == 1 }
        XCTAssertTrue(asked)
        let completes = await harness.backend.calls(to: "complete.slash")
        XCTAssertEqual(completes.first?.params["profile"]?.stringValue, "research")
        XCTAssertNil(completes.first?.params["session_id"])
        let catalogs = await harness.backend.calls(to: "commands.catalog")
        XCTAssertEqual(catalogs.first?.params["profile"]?.stringValue, "research")
        let shown = await waitUntil { chat.slashCompletion.items.first?.display == "/usage" }
        XCTAssertTrue(shown)
        let creates = await harness.backend.callCount("session.create")
        XCTAssertEqual(creates, 0, "typing a slash must not create a backend session")
        XCTAssertNil(chat.runtimeSessionID)
        await harness.tearDown()
    }
}
