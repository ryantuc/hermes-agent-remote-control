import HermesServeKit
import SwiftUI
import UIKit
import XCTest

@testable import HermesMobile

/// BUG-124, second pass — the fix shipped and a check on a device still failed on three counts.
///
/// The three, as reported: (1) dragging from the first bulleted item across the rest works and pastes `- `, but the first bullet itself cannot be selected; (2) a numbered list cannot be selected beyond one item, and the same holds for bold paragraphs that read as a numbered list; (3) the lead-in sentence above a list cannot be selected. The behaviour asked for is one drag from a heading all the way to the closing paragraph of the same message.
///
/// Every assertion here runs on two real replies rather than on a fixture written to make a renderer look good. That is exactly why the first pass shipped believing lists were fixed: the shapes that broke are a heading directly above a list, and a "numbered list" that is really bold paragraphs separated by blank lines, and this repository's invented fixtures had neither.
///
/// These were written and run before the fix, so the red they produced is the reproduction.
@MainActor
final class ProseSpanTests: XCTestCase {
    private static let tokens = HermesTokens(skin: .nousDark, polarity: .dark)

    // MARK: Probes

    private func window<V: View>(_ view: V, width: CGFloat) -> (UIWindow, UIHostingController<AnyView>) {
        let root = view.environment(\.hermes, Self.tokens)
        let host = UIHostingController(rootView: AnyView(root))
        host.safeAreaRegions = []
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: width, height: 40_000))
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

    /// The text views a whole reply mints, in the order they were found.
    private func render(_ source: String) -> (UIWindow, [UITextView]) {
        let (window, host) = self.window(MarkdownText(text: source).frame(width: 402), width: 402)
        return (window, textViews(under: host.view))
    }

    private func lines(_ source: String) -> [MarkdownLine] {
        MarkdownParser.blocks(from: source).flatMap { block -> [MarkdownLine] in
            if case .prose(_, let lines) = block { return lines }
            return []
        }
    }

    // MARK: Issue 3 — a lead-in heading cannot join the list under it

    /// Issue 3, as reported: the lead-in sentence above a list cannot be selected together with the list.
    ///
    /// `### Blind spots I missed` is a heading line and the five items under it are ordered lines with no blank line anywhere between them. One drag has to cover both.
    func testIssue3TheLeadInHeadingAndTheListUnderItAreOneSelection() {
        let (window, views) = render(OperatorSampleFixtures.architectureReview)
        defer { window.isHidden = true }
        guard let lead = views.first(where: { ($0.text ?? "").contains("Blind spots I missed") }) else {
            return XCTFail("no text view carries the lead-in heading at all — got \(views.count) views")
        }
        let text = lead.text ?? ""
        XCTAssertTrue(text.contains("Shop standard is LazyVStack"), "the heading \"Blind spots I missed\" is in a text view that does not contain the first item of the list beneath it, so a drag cannot run from one into the other")
        XCTAssertTrue(text.contains("Process-wide memory"), "the heading and the list's first item share a view but its last item does not, so the drag still stops inside the list")
    }

    // MARK: Issue 2 — the "numbered list" that is really paragraphs

    /// Issue 2, as reported: a selection inside a numbered list cannot go beyond one item, and the two closing paragraphs cannot be taken together with the stories above them.
    ///
    /// The shape is the whole finding: `**1. Northwind announces…**` is not an ordered line — `MarkdownParser.classify` needs a bare integer before the dot and `**1` is not one — so these are ten paragraphs, each separated from the next by a blank line. What broke is not lists. It is that a blank line ended a run.
    func testIssue2TheNewsDigestsBoldNumberedParagraphsAreOneSelection() {
        let (window, views) = render(OperatorSampleFixtures.newsDigest)
        defer { window.isHidden = true }
        guard let first = views.first(where: { ($0.text ?? "").contains("Northwind announces") }) else {
            return XCTFail("no text view carries the first story — got \(views.count) views")
        }
        let text = first.text ?? ""
        XCTAssertTrue(text.contains("Cascade–Ridge flash floods"), "story 1 and story 2 are in different text views, so a selection cannot go beyond one of them, and the cause is the blank line between them")
        XCTAssertTrue(text.contains("Also noted:") && text.contains("Verification & method:"), "the two closing paragraphs are not in the same view as the stories above them")
    }

    /// The control, and it is the half of issue 2 that was never broken. The architecture reply carries a true ordered list — five `1.`…`5.` lines with no blank line between them — and the first pass already merged those into one run. Asserted so the diagnosis is not a guess: what failed was the blank-line shape, not the ordered-line shape.
    func testATrueOrderedListWasAlreadyOneRunBeforeThisChange() {
        let ordered = ProseRunBuilder.runs(from: lines(OperatorSampleFixtures.architectureReview))
            .compactMap { run -> Int? in
                if case .list(let items) = run.content { return items.count }
                return nil
            }
        XCTAssertTrue(ordered.contains(5), "the five-item ordered list under \"Blind spots I missed\" did not come out as one run of five — got run sizes \(ordered). If this fails, the run builder is broken for ordered lines and the report's issue-2 diagnosis is wrong")
    }

    // MARK: Issue 1 — the first bullet's marker

    /// Issue 1, as reported: the first bullet cannot be selected.
    ///
    /// Two facts, and only the second is fixable here. The marker is on the text view — that is what the first pass shipped, and pasting proves it, because the paste carries `- `. But when a bulleted list starts a text view its first marker sits at character zero, and a long press cannot anchor a selection before the first character. Once a run spans the prose above the list, the list is no longer at character zero and a drag that starts above it carries the marker with it.
    func testIssue1TheFirstBulletIsNoLongerAtCharacterZeroOfItsView() {
        let (window, views) = render(OperatorSampleFixtures.architectureReview)
        defer { window.isHidden = true }
        guard let bulleted = views.first(where: { ($0.text ?? "").contains("Citations:") }) else {
            return XCTFail("no text view carries the bulleted list — got \(views.count) views")
        }
        let text = bulleted.text ?? ""
        XCTAssertFalse(text.hasPrefix("•"), "the bulleted list still begins its own text view, so its first marker is at character zero and there is nothing above it a drag can start from")
        XCTAssertTrue(text.contains("What survived"), "the heading above the bulleted list is not in the same view, so a drag cannot begin above the first bullet")
    }

    /// The hypothesis this refutes, kept because refuting it is the finding.
    ///
    /// The obvious explanation for "the first bullet cannot be selected" is word granularity: iOS selects whole words on a long press, and a dot followed by a tab looked like the kind of thing a tokenizer would skip past. It does not. Asked for the word enclosing character zero of a run that begins `•\t`, `UITextView`'s own tokenizer answers offset 0 — the marker anchors a word perfectly well, as printed below.
    ///
    /// So the cause is not the text. It is where the press begins: pressing and holding on the words puts the anchor after the marker, and the marker itself is a glyph roughly seven points wide at the very left edge of the row — a poor target to hit deliberately. The fix is therefore not to make the marker easier to grab but to make it unnecessary to grab: once a span runs through the prose above the list, a drag that starts anywhere above carries every marker below it.
    ///
    /// Asserted as the measurement rather than as the hypothesis, so nobody re-derives the wrong cause from this file.
    func testTheTokenizerAnchorsAWordOnTheMarkerSoGranularityIsNotWhyItCannotBeSelected() throws {
        let (window, views) = render("- a bullet\n- another bullet")
        defer { window.isHidden = true }
        let view = try XCTUnwrap(views.first)
        XCTAssertTrue((view.text ?? "").hasPrefix("•"), "this probe needs a run that starts with a marker")

        let start = view.beginningOfDocument
        let forward = view.tokenizer.rangeEnclosingPosition(start, with: .word, inDirection: .storage(.forward))
        let offset = forward.map { view.offset(from: view.beginningOfDocument, to: $0.start) }
        print("[bug-124] word range at character zero: \(String(describing: offset))")
        XCTAssertEqual(offset, 0, "the tokenizer no longer anchors a word on the marker. That would make word granularity a real candidate cause for issue 1 after all, and the diagnosis above would need reopening")
    }

    // MARK: The behaviour asked for

    /// The behaviour asked for is one drag from the heading "Pressure-test outcome" to the closing "Bottom line:" paragraph of the same message.
    ///
    /// Not reachable in one text view, and the reason is structural rather than a decision anyone can reverse: between those two sentences the reply contains a table and a fenced code block, and each owns its own horizontal scroller and its own layout. What is reachable is everything either side of them, which is what this pins.
    func testTheWholeProseOfTheReplyIsThreeSelectionsBrokenOnlyByTheTableAndTheFence() {
        let (window, views) = render(OperatorSampleFixtures.architectureReview)
        defer { window.isHidden = true }
        print("[bug-124] architecture reply: \(views.count) text views")
        XCTAssertEqual(views.count, 3, "the architecture reply came out as \(views.count) text views. Three is the answer the structure allows: everything before the table, everything between the table and the fence, and the closing paragraph after it")
        guard let first = views.first, let last = views.last else { return XCTFail("nothing rendered") }
        XCTAssertTrue((first.text ?? "").contains("Pressure-test outcome"))
        XCTAssertTrue((first.text ?? "").contains("Citations:"), "the first span should reach the bulleted list")
        XCTAssertTrue((last.text ?? "").contains("Bottom line:"))
    }
}
