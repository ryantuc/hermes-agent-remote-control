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

    /// - Parameter source: the conversation's `source`, because from 0.22.1 a backend with a gateway refuses every edit to a conversation the phone started with 404 `not_found`, and that refusal deserves its own plain sentence.
    init(action: Action, error: Error, source: String) {
        self.action = action
        title = "Couldn't \(action.verb) this conversation"
        message = Self.reason(for: error, source: source)
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
            case (403, _):
                return "The backend doesn't allow the phone to change this conversation. Nothing was changed."
            default:
                break
            }
        }
        return hermes.errorDescription ?? "The backend refused the change."
    }
}
