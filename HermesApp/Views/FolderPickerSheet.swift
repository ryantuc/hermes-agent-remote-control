import HermesServeKit
import SwiftUI

/// The working-directory picker. One tap to any known repo or project root, a
/// typed path, or the full host directory browser.
///
/// For a Home draft the pick is local — it rides `session.create(cwd:)` at
/// first send. For a live chat it writes `session.cwd.set`; the backend
/// emits `session.info` and the chip reconciles off that.
@MainActor
struct FolderPickerSheet: View {
    @Environment(\.hermes) private var t
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss

    /// Where the pick lands: a draft mutation or a live RPC.
    let currentPath: String
    let apply: (String) async -> String?

    @State private var repos: [ProjectsAPI.DiscoveredRepo] = []
    @State private var projects: [ProjectsAPI.Project] = []
    @State private var customPath = ""
    @State private var loading = true
    /// The load in flight is a host disk walk, not a cache read (FEAT-013).
    @State private var scanning = false
    @State private var failure: String?
    /// BUG-092: why the lists below are missing or stale, kept apart from `failure` (a pick that did not land) because only this one is fixed by loading again.
    @State private var loadFailure: String?
    @State private var applying: String?
    @State private var browsing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            // P18: failures live outside the scroll content.
            if let failure {
                Text(failure)
                    .font(HermesFont.footnote)
                    .foregroundStyle(t.danger)
                    .padding(.horizontal, Space.s6)
                    .padding(.bottom, Space.s3)
            }
            if let loadFailure {
                loadFailureRow(loadFailure)
            }

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    customRow
                    browseRow

