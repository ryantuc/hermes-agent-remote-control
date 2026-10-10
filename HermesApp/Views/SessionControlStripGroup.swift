import HermesServeKit
import SwiftUI

// MARK: - The strip group

/// The agent's own automation (a goal it is pursuing, a loop it repeats, a heartbeat it checks in on), as one 44 pt line above the composer when any of the three exists, and nothing at all otherwise. The controls live in the sheet it opens; a tap here never acts.
/// The sheet hangs off a host that stays mounted while the sheet is open, not off the line: clearing the last goal from the sheet takes the line away, and a sheet whose presenter leaves the tree is dismissed under the person.
@MainActor
struct SessionControlStripGroup: View {
    @Environment(\.hermes) private var t

    @Bindable var controls: SessionControlsModel
    var hasBlockingPrompt = false

    var body: some View {
        Group {
            if let line = controls.line {
                Button {
                    controls.isSheetPresented = true
                    HapticFeedback.selection()
                } label: {
                    SectionHeader(line.title, detail: line.detail, note: line.note)
                        .frame(minHeight: Hit.min)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(line.spoken)
                .accessibilityHint("Opens the automation controls")
                .accessibilityIdentifier("session.controls.line")
            } else {
                Color.clear.frame(width: 0, height: 0)
            }
        }
        .sheet(isPresented: $controls.isSheetPresented) { SessionControlSheet(controls: controls) }
        .onChange(of: hasBlockingPrompt) { _, pending in
            if pending { controls.isSheetPresented = false }
        }
    }
}

// MARK: - The sheet

/// One card per kind, each with its facts and its own row of actions. Pause and resume act at once; clear and stop ask first, because the backend has no undo for them.
@MainActor
struct SessionControlSheet: View {
    @Environment(\.hermes) private var t
    @Environment(\.dismiss) private var dismiss

