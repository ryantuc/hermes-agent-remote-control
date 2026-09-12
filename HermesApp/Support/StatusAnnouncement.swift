import UIKit

/// Decides whether a change in the status line is worth announcing to VoiceOver: phase edges only, so the tool name flickering inside a phase stays silent.
enum StatusAnnouncement {

    /// A rung of the status ladder: two different strings in the same rung are the same event as far as a listener is concerned.
    enum Phase: Equatable {
        case waitingAnswer
        case steered
        case redirected
        case sending
        case thinking
        case foreignWorking
        case foreignWaiting
        case queued
        // No `.stalled` rung: the 8 s threshold is not in `statusLineText` at all, so a case here is one nothing can produce.
        case none
    }

    /// Which rung a status string sits on, matched on the copy `ChatModel.statusLineText` emits.
    static func phase(forStatus status: String?) -> Phase {
        guard let status, !status.isEmpty else { return .none }
        // Order matters, and it is `statusLineText`'s own order: the foreign prefixes are tested before the fallthrough that would otherwise call them thinking.
        if status == "Waiting for your answer" { return .waitingAnswer }
        if status.hasPrefix("Steered — ") { return .steered }
        if status.hasPrefix("Redirected — ") { return .redirected }
        if status == "Sending…" { return .sending }
        if status.hasPrefix("Queued — ") { return .queued }
        if status.hasPrefix("Waiting for input in another client") { return .foreignWaiting }
        if status.hasPrefix("Working in another client") { return .foreignWorking }
        return .thinking
    }

    /// The thing to say, or nil for silence: silent when the phase did not change, and when the new status is nil because a streaming bubble took the surface.
    static func announcement(from old: String?, to new: String?) -> String? {
        guard let new else { return nil }
        guard phase(forStatus: old) != phase(forStatus: new) else { return nil }
        return new
    }

    /// Speaks it; a no-op when VoiceOver is not running, since UIKit drops the notification rather than queueing it.
    static func post(_ message: String) {
        UIAccessibility.post(notification: .announcement, argument: message)
    }
}
