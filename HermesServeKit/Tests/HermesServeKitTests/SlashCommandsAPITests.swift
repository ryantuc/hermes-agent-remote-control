import Foundation
import XCTest
@testable import HermesServeKit

final class SlashCommandsAPITests: XCTestCase {
    func testOptionalCatalogMetadataAndPartialWarningsKeepUsableCommands() {
        let catalog = SlashCommandCatalog(json: .object([
            "pairs": .array([.array([.string("/help"), .string("Show help")]), .array([.string("/review"), .string("Review code")])]),
            "skills": .object(["/review": .object([:])]),
            "warning": .string("plugin discovery unavailable"),
            "canon": .object(["/h": .string("/help")]),
        ]))
        XCTAssertEqual(catalog.entries.count, 2)
        XCTAssertEqual(catalog.entry(named: "h")?.description, "Show help")
        XCTAssertEqual(catalog.entry(named: "/review")?.kind, "skill")
        XCTAssertEqual(catalog.warning, "plugin discovery unavailable")
        XCTAssertNil(SlashCommandCatalog(json: .object([:])).warning)
        XCTAssertTrue(SlashCommandCatalog(json: .object([:])).entries.isEmpty)
    }

    func testCatalogCategoriesFindQuickCommandsMissingFromCompletionRPC() {
        let catalog = SlashCommandCatalog(json: .object([
            "categories": .array([.object([
                "name": .string("User commands"),
                "pairs": .array([.array([.string("/check"), .string("Run checks")])]),
            ])]),
        ]))
        XCTAssertEqual(catalog.entry(named: "check")?.kind, "quick")
        XCTAssertEqual(catalog.entry(named: "check")?.category, "User commands")
    }

    func testBareCommandsAndSlashExtrasPreserveOneLeadingSlashAndExistingArguments() throws {
        for insertion in ["help", "/help"] {
            let draft = "/hel arguments\nUnrelated draft 😀"
            let edit = try XCTUnwrap(SlashCompletionText.applying(
                SlashCompletionItem(text: insertion), replaceFrom: 1,
                text: draft, selection: NSRange(location: 4, length: 0)))
            XCTAssertEqual(edit.text, "/help arguments\nUnrelated draft 😀")
            XCTAssertEqual(edit.range, NSRange(location: 1, length: 3))
            XCTAssertEqual(edit.sourceText, draft)
            XCTAssertEqual(edit.selection, NSRange(location: 5, length: 0))
        }
    }

    func testCommandCompletionAtMiddleOfTokenReplacesTailButNotSuffix() throws {
        let edit = try XCTUnwrap(SlashCompletionText.applying(
            SlashCompletionItem(text: "help"), replaceFrom: 1,
            text: "/henonsense keep this", selection: NSRange(location: 3, length: 0)))
        XCTAssertEqual(edit.text, "/help keep this")
    }

    func testArgumentOffsetUsesUnicodeScalarsAndOnlyReplacesItsToken() throws {
        let draft = "/set 😀 ol suffix\nKeep this"
        let edit = try XCTUnwrap(SlashCompletionText.applying(
            SlashCompletionItem(text: "new"), replaceFrom: 7, text: draft,
            selection: NSRange(location: 10, length: 0)))
        XCTAssertEqual(edit.text, "/set 😀 new suffix\nKeep this")
        XCTAssertEqual(edit.range, NSRange(location: 8, length: 2))
        XCTAssertEqual(edit.selection.location, 11)
    }

    func testArgumentAtEndUsesReturnedWhitespaceExactly() throws {
        for insertion in ["new", "new "] {
            let edit = try XCTUnwrap(SlashCompletionText.applying(
                SlashCompletionItem(text: insertion), replaceFrom: 5, text: "/set ol",
                selection: NSRange(location: 7, length: 0)))
            XCTAssertEqual(edit.insertion, insertion)
            XCTAssertEqual(edit.text, "/set " + insertion)
        }
    }