    let controls: SessionControlsModel
    @State private var confirm: SessionControlConfirm?
    @State private var addingCriterion = false
    @State private var newCriterion = ""

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s5) {
            VStack(alignment: .leading, spacing: Space.s2) {
                Text("Automation")
                    .font(HermesFont.heading)
                    .foregroundStyle(t.text1)
                Text(subtitle)
                    .font(HermesFont.subhead)
                    .foregroundStyle(t.text3)
            }
            .padding(.horizontal, Space.s6)
            .padding(.top, Space.s6)

            ScrollView {
                VStack(alignment: .leading, spacing: Space.s5) {
                    if let error = controls.lastError {
                        SessionControlErrorRow(text: error) { controls.clearError() }
                    }
                    if let snapshot = controls.snapshot {
                        if let goal = snapshot.goal {
                            GoalCard(goal: goal, controls: controls, confirm: $confirm, addingCriterion: $addingCriterion)
                        }
                        if let loop = snapshot.loop {
                            LoopCard(loop: loop, controls: controls, confirm: $confirm)
                        }
                        if let heartbeat = snapshot.heartbeat {
                            HeartbeatCard(heartbeat: heartbeat, controls: controls, confirm: $confirm)
                        }
                    }
                    if controls.snapshot?.isEmpty ?? true {
                        Text("Nothing is running on its own right now.")
                            .font(HermesFont.callout)
                            .foregroundStyle(t.text3)
                            .padding(.horizontal, Space.s6)
                    }
                }
                .padding(.bottom, Space.s6)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(t.surface)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .presentationCornerRadius(Radius.sheet)
        .presentationBackground(t.surface)
        .confirmationDialog(
            confirm?.title ?? "",
            isPresented: Binding(get: { confirm != nil }, set: { if !$0 { confirm = nil } }),
            titleVisibility: .visible,
            presenting: confirm
        ) { pending in
            Button(pending.verb, role: .destructive) {
                let action = pending.action
                let index = pending.index
                Task { await controls.perform(action, index: index) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { pending in
            Text(pending.body)
        }
        .alert("Add a success criterion", isPresented: $addingCriterion) {
            TextField("What must be true when the goal is done", text: $newCriterion)
            Button("Add") {
                let text = newCriterion.trimmingCharacters(in: .whitespacesAndNewlines)
                newCriterion = ""
                guard !text.isEmpty else { return }
                Task { await controls.perform(.subgoalAdd, text: text) }
            }
            Button("Cancel", role: .cancel) { newCriterion = "" }
        } message: {
            Text("The agent checks every criterion before it calls the goal done.")
        }
        // The read-only view stops being true when the chat it belongs to loses its automation entirely.
        .onChange(of: controls.isVisible) { _, visible in
            if !visible, controls.support == .unsupported { dismiss() }
        }
    }

    private var subtitle: String {
        guard let snapshot = controls.snapshot, !snapshot.isEmpty else { return "Nothing running on its own" }
        var parts: [String] = []
        if let goal = snapshot.goal { parts.append("Goal \(SessionControlFormat.goalState(goal))") }
        if let loop = snapshot.loop { parts.append("Loop \(SessionControlFormat.loopState(loop))") }
        if let heartbeat = snapshot.heartbeat { parts.append("Heartbeat \(heartbeat.isPaused ? "paused" : "active")") }
        return parts.joined(separator: " · ")
    }
}

/// A destructive action waiting for its yes.
struct SessionControlConfirm: Identifiable, Equatable {
    let action: SessionControlAction
    let index: Int?
    let title: String
    let body: String
    let verb: String

    var id: String { "\(action.rawValue):\(index ?? 0)" }

    static func clearGoal() -> SessionControlConfirm {
        SessionControlConfirm(action: .goalClear, index: nil, title: "Clear this goal?", body: "The agent stops working towards it. Its progress stays in the conversation, but the goal itself cannot be brought back.", verb: "Clear goal")
    }

    static func stopLoop() -> SessionControlConfirm {
        SessionControlConfirm(action: .loopStop, index: nil, title: "Stop this loop?", body: "The prompt will not run again. To repeat it later you would set the loop up again.", verb: "Stop loop")
    }

    static func clearHeartbeat() -> SessionControlConfirm {
        SessionControlConfirm(action: .heartbeatClear, index: nil, title: "Clear this heartbeat?", body: "The agent stops checking in on this schedule.", verb: "Clear heartbeat")
    }

    static func removeCriterion(_ index: Int) -> SessionControlConfirm {
        SessionControlConfirm(action: .subgoalRemove, index: index, title: "Remove criterion \(index)?", body: "The agent will no longer check it before calling the goal done.", verb: "Remove")
    }

    static func clearCriteria() -> SessionControlConfirm {
        SessionControlConfirm(action: .subgoalClear, index: nil, title: "Remove every criterion?", body: "The goal keeps running, with nothing left for the agent to check at the end.", verb: "Remove all")
    }
}

// MARK: - Cards

@MainActor
private struct GoalCard: View {
    @Environment(\.hermes) private var t

    let goal: GoalSnapshot
    let controls: SessionControlsModel
    @Binding var confirm: SessionControlConfirm?
    @Binding var addingCriterion: Bool

    var body: some View {
        SessionControlCard(glyph: "◎", kind: "Goal", state: SessionControlFormat.goalState(goal), mark: mark, blurb: "The agent is working towards this on its own, turn after turn, until it is done or you stop it.") {
            Text(goal.title.isEmpty ? "Untitled goal" : goal.title)
                .font(HermesFont.callout)
                .foregroundStyle(t.text1)
                .fixedSize(horizontal: false, vertical: true)

            SessionControlFacts(facts: facts)

            if !goal.contract.isEmpty {
                contract
            }

            if !goal.gates.isEmpty {
                gates
            }

            criteria

            if goal.state != .done {
                actions
            }
        }
    }

    private var mark: SessionControlMark {
        if goal.isBlocked { return .danger }
        switch goal.state {
        case .active: return .running
        case .waiting, .paused: return .held
        case .done: return .done
        }
    }

    private var facts: [String] {
        var facts: [String] = []
        if let turns = SessionControlFormat.goalTurns(goal) { facts.append(turns) }
        if let barrier = goal.waitBarrier {
            switch barrier {
            case .until(let date, let reason):
                facts.append("Waiting until \(date.formatted(date: .omitted, time: .shortened))" + (reason.isEmpty ? "" : ": \(reason)"))
            case .session(let target, let reason):
                // The target is a session key, which means nothing to a reader; the reason is what they can act on.
                facts.append(reason.isEmpty ? "Waiting for another conversation to finish" : "Waiting for another conversation: \(reason)")
                _ = target
            case .pid(let pid, let reason):
                facts.append("Waiting for process \(pid)" + (reason.isEmpty ? "" : ": \(reason)"))
            }
        } else if let reason = goal.pausedReason, !reason.isEmpty {
            facts.append(reason)
        } else if let reason = goal.lastReason, !reason.isEmpty {
            facts.append(reason)
        }
        return facts
    }

    private var contract: some View {
        VStack(alignment: .leading, spacing: Space.s2) {
            labelled("Outcome", goal.contract.outcome)
            labelled("Checked by", goal.contract.verification)
            labelled("Constraints", goal.contract.constraints)
            labelled("Boundaries", goal.contract.boundaries)
            labelled("Stop when", goal.contract.stopWhen)
        }
    }

    @ViewBuilder
    private func labelled(_ label: String, _ value: String) -> some View {
        if !value.isEmpty {
            (Text("\(label): ").foregroundStyle(t.text3) + Text(value).foregroundStyle(t.text2))
                .font(HermesFont.footnote)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var gates: some View {
        VStack(alignment: .leading, spacing: Space.s2) {
            ForEach(Array(goal.gates.enumerated()), id: \.offset) { _, gate in
                HStack(spacing: Space.s3) {
                    Text(verbatim: gate.isPassing ? "✓" : (gate.lastExitCode == nil ? "○" : "✕"))
                        .font(HermesFont.code)
                        .foregroundStyle(gate.isPassing ? t.ok : (gate.lastExitCode == nil ? t.text3 : t.danger))
                    Text(gate.command)
                        .font(HermesFont.codeSmall)
                        .foregroundStyle(t.text2)
                        .lineLimit(2)
                }
            }
        }
    }

    private var criteria: some View {
        VStack(alignment: .leading, spacing: Space.s3) {
            HStack {
                Text(goal.subgoals.isEmpty ? "Success criteria" : "Success criteria (\(goal.subgoals.count))")
                    .font(HermesFont.footnote)
                    .foregroundStyle(t.text3)
                Spacer()
                if goal.state != .done {
                    Button { addingCriterion = true } label: {
                        Text("Add")
                            .font(HermesFont.footnote)
                            .foregroundStyle(t.action)
                            .frame(minWidth: Hit.min, minHeight: Hit.min)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(controls.isBusy)
                    .accessibilityLabel("Add a success criterion")
                    if !goal.subgoals.isEmpty {
                        Button { confirm = .clearCriteria() } label: {
                            Text("Clear all")
                                .font(HermesFont.footnote)
                                .foregroundStyle(t.danger)
                                .frame(minWidth: Hit.min, minHeight: Hit.min)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(controls.isBusy)
                        .accessibilityLabel("Remove every criterion")
                    }
                }
            }
            if goal.subgoals.isEmpty {
                Text("None yet. The agent decides on its own when the goal is done.")
                    .font(HermesFont.footnote)
                    .foregroundStyle(t.text3)
            }
            ForEach(Array(goal.subgoals.enumerated()), id: \.offset) { offset, criterion in
                HStack(alignment: .top, spacing: Space.s3) {
                    Text("\(offset + 1).")
                        .font(HermesFont.footnote)
                        .hermesNumeric()
                        .foregroundStyle(t.text3)
                    Text(criterion)
                        .font(HermesFont.callout)
                        .foregroundStyle(t.text2)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if goal.state != .done {
                        Button {
                            confirm = .removeCriterion(offset + 1)
                        } label: {
                            Image(systemName: "minus.circle")
                                .font(.system(size: 15))
                                .foregroundStyle(t.text3)
                        }
                        .buttonStyle(IconButtonStyle())
                        .disabled(controls.isBusy)
                        .accessibilityLabel("Remove criterion \(offset + 1)")
                    }
                }
            }
        }
    }

    private var actions: some View {
        SessionControlActions {
            switch goal.state {
            case .active:
                SessionControlButton("Pause", disabled: controls.isBusy) { await controls.perform(.goalPause) }
            case .paused:
                SessionControlButton("Resume", disabled: controls.isBusy) { await controls.perform(.goalResume) }
            case .waiting:
                SessionControlButton("Resume now", disabled: controls.isBusy) { await controls.perform(.goalUnwait) }
                SessionControlButton("Pause", disabled: controls.isBusy) { await controls.perform(.goalPause) }
            case .done:
                EmptyView()
            }
            SessionControlButton("Clear goal", destructive: true, disabled: controls.isBusy) { confirm = .clearGoal() }
        }
    }
}

@MainActor
private struct LoopCard: View {
    @Environment(\.hermes) private var t

    let loop: LoopSnapshot
    let controls: SessionControlsModel
    @Binding var confirm: SessionControlConfirm?

    var body: some View {
        SessionControlCard(glyph: "↻", kind: "Loop", state: SessionControlFormat.loopState(loop), mark: mark, blurb: "The agent runs this prompt again on a schedule.") {
            Text(loop.prompt.isEmpty ? "No prompt" : loop.prompt)
                .font(HermesFont.callout)
                .foregroundStyle(t.text1)
                .fixedSize(horizontal: false, vertical: true)

            SessionControlFacts(facts: facts)

            actions
        }
    }

    private var mark: SessionControlMark {
        switch loop.state {
        case .active: return .running
        case .deferred, .paused: return .held
        case .done: return .done
        }
    }

    private var facts: [String] {
        var facts = [SessionControlFormat.loopRuns(loop)]
        facts.append(loop.isSelfPaced ? "self-paced" : SessionControlFormat.interval(seconds: loop.intervalSeconds))
        if loop.state == .active, let next = loop.nextDueAt { facts.append("next \(SessionControlFormat.approximate(until: next))") }
        if !loop.until.isEmpty { facts.append("until: \(loop.until)") }
        if loop.deferredByGoal { facts.append("Waits until the goal is finished") }
        if loop.awaitingResponse { facts.append("Waiting for the reply to finish") }
        if let reason = loop.pausedReason, !reason.isEmpty { facts.append(reason) }
        if let reason = loop.lastStopReason, !reason.isEmpty { facts.append(reason) }
        return facts
    }

    private var actions: some View {
        SessionControlActions {
            switch loop.state {
            case .active, .deferred:
                SessionControlButton("Pause", disabled: controls.isBusy) { await controls.perform(.loopPause) }
                SessionControlButton("Stop loop", destructive: true, disabled: controls.isBusy) { confirm = .stopLoop() }
            case .paused:
                SessionControlButton("Resume", disabled: controls.isBusy) { await controls.perform(.loopResume) }
                SessionControlButton("Stop loop", destructive: true, disabled: controls.isBusy) { confirm = .stopLoop() }
            case .done:
                // A finished loop has nothing left to protect, so Desktop dismisses it without asking (`session-control-loop.tsx:106-110`).
                SessionControlButton("Dismiss", disabled: controls.isBusy) { await controls.perform(.loopStop) }
            }
        }
    }
}

@MainActor
private struct HeartbeatCard: View {
    @Environment(\.hermes) private var t

    let heartbeat: HeartbeatSnapshot
    let controls: SessionControlsModel
    @Binding var confirm: SessionControlConfirm?

    var body: some View {
        SessionControlCard(glyph: "♥", kind: "Heartbeat", state: heartbeat.isPaused ? "paused" : "active", mark: heartbeat.isPaused ? .held : .running, blurb: "The agent checks in with this prompt on a schedule, whenever the chat is idle.") {
            Text(heartbeat.prompt.isEmpty ? "No prompt" : heartbeat.prompt)
                .font(HermesFont.callout)
                .foregroundStyle(t.text1)
                .fixedSize(horizontal: false, vertical: true)

            if heartbeat.isPaused || heartbeat.nextDueAt == nil {
                SessionControlFacts(facts: facts(now: nil))
            } else {
                // Ticks only while active: a paused heartbeat has no countdown to pay a timeline for.
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    SessionControlFacts(facts: facts(now: context.date))
                }
            }

            SessionControlActions {
                if heartbeat.isPaused {
                    SessionControlButton("Resume", disabled: controls.isBusy) { await controls.perform(.heartbeatResume) }
                } else {
                    SessionControlButton("Pause", disabled: controls.isBusy) { await controls.perform(.heartbeatPause) }
                }
                SessionControlButton("Clear heartbeat", destructive: true, disabled: controls.isBusy) { confirm = .clearHeartbeat() }
            }
        }
    }

    private func facts(now: Date?) -> [String] {
        var facts = [SessionControlFormat.interval(seconds: Double(heartbeat.intervalSeconds))]
        facts.append("fired \(heartbeat.fireCount) time\(heartbeat.fireCount == 1 ? "" : "s")")
        if let now, let next = heartbeat.nextDueAt {
            facts.append(next <= now ? "due, waiting for the chat to go idle" : "next in \(SessionControlFormat.countdown(to: next, now: now))")
        }
        return facts
    }
}

// MARK: - Shared pieces

enum SessionControlMark {
    case running, held, done, danger
}

/// One card: a header line naming the kind and its state, a sentence saying what the kind is, then the content.
@MainActor
private struct SessionControlCard<Content: View>: View {
    @Environment(\.hermes) private var t

    let glyph: String
    let kind: String
    let state: String
    let mark: SessionControlMark
    let blurb: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s4) {
            HStack(spacing: Space.s3) {
                markView
                    .frame(width: 14, alignment: .leading)
                    .accessibilityHidden(true)
                Text(verbatim: glyph)
                    .font(HermesFont.codeStrong)
                    .foregroundStyle(t.text3)
                    .accessibilityHidden(true)
                Text(kind)
                    .font(HermesFont.calloutStrong)
                    .foregroundStyle(t.text1)
                Text(state)
                    .font(HermesFont.footnote)
                    .foregroundStyle(stateInk)
                Spacer(minLength: 0)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(kind), \(state)")

            Text(blurb)
                .font(HermesFont.footnote)
                .foregroundStyle(t.text3)
                .fixedSize(horizontal: false, vertical: true)

            content
        }
        .padding(.horizontal, Space.s5)
        .padding(.vertical, Space.s5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .enclosure(mark == .danger ? .danger : .neutral)
        .padding(.horizontal, Space.s6)
    }

    @ViewBuilder
    private var markView: some View {
        switch mark {
        case .running:
            PulsingDot(color: t.ok, size: 7)
        case .held:
            Image(systemName: "pause.fill")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(t.warn)
        case .done:
            Image(systemName: "checkmark")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(t.ok)
        case .danger:
            Text(verbatim: "✕")
                .font(HermesFont.code)
                .foregroundStyle(t.danger)
        }
    }

    private var stateInk: Color {
        switch mark {
        case .running: return t.ok
        case .held: return t.warn
        case .done: return t.text3
        case .danger: return t.danger
        }
    }
}

@MainActor
private struct SessionControlFacts: View {
    @Environment(\.hermes) private var t

    let facts: [String]

    var body: some View {
        if !facts.isEmpty {
            Text(facts.joined(separator: "  ·  "))
                .font(HermesFont.footnote)
                .hermesNumeric()
                .foregroundStyle(t.text3)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// The row of buttons at the foot of a card; wraps onto a second line on a narrow phone rather than squeezing.
@MainActor
private struct SessionControlActions<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: Space.s3) { content }
            VStack(spacing: Space.s3) { content }
        }
        .padding(.top, Space.s2)
    }
}

/// One action button. The closure is async so a wire action and a local "ask first" read the same at the call site; a synchronous body converts.
@MainActor
private struct SessionControlButton: View {
    let title: String
    let destructive: Bool
    let isDisabled: Bool
    let action: @MainActor () async -> Void

    init(_ title: String, destructive: Bool = false, disabled: Bool = false, action: @escaping @MainActor () async -> Void) {
        self.title = title
        self.destructive = destructive
        self.isDisabled = disabled
        self.action = action
    }

    var body: some View {
        Group {
            if destructive {
                Button(title) { Task { await action() } }
                    .buttonStyle(DangerButtonStyle(height: Hit.min))
            } else {
                Button(title) { Task { await action() } }
                    .buttonStyle(SecondaryButtonStyle(height: Hit.min))
            }
        }
        .disabled(isDisabled)
        .accessibilityIdentifier("session.controls.\(title.lowercased().replacingOccurrences(of: " ", with: "-"))")
    }
}

@MainActor
struct SessionControlErrorRow: View {
    @Environment(\.hermes) private var t

    let text: String
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: Space.s3) {
            Text(text)
                .font(HermesFont.footnote)
                .foregroundStyle(t.danger)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(action: dismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(t.text3)
            }
            .buttonStyle(IconButtonStyle())
            .accessibilityLabel("Dismiss")
        }
        .padding(.horizontal, Space.s5)
        .padding(.vertical, Space.s4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .enclosure(.danger)
        .padding(.horizontal, Space.s6)
    }
}
