import XCTest

@testable import HermesServeKit

/// BUG-037. `session.branch`'s `count` truncates the backend's **visible**
/// history, so the client's ordinal must count exactly the rows the server
/// counts and no others.
///
/// The server's filter is `_visible_branch_history` in
/// `tui_gateway/methods_session.py`: keep `user`/`assistant` rows whose
/// `_coerce_message_text(content).strip()` is non-empty. Every case below
/// pins one clause of that filter. If the server drifts, these fail first —
/// which matters more here than usual, because the drift is invisible on the
/// wire (no name changes shape, so no contract check can catch it).
final class BranchOrdinalTests: XCTestCase {

    private func message(
        id: Int,
        role: String,
        content: JSONValue = .null,
        displayKind: String? = nil,
        toolCalls: JSONValue? = nil
    ) -> TranscriptMessage {
        var object: [String: JSONValue] = [
            "id": .number(Double(id)),
            "role": .string(role),
            "content": content,
        ]
        if let displayKind { object["display_kind"] = .string(displayKind) }
        if let toolCalls { object["tool_calls"] = toolCalls }
        return TranscriptMessage(json: .object(object))
    }

    /// The plain case: a real user turn and a real assistant turn both count.
    func testUserAndAssistantTextRowsCount() {
        XCTAssertTrue(message(id: 1, role: "user", content: .string("hi")).countsTowardBranchOrdinal)
        XCTAssertTrue(message(id: 2, role: "assistant", content: .string("hello")).countsTowardBranchOrdinal)
    }

    /// `role not in {"user", "assistant"}` — the clause that caused the bug.
    /// Tool result rows are the commonest row in a tool-heavy session and the
    /// server does not count a single one of them.
    func testToolAndSystemRowsDoNotCount() {
        let toolResult = message(id: 1, role: "tool", content: .string("total 0\ndrwxr-xr-x"))
        XCTAssertFalse(toolResult.countsTowardBranchOrdinal)

        let system = message(id: 2, role: "system", content: .string("You are Hermes."))
        XCTAssertFalse(system.countsTowardBranchOrdinal)

        let unknown = message(id: 3, role: "wat", content: .string("?"))
        XCTAssertFalse(unknown.countsTowardBranchOrdinal)
    }

    /// `not _coerce_message_text(...).strip()` — an assistant row that carries
    /// only tool calls has `content: null` and does not count, even though it
    /// renders as tool cards in the transcript.
    func testEmptyAndWhitespaceOnlyRowsDoNotCount() {
        let toolCallOnly = message(
            id: 1, role: "assistant", content: .null,
            toolCalls: .array([
                .object([
                    "id": .string("call_1"),
                    "function": .object([
                        "name": .string("terminal"),
                        "arguments": .string("{}"),
                    ]),
                ])
            ])
        )
        XCTAssertFalse(toolCallOnly.countsTowardBranchOrdinal)
        XCTAssertFalse(message(id: 2, role: "assistant", content: .string("")).countsTowardBranchOrdinal)
        XCTAssertFalse(message(id: 3, role: "user", content: .string("   \n\t ")).countsTowardBranchOrdinal)
    }

    /// The trap. `_coerce_message_text` folds image parts into the string as
    /// their URL, so an image-only row is NON-empty server-side and counts —
    /// while `MessageContent.plainText` keeps only text parts and reports "".
    /// Testing `plainText` alone would under-count precisely the rows a user is
    /// most likely to branch at.
    func testImageOnlyRowCountsEvenThoughPlainTextIsEmpty() {
        let imageOnly = message(
            id: 1, role: "user",
            content: .array([
                .object([
                    "type": .string("image_url"),
                    "image_url": .object(["url": .string("data:image/png;base64,AAAA")]),
                ])
            ])
        )
        XCTAssertEqual(imageOnly.content.plainText, "", "precondition: plainText drops image parts")
        XCTAssertTrue(
            imageOnly.countsTowardBranchOrdinal,
            "the server folds the image URL into the text, so this row counts"
        )
    }

    /// `display_kind` is NOT part of the server's filter. Hidden and
    /// bookkeeping rows still occupy an ordinal even though nothing renders
    /// them — counting and rendering are separate questions, and conflating
    /// them is what produced BUG-037.
    func testHiddenAndBookkeepingRowsStillCount() {
        let bookkeeping = message(
            id: 1, role: "user", content: .string("[model switched]"), displayKind: "model_switch"
        )
        XCTAssertTrue(bookkeeping.isBookkeeping)
        XCTAssertTrue(bookkeeping.countsTowardBranchOrdinal, "the server does not filter display_kind")

        let hidden = message(id: 2, role: "user", content: .string("widget intent"), displayKind: "hidden")
        XCTAssertTrue(hidden.isHidden)
        XCTAssertTrue(hidden.countsTowardBranchOrdinal)
    }

    /// The regression, end to end, on the shape that actually shipped broken:
    /// a session where every assistant turn ran a tool.
    ///
    /// Rows: user, assistant(tool-call only), tool, assistant(text),
    ///       user, assistant(tool-call only), tool, assistant(text)
    ///
    /// The server counts 4 (two user turns, two assistant text turns). The old
    /// client counted all 8. Branching at the second user turn therefore sent
    /// count=5 for a list of length 4 — copying the entire conversation instead
    /// of stopping at the chosen message.
    func testToolHeavyTranscriptOrdinalsMatchTheServersVisibleList() {
        let rows = [
            message(id: 1, role: "user", content: .string("list the files")),
            message(id: 2, role: "assistant", content: .null,
                    toolCalls: .array([.object([
                        "id": .string("c1"),
                        "function": .object(["name": .string("terminal"), "arguments": .string("{}")]),
                    ])])),
            message(id: 3, role: "tool", content: .string("a.txt b.txt")),
            message(id: 4, role: "assistant", content: .string("There are two files.")),
            message(id: 5, role: "user", content: .string("delete a.txt")),
            message(id: 6, role: "assistant", content: .null,
                    toolCalls: .array([.object([
                        "id": .string("c2"),
                        "function": .object(["name": .string("terminal"), "arguments": .string("{}")]),
                    ])])),
            message(id: 7, role: "tool", content: .string("removed 'a.txt'")),
            message(id: 8, role: "assistant", content: .string("Deleted it.")),
        ]

        let counted = rows.filter(\.countsTowardBranchOrdinal)
        XCTAssertEqual(counted.count, 4, "the server's visible list holds 4 rows, not 8")
        XCTAssertEqual(counted.map(\.id), [1, 4, 5, 8])

        // Walk the rows the way the projection does and read off the ordinal at
        // the second user turn: it must address that turn's position in the
        // server's list (3), not its position in the raw row list (5).
        var ordinal = 0
        var ordinalAtSecondUserTurn = 0
        for row in rows {
            if row.countsTowardBranchOrdinal { ordinal += 1 }
            if row.id == 5 { ordinalAtSecondUserTurn = ordinal }
        }
        XCTAssertEqual(ordinalAtSecondUserTurn, 3)
        XCTAssertLessThanOrEqual(
            ordinalAtSecondUserTurn, counted.count,
            "an ordinal past the end of the server's list is the BUG-037 overshoot"
        )
    }
}
