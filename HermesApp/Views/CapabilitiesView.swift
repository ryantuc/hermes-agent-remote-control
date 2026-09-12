import HermesServeKit
import SwiftUI

/// Settings → Workspace → Capabilities: the desktop page's four
/// tabs — Skills · Tools · MCP · Hub. Read-and-toggle: adding an MCP server
/// or authoring a skill needs a filesystem, and a phone form that cannot
/// succeed is worse than no form. Every toggle paints first and rolls back
/// visibly on failure.
@MainActor
struct CapabilitiesView: View {
    @Environment(\.hermes) private var t
    @Environment(AppModel.self) private var app

    @AppStorage("hermes.capabilities.tab") private var tab = "Skills"

    @State private var skills: [SkillRow] = []
    @State private var toolsets: [ToolsetRow] = []
    @State private var servers: [MCPServerRow] = []
    @State private var loadError: String?
    @State private var loaded = false
    @State private var rowErrors: [String: String] = [:]
    @State private var skillQuery = ""

    // Hub
    @State private var hubQuery = ""
    @State private var hubResults: [HubResult] = []
    @State private var hubSearching = false
    @State private var hubMessage: String?
    @State private var installing: Set<String> = []

    struct SkillRow: Identifiable {
        let name: String
        let description: String
        var enabled: Bool
        var id: String { name }
    }

    struct ToolsetRow: Identifiable {
        let key: String
        let label: String
        let description: String
        var enabled: Bool
        var id: String { key }
    }

    struct MCPServerRow: Identifiable {
        let name: String
        let transport: String
        let toolCount: Int?
        var enabled: Bool
        var id: String { name }
    }

    struct HubResult: Identifiable {
        let identifier: String
        let name: String
        let source: String
        let description: String
        var installed: Bool
        var id: String { identifier }
    }

    var body: some View {
        VStack(spacing: 0) {
            TabRow(tabs: ["Skills", "Tools", "MCP", "Hub"], selection: $tab)
                .padding(.horizontal, Space.s6)
                .padding(.vertical, Space.s4)

            if let loadError {
                errorBlock(loadError)
            } else {
                switch tab {
                case "Tools": toolsList
                case "MCP": mcpList
                case "Hub": hubTab
                default: skillsList
                }
            }
        }
        .background(t.canvas)
        .navigationTitle("Capabilities")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(t.canvas, for: .navigationBar)
        .task { await loadIfNeeded() }
        .refreshable { await load() }
    }

    // MARK: Skills

