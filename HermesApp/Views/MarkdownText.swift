import SwiftUI
import UIKit

/// A block of assistant output after fenced-code splitting.
enum MarkdownBlock: Identifiable, Equatable {
    case prose(id: String, lines: [MarkdownLine])
    case code(id: String, language: String, content: String)
    /// A GFM pipe table, a sibling of `.prose` and never a line inside one, because the grid owns its own column layout and horizontal scroller.
    case table(id: String, headers: [String], alignments: [TableAlignment], rows: [[String]])

    var id: String {
        switch self {
        case .prose(let id, _), .code(let id, _, _), .table(let id, _, _, _): return id
        }
    }
}

/// What the colons in a GFM separator row say about a column.
enum TableAlignment: Equatable {
    case none
    case left
    case center
    case right
}

/// One line of prose, classified so the renderer can give it structure without pulling in a Markdown package.
struct MarkdownLine: Identifiable, Equatable {
    enum Kind: Equatable {
        case paragraph
        case heading(level: Int)
        case bullet(depth: Int)
        case ordered(depth: Int, marker: String)
        case quote
        case rule
    }

    let id: String
    let kind: Kind
    let text: String
}

/// Dependency-free Markdown. `AttributedString(markdown:)` handles inline syntax but flattens block structure and mangles fenced code, so fences are split out first; `.inlineOnlyPreservingWhitespace` keeps the hard line breaks `.full` throws away, and `.returnPartiallyParsedIfPossible` stops a half-streamed `**bold` blanking a bubble mid-token.
enum MarkdownParser {
    static func blocks(from source: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        var proseLines: [String] = []
        var codeLines: [String] = []
        var codeLanguage = ""
        var inFence = false
        var index = 0

        func emitProse(_ lines: [String]) {
            let joined = lines.joined(separator: "\n")
            guard !joined.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            blocks.append(.prose(id: "p\(blocks.count)", lines: classify(joined, seed: blocks.count)))
        }

        /// Everything that is not fenced code lands here as one `.prose` block, except where a GFM pipe table interrupts it and is carved out into its own.
        func flushProse() {
            defer { proseLines.removeAll() }
            var pending: [String] = []
            var cursor = 0
            while cursor < proseLines.count {
                if let run = tableRun(in: proseLines, startingAt: cursor) {
                    emitProse(pending)
                    pending.removeAll()
                    blocks.append(.table(
                        id: "t\(blocks.count)",
                        headers: run.headers,
                        alignments: run.alignments,
                        rows: run.rows
                    ))
                    cursor = run.end
                } else {
                    pending.append(proseLines[cursor])
                    cursor += 1
                }
            }
            emitProse(pending)
        }

        for rawLine in source.components(separatedBy: "\n") {
            index += 1
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                if inFence {
                    blocks.append(.code(
                        id: "c\(blocks.count)",
                        language: codeLanguage,
                        content: codeLines.joined(separator: "\n")
                    ))
                    codeLines.removeAll()
                    codeLanguage = ""
                    inFence = false
                } else {
                    flushProse()
                    codeLanguage = String(trimmed.dropFirst(3))
                        .trimmingCharacters(in: .whitespaces)
                        .lowercased()
                    inFence = true
                }
                continue
            }
            if inFence {
                codeLines.append(rawLine)
            } else {
                proseLines.append(rawLine)
            }
        }

