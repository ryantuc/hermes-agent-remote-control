import HermesServeKit
import SwiftUI

/// The running-session picker (FEAT-026): the same `session.active_list` signal the Home live dot is gated on, listed rather than counted.
/// Not `LiveActivityRosterSheet`, which lists the chats holding a Lock Screen card; this lists the agents that are running, including desktop, cron and not-yet-persisted ones.
@MainActor
enum LiveSessionPicker {

    /// Every running session, newest first by the live `last_active`, with the durable id breaking ties so two rows sharing a timestamp cannot swap places between polls.
    /// Filtered on `isWorking` rather than "has a row", which is exactly the set the Home dot is computed from, so the list and the dot cannot disagree.
    /// Bot plumbing is filtered because `session.active_list` applies no profile filter, and the persisted row wins over the live one when REST has listed the session (BUG-028).
    static func rows(_ app: AppModel) -> [SessionSummary] {
        let running = app.liveStatuses
            .filter { $0.value.isWorking }
            .sorted { lhs, rhs in
                lhs.value.lastActive == rhs.value.lastActive
                    ? lhs.key < rhs.key
                    : lhs.value.lastActive > rhs.value.lastActive
            }
        var rows: [SessionSummary] = []
        rows.reserveCapacity(running.count)
        for (key, status) in running {
            let live = SessionSummary(fromLive: status)
            guard !app.isBotPlumbing(live) else { continue }
            rows.append(app.threads.first(where: { $0.id == key }) ?? live)
        }
        return rows
    }

    /// BUG-054: `path =` rather than `path.append`, so the picked conversation is the only thing on the stack and Back from it is Home.
    static func open(_ session: SessionSummary, path: inout [AppRoute]) {
        path = [.thread(.existing(session))]
    }

    /// A row's trailing text: the gateway's own status word and the step fraction, routed from `AppModel` rather than recomputed, so surfaces cannot disagree about how far along a session is.
    static func detail(for sessionID: String, in app: AppModel) -> String {
        let label = app.liveWorkingLabel(for: sessionID)
        guard let fraction = app.liveStepFraction(for: sessionID) else { return label }
        return "\(label) · \(fraction)"
    }
}

/// The sheet the Home live dot presents, a sheet and not a pushed page because dismissing a sheet cannot land anywhere but where it was presented from (BUG-054).
@MainActor
struct LiveSessionPickerSheet: View {
    @Environment(\.hermes) private var t
    @Environment(\.dismiss) private var dismiss
    @Environment(AppModel.self) private var app

    /// Handed the picked session: the sheet does not own the navigation path, and Home performs the jump from `onDismiss` in the app's usual dismiss-then-act order.
    let onPick: (SessionSummary) -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    let rows = LiveSessionPicker.rows(app)
                    if rows.isEmpty {
                        emptyState
                    } else {
                        ForEach(rows) { session in
                            Button {
                                onPick(session)
                                dismiss()
                            } label: {
                                row(session)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .background(t.canvas.ignoresSafeArea())
            .navigationTitle("Running now")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationCornerRadius(Radius.sheet)
        .presentationBackground(t.surface)
    }

    /// Row chrome deliberately matches the Continue strip's live row.
    private func row(_ session: SessionSummary) -> some View {
        FlatRow {
            HStack(spacing: Space.s3) {
                PulsingDot(color: t.warn, size: 6)
                VStack(alignment: .leading, spacing: 1) {
                    Text(session.displayTitle)
                        .font(HermesFont.callout)
                        .foregroundStyle(t.text1)
                        .lineLimit(1)
                    if !session.preview.isEmpty {
                        Text(session.preview)
                            .font(HermesFont.footnote)
                            .foregroundStyle(t.text3)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
            }
        } trailing: {
            Text(LiveSessionPicker.detail(for: session.id, in: app))
                .font(HermesFont.footnote)
                .hermesNumeric()
                .foregroundStyle(t.warn)
        }
    }

    /// The dot is gated on something running, so this is not reachable in the steady state, but a turn can end while the sheet is up.
    private var emptyState: some View {
        VStack(alignment: .leading, spacing: Space.s5) {
            Text("Nothing is running right now.")
                .font(HermesFont.body)
                .foregroundStyle(t.text2)
            Text("A session appears here while an agent is working on it or waiting on you — including runs started from the desktop or by a schedule.")
                .font(HermesFont.footnote)
                .foregroundStyle(t.text3)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, Space.s6)
        .padding(.top, Space.s9)
    }
}
