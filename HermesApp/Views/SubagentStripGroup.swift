import HermesServeKit
import SwiftUI

// MARK: - The tree

/// One node of the delegation tree, built from `parent_id` alone because the wire carries no children array.
struct SubagentTreeNode: Identifiable {
    let row: SubagentRow
    let children: [SubagentTreeNode]
    var id: String { row.id }
}

/// Assembles the flat roster into the tree the detail sheet draws.
enum SubagentTree {
    /// Delegation nests, but not forever: a wire that says otherwise is malformed and gets flattened at this depth rather than recursing.
    static let maxDepth = 8

    static func build(from rows: [SubagentRow]) -> [SubagentTreeNode] {
        guard !rows.isEmpty else { return [] }
        let known = Set(rows.map(\.id))

        var childrenByParent: [String: [SubagentRow]] = [:]
        var roots: [SubagentRow] = []
        for row in rows {
            // A `parent_id` naming an agent that is not itself a row in this roster is the common case and not an error, because the parent is usually the session's own top-level agent; those rows are roots.
            if !row.parentID.isEmpty, row.parentID != row.id, known.contains(row.parentID) {
                childrenByParent[row.parentID, default: []].append(row)
            } else {
                roots.append(row)
            }
        }

        // A cycle leaves every row claimed as somebody's child and `roots` empty, which would render the sheet blank, so it falls back to flat.
        if roots.isEmpty { return rows.map { SubagentTreeNode(row: $0, children: []) } }

        func node(_ row: SubagentRow, depth: Int, ancestors: Set<String>) -> SubagentTreeNode {
            guard depth < maxDepth, !ancestors.contains(row.id) else {
                return SubagentTreeNode(row: row, children: [])
            }
            var ancestors = ancestors
            ancestors.insert(row.id)
            let children = (childrenByParent[row.id] ?? []).map {
                node($0, depth: depth + 1, ancestors: ancestors)
            }
            return SubagentTreeNode(row: row, children: children)
        }
        return roots.map { node($0, depth: 0, ancestors: []) }
    }

    /// Depth-first flattening with the indent level, so the sheet draws the tree as a plain list; a `List` with `children:` would bring free per-row height changes and its own scroll.
    static func flatten(_ nodes: [SubagentTreeNode], level: Int = 0) -> [(node: SubagentTreeNode, level: Int)] {
        nodes.flatMap { node in
            [(node, level)] + flatten(node.children, level: level + 1)
        }
    }

    /// `12s`, `3m 04s`, `1h 12m`, and never a bare float.
    static func elapsedLabel(_ seconds: TimeInterval) -> String {
        let total = Int(max(0, seconds).rounded())
        if total < 60 { return "\(total)s" }
        let minutes = total / 60
        if minutes < 60 { return String(format: "%dm %02ds", minutes, total % 60) }
        return String(format: "%dh %02dm", minutes / 60, minutes % 60)
    }
}

// MARK: - The strip group

/// The agents the session has delegated work to. A sibling of `TodoStripGroup` and not a variant of it, because the two describe different things and their retention rules point in opposite directions at the same instant.
/// BUG-014: its height does not depend on the roster, and is one 44 pt line whether one agent is working or thirty-two, carrying the fraction and what the leading agent is doing. The tree is one tap away.
@MainActor
struct SubagentStripGroup: View {
    @Environment(\.hermes) private var t
    /// Optional because the strip is also measured on its own, with no app around it.
    @Environment(AppModel.self) private var app: AppModel?

    let rows: [SubagentRow]
    var hasBlockingPrompt = false
    @State private var showingSheet = false

    /// How often the roster is re-read while agents are working; Desktop's composer uses the same interval.
    static let refreshInterval: UInt64 = 5_000_000_000

    private var running: [SubagentRow] { rows.filter { !$0.isTerminal } }
    /// Every agent has finished; the header lingers until the next `message.start` retires it, as a finished checklist does.
    private var isFinished: Bool { !rows.isEmpty && running.isEmpty }
    private var sessionID: String { rows.first { !$0.sessionID.isEmpty }?.sessionID ?? "" }

