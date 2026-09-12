import XCTest

@testable import HermesMobile

/// BUG-022 — GFM pipe tables reached the transcript as raw pipe text. The block
/// parser had no table case, so every `| a | b |` row fell through to
/// `.paragraph` and the `|---|---|` separator stayed on screen as a stray line.
///
/// These pin the recogniser rather than the view: `MarkdownParser.blocks(from:)`
/// is a pure function, needs no harness and no socket, and the view is reached
/// through an exhaustive `switch` that cannot compile while a `.table` block has
/// nowhere to go.
final class MarkdownTableTests: XCTestCase {

    // MARK: - Helpers

    /// Builds a source string with explicit `\n` separators so the assertion is
    /// about what the parser receives, not about how this file is stored.
    private func md(_ lines: String...) -> String {
        lines.joined(separator: "\n")
    }

    private func tableParts(
        _ block: MarkdownBlock?
    ) -> (headers: [String], alignments: [TableAlignment], rows: [[String]])? {
        guard case .table(_, let headers, let alignments, let rows)? = block else { return nil }
        return (headers, alignments, rows)
    }

    private func proseText(_ block: MarkdownBlock?) -> [String]? {
        guard case .prose(_, let lines)? = block else { return nil }
        return lines.map(\.text)
    }

    private func allProseText(_ blocks: [MarkdownBlock]) -> [String] {
        blocks.flatMap { block -> [String] in
            if case .prose(_, let lines) = block { return lines.map(\.text) }
            return []
        }
    }

    // MARK: - The reported bug

    func testGFMTableBecomesATableBlockAndAbsorbsTheSeparator() {
        let source = md(
            "| Name | Role |",
            "| --- | --- |",
            "| Hermes | agent |"
        )

        let blocks = MarkdownParser.blocks(from: source)

        XCTAssertEqual(blocks.count, 1, "a bare table is one block, not three paragraphs (got \(blocks))")
        guard let table = tableParts(blocks.first) else {
            return XCTFail("expected a .table block, got \(String(describing: blocks.first))")
        }
        XCTAssertEqual(table.headers, ["Name", "Role"])
        XCTAssertEqual(table.rows, [["Hermes", "agent"]])
        XCTAssertEqual(table.alignments, [.none, .none])

        let leftovers = allProseText(blocks)
        XCTAssertFalse(
            leftovers.contains { $0.contains("---") },
            "the separator row is table syntax and must be absorbed, not rendered (leftovers=\(leftovers))"
        )
        XCTAssertFalse(
            leftovers.contains { $0.contains("|") },
            "no pipe row may survive as prose (leftovers=\(leftovers))"
        )
    }

    // MARK: - Things that must NOT become tables

    func testParagraphContainingALonePipeIsNotATable() {
        let text = "Pipe the output | into less, then read it."

        let blocks = MarkdownParser.blocks(from: text)

        XCTAssertEqual(blocks.count, 1)
        XCTAssertNil(tableParts(blocks.first), "one stray pipe in a sentence is not a table")
        XCTAssertEqual(proseText(blocks.first), [text])
    }

    func testHeaderRowWithoutItsSeparatorStaysProseWhileStreaming() {
        // The first tokens of a streamed table. Promoting here would flash a
        // one-row grid and then reflow when the separator lands.
        let blocks = MarkdownParser.blocks(from: "| Name | Role |")

        XCTAssertEqual(blocks.count, 1)
        XCTAssertNil(tableParts(blocks.first), "a header row alone is not yet a table")
        XCTAssertEqual(proseText(blocks.first), ["| Name | Role |"])
    }

    func testPipeRowsWithNoSeparatorAtAllStayProse() {
        let blocks = MarkdownParser.blocks(from: md("| Name | Role |", "| Hermes | agent |"))

        XCTAssertEqual(blocks.count, 1)
        XCTAssertNil(tableParts(blocks.first), "pipe rows without a separator row are not a table")
    }

