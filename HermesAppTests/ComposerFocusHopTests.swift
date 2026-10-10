import SwiftUI
import UIKit
import XCTest

@testable import HermesMobile

/// BUG-146, `GrowingComposerField.swift` (`updateUIView`): every update scheduled a main-queue hop to reconcile focus before comparing anything, so each keystroke, which re-renders the field through the draft binding, queued a hop that then did nothing. The comparison now runs first, and a hop is scheduled only when the binding and the first responder disagree.
///
/// Hosted behind an `ObservableObject` so a change really re-renders the representable (memory `hermes-ios-no-test-ever-types`: a plain box can leave `updateUIView` unexercised and pass vacuously).
@MainActor
final class ComposerFocusHopTests: XCTestCase {

    private final class Draft: ObservableObject {
        @Published var text = ""
        @Published var focused = false
    }

    private struct Field: View {
        @ObservedObject var draft: Draft
        var body: some View {
            GrowingComposerField(
                text: $draft.text,
                placeholder: "Compose",
                textColor: .gray,
                isFocused: $draft.focused
            )
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func host(_ draft: Draft) -> (UIWindow, GrowingComposerField.ComposerTextView) {
        let controller = UIHostingController(rootView: Field(draft: draft))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 360, height: 800))
        window.rootViewController = controller
        window.makeKeyAndVisible()
        window.layoutIfNeeded()
        spin()
        return (window, findTextView(in: controller.view)!)
    }

    private func spin(_ seconds: TimeInterval = 0.05) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    private func findTextView(in view: UIView) -> GrowingComposerField.ComposerTextView? {
        if let textView = view as? GrowingComposerField.ComposerTextView { return textView }
        for subview in view.subviews {
            if let found = findTextView(in: subview) { return found }
        }
        return nil
    }

    func testUpdatesThatAgreeWithTheFirstResponderScheduleNoHop() throws {
        let draft = Draft()
        let (window, textView) = host(draft)
        let coordinator = try XCTUnwrap(textView.delegate as? GrowingComposerField.Coordinator)
        XCTAssertFalse(textView.isFirstResponder)
        let before = coordinator.focusHopsScheduled
        for index in 0..<5 {
            draft.text = "draft \(index)"
            window.layoutIfNeeded()
            spin()
        }
        XCTAssertEqual(textView.text, "draft 4", "the updates never reached the field, so this proved nothing")
        XCTAssertEqual(coordinator.focusHopsScheduled - before, 0, """
            five re-renders with the field unfocused and the binding false scheduled \
            \(coordinator.focusHopsScheduled - before) focus hops (BUG-146)
            """)
        window.isHidden = true
    }

    /// The hop that is still needed still happens.
    func testAFocusRequestStillLandsOnTheField() {
        let draft = Draft()
        let (window, textView) = host(draft)
        draft.focused = true
        window.layoutIfNeeded()
        spin(0.2)
        XCTAssertTrue(textView.isFirstResponder, "a focus request no longer reaches the text view")
        draft.focused = false
        window.layoutIfNeeded()
        spin(0.2)
        XCTAssertFalse(textView.isFirstResponder, "a release no longer resigns the text view")
        window.isHidden = true
    }

    func testTheRequestTable() {
        XCTAssertEqual(GrowingComposerField.focusRequest(isFocused: true, isFirstResponder: false), .become)
        XCTAssertEqual(GrowingComposerField.focusRequest(isFocused: false, isFirstResponder: true), .resign)
        XCTAssertNil(GrowingComposerField.focusRequest(isFocused: true, isFirstResponder: true))
        XCTAssertNil(GrowingComposerField.focusRequest(isFocused: false, isFirstResponder: false))
    }
}
