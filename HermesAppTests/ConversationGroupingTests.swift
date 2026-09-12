import HermesServeKit
import XCTest

@testable import HermesMobile

/// **What belongs under which bubble.**
///
/// The wire hands the client a flat array of five `ChatEntry` kinds, and
/// reasoning is a *field* on the assistant entry rather than a kind of its own.
/// Sessions grammar renders that array as-is, peer rows all the way down.
/// Conversation grammar cannot: a bot that ran three tools and then answered
/// has to show one answer with the work folded under it, or the transcript is a
/// log file with rounded corners.
///
/// `ConversationGrouping.group` is the whole of that judgement and it is a pure
/// function, so this file exercises it with no view, no `ChatModel`, no
/// simulator window and no scroll view — the same reason `TranscriptScroll` and
/// `HomeLiveIndicator` were factored out of their views.
final class ConversationGroupingTests: XCTestCase {

    // MARK: Fixtures

    private static let epoch = Date(timeIntervalSince1970: 1_760_000_000)

    private func user(_ id: String, at offset: TimeInterval = 0) -> ChatEntry {
        ChatEntry(id: id, kind: .user, text: "ask \(id)", timestamp: Self.epoch.addingTimeInterval(offset))
    }

    private func assistant(
        _ id: String,
        text: String = "answer",
        reasoning: String = "",
        streaming: Bool = false,
        at offset: TimeInterval = 0
    ) -> ChatEntry {
        ChatEntry(
            id: id,
            kind: .assistant,
            text: text,
            reasoning: reasoning,
            isStreaming: streaming,
            status: streaming ? "" : "complete",
            timestamp: Self.epoch.addingTimeInterval(offset),
            reasoningStartedAt: reasoning.isEmpty ? nil : Self.epoch,
            reasoningEndedAt: reasoning.isEmpty ? nil : Self.epoch.addingTimeInterval(4)
        )
    }

    private func tool(
        _ id: String,
        name: String = "terminal",
        running: Bool = false,
        at offset: TimeInterval = 0
    ) -> ChatEntry {
        ChatEntry(
            id: id,
            kind: .tool,
            tool: ToolActivity(id: id, name: name, context: "ctx", isRunning: running),
            timestamp: Self.epoch.addingTimeInterval(offset)
        )
    }

    // MARK: 1 — tools fold under the answer they produced

    func testToolsBeforeAnAssistantEntryFoldUnderIt() {
        let items = ConversationGrouping.group([
            user("u1"),
            tool("t1"), tool("t2"), tool("t3"),
            assistant("a1"),
        ])

        XCTAssertEqual(items.count, 2, """
            \(items.count) rows for one question, three tool calls and one answer. Conversation \
            grammar is one user bubble and one bot bubble; the tool calls belong to the answer, \
            on its disclosure line, not beside it as three peer rows
            """)
        guard case .entry(let first) = items.first else {
            return XCTFail("the first row is \(String(describing: items.first)), not the user's question")
        }
        XCTAssertEqual(first.id, "u1")
        guard case .turn(let answer, let tools) = items.last else {
            return XCTFail("the second row is \(String(describing: items.last)), not a bot turn")
        }
        XCTAssertEqual(answer.id, "a1")
        XCTAssertEqual(tools.map(\.id), ["t1", "t2", "t3"], """
            the turn carries \(tools.map(\.id)) — every tool call between the question and the \
            answer belongs to that answer, in order
            """)
    }

    /// A tool run that is *not* consecutive with the answer belonged to the
    /// turn before it. Folding it forward would put one turn's work under the
    /// next turn's bubble, and jump the user's message to do it.
    func testAUserTurnBetweenToolsAndAnAnswerBreaksTheRun() {
        let items = ConversationGrouping.group([
            tool("t1"),
            user("u1"),
            assistant("a1"),
        ])

        XCTAssertEqual(items.count, 3)
        guard case .pendingTools(let orphaned) = items.first else {
            return XCTFail("the tool run did not flush before the user's message: \(items.map(\.id))")
        }
        XCTAssertEqual(orphaned.map(\.id), ["t1"])
        guard case .turn(_, let tools) = items.last else {
            return XCTFail("the answer is not a turn: \(items.map(\.id))")
        }
        XCTAssertTrue(tools.isEmpty, """
            the answer swallowed \(tools.map(\.id)), which ran before a question it could not \
            have been answering
            """)
    }

