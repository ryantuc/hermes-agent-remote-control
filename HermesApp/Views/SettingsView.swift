import ActivityKit
import HermesServeKit
import SwiftUI

/// One row on the Settings root.
struct SettingsRootRow: Identifiable, Equatable {
    let label: String
    let destination: AppRoute
    var id: String { label }
}

/// One group on the Settings root.
struct SettingsRootSection: Identifiable, Equatable {
    let title: String
    /// Rides the header line: which backend these rows belong to.
    var note: String?
    /// One sentence under the group, shown only when its rows cannot act.
    var footer: String?
    /// `false` greys every row in the group and shows the footer; the rows stay on screen, since a greyed row teaches the reader what to connect.
    var isEnabled: Bool = true
    let rows: [SettingsRootRow]
    var id: String { title }
}

/// The Settings root's tree, grouped by whose setting it is: Backend and Agent belong to the backend, This phone to the device, Browse and About to neither.
enum SettingsTree {
    /// The Agent group's one sentence when there is no backend to configure, the same words `SettingsStore` writes into `writeFailures` in that state (BUG-096).
    static let agentDisconnectedFooter = "Connect a backend to change these."

    /// The root's sections; `isConnected` is `AppModel.rest != nil`, which is false with no profile and false in the demo.
    static func sections(
        backendNote: String,
        isConnected: Bool,
        showAdvanced: Bool
    ) -> [SettingsRootSection] {
        var agentRows: [SettingsRootRow] = [
            SettingsRootRow(label: "Model & reasoning", destination: .settingsScreen(.modelReasoning)),
            SettingsRootRow(label: "Personality", destination: .settingsScreen(.personality)),
            SettingsRootRow(label: "Workspace", destination: .settingsScreen(.workspace)),
            SettingsRootRow(label: "Safety & approvals", destination: .settingsScreen(.safety)),
            SettingsRootRow(label: "Memory & context", destination: .settingsScreen(.memory)),
            SettingsRootRow(label: "Capabilities", destination: .settingsScreen(.capabilities)),
            SettingsRootRow(label: "Messaging", destination: .settingsScreen(.messaging)),
        ]
        if showAdvanced {
            agentRows.append(
                SettingsRootRow(label: "Advanced", destination: .settingsScreen(.advanced))
            )
        }

        return [
            SettingsRootSection(
                title: "Backend",
                note: backendNote,
                rows: [
                    SettingsRootRow(label: "Backend", destination: .settingsBackend),
                    SettingsRootRow(label: "Command Center", destination: .commandCenter),
                ]
            ),
            SettingsRootSection(
                title: "Agent",
                footer: isConnected ? nil : agentDisconnectedFooter,
                isEnabled: isConnected,
                rows: agentRows
            ),
            SettingsRootSection(
                title: "This phone",
                rows: [
                    SettingsRootRow(label: "Appearance", destination: .settingsAppearance),
                    SettingsRootRow(label: "Chat", destination: .settingsScreen(.chat)),
                    SettingsRootRow(label: "Voice", destination: .settingsScreen(.voice)),
                    SettingsRootRow(
                        label: "Notifications & Live Activities",
                        destination: .settingsScreen(.notifications)
                    ),
                ]
            ),
            SettingsRootSection(
                title: "Browse",
                rows: [
                    SettingsRootRow(label: "Artifacts", destination: .settingsScreen(.artifacts)),
                ]
            ),
            SettingsRootSection(
                title: "About",
                rows: [
                    SettingsRootRow(label: "About HARC", destination: .settingsScreen(.about)),
                ]
            ),
        ]
    }
}

/// Settings root: a destination, not an overlay — an overlay stack on a phone loses the back gesture.
@MainActor
struct SettingsView: View {
    @Environment(\.hermes) private var t
    @Environment(AppModel.self) private var app
    @Environment(Theme.self) private var theme

    @Binding var path: [AppRoute]

    private var store: SettingsStore { app.settings }

    /// `rest` is non-nil from the moment a profile is activated, so this is false for a fresh install and inside the demo, and true for a backend that is merely offline.
    private var isConnected: Bool { app.rest != nil }

