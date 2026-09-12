import SwiftUI
import UIKit

// MARK: - The type rung as a UIFont

extension HermesTextStyle {
    /// The rung, scaled for Dynamic Type as `View.font(_:)` scales it, in one builder for every UIKit text surface.
    var uiFont: UIFont {
        let base: UIFont = design == .monospaced
            ? .monospacedSystemFont(ofSize: size, weight: uiWeight)
            : .systemFont(ofSize: size, weight: uiWeight)
        return UIFontMetrics(forTextStyle: uiTextStyle).scaledFont(for: base)
    }

    /// The same rung with its digits on one width, so "9." and "10." start their words in the same column.
    var uiDigitFont: UIFont {
        guard design != .monospaced else { return uiFont }
        return UIFontMetrics(forTextStyle: uiTextStyle)
            .scaledFont(for: .monospacedDigitSystemFont(ofSize: size, weight: uiWeight))
    }

    var uiWeight: UIFont.Weight {
        switch weight {
        case .semibold: return .semibold
        case .medium: return .medium
        case .bold: return .bold
        default: return .regular
        }
    }

    var uiTextStyle: UIFont.TextStyle {
        switch relativeTo {
        case .largeTitle: return .largeTitle
        case .title: return .title1
        case .title2: return .title2
        case .title3: return .title3
        case .headline: return .headline
        case .subheadline: return .subheadline
        case .callout: return .callout
        case .footnote: return .footnote
        case .caption: return .caption1
        case .caption2: return .caption2
        default: return .body
        }
    }
}

// MARK: - The text view

/// BUG-124: markers are drawn as real characters so a drag can begin on one, and `copy(_:)` maps each back to the source markdown it stands for.
///
/// Three kinds of substitution: a marker (drawn text standing for source text), a prefix (source text with nothing drawn for it, like a heading's hashes), and a separator (one drawn newline standing for more than one). All are block-level line syntax; inline emphasis is deliberately not restored, because the inline parser consumed it long before this.
///
/// Only `copy(_:)` is intercepted, and it writes the plain string itself so a run with no substitutions takes the identical path; Share and Look Up get the drawn form and are left alone.
final class SelectableTextView: UITextView {
    /// One piece of drawn text and the source markdown it stands for; a zero-length range is an insertion, contributing its source when the character at its location is selected.
    struct MarkerSubstitution: Equatable {
        let range: NSRange
        let source: String
    }

    /// Empty for a run with no markers, no headings and no swallowed blank lines, which copies verbatim.
    var markerSubstitutions: [MarkerSubstitution] = []

    override func copy(_ sender: Any?) {
        guard selectedRange.length > 0 else { return super.copy(sender) }
        UIPasteboard.general.string = sourceText(for: selectedRange)
    }

    /// BUG-137: a selection does not outlive the focus that made it.
    ///
    /// `UITextView` keeps `selectedTextRange` across a resign but draws it only while first responder, so a dismissed selection looks gone and is re-grabbed by the next long press inside it; the resign is the one event that covers every way focus leaves.
    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned, selectedRange.length > 0 { selectedTextRange = nil }
        return resigned
    }

    /// The selection as source markdown; a partially selected marker still contributes the whole of it.
    func sourceText(for range: NSRange) -> String {
        let full = (attributedText?.string ?? text ?? "") as NSString
        let bounded = NSIntersectionRange(range, NSRange(location: 0, length: full.length))
        guard bounded.length > 0 else { return "" }

        var result = ""
        var cursor = bounded.location
        let end = NSMaxRange(bounded)
        // Insertions before drawn substitutions at the same location, so a heading's hashes precede anything drawn at its first character.
        let ordered = markerSubstitutions.sorted {
            $0.range.location == $1.range.location ? $0.range.length < $1.range.length : $0.range.location < $1.range.location
        }
        for substitution in ordered {
            if substitution.range.length == 0 {
                guard substitution.range.location >= bounded.location,
                      substitution.range.location < end else { continue }
            } else {
                guard NSIntersectionRange(substitution.range, bounded).length > 0 else { continue }
            }
            if substitution.range.location > cursor {
                result += full.substring(with: NSRange(location: cursor, length: substitution.range.location - cursor))
            }
            result += substitution.source
            cursor = max(cursor, min(NSMaxRange(substitution.range), end))
        }
        if cursor < end {
            result += full.substring(with: NSRange(location: cursor, length: end - cursor))
        }
        return result
    }
}