    var body: some View {
        header
            .sheet(isPresented: $showingSheet) { SubagentSheet(rows: rows) }
            .onChange(of: hasBlockingPrompt) { _, pending in
                if pending { showingSheet = false }
            }
            // While agents are drawn as working and the strip is on screen, re-read the roster, so one whose `subagent.complete` never reached this phone settles instead of reading "running" for good.
            .task(id: running.isEmpty ? "" : sessionID) {
                await refreshWhileWorking()
            }
    }

    private func refreshWhileWorking() async {
        let sessionID = self.sessionID
        guard !running.isEmpty, !sessionID.isEmpty, let app else { return }
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: Self.refreshInterval)
            guard !Task.isCancelled, let chat = app.chat(runtimeSessionID: sessionID) else { return }
            guard await chat.subagentRoster.refresh(app: app, sessionID: sessionID) else { return }
        }
    }

    // MARK: Header

    private var header: some View {
        Button {
            showingSheet = true
            HapticFeedback.selection()
        } label: {
            // The caret form is deliberately unused: nothing here toggles, and a chevron would promise an inline expansion that does not exist.
            // BUG-014: `detail` and not `count`, because `running.count` counted down as agents landed; finished-over-spawned climbs, and `note` names the agent whose work is in flight.
            SectionHeader(
                isFinished ? "◈ Agents done" : "◈ Agents",
                detail: StripProgress.agents(rows),
                note: running.first?.goal
            )
            .frame(minHeight: Hit.min)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(spokenSummary)
        .accessibilityHint("Opens the agent tree")
    }

    private var spokenSummary: String {
        if isFinished { return "Agents, all \(rows.count) finished" }
        let goal = running.first?.goal ?? ""
        let base = "Agents, \(running.count) of \(rows.count) working"
        return goal.isEmpty ? base : "\(base). \(goal)"
    }
}

/// The status mark, in the pinned semantic colours and never a derived one.
@MainActor
struct SubagentStateMark: View {
    @Environment(\.hermes) private var t

    let state: SubagentRow.State

    var body: some View {
        switch state {
        case .running:
            PulsingDot(color: t.warn, size: 7)
        case .completed:
            Image(systemName: "checkmark")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(t.ok)
        case .failed:
            Text(verbatim: "✕")
                .font(HermesFont.code)
                .foregroundStyle(t.danger)
        case .interrupted:
            Text(verbatim: "⊘")
                .font(HermesFont.code)
                .foregroundStyle(t.text4)
        case .ended:
            // Finished, outcome unknown: a quiet check, never the green one that claims success.
            Image(systemName: "checkmark")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(t.text4)
        }
    }

    static func spoken(_ state: SubagentRow.State) -> String {
        switch state {
        case .running: return "Working"
        case .completed: return "Done"
        case .failed: return "Failed"
        case .interrupted: return "Interrupted"
        case .ended: return "Finished"
        }
    }
}

// MARK: - The tree sheet

/// The full delegation tree, showing what the parent session knows about each child: goal, status, elapsed, model, tool count, and the agent's own progress lines.
/// `subagent.text` is never relayed on the parent session, so reply bodies are not here; tapping an agent opens its own page, which reads the end of its live transcript and holds its steer and stop controls, one agent at a time rather than on a row inside the strip.
@MainActor
struct SubagentSheet: View {
    @Environment(\.hermes) private var t

    let rows: [SubagentRow]

    private var flattened: [(node: SubagentTreeNode, level: Int)] {
        SubagentTree.flatten(SubagentTree.build(from: rows))
    }

    private var runningCount: Int { rows.filter { !$0.isTerminal }.count }

