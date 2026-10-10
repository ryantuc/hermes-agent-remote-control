import ActivityKit
import HermesServeKit

/// The ActivityKit contract, compiled into both the app and the widget extension, so it may reference nothing app-only (`AppModel`, `Theme`, the app container's defaults).
struct HermesActivityAttributes: ActivityAttributes {
    typealias ContentState = LiveActivitySnapshot

    /// The runtime session id; one card per chat, keyed by this.
    var sessionKey: String
    /// The backend this chat is talking to, shown small under the title.
    var backendName: String
    /// The skin at the moment the card was requested; attributes are immutable for the life of an activity, so a mid-turn skin change does not repaint a live card.
    var skin: LiveActivitySkinSeed
}

/// BUG-062 B. What a card says while its session waits on a person for something other than an approval, which keeps its own copy and buttons.
///
/// The content state is the kit's `LiveActivitySnapshot`, which has no field for the kind of question, and its shape is archived with every card in flight. So the line rides in `statusText`: `LiveActivityController` is the only producer of snapshots, writes one of these lines exactly when the current-request registry has a non-approval request open, and strips them from `statusText` otherwise, so a match here is the registry's word and never the backend's status copy.
enum ParkedQuestion: String, CaseIterable, Sendable {
    /// A clarify, a password or a value: something this phone can answer.
    case answer
    /// A request only Desktop can complete.
    case desktop
    /// A connector sign-in card: an app is waiting to be connected before the turn goes on.
    case signIn

    /// Lock-screen glass: names the kind of wait and nothing else, never the question.
    var line: String {
        switch self {
        case .answer: return "Waiting for your answer"
        case .desktop: return "Continue in Desktop"
        case .signIn: return "Waiting for you to sign in"
        }
    }

    /// The card's one control. It opens the chat, where the question is; there is no intent and no Approve, because a question is answered in the app.
    var linkTitle: String {
        switch self {
        case .answer: return "Answer in Hermes"
        case .desktop, .signIn: return "Open Hermes"
        }
    }

    init?(line: String) {
        guard let match = Self.allCases.first(where: { $0.line == line }) else { return nil }
        self = match
    }

    /// The snapshot a card shows for `parked`: the line in `statusText` and the tool fields blank, because the running tool is the question itself.
    /// With nothing parked, a `statusText` that happens to equal one of the lines is dropped, which is what keeps `LiveActivitySnapshot.parkedQuestion` honest.
    static func applying(_ parked: ParkedQuestion?, to snapshot: LiveActivitySnapshot) -> LiveActivitySnapshot {
        var result = snapshot
        if let parked {
            result.statusText = parked.line
            result.toolName = ""
            result.toolDetail = ""
        } else if ParkedQuestion(line: result.statusText) != nil {
            result.statusText = ""
        }
        return result
    }

    /// The reduced card's line: a constant like every other line it can show, so no session content reaches it. Ended and stale outrank the wait, as they outrank a running turn.
    static func reducedLine(for state: LiveActivitySnapshot, isStale: Bool) -> String {
        if !isStale, state.parkedQuestion != nil { return "Waiting for you" }
        return LiveActivityDerivation.reducedLine(for: state, isStale: isStale)
    }
}

extension LiveActivitySnapshot {
    /// The question this card is parked on, if any; nil once the turn has ended, and nil while an approval holds the card.
    var parkedQuestion: ParkedQuestion? {
        guard !hasEnded, !hasApproval else { return nil }
        return ParkedQuestion(line: statusText)
    }

    /// Someone is being asked something, so the dot goes to warn and stops reading as "Running".
    var isWaitingOnPerson: Bool { hasApproval || parkedQuestion != nil }
}
