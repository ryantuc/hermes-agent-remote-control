import HermesServeKit
import SwiftUI

// MARK: - The strip group

/// The background processes the agent left running (a dev server, a test run, a deploy), as one 44 pt line while any is running. The sheet lists them with their output and a Stop for each.
/// The sheet hangs off a host that stays mounted while the sheet is open, not off the line: stopping the last process takes the line away at the next read, and the sheet is where "Stopped." and the finished row are read.
@MainActor
struct BackgroundProcessesStripGroup: View {
    @Environment(\.hermes) private var t

    @Bindable var processes: BackgroundProcessesModel
    var hasBlockingPrompt = false

    var body: some View {
        Group {
            if let line = processes.line {
                Button {
                    processes.isSheetPresented = true
                    HapticFeedback.selection()
                } label: {
                    SectionHeader(line.title, detail: line.detail, note: line.note)
                        .frame(minHeight: Hit.min)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(line.spoken)
                .accessibilityHint("Opens the list of background processes")
                .accessibilityIdentifier("session.processes.line")
            } else {
                Color.clear.frame(width: 0, height: 0)
            }
        }
        .sheet(isPresented: $processes.isSheetPresented) { BackgroundProcessesSheet(processes: processes) }
        .onChange(of: hasBlockingPrompt) { _, pending in
            if pending { processes.isSheetPresented = false }
        }
    }
}

// MARK: - The sheet

/// Every process the registry still lists for this chat, running first. Polls `process.list` every five seconds for exactly as long as it is on screen; the `.task` ends with the sheet.
@MainActor
struct BackgroundProcessesSheet: View {
    @Environment(\.hermes) private var t