        if inFence {
            // An unterminated fence is the normal state mid-stream, so render what has arrived rather than swallowing it.
            blocks.append(.code(
                id: "c\(blocks.count)",
                language: codeLanguage,
                content: codeLines.joined(separator: "\n")
            ))
        }
        flushProse()
        return blocks
    }

    private static func classify(_ source: String, seed: Int) -> [MarkdownLine] {
        source.components(separatedBy: "\n").enumerated().map { offset, raw in
            let id = "l\(seed)-\(offset)"
            let indent = raw.prefix { $0 == " " || $0 == "\t" }.count
            let trimmed = raw.trimmingCharacters(in: .whitespaces)

            if trimmed == "---" || trimmed == "***" || trimmed == "___" {
                return MarkdownLine(id: id, kind: .rule, text: "")
            }
            if trimmed.hasPrefix("#") {
                let hashes = trimmed.prefix { $0 == "#" }.count
                if hashes <= 6, trimmed.dropFirst(hashes).hasPrefix(" ") {
                    return MarkdownLine(
                        id: id,
                        kind: .heading(level: hashes),
                        text: String(trimmed.dropFirst(hashes)).trimmingCharacters(in: .whitespaces)
                    )
                }
            }
            if trimmed.hasPrefix("> ") || trimmed == ">" {
                return MarkdownLine(id: id, kind: .quote, text: String(trimmed.dropFirst(1)).trimmingCharacters(in: .whitespaces))
            }
            for marker in ["- ", "* ", "+ "] where trimmed.hasPrefix(marker) {
                return MarkdownLine(
                    id: id,
                    kind: .bullet(depth: min(indent / 2, 3)),
                    text: String(trimmed.dropFirst(2))
                )
            }
            if let dot = trimmed.firstIndex(of: "."),
               trimmed.distance(from: trimmed.startIndex, to: dot) <= 3,
               Int(trimmed[trimmed.startIndex..<dot]) != nil,
               trimmed.index(after: dot) < trimmed.endIndex,
               trimmed[trimmed.index(after: dot)] == " " {
                return MarkdownLine(
                    id: id,
                    kind: .ordered(depth: min(indent / 2, 3), marker: String(trimmed[trimmed.startIndex..<dot]) + "."),
                    text: String(trimmed[trimmed.index(dot, offsetBy: 2)...])
                )
            }
            return MarkdownLine(id: id, kind: .paragraph, text: trimmed)
        }
    }

    /// A GFM pipe table found inside a run of prose lines.
    private struct TableRun {
        let headers: [String]
        let alignments: [TableAlignment]
        let rows: [[String]]
        /// Index of the first line after the table.
        let end: Int
    }

    /// A fully piped header row, a separator, then body rows, ending at the first line that is not a pipe row. Deliberately narrower than the GFM grammar, and a header row whose separator has not arrived yet stays prose so a streaming bubble never flashes a one-row grid.
    private static func tableRun(in lines: [String], startingAt start: Int) -> TableRun? {
        guard start + 1 < lines.count,
              let headers = pipeCells(lines[start]),
              let alignments = separatorAlignments(lines[start + 1]),
              alignments.count == headers.count else { return nil }

        var rows: [[String]] = []
        var cursor = start + 2
        while cursor < lines.count, let cells = pipeCells(lines[cursor]) {
            rows.append(fit(cells, to: headers.count))
            cursor += 1
        }
        return TableRun(headers: headers, alignments: alignments, rows: rows, end: cursor)
    }

    /// Splits `| a | b |` into its cells, or nil when the line is not a pipe row. An escaped pipe is not a cell boundary, and the escape is left in the text so the inline parser resolves it as it would inside a paragraph.
    private static func pipeCells(_ raw: String) -> [String]? {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard trimmed.count >= 3, trimmed.hasPrefix("|"), trimmed.hasSuffix("|") else { return nil }

        var cells: [String] = []
        var current = ""
        var escaping = false
        for character in trimmed.dropFirst().dropLast() {
            if escaping {
                current.append(character)
                escaping = false
            } else if character == "\\" {
                current.append(character)
                escaping = true
            } else if character == "|" {
                cells.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
            } else {
                current.append(character)
            }
        }
        cells.append(current.trimmingCharacters(in: .whitespaces))
        guard cells.count >= 2 else { return nil }
        return cells
    }

    /// `| --- | :---: |` becomes one alignment per column and anything else is nil; a piped separator is never a `.rule`, because the table absorbs it.
    private static func separatorAlignments(_ raw: String) -> [TableAlignment]? {
        guard let cells = pipeCells(raw) else { return nil }
        var alignments: [TableAlignment] = []
        for cell in cells {
            var dashes = cell
            let left = dashes.hasPrefix(":")
            if left { dashes.removeFirst() }
            let right = dashes.hasSuffix(":")
            if right { dashes.removeLast() }
            guard dashes.count >= 3, dashes.allSatisfy({ $0 == "-" }) else { return nil }
            switch (left, right) {
            case (true, true): alignments.append(.center)
            case (true, false): alignments.append(.left)
            case (false, true): alignments.append(.right)
            case (false, false): alignments.append(.none)
            }
        }
        return alignments
    }

    /// A body row is padded or truncated to the header row's arity, so the grid stays rectangular whatever the model emitted.
    private static func fit(_ cells: [String], to width: Int) -> [String] {
        if cells.count == width { return cells }
        if cells.count > width { return Array(cells.prefix(width)) }
        return cells + Array(repeating: "", count: width - cells.count)
    }

    /// Inline-only parse with a graceful fallback. Never throws into a view.
    static func inline(_ source: String) -> AttributedString {
        guard !source.isEmpty else { return AttributedString() }
        let options = AttributedString.MarkdownParsingOptions(
            allowsExtendedAttributes: true,
            interpretedSyntax: .inlineOnlyPreservingWhitespace,
            failurePolicy: .returnPartiallyParsedIfPossible
        )
        if let parsed = try? AttributedString(markdown: source, options: options) {
            return parsed
        }
        return AttributedString(source)
    }
}