    private var sections: [SettingsRootSection] {
        SettingsTree.sections(
            backendNote: backendHeaderNote,
            isConnected: isConnected,
            showAdvanced: store.showAdvanced
        )
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                let tree = sections
                ForEach(tree) { section in
                    sectionView(section, isFirst: section.id == tree.first?.id)
                }
            }
            .padding(.bottom, Space.s10)
        }
        .background(t.canvas)
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        .hermesTopBar()
        .task { await store.loadIfNeeded() }
    }

    @ViewBuilder
    private func sectionView(_ section: SettingsRootSection, isFirst: Bool) -> some View {
        SectionHeader(section.title, note: section.note)
            .padding(.top, isFirst ? Space.settingsTop : Space.s8)

        ForEach(section.rows) { row in
            valueRow(row, isEnabled: section.isEnabled)
        }

        if let footer = section.footer {
            Text(footer)
                .font(HermesFont.footnote)
                .foregroundStyle(t.text3)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, Space.s6)
                .padding(.top, Space.s3)
        }
    }

    // MARK: Row summaries — the spec's at-a-glance values

    /// The at-a-glance value for a row, keyed on where it goes.
    private func summary(for destination: AppRoute) -> String {
        switch destination {
        case .settingsBackend:
            return backendValue
        case .settingsAppearance:
            return appearanceValue
        case .settingsScreen(let id):
            switch id {
            case .modelReasoning: return modelReasoningValue
            case .personality: return personalityValue
            case .workspace: return workspaceValue
            case .safety: return safetyValue
            case .memory: return memoryValue
            case .advanced: return advancedValue
            case .capabilities: return "Skills, tools, MCP"
            case .messaging: return messagingValue
            case .artifacts: return "Recent output"
            case .chat: return chatValue
            case .voice: return voiceValue
            case .notifications: return notificationsValue
            case .about: return aboutValue
            // Reached from the Chat screen, never from this root. Named rather than defaulted (BUG-146), so a new settings screen is a compile error here instead of a row with a blank value.
            case .transcript, .composerActions: return ""
            }
        // Command Center and Diagnostics are screens, not settings: neither has one value worth naming on the way in.
        default:
            return ""
        }
    }

    /// What the Backend header says the rest of the screen is about: the host rather than the profile's display name, which the row underneath already carries.
    private var backendHeaderNote: String {
        if app.isDemoActive { return "Demo" }
        guard let profile = app.activeProfile else { return "No backend" }
        if let configuration = try? profile.makeConfiguration() { return configuration.displayHost }
        return profile.displayName
    }

    /// The launch posture, which is the first row on the Chat screen.
    @AppStorage(AppMode.launchModeStorageKey) private var launchMode = AppMode.sessions.rawValue

    private var chatValue: String {
        "Opens in \(AppMode.launchMode(stored: launchMode).label)"
    }

    /// Dictation ships on by default, so the row says which engine is in play rather than on or off.
    private var voiceValue: String {
        VoicePreferences.engine.label
    }

    /// The system switch outranks ours: a master toggle that reads "On" while iOS has Live Activities turned off for this app is a lie on the row.
    private var notificationsValue: String {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return "Off in iOS" }
        return LiveActivityPreferences.presentationAllowed ? "Live Activities on" : "Live Activities off"
    }

    private var backendValue: String {
        let name = app.activeProfile?.displayName ?? ""
        return name.isEmpty ? "None" : name
    }

    private var modelReasoningValue: String {
        let model = store.stringValue("model") ?? ""
        let effort = store.stringValue("agent.reasoning_effort") ?? ""
        let shortModel = model.split(separator: "/").last.map(String.init) ?? model
        if shortModel.isEmpty { return "" }
        return effort.isEmpty ? shortModel : "\(shortModel) · \(effort)"
    }

    private var personalityValue: String {
        let raw = store.stringValue("display.personality") ?? ""
        return raw.isEmpty || raw == "none" ? "None" : raw.capitalized
    }

    private var messagingValue: String {
        guard let status = app.serverStatus else { return "" }
        let count = status.raw["gateway_platforms"]?.objectValue?.count ?? 0
        guard count > 0 else { return "" }
        return count == 1 ? "1 platform" : "\(count) platforms"
    }

    private var workspaceValue: String {
        let cwd = store.stringValue("terminal.cwd") ?? ""
        return (cwd as NSString).abbreviatingWithTildeInPath
    }

    private var safetyValue: String {
        (store.stringValue("approvals.mode") ?? "").capitalized
    }

    private var memoryValue: String {
        guard let enabled = store.boolValue("memory.memory_enabled") else { return "" }
        return enabled ? "On" : "Off"
    }

    private var advancedValue: String {
        store.stringListValue("toolsets")?.joined(separator: ", ") ?? ""
    }

    private var appearanceValue: String {
        // BUG-046: the skin that is painted, not the one that is remembered, since while Follow is on those differ.
        let skin = theme.effectiveSkinLabel
        let polarity: String
        switch theme.polarityPreference {
        case .system: polarity = "System"
        case .light: polarity = "Light"
        case .dark: polarity = "Dark"
        }
        return "\(skin) · \(polarity)"
    }

    private var aboutValue: String {
        guard let version = app.serverStatus?.version, !version.isEmpty else { return "" }
        return "v\(version)"
    }

    private func valueRow(_ row: SettingsRootRow, isEnabled: Bool) -> some View {
        let value = summary(for: row.destination)
        return Button {
            path.append(row.destination)
        } label: {
            SettingsValueRowLabel(label: row.label, value: value, isEnabled: isEnabled)
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .accessibilityLabel("\(row.label): \(value)")
    }
}

/// The Value row kind on the Settings root: label · value · chevron. Drawn apart from the button that carries it so a test can render one without an `AppModel`.
struct SettingsValueRowLabel: View {
    @Environment(\.hermes) private var t

    let label: String
    let value: String
    /// A disabled row keeps both texts and drops its label to `controlDisabledInk`, the rung every disabled control's words take. It used to fade the whole row to 45 %, which put the label at 2.6:1 in light and the `text3` value under 2:1; the row names a screen the reader is being taught exists, so it stays readable.
    let isEnabled: Bool

    var body: some View {
        FlatRow {
            Text(label)
                .font(HermesFont.callout)
                .foregroundStyle(isEnabled ? t.text1 : t.controlDisabledInk)
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
}
