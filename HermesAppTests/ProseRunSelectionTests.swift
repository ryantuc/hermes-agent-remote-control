import HermesServeKit
import SwiftUI
import UIKit
import XCTest

@testable import HermesMobile

/// BUG-124 — selecting text inside a list took one line at a time.
///
/// The unit of selection used to be one *source line*: `MarkdownParser.classify` splits on `"\n"` and `ProseView` rendered one `SelectableText` — one `UITextView` — per line. So a drag stopped at every newline the model emitted, a list could only be taken one item at a time, and the bullet the reader tried to start the drag on was a SwiftUI `Text` beside the words with no selection of any kind.
///
/// A run is now one text view. These pin the three things that can go wrong with that: **what groups** (the run builder is a pure function and is asserted as one), **what the reader can drag across** (how many text views a reply mints and what is in them), and **what reaches the clipboard** (the marker the reply was written with, not the dot that was drawn for it).
///
/// What this file cannot see, and it is the same limit `SelectableTextTests` records: no app-hosted test has ever observed iOS's loupe, its drag handles or its Copy / Select All / Look Up callout. Green here is "the drag has one text view to run across and copy substitutes the source marker", not "a reader dragged across a list on a device"; that half is only checkable by hand on a device.
@MainActor
final class ProseRunSelectionTests: XCTestCase {
    private static let tokens = HermesTokens(skin: .nousDark, polarity: .dark)

    // MARK: Probes

    private func lines(_ source: String) -> [MarkdownLine] {
        MarkdownParser.blocks(from: source).flatMap { block -> [MarkdownLine] in
            if case .prose(_, let lines) = block { return lines }
            return []
        }
    }

    private func runs(_ source: String) -> [ProseRun] {
        ProseRunBuilder.runs(from: lines(source))
    }

    /// A run's shape, named, so a failure says which grouping went wrong rather
    /// than printing a wall of `MarkdownLine`s.
    private func shape(_ run: ProseRun) -> String {
        switch run.content {
        case .rule: return "rule"
        case .gap: return "gap"
        case .heading(let level, _): return "heading\(level)"
        case .paragraphs(let lines): return "paragraphs(\(lines.count))"
        case .list(let lines): return "list(\(lines.count))"
        case .quote(let lines): return "quote(\(lines.count))"
        }
    }

    private func shapes(_ source: String) -> [String] {
        runs(source).map(shape)
    }