                    if loading {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                            .padding(.top, Space.s8)
                    } else {
                        if !repos.isEmpty {
                            SectionHeader("Repositories")
                            ForEach(repos) { repo in
                                pathRow(label: repo.label, path: repo.root, isRepo: true)
                            }
                        }
                        let extraProjects = Self.extraProjects(projects, besides: repos)
                        if !extraProjects.isEmpty {
                            SectionHeader("Projects")
                                .padding(.top, Space.s5)
                            ForEach(extraProjects) { project in
                                pathRow(label: project.label, path: project.path, isRepo: false)
                            }
                        }
                    }
                }
                .padding(.bottom, Space.s8)
            }
        }
        .background(t.canvas)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .presentationCornerRadius(Radius.sheet)
        .presentationBackground(t.canvas)
        // Keyed on the socket: a picker presented before the connection opens
        // would otherwise latch "Not connected to a backend" and never recover.
        .task(id: app.connectionState.isOpen) { await load() }
        .sheet(isPresented: $browsing) {
            DirectoryBrowserSheet(
                startPath: browseStart,
                currentPath: currentPath,
                apply: { path in
                    let error = await apply(path)
                    if error == nil { dismiss() }
                    return error
                }
            )
        }
    }

    /// Where browsing opens: the current working directory when there is one,
    /// otherwise the first known repo. Never a guessed device path — this is
    /// the gateway's filesystem, and it may not even be the same OS.
    private var browseStart: String {
        if !currentPath.isEmpty { return currentPath }
        if !app.defaultCwd.isEmpty { return app.defaultCwd }
        return repos.first?.root ?? projects.first(where: { !$0.path.isEmpty })?.path ?? ""
    }

    /// The Projects section: a project is listed only when no Repositories row already names its directory.
    /// BUG-091: through `HostPath.isSame`, never `==` — on a Windows host `discover_repos` spells a root `X:\…` and `projects.tree` spells the same directory `X:/…`.
    static func extraProjects(
        _ projects: [ProjectsAPI.Project],
        besides repos: [ProjectsAPI.DiscoveredRepo]
    ) -> [ProjectsAPI.Project] {
        projects.filter { project in
            !project.isNoProject && !project.path.isEmpty
                && !repos.contains(where: { HostPath.isSame($0.root, project.path) })
        }
    }

    /// Whether a row is the working directory already in play, which earns it the checkmark; `HostPath.isSame` for the same reason as above.
    static func isCurrent(_ path: String, currentPath: String) -> Bool {
        !currentPath.isEmpty && HostPath.isSame(path, currentPath)
    }

    /// BUG-092: one line for whichever of the two list calls failed; nil when both answered.
    static func loadFailureText(repositories: String?, projects: String?) -> String? {
        switch (repositories, projects) {
        case (nil, nil):
            return nil
        case let (reason?, nil):
            return "Couldn't list repositories: \(reason)"
        case let (nil, reason?):
            return "Couldn't list projects: \(reason)"
        case let (repoReason?, projectReason?):
            return repoReason == projectReason
                ? "Couldn't list repositories or projects: \(repoReason)"
                : "Couldn't list repositories: \(repoReason) Couldn't list projects: \(projectReason)"
        }
    }

    /// The reason, and a retry that reloads without the host disk walk the refresh button runs.
    private func loadFailureRow(_ message: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.s4) {
            Text(message)
                .font(HermesFont.footnote)
                .foregroundStyle(t.danger)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            if app.projectsAPI != nil {
                Button("Try again") {
                    Task { await load() }
                }
                .font(HermesFont.subhead)
                .foregroundStyle(t.action)
                .buttonStyle(.plain)
                .frame(minHeight: Hit.min)
                .contentShape(Rectangle())
                .disabled(loading)
            }
        }
        .padding(.horizontal, Space.s6)
        .padding(.bottom, Space.s3)
    }

    private var browseRow: some View {
        Button {
            browsing = true
        } label: {
            FlatRow {
                Text("Browse the host…")
                    .font(HermesFont.callout)
                    .foregroundStyle(t.action)
            } trailing: {
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(t.text4)
            }
        }
        .buttonStyle(.plain)
        .disabled(applying != nil || browseStart.isEmpty)
    }

    private var header: some View {
        HStack {
            Text("Working directory")
                .font(HermesFont.heading)
                .foregroundStyle(t.text1)
            Spacer()
            // FEAT-013. A button and not part of `load()`: the scan is a
            // synchronous disk walk on the host.
            Button {
                Task { await load(scan: true) }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(scanning ? t.text4 : t.text3)
            }
            .buttonStyle(IconButtonStyle())
            .disabled(loading || applying != nil)
            .accessibilityLabel("Scan the host for repositories")
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(t.text3)
            }
            .buttonStyle(IconButtonStyle())
            .accessibilityLabel("Close")
        }
        .padding(.horizontal, Space.s6)
        .padding(.top, Space.s6)
        .padding(.bottom, Space.s4)
    }

    private var customRow: some View {
        HStack(spacing: Space.s3) {
            TextField("Or type a path on the host", text: $customPath)
                .font(HermesFont.code)
                .foregroundStyle(t.text1)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .onSubmit { Task { await pick(customPath) } }
                .padding(Space.s4)
                .background(t.fill2, in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
            Button {
                Task { await pick(customPath) }
            } label: {
                Image(systemName: "arrow.right")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(t.text1)
            }
            .buttonStyle(IconButtonStyle())
            .disabled(customPath.trimmingCharacters(in: .whitespaces).isEmpty)
            .accessibilityLabel("Use this path")
        }
        .padding(.horizontal, Space.s6)
        .padding(.bottom, Space.s4)
    }

    private func pathRow(label: String, path: String, isRepo: Bool) -> some View {
        Button {
            Task { await pick(path) }
        } label: {
            FlatRow {
                HStack(spacing: Space.s3) {
                    Text(verbatim: isRepo ? "◆" : "◇")
                        .font(HermesFont.caption)
                        .foregroundStyle(isRepo ? t.action : t.text4)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: Space.s1) {
                        Text(label)
                            .font(HermesFont.callout)
                            .foregroundStyle(t.text1)
                        Text((path as NSString).abbreviatingWithTildeInPath)
                            .font(HermesFont.code)
                            .foregroundStyle(t.text3)
                            .lineLimit(1)
                            .truncationMode(.head)
                    }
                }
            } trailing: {
                if applying == path {
                    ProgressView().controlSize(.small)
                } else if Self.isCurrent(path, currentPath: currentPath) {
                    Image(systemName: "checkmark")
                        .foregroundStyle(t.action)
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(applying != nil)
        .accessibilityLabel("Use \(label)")
    }

    private func pick(_ raw: String) async {
        let path = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else { return }
        failure = nil
        applying = path
        defer { applying = nil }
        if let error = await apply(path) {
            failure = error
        } else {
            dismiss()
        }
    }

    /// `scan: true` is the refresh button's path only (FEAT-013) — the backend
    /// walks its own disk for repositories no session has ever touched, which
    /// is the only way one reaches this list.
    private func load(scan: Bool = false) async {
        loading = true
        scanning = scan
        defer {
            loading = false
            scanning = false
        }
        guard let projectsAPI = app.projectsAPI else {
            loadFailure = "Not connected to a backend."
            return
        }
        failure = nil
        let repoLoad = await HostListLoad.run(keeping: repos) {
            try await projectsAPI.discoverRepos(scan: scan)
        }
        repos = repoLoad.rows
        let projectLoad = await HostListLoad.run(keeping: projects) {
            try await projectsAPI.tree()
        }
        projects = projectLoad.rows
        loadFailure = Self.loadFailureText(repositories: repoLoad.failure, projects: projectLoad.failure)
    }
}

/// One list fetch for the folder and worktree sheets: the rows to draw and, when the fetch failed, why.
/// BUG-092: a thrown call is not an empty answer. It keeps the rows already on screen and carries the reason, so no sheet can tell the user their backend has nothing when all the client knows is that the call failed.
struct HostListLoad<Row> {
    var rows: [Row]
    var failure: String?

    static func run(keeping previous: [Row], _ fetch: () async throws -> [Row]) async -> HostListLoad<Row> {
        do {
            return HostListLoad(rows: try await fetch(), failure: nil)
        } catch is CancellationError {
            // The sheet went away or its key changed; nothing to report, and no answer either.
            return HostListLoad(rows: previous, failure: nil)
        } catch {
            let reason = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            return HostListLoad(rows: previous, failure: reason)
        }
    }
}
