import SwiftUI
import UIKit

/// The composer's input field: a real `UITextView` that grows with the text to `maxLineCount` lines, then holds that height and scrolls.
///
/// BUG-002: not `TextField(axis: .vertical).lineLimit(1...n)`, whose backing text view refuses the intrinsic-height negotiation and collapses to one internally scrolling line.
struct GrowingComposerField: UIViewRepresentable {
    @Binding var text: String
    let placeholder: String
    let textColor: Color
    /// How tall the field may grow before it stops growing and scrolls.
    var maxLineCount: Int
    /// Whether the field should hold the keyboard.
    ///
    /// A plain `Binding`, not a `FocusState.Binding`: no view can claim focus with `.focused(_:)` on a representable, so a focus-state write does not stick and every re-render resigns first responder.
    @Binding var isFocused: Bool

    init(
        text: Binding<String>,
        placeholder: String,
        textColor: Color,
        maxLineCount: Int = 16,
        isFocused: Binding<Bool>
    ) {
        _text = text
        self.placeholder = placeholder
        self.textColor = textColor
        self.maxLineCount = maxLineCount
        _isFocused = isFocused
    }

    func makeUIView(context: Context) -> ComposerTextView {
        let textView = ComposerTextView()
        textView.delegate = context.coordinator
        textView.backgroundColor = .clear
        textView.textColor = UIColor(textColor)
        textView.font = Self.bodyFont
        // `lineFragmentPadding` is zeroed so the left and right insets are not doubled.
        textView.textContainer.lineFragmentPadding = 0
        textView.textContainerInset = Self.textInsets
        textView.adjustsFontForContentSizeCategory = true
        textView.isScrollEnabled = false
        textView.scrollsToTop = false
        textView.maxLineCount = maxLineCount
        // Both HIGH: exactly as tall as the text up to the cap, neither stretched past it nor squashed below it by the surrounding stack.
        textView.setContentHuggingPriority(.defaultHigh, for: .vertical)
        textView.setContentCompressionResistancePriority(.defaultHigh, for: .vertical)
        return textView
    }

