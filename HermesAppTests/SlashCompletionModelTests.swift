import Foundation
import HermesServeKit
import XCTest
@testable import HermesMobile

@MainActor
final class SlashCompletionModelTests: XCTestCase {
    private let scope = SlashCompletionScope(backendID: "one", profileID: "default", connectionID: "socket-1")

    private func update(_ model: SlashCompletionModel, _ text: String, api: (any SlashCommandDiscovering)? = nil,
                        scope: SlashCompletionScope? = nil, paste: Bool = false, external: Bool = false,
                        composing: Bool = false, caret: Int? = nil, editedRange: NSRange? = nil, userEdit: Bool = true) {
        model.update(text: text, selection: NSRange(location: caret ?? text.utf16.count, length: 0),
                     isComposing: composing, isPaste: paste, isExternal: external, editedRange: editedRange,
                     isUserEdit: userEdit, scope: scope ?? self.scope, api: api)
    }

    func testPasteAndProgrammaticDraftNeverBecomeCommandsByEditingArguments() {
        let model = SlashCompletionModel(debounce: .zero)
        update(model, "/help", paste: true)
        XCTAssertFalse(model.commandIntent(for: "/help"))
        update(model, "/help explain this")
        XCTAssertFalse(model.commandIntent(for: "/help explain this"))
        XCTAssertTrue(model.items.isEmpty)
        update(model, "")
        update(model, "/help")
        XCTAssertTrue(model.commandIntent(for: "/help"))
        model.dismiss()
        XCTAssertTrue(model.commandIntent(for: "/help"), "Escape hides suggestions without changing send semantics")
        update(model, "/status", external: true)
        XCTAssertFalse(model.commandIntent(for: "/status"))
    }

    func testPastedArgumentsPreserveTypedCommandButPastedLeadingTokenDoesNot() {
        let model = SlashCompletionModel(debounce: .zero)
        update(model, "/review")
        update(model, "/review pasted context", paste: true, editedRange: NSRange(location: 7, length: 0))
        XCTAssertTrue(model.commandIntent(for: "/review pasted context"))
        update(model, "/review pasted context\nQuoted attachment", external: true)
        XCTAssertTrue(model.commandIntent(for: "/review pasted context\nQuoted attachment"))
        update(model, "/review copied prose", paste: true, editedRange: NSRange(location: 0, length: 41))
        XCTAssertFalse(model.commandIntent(for: "/review copied prose"))
    }

    func testSameDraftRetainsTypedOrLiteralProvenanceAcrossReconnectAndRemount() {
        let model = SlashCompletionModel(debounce: .zero)
        update(model, "/help")
        let reconnected = SlashCompletionScope(backendID: "one", profileID: "default", connectionID: "socket-2")
        update(model, "/help", scope: reconnected, userEdit: false)
        XCTAssertTrue(model.commandIntent(for: "/help"))
        model.invalidate()
        update(model, "/help", scope: reconnected, external: true, userEdit: false)
        XCTAssertTrue(model.commandIntent(for: "/help"))
        update(model, "/help", scope: reconnected, paste: true, editedRange: NSRange(location: 0, length: 5))
        model.invalidate()
        update(model, "/help", scope: reconnected, userEdit: false)
        XCTAssertFalse(model.commandIntent(for: "/help"))
        update(model, "/help prose", scope: reconnected)
        XCTAssertFalse(model.commandIntent(for: "/help prose"))
    }

    func testPathsAndIMELeaveCompositionAlone() {
        let model = SlashCompletionModel(debounce: .zero)
        update(model, "/usr/bin")
        XCTAssertFalse(model.commandIntent(for: "/usr/bin"))
        update(model, "")
        update(model, "/help", composing: true)
        XCTAssertFalse(model.commandIntent(for: "/help"))
        XCTAssertTrue(model.items.isEmpty)
    }