/// Renders assistant and user text: fenced code in a scrollable monospaced box with a copy button, everything else as structured prose. The code box is a flat surface and not an enclosure, since enclosure means "this touches your machine".
/// The block parse is memoised by source text in a class held in `@State`, which can be mutated during body evaluation without invalidating anything, so a body evaluation where `text` did not change reuses the last parse.
@MainActor
private final class MarkdownParseCache {
    private var text: String?
    private var blocks: [MarkdownBlock] = []

    func blocks(for text: String) -> [MarkdownBlock] {
        if self.text != text {
            self.text = text
            blocks = ColdOpenTrace.measureAccumulating("markdown.blocks") { MarkdownParser.blocks(from: text) }
        }
        return blocks
    }
}

@MainActor
struct MarkdownText: View {
    @Environment(\.hermes) private var t
    let text: String
    /// `nil` resolves to `text-1`. Passed as a token, never a system role.
    var textColor: Color?
    /// Whether this block sizes to its content instead of filling the width it is offered. A session transcript wants the fill; a conversation bubble wants the hug, because its ground is drawn around this block.
    var hugsContent: Bool = false

    @State private var cache = MarkdownParseCache()

    private var blocks: [MarkdownBlock] { cache.blocks(for: text) }

    var body: some View {
        let color = textColor ?? t.text1
        VStack(alignment: .leading, spacing: Space.s4) {
            ForEach(blocks) { block in
                switch block {
                case .prose(_, let lines):
                    ProseView(lines: lines, textColor: color, hugsContent: hugsContent)
                case .code(_, let language, let content):
                    CodeBlockView(language: language, code: content)
                case .table(_, let headers, let alignments, let rows):
                    TableBlockView(
                        headers: headers,
                        alignments: alignments,
                        rows: rows,
                        textColor: color
                    )
                }
            }
        }
        .frame(maxWidth: hugsContent ? nil : .infinity, alignment: .leading)
    }
}

/// BUG-124: a contiguous group of prose lines that shares one text view, because one selectable view per source line makes a drag stop at every newline the model emitted.
/// Consecutive paragraphs, list items and quote lines each form one run; a heading, a rule and a blank line break one, and fenced code and tables never reach here.
struct ProseRun: Identifiable, Equatable {
    enum Content: Equatable {
        case rule
        /// A blank source line: `Space.s2` of air, and the end of any run.
        case gap
        case heading(level: Int, text: String)
        case paragraphs([MarkdownLine])
        case list([MarkdownLine])
        case quote([MarkdownLine])
    }

    let id: String
    let content: Content

