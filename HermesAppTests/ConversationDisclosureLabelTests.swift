import HermesServeKit
import XCTest

@testable import HermesMobile

/// **The one line that stands for everything a turn did.**
///
/// In conversation grammar the tool cards and the reasoning trace collapse into
/// a single caption under the bubble. That line is the only thing most readers
/// will ever see of either, so it has to be built from what is *actually*
/// there — never a template with blanks filled in, and never a number this
/// client did not measure (`ChatEntry.reasoningDuration`: "a wrong number is
/// worse than no number").
final class ConversationDisclosureLabelTests: XCTestCase {

    private func phrase(
        tools: Int = 0,
        running: Bool = false,
        reasoning: Bool = false,
        duration: TimeInterval? = nil,
        streaming: Bool = false
    ) -> String? {
        ConversationDisclosureLabel.phrase(
            toolCount: tools,
            isRunningTools: running,
            hasReasoning: reasoning,
            reasoningDuration: duration,
            isStreaming: streaming
        )
    }

    // MARK: Nothing to say

    /// A plain answer gets no line at all. An always-present disclosure that
    /// says nothing is the defect BUG-017 (C) fixed in `ReasoningBlock` — a
    /// chevron and empty space — and this surface must not reintroduce it.
    func testAPlainAnswerHasNoDisclosureLine() {
        XCTAssertNil(phrase(), """
            an answer that ran no tools and showed no reasoning produced a disclosure line. \
            There is nothing behind it to expand, so the line is a control that does nothing
            """)
    }

    // MARK: Tools

    func testOneToolIsSingular() {
        XCTAssertEqual(phrase(tools: 1), "Ran 1 tool")
    }

    func testSeveralToolsArePlural() {
        XCTAssertEqual(phrase(tools: 3), "Ran 3 tools")
    }

    func testRunningToolsAreStatedInThePresentTense() {
        XCTAssertEqual(phrase(tools: 2, running: true), "Running 2 tools…")
        XCTAssertEqual(phrase(tools: 1, running: true), "Running 1 tool…")
    }

    // MARK: Reasoning

    func testAMeasuredThinkStatesItsDuration() {
        XCTAssertEqual(phrase(reasoning: true, duration: 4), "Thought for 4.0 s")
    }

    /// Nil is a real answer, and the line has to render it as one: a trace
    /// loaded from history never saw the stream, so there is no duration to
    /// state and inventing a zero would be a lie about a ninety-second think.
    func testAnUnmeasuredThinkStatesNoDuration() {
        XCTAssertEqual(phrase(reasoning: true, duration: nil), "Thought")
    }

    func testAStreamingTurnSaysItIsThinking() {
        XCTAssertEqual(phrase(reasoning: true, duration: nil, streaming: true), "Thinking…")
        XCTAssertEqual(phrase(reasoning: true, duration: 4, streaming: true), "Thinking…", """
            a duration was printed for a think that has not finished. The stamps only close on \
            `message.complete`; a counter that stops early reads as a finished thought
            """)
    }

    // MARK: Both

    func testToolsAndReasoningJoinInOneSentenceCasePhrase() {
        XCTAssertEqual(phrase(tools: 3, reasoning: true, duration: 4), "Ran 3 tools · thought for 4.0 s", """
            the joined phrase is sentence case, once, on the whole line — not title case on each \
            half. It is a caption under a bubble, not a heading
            """)
    }

    func testAStreamingTurnMidToolRunSaysBoth() {
        XCTAssertEqual(
            phrase(tools: 2, running: true, reasoning: true, streaming: true),
            "Running 2 tools… · thinking…"
        )
    }

    // MARK: Reading it off a grouped row

    func testTheRowConvenienceAgreesWithTheBuilder() {
        let tools = [
            ChatEntry(id: "t1", kind: .tool, tool: ToolActivity(id: "t1", name: "read", isRunning: false)),
            ChatEntry(id: "t2", kind: .tool, tool: ToolActivity(id: "t2", name: "read", isRunning: false)),
        ]
        let answer = ChatEntry(id: "a1", kind: .assistant, text: "done", status: "complete")
        XCTAssertEqual(
            ConversationDisclosureLabel.phrase(for: .turn(assistant: answer, tools: tools)),
            "Ran 2 tools"
        )
        XCTAssertEqual(ConversationDisclosureLabel.phrase(for: .entry(answer)), nil)
    }

    /// One running call in the run is enough: the line has to read as live for
    /// as long as anything in it is.
    func testARunWithOneLiveCallReadsAsRunning() {
        let tools = [
            ChatEntry(id: "t1", kind: .tool, tool: ToolActivity(id: "t1", name: "read", isRunning: false)),
            ChatEntry(id: "t2", kind: .tool, tool: ToolActivity(id: "t2", name: "terminal", isRunning: true)),
        ]
        XCTAssertEqual(ConversationDisclosureLabel.phrase(for: .pendingTools(tools)), "Running 2 tools…")
    }
}
