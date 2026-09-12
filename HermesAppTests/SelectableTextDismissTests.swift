import SwiftUI
import UIKit
import XCTest

@testable import HermesMobile

/// BUG-137 — a selection does not outlive the focus that made it.
///
/// The reported symptom: tapping away from a selection, which should dismiss it, and then trying to start a new selection brings the old one back, and a new selection cannot be started unless the press lands outside the old range.
///
/// `selectedTextRange` is view state and `UITextView` keeps it across a resign. The highlight and the callout are drawn only while the view holds first responder, so the tap *looks* like it dismissed the selection; the range is still set, and the next long press — which takes first responder again — brings it back. A press that lands inside the restored range is read as grabbing the existing selection rather than starting a new one, which is precisely the asymmetry reported. Nothing in the app cleared it: before this fix `selectedRange` and `selectedTextRange` appeared in `HermesApp/` exactly twice, both inside `SelectableTextView.copy(_:)`.
///
/// What these tests can and cannot see: they can see the responder transition and the range that survives it, on the real view the transcript hosts, in a real window, through the real actuator the transcript's tap calls. They cannot see the loupe, the drag handles or the Copy / Select All callout — those are system UI and no app-hosted test has ever observed them. The acceptance is a hand check on a device: select, tap away, select something else.
///
/// **Why the window must belong to a real `UIWindowScene`.** `Keyboard.dismiss()` is `UIApplication.sendAction(_:to:nil,…)`, which resolves its target from the first responder of the key window of an active scene. A window built with `UIWindow(frame:)` belongs to no scene since iOS 13, so the lookup would never reach the view and the call would silently do nothing — the test would fail against a mechanism that works. `KeyboardDismissTests` established this and the harness here is deliberately the same shape.
@MainActor
final class SelectableTextDismissTests: XCTestCase {
    private static let tokens = HermesTokens(skin: .nousDark, polarity: .dark)

    /// Two spans, because a horizontal rule is one of the three things that
    /// still ends one. The first is long enough that a partial selection is a
    /// real partial selection rather than the whole view.
    private static let source = """
    The first span of the reply, long enough that a reader can select some of it and leave the rest.

    ---

    The second span, under the rule, in a text view of its own.
    """

    // MARK: Harness

