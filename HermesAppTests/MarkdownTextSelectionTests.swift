import HermesServeKit
import SwiftUI
import XCTest

@testable import HermesMobile

/// BUG-058 — the half of "text selection does not work on the phone" that source could settle.
///
/// Read this before concluding the bug is fixed. BUG-058 has two halves and this class is only one of them. The other half is a hand check on a device: drag across part of a reply and iOS's callout appears with Copy in it, in a session thread and in a bot thread. No test in this repository has ever observed an iOS selection callout and none here does — the app-hosted suite cannot see system UI at all, and XCUITest reports it unreliably. That is exactly how BUG-044 came to be closed on green tests while the defect was still on the device, so do not start by re-running green tests and concluding the bug is absent.
///
/// What *was* settleable from source is a real, independent defect: four of the six line kinds a reply is built from could not raise a callout **by construction**, because `.textSelection(.enabled)` was applied to paragraphs, fenced code and table cells and to nothing else. A heading, a bullet, a numbered step and a block quote had no modifier to defeat. That is what these tests are about.
///
/// The report's own audit found three of the four. The heading case was missed by it and found here.
@MainActor
final class MarkdownTextSelectionTests: XCTestCase {

    /// **The tripwire, and it fires at compile time rather than at run time.**
    ///
    /// This switch is exhaustive over `MarkdownLine.Kind`. Adding a case to that enum stops this file compiling, which puts whoever adds it in front of the one question the original defect was an unnoticed answer to: does this new line carry a reply's words, and is it therefore selectable?
    ///
    /// A run-time assertion would not do. The failure being guarded against is *omission* — a renderer that reads perfectly well on its own and is only wrong beside its neighbours — and there is no value to inspect at run time that reveals an absent view modifier.
    private func classification(of kind: MarkdownLine.Kind) -> (name: String, carriesWords: Bool) {
        switch kind {
        case .paragraph: return ("paragraph", true)
        case .heading: return ("heading", true)
        case .bullet: return ("bullet", true)
        case .ordered: return ("ordered", true)
        case .quote: return ("quote", true)
        // The only kind with nothing to select: a horizontal rule is a
        // `Rectangle`, not words.
        case .rule: return ("rule", false)
        }
    }

    private let everyKind: [MarkdownLine.Kind] = [
        .paragraph,
        .heading(level: 2),
        .bullet(depth: 0),
        .ordered(depth: 0, marker: "1."),
        .quote,
        .rule,
    ]

    /// Five of the six line kinds carry prose, and all five go through the one constructor that applies the modifier. Stated as a count so a kind added to the enum *and* to `everyKind` without a decision still fails here rather than passing quietly.
    func testEveryLineKindThatCarriesWordsIsAccountedFor() {
        let carrying = everyKind.filter { classification(of: $0).carriesWords }
        XCTAssertEqual(carrying.count, 5,
                       "five kinds draw a reply's words; if this moved, a renderer was added or removed and the selection question needs answering for it")
        XCTAssertEqual(everyKind.count, 6,
                       "MarkdownLine.Kind has six cases — if a seventh exists, add it to everyKind and decide whether it is selectable")

        let names = Set(everyKind.map { classification(of: $0).name })
        XCTAssertEqual(names.count, everyKind.count, "two kinds classified under one name")
    }

    // MARK: The parse, so the mapping from real markdown to those kinds is pinned

    /// The four kinds that were unselectable, produced from the markdown a real reply contains. Without this the tripwire above would be guarding an enum nobody proves the parser reaches.
    func testARealReplyProducesTheFourKindsThatCouldNotBeSelected() throws {
        let source = """
        ## A heading

        - a bullet

        1. a numbered step

        > a quotation
        """
        let blocks = MarkdownParser.blocks(from: source)
        let lines = blocks.flatMap { block -> [MarkdownLine] in
            if case .prose(_, let lines) = block { return lines }
            return []
        }

        let kinds = lines.map { classification(of: $0.kind).name }
        XCTAssertTrue(kinds.contains("heading"), "the parser did not produce a heading — got \(kinds)")
        XCTAssertTrue(kinds.contains("bullet"), "the parser did not produce a bullet — got \(kinds)")
        XCTAssertTrue(kinds.contains("ordered"), "the parser did not produce an ordered line — got \(kinds)")
        XCTAssertTrue(kinds.contains("quote"), "the parser did not produce a quote — got \(kinds)")

        // A heading, a bullet, an ordered step and a quote are never empty:
        // each is recognised by a marker that must be followed by something.
        //
        // A **paragraph** can be, and legitimately is — a blank line between
        // two blocks classifies as an empty `.paragraph`, and the renderer
        // draws it as a `Spacer` rather than as text. That is not an exception
        // to the rule this file is about; it is the one line kind that
        // sometimes carries no words, and `replyText` is never reached for it.
        // Asserted rather than skipped, because a *non*-empty paragraph
        // arriving as empty would be a real parser defect.
        for line in lines where classification(of: line.kind).name != "paragraph" {
            XCTAssertFalse(line.text.isEmpty || line.text.allSatisfy(\.isWhitespace),
                           "a \(classification(of: line.kind).name) reached the renderer with no words in it")
        }
        let paragraphs = lines.filter { classification(of: $0.kind).name == "paragraph" }
        XCTAssertTrue(paragraphs.allSatisfy { $0.text.isEmpty || $0.text.allSatisfy(\.isWhitespace) },
                      "this fixture's only paragraphs are the blank lines between blocks — a paragraph with words in it means the fixture changed and the assertion above should cover it")
    }

    /// The markers are not part of the words. A bullet's dot, a step's number and a quote's rule are decoration drawn beside the text, and the parser strips them — which is what makes it correct to apply the modifier to the text alone. A selection that could begin on "•" would paste a character the reply never contained.
    func testTheMarkersAreNotPartOfTheSelectableText() throws {
        let blocks = MarkdownParser.blocks(from: "- a bullet\n\n1. a numbered step\n\n> a quotation")
        let lines = blocks.flatMap { block -> [MarkdownLine] in
            if case .prose(_, let lines) = block { return lines }
            return []
        }

        for line in lines {
            XCTAssertFalse(line.text.hasPrefix("- "), "the bullet's marker survived into the text")
            XCTAssertFalse(line.text.hasPrefix("• "), "the rendered dot is in the text")
            XCTAssertFalse(line.text.hasPrefix("> "), "the quote's marker survived into the text")
            XCTAssertFalse(line.text.hasPrefix("1. "), "the step's number survived into the text")
        }
    }

    /// A heading keeps its words after inline parsing. The heading case is the one the report's own audit missed, so it earns its own assertion rather than riding along with the other three.
    func testAHeadingKeepsItsWords() throws {
        let blocks = MarkdownParser.blocks(from: "### Two notes on what this contains")
        let lines = blocks.flatMap { block -> [MarkdownLine] in
            if case .prose(_, let lines) = block { return lines }
            return []
        }
        let heading = try XCTUnwrap(lines.first { classification(of: $0.kind).name == "heading" })
        XCTAssertEqual(heading.text, "Two notes on what this contains")
        XCTAssertFalse(heading.text.hasPrefix("#"), "the hashes survived into the text")
    }
}
