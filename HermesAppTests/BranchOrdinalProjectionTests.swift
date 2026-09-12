import Foundation
import XCTest

// `@testable` on the kit as well as the app: `TranscriptPage`'s memberwise
// initialiser is internal (the type is only ever built inside `RestAPI`), and
// these tests need to hand the projection a synthetic page.
@testable import HermesMobile
@testable import HermesServeKit

/// BUG-037 — `ChatModel.projectTranscriptWithOrdinals` (ChatModel.swift:1922).
///
/// The kit-side tests in `BranchOrdinalTests` pin the *predicate*
/// (`TranscriptMessage.countsTowardBranchOrdinal`). These pin the **fix site**:
/// that the projection actually applies it, and that the number handed to
/// `session.branch` as `count` addresses the position the user picked.
///
/// The distinction matters. A correct predicate that the projection forgets to
/// use is exactly the shape of the original bug — the ordinal was computed in
/// the loop, not in a helper, and no test looked at the loop.
@MainActor
final class BranchOrdinalProjectionTests: XCTestCase {

    private func row(
        _ id: Int,
        _ role: String,
        _ text: String? = nil,
        displayKind: String? = nil,
        toolCallID: String? = nil,
        toolCalls: [String] = []
    ) -> TranscriptMessage {
        var object: [String: JSONValue] = [
            "id": .number(Double(id)),
            "role": .string(role),
            "content": text.map(JSONValue.string) ?? .null,
            "timestamp": .number(1_787_000_000),
        ]
        if let displayKind { object["display_kind"] = .string(displayKind) }
        if let toolCallID { object["tool_call_id"] = .string(toolCallID) }
        if !toolCalls.isEmpty {
            object["tool_calls"] = .array(toolCalls.map { id in
                .object([
                    "id": .string(id),
                    "function": .object([
                        "name": .string("terminal"),
                        "arguments": .string("{\"command\":\"ls\"}"),
                    ]),
                ])
            })
        }
        return TranscriptMessage(json: .object(object))
    }

    private func page(_ messages: [TranscriptMessage]) -> TranscriptPage {
        TranscriptPage(
            sessionID: "s1",
            messages: messages,
            limit: nil,
            offset: 0,
            returned: messages.count
        )
    }

    /// The regression, at the fix site, on the shape that shipped broken: every
    /// assistant turn ran a tool.
    ///
    /// Server-visible rows are the two user turns and the two assistant text
    /// turns — four. Before the fix the projection counted all eight, so
    /// branching at "delete a.txt" sent `count: 5` against a list of length 4
    /// and copied the whole conversation instead of stopping there.
    func testToolHeavySessionOrdinalsAddressTheServersVisibleList() {
        let messages = [
            row(1, "user", "list the files"),
            row(2, "assistant", nil, toolCalls: ["c1"]),
            row(3, "tool", "a.txt b.txt", toolCallID: "c1"),
            row(4, "assistant", "There are two files."),
            row(5, "user", "delete a.txt"),
            row(6, "assistant", nil, toolCalls: ["c2"]),
            row(7, "tool", "removed 'a.txt'", toolCallID: "c2"),
            row(8, "assistant", "Deleted it."),
        ]

        let projected = ChatModel.projectTranscriptWithOrdinals(page(messages))

        // The user turns, as the transcript renders them.
        let userEntries = projected.entries.filter { $0.kind == .user }
        XCTAssertEqual(userEntries.count, 2)

        let firstUser = try? XCTUnwrap(userEntries.first)
        let secondUser = try? XCTUnwrap(userEntries.last)
        XCTAssertEqual(projected.ordinals[firstUser?.id ?? ""], 1)
        XCTAssertEqual(
            projected.ordinals[secondUser?.id ?? ""], 3,
            "the second user turn is the 3rd row in the server's visible list, not the 5th row overall"
        )

        // The invariant the bug violated: no ordinal may exceed the length of
        // the list the server will slice. Four visible rows means every ordinal
        // is <= 4; the old projection produced 5 and 8 here.
        let serverVisibleCount = messages.filter(\.countsTowardBranchOrdinal).count
        XCTAssertEqual(serverVisibleCount, 4)
        for (entryID, ordinal) in projected.ordinals {
            XCTAssertLessThanOrEqual(
                ordinal, serverVisibleCount,
                "ordinal \(ordinal) for \(entryID) is past the end of the server's visible list"
            )
        }
    }

    /// Hidden and bookkeeping rows are skipped for rendering but still occupy an
    /// ordinal, because the server's filter does not look at `display_kind`.
    /// Getting this backwards would break branching in the other direction —
    /// copying too little.
    func testBookkeepingRowsAreNotRenderedButStillConsumeAnOrdinal() {
        let messages = [
            row(1, "user", "hello"),
            row(2, "assistant", "hi"),
            row(3, "user", "[model switched to opus]", displayKind: "model_switch"),
            row(4, "user", "carry on"),
        ]

        let projected = ChatModel.projectTranscriptWithOrdinals(page(messages))

        let userEntries = projected.entries.filter { $0.kind == .user }
        XCTAssertEqual(userEntries.count, 2, "the bookkeeping row must not render as a user turn")
        XCTAssertEqual(userEntries.last.map { projected.ordinals[$0.id] } ?? nil, 4,
                       "the skipped bookkeeping row still counts, so 'carry on' is the 4th visible row")
    }

    /// A session with no tools is the case that worked before and must keep
    /// working: every row counts, so ordinals are simply 1…n.
    func testPlainConversationIsUnchangedByTheFix() {
        let messages = [
            row(1, "user", "one"),
            row(2, "assistant", "two"),
            row(3, "user", "three"),
            row(4, "assistant", "four"),
        ]

        let projected = ChatModel.projectTranscriptWithOrdinals(page(messages))
        let ordinals = projected.entries.compactMap { projected.ordinals[$0.id] }
        XCTAssertEqual(ordinals, [1, 2, 3, 4])
    }
}
