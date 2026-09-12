import SwiftUI

/// The one copy of the question asked before stopping a turn another client started.
enum ForeignStopCopy {
    static let title = "Stop another client's work?"
    static let message = "This was started somewhere else — a desktop client or a scheduled run. Stopping it here stops it there too."
}

extension View {
    /// Ask before stopping a turn this client did not start.
    ///
    /// `onStop` is `model.stopTapped()`; a bare `interrupt()` skips the optimistic finalise and the interrupt latch.
    func foreignStopConfirmation(
        isPresented: Binding<Bool>,
        onStop: @escaping () -> Void
    ) -> some View {
        // A foreign turn is worth confirming before it is ended; the backend gates `subagent.interrupt` on transport authority only from 0.21.1.
        alert(ForeignStopCopy.title, isPresented: isPresented) {
            Button("Cancel", role: .cancel) { }
            Button("Stop", role: .destructive) { onStop() }
        } message: {
            Text(ForeignStopCopy.message)
        }
    }

    /// The same question, for a caller whose target is a row rather than the screen it is on.
    ///
    /// `presenting:` hands the target into the action closure because SwiftUI does not order the `isPresented` setter and the button's action.
    func foreignStopConfirmation<Target>(
        target: Binding<Target?>,
        onStop: @escaping (Target) -> Void
    ) -> some View {
        alert(
            ForeignStopCopy.title,
            isPresented: Binding(
                get: { target.wrappedValue != nil },
                set: { if !$0 { target.wrappedValue = nil } }
            ),
            presenting: target.wrappedValue
        ) { value in
            Button("Cancel", role: .cancel) { }
            Button("Stop", role: .destructive) { onStop(value) }
        } message: { _ in
            Text(ForeignStopCopy.message)
        }
    }
}
