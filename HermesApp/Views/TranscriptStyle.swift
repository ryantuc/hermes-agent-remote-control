import HermesServeKit
import SwiftUI

/// How a transcript speaks. Presentation follows the thread rather than the app mode, so a bot thread renders in conversation grammar wherever it is reached from; `.session` is the environment default, so a view that does not set the key keeps its current behaviour.
enum TranscriptStyle: String, Hashable, Sendable, CaseIterable {
    /// Bare assistant prose on the canvas, the always-visible `MessageActionRow`, inline tool cards and an inline reasoning disclosure.
    case session
    /// Left-aligned bot bubbles, with tools and reasoning folded into one disclosure line under the bubble.
    case conversation

    /// Which grammar a chat renders in. An empty `botProfile` is treated as nil, because a coerced `""` off the wire is an absent profile and not a bot named "".
    static func resolve(explicit: TranscriptStyle?, botProfile: String?) -> TranscriptStyle {
        if let explicit { return explicit }
        guard let botProfile, !botProfile.isEmpty else { return .session }
        return .conversation
    }
}

private struct TranscriptStyleKey: EnvironmentKey {
    static let defaultValue = TranscriptStyle.session
}

extension EnvironmentValues {
    /// Read by `MessageBubbleView` and the views it composes; set once, by `ChatView`, from `TranscriptStyle.resolve`.
    var transcriptStyle: TranscriptStyle {
        get { self[TranscriptStyleKey.self] }
        set { self[TranscriptStyleKey.self] = newValue }
    }
}

/// What `ChatView` needs to know about a bot thread to render one, as one value rather than two loose optionals because the two answers have to agree. Both nil resolves to `.session`.
struct BotThreadIdentity: Equatable {
    var profile: String?
    var displayName: String?

    init(profile: String? = nil, displayName: String? = nil) {
        self.profile = profile
        self.displayName = displayName
    }
}

// MARK: - Conversation grouping

/// One row of a `.conversation` transcript. The wire gives a flat array of `ChatEntry` kinds with reasoning as a field rather than a kind, and conversation grammar needs one more level so a turn's tool calls sit under its bubble.
enum ConversationItem: Identifiable, Equatable {
    /// Rendered as Sessions mode renders it: user turns, notices, system rows.
    case entry(ChatEntry)
    /// A bot turn: the assistant entry plus the tool entries that ran for it.
    case turn(assistant: ChatEntry, tools: [ChatEntry])
    /// Tool entries with no assistant entry after them yet, which is the mid-turn state and also a run the conversation moved on from.
    case pendingTools([ChatEntry])

    var id: String {
        switch self {
        case .entry(let entry): return entry.id
        case .turn(let assistant, _): return assistant.id
        case .pendingTools(let tools): return "pending-\(tools.first?.id ?? "")"
        }
    }

    var timestamp: Date {
        switch self {
        case .entry(let entry): return entry.timestamp
        // The turn is stamped by its tools when it has them, because they ran first and a day separator has to land before the work.
        case .turn(let assistant, let tools): return tools.first?.timestamp ?? assistant.timestamp
        case .pendingTools(let tools): return tools.first?.timestamp ?? Date()
        }
    }
}

/// Folds the flat transcript into conversation rows: consecutive tools preceding an assistant entry fold under that entry. Consecutive is load-bearing, because a user turn between a tool run and the next answer means the run belonged to the turn before it.
enum ConversationGrouping {
    static func group(_ entries: [ChatEntry]) -> [ConversationItem] {
        var items: [ConversationItem] = []
        var run: [ChatEntry] = []

        func flushRun() {
            guard !run.isEmpty else { return }
            items.append(.pendingTools(run))
            run.removeAll()
        }

        for entry in entries {
            switch entry.kind {
            case .tool:
                run.append(entry)
            case .assistant:
                items.append(.turn(assistant: entry, tools: run))
                run.removeAll()
            case .user, .notice, .system:
                flushRun()
                items.append(.entry(entry))
            }
        }
        flushRun()
        return items
    }
}
