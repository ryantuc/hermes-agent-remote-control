import Foundation

/// The composer's placeholder text, copied verbatim from the desktop client — punctuation included — so the phone does not maintain a second translation.
enum ComposerPlaceholders {
    static let newSession = [
        "What are we building?",
        "Give Hermes a task",
        "What's on your mind?",
        "Describe what you need",
        "What should we tackle?",
        "Ask anything",
        "Start with a goal",
    ]

    static let followUp = [
        "Send a follow-up",
        "Add more context",
        "Refine the request",
        "What's next?",
        "Keep it going",
        "Push it further",
        "Adjust or continue",
    ]

    /// Transport down, cold start.
    static let starting = "Starting Hermes..."

    /// Transport down, and we have been up before.
    static let reconnecting = "Reconnecting to Hermes…"

    /// One phrase from the pool this conversation belongs to; call it when the conversation changes and at no other time.
    static func resting(isNewConversation: Bool) -> String {
        let pool = isNewConversation ? newSession : followUp
        return pool.randomElement() ?? ""
    }
}