    var body: some View {
        NavigationStack {
            tree
                .toolbar(.hidden, for: .navigationBar)
                .navigationDestination(for: String.self) { id in
                    SubagentDetailView(id: id, rows: rows)
                }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .presentationCornerRadius(Radius.sheet)
        .presentationBackground(t.surface)
    }

    private var tree: some View {
        VStack(alignment: .leading, spacing: Space.s5) {
            VStack(alignment: .leading, spacing: Space.s2) {
                Text("Agents")
                    .font(HermesFont.heading)
                    .foregroundStyle(t.text1)
                Text("\(runningCount) of \(rows.count) working")
                    .font(HermesFont.subhead)
                    .hermesNumeric()
                    .foregroundStyle(t.text3)
            }
            .padding(.horizontal, Space.s6)
            .padding(.top, Space.s6)

            ScrollView {
                // Lazy, because 32 agents by 24 stream lines is a real ceiling and rows below the fold cost nothing until they are reached.
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(flattened, id: \.node.id) { entry in
                        NavigationLink(value: entry.node.row.id) {
                            SubagentDetailRow(row: entry.node.row, level: entry.level)
                        }
                        .buttonStyle(.plain)
                        .accessibilityHint("Opens what this agent is doing")
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(t.surface)
    }
}

@MainActor
struct SubagentDetailRow: View {
    @Environment(\.hermes) private var t

    let row: SubagentRow
    let level: Int

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s3) {
            HStack(alignment: .top, spacing: Space.s4) {
                SubagentStateMark(state: row.state)
                    .frame(width: 14, alignment: .leading)
                    .padding(.top, 2)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: Space.s2) {
                    // Full text here, because the strip truncates to one line to keep its height predictable.
                    Text(row.goal.isEmpty ? "Working" : row.goal)
                        .font(HermesFont.callout)
                        .foregroundStyle(t.text1)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    metadata

                    if !row.summary.isEmpty {
                        Text(row.summary)
                            .font(HermesFont.subhead)
                            .foregroundStyle(t.text2)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    if !row.stream.isEmpty {
                        streamLines
                    }
                }
            }
        }
        .padding(.horizontal, Space.s6)
        .padding(.vertical, Space.s5)
        // The tree edge, drawn as indentation and capped so a deep chain cannot indent a goal off the right of the screen.
        .padding(.leading, CGFloat(min(level, 4)) * Space.s6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .hairline()
        .accessibilityElement(children: .combine)
    }

    /// Status, elapsed, model and tool count; a running agent's elapsed ticks and a finished one's does not, so only the running case pays for a timeline.
    @ViewBuilder
    private var metadata: some View {
        if row.isTerminal {
            metadataLine(elapsed: row.elapsed())
        } else {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                metadataLine(elapsed: row.elapsed(now: context.date))
            }
        }
    }

    private func metadataLine(elapsed: TimeInterval) -> some View {
        Text(facts(elapsed: elapsed).joined(separator: "  ·  "))
            .font(HermesFont.footnote)
            .hermesNumeric()
            .foregroundStyle(t.text3)
            .lineLimit(2)
    }

    private func facts(elapsed: TimeInterval) -> [String] {
        var facts = [SubagentStateMark.spoken(row.state), SubagentTree.elapsedLabel(elapsed)]
        if !row.model.isEmpty { facts.append(row.model) }
        if row.toolCount > 0 { facts.append("\(row.toolCount) tool\(row.toolCount == 1 ? "" : "s")") }
        if !row.isTerminal, !row.currentTool.isEmpty { facts.append(row.currentTool) }
        if let index = row.taskIndex, let count = row.taskCount, count > 1 {
            facts.append("task \(index + 1) of \(count)")
        }
        return facts
    }

    /// The agent's own progress lines, bounded at 24 by the kit with whitespace collapsed and clamped on the way in.
    private var streamLines: some View {
        VStack(alignment: .leading, spacing: Space.s1) {
            ForEach(Array(row.stream.enumerated()), id: \.offset) { _, line in
                Text(line)
                    .font(HermesFont.codeSmall)
                    .foregroundStyle(t.text3)
                    .lineLimit(2)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.top, Space.s1)
    }
}
