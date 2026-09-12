import HermesServeKit
import SwiftUI

/// The host directory browser. Pushed from the folder picker for the case where
/// the folder you want is not one of its shortcuts.
///
/// Everything here describes a filesystem that is **not this device's**, and the
/// gateway may be a Windows box, so separators, the breadcrumb and the `..` row
/// all go through `HostPath` rather than `URL`.
@MainActor
struct DirectoryBrowserSheet: View {
    @Environment(\.hermes) private var t
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss

    let startPath: String
    let currentPath: String
    let apply: (String) async -> String?

    @State private var path = ""
    @State private var listing: DirectoryListing?
    @State private var loading = true
    @State private var failure: String?
    @State private var applying = false

    /// Repo-ness and branch per row, keyed by the row's path. Filled in behind
    /// the listing so the rows appear immediately and gain their diamonds as
    /// the probes land.
    @State private var repoRoots: Set<String> = []
    @State private var branchByPath: [String: String] = [:]
    @State private var probeGeneration = 0

    @State private var creatingFolder = false
    @State private var newFolderName = ""

    /// Bounds on the per-row probes. A home directory with 200 entries must not
    /// fire 200 requests at a tailnet gateway; past the cap the rows simply
    /// render without a diamond, which is the honest "not measured" state.
    private static let repoProbeCap = 60
    private static let branchProbeCap = 24

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            breadcrumb

