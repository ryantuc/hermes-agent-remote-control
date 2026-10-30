import Foundation
import HermesServeKit

/// What the person is told when a rename, pin, archive or delete does not go through, so a refusal is never silent.
struct SessionEditNotice: Identifiable, Equatable {
    enum Action: Equatable {
        case rename, pin, unpin, archive, unarchive, delete

        var verb: String {
            switch self {
            case .rename: return "rename"
            case .pin: return "pin"
            case .unpin: return "unpin"
            case .archive: return "archive"
            case .unarchive: return "unarchive"
            case .delete: return "delete"
            }
        }
    }

    let id = UUID()
    let action: Action
    let title: String
    let message: String

    /// Named in the title, because the notice can arrive after the person has moved on to another conversation.
    ///
    /// The conversation's `source` matters too: from 0.22.1 a backend with a gateway refuses every edit to a conversation the phone started with 404 `not_found`, and that refusal deserves its own plain sentence.
    init(action: Action, error: Error, conversation: SessionSummary) {
        self.action = action
        title = "Couldn't \(action.verb) \(Self.name(of: conversation))"
        message = Self.reason(for: error, source: conversation.source)
    }

    /// The name the hub shows, quoted, or "this conversation" for a row that has neither a title nor a preview.
    static func name(of conversation: SessionSummary) -> String {
        let hasName = conversation.title?.isEmpty == false || !conversation.preview.isEmpty
        return hasName ? "“\(conversation.displayTitle)”" : "this conversation"
    }

    static func reason(for error: Error, source: String) -> String {
        guard let hermes = error as? HermesError else {
            return (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
        if hermes.isTransportFailure {
            return "The backend couldn't be reached. Check the connection and try again."
        }
        if case .httpStatus(let code, let message) = hermes {
            let detail = message.trimmingCharacters(in: .whitespacesAndNewlines)
            switch (code, detail) {
            case (404, "not_found") where source == SessionAPI.sourceTag:
                return "This version of Hermes doesn't let the phone change conversations that were started on the phone. Nothing was changed."
            case (404, "not_found"):
                return "The backend wouldn't change this conversation. Nothing was changed."
            case (404, _):
                return "This conversation is no longer on the backend."
            case (409, "revision_conflict"), (409, "stale_generation"):
                return "This conversation changed somewhere else just now. Try again."
            case (409, "session_busy"):
                return "This conversation is busy right now. Try again when it has finished."
            // 0.22.1 sends every edit to the offline store, which a running gateway refuses with a sentence naming its home folder.
            case (409, let other) where other.hasPrefix("Gateway runtime already owns"):
                return "Hermes's gateway is holding this conversation, so the phone can't change it right now."
            case (403, _):
                return "The backend doesn't allow the phone to change this conversation. Nothing was changed."
            default:
                break
            }
        }
        return hermes.errorDescription ?? "The backend refused the change."
    }
}

/// The notices not yet dismissed, oldest first, so a refusal that lands while another is on screen waits its turn instead of replacing it.
struct SessionEditNoticeQueue: Equatable {
    /// Enough for a burst of taps; older ones are dropped rather than queued without end.
    static let limit = 3

    private(set) var pending: [SessionEditNotice] = []

    /// The one to show now.
    var front: SessionEditNotice? { pending.first }
    /// The most recent refusal.
    var latest: SessionEditNotice? { pending.last }

    mutating func post(_ notice: SessionEditNotice) {
        pending.append(notice)
        if pending.count > Self.limit { pending.removeFirst(pending.count - Self.limit) }
    }

    /// Removes exactly the notice that was on screen, never one that arrived behind it.
    mutating func dismiss(_ id: SessionEditNotice.ID) {
        pending.removeAll { $0.id == id }
    }
}
