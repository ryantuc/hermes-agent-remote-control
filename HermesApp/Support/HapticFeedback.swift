import SwiftUI
import UIKit

/// Haptics for the moments that matter on a phone; `approvalRequested` has to be impossible to miss, because an `approval.request` blocks the agent for ~300 s and then fails the tool closed.
@MainActor
enum HapticFeedback {
    static func approvalRequested() {
        let generator = UINotificationFeedbackGenerator()
        generator.prepare()
        generator.notificationOccurred(.warning)
    }

    static func turnCompleted() {
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    static func turnFailed() {
        UINotificationFeedbackGenerator().notificationOccurred(.error)
    }

    static func sent() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    static func decisionSubmitted(isDeny: Bool) {
        UIImpactFeedbackGenerator(style: isDeny ? .rigid : .medium).impactOccurred()
    }

    static func selection() {
        UISelectionFeedbackGenerator().selectionChanged()
    }

    /// BUG-117: something went on the clipboard, and the generator is prepared because an unprepared one drops its first event while the Taptic Engine spins up.
    static func copied() {
        let generator = UIImpactFeedbackGenerator(style: .light)
        generator.prepare()
        generator.impactOccurred()
    }
}