// MARK: - SelectableText

/// BUG-058: a reply's words on a read-only `UITextView`, so iOS's own selection owns the long press.
///
/// Not `Text.textSelection(.enabled)`, which on iOS selects the whole run with no loupe, no handles and no substring, and inside this transcript produces nothing at all.
///
/// The view is selectable and nothing else: not editable, not scrolling, clear and inset-free, sized by `sizeThatFits` so a paragraph is the height `Text` gave it. It is hidden from accessibility with the words re-stated on a synthetic element, because a `UITextView` reports as a text view and would take every transcript row out of `app.staticTexts` and stand in for the composer in `app.textViews.firstMatch`.
///
/// BUG-124: one view per contiguous span, ending only at a horizontal rule, a table or a fenced code block, so a drag is not stopped by every newline. The structure the `VStack` drew is rebuilt in paragraph styles; `NSTextList` is deliberately not used, because its availability at this deployment target is unestablished.
struct SelectableText: View {
    /// One paragraph of a span; a heading, a bullet and a quotation can share one text container.
    struct Paragraph: Equatable {
        var text: AttributedString
        /// `nil` takes the view's rung. A heading carries its own.
        var style: HermesTextStyle?
        /// `nil` takes the view's colour. A quotation carries `text-3`.
        var color: Color?
        /// Drawn before the words, a tab between it and them. `"•"`, `"1."`, `"▎"`.
        var marker: String = ""
        /// What `copy(_:)` puts on the clipboard in the drawn marker's place: `"- "`, `"1. "`, `"> "`, with the nesting the depth came from.
        var copyMarker: String = ""
        /// Source markdown with nothing drawn for it: a heading's `"### "`.
        var copyPrefix: String = ""
        /// The marker's colour. `nil` takes the view's.
        var markerColor: Color?
        /// Space between the marker and the words.
        var markerGap: CGFloat = Space.s3
        /// Nesting level, at 12 pt of indent per level.
        var depth: Int = 0
        /// A step's number is monospaced so a ten-item list does not step sideways at "10.".
        var marksWithDigits: Bool = false
        /// Space above this paragraph.
        var spacingBefore: CGFloat = 0
        /// Space below it, including the blank lines this span swallowed.
        var spacingAfter: CGFloat = 0
        /// How many blank source lines followed this paragraph: drawn as spacing, restored as newlines on copy.
        var blankLinesAfter: Int = 0
    }

    let paragraphs: [Paragraph]
    let style: HermesTextStyle
    let color: Color

    init(_ text: AttributedString, style: HermesTextStyle, color: Color) {
        self.init(paragraphs: [Paragraph(text: text)], style: style, color: color)
    }

    init(_ text: String, style: HermesTextStyle, color: Color) {
        self.init(AttributedString(text), style: style, color: color)
    }

    init(paragraphs: [Paragraph], style: HermesTextStyle, color: Color) {
        self.paragraphs = paragraphs
        self.style = style
        self.color = color
    }

    /// The words without the drawn markers, which is what the synthetic accessibility element carries.
    private var spokenText: String {
        paragraphs.map { String($0.text.characters) }.joined(separator: "\n")
    }

    var body: some View {
        SelectableTextRepresentable(paragraphs: paragraphs, style: style, color: color)
            // A representable has no baseline of its own and would hand `.firstTextBaseline` its bottom edge, putting a bullet's dot at the foot of a three-line item.
            .alignmentGuide(.firstTextBaseline) { _ in (paragraphs.first?.style ?? style).uiFont.ascender }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(spokenText)
            .accessibilityAddTraits(.isStaticText)
    }
}