    /// Whether this run draws words on a selectable text view; one view per run is what stops a forty-line reply minting forty `UITextView`s.
    var carriesWords: Bool {
        switch content {
        case .rule, .gap: return false
        case .heading, .paragraphs, .list, .quote: return true
        }
    }
}

enum ProseRunBuilder {
    private enum Pending: Equatable {
        case paragraphs
        case list
        case quote
    }

    static func runs(from lines: [MarkdownLine]) -> [ProseRun] {
        var result: [ProseRun] = []
        var pending: [MarkdownLine] = []
        var open: Pending?

        func flush() {
            defer {
                pending.removeAll()
                open = nil
            }
            guard let kind = open, let first = pending.first else { return }
            switch kind {
            case .paragraphs: result.append(ProseRun(id: first.id, content: .paragraphs(pending)))
            case .list: result.append(ProseRun(id: first.id, content: .list(pending)))
            case .quote: result.append(ProseRun(id: first.id, content: .quote(pending)))
            }
        }

        func extend(_ wanted: Pending, with line: MarkdownLine) {
            if open != wanted {
                flush()
                open = wanted
            }
            pending.append(line)
        }

        for line in lines {
            switch line.kind {
            case .rule:
                flush()
                result.append(ProseRun(id: line.id, content: .rule))
            case .heading(let level):
                flush()
                result.append(ProseRun(id: line.id, content: .heading(level: level, text: line.text)))
            case .paragraph:
                if line.text.isEmpty {
                    flush()
                    result.append(ProseRun(id: line.id, content: .gap))
                } else {
                    extend(.paragraphs, with: line)
                }
            case .bullet, .ordered:
                extend(.list, with: line)
            case .quote:
                extend(.quote, with: line)
            }
        }
        flush()
        return result
    }
}

/// One line of a span, plus the blank lines that followed it. A second stage over `ProseRunBuilder`'s output, welding consecutive word-carrying runs into one span and swallowing the blank lines between them as spacing rather than as boundaries.
struct ProseSpanLine: Equatable {
    let line: MarkdownLine
    /// Blank source lines between this line and the next one in the same span.
    /// They are drawn as extra paragraph spacing and restored as newlines on copy.
    var blanksAfter: Int = 0
}

/// A contiguous stretch of a reply that shares one selectable text view.
struct ProseSpan: Identifiable, Equatable {
    enum Content: Equatable {
        case rule
        /// A blank line at the edge of a span, where it still draws air rather
        /// than joining two paragraphs.
        case gap
        case span([ProseSpanLine])
        /// A quotation is its own span, because its rule is a `Rectangle` beside the words and cannot be one inside a shared text container. Drawn as a per-line glyph instead it comes out as dashes with gaps, since the glyph is shorter than the line box.
        case quote([ProseSpanLine])
    }

    let id: String
    let content: Content

    var carriesWords: Bool {
        switch content {
        case .rule, .gap: return false
        case .span, .quote: return true
        }
    }
}

/// A span runs through paragraphs, list items, quote lines and headings, with blank lines inside it becoming paragraph spacing. Only a horizontal rule, a table and a fenced code block end one, because each owns its own layout and cannot be a paragraph in someone else's text container.
/// Blank lines at the edge of a span stay gaps: that air is already accounted for by the layout around it, and moving it inside the span would change every height.
enum ProseSpanBuilder {
    static func spans(from runs: [ProseRun]) -> [ProseSpan] {
        var result: [ProseSpan] = []
        var pending: [ProseSpanLine] = []
        var blankIDs: [String] = []

        func flushSpan() {
            guard let first = pending.first else { return }
            result.append(ProseSpan(id: first.line.id, content: .span(pending)))
            pending = []
        }

        func flushBlanks() {
            for id in blankIDs { result.append(ProseSpan(id: id, content: .gap)) }
            blankIDs = []
        }

        func absorb(_ lines: [MarkdownLine]) {
            if pending.isEmpty {
                // Leading blanks are the layout's, not the paragraph's.
                flushBlanks()
            } else {
                pending[pending.count - 1].blanksAfter += blankIDs.count
                blankIDs = []
            }
            pending += lines.map { ProseSpanLine(line: $0) }
        }

        for run in runs {
            switch run.content {
            case .rule:
                flushSpan()
                flushBlanks()
                result.append(ProseSpan(id: run.id, content: .rule))
            case .gap:
                blankIDs.append(run.id)
            case .heading(let level, let text):
                absorb([MarkdownLine(id: run.id, kind: .heading(level: level), text: text)])
            case .paragraphs(let lines), .list(let lines):
                absorb(lines)
            case .quote(let lines):
                // The rule cannot be drawn inside a shared container, so a quotation stays its own view.
                flushSpan()
                flushBlanks()
                result.append(ProseSpan(
                    id: run.id,
                    content: .quote(lines.map { ProseSpanLine(line: $0) })
                ))
            }
        }
        flushSpan()
        flushBlanks()
        return result
    }

