import HermesServeKit
import SwiftUI

/// One delegated agent, pushed from the agent tree: what the parent knows about it, the end of its own live transcript (`subagent.tail`), and the two things a person can do to it from a phone, send it a message or stop it.
/// Content inside a sheet, so opaque; only the bar is chrome.
@MainActor
struct SubagentDetailView: View {
    @Environment(\.hermes) private var t
    @Environment(AppModel.self) private var app: AppModel?

    let id: String
    let rows: [SubagentRow]

    @State private var tail: SubagentRosterModel.TailOutcome?
    @State private var draft = ""
    @State private var isWorking = false
    @State private var feedback: SubagentRosterModel.ControlOutcome?
    @State private var confirmingStop = false

    /// Desktop refreshes an open transcript on the same interval.
    static let tailInterval: UInt64 = 2_000_000_000

    private var row: SubagentRow? { rows.first { $0.id == id } }
    private var roster: SubagentRosterModel? {
        guard let app, let row, !row.sessionID.isEmpty else { return nil }
        return app.chat(runtimeSessionID: row.sessionID)?.subagentRoster
    }

    var body: some View {
        Group {
            if let row {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        SubagentDetailRow(row: row, level: 0)
                        if tail != .unsupported, !row.wireSubagentID.isEmpty {
                            liveOutput(row)
                        }
                        if !row.isTerminal, !row.wireSubagentID.isEmpty, let app, let roster {
                            controls(row, app: app, roster: roster)
                        }
                    }
                }
                .task(id: row.isTerminal) { await followTail() }
            } else {
                StatePanel(symbol: "checkmark.circle", title: "This agent is no longer listed",
                           message: "Finished agents leave the list when the next turn starts.")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(t.surface)
        .navigationTitle("Agent")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .hermesTopBar()
        .confirmationDialog(row?.originUnknown == true ? "Stop this agent?" : "Stop an agent this phone didn't start?",
                            isPresented: $confirmingStop, titleVisibility: .visible) {
            Button("Stop agent", role: .destructive) { performStop() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(row?.originUnknown == true
                 ? "HARC can't tell which window started this agent. Stopping it ends its work for everyone watching this chat."
                 : "Another window started this agent. Stopping it ends its work for everyone watching this chat.")
        }
    }

    // MARK: Live output

    private func liveOutput(_ row: SubagentRow) -> some View {
        VStack(alignment: .leading, spacing: Space.s3) {
            HStack(alignment: .firstTextBaseline) {
                Text("Live output")
                    .font(HermesFont.footnote)
                    .foregroundStyle(t.text3)
                Spacer(minLength: Space.s4)
                if case .some(.text(_, let truncated)) = tail, truncated {
                    Text("Last 16 KB")
                        .font(HermesFont.footnote)
                        .foregroundStyle(t.text4)
                }
            }
            switch tail {
            case .some(.text(let text, _)):
                // Its own short scroll, pinned to the newest line, so the page around it does not have to scroll to the bottom of 16 KB.
                ScrollView {
                    Text(text)
                        .font(HermesFont.codeSmall)
                        .foregroundStyle(t.text2)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(Space.s5)
                }
                .defaultScrollAnchor(.bottom)
                .frame(maxHeight: 280)
                .background(t.fill1, in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
                .accessibilityLabel("Live output")
            case .some(.unavailable):
                Text(row.isTerminal ? "It has finished, and its live output is gone." : "No live output to show yet. It appears here once the agent writes some.")
                    .font(HermesFont.subhead)
                    .foregroundStyle(t.text3)
                    .fixedSize(horizontal: false, vertical: true)
            case .some(.unsupported), .none:
                Text("Reading its output…")
                    .font(HermesFont.subhead)
                    .foregroundStyle(t.text3)
            }
        }
        .padding(.horizontal, Space.s6)
        .padding(.vertical, Space.s5)
        .hairline()
    }

    /// Read now and then every two seconds while the agent works; a finished one gets a last read and no more.
    private func followTail() async {
        guard let app, let roster else { return }
        while !Task.isCancelled {
            guard let current = row else { return }
            let outcome = await roster.tail(app: app, row: current)
            guard !Task.isCancelled else { return }
            tail = outcome
            if outcome == .unsupported || current.isTerminal { return }
            try? await Task.sleep(nanoseconds: Self.tailInterval)
        }
    }

    // MARK: Steer and stop

    private func controls(_ row: SubagentRow, app: AppModel, roster: SubagentRosterModel) -> some View {
        VStack(alignment: .leading, spacing: Space.s4) {
            if roster.canSteer(app: app, row: row) {
                Text("Message this agent")
                    .font(HermesFont.footnote)
                    .foregroundStyle(t.text3)
                TextField("For example: skip the tests and summarise", text: $draft, axis: .vertical)
                    .font(HermesFont.body)
                    .lineLimit(1...4)
                    .padding(Space.s5)
                    .enclosure()
                    .accessibilityIdentifier("subagent.steer.field")
                Button("Send to agent") { performSteer() }
                    .buttonStyle(PrimaryButtonStyle(height: Hit.min))
                    .disabled(isWorking || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("subagent.steer.send")
                Text("It reads the message before its next step; a step already running is not cut short.")
                    .font(HermesFont.footnote)
                    .foregroundStyle(t.text4)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button("Stop this agent") {
                if row.startedByThisClient { performStop() } else { confirmingStop = true }
            }
            .buttonStyle(DangerButtonStyle(height: Hit.min))
            .disabled(isWorking)
            .accessibilityIdentifier("subagent.stop")

            if let feedback {
                switch feedback {
                case .done(let text):
                    Text(text).font(HermesFont.subhead).foregroundStyle(t.text2)
                case .refused(let text):
                    Text(text).font(HermesFont.subhead).foregroundStyle(t.danger)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.horizontal, Space.s6)
        .padding(.vertical, Space.s6)
    }

    private func performSteer() {
        guard let app, let roster, let row else { return }
        let text = draft
        isWorking = true
        Task {
            let outcome = await roster.steer(app: app, row: row, text: text)
            if case .done = outcome { draft = "" }
            feedback = outcome
            isWorking = false
        }
    }

    private func performStop() {
        guard let app, let roster, let row else { return }
        isWorking = true
        Task {
            feedback = await roster.stop(app: app, row: row)
            isWorking = false
        }
    }
}
