import SwiftUI
import UIKit
import XCTest

@testable import HermesMobile

/// The composer field grows with its text instead of collapsing to one
/// internal-scrolling line, keeps growing to a 16-line cap, then holds that
/// height and scrolls — the behaviour every other chat app on the phone has.
///
/// `TextField(axis: .vertical).lineLimit(1...n)` is SwiftUI's spelling of this
/// but fails at runtime: the backing `UITextView` refuses the intrinsic-height
/// negotiation, the field stays one line tall, and text typed past the first
/// line scrolls out of view with no way back (BUG-002).
/// `GrowingComposerField` replaces it with a plain `UITextView` whose intrinsic
/// height is its content height (`isScrollEnabled = false`) up to the cap.
///
/// These are view tests (UIKit in the simulator) — no `ScriptedBackend`.
///
/// **Every height assertion here is relative.** The tests derive the one-line
/// height and the per-line step from live fields and assert the growth policy
/// against those, rather than restating the production formula — a test that
/// recomputes the formula only proves the formula was typed twice.
///
/// The field needs a live `UIWindow` or the representable never materialises
/// and there is no `UITextView` to measure. Most tests here wrap it in
/// `.fixedSize(vertical:)` to ask "what height does it want?" —
/// `testFieldTakesItsFullHeightInAnAppLikeStack` is the one that asks the
/// question that actually matters, "what height does it get?", and it is the
/// only one that catches a field the surrounding stack is free to squash.
@MainActor
final class GrowingComposerFieldTests: XCTestCase {

    /// A tiny holder so a test can rebuild the field struct with a new value
    /// and re-render through the hosting controller.
    private final class Box {
        var value: String
        init(_ value: String) { self.value = value }
    }

    /// Stands in for `ComposerView`'s `@State` focus flag. A `Binding` over
    /// real storage, because that is the whole point of the fix this file
    /// pins: a `FocusState.Binding` silently drops what is written to it when
    /// no view claims the focus value, and only a representable is here.
    private final class FocusBox {
        var value = false
    }
    private let focus = FocusBox()

    private func makeField(_ box: Box) -> GrowingComposerField {
        GrowingComposerField(
            text: Binding(get: { box.value }, set: { box.value = $0 }),
            placeholder: "Compose",
            textColor: .gray,
            isFocused: Binding(get: { [focus] in focus.value }, set: { [focus] in focus.value = $0 })
        )
    }