    let processes: BackgroundProcessesModel
    @State private var stopping: BackgroundProcess?

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s5) {
            VStack(alignment: .leading, spacing: Space.s2) {
                Text("Background processes")
                    .font(HermesFont.heading)
                    .foregroundStyle(t.text1)
                Text(subtitle)
                    .font(HermesFont.subhead)
                    .hermesNumeric()
                    .foregroundStyle(t.text3)
            }
            .padding(.horizontal, Space.s6)
            .padding(.top, Space.s6)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if let error = processes.lastError {
                        SessionControlErrorRow(text: error) { processes.clearError() }
                            .padding(.bottom, Space.s4)
                    } else if let outcome = processes.lastOutcome {
                        Text(outcome)
                            .font(HermesFont.footnote)
                            .foregroundStyle(t.text3)
                            .padding(.horizontal, Space.s6)
                            .padding(.bottom, Space.s4)
                    }
                    ForEach(processes.running + processes.finished) { process in
                        BackgroundProcessRow(
                            process: process,
                            isStopping: processes.stopping.contains(process.id),
                            onStop: { stopping = process }
                        )
                    }
                    if processes.processes.isEmpty {
                        Text("Nothing is running in the background.")
                            .font(HermesFont.callout)
                            .foregroundStyle(t.text3)
                            .padding(.horizontal, Space.s6)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(t.surface)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .presentationCornerRadius(Radius.sheet)
        .presentationBackground(t.surface)
        .task { await processes.pollWhilePresented() }
        .confirmationDialog(
            "Stop this process?",
            isPresented: Binding(get: { stopping != nil }, set: { if !$0 { stopping = nil } }),
            titleVisibility: .visible,
            presenting: stopping
        ) { process in
            Button("Stop", role: .destructive) {
                let id = process.id
                Task { await processes.stop(id) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { process in
            Text("\(process.command.isEmpty ? "The process" : process.command) will be ended now. Anything it was in the middle of is lost.")
        }
    }

    private var subtitle: String {
        let running = processes.running.count
        let finished = processes.finished.count
        var parts = ["\(running) running"]
        if finished > 0 { parts.append("\(finished) finished") }
        return parts.joined(separator: " · ")
    }
}

@MainActor
private struct BackgroundProcessRow: View {
    @Environment(\.hermes) private var t

    let process: BackgroundProcess
    let isStopping: Bool
    let onStop: () -> Void
    @State private var showingOutput = false

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s3) {
            HStack(alignment: .top, spacing: Space.s4) {
                mark
                    .frame(width: 14, alignment: .leading)
                    .padding(.top, 2)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: Space.s2) {
                    Text(process.command.isEmpty ? "Process \(process.id)" : process.command)
                        .font(HermesFont.codeSmall)
                        .foregroundStyle(t.text1)
                        .lineLimit(3)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text(facts.joined(separator: "  ·  "))
                        .font(HermesFont.footnote)
                        .hermesNumeric()
                        .foregroundStyle(t.text3)
                        .lineLimit(2)
                }
                if process.isRunning {
                    Button(action: onStop) {
                        if isStopping {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Image(systemName: "stop.circle")
                                .font(.system(size: 20))
                                .foregroundStyle(t.danger)
                        }
                    }
                    .buttonStyle(IconButtonStyle())
                    .disabled(isStopping)
                    .accessibilityLabel("Stop \(process.command.isEmpty ? "this process" : process.command)")
                    .accessibilityIdentifier("session.processes.stop")
                }
            }

            if !tail.isEmpty {
                Button {
                    showingOutput.toggle()
                    HapticFeedback.selection()
                } label: {
                    HStack(spacing: Space.s2) {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 10, weight: .semibold))
                            .rotationEffect(.degrees(showingOutput ? 90 : 0))
                        Text(showingOutput ? "Hide output" : "Show recent output")
                            .font(HermesFont.footnote)
                    }
                    .foregroundStyle(t.text3)
                    .frame(minHeight: Hit.min)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if showingOutput {
                    ScrollView(.horizontal) {
                        Text(tail)
                            .font(HermesFont.codeSmall)
                            .foregroundStyle(t.text2)
                            .textSelection(.enabled)
                            .padding(Space.s4)
                    }
                    .background(t.surface2, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
            }
        }
        .padding(.horizontal, Space.s6)
        .padding(.vertical, Space.s5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .hairline()
    }

    @ViewBuilder
    private var mark: some View {
        if process.isRunning {
            PulsingDot(color: t.ok, size: 7)
        } else if process.exitCode == 0 {
            Image(systemName: "checkmark")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(t.ok)
        } else {
            Text(verbatim: "✕")
                .font(HermesFont.code)
                .foregroundStyle(t.danger)
        }
    }

    private var facts: [String] {
        var facts: [String] = []
        if process.isRunning {
            facts.append("Running")
            if let uptime = process.uptime { facts.append("for \(SessionControlFormat.elapsed(uptime))") }
        } else {
            if let code = process.exitCode {
                facts.append(code == 0 ? "Finished" : "Finished with exit code \(code)")
            } else {
                facts.append("Finished")
            }
            if let exited = process.exitedAt {
                facts.append(exited.formatted(.relative(presentation: .named)))
            }
            if let reason = Self.spokenReason(process.completionReason) { facts.append(reason) }
        }
        if let pid = process.pid { facts.append("pid \(pid)") }
        if !process.cwd.isEmpty { facts.append(HostPath.lastComponent(of: process.cwd)) }
        return facts
    }

    /// The registry's `completion_reason` in words; a plain exit is already said by "Finished", and the raw tokens are not for a reader.
    static func spokenReason(_ reason: String) -> String? {
        switch reason.lowercased() {
        case "", "exited", "completed": return nil
        case "killed", "user_killed": return "stopped by you"
        case "timeout", "timed_out": return "timed out"
        case "interrupted": return "interrupted"
        case "session_reset", "session_closed": return "ended with the session"
        default: return reason.replacingOccurrences(of: "_", with: " ")
        }
    }

    /// The gateway's 4,000-char tail, trimmed; the 200-char preview when the tail is absent.
    private var tail: String {
        let text = process.outputTail.isEmpty ? process.outputPreview : process.outputTail
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
