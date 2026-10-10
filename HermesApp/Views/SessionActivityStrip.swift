import HermesServeKit
import SwiftUI

/// The composer's shared status surface, as a plain `VStack` of independent groups.
/// Its height deliberately does not depend on the wire: one 44 pt line per populated group (tasks, agents, automation, processes), so 0 to 176 pt in portrait, and no state a tap can put it in. In a compact height (a phone in landscape) it shows at most two groups, the first two in that order, because the keyboard leaves about 90 pt between the bar and the composer there. This strip shrinks the transcript's scroll view, and a height change that pushes the bottom sentinel out of the viewport latches `isNearBottom` false for the rest of the turn.
/// BUG-014: a header and not a list, because the row-drawing shape measured 424 pt with both groups full against a 155.7 pt composer. The drawer holds the full list, one tap from the header.
@MainActor
struct SessionActivityStrip: View {
    @Environment(\.hermes) private var t
    @Environment(\.verticalSizeClass) private var verticalSizeClass

    let activity: SessionActivity
    /// The chat's goal, loop and heartbeat; nil draws nothing, and so does a model whose backend has none or lacks the methods.
    var controls: SessionControlsModel? = nil
    /// The chat's background processes, on the same terms.
    var processes: BackgroundProcessesModel? = nil
    var hasBlockingPrompt = false

    /// The four groups, in the order they stack.
    enum GroupKind: Equatable, CaseIterable {
        case todos, agents, controls, processes
    }

    /// How many groups a compact height shows.
    static let compactHeightGroupCap = 2

    /// Which groups draw. A group whose sheet is open stays even when its line has nothing to say, so the sheet's host does not leave the tree under it.
    static func groups(activity: SessionActivity, controls: SessionControlsModel?, processes: BackgroundProcessesModel?, compactHeight: Bool) -> [GroupKind] {
        var present: [GroupKind] = []
        if !activity.todos.isEmpty { present.append(.todos) }
        if !activity.subagents.isEmpty { present.append(.agents) }
        if let controls, controls.isVisible || controls.isSheetPresented { present.append(.controls) }
        if let processes, processes.isVisible || processes.isSheetPresented { present.append(.processes) }
        return compactHeight ? Array(present.prefix(compactHeightGroupCap)) : present
    }

    private var shown: [GroupKind] {
        Self.groups(activity: activity, controls: controls, processes: processes, compactHeight: verticalSizeClass == .compact)
    }

    var body: some View {
        let shown = shown
        if !shown.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(shown, id: \.self) { kind in
                    switch kind {
                    case .todos:
                        TodoStripGroup(list: activity.todos, hasBlockingPrompt: hasBlockingPrompt)
                    // A sibling group rather than a variant of the one above it: the two describe different things and their retention rules point in opposite directions at the same instant.
                    case .agents:
                        SubagentStripGroup(rows: activity.subagents, hasBlockingPrompt: hasBlockingPrompt)
                    // Two more siblings, each one line and each only while it has something running: what the agent does on its own, and what it left running.
                    case .controls:
                        if let controls { SessionControlStripGroup(controls: controls, hasBlockingPrompt: hasBlockingPrompt) }
                    case .processes:
                        if let processes { BackgroundProcessesStripGroup(processes: processes, hasBlockingPrompt: hasBlockingPrompt) }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            // No ground of its own: the strip sits on the conversation dock's one frosted plate, and an opaque band here would cover the plate's rounded edge. Separated from what follows it, not from the plate's edge.
            .hairline(.bottom)
            .allowsHitTesting(!hasBlockingPrompt)
        }
    }
}

// MARK: - Header progress

/// BUG-014: the fraction both strip headers wear, and the one rule they must obey, which is that it climbs. A number that decreases as work progresses is actively misleading.
enum StripProgress {
    static func detail(settled: Int, total: Int) -> String {
        "\(settled)/\(total)"
    }

    /// Agents: finished over spawned, where `isTerminal` covers completed, failed and interrupted alike.
    static func agents(_ rows: [SubagentRow]) -> String {
        detail(settled: rows.filter(\.isTerminal).count, total: rows.count)
    }

    /// Tasks: the same `settledCount` the sheet subtitle and the collapsed card show, where completed and cancelled both count as settled.
    static func todos(_ list: TodoList) -> String {
        detail(settled: list.settledCount, total: list.total)
    }
}

// MARK: - Todos

/// The agent's live plan: one header line carrying the fraction and the task in progress, with the sheet holding the readable list. An inline expansion costs 176 pt, which with the keyboard up is more transcript than a small phone has.
/// A finished list keeps its header until the next `message.start` retires it. That linger is a deliberate divergence from desktop's 4-second timer, because the engine is synchronous and timer-free by design.
@MainActor
private struct TodoStripGroup: View {
    @Environment(\.hermes) private var t

    let list: TodoList
    let hasBlockingPrompt: Bool
    @State private var showingSheet = false

    var body: some View {
        header
            .sheet(isPresented: $showingSheet) { sheet }
            .onChange(of: hasBlockingPrompt) { _, pending in
                if pending { showingSheet = false }
            }
    }

    // MARK: Header