    func testCatalogMergesQuickCommandsAndKeepsPartialWarningWhenCompletionIsAbsent() async {
        let probe = SlashProbe(catalog: SlashCommandCatalog(entries: [
            SlashCatalogEntry(name: "/check", description: "Run checks", category: "User commands", kind: "quick"),
            SlashCatalogEntry(name: "/new", description: "Start a new session"),
        ], warning: "Some plugins could not be discovered"), failCompletion: true)
        addTeardownBlock { await probe.finish() }
        let model = SlashCompletionModel(debounce: .zero)
        update(model, "/", api: probe)
        await settle { model.items.map(\.display) == ["/check"] }
        XCTAssertEqual(model.items.map(\.display), ["/check"])
        XCTAssertEqual(model.notice, "Some plugins could not be discovered")
        XCTAssertEqual(model.advertisedEntry(named: "check")?.kind, "quick")
        let edit = model.selectedItem.flatMap { model.replacement(for: $0) }
        XCTAssertEqual(edit?.text, "/check ")
        model.invalidate()
    }

    func testTransientCatalogFailureRetriesOnNextEdit() async {
        let probe = SlashProbe(catalog: SlashCommandCatalog(entries: [SlashCatalogEntry(name: "/check")]),
                               failCompletion: true, catalogFailures: 1)
        addTeardownBlock { await probe.finish() }
        let model = SlashCompletionModel(debounce: .zero)
        update(model, "/", api: probe)
        await settleAsync { await probe.catalogCalls() == 1 }
        await settle { model.notice != nil }
        update(model, "/ch", api: probe)
        await settle { model.items.first?.display == "/check" }
        XCTAssertEqual(model.items.first?.display, "/check")
        model.invalidate()
    }

    /// A 4000 is the gateway's params admission refusing the request's shape (`tui_gateway/rpc_dispatch.py:27-31`): as definite as a missing method, so it is not resent on every keystroke. An older backend refuses `profile` on `complete.slash` while its catalog accepts it, so catalog rows stay offered; a new scope is asked again.
    func testContractRefusalRetiresCompletionForTheScopeOnly() async {
        let probe = SlashProbe(
            catalog: SlashCommandCatalog(entries: [SlashCatalogEntry(name: "/check", description: "Run checks")]),
            completionError: HermesError.rpc(code: 4000, message: "invalid params for complete.slash: profile: Extra inputs are not permitted")
        )
        addTeardownBlock { await probe.finish() }
        let model = SlashCompletionModel(debounce: .zero)
        update(model, "/", api: probe)
        await settleAsync { await probe.completeCalls() == 1 }
        // The refusal has been handled (it sets the notice) before the next keystroke arrives.
        await settle { model.notice != nil }
        await settle { model.items.map(\.display) == ["/check"] }
        update(model, "/c", api: probe)
        update(model, "/ch", api: probe)
        await settle { model.items.first?.display == "/check" }
        for _ in 0..<200 { await Task.yield() }
        let repeated = await probe.completeCalls()
        XCTAssertEqual(repeated, 1, "a refused request shape is not resent on every keystroke")
        let bound = SlashCompletionScope(backendID: "one", profileID: "default", sessionID: "bound", connectionID: "socket-1")
        update(model, "/ch", api: probe, scope: bound)
        await settleAsync { await probe.completeCalls() == 2 }
        let retried = await probe.completeCalls()
        XCTAssertEqual(retried, 2, "a new scope is a different request and may be accepted")
        model.invalidate()
    }

    func testLateDraftAndCursorRepliesCannotRestoreOldSuggestions() async {
        let probe = SlashProbe()
        addTeardownBlock { await probe.finish() }
        let model = SlashCompletionModel(debounce: .zero)
        update(model, "/he", api: probe)
        await settleAsync { await probe.hasRequest("/he") }
        update(model, "/st", api: probe)
        await settleAsync { await probe.hasRequest("/st") }
        await probe.reply("/st", items: [SlashCompletionItem(text: "status", meta: "Status")])
        await settle { model.items.first?.text == "status" }
        await probe.reply("/he", items: [SlashCompletionItem(text: "help", meta: "Help")])
        await Task.yield()
        XCTAssertEqual(model.items.first?.text, "status")
        // A caret-only move also retires the old request even if the draft stays identical.
        update(model, "/sta", api: probe)
        await settleAsync { await probe.hasRequest("/sta") }
        update(model, "/sta", api: probe, caret: 0)
        await probe.reply("/sta", items: [SlashCompletionItem(text: "status")])
        await Task.yield()
        XCTAssertTrue(model.items.isEmpty)
        model.invalidate()
    }