    private func window<V: View>(_ view: V, width: CGFloat) -> (UIWindow, UIHostingController<AnyView>) {
        let root = view.environment(\.hermes, Self.tokens)
        let host = UIHostingController(rootView: AnyView(root))
        host.safeAreaRegions = []
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: width, height: 1600))
        window.rootViewController = host
        window.makeKeyAndVisible()
        window.layoutIfNeeded()
        host.view.layoutIfNeeded()
        return (window, host)
    }

    private func textViews(under view: UIView) -> [UITextView] {
        var found: [UITextView] = []
        if let textView = view as? UITextView { found.append(textView) }
        for subview in view.subviews { found += textViews(under: subview) }
        return found
    }

    // MARK: 1 — what groups, and what breaks a group

    /// The reported symptom at the level of the data structure: four consecutive bullets are one thing to drag across, not four.
    func testConsecutiveListItemsAreOneRun() {
        XCTAssertEqual(shapes("- one\n- two\n- three\n- four"), ["list(4)"])
    }

    /// A model that writes a paragraph over two source lines wrote one
    /// paragraph. This is the half of the bug that is invisible in the report's
    /// wording — "a drag stops at a block boundary" understates it, because the
    /// boundary was every newline.
    func testConsecutiveParagraphLinesAreOneRun() {
        XCTAssertEqual(shapes("The first thing to know is X.\nThe second thing is Y."), ["paragraphs(2)"])
    }

    func testConsecutiveQuoteLinesAreOneRun() {
        XCTAssertEqual(shapes("> first\n> second"), ["quote(2)"])
    }

    /// Bullets and numbered steps at different depths still share a run: each
    /// item carries its own indent and its own marker in the paragraph style,
    /// so nothing is gained by cutting the run and a drag would stop for no
    /// reason the reader can see.
    func testAListRunSurvivesAChangeOfDepthOrMarkerKind() {
        XCTAssertEqual(shapes("- one\n  - nested\n1. a step\n2. another step"), ["list(4)"])
    }

    /// **The constraint that keeps `SelectableTextTests`' count of five true.**
    /// A blank line is a paragraph break the author wrote, not a wrap, and it
    /// still draws `Space.s2` of air.
    func testABlankLineEndsARun() {
        XCTAssertEqual(shapes("first\n\nsecond"), ["paragraphs(1)", "gap", "paragraphs(1)"])
        XCTAssertEqual(shapes("- one\n\n- two"), ["list(1)", "gap", "list(1)"])
    }

    /// Structure that owns its own layout terminates a run: a heading has its
    /// own rung and its own top padding, a rule is a `Rectangle`.
    func testHeadingsAndRulesEndARun() {
        XCTAssertEqual(
            shapes("before\n## A heading\nafter\n---\nlast"),
            ["paragraphs(1)", "heading2", "paragraphs(1)", "rule", "paragraphs(1)"]
        )
    }

    /// A table and a fenced code block are separate `MarkdownBlock`s and never
    /// reach the run builder at all, so prose either side of one is two runs by
    /// construction. Asserted because "what breaks a run" is only half in the
    /// builder.
    func testATableSplitsTheProseAroundItIntoSeparateBlocks() {
        let blocks = MarkdownParser.blocks(from: "before\n| a | b |\n| --- | --- |\n| 1 | 2 |\nafter")
        let kinds = blocks.map { block -> String in
            switch block {
            case .prose: return "prose"
            case .code: return "code"
            case .table: return "table"
            }
        }
        XCTAssertEqual(kinds, ["prose", "table", "prose"])
    }

    // MARK: 2 — how many text views a reply mints

    /// **The cost half of BUG-124, and the reason BUG-123 should know about it.**
    /// Six lines of words used to be six `UITextView`s and six
    /// `UIViewRepresentable` hosts; they are two now.
    func testAReplyMintsOneTextViewPerRunRatherThanOnePerLine() {
        let source = """
        Two lines of one paragraph, wrapped by the model rather than by the phone.
        The second line, which used to be a text view of its own.

        - one
        - two
        - three
        - four
        """
        let before = lines(source).filter { line in
            if case .paragraph = line.kind { return !line.text.isEmpty }
            if case .rule = line.kind { return false }
            return true
        }.count
        let (window, host) = self.window(MarkdownText(text: source).frame(width: 402), width: 402)
        defer { window.isHidden = true }
        let views = textViews(under: host.view)

        XCTAssertEqual(before, 6, "the fixture should carry six lines of words; got \(before)")
        XCTAssertEqual(views.count, 1, """
            \(before) lines of words came out as \(views.count) text views. A blank line no longer \
            ends a span, so the paragraph pair and the four bullets under it are one thing to drag \
            across, which is what BUG-124 reported was impossible
            """)
    }

    /// **What the `transcript-long` fixture actually costs, measured rather than assumed.**
    ///
    /// It is tempting to assume one text box per list run also cuts this fixture's element count, and for this fixture it does not: `seedLongDemoTranscript`'s answer rows are eight paragraphs joined by blank lines, and a blank line ends a run, so nine word-carrying lines are still nine runs and nine text views. The saving is real and it is on replies with lists or with hard-wrapped prose, which this fixture has none of.
    func testTheLongTranscriptFixtureRowIsUnchangedByTheRunMerge() {
        let wall = (1...8)
            .map { "Paragraph \($0) of a long answer that wraps several times on a phone width." }
            .joined(separator: "\n\n")
        let source = "transcript row 5 — answer 3\n\n\(wall)"
        let carrying = runs(source).filter(\.carriesWords).count
        let spans = ProseSpanBuilder.spans(from: lines(source)).filter(\.carriesWords).count
        // The nine runs are still nine — the classifier did not change — but they are one span now, so this fixture's row count does fall after all, for a different reason than the run merge.
        XCTAssertEqual(spans, 1, "the fixture's nine blank-line-separated paragraphs are " +
                       "\(spans) spans; a blank line no longer ends one")
        XCTAssertEqual(carrying, 9, """
            the transcript-long answer row is \(carrying) word-carrying runs. Nine is the expected \
            number and the expected NON-saving: every paragraph in that fixture is separated by a \
            blank line, so there is nothing contiguous to merge
            """)
    }

    /// The whole renderer, counted: `-hermesScreenshotRoute markdown` draws this reply, so counting its text views is the screenshot in numbers.
    ///
    /// The invariant is asserted rather than a hand-computed total — one text view per word-carrying run, with both sides derived from the parse — so the assertion cannot drift with the fixture.
    func testTheShowcaseFixtureMintsOneTextViewPerRun() {
        // The expectation is derived from spans rather than runs: the invariant is unchanged and still self-checking — one text view per thing a drag can cross — but the thing a drag can cross is now a span, and the fixture's six runs are two of them.
        let source = ChatModel.markdownShowcase
        let blocks = MarkdownParser.blocks(from: source)
        let proseLines = blocks.flatMap { block -> [MarkdownLine] in
            if case .prose(_, let lines) = block { return lines }
            return []
        }
        let before = proseLines.filter { line in
            if case .paragraph = line.kind { return !line.text.isEmpty }
            if case .rule = line.kind { return false }
            return true
        }.count
        let expected = blocks.flatMap { block -> [ProseSpan] in
            if case .prose(_, let lines) = block { return ProseSpanBuilder.spans(from: lines) }
            return []
        }.filter(\.carriesWords).count

        let (window, host) = self.window(MarkdownText(text: source).frame(width: 402), width: 402)
        defer { window.isHidden = true }
        let views = textViews(under: host.view)

        print("[bug-124] showcase fixture: \(before) word-carrying source lines -> \(views.count) text views (\(expected) runs)")
        XCTAssertEqual(views.count, expected, "the fixture has \(expected) word-carrying spans and hosted \(views.count) text views. One view per span is the whole of the fix; anything else means a span is being split or two spans are being merged")
        XCTAssertLessThan(views.count, before, "\(before) lines of words came out as \(views.count) text views, which is no saving at all — on a fixture that deliberately contains a four-item list, a three-step list and a paragraph the model wrapped itself")
        // A code fence and a table are `Text`, not `SelectableText`, and must
        // not have started minting text views of their own.
        XCTAssertFalse(views.contains { ($0.text ?? "").contains("let answer = 42") },
                       "the fenced code is on a selectable text view; it is a `Text` in a horizontal scroller")
        XCTAssertFalse(views.contains { ($0.text ?? "").contains("your machine") },
                       "a table cell is on a selectable text view; the grid's cells are `Text`s")
    }

    // MARK: 3 — what reaches the clipboard

    /// Hosts one prose run and hands back the window with it, so the caller
    /// can `defer` the teardown rather than capturing a `UIWindow` in an
    /// escaping teardown block.
    private func hostedRun(_ source: String) throws -> (UIWindow, UITextView) {
        let (window, host) = self.window(MarkdownText(text: source).frame(width: 402), width: 402)
        let first = try XCTUnwrap(textViews(under: host.view).first, "nothing was hosted for \(source)")
        return (window, first)
    }

    /// **The assertion the old rule could not make.** "Do not put the marker on
    /// the text view" was a proxy for "do not paste a character the reply never
    /// contained"; this asserts the thing itself.
    func testASelectionSpanningTwoBulletsCopiesTheSourceMarkers() throws {
        let (window, view) = try hostedRun("- a bullet\n- another bullet")
        defer { window.isHidden = true }
        let drawn = (view.text ?? "") as NSString
        XCTAssertEqual(drawn as String, "•\ta bullet\n•\tanother bullet",
                       "the run is not drawn as one dot-and-tab per item")

        // From the first word of item one to the end of item two: a drag that
        // begins inside the words and crosses an item boundary, which is the
        // gesture in the report.
        let start = drawn.range(of: "a bullet").location
        UIPasteboard.general.string = ""
        view.selectedRange = NSRange(location: start, length: drawn.length - start)
        view.copy(nil)
        XCTAssertEqual(UIPasteboard.general.string, "a bullet\n- another bullet", """
            a selection that crosses a bullet boundary put "\(UIPasteboard.general.string ?? "")" on \
            the clipboard. The drawn dot must become the "- " the reply was written with
            """)
    }

    /// A numbered list never needed the substitution — a reply that says "1."
    /// contains "1." — but it goes through the same path, so it is asserted the
    /// same way.
    func testANumberedListCopiesItsNumbers() throws {
        let (window, view) = try hostedRun("1. first step\n2. second step")
        defer { window.isHidden = true }
        let drawn = (view.text ?? "") as NSString
        UIPasteboard.general.string = ""
        view.selectedRange = NSRange(location: 0, length: drawn.length)
        view.copy(nil)
        XCTAssertEqual(UIPasteboard.general.string, "1. first step\n2. second step")
    }

    /// A nested item pastes with the indent its depth came from, so the
    /// clipboard is markdown a reader can paste back into a reply.
    func testANestedBulletCopiesWithItsIndent() throws {
        let (window, view) = try hostedRun("- one\n  - nested")
        defer { window.isHidden = true }
        let drawn = (view.text ?? "") as NSString
        UIPasteboard.general.string = ""
        view.selectedRange = NSRange(location: 0, length: drawn.length)
        view.copy(nil)
        XCTAssertEqual(UIPasteboard.general.string, "- one\n  - nested")
    }

    /// A run with no markers has nothing to substitute and must come back
    /// character for character. Asserted so the interception cannot quietly
    /// start rewriting ordinary prose — and because a paragraph run is where
    /// the merge is otherwise invisible: two source lines, one text view, one
    /// newline on the clipboard exactly as the reply had it.
    func testAParagraphRunCopiesItselfUnchanged() throws {
        let (window, view) = try hostedRun("The first thing to know is X.\nThe second thing is Y.")
        defer { window.isHidden = true }
        XCTAssertEqual(view.text, "The first thing to know is X.\nThe second thing is Y.")
        UIPasteboard.general.string = ""
        view.selectedRange = NSRange(location: 0, length: ((view.text ?? "") as NSString).length)
        view.copy(nil)
        XCTAssertEqual(UIPasteboard.general.string, "The first thing to know is X.\nThe second thing is Y.")
    }

    // MARK: 4 — the table's copy affordance

    /// A table gets a copy button like a code block does. What that button copies has to be markdown, and the property worth asserting is not the exact spacing but that re-parsing it yields the same table.
    func testTheTableCopiesMarkdownThatParsesBackToTheSameTable() {
        let source = "| Name | Role | Count |\n| :--- | :---: | ---: |\n| Hermes | agent | 3 |\n| Iris | design | 1 |"
        guard case .table(_, let headers, let alignments, let rows)? = MarkdownParser.blocks(from: source).first else {
            return XCTFail("the fixture did not parse as a table")
        }
        let copied = TableBlockView.markdown(headers: headers, alignments: alignments, rows: rows)
        XCTAssertEqual(copied, "| Name | Role | Count |\n| :--- | :---: | ---: |\n| Hermes | agent | 3 |\n| Iris | design | 1 |")

        guard case .table(_, let headers2, let alignments2, let rows2)? = MarkdownParser.blocks(from: copied).first else {
            return XCTFail("what the button copies does not parse back as a table: \(copied)")
        }
        XCTAssertEqual(headers2, headers)
        XCTAssertEqual(alignments2, alignments)
        XCTAssertEqual(rows2, rows)
    }

    // MARK: 5 — the two surfaces reported separately

    /// "Turn errors should be selectable." They carried the inert
    /// `.textSelection(.enabled)`; the message is on a real text view now.
    func testTheTurnErrorMessageIsOnASelectableTextView() {
        let message = "The backend closed the connection while the turn was running."
        let (window, host) = self.window(TurnError(message: message).frame(width: 402), width: 402)
        defer { window.isHidden = true }
        let views = textViews(under: host.view)
        guard let view = views.first(where: { ($0.text ?? "") == message }) else {
            return XCTFail("the error message is not on a text view — got \(views.map { $0.text ?? "" })")
        }
        XCTAssertTrue(view.isSelectable)
        XCTAssertFalse(view.isEditable, "an editable error message would raise the keyboard on a long press")
    }

    /// "Thinking traces when expanded should also be selectable." `.full` is the
    /// mode that opens the trace without a tap, which is the only way to reach
    /// the expanded branch from a hosted test.
    func testTheExpandedReasoningTraceIsOnASelectableTextView() {
        let key = "hermes.reasoning.mode"
        let previous = UserDefaults.standard.string(forKey: key)
        UserDefaults.standard.set("full", forKey: key)
        defer {
            if let previous {
                UserDefaults.standard.set(previous, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }

        let trace = "First I checked the ledger, then I read the branch, and only then did I answer."
        let root = ReasoningBlock(text: trace, isStreaming: false, duration: 4)
        let (window, host) = self.window(root.frame(width: 402), width: 402)
        defer { window.isHidden = true }
        let views = textViews(under: host.view)
        guard let view = views.first(where: { ($0.text ?? "") == trace }) else {
            return XCTFail("the expanded trace is not on a text view — got \(views.map { $0.text ?? "" })")
        }
        XCTAssertTrue(view.isSelectable)
        XCTAssertFalse(view.isScrollEnabled, "the trace's own scroller owns the pan; a scrolling text view inside it would fight for it")
    }
}
