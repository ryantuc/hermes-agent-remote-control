import Foundation
import HermesServeKit

/// `/model` is the model drawer on a phone, as it is on Desktop (`apps/desktop/src/app/session/hooks/use-prompt-actions/slash.ts`, `openPicker`). On its own it opens the drawer the model button opens. With a name after it, it picks that model when the backend offers exactly one by that name, and opens the drawer otherwise. Either way nothing is sent and no conversation is created.
@MainActor
enum ModelCommand {
    enum Request: Equatable {
        case picker
        case select(String)
    }

    enum Outcome: Equatable {
        case openPicker
        case selected(slug: String)
        case failed(String)
    }

    /// One model on one provider, as the drawer writes it.
    struct Choice: Equatable {
        let slug: String
        let providerSlug: String
    }

    /// What a draft asks for when it is a `/model` command; nil for anything else, `/models` included.
    nonisolated static func request(in draft: String) -> Request? {
        guard SlashCompletionText.commandName(in: draft) == "/model" else { return nil }
        let argument = draft.dropFirst("/model".count).trimmingCharacters(in: .whitespacesAndNewlines)
        return argument.isEmpty ? .picker : .select(argument)
    }

    /// What the drawer's search field opens with: the name that matched nothing, so the person continues from it.
    nonisolated static func searchText(for request: Request) -> String {
        if case .select(let text) = request { return text }
        return ""
    }

    /// The command Send would run instead of sending, when the draft is a typed `/model`. A pasted `/model` is words, and an edit in progress sends as the edit.
    static func pending(in chat: ChatModel) -> Request? {
        guard chat.editingEntryID == nil, !chat.isExecutingSlash,
              chat.slashCompletion.commandIntent(for: chat.draft) else { return nil }
        return request(in: chat.draft)
    }

    /// The model `text` names among those the backend offers on a connected provider: an exact slug, else an exact name, else the only model whose name or slug contains the text. A looser rule is tried only when a stricter one matched nothing, so a name that matches two models opens the drawer rather than picking one. A model served by several providers is the current provider's, or ambiguous when none of them is current.
    nonisolated static func match(_ text: String, in catalogue: ModelCatalogue) -> Choice? {
        let needle = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return nil }
        let offered = catalogue.providers.filter(\.authenticated).flatMap { provider in
            provider.models.map { (provider: provider, model: $0) }
        }
        let rules: [(ModelRow) -> Bool] = [
            { $0.slug.lowercased() == needle },
            { $0.name.lowercased() == needle },
            { $0.name.lowercased().contains(needle) || $0.slug.lowercased().contains(needle) },
        ]
        for rule in rules {
            let hits = offered.filter { rule($0.model) }
            guard !hits.isEmpty else { continue }
            guard Set(hits.map { $0.model.slug }).count == 1 else { return nil }
            let hit = hits.count == 1 ? hits.first : hits.first(where: { $0.provider.isCurrent })
            return hit.map { Choice(slug: $0.model.slug, providerSlug: $0.provider.slug) }
        }
        return nil
    }

    /// Runs the request against the backend. A draft takes the choice locally and `session.create` carries it, exactly as the drawer does; a live conversation writes it to its own session. Anything the drawer would have to ask about (an expensive model, a model it cannot match, a catalogue that would not load) opens the drawer, which asks.
    static func perform(_ request: Request, on chat: ChatModel, app: AppModel) async -> Outcome {
        guard case .select(let text) = request else { return .openPicker }
        guard let configAPI = app.configAPI else { return .failed("Not connected to a backend.") }
        guard let catalogue = try? await configAPI.modelOptions(),
              let choice = match(text, in: catalogue) else { return .openPicker }
        if chat.isDraft {
            chat.draftModelSlug = choice.slug
            chat.draftProviderSlug = choice.providerSlug
            return .selected(slug: choice.slug)
        }
        // Without a session id `config.set` writes the backend's global default, for every client.
        guard let sessionID = chat.runtimeSessionID else { return .openPicker }
        do {
            let result = try await configAPI.set("model", value: .string(choice.slug), sessionID: sessionID)
            if result.confirmRequired { return .openPicker }
            if result.deferred { chat.pendingModelWrite = true }
            return .selected(slug: choice.slug)
        } catch {
            return .failed((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        }
    }

    /// What the composer shows afterwards. The command leaves the composer once it has run, unless the person has typed over it meanwhile; a failure keeps it, with the reason on the error row.
    static func apply(_ outcome: Outcome, typed: String, to chat: ChatModel, openPicker: () -> Void) {
        switch outcome {
        case .openPicker, .selected:
            chat.errorMessage = nil
            if chat.draft == typed { chat.draft = "" }
            if outcome == .openPicker { openPicker() }
        case .failed(let message):
            chat.errorMessage = message
        }
    }
}
