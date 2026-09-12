import HermesServeKit
import SwiftUI

/// The navigation hub, top to bottom: backend row, New conversation, search, history, Settings pinned to the bottom.
@MainActor
struct NavigationHubView: View {
    @Environment(\.hermes) private var t
    @Environment(AppModel.self) private var app

    @Binding var path: [AppRoute]
    @Binding var isPresented: Bool
    /// Which top-level surface the shell is on; a binding rather than a value because `RootView` owns the state and the hub never writes it.
    @Binding var mode: AppMode

    @State private var actionTarget: SessionSummary?
    /// The rename alert is presented from the action sheet's onDismiss, never in the same action that clears `actionTarget`.
    @State private var queuedRename: SessionSummary?
    @State private var renameTarget: SessionSummary?
    @State private var renameText: String = ""

    var body: some View {
        @Bindable var app = app

        VStack(alignment: .leading, spacing: 0) {
            backendRow

            // Sessions-only: a bot's thread is opened rather than started, and these controls act on `app.threads`, which is not what the roster is made of.
            if mode == .sessions {
                newConversationRow
                    .padding(.horizontal, Space.s4)
                    .padding(.top, Space.s4)

                if !app.threads.isEmpty {
                    searchField
                        .padding(.horizontal, Space.s6)
                        .padding(.top, Space.s5)
                }
            }

            history

            commandCenterRow
            settingsRow
        }
        .background(t.surface)
        .sheet(item: $actionTarget, onDismiss: {
            if let queued = queuedRename {
                queuedRename = nil
                renameTarget = queued
                renameText = queued.title ?? ""
            }
        }) { thread in
            rowActions(thread)
        }
        .alert("Rename conversation", isPresented: renameBinding) {
            TextField("Title", text: $renameText)
            Button("Cancel", role: .cancel) { renameTarget = nil }
            Button("Save") {
                if let target = renameTarget {
                    let title = renameText
                    Task { await app.renameThread(target, to: title) }
                }
                renameTarget = nil
            }
        } message: {
            Text("Titles are stored on the backend and sync to every Hermes client.")
        }
    }

    // MARK: Backend row — the app's identity line

    private var backendRow: some View {
        HubBackendRow(
            title: backendTitle,
            subtitle: backendSubtitle,
            dot: stateDot
        ) {
            navigate(to: [.settings, .settingsBackend])
        }
    }

    /// One computed name on the model, so this row says Demo while the demo runs rather than naming the backend it is standing in front of.
    private var backendTitle: String {
        app.backendDisplayName ?? "No backend"
    }

    private var backendSubtitle: String {
        switch app.connectionState {
        case .open:
            var parts = ["Connected"]
            if let version = app.serverStatus?.version, !version.isEmpty { parts.append("v\(version)") }
            return parts.joined(separator: " · ")
        case .connecting: return "Connecting…"
        case .reconnecting(let attempt, _): return "Reconnecting (attempt \(attempt))…"
        case .offline: return "Offline"
        case .unauthorized: return "Sign-in required"
        case .idle: return "Not connected"
        }
    }

    private var stateDot: Color {
        switch app.connectionState {
        case .open: return t.ok
        case .connecting, .reconnecting: return t.warn
        case .offline, .unauthorized: return t.danger
        case .idle: return t.text4
        }
    }

    // MARK: New conversation