    private var skillsList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                searchField($skillQuery, prompt: "Search skills")
                let rows = skills.filter {
                    skillQuery.isEmpty
                        || $0.name.localizedCaseInsensitiveContains(skillQuery)
                        || $0.description.localizedCaseInsensitiveContains(skillQuery)
                }
                ForEach(rows) { skill in
                    toggleRow(
                        title: skill.name,
                        subtitle: skill.description,
                        isOn: skill.enabled,
                        errorKey: "skill.\(skill.name)"
                    ) { newValue in
                        await setSkill(skill.name, enabled: newValue)
                    }
                }
            }
            .padding(.bottom, Space.s10)
        }
    }

    // MARK: Tools

    private var toolsList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(toolsets) { toolset in
                    toggleRow(
                        title: toolset.label,
                        subtitle: toolset.description,
                        isOn: toolset.enabled,
                        errorKey: "toolset.\(toolset.key)"
                    ) { newValue in
                        await setToolset(toolset.key, enabled: newValue)
                    }
                }
            }
            .padding(.bottom, Space.s10)
        }
    }

    // MARK: MCP

    private var mcpList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(servers) { server in
                    toggleRow(
                        title: server.name,
                        subtitle: server.toolCount.map { "\(server.transport) · \($0) tools" } ?? server.transport,
                        isOn: server.enabled,
                        errorKey: "mcp.\(server.name)"
                    ) { newValue in
                        await setServer(server.name, enabled: newValue)
                    }
                }
                Text("Adding a server means pointing at a binary on disk and editing JSON — that lives on the desktop or in the CLI. Toggles here take effect on the next session.")
                    .font(HermesFont.footnote)
                    .foregroundStyle(t.text3)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(Space.s6)
            }
            .padding(.bottom, Space.s10)
        }
    }

    // MARK: Hub

    private var hubTab: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                HStack(spacing: Space.s3) {
                    searchField($hubQuery, prompt: "Search the skills hub")
                    Button {
                        Task { await hubSearch() }
                    } label: {
                        if hubSearching {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "arrow.right")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(t.text1)
                        }
                    }
                    .buttonStyle(IconButtonStyle())
                    .disabled(hubSearching)
                    .accessibilityLabel("Search")
                    .padding(.trailing, Space.s6)
                }

                if let hubMessage {
                    Text(hubMessage)
                        .font(HermesFont.footnote)
                        .foregroundStyle(t.text3)
                        .padding(.horizontal, Space.s6)
                        .padding(.vertical, Space.s4)
                }

                ForEach(hubResults) { result in
                    hubRow(result)
                }
            }
            .padding(.bottom, Space.s10)
        }
    }

    private func hubRow(_ result: HubResult) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            FlatRow {
                VStack(alignment: .leading, spacing: Space.s1) {
                    Text(result.name)
                        .font(HermesFont.callout)
                        .foregroundStyle(t.text1)
                    Text(result.description.isEmpty ? result.source : "\(result.source) · \(result.description)")
                        .font(HermesFont.footnote)
                        .foregroundStyle(t.text3)
                        .lineLimit(2)
                }
            } trailing: {
                if installing.contains(result.identifier) {
                    ProgressView().controlSize(.small)
                } else if result.installed {
                    Image(systemName: "checkmark")
                        .foregroundStyle(t.ok)
                        .accessibilityLabel("Installed")
                } else {
                    Button("Install") {
                        Task { await install(result) }
                    }
                    .font(HermesFont.subhead)
                    .foregroundStyle(t.action)
                    .buttonStyle(.plain)
                    .frame(minHeight: Hit.min)
                    .contentShape(Rectangle())
                }
            }
            if let error = rowErrors["hub.\(result.identifier)"] {
                Text(error)
                    .font(HermesFont.footnote)
                    .foregroundStyle(t.danger)
                    .padding(.horizontal, Space.s6)
                    .padding(.bottom, Space.s3)
            }
        }
    }

    // MARK: Shared rows

    private func toggleRow(
        title: String,
        subtitle: String,
        isOn: Bool,
        errorKey: String,
        write: @escaping (Bool) async -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            SwitchRow(
                title,
                subtitle: subtitle.isEmpty ? nil : subtitle,
                isOn: Binding(
                    get: { isOn },
                    set: { newValue in Task { await write(newValue) } }
                )
            )
            if let error = rowErrors[errorKey] {
                Text(error)
                    .font(HermesFont.footnote)
                    .foregroundStyle(t.danger)
                    .padding(.horizontal, Space.s6)
                    .padding(.bottom, Space.s3)
            }
        }
    }

    private func searchField(_ text: Binding<String>, prompt: String) -> some View {
        HStack(spacing: Space.s3) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13))
                .foregroundStyle(t.text4)
            TextField(prompt, text: text)
                .font(HermesFont.callout)
                .foregroundStyle(t.text1)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .onSubmit { if prompt.contains("hub") { Task { await hubSearch() } } }
        }
        .frame(minHeight: Hit.min)
        .padding(.horizontal, Space.s6)
        .hairline()
    }

    private func errorBlock(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: Space.s5) {
            Text("Couldn't load capabilities")
                .font(HermesFont.heading)
                .foregroundStyle(t.text1)
            Text(message)
                .font(HermesFont.subhead)
                .foregroundStyle(t.text3)
            Button("Try again") { Task { await load() } }
                .buttonStyle(SecondaryButtonStyle())
                .frame(maxWidth: 220)
        }
        .padding(Space.s6)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Loading

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
            let skillsJSON = try await rest.getJSON("/api/skills")
            skills = (skillsJSON.arrayValue ?? []).compactMap { row in
                guard let name = row["name"]?.coercedString, !name.isEmpty else { return nil }
                return SkillRow(
                    name: name,
                    description: row["description"]?.coercedString ?? "",
                    enabled: row["enabled"]?.coercedBool ?? false
                )
            }

            let toolsJSON = try await rest.getJSON("/api/tools/toolsets")
            let toolRows = toolsJSON["toolsets"]?.arrayValue ?? toolsJSON.arrayValue ?? []
            toolsets = toolRows.compactMap { row in
                guard let key = (row["key"] ?? row["name"])?.coercedString, !key.isEmpty else { return nil }
                return ToolsetRow(
                    key: key,
                    label: row["label"]?.coercedString ?? key,
                    description: row["description"]?.coercedString ?? "",
                    enabled: row["enabled"]?.coercedBool ?? false
                )
            }

            let mcpJSON = try await rest.getJSON("/api/mcp/servers")
            servers = (mcpJSON["servers"]?.arrayValue ?? []).compactMap { row in
                guard let name = row["name"]?.coercedString, !name.isEmpty else { return nil }
                let tools = row["tools"]?.arrayValue?.count
                return MCPServerRow(
                    name: name,
                    transport: row["transport"]?.coercedString ?? "",
                    toolCount: tools,
                    enabled: row["enabled"]?.coercedBool ?? false
                )
            }
            loaded = true
        } catch {
            loadError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    // MARK: Writes — paint first, roll back visibly

    private func setSkill(_ name: String, enabled: Bool) async {
        guard let rest = app.rest, let index = skills.firstIndex(where: { $0.name == name }) else { return }
        let previous = skills[index].enabled
        skills[index].enabled = enabled
        rowErrors["skill.\(name)"] = nil
        do {
            try await rest.sendJSON(
                "PUT", "/api/skills/toggle",
                body: .object(["name": .string(name), "enabled": .bool(enabled)])
            )
        } catch {
            if let idx = skills.firstIndex(where: { $0.name == name }) {
                skills[idx].enabled = previous
            }
            rowErrors["skill.\(name)"] = describe(error)
        }
    }

    private func setToolset(_ key: String, enabled: Bool) async {
        guard let rest = app.rest, let index = toolsets.firstIndex(where: { $0.key == key }) else { return }
        let previous = toolsets[index].enabled
        toolsets[index].enabled = enabled
        rowErrors["toolset.\(key)"] = nil
        do {
            try await rest.sendJSON(
                "PUT", "/api/tools/toolsets/\(key)",
                body: .object(["enabled": .bool(enabled)])
            )
        } catch {
            if let idx = toolsets.firstIndex(where: { $0.key == key }) {
                toolsets[idx].enabled = previous
            }
            rowErrors["toolset.\(key)"] = describe(error)
        }
    }

    private func setServer(_ name: String, enabled: Bool) async {
        guard let rest = app.rest, let index = servers.firstIndex(where: { $0.name == name }) else { return }
        let previous = servers[index].enabled
        servers[index].enabled = enabled
        rowErrors["mcp.\(name)"] = nil
        do {
            try await rest.sendJSON(
                "PUT", "/api/mcp/servers/\(name)/enabled",
                body: .object(["enabled": .bool(enabled)])
            )
        } catch {
            if let idx = servers.firstIndex(where: { $0.name == name }) {
                servers[idx].enabled = previous
            }
            rowErrors["mcp.\(name)"] = describe(error)
        }
    }

    private func hubSearch() async {
        guard let rest = app.rest else { return }
        let query = hubQuery.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else {
            hubMessage = "Type something to search the catalogue."
            return
        }
        hubSearching = true
        defer { hubSearching = false }
        hubMessage = nil
        do {
            let json = try await rest.getJSON(
                "/api/skills/hub/search",
                query: [URLQueryItem(name: "q", value: query)]
            )
            let installedNames = Set(skills.map(\.name))
            hubResults = (json["results"]?.arrayValue ?? []).compactMap { row in
                let identifier = (row["identifier"] ?? row["id"])?.coercedString ?? ""
                guard !identifier.isEmpty else { return nil }
                let name = row["name"]?.coercedString ?? identifier
                return HubResult(
                    identifier: identifier,
                    name: name,
                    source: row["source"]?.coercedString ?? "",
                    description: row["description"]?.coercedString ?? "",
                    installed: (row["installed"]?.coercedBool ?? false) || installedNames.contains(name)
                )
            }
            if hubResults.isEmpty { hubMessage = "Nothing matches “\(query)”." }
        } catch {
            hubMessage = describe(error)
        }
    }

    /// Install is a one-tap write with a visible rollback: the row shows a
    /// spinner while the backend action runs, then either flips to installed
    /// (the skill appears in /api/skills) or carries the failure.
    private func install(_ result: HubResult) async {
        guard let rest = app.rest else { return }
        installing.insert(result.identifier)
        rowErrors["hub.\(result.identifier)"] = nil
        defer { installing.remove(result.identifier) }
        do {
            try await rest.sendJSON(
                "POST", "/api/skills/hub/install",
                body: .object(["identifier": .string(result.identifier)])
            )
            // The install spawns a backend action; poll for the skill to land.
            for _ in 0..<6 {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                await load()
                if skills.contains(where: { $0.name == result.name }) {
                    if let idx = hubResults.firstIndex(where: { $0.identifier == result.identifier }) {
                        hubResults[idx].installed = true
                    }
                    return
                }
            }
            rowErrors["hub.\(result.identifier)"] = "The install did not finish — check the desktop for build output."
        } catch {
            rowErrors["hub.\(result.identifier)"] = describe(error)
        }
    }

    private func describe(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}
