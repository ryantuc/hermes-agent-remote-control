import SwiftUI
import UIKit
import XCTest

@testable import HermesMobile

/// **BUG-012 (D)** — `Keyboard.dismiss()` puts the composer's keyboard away
/// without needing a render pass.
///
/// `Keyboard.swift` had no tests at all, and the mechanism it provides is the
/// whole of the fix for the keyboard surviving the pop back to Home. The
/// composer's other dismissal — writing `isFocused = false` — is not a
/// dismissal but a *request*: the field is a `UIViewRepresentable` and its only
/// `resignFirstResponder` lives inside `updateUIView`, so the write becomes a
/// dismissal only if SwiftUI re-renders afterwards. On the pop nothing does,
/// because the view holding the flag is being destroyed.
///
/// `Keyboard.dismiss()` goes up the responder chain instead
/// (`UIApplication.sendAction(_:to:from:for:)` with a nil target), so it does
/// not care that the field is a representable and it does not need an update to
/// follow. These tests mount the real field in a real `UIWindow`, take first
/// responder, and assert that one call resigns it.
///
/// What they cannot establish: the navigation teardown itself. There is no
/// harness here that pushes and pops a real `NavigationStack` destination, so
/// "the keyboard is gone when Home appears" stays a device check. What is
/// pinned is that the actuator this fix calls works on this field, in a real
/// window, with no re-render behind it.
@MainActor
final class KeyboardDismissTests: XCTestCase {

    /// Observable state, so a mutation drives a REAL SwiftUI re-render and a
    /// real `updateUIView` — the same reason `GrowingComposerFieldTests` uses
    /// one. A plain box is invisible to SwiftUI and a focus test built on it
    /// can pass whether or not the reconciliation it checks ever runs.
    private final class FieldState: ObservableObject {
        @Published var text: String
        @Published var focused: Bool
        init(text: String = "", focused: Bool = false) {
            self.text = text
            self.focused = focused
        }
    }

    private struct Harness: View {
        @ObservedObject var state: FieldState
        var body: some View {
            VStack(alignment: .leading, spacing: 0) {
                GrowingComposerField(
                    text: $state.text,
                    placeholder: "Compose",
                    textColor: .gray,
                    isFocused: $state.focused
                )
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// The window must belong to a real `UIWindowScene`, and that is not a
    /// detail — it is the difference between this file testing something and
    /// testing nothing.
    ///
    /// `GrowingComposerFieldTests` builds its windows with `UIWindow(frame:)`,
    /// which since iOS 13 produces a window attached to no scene. That is
    /// enough for everything it asserts: layout runs, and
    /// `becomeFirstResponder()` / `resignFirstResponder()` sent *directly* to a
    /// view work regardless. It is not enough here. `Keyboard.dismiss()` goes
    /// through `UIApplication.sendAction(_:to:nil,…)`, which resolves its
    /// target by walking the responder chain from the first responder of the
    /// **key window of an active scene** — and a scene-less window is not in
    /// any scene's list, so the lookup never reaches the field and the call
    /// silently does nothing. Built that way these tests fail against a
    /// mechanism that demonstrably works on a device (Home's canvas tap is the
    /// one dismissal confirmed by hand), which would be a false negative
    /// about the app dressed up as a red test.
    private func makeHost(_ state: FieldState) throws
        -> (window: UIWindow, textView: GrowingComposerField.ComposerTextView) {
        let scene = try XCTUnwrap(Self.activeWindowScene, """
            the test host has no window scene, so nothing here can exercise the responder \
            chain — this test would be vacuous rather than passing
            """)
        let host = UIHostingController(rootView: Harness(state: state))
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 360, height: 800)
        window.rootViewController = host
        window.makeKeyAndVisible()
        window.layoutIfNeeded()
        host.view.layoutIfNeeded()
        return (window, try XCTUnwrap(findTextView(in: host.view)))
    }

    private static var activeWindowScene: UIWindowScene? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        return scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
    }

    private func findTextView(in view: UIView) -> GrowingComposerField.ComposerTextView? {
        if let field = view as? GrowingComposerField.ComposerTextView { return field }
        for subview in view.subviews {
            if let found = findTextView(in: subview) { return found }
        }
        return nil
    }

    /// Let SwiftUI render and `updateUIView`'s async focus reconciliation run.
    private func settle(_ window: UIWindow) {
        window.layoutIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.25))
        window.layoutIfNeeded()
    }

    /// The mechanism, on the field the composer actually uses.
    func testKeyboardDismissResignsTheComposerField() throws {
        let state = FieldState(text: "half a sentence")
        let (window, textView) = try makeHost(state)

        XCTAssertTrue(textView.becomeFirstResponder(), "the field never took first responder")
        settle(window)
        XCTAssertTrue(textView.isFirstResponder, "precondition: the field holds the keyboard")

        Keyboard.dismiss()

        XCTAssertFalse(textView.isFirstResponder, """
            Keyboard.dismiss() did not resign the composer field. This is the actuator \
            ComposerView.onDisappear now calls on the way out of a chat; if it does not \
            reach the field, the keyboard rides the pop back to Home (BUG-012 symptom 2).
            """)
    }

    /// It resigns *synchronously*, with no re-render behind it — which is the
    /// only reason it can work in `onDisappear`, where the view is being torn
    /// down and no further update is coming. Asserted before any `settle()`:
    /// nothing is allowed to run between the call and the check.
    func testKeyboardDismissNeedsNoRenderPass() throws {
        let state = FieldState(text: "half a sentence")
        let (window, textView) = try makeHost(state)
        XCTAssertTrue(textView.becomeFirstResponder(), "the field never took first responder")
        settle(window)

        Keyboard.dismiss()
        XCTAssertFalse(textView.isFirstResponder,
                       "the resign must land in the same turn of the run loop, not after a render")

        // And the flag follows it down through the coordinator's end-editing
        // callback, so the field's own view of focus does not disagree with the
        // responder — `ComposerView.onDisappear` keeps writing `isFocused =
        // false` beside this call for the push case, and the two must agree.
        settle(window)
        XCTAssertFalse(state.focused,
                       "the field must report itself unfocused after a responder-chain dismissal")
    }

    /// The negative control, which is what makes the two tests above mean
    /// anything: the field really does take and hold the keyboard until it is
    /// told otherwise.
    func testTheFieldHoldsFirstResponderUntilDismissed() throws {
        let state = FieldState(text: "half a sentence")
        let (window, textView) = try makeHost(state)

        XCTAssertTrue(textView.becomeFirstResponder())
        settle(window)
        settle(window)
        XCTAssertTrue(textView.isFirstResponder,
                      "nothing dismisses the field on its own — if this fails the other two prove nothing")
    }
}
