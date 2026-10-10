import HermesServeKit
import XCTest

@testable import HermesMobile

/// The Bots/conversation disclosure could draw a following assistant's reasoning above the tools grouped before it. An earlier fix put the order right for the Sessions renderer only.
///
/// `ConversationGrouping` folds the tools that precede an assistant entry under that entry. Since the 498 repair the engine closes an assistant entry when a tool card is appended, so the assistant entry that follows a tool run was opened after it, and its reasoning was thought after those tools ran. The expansion has to draw the tools first.
@MainActor
final class ConversationDisclosureOrderTests: XCTestCase {

    private let now = Date()

    private func tool(_ id: String, _ name: String = "terminal") -> ChatEntry {
        ChatEntry(id: id, kind: .tool, tool: ToolActivity(id: id, name: name, context: "ls", isRunning: false), timestamp: now)
    }

    private func assistant(_ id: String, text: String, reasoning: String) -> ChatEntry {
        ChatEntry(id: id, kind: .assistant, text: text, reasoning: reasoning, status: "complete", timestamp: now)
    }

    /// The shape the 498 repair produces: thinking, a tool, then the answer with the thinking that came after the tool.
    func testReasoningThatFollowedTheToolsIsDrawnAfterThem() throws {
        let entries = [
            ChatEntry(id: "u1", kind: .user, text: "List the files", timestamp: now),
            assistant("a1", text: "", reasoning: "I should list the directory."),
            tool("t1"),
            assistant("a2", text: "Here they are.", reasoning: "The listing came back; summarise it."),
        ]
        let items = ConversationGrouping.group(entries)
        guard case .turn(let answer, let tools)? = items.last else {
            return XCTFail("the answer was not grouped as a turn: \(items)")
        }
        XCTAssertEqual(tools.map(\.id), ["t1"])
        let order = ConversationDisclosure.sections(assistant: answer, tools: tools, grouping: true).map(\.id)
        XCTAssertEqual(order, ["t1", "reasoning-a2"], """
            the answer's reasoning is drawn above the tool it followed. The disclosure reads \
            \(order); the turn happened as tool, then thinking, then answer
            """)
    }

    func testSeveralToolsKeepTheirOrderAndGroupingAheadOfTheReasoning() {
        let tools = [tool("t1", "read"), tool("t2", "read"), tool("t3", "terminal")]
        let answer = assistant("a2", text: "Done.", reasoning: "All three ran.")
        let order = ConversationDisclosure.sections(assistant: answer, tools: tools, grouping: true).map(\.id)
        XCTAssertEqual(order, ["group-t1", "t3", "reasoning-a2"])
    }

    func testATurnWithNoToolsShowsOnlyItsReasoning() {
        let answer = assistant("a1", text: "Hi.", reasoning: "A greeting.")
        XCTAssertEqual(ConversationDisclosure.sections(assistant: answer, tools: [], grouping: true).map(\.id), ["reasoning-a1"])
    }

    func testAMidTurnToolRunHasNoReasoning() {
        XCTAssertEqual(ConversationDisclosure.sections(assistant: nil, tools: [tool("t1")], grouping: true).map(\.id), ["t1"])
    }
}
