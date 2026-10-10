import HermesServeKit
import SwiftUI

/// Settings → Workspace → Messaging: a status page, not an
/// editor. Platform rows with a connection dot, configured state, and an
/// enable toggle. Adding a bot token means pasting a secret into an env
/// file — the page says so once, at the bottom, and stays honest about it.
@MainActor
struct MessagingStatusView: View {
    @Environment(\.hermes) private var t
    @Environment(AppModel.self) private var app

    @State private var platforms: [PlatformRow] = []
    @State private var envPath = ""
    @State private var loadError: String?
    @State private var loaded = false
    @State private var rowErrors: [String: String] = [:]

    struct PlatformRow: Identifiable {
        let id: String
        let name: String
        let description: String
        let configured: Bool
        let state: String
        let errorMessage: String
        var enabled: Bool
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if let loadError {
                    StatePanel.loadFailure(title: "Couldn't load platforms", error: loadError, hasBackend: app.rest != nil) {
                        Task { await load() }
                    }
                    .containerRelativeFrame(.vertical)
                } else {
                    ForEach(platforms) { platform in
                        platformRow(platform)
                    }
                    if !platforms.isEmpty {
                        footer
                    }
                }
            }
            .padding(.bottom, Space.s10)
        }
        .background(t.canvas)
        .navigationTitle("Messaging")
        .navigationBarTitleDisplayMode(.inline)
        .hermesTopBar()
        .task { await loadIfNeeded() }
        .refreshable { await load() }
    }

    private func platformRow(_ platform: PlatformRow) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            SwitchRow(
                platform.name,
                subtitle: subtitle(for: platform),
                isOn: Binding(
                    get: { platform.enabled },
                    set: { newValue in Task { await setEnabled(platform.id, enabled: newValue) } }
                )
            )
            .overlay(alignment: .topLeading) {
                Circle()
                    .fill(stateColor(platform))
                    .frame(width: 7, height: 7)
                    .offset(x: Space.s2, y: 22)
                    .accessibilityHidden(true)
            }
            if let error = rowErrors[platform.id] {
                Text(error)
                    .font(HermesFont.footnote)
                    .foregroundStyle(t.danger)
                    .padding(.horizontal, Space.s6)
                    .padding(.bottom, Space.s3)
            }
        }
    }

    private func subtitle(for platform: PlatformRow) -> String {
        if !platform.configured { return "Not configured" }
        if !platform.errorMessage.isEmpty { return platform.errorMessage }
        return platform.state.isEmpty ? "Configured" : platform.state.capitalized
    }

    private func stateColor(_ platform: PlatformRow) -> Color {
        if !platform.configured { return t.text4 }
        switch platform.state.lowercased() {
        case "connected", "running": return t.ok
        case "error", "failed": return t.danger
        case "disconnected", "stopped": return t.text4
        default: return t.warn
        }
    }

    private var footer: some View {
        Text("Platforms are set up on your computer: adding one means putting its bot token into \(envPath.isEmpty ? "the backend's settings file" : envPath), which this app does not do.")
            .font(HermesFont.footnote)
            .foregroundStyle(t.text3)
            .fixedSize(horizontal: false, vertical: true)
            .padding(Space.s6)
    }


    private func loadIfNeeded() async {
        guard !loaded else { return }
        await load()
    }

    private func load() async {
        guard let rest = app.rest else {
            loadError = "Not connected to a backend."
            return
        }
        loadError = nil
        do {
            let json = try await rest.getJSON("/api/messaging/platforms")
            envPath = json["env_path"]?.coercedString ?? ""
            platforms = (json["platforms"]?.arrayValue ?? []).compactMap { row in
                guard let id = row["id"]?.coercedString, !id.isEmpty else { return nil }
                return PlatformRow(
                    id: id,
                    name: row["name"]?.coercedString ?? id,
                    description: row["description"]?.coercedString ?? "",
                    configured: row["configured"]?.coercedBool ?? false,
                    state: row["state"]?.coercedString ?? "",
                    errorMessage: row["error_message"]?.coercedString ?? "",
                    enabled: row["enabled"]?.coercedBool ?? false
                )
            }
            loaded = true
        } catch {
            loadError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func setEnabled(_ id: String, enabled: Bool) async {
        guard let rest = app.rest, let index = platforms.firstIndex(where: { $0.id == id }) else { return }
        let previous = platforms[index].enabled
        platforms[index].enabled = enabled
        rowErrors[id] = nil
        do {
            try await rest.sendJSON(
                "PUT", "/api/messaging/platforms/\(id)",
                body: .object(["enabled": .bool(enabled)])
            )
        } catch {
            if let idx = platforms.firstIndex(where: { $0.id == id }) {
                platforms[idx].enabled = previous
            }
            rowErrors[id] = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }
}