    static func spans(from lines: [MarkdownLine]) -> [ProseSpan] {
        spans(from: ProseRunBuilder.runs(from: lines))
    }
}

@MainActor
private struct ProseView: View {
    @Environment(\.hermes) private var t
    let lines: [MarkdownLine]
    let textColor: Color
    /// Passed straight down from `MarkdownText`; the fill lives on both this stack and its parent, so dropping it in one place only moves the problem.
    var hugsContent: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s2) {
            ForEach(ProseSpanBuilder.spans(from: lines)) { span in
                switch span.content {
                case .rule:
                    Rectangle()
                        .fill(t.stroke3)
                        .frame(height: 1)
                        .padding(.vertical, Space.s1)

                case .gap:
                    Spacer().frame(height: Space.s2)

                case .span(let spanLines):
                    SelectableText(
                        paragraphs: spanLines.enumerated().map { index, spanLine in
                            paragraph(spanLine, isLast: index == spanLines.count - 1)
                        },
                        style: HermesFont.body,
                        color: textColor
                    )

                case .quote(let spanLines):
                    // The bar spans the whole quotation and is a `Rectangle` rather than a glyph.
                    HStack(alignment: .top, spacing: Space.s4) {
                        Rectangle()
                            .fill(t.stroke3)
                            .frame(width: 3)
                        SelectableText(
                            paragraphs: spanLines.enumerated().map { index, spanLine in
                                paragraph(spanLine, isLast: index == spanLines.count - 1)
                            },
                            style: HermesFont.body,
                            color: t.text3
                        )
                    }
                }
            }
        }
        .frame(maxWidth: hugsContent ? nil : .infinity, alignment: .leading)
    }

    /// One line of a span as a paragraph the text container can draw. The `VStack` spacing this replaces becomes `paragraphSpacing` on the paragraph above and `paragraphSpacingBefore` on a heading, which TextKit adds together the way the stack did.
    private func paragraph(_ spanLine: ProseSpanLine, isLast: Bool) -> SelectableText.Paragraph {
        let line = spanLine.line
        let text = ColdOpenTrace.measureAccumulating("markdown.inline") { MarkdownParser.inline(line.text) }
        // The stack's own 4 pt plus 8 pt for every blank line swallowed, and never after the last paragraph, or the span would be taller than the rows it replaced.
        let after: CGFloat = isLast ? 0 : Space.s2 + CGFloat(spanLine.blanksAfter) * (Space.s2 * 2)

        switch line.kind {
        case .heading(let level):
            return SelectableText.Paragraph(
                text: text,
                style: headingFont(level),
                // A heading is markdown too, so a drag that crosses one pastes the hashes the reply was written with.
                copyPrefix: String(repeating: "#", count: level) + " ",
                spacingBefore: level <= 2 ? Space.s2 : Space.s1,
                spacingAfter: after,
                blankLinesAfter: spanLine.blanksAfter
            )

        case .bullet(let depth):
            return SelectableText.Paragraph(
                text: text,
                marker: "•",
                copyMarker: String(repeating: "  ", count: depth) + "- ",
                markerColor: t.text3,
                depth: depth,
                spacingAfter: after,
                blankLinesAfter: spanLine.blanksAfter
            )

        case .ordered(let depth, let marker):
            return SelectableText.Paragraph(
                text: text,
                marker: marker,
                copyMarker: String(repeating: "  ", count: depth) + marker + " ",
                markerColor: t.text3,
                depth: depth,
                marksWithDigits: true,
                spacingAfter: after,
                blankLinesAfter: spanLine.blanksAfter
            )

        case .quote:
            // No marker: the rule beside a quotation is a `Rectangle` in the stack around this view, so `>` never reaches the text.
            return SelectableText.Paragraph(
                text: text,
                color: t.text3,
                spacingAfter: after,
                blankLinesAfter: spanLine.blanksAfter
            )

        case .paragraph, .rule:
            return SelectableText.Paragraph(
                text: text,
                spacingAfter: after,
                blankLinesAfter: spanLine.blanksAfter
            )
        }
    }

    /// BUG-058: the one door every line of a reply's prose walks through, so a kind added to `MarkdownLine.Kind` cannot be rendered unselectably by omission.
    /// Applied to the words and not to the row, because a selection that began by grabbing a bullet's dot would paste a character the reply never contained.
    /// The words sit on `SelectableText`, a read-only `UITextView`: `Text.textSelection` selects a whole run for Copy at best and raises nothing at all in this transcript on iOS 26.
    @ViewBuilder
    private func replyText(_ raw: String, font: HermesTextStyle, color: Color) -> some View {
        SelectableText(
            ColdOpenTrace.measureAccumulating("markdown.inline") { MarkdownParser.inline(raw) },
            style: font,
            color: color
        )
    }

    private func headingFont(_ level: Int) -> HermesTextStyle {
        switch level {
        case 1: return HermesFont.title
        case 2: return HermesFont.heading
        default: return HermesFont.calloutStrong
        }
    }
}

