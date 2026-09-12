import SwiftUI

/// Settings → This phone → Chat (FEAT-031): the four choices that shape a conversation on this device, none of which goes near the backend's configuration document.
@MainActor
struct ChatSettingsView: View {
    @Environment(\.hermes) private var t

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                openInRow
                projectStickinessRow
                linkRow(
                    label: "Composer actions",
                    value: composerActionsValue,
                    destination: .settingsScreen(.composerActions)
                )
                linkRow(
                    label: "Transcript",
                    value: transcriptValue,
                    destination: .settingsScreen(.transcript)
                )
            }
            .padding(.top, Space.s4)
            .padding(.bottom, Space.s10)
        }
        .background(t.canvas)
        .navigationTitle("Chat")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(t.canvas, for: .navigationBar)
    }

    // MARK: Open in — the launch mode

    /// Which of the two top-level surfaces the app opens on: the launch posture, not a memory of where the user was last.
    /// Rendered inline rather than as a `SettingRowDescriptor`, because that tree renders a row only while its key is present in the backend's config document and this value never goes near the backend.
    @AppStorage(AppMode.launchModeStorageKey) private var launchMode = AppMode.sessions.rawValue

    private var openInRow: some View {
        VStack(alignment: .leading, spacing: Space.s3) {
            Text("Open in")
                .font(HermesFont.callout)
                .foregroundStyle(t.text1)
            SegmentedRow(
                options: AppMode.allCases,
                selection: Binding(
                    get: { AppMode.launchMode(stored: launchMode) },
                    set: { launchMode = $0.rawValue }
                ),
                label: { $0.label }
            )
            Text("Which screen the app lands on when you open it. Switching with the control in the top bar does not change this.")
                .font(HermesFont.footnote)
                .foregroundStyle(t.text3)
        }
        .padding(.horizontal, Space.s6)
        .padding(.vertical, Space.s4)
        .hairline()
    }

    // MARK: Reuse last project — the stickiness window (FEAT-028)

    /// How long a project pick keeps seeding new conversations.
    @AppStorage(ProjectStickiness.storageKey) private var projectStickiness = ProjectStickiness.fallback.rawValue

    private var projectStickinessRow: some View {
        VStack(alignment: .leading, spacing: Space.s3) {
            Text("Reuse last project")
                .font(HermesFont.callout)
                .foregroundStyle(t.text1)
            SegmentedRow(
                options: ProjectStickiness.allCases,
                selection: Binding(
                    get: { ProjectStickiness(rawValue: projectStickiness) ?? .fallback },
                    set: { projectStickiness = $0.rawValue }
                ),
                label: { $0.label }
            )
            Text(projectStickinessExplainer)
                .font(HermesFont.footnote)
                .foregroundStyle(t.text3)
        }
        .padding(.horizontal, Space.s6)
        .padding(.vertical, Space.s4)
        .hairline()
    }

    private var projectStickinessExplainer: String {
        switch ProjectStickiness(rawValue: projectStickiness) ?? .fallback {
        case .off:
            return "A new conversation always starts in the backend's default folder, whatever you were last working in."
        case .always:
            return "A new conversation starts in the project you last worked in, however long ago that was."
        case .tenMinutes:
            return "A new conversation starts in the project you last worked in, for ten minutes after you last used it. Then it goes back to the backend's default folder."
        case .oneHour:
            return "A new conversation starts in the project you last worked in, for an hour after you last used it. Then it goes back to the backend's default folder."
        }
    }

    // MARK: The two pushed screens

    private var composerActionsValue: String {
        let count = ComposerQuickAction.enabled.count
        return count == 1 ? "1 shown" : "\(count) shown"
    }

    private var transcriptValue: String {
        TranscriptPreferences.groupRepeatedCalls ? "Grouped calls" : "Every call"
    }

    private func linkRow(label: String, value: String, destination: AppRoute) -> some View {
        NavigationLink(value: destination) {
            FlatRow {
                Text(label)
                    .font(HermesFont.callout)
                    .foregroundStyle(t.text1)
            } trailing: {
                HStack(spacing: Space.s3) {
                    Text(value)
                        .font(HermesFont.subhead)
                        .foregroundStyle(t.text3)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(t.text4)
                }
                .frame(maxWidth: 190, alignment: .trailing)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(label): \(value)")
    }
}