    func testProfileChangeAndInvalidationFenceRepliesAndCachedCommands() async {
        let oldProbe = SlashProbe()
        let newProbe = SlashProbe()
        addTeardownBlock {
            await oldProbe.finish()
            await newProbe.finish()
        }
        let model = SlashCompletionModel(debounce: .zero)
        update(model, "/he", api: oldProbe)
        await settleAsync { await oldProbe.hasRequest("/he") }
        let other = SlashCompletionScope(backendID: "two", profileID: "research", connectionID: "socket-2")
        update(model, "", api: newProbe, scope: other)
        update(model, "/st", api: newProbe, scope: other)
        await settleAsync { await newProbe.hasRequest("/st") }
        await oldProbe.reply("/he", items: [SlashCompletionItem(text: "help")])
        await newProbe.reply("/st", items: [SlashCompletionItem(text: "status")])
        await settle { model.items.first?.text == "status" }
        XCTAssertNil(model.advertisedEntry(named: "help"))
        update(model, "/sta", api: newProbe, scope: other)
        await settleAsync { await newProbe.hasRequest("/sta") }
        model.invalidate()
        await newProbe.reply("/sta", items: [SlashCompletionItem(text: "status")])
        await Task.yield()
        XCTAssertTrue(model.items.isEmpty)
        XCTAssertNil(model.advertisedEntry(named: "status"))
    }

    private func settle(_ predicate: () -> Bool) async {
        for _ in 0..<1000 {
            if predicate() { return }
            await Task.yield()
        }
        XCTFail("Completion state did not settle")
    }

    private func settleAsync(_ predicate: () async -> Bool) async {
        for _ in 0..<1000 {
            if await predicate() { return }
            await Task.yield()
        }
        XCTFail("Completion request did not start")
    }
}

private actor SlashProbe: SlashCommandDiscovering {
    let result: SlashCommandCatalog
    let failCompletion: Bool
    let completionError: HermesError?
    var catalogFailures: Int
    var catalogCallCount = 0
    var completeCallCount = 0
    var pending: [String: [CheckedContinuation<SlashCompletionResult, Error>]] = [:]

    init(catalog: SlashCommandCatalog = SlashCommandCatalog(), failCompletion: Bool = false, catalogFailures: Int = 0,
         completionError: HermesError? = nil) {
        result = catalog
        self.failCompletion = failCompletion
        self.catalogFailures = catalogFailures
        self.completionError = completionError
    }

    func catalog(sessionID: String?, profile: String?) async throws -> SlashCommandCatalog {
        catalogCallCount += 1
        if catalogFailures > 0 {
            catalogFailures -= 1
            throw HermesError.requestTimedOut(method: "commands.catalog", seconds: 5)
        }
        return result
    }
    func catalogCalls() -> Int { catalogCallCount }
    func completeCalls() -> Int { completeCallCount }
    func complete(text: String, sessionID: String?, profile: String?) async throws -> SlashCompletionResult {
        completeCallCount += 1
        if let completionError { throw completionError }
        if failCompletion { throw HermesError.rpc(code: -32601, message: "Method not found") }
        return try await withCheckedThrowingContinuation { pending[text, default: []].append($0) }
    }
    func hasRequest(_ text: String) -> Bool { pending[text] != nil }
    func reply(_ text: String, items: [SlashCompletionItem]) {
        pending.removeValue(forKey: text)?.forEach {
            $0.resume(returning: SlashCompletionResult(items: items, replaceFrom: 1))
        }
    }
    func finish() {
        let continuations = pending.values.flatMap { $0 }
        pending = [:]
        continuations.forEach { $0.resume(throwing: CancellationError()) }
    }
}