    // MARK: 2 — the mid-turn run

    func testATrailingToolRunWithNoAnswerYetGetsItsOwnRow() {
        let items = ConversationGrouping.group([
            user("u1"),
            assistant("a1"),
            tool("t1", running: true), tool("t2", running: true),
        ])

        guard case .pendingTools(let tools) = items.last else {
            return XCTFail("""
                a tool run with no answer after it produced \(String(describing: items.last)). \
                Mid-turn the reader has to see that something is running — dropping the row until \
                the answer arrives makes a working bot look idle
                """)
        }
        XCTAssertEqual(tools.map(\.id), ["t1", "t2"])
    }

    // MARK: 3 — everything else passes through untouched

    func testNoticesAndSystemRowsPassThrough() {
        let notice = ChatEntry(id: "n1", kind: .notice, text: "reconnected", timestamp: Self.epoch)
        let system = ChatEntry(id: "s1", kind: .system, text: "review.summary", timestamp: Self.epoch)
        let items = ConversationGrouping.group([notice, system])

        XCTAssertEqual(items.map(\.id), ["n1", "s1"], """
            notices and system rows are not conversation turns and must render exactly as \
            Sessions mode renders them; grouping produced \(items.map(\.id))
            """)
        for item in items {
            guard case .entry = item else {
                return XCTFail("\(item.id) was folded into a turn it does not belong to")
            }
        }
    }

    func testAnEmptyTranscriptGroupsToNothing() {
        XCTAssertTrue(ConversationGrouping.group([]).isEmpty)
    }

    // MARK: 4 — reasoning is a field, not a row

    func testAReasoningOnlyAssistantEntryIsStillATurnAndSaysWhatItDid() {
        let items = ConversationGrouping.group([assistant("a1", text: "", reasoning: "weighing it up")])

        guard items.count == 1, case .turn(let answer, let tools) = items[0] else {
            return XCTFail("a reasoning-only answer produced \(items.map(\.id))")
        }
        XCTAssertTrue(tools.isEmpty)
        XCTAssertEqual(answer.reasoning, "weighing it up")
        XCTAssertEqual(ConversationDisclosureLabel.phrase(for: items[0]), "Thought for 4.0 s", """
            an answer whose only content is a reasoning trace still has to say so on its \
            disclosure line, or the turn renders as an empty bubble with nothing under it
            """)
    }

    // MARK: 5 — ids and stamps, which the transcript navigates by

    /// The scroll machinery and the day separators both key on these. A turn
    /// keeps its assistant entry's id so `proxy.scrollTo` still finds the row,
    /// and it is stamped by its *tools* — they ran first, and a day separator
    /// has to land before the work rather than in the middle of it.
    func testATurnKeepsItsAssistantIDAndIsStampedByItsFirstTool() {
        let items = ConversationGrouping.group([
            tool("t1", at: 10),
            assistant("a1", at: 40),
        ])
        XCTAssertEqual(items.first?.id, "a1")
        XCTAssertEqual(items.first?.timestamp, Self.epoch.addingTimeInterval(10))
    }

    func testTurnsAndRowsKeepWireOrder() {
        let items = ConversationGrouping.group([
            user("u1", at: 0),
            tool("t1", at: 1), assistant("a1", at: 2),
            user("u2", at: 3),
            tool("t2", at: 4), tool("t3", at: 5), assistant("a2", at: 6),
        ])
        XCTAssertEqual(items.map(\.id), ["u1", "a1", "u2", "a2"])
    }
}