    func testSeparatorRowOnItsOwnIsNotATable() {
        let blocks = MarkdownParser.blocks(from: "| --- | --- |")

        XCTAssertEqual(blocks.count, 1)
        XCTAssertNil(tableParts(blocks.first))
    }

    func testPipeRowsInsideAFencedBlockStayCode() {
        let source = md(
            "```",
            "| Name | Role |",
            "| --- | --- |",
            "| Hermes | agent |",
            "```"
        )

        let blocks = MarkdownParser.blocks(from: source)

        XCTAssertEqual(blocks.count, 1)
        guard case .code(_, _, let content)? = blocks.first else {
            return XCTFail("expected a .code block, got \(String(describing: blocks.first))")
        }
        XCTAssertTrue(content.contains("| --- | --- |"), "the fence keeps its pipes verbatim (content=\(content))")
    }

    // MARK: - Shape

    func testSeparatorColonsRecordColumnAlignment() {
        let source = md(
            "| L | C | R | D |",
            "| :--- | :---: | ---: | --- |",
            "| 1 | 2 | 3 | 4 |"
        )

        let blocks = MarkdownParser.blocks(from: source)

        guard let table = tableParts(blocks.first) else {
            return XCTFail("expected a .table block, got \(String(describing: blocks.first))")
        }
        XCTAssertEqual(table.alignments, [.left, .center, .right, .none])
        XCTAssertEqual(table.headers, ["L", "C", "R", "D"])
        XCTAssertEqual(table.rows, [["1", "2", "3", "4"]])
    }

    func testTableBetweenParagraphsYieldsProseTableProse() {
        let source = md(
            "Before the table.",
            "",
            "| Name | Role |",
            "| --- | --- |",
            "| Hermes | agent |",
            "",
            "After the table."
        )

        let blocks = MarkdownParser.blocks(from: source)

        XCTAssertEqual(blocks.count, 3, "prose / table / prose (got \(blocks.map(\.id)))")
        XCTAssertEqual(blocks.map(\.id), ["p0", "t1", "p2"], "block ids stay stable and ordered")
        XCTAssertEqual(proseText(blocks.first)?.first, "Before the table.")
        XCTAssertNotNil(tableParts(blocks.count > 1 ? blocks[1] : nil))
        XCTAssertEqual(proseText(blocks.count > 2 ? blocks[2] : nil)?.last, "After the table.")
    }

    func testEscapedPipeDoesNotSplitACell() {
        let source = md(
            "| Expression | Meaning |",
            "| --- | --- |",
            #"| a \| b | either |"#
        )

        let blocks = MarkdownParser.blocks(from: source)

        guard let table = tableParts(blocks.first) else {
            return XCTFail("expected a .table block, got \(String(describing: blocks.first))")
        }
        XCTAssertEqual(
            table.rows,
            [[#"a \| b"#, "either"]],
            "an escaped pipe stays inside its cell, escape intact, for the one inline parser to resolve"
        )
    }

    func testRaggedBodyRowsAreFittedToTheHeaderArity() {
        let source = md(
            "| A | B | C |",
            "| --- | --- | --- |",
            "| 1 | 2 |",
            "| 1 | 2 | 3 | 4 |"
        )

        let blocks = MarkdownParser.blocks(from: source)

        guard let table = tableParts(blocks.first) else {
            return XCTFail("expected a .table block, got \(String(describing: blocks.first))")
        }
        XCTAssertEqual(table.rows, [["1", "2", ""], ["1", "2", "3"]], "the grid stays rectangular")
    }

    func testInlineFormattingInsideACellSurvivesToTheInlineParser() {
        let source = md(
            "| Name | Role |",
            "| --- | --- |",
            "| **Hermes** | `agent` |"
        )

        let blocks = MarkdownParser.blocks(from: source)

        guard let table = tableParts(blocks.first) else {
            return XCTFail("expected a .table block, got \(String(describing: blocks.first))")
        }
        XCTAssertEqual(table.rows, [["**Hermes**", "`agent`"]], "cells keep their markers; the inline pass owns them")
        XCTAssertEqual(String(MarkdownParser.inline("**Hermes**").characters), "Hermes")
    }
}