            if let failure {
                Text(failure)
                    .font(HermesFont.footnote)
                    .foregroundStyle(t.danger)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, Space.s6)
                    .padding(.bottom, Space.s3)
            }

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    newFolderRow

                    if let parent = HostPath.parent(of: path) {
                        upRow(to: parent)
                    }

                    if loading {
                        HStack(spacing: Space.s4) {
                            ProgressView().controlSize(.small)
                            Text("Reading the folder…")
                                .font(HermesFont.footnote)
                                .foregroundStyle(t.text3)
                        }
                        .padding(.horizontal, Space.s6)
                        .padding(.vertical, Space.s5)
                    } else if let message = listing?.errorMessage {
                        // 200 + an `error` string, not a status code — an
                        // unreadable folder must not read as an empty one.
                        Text(message)
                            .font(HermesFont.footnote)
                            .foregroundStyle(t.warn)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.horizontal, Space.s6)
                            .padding(.vertical, Space.s5)
                    } else if directories.isEmpty {
                        Text("No subfolders here.")
                            .font(HermesFont.footnote)
                            .foregroundStyle(t.text3)
                            .padding(.horizontal, Space.s6)
                            .padding(.vertical, Space.s5)
                    } else {
                        ForEach(directories) { entry in
                            directoryRow(entry)
                        }
                    }
                }
                .padding(.bottom, Space.s8)
            }

            useThisFolder
        }
        .background(t.canvas)
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .presentationCornerRadius(Radius.sheet)
        .presentationBackground(t.canvas)
        // Keyed on the socket for the same reason as the worktree sheet: a
        // sheet presented before the connection opens must recover on its own.
        // `startPath` can be empty then too, so the fallback is re-read here.
        .task(id: app.connectionState.isOpen) {
            if path.isEmpty { path = startPath.isEmpty ? app.defaultCwd : startPath }
            // Still nothing: `AppModel.defaultCwd` is fetched after connect and
            // may not have landed yet. Ask the host directly rather than
            // guessing a path for a filesystem that may not be this OS.
            if path.isEmpty, let git = app.gitAPI { path = await git.defaultCwd() }
            guard !path.isEmpty else {
                loading = false
                return
            }
            await load()
        }
    }

    private var directories: [DirectoryEntry] { listing?.directories ?? [] }

    // MARK: Header + breadcrumb

    private var header: some View {
        HStack {
            Text("Browse the host")
                .font(HermesFont.heading)
                .foregroundStyle(t.text1)
            Spacer()
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
        .padding(.bottom, Space.s3)
    }

    /// `HermesFont.code`, scrolled horizontally and pinned to the tail — the
    /// leaf is the part you are reading.
    private var breadcrumb: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Space.s2) {
                ForEach(Array(HostPath.breadcrumb(path).enumerated()), id: \.element.id) { index, crumb in
                    if index > 0 {
                        Text(verbatim: "›")
                            .font(HermesFont.caption)
                            .foregroundStyle(t.text4)
                            .accessibilityHidden(true)
                    }
                    Button {
                        navigate(to: crumb.path)
                    } label: {
                        Text(crumb.name)
                            .font(HermesFont.code)
                            .foregroundStyle(crumb.path == path ? t.text1 : t.text3)
                            .lineLimit(1)
                    }
                    .buttonStyle(.plain)
                    .disabled(applying)
                    .accessibilityLabel("Go to \(crumb.name)")
                }
            }
            .padding(.horizontal, Space.s6)
            .frame(minHeight: Hit.min)
        }
        .defaultScrollAnchor(.trailing)
        .padding(.bottom, Space.s2)
    }

    // MARK: Rows

    /// This is a write on the gateway's own filesystem, not a local one, and the
    /// footnote says so.
    @ViewBuilder
    private var newFolderRow: some View {
        if creatingFolder {
            VStack(alignment: .leading, spacing: Space.s3) {
                HStack(spacing: Space.s3) {
                    TextField("Folder name", text: $newFolderName)
                        .font(HermesFont.code)
                        .foregroundStyle(t.text1)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .onSubmit { Task { await createFolder() } }
                        .padding(Space.s4)
                        .background(t.fill2, in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
                        .accessibilityLabel("New folder name")
                    Button {
                        Task { await createFolder() }
                    } label: {
                        Image(systemName: "arrow.right")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(t.text1)
                    }
                    .buttonStyle(IconButtonStyle())
                    .disabled(newFolderName.trimmingCharacters(in: .whitespaces).isEmpty || applying)
                    .accessibilityLabel("Create the folder")
                    Button {
                        creatingFolder = false
                        newFolderName = ""
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(t.text3)
                    }
                    .buttonStyle(IconButtonStyle())
                    .accessibilityLabel("Cancel")
                }
                Text("Runs mkdir -p on the host, through the gateway's managed-files gate. A gateway locked to a files root refuses anything outside it.")
                    .font(HermesFont.footnote)
                    .foregroundStyle(t.text3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, Space.s6)
            .padding(.vertical, Space.s4)
        } else {
            Button {
                creatingFolder = true
            } label: {
                FlatRow {
                    Text("New folder…")
                        .font(HermesFont.callout)
                        .foregroundStyle(t.action)
                } trailing: {
                    EmptyView()
                }
            }
            .buttonStyle(.plain)
            .disabled(applying)
        }
    }

    private func upRow(to parent: String) -> some View {
        Button {
            navigate(to: parent)
        } label: {
            FlatRow {
                Text(verbatim: "..")
                    .font(HermesFont.code)
                    .foregroundStyle(t.text2)
            } trailing: {
                EmptyView()
            }
        }
        .buttonStyle(.plain)
        .disabled(applying)
        .accessibilityLabel("Up to \(HostPath.lastComponent(of: parent))")
    }

    private func directoryRow(_ entry: DirectoryEntry) -> some View {
        let isRepo = repoRoots.contains(HostPath.normalized(entry.path))
        let branch = branchByPath[HostPath.normalized(entry.path)]
        return Button {
            navigate(to: entry.path)
        } label: {
            FlatRow {
                HStack(spacing: Space.s3) {
                    Text(verbatim: isRepo ? "◆" : "◇")
                        .font(HermesFont.caption)
                        .foregroundStyle(isRepo ? t.action : t.text4)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: Space.s1) {
                        Text(entry.name)
                            .font(HermesFont.callout)
                            .foregroundStyle(t.text1)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        // A repo the host does not name a branch for keeps its
                        // diamond and loses the line — it is not rendered empty.
                        if let branch, !branch.isEmpty {
                            Text(verbatim: "git · \(branch)")
                                .font(HermesFont.code)
                                .foregroundStyle(t.text3)
                                .lineLimit(1)
                                .truncationMode(.head)
                        }
                    }
                }
            } trailing: {
                HStack(spacing: Space.s3) {
                    if HostPath.isSame(entry.path, currentPath) {
                        Image(systemName: "checkmark")
                            .foregroundStyle(t.action)
                    }
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(t.text4)
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(applying)
        .accessibilityLabel(accessibilityLabel(entry.name, isRepo: isRepo, branch: branch))
    }

    private func accessibilityLabel(_ name: String, isRepo: Bool, branch: String?) -> String {
        guard isRepo else { return name }
        if let branch, !branch.isEmpty { return "\(name), git repository on \(branch)" }
        return "\(name), git repository"
    }

    private var useThisFolder: some View {
        VStack(spacing: Space.s3) {
            Button {
                Task { await use() }
            } label: {
                HStack(spacing: Space.s3) {
                    if applying { ProgressView().controlSize(.small) }
                    Text("Use this folder")
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(applying || path.isEmpty)
        }
        .padding(.horizontal, Space.s6)
        .padding(.top, Space.s4)
        .padding(.bottom, Space.s6)
        .background(t.canvas)
    }

    // MARK: Behaviour

    private func navigate(to next: String) {
        guard !applying, !HostPath.isSame(next, path) else { return }
        path = next
        creatingFolder = false
        newFolderName = ""
        Task { await load() }
    }

    private func load() async {
        guard let git = app.gitAPI else {
            failure = "Not connected to a backend."
            loading = false
            return
        }
        loading = true
        failure = nil
        repoRoots = []
        branchByPath = [:]
        probeGeneration += 1
        let generation = probeGeneration
        defer { loading = false }
        do {
            let result = try await git.listDirectory(path: path)
            guard generation == probeGeneration else { return }
            listing = result
            await probeRepositories(result.directories, generation: generation, git: git)
        } catch {
            listing = nil
            failure = message(error)
        }
    }

    /// Two cheap probes per row, both pure filesystem on the host: `git-root`
    /// decides the diamond, `.git/HEAD` supplies the branch. Neither spawns git,
    /// which `GET /api/git/status` would.
    private func probeRepositories(_ entries: [DirectoryEntry], generation: Int, git: GitAPI) async {
        let candidates = Array(entries.prefix(Self.repoProbeCap))
        guard !candidates.isEmpty else { return }

        var found: [String] = []
        await withTaskGroup(of: (String, Bool).self) { group in
            for entry in candidates {
                group.addTask { (entry.path, await git.isRepositoryRoot(path: entry.path)) }
            }
            for await (path, isRepo) in group where isRepo {
                found.append(path)
            }
        }
        guard generation == probeGeneration else { return }
        repoRoots = Set(found.map(HostPath.normalized))

        let branchTargets = Array(found.prefix(Self.branchProbeCap))
        guard !branchTargets.isEmpty else { return }
        await withTaskGroup(of: (String, String?).self) { group in
            for path in branchTargets {
                group.addTask { (path, await git.headBranch(path: path)) }
            }
            for await (path, branch) in group {
                guard generation == probeGeneration else { continue }
                if let branch { branchByPath[HostPath.normalized(path)] = branch }
            }
        }
    }

    private func createFolder() async {
        guard let git = app.gitAPI else { return }
        let name = newFolderName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        failure = nil
        applying = true
        defer { applying = false }
        do {
            let created = try await git.makeDirectory(path: HostPath.joining(path, name))
            creatingFolder = false
            newFolderName = ""
            navigate(to: created)
        } catch {
            failure = message(error)
        }
    }

    private func use() async {
        failure = nil
        applying = true
        defer { applying = false }
        if let error = await apply(path) {
            failure = error
        } else {
            dismiss()
        }
    }

    private func message(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}