    private static var activeWindowScene: UIWindowScene? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        return scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
    }

    private static func selectableViews(under view: UIView) -> [SelectableTextView] {
        var found: [SelectableTextView] = []
        if let textView = view as? SelectableTextView { found.append(textView) }
        for subview in view.subviews { found += selectableViews(under: subview) }
        return found
    }

    private func host() throws -> (window: UIWindow, views: [SelectableTextView]) {
        let scene = try XCTUnwrap(Self.activeWindowScene, """
            the test host has no window scene, so nothing here can exercise the responder \
            chain — this test would be vacuous rather than passing
            """)
        let root = MarkdownText(text: Self.source)
            .frame(width: 360)
            .environment(\.hermes, Self.tokens)
        let controller = UIHostingController(rootView: AnyView(root))
        controller.safeAreaRegions = []
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 360, height: 800)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        window.layoutIfNeeded()
        controller.view.layoutIfNeeded()
        let views = Self.selectableViews(under: controller.view)
        XCTAssertEqual(views.count, 2, "the fixture should host two spans; found \(views.count)")
        return (window, views)
    }

    /// Select the second half of a view's drawn text, the way a drag that
    /// starts mid-paragraph does.
    @discardableResult
    private func selectTail(of view: SelectableTextView) -> NSRange {
        let length = ((view.text ?? "") as NSString).length
        let range = NSRange(location: length / 2, length: length - length / 2)
        view.selectedRange = range
        return range
    }

    // MARK: 1 — the reported symptom, through the actuator a tap fires

    /// A tap anywhere in the transcript calls `Keyboard.dismiss()`
    /// (`ChatView.swift:741` for the content, `:754` for the empty canvas).
    /// After it, the view must hold neither focus nor a selection, and taking
    /// focus again must not resurrect one.
    func testTappingAwayClearsTheSelectionAndItDoesNotComeBack() throws {
        let (window, views) = try host()
        defer { window.isHidden = true }
        let span = try XCTUnwrap(views.first)

        XCTAssertTrue(span.becomeFirstResponder(), "the span never took first responder, so there is no selection to dismiss")
        selectTail(of: span)
        XCTAssertGreaterThan(span.selectedRange.length, 0, "precondition: something is selected")
        XCTAssertTrue(span.isFirstResponder, "precondition: the span holds focus while the callout is up")

        Keyboard.dismiss()

        XCTAssertFalse(span.isFirstResponder, "the transcript's tap did not resign the span")
        XCTAssertEqual(span.selectedRange.length, 0, """
            the selection outlived the focus that made it. It is invisible now — the highlight and \
            the callout are only drawn while the view is first responder — but it is still set, and \
            the next long press restores it instead of starting a new selection (BUG-137).
            """)

        XCTAssertTrue(span.becomeFirstResponder(), "the span could not take focus again")
        XCTAssertEqual(span.selectedRange.length, 0, """
            the old selection came back the moment the view took focus again, which is exactly the \
            reported symptom: a new selection cannot be started unless the press lands outside it.
            """)
    }

    // MARK: 2 — focus moving between per-span views

    /// Since BUG-124's second pass a reply is several spans and each is its own
    /// text view, so the reader moves focus from one to the next by pressing in
    /// it. The span being left behind must not keep its range either.
    func testFocusMovingToAnotherSpanClearsTheFirstSpansSelection() throws {
        let (window, views) = try host()
        defer { window.isHidden = true }
        let first = try XCTUnwrap(views.first)
        let second = try XCTUnwrap(views.last)

        XCTAssertTrue(first.becomeFirstResponder())
        selectTail(of: first)
        XCTAssertGreaterThan(first.selectedRange.length, 0, "precondition: the first span carries a selection")

        XCTAssertTrue(second.becomeFirstResponder(), "the second span never took first responder")

        XCTAssertFalse(first.isFirstResponder, "UIKit did not resign the first span when the second took focus")
        XCTAssertEqual(first.selectedRange.length, 0, """
            the span the reader left still carries its selection, so pressing back into it resumes \
            that selection rather than starting a new one
            """)
    }

    // MARK: 3 — the mechanism, with no responder chain in the way

    /// The clear hangs off `resignFirstResponder()` rather than off any one
    /// gesture, so it also covers the ways focus leaves that no tap causes: the
    /// row scrolling out of the window, the app going to the background, the
    /// chat being popped. Sent directly here rather than through the responder
    /// chain, so this half holds whatever `Keyboard.dismiss()` does.
    ///
    /// Measured: `UITextView`
    /// refuses the resign — returns `false` — when it does not hold first
    /// responder, and the first draft of this test asserted the opposite. That
    /// is why the take is here and why the fix's own guard reads `if resigned`:
    /// a refused resign means the view still has focus, and a view that still
    /// has focus must keep its selection.
    func testResigningClearsTheRangeWhicheverWayFocusLeaves() throws {
        let (window, views) = try host()
        defer { window.isHidden = true }
        let span = try XCTUnwrap(views.first)

        XCTAssertTrue(span.becomeFirstResponder(), "the span never took first responder")
        selectTail(of: span)
        XCTAssertGreaterThan(span.selectedRange.length, 0, "precondition: something is selected")

        XCTAssertTrue(span.resignFirstResponder(), "the resign was refused")
        XCTAssertEqual(span.selectedRange.length, 0, "a resign must leave nothing selected")
    }

    /// And a refused resign leaves the selection alone. `UITextView` returns
    /// `false` when it is not first responder, which is the case every time
    /// something sweeps the chain past a view that never had focus — those must
    /// not wipe a selection the reader is still holding somewhere else.
    func testARefusedResignLeavesTheSelectionAlone() throws {
        let (window, views) = try host()
        defer { window.isHidden = true }
        let span = try XCTUnwrap(views.first)

        let selected = selectTail(of: span)
        XCTAssertFalse(span.isFirstResponder, "precondition: the span does not hold focus")

        XCTAssertFalse(span.resignFirstResponder(), "a view with no focus should refuse to resign it")
        XCTAssertEqual(span.selectedRange, selected, "a refused resign must not clear anything")
    }

    // MARK: 4 — the controls, so the fix is not a selection that never works

    /// Nothing clears a *live* selection. If this fails, the two tests above
    /// prove nothing — a view that never holds a selection would pass them.
    func testASelectionSurvivesWhileTheViewStillHoldsFocus() throws {
        let (window, views) = try host()
        defer { window.isHidden = true }
        let span = try XCTUnwrap(views.first)

        XCTAssertTrue(span.becomeFirstResponder())
        let selected = selectTail(of: span)
        window.layoutIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.25))
        window.layoutIfNeeded()

        XCTAssertTrue(span.isFirstResponder, "nothing may take focus away on its own")
        XCTAssertEqual(span.selectedRange, selected, """
            the selection was cleared while the reader still held it, which would make the drag \
            handles and the Copy callout unusable
            """)
    }

    /// And Copy still copies. `copy(_:)` is dispatched to the view *as first
    /// responder*, so it can never see a cleared range — but the two behaviours
    /// live four lines apart in the same class and this is what says so.
    func testCopyStillWritesTheSourceMarkdownForALiveSelection() throws {
        let (window, views) = try host()
        defer { window.isHidden = true }
        let span = try XCTUnwrap(views.first)

        XCTAssertTrue(span.becomeFirstResponder())
        let drawn = (span.text ?? "") as NSString
        span.selectedRange = NSRange(location: 0, length: drawn.length)
        UIPasteboard.general.string = ""
        span.copy(nil)

        XCTAssertEqual(UIPasteboard.general.string, drawn as String, """
            the clipboard did not receive the selected span, so the resign clear has reached a path \
            it must never touch
            """)
    }
}
