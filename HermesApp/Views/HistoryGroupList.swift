import HermesServeKit
import SwiftUI

/// The hub's grouped history: Pinned / Live / Recents / one group per messaging
/// platform / Cron / Archived, in that fixed order. An empty group is removed,
/// never rendered as zero; a search query flattens everything into one list.
@MainActor
struct HistoryGroupList: View {
    @Environment(\.hermes) private var t
    @Environment(AppModel.self) private var app
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let onOpen: (SessionSummary) -> Void
    let onLongPress: (SessionSummary) -> Void

    /// Expansion overrides; a group absent here uses its default.
    @State private var expansionOverrides: [String: Bool] = Self.loadOverrides()

    private static let overridesKey = "hermes.history.expansion"

    var body: some View {
        let query = app.searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if query.isEmpty {
            groupedList
        } else {
            flatResults
        }
    }

    // MARK: Grouped

    private var groupedList: some View {
        let groups = HistoryGrouping.groups(from: app.hubSessions)
        return LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(groups) { group in
                SectionHeader(
                    group.title,
                    count: group.sessions.count,
                    isExpanded: isExpanded(group),
                    onToggle: { toggle(group) }
                )
                if isExpanded(group) {
                    ForEach(group.sessions) { thread in
                        row(thread, showsSourceBadge: group.isMixed)
                    }
                }
            }
        }
    }

    private var flatResults: some View {
        LazyVStack(alignment: .leading, spacing: 0) {
            if app.filteredThreads.isEmpty {
                Text("Nothing matches “\(app.searchText)”")
                    .font(HermesFont.subhead)
                    .foregroundStyle(t.text3)
                    .padding(Space.s6)
            } else {
                ForEach(app.filteredThreads) { thread in
                    row(thread, showsSourceBadge: true)
                }
            }
        }
    }

    // MARK: Rows — 48 pt minimum, indented to clear the caret

    private func row(_ thread: SessionSummary, showsSourceBadge: Bool) -> some View {
        Button {
            onOpen(thread)
        } label: {
            HStack(spacing: Space.s3) {
                toneDot(thread)
                VStack(alignment: .leading, spacing: Space.s1) {
                    Text(thread.displayTitle)
                        .font(HermesFont.callout)
                        .foregroundStyle(t.text1)
                        .lineLimit(1)
                    Text(meta(thread, showsSourceBadge: showsSourceBadge))
                        .font(HermesFont.subhead)
                        .foregroundStyle(t.text3)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.leading, Space.s6 + Space.s5)
            .padding(.trailing, Space.s6)
            .padding(.vertical, Space.s4)
            .frame(minHeight: Hit.commit, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onLongPressGesture(minimumDuration: 0.4) {
            HapticFeedback.selection()
            onLongPress(thread)
        }
        .accessibilityLabel(thread.displayTitle)
        .accessibilityHint("Double tap to open. Touch and hold for actions.")
    }

    /// Live → pulsing warn; pinned → text-3; otherwise none. (Waiting-for-
    /// approval needs approval events per session, which the hub does not
    /// receive; the chat surface owns that signal.)
    @ViewBuilder
    private func toneDot(_ thread: SessionSummary) -> some View {
        if app.isLiveWorking(thread.id) {
            PulsingDot(color: t.warn, size: 6)
        } else if thread.pinned {
            Circle().fill(t.text3).frame(width: 6, height: 6)
        }
    }

    private func meta(_ thread: SessionSummary, showsSourceBadge: Bool) -> String {
        var parts: [String] = []
        if app.isLiveWorking(thread.id) {
            // The gateway's own word for what the session is doing —
            // `waiting` / `starting` / `working`.
            parts.append(app.liveStatus(forStoredID: thread.id)?.status ?? "working")
        } else {
            parts.append(RelativeTime.short(epochSeconds: thread.lastActive))
        }
        if showsSourceBadge, let label = SessionSource.label(thread.source) {
            parts.append(label)
        }
        return parts.joined(separator: " · ")
    }

    // MARK: Expansion persistence

    private func isExpanded(_ group: SessionGroup) -> Bool {
        expansionOverrides[group.id] ?? group.defaultExpanded
    }

    private func toggle(_ group: SessionGroup) {
        withAnimation(reduceMotion ? nil : Motion.quick) {
            expansionOverrides[group.id] = !isExpanded(group)
        }
        UserDefaults.standard.set(expansionOverrides, forKey: Self.overridesKey)
        HapticFeedback.selection()
    }

    private static func loadOverrides() -> [String: Bool] {
        (UserDefaults.standard.dictionary(forKey: overridesKey) as? [String: Bool]) ?? [:]
    }
}