    func updateUIView(_ textView: ComposerTextView, context: Context) {
        context.coordinator.parent = self
        // Set the text only when the view's buffer has diverged; during typing the buffer is the source of truth and must not be restarted.
        if textView.text != text { textView.text = text }
        textView.textColor = UIColor(textColor)
        textView.font = Self.bodyFont
        textView.accessibilityLabel = text.isEmpty ? placeholder : nil
        textView.maxLineCount = maxLineCount
        textView.applyHeightPolicy()
        // Bridge SwiftUI focus to UIKit first responder; the coordinator writes the binding back on begin and end editing.
        DispatchQueue.main.async {
            if isFocused && !textView.isFirstResponder {
                textView.becomeFirstResponder()
            } else if !isFocused && textView.isFirstResponder {
                textView.resignFirstResponder()
            }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    /// `HermesFont.body` through `UIFontMetrics`, so Dynamic Type stays on.
    static var bodyFont: UIFont {
        UIFontMetrics(forTextStyle: .body)
            .scaledFont(for: .systemFont(ofSize: HermesFont.body.size, weight: .regular))
    }

    /// The text container's insets, in one definition because the field and the height-at-N-lines metric must use the same number.
    static let textInsets = UIEdgeInsets(
        top: Space.s5, left: Space.s5, bottom: Space.s4, right: Space.s5
    )

    /// BUG-039: one line, quantised up to the pixel grid before it is multiplied, because TextKit rounds each cumulative height and makes the raw `lineHeight` an uneven step.
    ///
    /// Rounding up rather than to nearest is load-bearing: the box must never be shorter than the text it holds.
    static func lineStep(font: UIFont, displayScale: CGFloat) -> CGFloat {
        // A detached view can report a scale of 0 before it reaches a window; 2x is the coarsest grid this ships to.
        let scale = displayScale > 0 ? displayScale : 2
        return (font.lineHeight * scale).rounded(.up) / scale
    }

    /// The height of a field holding exactly `lines` whole lines.
    static func height(
        forLines lines: Int, font: UIFont, insets: UIEdgeInsets, displayScale: CGFloat
    ) -> CGFloat {
        lineStep(font: font, displayScale: displayScale) * CGFloat(max(1, lines))
            + insets.top + insets.bottom
    }

    /// How many whole lines of composer text fit in `height` points of field, never more than `ceiling` and never fewer than one.
    static func lineCount(fitting height: CGFloat, upTo ceiling: Int, displayScale: CGFloat) -> Int {
        let step = lineStep(font: bodyFont, displayScale: displayScale)
        let forText = height - textInsets.top - textInsets.bottom
        guard step > 0, forText >= step else { return 1 }
        // 1e-6 so a budget that is exactly N lines is not read as N - 1 by a float hair.
        return min(ceiling, max(1, Int(forText / step + 1e-6)))
    }

    final class ComposerTextView: UITextView {
        /// The growth cap, in lines; past it the field holds its height and scrolls.
        var maxLineCount: Int = 16 {
            didSet {
                guard maxLineCount != oldValue else { return }
                applyHeightPolicy()
            }
        }
        private var lastLayoutWidth: CGFloat = 0

        /// The width to lay text out at; the fallback is transient because `layoutSubviews` re-invalidates once the real width arrives.
        private var layoutWidth: CGFloat { bounds.width > 0 ? bounds.width : 300 }

        /// Content-sized while it fits, capped at `maxLineCount` lines, and scrollable from there.
        ///
        /// `sizeThatFits` is used rather than `layoutManager.usedRect`, which reports the viewport once scrolling turns on.
        func applyHeightPolicy() {
            let full = sizeThatFits(CGSize(width: layoutWidth, height: .greatestFiniteMagnitude)).height
            isScrollEnabled = full > capHeight
            invalidateIntrinsicContentSize()
        }

        /// Whole lines, never a fraction of one: the laid-out text is rounded up to the line it reaches into, floored at one and capped at `maxLineCount`.
        override var intrinsicContentSize: CGSize {
            let full = sizeThatFits(CGSize(width: layoutWidth, height: .greatestFiniteMagnitude))
            let height = min(height(forLines: lines(filling: full.height)), capHeight)
            return CGSize(width: full.width, height: height)
        }

        /// How many whole lines a laid-out height reaches into, at least one.
        private func lines(filling contentHeight: CGFloat) -> Int {
            let text = contentHeight - textContainerInset.top - textContainerInset.bottom
            let step = GrowingComposerField.lineStep(font: resolvedFont, displayScale: scale)
            guard step > 0, text > 0 else { return 1 }
            // The epsilon is not decoration: a height of exactly N lines divides to N, and `.up` on N is N + 1.
            return max(1, Int((text / step - 0.001).rounded(.up)))
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            if bounds.width != lastLayoutWidth {
                lastLayoutWidth = bounds.width
                invalidateIntrinsicContentSize()
            }
        }

        private var capHeight: CGFloat { height(forLines: max(1, maxLineCount)) }

        private var resolvedFont: UIFont { font ?? GrowingComposerField.bodyFont }

        /// The pixel grid this field's lines are quantised to.
        private var scale: CGFloat { traitCollection.displayScale }

        /// A whole number of quantised lines plus the insets; see `GrowingComposerField.lineStep`.
        private func height(forLines lines: Int) -> CGFloat {
            GrowingComposerField.height(
                forLines: lines,
                font: resolvedFont,
                insets: textContainerInset,
                displayScale: scale
            )
        }
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: GrowingComposerField

        init(parent: GrowingComposerField) {
            self.parent = parent
        }

        func textViewDidChange(_ textView: UITextView) {
            parent.text = textView.text ?? ""
            guard let textView = textView as? ComposerTextView else { return }
            textView.applyHeightPolicy()
        }

        func textViewDidBeginEditing(_ textView: UITextView) {
            if !parent.isFocused { parent.isFocused = true }
        }

        func textViewDidEndEditing(_ textView: UITextView) {
            if parent.isFocused { parent.isFocused = false }
        }
    }
}
