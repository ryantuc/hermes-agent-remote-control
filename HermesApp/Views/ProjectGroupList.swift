import HermesServeKit
import SwiftUI

/// The hub's Projects mode: repo → worktree lane → sessions, mirroring the
/// desktop's `workspace-groups.ts`. Lane labels copy the desktop's `LaneLabel`
/// trick — ellipsize the head, pin the tail — because branch names share long
/// prefixes and plain end-truncation renders two lanes identically.
///
/// All of the state lives in `ProjectGroupModel` (BUG-005).
@MainActor
struct ProjectGroupList: View {
    @Environment(\.hermes) private var t
    @Environment(AppModel.self) private var app

    let onOpen: (SessionSummary) -> Void

    @State private var model = ProjectGroupModel()

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 0) {
            if model.loading && model.projects.isEmpty {
                HStack(spacing: Space.s4) {
                    ProgressView().controlSize(.small)
                    Text("Loading projects…")
                        .font(HermesFont.footnote)
                        .foregroundStyle(t.text3)
                }
                .padding(Space.s6)
            } else if let loadError = model.loadError {
                VStack(alignment: .leading, spacing: Space.s4) {
                    Text(loadError)
                        .font(HermesFont.footnote)
                        .foregroundStyle(t.danger)
                    Button("Try again") {
                        Task { await model.load(api: app.projectsAPI, force: true) }
                    }
                    .buttonStyle(SecondaryButtonStyle())
                    .frame(maxWidth: 180)
                }
                .padding(Space.s6)
            } else {
                ForEach(model.displayProjects) { project in
                    projectSection(project)
                }
            }
        }
        .task { await model.load(api: app.projectsAPI, force: false) }
        .onDisappear { model.cancelHydration() }
    }

    @ViewBuilder
    private func projectSection(_ project: ProjectsAPI.Project) -> some View {
        SectionHeader(
            project.label,
            count: project.sessionCount,
            isExpanded: model.isExpanded(project.id),
            onToggle: { toggle(project) }
        )
        if let content = model.sectionBody(for: project.id) {
            switch content {
            case .rows(let full):
                ForEach(full.repos) { repo in
                    ForEach(repo.lanes) { lane in
                        laneRows(lane, showLaneLabel: repo.lanes.count > 1 || !lane.isMain)
                    }
                }
            case .error(let message):
                VStack(alignment: .leading, spacing: Space.s4) {
                    Text(message)
                        .font(HermesFont.footnote)
                        .foregroundStyle(t.danger)
                    Button("Try again") {
                        model.ensureHydrated(project.id, api: app.projectsAPI)
                    }
                    .buttonStyle(SecondaryButtonStyle())
                    .frame(maxWidth: 180)
                }
                .padding(.horizontal, Space.s7)
                .padding(.vertical, Space.s3)
            case .loading:
                HStack(spacing: Space.s4) {
                    ProgressView().controlSize(.mini)
                    Text("Loading sessions…")
                        .font(HermesFont.footnote)
                        .foregroundStyle(t.text3)
                }
                .padding(.horizontal, Space.s7)
                .padding(.vertical, Space.s3)
            }
        }
    }

    @ViewBuilder
    private func laneRows(_ lane: ProjectsAPI.Lane, showLaneLabel: Bool) -> some View {
        if showLaneLabel, !lane.label.isEmpty {
            // LaneLabel: head ellipsis, tail pinned — mono, text-3.
            Text(lane.label)
                .font(HermesFont.code)
                .foregroundStyle(t.text3)
                .lineLimit(1)
                .truncationMode(.head)
                .padding(.horizontal, Space.s7)
                .padding(.top, Space.s3)
                .accessibilityLabel("Lane \(lane.label)")
        }
        ForEach(lane.sessions) { session in
            Button {
                onOpen(session)
            } label: {
                FlatRow(showsHairline: false) {
                    Text(session.displayTitle)
                        .font(HermesFont.callout)
                        .foregroundStyle(t.text1)
                        .lineLimit(1)
                        .padding(.leading, Space.s4)
                } trailing: {
                    Text(RelativeTime.short(epochSeconds: session.lastActive))
                        .font(HermesFont.footnote)
                        .hermesNumeric()
                        .foregroundStyle(t.text3)
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel(session.displayTitle)
        }
    }

    private func toggle(_ project: ProjectsAPI.Project) {
        model.toggle(project.id, api: app.projectsAPI)
        HapticFeedback.selection()
    }
}