    private func makeHost(_ box: Box)
        -> (window: UIWindow, textView: GrowingComposerField.ComposerTextView) {
        let host = UIHostingController(rootView: AnyView(VStack(alignment: .leading, spacing: 0) {
            makeField(box)
                .fixedSize(horizontal: false, vertical: true)
        }))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 360, height: 800))
        window.rootViewController = host
        window.makeKeyAndVisible()
        window.layoutIfNeeded()
        host.view.layoutIfNeeded()
        let textView = findTextView(in: host.view)!
        return (window, textView)
    }

    private func rerender(_ window: UIWindow, box: Box)
        -> GrowingComposerField.ComposerTextView {
        let host = window.rootViewController as! UIHostingController<AnyView>
        host.rootView = AnyView(VStack(alignment: .leading, spacing: 0) {
            makeField(box)
                .fixedSize(horizontal: false, vertical: true)
        })
        window.layoutIfNeeded()
        return findTextView(in: host.view)!
    }

    private func findTextView(in view: UIView) -> GrowingComposerField.ComposerTextView? {
        if let textView = view as? GrowingComposerField.ComposerTextView { return textView }
        for subview in view.subviews {
            if let found = findTextView(in: subview) { return found }
        }
        return nil
    }

    /// A field holding exactly `lines` hard-wrapped lines.
    private func field(lines: Int) -> GrowingComposerField.ComposerTextView {
        makeHost(Box(Array(repeating: "A", count: lines).joined(separator: "\n"))).textView
    }

    private func height(lines: Int) -> CGFloat { field(lines: lines).frame.height }

    /// One line of growth, measured off live fields rather than assumed.
    private var lineStep: CGFloat { height(lines: 3) - height(lines: 2) }

    // MARK: - Growth

    /// The resting composer is one line tall and not scrollable.
    func testEmptyFieldIsOneLineAndNotScrollable() {
        let (_, textView) = makeHost(Box(""))
        XCTAssertFalse(textView.isScrollEnabled)
        XCTAssertEqual(textView.frame.height, height(lines: 1), accuracy: 1.0,
                       "an empty composer must stay a single line")
    }

    /// The field grows a line at a time. This is the actual feature, and the
    /// old suite never asserted it — it checked one line and the cap, so a
    /// field that jumped straight from 1 line to the cap would have passed.
    func testFieldGrowsLineByLine() {
        let step = lineStep
        XCTAssertGreaterThan(step, 1, "a line of growth must be a real height")
        for lines in 2...6 {
            XCTAssertEqual(
                height(lines: lines), height(lines: 1) + step * CGFloat(lines - 1), accuracy: 1.0,
                "\(lines) lines of draft must render \(lines) lines tall"
            )
        }
        XCTAssertFalse(field(lines: 6).isScrollEnabled,
                       "a draft inside the cap must not scroll")
    }

    // MARK: - The cap

    /// A long draft stops growing at 16 lines and scrolls from there.
    func testLongTextCapsAtSixteenLinesAndScrolls() {
        let capped = field(lines: 40)
        XCTAssertTrue(capped.isScrollEnabled,
                      "text past the cap must scroll inside the field")
        XCTAssertEqual(capped.frame.height, height(lines: 16), accuracy: 1.0,
                       "the field must stop growing at 16 lines")
    }

    /// The cap is a whole number of lines, not an arbitrary height that stops
    /// part-way down a row.
    func testCapIsAWholeNumberOfLines() {
        let step = lineStep
        XCTAssertEqual(
            height(lines: 40), height(lines: 1) + step * 15, accuracy: 1.0,
            "the capped field must be exactly 16 whole lines tall"
        )
    }

    /// The field takes the height it asks for when the layout has room.
    ///
    /// This is the regression, and it is the reason every other test in this
    /// file can pass while the phone shows something else: they all host the
    /// field under `.fixedSize`, which forces the ideal height and hides what
    /// the surrounding stack would otherwise do to it. The shipped field set
    /// BOTH vertical layout priorities to `.defaultLow` — "stretch me, squash
    /// me, I don't mind" — so on Home it settled at eleven lines with the cap
    /// at sixteen and room to spare above. This host has no `.fixedSize` and
    /// 800 pt of window, exactly like the real one.
    func testFieldTakesItsFullHeightInAnAppLikeStack() {
        let textView = appLikeField(windowHeight: 800)
        XCTAssertEqual(
            textView.frame.height, height(lines: 16), accuracy: 1.0,
            "a field with room to spare must grow to its 16-line cap, not stop wherever the stack squeezed it"
        )
        XCTAssertTrue(textView.isScrollEnabled, "past the cap the field scrolls")
    }

    /// A lower cap is honoured exactly.
    ///
    /// This is how a short viewport is served — `ComposerView` drops the cap
    /// to 5 on a compact-height screen rather than leaving the field to be
    /// crushed by the layout. A landscape phone has ~400 pt with the keyboard
    /// already eating half of it, and sixteen lines there put Send off the
    /// bottom of the screen.
    func testALowerCapIsHonouredExactly() {
        let host = UIHostingController(rootView: AnyView(VStack(alignment: .leading, spacing: 0) {
            GrowingComposerField(
                text: .constant(Array(repeating: "A", count: 40).joined(separator: "\n")),
                placeholder: "Compose",
                textColor: .gray,
                maxLineCount: 5,
                isFocused: Binding(get: { [focus] in focus.value }, set: { [focus] in focus.value = $0 })
            )
            .fixedSize(horizontal: false, vertical: true)
        }))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 360, height: 800))
        window.rootViewController = host
        window.makeKeyAndVisible()
        window.layoutIfNeeded()
        host.view.layoutIfNeeded()
        let textView = findTextView(in: host.view)!

        XCTAssertEqual(textView.frame.height, height(lines: 5), accuracy: 1.0,
                       "a 5-line cap must render 5 lines")
        XCTAssertTrue(textView.isScrollEnabled, "past the cap the field scrolls")
    }

    /// The composer as the app builds it: bottom-anchored, control row below,
    /// and no `.fixedSize` anywhere.
    private func appLikeField(windowHeight: CGFloat) -> GrowingComposerField.ComposerTextView {
        let host = UIHostingController(rootView: AnyView(
            VStack(spacing: 0) {
                Spacer(minLength: 0)
                VStack(alignment: .leading, spacing: 0) {
                    makeField(Box(Array(repeating: "A", count: 40).joined(separator: "\n")))
                    Color.clear.frame(height: 34)   // stands in for the control row
                }
            }
        ))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 360, height: windowHeight))
        window.rootViewController = host
        window.makeKeyAndVisible()
        window.layoutIfNeeded()
        host.view.layoutIfNeeded()
        return findTextView(in: host.view)!
    }

    /// Wrapped text caps the same way hard-wrapped text does: the cap is about
    /// laid-out lines, not newlines.
    func testWrappedTextCapsAtTheSameHeight() {
        let (_, wrapped) = makeHost(Box(String(repeating: "The quick brown fox jumps over the lazy dog. ", count: 40)))
        XCTAssertTrue(wrapped.isScrollEnabled)
        XCTAssertEqual(wrapped.frame.height, height(lines: 16), accuracy: 1.0,
                       "a long wrapped draft caps at the same 16 lines")
    }

    // MARK: - Focus

    /// Observable state, so mutating it drives a REAL SwiftUI re-render and a
    /// real `updateUIView`.
    ///
    /// The `Box`/`rerender` pair the height tests use cannot do this: `Box` is
    /// invisible to SwiftUI, so swapping `rootView` re-renders the wrapper
    /// without necessarily re-running the representable's update. A focus test
    /// built on it passes whether or not the reconciliation it is checking
    /// ever runs — which is exactly the sort of test that let this bug reach
    /// the phone.
    private final class FieldState: ObservableObject {
        @Published var text: String
        @Published var focused: Bool
        init(text: String = "", focused: Bool = false) {
            self.text = text
            self.focused = focused
        }
    }

    private struct FocusHarness: View {
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

    private func makeFocusHost(_ state: FieldState)
        -> (window: UIWindow, textView: GrowingComposerField.ComposerTextView) {
        let host = UIHostingController(rootView: FocusHarness(state: state))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 360, height: 800))
        window.rootViewController = host
        window.makeKeyAndVisible()
        window.layoutIfNeeded()
        host.view.layoutIfNeeded()
        return (window, findTextView(in: host.view)!)
    }

    /// Let SwiftUI render and `updateUIView`'s async focus reconciliation run.
    private func settle(_ window: UIWindow) {
        window.layoutIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.25))
        window.layoutIfNeeded()
    }

    /// **Typing must not close the keyboard.** Shipped to the phone and it did:
    /// one keystroke, keyboard gone, tap again, one more keystroke, gone again.
    ///
    /// The composer field used to be a SwiftUI `TextField` carrying
    /// `.focused($isFocused)`. Replacing it with this representable dropped
    /// that modifier and left the `@FocusState` bound to no view at all, so
    /// SwiftUI discarded the coordinator's `isFocused = true`. Every re-render
    /// then read `false` and `updateUIView` resigned first responder — and a
    /// keystroke IS a re-render, because it writes the draft binding.
    ///
    /// Nothing caught it because nothing typed: the other tests here set
    /// `text` programmatically and the screenshot harness injects the draft
    /// through a launch argument. Both skip the keyboard entirely.
    func testTypingDoesNotDismissTheKeyboard() {
        let state = FieldState()
        let (window, textView) = makeFocusHost(state)

        XCTAssertTrue(textView.becomeFirstResponder(), "the field never took first responder")
        settle(window)
        XCTAssertTrue(state.focused,
                      "UIKit's begin-editing callback must write focus back through the binding")

        // Three keystrokes, the way the keyboard delivers them: each one writes
        // the draft binding, and writing the draft binding is a re-render.
        for character in ["a", "ab", "abc"] {
            textView.text = character
            textView.delegate?.textViewDidChange?(textView)
            settle(window)
            XCTAssertEqual(state.text, character, "precondition: the keystroke reached the draft")
            XCTAssertTrue(
                textView.isFirstResponder,
                "typing \"\(character)\" closed the keyboard — the field lost first responder on re-render"
            )
        }
        XCTAssertTrue(state.focused, "and the focus flag must still say the field is focused")
    }

    /// The other half of the contract: the composer still dismisses on command.
    /// `ComposerView` writes `isFocused = false` when a sheet opens, when it
    /// disappears, and on send from Home.
    func testWritingFocusFalseDismissesTheKeyboard() {
        let state = FieldState(text: "hello")
        let (window, textView) = makeFocusHost(state)
        XCTAssertTrue(textView.becomeFirstResponder(), "the field never took first responder")
        settle(window)

        state.focused = false
        settle(window)

        XCTAssertFalse(textView.isFirstResponder,
                       "clearing the focus flag must still put the keyboard away")
    }

    /// And the command works in the other direction, which is what makes the
    /// dismissal test above meaningful rather than a view that simply never
    /// takes focus.
    func testWritingFocusTrueRaisesTheKeyboard() {
        let state = FieldState(text: "hello")
        let (window, textView) = makeFocusHost(state)
        XCTAssertFalse(textView.isFirstResponder, "precondition: not focused at rest")

        state.focused = true
        settle(window)

        XCTAssertTrue(textView.isFirstResponder,
                      "setting the focus flag must raise the keyboard")
    }

    // MARK: - Write-back

    /// Typing writes through to the binding, and a re-render never clobbers
    /// the live buffer (SanitizedTextField's rule).
    func testEditingWritesBackToBindingAndSurvivesRerender() {
        let box = Box("")
        let (window, textView) = makeHost(box)
        textView.text = "typed by the user"
        textView.delegate?.textViewDidChange?(textView)
        XCTAssertEqual(box.value, "typed by the user",
                       "the draft binding must receive what was typed")

        let textViewAfter = rerender(window, box: box)
        XCTAssertEqual(textViewAfter.text, "typed by the user",
                       "a re-render must not restart the edit session")
    }
}
