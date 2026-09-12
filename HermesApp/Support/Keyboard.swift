import SwiftUI
import UIKit

/// Dismissing the keyboard from a view that does not own the focus binding; Home's body is a `VStack`, so `.scrollDismissesKeyboard` has no scroll surface to attach to there.
enum Keyboard {
    /// Resign whatever holds first responder; SwiftUI's focus system follows the responder chain, so the composer's `@FocusState` clears itself.
    @MainActor
    static func dismiss() {
        UIApplication.shared.sendAction(
            #selector(UIResponder.resignFirstResponder),
            to: nil,
            from: nil,
            for: nil
        )
    }
}