    private var header: some View {
        Button(action: openSheet) {
            // The caret form is deliberately not used: nothing here toggles, and a chevron would promise an inline expansion that does not exist.
            // `detail` and not `count`, because the bare total is the same number running and finished; `note` carries the task in progress.
            SectionHeader(
                list.isFinished ? "Tasks done" : "Tasks",
                detail: StripProgress.todos(list),
                note: list.current?.content
            )
            .frame(minHeight: Hit.min)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(spokenSummary)
        .accessibilityHint("Opens the full task list")
    }

    private func openSheet() {
        showingSheet = true
        HapticFeedback.selection()
    }

    private func rowStack(items: [TodoItem]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            // Keyed by offset, so a repeated id on the wire cannot collide into one row.
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                TodoItemRow(item: item)
            }
        }
    }

    // MARK: The full list

    private var sheet: some View {
        VStack(alignment: .leading, spacing: Space.s5) {
            VStack(alignment: .leading, spacing: Space.s2) {
                Text("Tasks")
                    .font(HermesFont.heading)
                    .foregroundStyle(t.text1)
                Text(spokenSummary)
                    .font(HermesFont.subhead)
                    .foregroundStyle(t.text3)
            }
            .padding(.horizontal, Space.s6)
            .padding(.top, Space.s6)

            ScrollView {
                // Full text and every item: the strip is one line, and this is where the list is readable.
                rowStack(items: list.items)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(t.surface)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .presentationCornerRadius(Radius.sheet)
        .presentationBackground(t.surface)
    }

    private var spokenSummary: String {
        let base = "Tasks, \(list.settledCount) of \(list.total) done"
        guard let current = list.current else { return base }
        return "\(base). Working on \(current.content)"
    }
}

/// One task, in the sheet the strip opens and in the transcript's collapsed `todo` card, at full text because neither surface is short of room.
@MainActor
private struct TodoItemRow: View {
    @Environment(\.hermes) private var t

    let item: TodoItem

    var body: some View {
        FlatRow(showsHairline: false) { content } trailing: { EmptyView() }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(spokenStatus): \(item.content)")
    }

    private var content: some View {
        HStack(alignment: .top, spacing: Space.s4) {
            marker
                .frame(width: 14, alignment: .leading)
                .padding(.top, 2)
                .accessibilityHidden(true)
            Text(item.content)
                .font(HermesFont.callout)
                .foregroundStyle(ink)
                .strikethrough(item.status == .cancelled)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Text glyphs and status marks, never a tool-family SF Symbol.
    @ViewBuilder
    private var marker: some View {
        switch item.status {
        case .pending:
            Text(verbatim: "○")
                .font(HermesFont.code)
                .foregroundStyle(t.text3)
        case .inProgress:
            PulsingDot(color: t.warn, size: 7)
        case .completed:
            Image(systemName: "checkmark")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(t.ok)
        case .cancelled:
            // A caret or rule rather than text, which is the only thing `text4` carries.
            Text(verbatim: "⊘")
                .font(HermesFont.code)
                .foregroundStyle(t.text4)
        }
    }

    private var ink: Color {
        switch item.status {
        case .pending: return t.text2
        case .inProgress: return t.text1
        case .completed, .cancelled: return t.text3
        }
    }

    private var spokenStatus: String {
        switch item.status {
        case .pending: return "To do"
        case .inProgress: return "In progress"
        case .completed: return "Done"
        case .cancelled: return "Cancelled"
        }
    }
}

// MARK: - The transcript's collapsed todo card

/// What a `todo` call looks like in the transcript once its list has been hoisted into the strip: one collapsible row rather than a wall of JSON.
/// Desktop renders the todo part as nothing in the thread; the phone deliberately differs, because the transcript is the only scrollback and a plan from three turns ago should still be findable.
/// Only reached when the typed parse succeeded, so a payload the parser could not understand keeps the ordinary tool card.
@MainActor
struct TodoToolRow: View {
    @Environment(\.hermes) private var t
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let activity: ToolActivity
    let todos: TodoList
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if isExpanded {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(todos.items.enumerated()), id: \.offset) { _, item in
                        TodoItemRow(item: item)
                    }
                    if todos.items.isEmpty {
                        Text("The agent cleared its task list.")
                            .font(HermesFont.subhead)
                            .foregroundStyle(t.text3)
                            .padding(.horizontal, Space.s6)
                            .padding(.bottom, Space.s5)
                    }
                }
            }
        }
        .enclosure(activity.isError ? .danger : .neutral)
    }

    private var header: some View {
        Button {
            // BUG-009: discrete, because this inserts rows into a scroll view pinned with `.defaultScrollAnchor(.bottom)` and animating the height change puts a second layout drive on it.
            isExpanded.toggle()
            HapticFeedback.selection()
        } label: {
            HStack(spacing: Space.s4) {
                ToolFamilyIcon(family: .todo)
                    .accessibilityHidden(true)

                Text(activity.name.isEmpty ? TodoList.toolName : activity.name)
                    .font(HermesFont.codeStrong)
                    .foregroundStyle(t.text1)

                Text(summary)
                    .font(HermesFont.footnote)
                    .hermesNumeric()
                    .foregroundStyle(t.text3)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(t.text4)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .animation(reduceMotion ? nil : Motion.quick, value: isExpanded)
            }
            .padding(.horizontal, Space.s5)
            .frame(minHeight: Hit.min)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Task list, \(summary)")
        .accessibilityHint(isExpanded ? "Collapse the list" : "Expand the list")
    }

    private var summary: String {
        if todos.items.isEmpty { return "list cleared" }
        return "\(todos.settledCount)/\(todos.total) done"
    }
}