private struct SelectableTextRepresentable: UIViewRepresentable {
    let paragraphs: [SelectableText.Paragraph]
    let style: HermesTextStyle
    let color: Color
    /// Read so a category change re-runs `updateUIView`; the rung's scaled point size is what the render key changes on.
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    final class Coordinator {
        struct Key: Equatable {
            let paragraphs: [SelectableText.Paragraph]
            let pointSize: CGFloat
            let color: UIColor
        }
        var key: Key?
        var memo = SelectableTextSizeMemo()
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> SelectableTextView {
        ColdOpenTrace.measureAccumulating("selectable.makeUIView") { Self.makeTextView() }
    }

    private static func makeTextView() -> SelectableTextView {
        let view = SelectableTextView()
        view.isEditable = false
        view.isSelectable = true
        view.isScrollEnabled = false
        view.scrollsToTop = false
        view.backgroundColor = .clear
        view.textContainerInset = .zero
        view.textContainer.lineFragmentPadding = 0
        view.adjustsFontForContentSizeCategory = true
        // Links come from the markdown, never from detection, which would turn a model id or a path into a tappable thing it is not.
        view.dataDetectorTypes = []
        // See the type doc: the synthetic SwiftUI element carries the words.
        view.isAccessibilityElement = false
        view.accessibilityElementsHidden = true
        // Exactly as tall as the text, wrapping rather than pushing its row wider.
        view.setContentHuggingPriority(.required, for: .vertical)
        view.setContentCompressionResistancePriority(.required, for: .vertical)
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return view
    }

    func updateUIView(_ view: SelectableTextView, context: Context) {
        let font = style.uiFont
        let uiColor = UIColor(color)
        let key = Coordinator.Key(paragraphs: paragraphs, pointSize: font.pointSize, color: uiColor)
        // Streaming re-evaluates every span on every delta, so only a changed span pays for a re-render.
        guard context.coordinator.key != key else { return }
        context.coordinator.key = key
        // The remembered height described the previous words, so new words, size or colour invalidate it.
        context.coordinator.memo.invalidate()
        ColdOpenTrace.measureAccumulating("selectable.setAttributedText") {
            let rendered = Self.render(paragraphs, style: style, color: uiColor)
            view.attributedText = rendered.text
            view.markerSubstitutions = rendered.substitutions
        }
    }

    /// `sizeThatFits` for the full laid-out height, at the text's own width rather than the offer, so a short user turn hugs its bubble.
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: SelectableTextView, context: Context) -> CGSize? {
        let bound: CGFloat
        if let width = proposal.width, width.isFinite, width > 0 {
            bound = width
        } else {
            bound = 10_000
        }
        // BUG-123: the answer cannot have changed, because the only inputs are the attributed text, which `updateUIView` invalidates on, and the width.
        if let remembered = context.coordinator.memo.size(forWidth: bound) { return remembered }
        let fitted = ColdOpenTrace.measureAccumulating("selectable.sizeThatFits") {
            uiView.sizeThatFits(CGSize(width: bound, height: .greatestFiniteMagnitude))
        }
        let result = CGSize(width: min(fitted.width.rounded(.up), bound), height: fitted.height.rounded(.up))
        context.coordinator.memo.record(width: bound, size: result)
        return result
    }

    /// A span's paragraphs as one attributed string, plus where each drawn
    /// marker is and what it stands for.
    struct Rendered {
        let text: NSAttributedString
        let substitutions: [SelectableTextView.MarkerSubstitution]
    }