    func testReturnedSeparatorNeverDuplicatesTheExistingSuffix() throws {
        for suffix in [" args\nKeep this", "\targs", "\nKeep this"] {
            let edit = try XCTUnwrap(SlashCompletionText.applying(
                SlashCompletionItem(text: "help "), replaceFrom: 1, text: "/he" + suffix,
                selection: NSRange(location: 3, length: 0)))
            XCTAssertEqual(edit.insertion, "help")
            XCTAssertEqual(edit.text, "/help" + suffix)
        }
    }

    func testMissingArgumentOffsetCannotGuessAndBadRangesDoNotMutateDraft() {
        let item = SlashCompletionItem(text: "new")
        XCTAssertNil(SlashCompletionText.applying(item, replaceFrom: nil, text: "/set old", selection: NSRange(location: 8, length: 0)))
        XCTAssertNil(SlashCompletionText.applying(item, replaceFrom: 90, text: "/set old", selection: NSRange(location: 8, length: 0)))
        XCTAssertNil(SlashCompletionText.applying(item, replaceFrom: -1, text: "/set old", selection: NSRange(location: 8, length: 0)))
        XCTAssertNil(SlashCompletionText.applying(item, replaceFrom: 1, text: "/help", selection: NSRange(location: 1, length: 2)))
    }

    func testCaretCannotSplitUTF16SurrogatePair() {
        let draft = "/set 😀suffix"
        let splitCaret = NSRange(location: 6, length: 0)
        XCTAssertNil(SlashCompletionText.query(text: draft, selection: splitCaret))
        XCTAssertNil(SlashCompletionText.applying(SlashCompletionItem(text: "new"), replaceFrom: 5,
                                                text: draft, selection: splitCaret))
        XCTAssertNil(SlashCompletionText.query(text: draft, selection: NSRange(location: Int.max, length: 0)))
        XCTAssertEqual(SlashCompletionText.query(text: draft, selection: NSRange(location: 5, length: 0)), "/set ")
        XCTAssertEqual(SlashCompletionText.query(text: draft, selection: NSRange(location: 7, length: 0)), "/set 😀")
    }

    func testTriggerRejectsPathsURLsCodeProseAndMarkedText() {
        for draft in ["https://example.com/a", "/usr/bin", "/tmp/file.txt", "look /help", "```\n/help", " /help"] {
            XCTAssertNil(SlashCompletionText.query(text: draft, selection: NSRange(location: draft.utf16.count, length: 0)), draft)
        }
        XCTAssertNil(SlashCompletionText.query(text: "/he", selection: NSRange(location: 3, length: 0), isComposing: true))
        XCTAssertEqual(SlashCompletionText.query(text: "/he rest\ntext", selection: NSRange(location: 3, length: 0)), "/he")
    }

    func testUnsupportedDesktopActionsAndAliasesUseOnePolicy() {
        XCTAssertFalse(SlashCommandSupport.supports(name: "model"))
        for name in ["clear", "quit", "config", "cron", "sb", "reload_mcp", "exit"] {
            XCTAssertFalse(SlashCommandSupport.supports(name: name), name)
        }
        XCTAssertFalse(SlashCommandSupport.supports(name: "future-command", desktopAction: "open-dialog"))
        XCTAssertFalse(SlashCommandSupport.supports(name: "help", desktopAction: "hidden"))
        XCTAssertTrue(SlashCommandSupport.supports(name: "help", desktopAction: "help"))
        XCTAssertFalse(SlashCommandSupport.supports(SlashCatalogEntry(name: "/m", canonicalName: "/model")))
    }