/// Fenced code: horizontally scrollable, never wrapping and never forcing the page to scroll sideways, with a copy button.
@MainActor
struct CodeBlockView: View {
    @Environment(\.hermes) private var t
    let language: String
    let code: String

    @State private var didCopy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(language.isEmpty ? "code" : language)
                    .font(HermesFont.caption)
                    .foregroundStyle(t.text3)
                Spacer()
                Button {
                    UIPasteboard.general.string = code
                    didCopy = true
                    HapticFeedback.selection()
                    Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 1_600_000_000)
                        didCopy = false
                    }
                } label: {
                    Label(didCopy ? "Copied" : "Copy", systemImage: didCopy ? "checkmark" : "doc.on.doc")
                        .font(HermesFont.footnote)
                        .labelStyle(.titleAndIcon)
                        .frame(minWidth: Hit.min, minHeight: Hit.min)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(t.text3)
                .accessibilityLabel("Copy code")
            }
            .padding(.horizontal, Space.s5)

            Rectangle().fill(t.stroke3).frame(height: 1)

            ScrollView(.horizontal, showsIndicators: true) {
                // BUG-058: `.textSelection(.enabled)` raises no callout at all inside this transcript on iOS 26, so a code fence's affordance is the Copy button above.
                Text(code)
                    .font(HermesFont.code)
                    .foregroundStyle(t.text1)
                    .padding(Space.s5)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(t.surface2)
        .clipShape(RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
    }
}

/// A GFM pipe table: flat, and horizontally scrollable so a wide table never drags the transcript sideways.
/// `Grid` rather than `LazyVGrid`, because columns have to size to their widest cell and the grid has to report one intrinsic width to the scroller.
/// It carries a Copy button for the reason a code fence does: a grid's cells are separate views by construction and cannot be dragged across the way prose can.
@MainActor
struct TableBlockView: View {
    @Environment(\.hermes) private var t
    let headers: [String]
    let alignments: [TableAlignment]
    let rows: [[String]]
    /// `nil` resolves to `text-1`, matching `MarkdownText`.
    var textColor: Color?

    @State private var didCopy = false

