import Foundation
import HermesServeKit
import Observation

struct SlashCompletionScope: Sendable, Hashable {
    let backendID: String
    let profileID: String
    var sessionID: String? = nil
    /// Identity only: a workspace change retires cached discovery, but no discovery RPC declares a `cwd` parameter.
    var cwd: String? = nil
    var connectionID: String = ""
    /// The wire value for a session-less request, nil for the backend's launch profile. A bound session supersedes it.
    var profile: String? = nil
}

/// Discovery never writes the draft. Every response is fenced by connection, profile, text, and caret.
@MainActor
@Observable
final class SlashCompletionModel {
    private(set) var items: [SlashCompletionItem] = []
    private(set) var selectedIndex = 0
    private(set) var notice: String?
    private(set) var catalog: SlashCommandCatalog?

    @ObservationIgnored private var requestTask: Task<Void, Never>?
    @ObservationIgnored private var catalogTask: Task<Void, Never>?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var scope: SlashCompletionScope?
    @ObservationIgnored private var sourceText = ""
    @ObservationIgnored private var sourceSelection = NSRange(location: 0, length: 0)
    @ObservationIgnored private var query: String?
    @ObservationIgnored private var result: SlashCompletionResult?
    @ObservationIgnored private var advertised: [String: SlashCatalogEntry] = [:]
    @ObservationIgnored private var catalogAttempted = false
    @ObservationIgnored private var completionUnavailable = false
    @ObservationIgnored private var literalSlashDraft = false
    @ObservationIgnored private var typedSlashIntent = false
    @ObservationIgnored private var dismissedText: String?
    @ObservationIgnored private let debounce: Duration

    init(debounce: Duration = .milliseconds(140)) { self.debounce = debounce }

    var selectedItem: SlashCompletionItem? {
        items.indices.contains(selectedIndex) ? items[selectedIndex] : nil
    }

    func commandIntent(for text: String) -> Bool {
        typedSlashIntent && !literalSlashDraft && SlashCompletionText.commandName(in: text) != nil
            && SlashCompletionText.commandName(in: text) == SlashCompletionText.commandName(in: sourceText)
    }

    func advertisedEntry(named name: String) -> SlashCatalogEntry? {
        catalog?.entry(named: name) ?? advertised[SlashCommandSupport.normalizedName(name)]
    }

    func update(text: String, selection: NSRange, isComposing: Bool, isPaste: Bool,
                isExternal: Bool = false, editedRange: NSRange? = nil, isUserEdit: Bool = true,
                scope newScope: SlashCompletionScope,
                api: (any SlashCommandDiscovering)?) {
        let previousText = sourceText
        let previousCommand = SlashCompletionText.commandName(in: previousText)
        let sameTypedCommand = typedSlashIntent && !literalSlashDraft && previousCommand != "/"
            && previousCommand == SlashCompletionText.commandName(in: text)
        let priorTokenLength = previousText.prefix { !$0.isWhitespace }.utf16.count
        let changedScope = scope != newScope
        if changedScope {
            requestTask?.cancel()
            catalogTask?.cancel()
            catalogTask = nil
            catalogAttempted = false
            completionUnavailable = false
            catalog = nil
            advertised = [:]
            notice = nil
            dismissedText = nil
            scope = newScope
        }
        generation += 1
        let currentGeneration = generation
        requestTask?.cancel()
        sourceText = text
        sourceSelection = selection
        result = nil
        items = []
        selectedIndex = 0
        query = nil

        if !text.hasPrefix("/") {
            literalSlashDraft = false
            typedSlashIntent = false
            dismissedText = nil
        } else if isPaste {
            // Pasting arguments after a deliberately typed command does not turn it into prose.
            // Replacing the leading token, even with the identical spelling, establishes a literal draft.
            if !(sameTypedCommand && (editedRange?.location ?? 0) >= priorTokenLength) {
                literalSlashDraft = true
                typedSlashIntent = false
            }
        } else if isExternal {
            if !(text == previousText || (sameTypedCommand && text.hasPrefix(previousText))) {
                literalSlashDraft = true
                typedSlashIntent = false
            }
        } else if isUserEdit && !isComposing && !literalSlashDraft {
            typedSlashIntent = SlashCompletionText.commandName(in: text) != nil
        }
        guard typedSlashIntent, !literalSlashDraft,
              let query = SlashCompletionText.query(text: text, selection: selection, isComposing: isComposing),
              dismissedText != text else {
            notice = nil
            return
        }
        self.query = query
        guard let api else {
            notice = "Command suggestions are unavailable while disconnected."
            return
        }
        notice = catalog?.warning
        if !catalogAttempted {
            catalogAttempted = true
            catalogTask = Task { [weak self] in
                do {
                    let catalog = try await api.catalog(sessionID: newScope.sessionID, profile: newScope.profile)
                    guard !Task.isCancelled, let self, self.scope == newScope else { return }
                    self.catalog = catalog
                    if self.query != nil {
                        self.notice = catalog.warning
                        self.refreshItems()
                    }
                } catch {
                    // A missing catalog must not discard a successful completion response.
                    guard !Task.isCancelled, let self, self.scope == newScope else { return }
                    self.catalogAttempted = Self.isDefiniteRefusal(error)
                    if self.completionUnavailable, self.query != nil {
                        self.notice = "Command discovery is unavailable on this backend. Your draft is unchanged."
                    }
                }
            }
        }
        refreshItems()
        guard !completionUnavailable else { return }
        requestTask = Task { [weak self] in
            do {
                guard let self else { return }
                try await Task.sleep(for: self.debounce)
                let response = try await api.complete(text: query, sessionID: newScope.sessionID, profile: newScope.profile)
                guard !Task.isCancelled, self.generation == currentGeneration, self.scope == newScope,
                      self.sourceText == text, self.sourceSelection == selection else { return }
                self.result = response
                self.refreshItems()
            } catch {
                guard !Task.isCancelled, let self, self.scope == newScope else { return }
                // A refusal is a property of the scope, not of this keystroke's text, so it is recorded even when a newer edit owns the display.
                if Self.isDefiniteRefusal(error) {
                    self.completionUnavailable = true
                }
                guard self.generation == currentGeneration else { return }
                self.notice = self.catalog?.warning ?? "Command suggestions are unavailable. Your draft is unchanged."
                self.refreshItems()
            }
        }
    }