    static func render(
        _ paragraphs: [SelectableText.Paragraph],
        style: HermesTextStyle,
        color: UIColor
    ) -> Rendered {
        let result = NSMutableAttributedString()
        var substitutions: [SelectableTextView.MarkerSubstitution] = []

        for (index, paragraph) in paragraphs.enumerated() {
            let rung = paragraph.style ?? style
            let font = rung.uiFont
            let bodyColor = paragraph.color.map { UIColor($0) } ?? color
            let markerColor = paragraph.markerColor.map { UIColor($0) } ?? bodyColor
            let start = result.length

            // A heading draws no marker and is still markdown, so its hashes register as an insertion at its first character.
            if !paragraph.copyPrefix.isEmpty {
                substitutions.append(SelectableTextView.MarkerSubstitution(
                    range: NSRange(location: start, length: 0),
                    source: paragraph.copyPrefix
                ))
            }

            var markerWidth: CGFloat = 0
            if !paragraph.marker.isEmpty {
                let markerFont = paragraph.marksWithDigits ? rung.uiDigitFont : font
                let drawn = paragraph.marker + "\t"
                markerWidth = (paragraph.marker as NSString)
                    .size(withAttributes: [.font: markerFont])
                    .width
                result.append(NSAttributedString(
                    string: drawn,
                    attributes: [.font: markerFont, .foregroundColor: markerColor]
                ))
                substitutions.append(SelectableTextView.MarkerSubstitution(
                    range: NSRange(location: start, length: (drawn as NSString).length),
                    source: paragraph.copyMarker
                ))
            }

            result.append(render(paragraph.text, style: rung, font: font, color: bodyColor))

            // The separator belongs to the paragraph it ends, so the terminating character carries that line's style rather than the next one's indents.
            if index < paragraphs.count - 1 {
                let separator = NSRange(location: result.length, length: 1)
                result.append(NSAttributedString(string: "\n", attributes: [.font: font, .foregroundColor: bodyColor]))
                if paragraph.blankLinesAfter > 0 {
                    substitutions.append(SelectableTextView.MarkerSubstitution(
                        range: separator,
                        source: String(repeating: "\n", count: paragraph.blankLinesAfter + 1)
                    ))
                }
            }

            let indent = CGFloat(paragraph.depth) * Space.s5
            let hanging = paragraph.marker.isEmpty ? indent : indent + markerWidth + paragraph.markerGap
            let paragraphStyle = NSMutableParagraphStyle()
            paragraphStyle.lineBreakMode = .byWordWrapping
            paragraphStyle.firstLineHeadIndent = indent
            // A wrapped item hangs under its first character, not under its dot.
            paragraphStyle.headIndent = hanging
            if !paragraph.marker.isEmpty {
                paragraphStyle.tabStops = [NSTextTab(textAlignment: .left, location: hanging)]
                paragraphStyle.defaultTabInterval = hanging
            }
            paragraphStyle.paragraphSpacingBefore = paragraph.spacingBefore
            paragraphStyle.paragraphSpacing = paragraph.spacingAfter
            result.addAttribute(
                .paragraphStyle,
                value: paragraphStyle,
                range: NSRange(location: start, length: result.length - start)
            )
        }
        return Rendered(text: result, substitutions: substitutions)
    }

    /// The inline markdown as attributes UIKit draws: `Text` resolves `inlinePresentationIntent` itself, a `UITextView` draws only fonts, so the intents are resolved here.
    static func render(_ source: AttributedString, style: HermesTextStyle, font: UIFont, color: UIColor) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let codeFont = UIFontMetrics(forTextStyle: style.uiTextStyle)
            .scaledFont(for: .monospacedSystemFont(ofSize: style.size, weight: style.uiWeight))
        for run in source.runs {
            let intent = run.inlinePresentationIntent ?? []
            var runFont = intent.contains(.code) ? codeFont : font
            var traits: UIFontDescriptor.SymbolicTraits = []
            if intent.contains(.stronglyEmphasized) { traits.insert(.traitBold) }
            if intent.contains(.emphasized) { traits.insert(.traitItalic) }
            if !traits.isEmpty,
               let descriptor = runFont.fontDescriptor.withSymbolicTraits(runFont.fontDescriptor.symbolicTraits.union(traits)) {
                runFont = UIFont(descriptor: descriptor, size: runFont.pointSize)
            }
            var attributes: [NSAttributedString.Key: Any] = [.font: runFont, .foregroundColor: color]
            if intent.contains(.strikethrough) {
                attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
            }
            if let link = run.link {
                attributes[.link] = link
            }
            result.append(NSAttributedString(string: String(source[run.range].characters), attributes: attributes))
        }
        return result
    }
}

// MARK: - The remembered height

/// BUG-123: the last height TextKit produced for one span, remembered against the width it was asked for, because `sizeThatFits` is a full layout and SwiftUI probes a representable repeatedly.
///
/// Deliberately one entry, not a dictionary: a span is measured at one width at a time.
struct SelectableTextSizeMemo: Equatable {
    private var width: CGFloat?
    private var fitted: CGSize?

    /// Forget, when the words, the point size or the colour change.
    mutating func invalidate() {
        width = nil
        fitted = nil
    }

    /// The remembered size, if it was measured at exactly this width.
    func size(forWidth width: CGFloat) -> CGSize? {
        guard let remembered = self.width, remembered == width else { return nil }
        return fitted
    }

    mutating func record(width: CGFloat, size: CGSize) {
        self.width = width
        fitted = size
    }
}