    var body: some View {
        let color = textColor ?? t.text1
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("table")
                    .font(HermesFont.caption)
                    .foregroundStyle(t.text3)
                Spacer()
                Button {
                    UIPasteboard.general.string = Self.markdown(
                        headers: headers,
                        alignments: alignments,
                        rows: rows
                    )
                    didCopy = true
                    HapticFeedback.selection()
                    Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 1_600_000_000)
                        didCopy = false
                    }
                } label: {
                    Label(didCopy ? "Copied" : "Copy", systemImage: didCopy ? "checkmark" : "doc.on.doc")
                        .font(HermesFont.footnote)
                        .labelStyle(.titleAndIcon)
                        .frame(minWidth: Hit.min, minHeight: Hit.min)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(t.text3)
                .accessibilityLabel("Copy table")
            }
            .padding(.horizontal, Space.s5)

            Rectangle().fill(t.stroke3).frame(height: 1)

            ScrollView(.horizontal, showsIndicators: true) {
                Grid(alignment: .topLeading, horizontalSpacing: Space.s5, verticalSpacing: Space.s3) {
                    GridRow {
                        ForEach(Array(headers.enumerated()), id: \.offset) { index, cell in
                            Text(MarkdownParser.inline(cell))
                                .font(HermesFont.calloutStrong)
                                .foregroundStyle(color)
                                .multilineTextAlignment(textAlignment(index))
                                .gridColumnAlignment(columnAlignment(index))
                                .accessibilityLabel("Column \(index + 1), \(cell)")
                        }
                    }

                    GridRow {
                        Rectangle()
                            .fill(t.stroke3)
                            .frame(height: 1)
                            .gridCellColumns(max(headers.count, 1))
                    }

                    ForEach(Array(rows.enumerated()), id: \.offset) { rowIndex, row in
                        GridRow {
                            ForEach(Array(row.enumerated()), id: \.offset) { index, cell in
                                // BUG-058: `.textSelection(.enabled)` raises nothing here, so the Copy button above is the affordance.
                                Text(MarkdownParser.inline(cell))
                                    .font(HermesFont.body)
                                    .foregroundStyle(color)
                                    .multilineTextAlignment(textAlignment(index))
                                    .accessibilityLabel(cellLabel(cell, column: index, row: rowIndex))
                            }
                        }
                    }
                }
                .padding(Space.s5)
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Table, \(headers.count) columns, \(rows.count) rows")
        }
        .background(t.surface2)
        .clipShape(RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
    }

    /// The table as the GFM the reply was written with, reconstructed from the parsed grid rather than carried through from the source. The difference is cosmetic and one-directional, and re-parsing this output yields the same table.
    static func markdown(headers: [String], alignments: [TableAlignment], rows: [[String]]) -> String {
        func line(_ cells: [String]) -> String {
            "| " + cells.joined(separator: " | ") + " |"
        }
        let separator = (0..<max(headers.count, 1)).map { index -> String in
            switch index < alignments.count ? alignments[index] : TableAlignment.none {
            case .left: return ":---"
            case .center: return ":---:"
            case .right: return "---:"
            case .none: return "---"
            }
        }
        return ([line(headers), line(separator)] + rows.map(line)).joined(separator: "\n")
    }

    /// VoiceOver reads a body cell as "header: value", because the column header is the only thing that tells a cell apart once the grid is linearised.
    private func cellLabel(_ cell: String, column: Int, row: Int) -> String {
        let value = cell.isEmpty ? "empty" : cell
        guard column < headers.count, !headers[column].isEmpty else {
            return "Row \(row + 1), \(value)"
        }
        return "\(headers[column]): \(value)"
    }

    private func alignment(_ index: Int) -> TableAlignment {
        index < alignments.count ? alignments[index] : TableAlignment.none
    }

    private func columnAlignment(_ index: Int) -> HorizontalAlignment {
        switch alignment(index) {
        case .center: return .center
        case .right: return .trailing
        case .left, .none: return .leading
        }
    }

    private func textAlignment(_ index: Int) -> TextAlignment {
        switch alignment(index) {
        case .center: return .center
        case .right: return .trailing
        case .left, .none: return .leading
        }
    }
}
