import HermesServeKit
import SwiftUI

/// The phrase on a conversation transcript's disclosure line, built from what is actually there: a turn that ran no tools says nothing about tools, and a trace whose duration this client never watched says "thought" rather than inventing a number.
enum ConversationDisclosureLabel {
    static func phrase(
        toolCount: Int,
        isRunningTools: Bool,
        hasReasoning: Bool,
        reasoningDuration: TimeInterval?,
        isStreaming: Bool
    ) -> String? {
        var parts: [String] = []

        if toolCount > 0 {
            let noun = toolCount == 1 ? "tool" : "tools"
            parts.append(isRunningTools ? "running \(toolCount) \(noun)…" : "ran \(toolCount) \(noun)")
        }

        if hasReasoning {
            if isStreaming {
                parts.append("thinking…")
            } else if let reasoningDuration {
                parts.append("thought for \(RelativeTime.duration(reasoningDuration))")
            } else {
                parts.append("thought")
            }
        }

        guard let first = parts.first else { return nil }
        // Sentence case on the joined phrase and not on each part: "Ran 3 tools · thought for 4.0 s", never "Ran 3 Tools · Thought for 4.0 s".
        let capitalised = first.prefix(1).uppercased() + first.dropFirst()
        return ([capitalised] + parts.dropFirst()).joined(separator: " · ")
    }

    /// The phrase for one grouped row, or nil when the row has nothing to disclose.
    static func phrase(for item: ConversationItem) -> String? {
        switch item {
        case .entry:
            return nil
        case .turn(let assistant, let tools):
            return phrase(
                toolCount: tools.count,
                isRunningTools: tools.contains { $0.tool?.isRunning == true },
                hasReasoning: !assistant.reasoning.isEmpty,
                reasoningDuration: assistant.reasoningDuration,
                isStreaming: assistant.isStreaming
            )
        case .pendingTools(let tools):
            return phrase(
                toolCount: tools.count,
                isRunningTools: tools.contains { $0.tool?.isRunning == true },
                hasReasoning: false,
                reasoningDuration: nil,
                isStreaming: false
            )
        }
    }
}

/// The one compact line under a bot bubble that stands for everything the turn did. Expanding renders the same `ToolCardView`, `ToolGroupCard` and `ReasoningBlock` Sessions mode renders, so there is no second card to keep in step.
@MainActor
struct ConversationDisclosure: View {
    @Environment(\.hermes) private var t
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isExpanded = false

    let label: String
    /// The assistant entry whose reasoning belongs in the expansion; nil for a mid-turn tool run.
    var assistant: ChatEntry?
    let tools: [ChatEntry]

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s5) {
            Button {
                // BUG-009: discrete, because this swaps one caption line for a stack of tool cards inside a scroll view pinned with `.defaultScrollAnchor(.bottom)`, and animating it puts a second layout drive on that scroll view.
                isExpanded.toggle()
            } label: {
                HStack(spacing: Space.s3) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(t.text4)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .animation(reduceMotion ? nil : Motion.quick, value: isExpanded)
                    Text(label)
                        .font(HermesFont.caption)
                        .foregroundStyle(t.text3)
                        .lineLimit(1)
                }
                .frame(minHeight: Hit.min, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(label)

            if isExpanded {
                expansion
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Sessions mode's own rendering; the grouping preference is read here rather than baked in, so Settings keeps governing repeated calls in both grammars.
    @ViewBuilder
    private var expansion: some View {
        VStack(alignment: .leading, spacing: Space.s5) {
            ForEach(Self.sections(assistant: assistant, tools: tools, grouping: TranscriptPreferences.groupRepeatedCalls)) { section in
                switch section {
                case .reasoning(let assistant):
                    ReasoningBlock(
                        text: assistant.reasoning,
                        isStreaming: assistant.isStreaming,
                        duration: assistant.reasoningDuration
                    )
                case .tool(.entry(let entry)):
                    if let tool = entry.tool { ToolCardView(activity: tool) }
                case .tool(.toolGroup(let entries)):
                    ToolGroupCard(entries: entries)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// One block of the expansion: the turn's reasoning trace, or one tool row grouped as Sessions mode groups them.
    enum Section: Identifiable {
        case reasoning(ChatEntry)
        case tool(ChatView.TranscriptItem)

        var id: String {
            switch self {
            case .reasoning(let assistant): return "reasoning-\(assistant.id)"
            case .tool(let item): return item.id
            }
        }
    }

    /// The expansion's blocks, in the order they happened: the tools first, then the reasoning.
    /// `ConversationGrouping` folds the tools that ran before an assistant entry under it, and the engine closes an assistant entry when a tool card is appended, so this entry was opened after those tools and its reasoning was thought after they ran. Drawing it first put a later thought above the work it followed, the order already fixed for the Sessions renderer.
    static func sections(assistant: ChatEntry?, tools: [ChatEntry], grouping: Bool) -> [Section] {
        var sections = ChatView.groupItems(tools, grouping: grouping).map(Section.tool)
        if let assistant, !assistant.reasoning.isEmpty {
            sections.append(.reasoning(assistant))
        }
        return sections
    }
}