    /// The person chose to send this draft as words: it stays literal until its leading slash goes (FEAT-043, Send as text).
    func markLiteral() {
        literalSlashDraft = true
        typedSlashIntent = false
        dismiss()
    }

    func dismiss() {
        generation += 1
        requestTask?.cancel()
        dismissedText = sourceText
        query = nil
        result = nil
        items = []
        selectedIndex = 0
        notice = nil
    }

    /// Leaving the composer also retires catalog replies. Cached names cannot cross a new connection.
    func invalidate() {
        dismiss()
        catalogTask?.cancel()
        catalogTask = nil
        scope = nil
        catalog = nil
        advertised = [:]
        catalogAttempted = false
        completionUnavailable = false
        // Keep same-draft provenance across remount/reconnect; a selection callback cannot re-arm pasted text.
    }

    /// A missing method (-32601), or the gateway's params admission refusing the request's shape (4000, `tui_gateway/rpc_dispatch.py`), cannot succeed again for this scope, so it is not resent per keystroke; a new scope asks again. A timeout or a dropped socket proves nothing and is retried on the next edit.
    private static func isDefiniteRefusal(_ error: Error) -> Bool {
        guard case HermesError.rpc(let code, _, _) = error else { return false }
        return code == -32601 || code == 4000
    }

    func moveSelection(by delta: Int) {
        guard !items.isEmpty else { return }
        selectedIndex = (selectedIndex + delta % items.count + items.count) % items.count
    }

    func replacement(for item: SlashCompletionItem) -> SlashCompletionEdit? {
        guard items.contains(item), let query else { return nil }
        // Catalog-only command rows have the same leading-slash insertion contract.
        let offset = query.contains(" ") ? result?.replaceFrom : (result?.replaceFrom ?? 1)
        return SlashCompletionText.applying(item, replaceFrom: offset, text: sourceText, selection: sourceSelection)
    }

    private func refreshItems() {
        guard let query else { return }
        let commandStage = !query.contains(" ")
        let oldSelected = selectedItem?.id
        var merged: [SlashCompletionItem] = []
        var seen = Set<String>()
        for item in result?.items ?? [] {
            if commandStage {
                let name = SlashCommandSupport.normalizedName(item.text)
                let entry = catalog?.entry(named: name)
                let interfaceLine = SlashCommandSupport.interfaceCommands[name]
                guard interfaceLine != nil || (entry.map({ SlashCommandSupport.supports($0) }) ?? SlashCommandSupport.supports(name: name)) else { continue }
                guard seen.insert(name).inserted else { continue }
                let projected = SlashCompletionItem(text: item.text,
                    display: item.display.hasPrefix("/") ? item.display : name,
                    meta: interfaceLine ?? (item.meta.isEmpty ? entry?.description ?? "" : item.meta),
                    kind: item.kind == "skill" ? "skill" : entry?.kind ?? item.kind)
                merged.append(projected)
                advertised[name] = entry ?? SlashCatalogEntry(name: name, description: projected.meta, kind: projected.kind)
            } else {
                merged.append(item)
            }
        }
        if commandStage, let catalog {
            let needle = String(query.dropFirst()).lowercased()
            for entry in catalog.entries where SlashCommandSupport.supports(entry) || SlashCommandSupport.interfaceCommands[entry.name] != nil {
                guard needle.isEmpty || entry.name.lowercased().contains(needle) || entry.description.lowercased().contains(needle) else { continue }
                guard seen.insert(entry.name).inserted else { continue }
                merged.append(SlashCompletionItem(text: String(entry.name.dropFirst()), display: entry.name,
                                                 meta: SlashCommandSupport.interfaceCommands[entry.name] ?? entry.description, kind: entry.kind ?? entry.category))
                advertised[entry.name] = entry
            }
        }
        if !commandStage, let name = SlashCompletionText.commandName(in: query),
           SlashCommandSupport.unavailableReason(name: name, entry: advertisedEntry(named: name)) != nil {
            merged = []
        }
        items = Array(merged.prefix(30))
        selectedIndex = oldSelected.flatMap { id in items.firstIndex { $0.id == id } } ?? 0
    }
}
