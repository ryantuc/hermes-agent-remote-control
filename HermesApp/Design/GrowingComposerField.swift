import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// The live UIKit buffer, including cursor and marked text; a draft string alone cannot fence a completion.
struct ComposerEditorSnapshot: Equatable {
    enum Origin: Equatable { case typing, paste, selection, external, completion }
    var text: String
    var selection: NSRange
    var isComposing: Bool
    var origin: Origin
    var editedRange: NSRange? = nil
}

/// A one-shot edit. The editor rechecks the source buffer when it applies this request.
struct ComposerEditorReplacement {
    let id = UUID()
    var expectedText: String
    var expectedSelection: NSRange
    var range: NSRange
    var text: String
}

enum ComposerCompletionKey: Equatable { case up, down, tab, escape }

/// One image off the pasteboard: the encoded bytes as the pasteboard held them, and what they are.
struct PastedImage: Equatable {
    var data: Data
    var contentType: UTType?

    /// Every item on the pasteboard that carries an image, in the first image encoding the item offers; an item holding only a decoded `UIImage` is encoded as PNG.
    static func read(from pasteboard: UIPasteboard) -> [PastedImage] {
        var images: [PastedImage] = []
        let types = pasteboard.types(forItemSet: nil) ?? []
        for (index, itemTypes) in types.enumerated() {
            let item = IndexSet(integer: index)
            for identifier in itemTypes {
                guard let type = UTType(identifier), type.conforms(to: .image),
                      let data = pasteboard.data(forPasteboardType: identifier, inItemSet: item)?.first,
                      !data.isEmpty
                else { continue }
                images.append(PastedImage(data: data, contentType: type))
                break
            }
        }
        if images.isEmpty, let decoded = pasteboard.images {
            images = decoded.compactMap { image in
                image.pngData().map { PastedImage(data: $0, contentType: .png) }
            }
        }
        return images
    }
}

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
    var replacement: ComposerEditorReplacement?
    var hasCompletions: Bool
    var onEditorChange: ((ComposerEditorSnapshot) -> Void)?
    var onCompletionKey: ((ComposerCompletionKey) -> Void)?
    /// BUG-057: images pasted into the field, which a `String` draft cannot hold.
    var onPasteImages: (([PastedImage]) -> Void)?

    init(
        text: Binding<String>,
        placeholder: String,
        textColor: Color,
        maxLineCount: Int = 16,
        isFocused: Binding<Bool>,
        replacement: ComposerEditorReplacement? = nil,
        hasCompletions: Bool = false,
        onEditorChange: ((ComposerEditorSnapshot) -> Void)? = nil,
        onCompletionKey: ((ComposerCompletionKey) -> Void)? = nil,
        onPasteImages: (([PastedImage]) -> Void)? = nil
    ) {
        _text = text
        self.placeholder = placeholder
        self.textColor = textColor
        self.maxLineCount = maxLineCount
        _isFocused = isFocused
        self.replacement = replacement
        self.hasCompletions = hasCompletions
        self.onEditorChange = onEditorChange
        self.onCompletionKey = onCompletionKey
        self.onPasteImages = onPasteImages
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
        // Marked text belongs to the input method until it commits. Reconciliation must never replace it.
        if textView.text != text, textView.markedTextRange == nil {
            let selection = textView.selectedRange
            context.coordinator.isReconciling = true
            textView.text = text
            let length = (text as NSString).length
            textView.selectedRange = NSRange(location: min(selection.location, length), length: 0)
            context.coordinator.isReconciling = false
            DispatchQueue.main.async { [weak textView, weak coordinator = context.coordinator] in
                guard let textView, let coordinator, textView.text == text,
                      coordinator.parent.text == text else { return }
                coordinator.report(textView, origin: .external)
            }
        }
        textView.hasCompletions = hasCompletions
        textView.onCompletionKey = onCompletionKey
        textView.onPasteImages = onPasteImages
        if let replacement, context.coordinator.lastReplacementID != replacement.id {
            context.coordinator.lastReplacementID = replacement.id
            DispatchQueue.main.async { [weak textView, weak coordinator = context.coordinator] in
                guard let textView, let coordinator,
                      coordinator.parent.replacement?.id == replacement.id else { return }
                coordinator.apply(replacement, to: textView)
            }
        }
        textView.textColor = UIColor(textColor)
        textView.font = Self.bodyFont
        textView.accessibilityLabel = text.isEmpty ? placeholder : nil
        textView.maxLineCount = maxLineCount
        textView.applyHeightPolicy()
        // Bridge SwiftUI focus to UIKit first responder; the coordinator writes the binding back on begin and end editing.
        // BUG-146: compared before hopping, so the update every keystroke causes schedules nothing when the two already agree. The hop is still needed when they disagree, because a view not yet in a window cannot become first responder; it compares again when it runs.
        guard Self.focusRequest(isFocused: isFocused, isFirstResponder: textView.isFirstResponder) != nil else { return }
        context.coordinator.focusHopsScheduled += 1
        DispatchQueue.main.async {
            switch Self.focusRequest(isFocused: isFocused, isFirstResponder: textView.isFirstResponder) {
            case .become: textView.becomeFirstResponder()
            case .resign: textView.resignFirstResponder()
            case nil: break
            }
        }
    }

    /// What it takes to make UIKit's first responder agree with the focus binding; nil when they already agree.
    enum FocusRequest: Equatable { case become, resign }

    static func focusRequest(isFocused: Bool, isFirstResponder: Bool) -> FocusRequest? {
        if isFocused && !isFirstResponder { return .become }
        if !isFocused && isFirstResponder { return .resign }
        return nil
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
        var hasCompletions = false
        var onCompletionKey: ((ComposerCompletionKey) -> Void)?
        var onPasteImages: (([PastedImage]) -> Void)?
        /// Where Paste reads from. A test hands in a named pasteboard, which the system does not guard with a paste prompt.
        var pasteboard: UIPasteboard = .general
        private(set) var isPasting = false

        override func paste(_ sender: Any?) {
            if takePastedImages() { return }
            isPasting = true
            defer { isPasting = false }
            super.paste(sender)
        }

        /// The image half of Paste: true when the pasteboard's images were handed to `onPasteImages` and the text view has nothing left to paste.
        /// BUG-057: the draft is a `String`, so an image pasted into the text view itself vanished. Only a paste with no text on it is taken; text, and text with a picture beside it (a selection copied from a web page), stays the text view's.
        func takePastedImages() -> Bool {
            guard let onPasteImages, pasteboard.hasImages, !pasteboard.hasStrings else { return false }
            let images = PastedImage.read(from: pasteboard)
            guard !images.isEmpty else { return false }
            onPasteImages(images)
            return true
        }

        /// Paste is offered for an image-only pasteboard too, which a plain-text view would otherwise not do.
        override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
            if action == #selector(paste(_:)), onPasteImages != nil, pasteboard.hasImages {
                return true
            }
            return super.canPerformAction(action, withSender: sender)
        }

        // Enter keeps UITextView's ordinary newline behavior. Only the four completion keys are claimed.
        override var keyCommands: [UIKeyCommand]? {
            guard hasCompletions, markedTextRange == nil else { return super.keyCommands }
            let commands = [
                UIKeyCommand(input: UIKeyCommand.inputUpArrow, modifierFlags: [], action: #selector(completionUp)),
                UIKeyCommand(input: UIKeyCommand.inputDownArrow, modifierFlags: [], action: #selector(completionDown)),
                UIKeyCommand(input: "\t", modifierFlags: [], action: #selector(completionTab)),
                UIKeyCommand(input: UIKeyCommand.inputEscape, modifierFlags: [], action: #selector(completionEscape))
            ]
            commands.forEach { $0.wantsPriorityOverSystemBehavior = true }
            return commands + (super.keyCommands ?? [])
        }

        @objc private func completionUp() { onCompletionKey?(.up) }
        @objc private func completionDown() { onCompletionKey?(.down) }
        @objc private func completionTab() { onCompletionKey?(.tab) }
        @objc private func completionEscape() { onCompletionKey?(.escape) }

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
        var lastReplacementID: UUID?
        var isReconciling = false
        /// How many main-queue hops `updateUIView` has scheduled to reconcile focus; read by tests.
        var focusHopsScheduled = 0
        private var nextOrigin: ComposerEditorSnapshot.Origin = .typing
        private var nextEditedRange: NSRange?

        init(parent: GrowingComposerField) {
            self.parent = parent
        }

        func textViewDidChange(_ textView: UITextView) {
            guard !isReconciling else { return }
            parent.text = textView.text ?? ""
            report(textView, origin: nextOrigin, editedRange: nextEditedRange)
            nextOrigin = .typing
            nextEditedRange = nil
            guard let textView = textView as? ComposerTextView else { return }
            textView.applyHeightPolicy()
        }

        func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
            // A bulk leading slash also catches drop/autofill. Multi-character IME commits and
            // autocorrection elsewhere remain typing; their length alone does not mean paste.
            let insertsBulkSlash = range.location == 0 && text.hasPrefix("/") && text.count > 1
            nextOrigin = (textView as? ComposerTextView)?.isPasting == true || insertsBulkSlash ? .paste : .typing
            nextEditedRange = range
            return true
        }

        func textViewDidChangeSelection(_ textView: UITextView) {
            guard !isReconciling else { return }
            report(textView, origin: .selection)
        }

        func report(_ textView: UITextView, origin: ComposerEditorSnapshot.Origin, editedRange: NSRange? = nil) {
            parent.onEditorChange?(ComposerEditorSnapshot(
                text: textView.text ?? "", selection: textView.selectedRange,
                isComposing: textView.markedTextRange != nil, origin: origin, editedRange: editedRange
            ))
        }

        /// Return false for a late result, moved cursor, nonempty marked text, or an invalid UTF16 range.
        @discardableResult
        func apply(_ edit: ComposerEditorReplacement, to textView: ComposerTextView) -> Bool {
            guard textView.markedTextRange == nil,
                  textView.text == edit.expectedText,
                  textView.selectedRange == edit.expectedSelection,
                  Self.isValidUTF16Range(edit.range, in: edit.expectedText),
                  Range(edit.range, in: edit.expectedText) != nil,
                  let start = textView.position(from: textView.beginningOfDocument, offset: edit.range.location),
                  let end = textView.position(from: start, offset: edit.range.length),
                  let range = textView.textRange(from: start, to: end) else { return false }
            isReconciling = true
            textView.replace(range, withText: edit.text)
            textView.selectedRange = NSRange(location: edit.range.location + (edit.text as NSString).length, length: 0)
            isReconciling = false
            parent.text = textView.text ?? ""
            textView.applyHeightPolicy()
            report(textView, origin: .completion, editedRange: edit.range)
            return true
        }

        /// Foundation can bridge a range bisecting a surrogate pair to a String range, so validate
        /// the UTF16 boundaries explicitly before handing an edit to TextKit.
        private static func isValidUTF16Range(_ range: NSRange, in text: String) -> Bool {
            let utf16 = text as NSString
            guard range.location >= 0, range.length >= 0,
                  range.location <= utf16.length,
                  range.length <= utf16.length - range.location else { return false }
            func isScalarBoundary(_ offset: Int) -> Bool {
                guard offset > 0, offset < utf16.length else { return true }
                let before = utf16.character(at: offset - 1)
                let after = utf16.character(at: offset)
                return !(0xD800...0xDBFF).contains(before) || !(0xDC00...0xDFFF).contains(after)
            }
            return isScalarBoundary(range.location) && isScalarBoundary(range.location + range.length)
        }

        func textViewDidBeginEditing(_ textView: UITextView) {
            if !parent.isFocused { parent.isFocused = true }
        }

        func textViewDidEndEditing(_ textView: UITextView) {
            if parent.isFocused { parent.isFocused = false }
        }
    }
}
