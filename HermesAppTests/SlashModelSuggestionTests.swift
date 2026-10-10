import Foundation
import HermesServeKit
import XCTest
@testable import HermesMobile

/// "/model" is answered by the composer (it opens the model drawer), so the suggestion list offers it, describing what it does here rather than the backend's terminal wording, even though the backend marks it hidden from Desktop's list. Its arguments are not suggested: the drawer is where a model is chosen.
@MainActor
final class SlashModelSuggestionTests: XCTestCase {
    private let scope = SlashCompletionScope(backendID: "one", profileID: "default", connectionID: "socket-1")

    private func type(_ text: String, into model: SlashCompletionModel, api: any SlashCommandDiscovering) {
        model.update(text: text, selection: NSRange(location: text.utf16.count, length: 0),
                     isComposing: false, isPaste: false, isExternal: false, editedRange: nil,
                     isUserEdit: true, scope: scope, api: api)
    }

    private func settle(_ predicate: () -> Bool) async {
        for _ in 0..<200 {
            if predicate() { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    func testModelIsListedFromTheBackendsCompletionsAsOpeningThePicker() async {
        let probe = ModelSuggestionProbe(
            completion: SlashCompletionResult(items: [
                SlashCompletionItem(text: "/model", meta: "Switch model (session-scoped; --global to persist)"),
                SlashCompletionItem(text: "/new", meta: "Start a new session"),
            ], replaceFrom: 1),
            catalog: SlashCommandCatalog(entries: [
                SlashCatalogEntry(name: "/model", description: "Switch model (session-scoped; --global to persist)", desktopAction: "hidden"),
            ]))
        let model = SlashCompletionModel(debounce: .zero)
        type("/mo", into: model, api: probe)
        await settle { model.items.contains { $0.display == "/model" } }
        let row = model.items.first { $0.display == "/model" }
        XCTAssertNotNil(row, "/model is missing from the list: \(model.items.map(\.display))")
        XCTAssertEqual(row?.meta, "Open the model picker")
        XCTAssertFalse(model.items.contains { $0.display == "/new" }, "an unavailable command was listed")
    }

    func testModelIsListedFromTheCatalogWhenCompletionIsAbsent() async {
        let probe = ModelSuggestionProbe(
            completion: nil,
            catalog: SlashCommandCatalog(entries: [
                SlashCatalogEntry(name: "/model", description: "Switch model (session-scoped; --global to persist)", desktopAction: "hidden"),
            ]))
        let model = SlashCompletionModel(debounce: .zero)
        type("/", into: model, api: probe)
        await settle { model.items.map(\.display) == ["/model"] }
        XCTAssertEqual(model.items.map(\.display), ["/model"])
        XCTAssertEqual(model.items.first?.meta, "Open the model picker")
    }

    func testModelArgumentsAreNotSuggested() async {
        let probe = ModelSuggestionProbe(
            completion: SlashCompletionResult(items: [SlashCompletionItem(text: "--global", meta: "Persist")], replaceFrom: 7),
            catalog: SlashCommandCatalog(entries: [SlashCatalogEntry(name: "/model")]))
        let model = SlashCompletionModel(debounce: .zero)
        type("/model --g", into: model, api: probe)
        try? await Task.sleep(for: .milliseconds(300))
        XCTAssertTrue(model.items.isEmpty, "argument suggestions for /model: \(model.items.map(\.display))")
    }

    func testDispatchStillRefusesModelSoItIsNeverSent() {
        XCTAssertFalse(SlashCommandSupport.supports(name: "model"))
        XCTAssertEqual(SlashCommandSupport.interfaceCommands["/model"], "Open the model picker")
    }
}

private actor ModelSuggestionProbe: SlashCommandDiscovering {
    let completion: SlashCompletionResult?
    let catalogReply: SlashCommandCatalog

    init(completion: SlashCompletionResult?, catalog: SlashCommandCatalog) {
        self.completion = completion
        catalogReply = catalog
    }

    func complete(text: String, sessionID: String?, profile: String?) async throws -> SlashCompletionResult {
        guard let completion else { throw HermesError.rpc(code: -32601, message: "Method not found", data: nil) }
        return completion
    }

    func catalog(sessionID: String?, profile: String?) async throws -> SlashCommandCatalog {
        catalogReply
    }
}