    func testRPCWireParametersAndOlderCompletionWithoutKind() async throws {
        let (client, socket) = try await ScriptedGateway.connected(replies: [
            "complete.slash": [.object(["items": .array([.object(["text": .string("help"), "meta": .string("Help")])]), "replace_from": .number(1)])],
            "commands.catalog": [.object([:])],
            "slash.exec": [.object(["type": .string("skill"), "message": .string("Expanded prompt")])],
            "command.dispatch": [.object(["type": .string("alias"), "target": .string("/help")])],
        ])
        let api = SlashCommandsAPI(client: client)
        let completion = try await api.complete(text: "/he", sessionID: "sid", profile: "research")
        XCTAssertNil(completion.items.first?.kind)
        XCTAssertEqual(completion.replaceFrom, 1)
        _ = try await api.catalog(sessionID: "sid", profile: "research")
        let execution = try await api.execute(sessionID: "sid", line: "/review original arguments")
        XCTAssertEqual(execution.message, "Expanded prompt")
        let dispatch = try await api.dispatch(sessionID: "sid", name: "/review", argument: "original arguments")
        XCTAssertEqual(dispatch.target, "/help")
        // The backend forbids undeclared params keys (4000), and neither discovery method declares `cwd`. A bound session supersedes `profile`.
        let completeParams = await socket.sentParams("complete.slash")
        XCTAssertEqual(completeParams, .object(["text": .string("/he"), "session_id": .string("sid")]))
        let catalogParams = await socket.sentParams("commands.catalog")
        XCTAssertEqual(catalogParams, .object(["session_id": .string("sid")]))
        let executeParams = await socket.sentParams("slash.exec")
        XCTAssertEqual(executeParams?["command"], .string("/review original arguments"))
        let dispatchParams = await socket.sentParams("command.dispatch")
        XCTAssertEqual(dispatchParams?["name"], .string("review"))
        XCTAssertEqual(dispatchParams?["arg"], .string("original arguments"))
        await client.disconnect()
    }

    /// The gateway's params models are `extra="forbid"` and admission answers 4000 for any undeclared key before a handler runs (`tui_gateway/contracts/base.py:32-35`, `tui_gateway/rpc_dispatch.py:27-31`). Declared keys: `complete.slash` text, session_id, profile (`contracts/profiles_vault_complete_foreign_subagents.py:50-56`); `commands.catalog` session_id, profile (`contracts/tools_commands.py:190-192`); `slash.exec` session_id, command, profile (`:282-285`); `command.dispatch` name, arg, session_id, profile (`:257-261`).
    func testEveryRequestCarriesOnlyKeysTheBackendContractDeclares() async throws {
        let (client, socket) = try await ScriptedGateway.connected()
        let api = SlashCommandsAPI(client: client)
        // The widest scope the app can hold: a bound session plus a named profile. Neither method can be handed a `cwd` any more.
        _ = try await api.complete(text: "/he", sessionID: "sid", profile: "research")
        _ = try await api.catalog(sessionID: "sid", profile: "research")
        _ = try await api.execute(sessionID: "sid", line: "usage")
        _ = try await api.dispatch(sessionID: "sid", name: "write", argument: "task")
        let declared: [(String, Set<String>)] = [
            ("complete.slash", ["text", "session_id", "profile"]),
            ("commands.catalog", ["session_id", "profile"]),
            ("slash.exec", ["session_id", "command", "profile"]),
            ("command.dispatch", ["name", "arg", "session_id", "profile"]),
        ]
        for (method, allowed) in declared {
            let params = await socket.sentParams(method)
            let object: [String: JSONValue] = params?.objectValue ?? [:]
            let keys = Set(object.keys)
            XCTAssertFalse(keys.isEmpty, "\(method) was never sent")
            XCTAssertTrue(keys.isSubset(of: allowed), "\(method) sent \(keys.subtracting(allowed).sorted()); the backend answers 4000")
        }
        await client.disconnect()
    }

    func testSessionlessDiscoveryNamesOnlyItsProfile() async throws {
        let (client, socket) = try await ScriptedGateway.connected()
        let api = SlashCommandsAPI(client: client)
        _ = try await api.complete(text: "/he", sessionID: nil, profile: "research")
        _ = try await api.catalog(sessionID: nil, profile: "research")
        let completeParams = await socket.sentParams("complete.slash")
        XCTAssertEqual(completeParams, .object(["text": .string("/he"), "profile": .string("research")]))
        let catalogParams = await socket.sentParams("commands.catalog")
        XCTAssertEqual(catalogParams, .object(["profile": .string("research")]))
        // The launch profile is the absence of a scope, never an empty string.
        _ = try await api.complete(text: "/", sessionID: nil, profile: nil)
        let unscoped = await socket.sentParams("complete.slash")
        XCTAssertEqual(unscoped, .object(["text": .string("/")]))
        await client.disconnect()
    }
}