    private var newConversationRow: some View {
        Button {
            navigate(to: [])
        } label: {
            HStack(spacing: Space.s4) {
                Image(systemName: "square.and.pencil")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(t.text1)
                Text("New conversation")
                    .font(HermesFont.callout)
                    .foregroundStyle(t.text1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Space.s5)
            .frame(minHeight: Hit.min)
            .background(
                path.isEmpty ? t.fill3 : .clear,
                in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: Search — the flat underline field

    private var searchField: some View {
        @Bindable var app = app
        return HStack(spacing: Space.s3) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13))
                .foregroundStyle(t.text4)
            TextField("Search", text: $app.searchText)
                .font(HermesFont.callout)
                .foregroundStyle(t.text1)
                .autocorrectionDisabled()
            if !app.searchText.isEmpty {
                Button {
                    app.searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(t.text4)
                        .frame(width: Hit.min, height: Hit.min)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .frame(minHeight: Hit.min)
        .hairline()
    }

    // MARK: History — Sessions / Projects (phases 4 + 7), or the Bots roster

    /// Sessions-vs-Projects grouping and only that: its two values are written into an installed app's defaults, and the app mode lives under its own key (`AppMode.launchModeStorageKey`).
    @AppStorage("hermes.hub.mode") private var groupingMode = "Sessions"

    /// The scroller between the identity line and the pinned footer; the roster renders inside this same region, because a nested scroller would put its last rows under that footer (BUG-043).
    private var history: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if mode == .bots {
                    BotRosterList { bot in
                        navigate(to: [.thread(.bot(bot.threadRef))])
                    }
                    .padding(.bottom, Space.s6)
                } else {
                    if !app.threads.isEmpty {
                        SegmentedRow(
                            options: ["Sessions", "Projects"],
                            selection: $groupingMode,
                            label: { $0 }
                        )
                        .padding(.horizontal, Space.s6)
                        .padding(.top, Space.s4)
                    }

                    if groupingMode == "Projects" {
                        ProjectGroupList(
                            onOpen: { thread in navigate(to: [.thread(.existing(thread))]) }
                        )
                        .padding(.bottom, Space.s6)
                    } else {
                        HistoryGroupList(
                            onOpen: { thread in navigate(to: [.thread(.existing(thread))]) },
                            onLongPress: { thread in actionTarget = thread }
                        )
                        .padding(.bottom, Space.s6)
                    }
                }
            }
        }
        .frame(maxHeight: .infinity)
    }

    // MARK: Command Center + Settings — pinned to the bottom (spec §3)

    private var commandCenterRow: some View {
        bottomRow(icon: "gauge.with.needle", label: "Command Center") {
            navigate(to: [.commandCenter])
        }
    }

    private var settingsRow: some View {
        bottomRow(icon: "gearshape", label: "Settings") {
            navigate(to: [.settings])
        }
    }

    /// One pinned row. Named rather than a literal because the history above has to be inset by the footer these two rows make, and a layout inset derived from a number typed twice is a layout inset that drifts (BUG-043).
    static let pinnedRowHeight: CGFloat = 50

    private func bottomRow(icon: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: Space.s4) {
                Image(systemName: icon)
                    .font(.system(size: 15))
                    .foregroundStyle(t.text2)
                Text(label)
                    .font(HermesFont.callout)
                    .foregroundStyle(t.text1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Space.s6)
            .frame(height: Self.pinnedRowHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hairline(.top)
    }

    // MARK: Row actions — long-press

    private func rowActions(_ thread: SessionSummary) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(thread.displayTitle)
                .font(HermesFont.heading)
                .foregroundStyle(t.text1)
                .lineLimit(1)
                .padding(.horizontal, Space.s6)
                .padding(.top, Space.s6)
                .padding(.bottom, Space.s5)

            Button {
                let target = thread
                actionTarget = nil
                Task { await app.setPinned(target, pinned: !target.pinned) }
            } label: {
                FlatRow {
                    Text(thread.pinned ? "Unpin" : "Pin").font(HermesFont.callout).foregroundStyle(t.text1)
                } trailing: {
                    EmptyView()
                }
            }
            .buttonStyle(.plain)

            Button {
                // Dismiss, then present: the alert fires from onDismiss.
                queuedRename = thread
                actionTarget = nil
            } label: {
                FlatRow {
                    Text("Rename").font(HermesFont.callout).foregroundStyle(t.text1)
                } trailing: {
                    EmptyView()
                }
            }
            .buttonStyle(.plain)

            Button {
                let target = thread
                actionTarget = nil
                Task { await app.setArchived(target, archived: !target.archived) }
            } label: {
                FlatRow {
                    Text(thread.archived ? "Unarchive" : "Archive").font(HermesFont.callout).foregroundStyle(t.text1)
                } trailing: {
                    EmptyView()
                }
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: Space.s4) {
                HoldToConfirmButton("Hold to delete") {
                    let target = thread
                    actionTarget = nil
                    Task { await app.deleteThread(target) }
                }
                Text("This removes the conversation and its transcript from the backend. It cannot be undone.")
                    .font(HermesFont.footnote)
                    .foregroundStyle(t.text3)
            }
            .padding(Space.s6)

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(t.surface)
        .presentationDetents([.height(400)])
        .presentationDragIndicator(.hidden)
        .presentationCornerRadius(Radius.sheet)
        .presentationBackground(t.surface)
    }

    private var renameBinding: Binding<Bool> {
        Binding(get: { renameTarget != nil }, set: { if !$0 { renameTarget = nil } })
    }

    // MARK: Navigation

    /// Every hub destination closes the drawer and rewrites the path — the hub is an overlay over the stack, not a member of it.
    private func navigate(to newPath: [AppRoute]) {
        path = newPath
        isPresented = false
    }
}

/// The hub's identity line — the backend name over its connection state, the whole row a button into Backend settings.
///
/// 56 pt is a resting height and a floor, never a cap: `.frame(height:)` does not clip, so at accessibility content sizes the stacked labels drew through the bottom of the row (FEAT-008).
@MainActor
struct HubBackendRow: View {
    @Environment(\.hermes) private var t

    /// What the row measures at the default content size category, and the floor it never drops below.
    static let restingHeight: CGFloat = 56

    let title: String
    let subtitle: String
    let dot: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: Space.s4) {
                Circle()
                    .fill(dot)
                    .frame(width: 8, height: 8)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: Space.s1) {
                    Text(title)
                        .font(HermesFont.calloutStrong)
                        .foregroundStyle(t.text1)
                        .lineLimit(1)
                    Text(subtitle)
                        .font(HermesFont.footnote)
                        .foregroundStyle(t.text3)
                        .lineLimit(1)
                }
                Spacer(minLength: Space.s4)
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(t.text4)
            }
            .padding(.horizontal, Space.s6)
            .frame(minHeight: Self.restingHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hairline()
        .accessibilityLabel("Backend: \(title), \(subtitle)")
        .accessibilityHint("Opens backend settings")
    }
}
