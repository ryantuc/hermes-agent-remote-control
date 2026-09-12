import HermesServeKit
import SwiftUI

/// Repository, branch and worktree. Opened from Home's top-bar chip and from
/// the `+` sheet's **Repository & branch** quick action.
///
/// It mirrors the desktop's worktree dialog contract exactly: same three branch
/// actions, same base-branch fallback, same git-ref sanitiser.
@MainActor
struct WorktreeSheet: View {
    @Environment(\.hermes) private var t
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss

    let currentPath: String
    let apply: (String) async -> String?

    /// Which half of the sheet is showing. The desktop calls the second one
    /// "convert mode"; the spec calls it *Check out an existing branch*.
    private enum Mode: Equatable {
        case lanes
        case newWorktree
        case existingBranch
    }

    @State private var mode: Mode = .lanes
    @State private var repos: [ProjectsAPI.DiscoveredRepo] = []
    @State private var repoRoot = ""
    @State private var worktrees: [GitWorktree] = []
    @State private var branches: [GitBranch] = []
    @State private var baseBranches: [GitBaseBranch] = []

    @State private var branchName = ""
    @State private var selectedBase = ""
    @State private var branchFilter = ""
    @State private var showingBasePicker = false

    @State private var loadingRepos = true
    @State private var loadingLanes = false
    @State private var loadingBranches = false
    @State private var pendingLabel: String?
    @State private var failure: String?
    @State private var reposExpanded = false

    /// A repository row's identity, from either source.
    private struct RepoChoice: Identifiable {
        let label: String
        let root: String
        var id: String { root }
    }

    /// Every discovered repository, plus the one in play when it is not among
    /// them — `projects.discover_repos` only knows repositories a session has
    /// touched, and the working directory may be somewhere it has never been.
    private var repoChoices: [RepoChoice] {
        var rows = repos.map { RepoChoice(label: $0.label, root: $0.root) }
        if !repoRoot.isEmpty, !rows.contains(where: { HostPath.isSame($0.root, repoRoot) }) {
            rows.insert(RepoChoice(label: HostPath.lastComponent(of: repoRoot), root: repoRoot), at: 0)
        }
        return rows
    }

    /// Collapsed shows the repository in play and nothing else; with none
    /// chosen there is nothing to collapse *to*, so the list opens.
    private var visibleRepos: [RepoChoice] {
        guard !reposExpanded, !repoRoot.isEmpty else { return repoChoices }
        return repoChoices.filter { HostPath.isSame($0.root, repoRoot) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            // P18: a failure lives outside the scroll content, so it cannot be
            // scrolled away from the control that produced it.
            if let failure {
                Text(failure)
                    .font(HermesFont.footnote)
                    .foregroundStyle(t.danger)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, Space.s6)
                    .padding(.bottom, Space.s4)
                    .accessibilityAddTraits(.isStaticText)
            }

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    switch mode {
                    case .lanes: laneBody
                    case .newWorktree: newWorktreeBody
                    case .existingBranch: existingBranchBody
                    }
                }
                .padding(.bottom, Space.s10)
            }
        }
        .background(t.canvas)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .presentationCornerRadius(Radius.sheet)
        .presentationBackground(t.canvas)
        // Keyed on the socket, not a bare `.task`: a sheet can be presented
        // before the connection is open, and a one-shot load would latch
        // "Not connected to a backend" forever.
        .task(id: app.connectionState.isOpen) { await loadRepos() }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: Space.s3) {
            if mode != .lanes {
                Button {
                    mode = .lanes
                    failure = nil
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(t.text2)
                }
                .buttonStyle(IconButtonStyle())
                .accessibilityLabel("Back")
            }

            Text(title)
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
        .padding(.bottom, Space.s4)
    }

    private var title: String {
        switch mode {
        case .lanes: return "Repository & branch"
        case .newWorktree: return "New worktree"
        case .existingBranch: return "Check out a branch"
        }
    }

    // MARK: Lanes — the landing view

    @ViewBuilder
    private var laneBody: some View {
        if loadingRepos {
            loadingRow("Finding repositories…")
        } else if repoChoices.isEmpty {
            emptyNote("No repositories on the backend yet. Pick a working directory first — a folder becomes a repository the moment a worktree is created in it.")
        } else {
            // REPOSITORY comes first but can run to 20+ rows, so collapsed it
            // shows only the repository in play and the count in the header.
            if !repoChoices.isEmpty {
                SectionHeader(
                    "Repository",
                    count: repoChoices.count,
                    isExpanded: reposExpanded,
                    onToggle: { reposExpanded.toggle() }
                )
                ForEach(visibleRepos) { repo in
                    repoRow(repo)
                }
            }

            if !repoRoot.isEmpty {
                SectionHeader("Lane")
                    .padding(.top, Space.s5)
                if loadingLanes {
                    loadingRow("Reading worktrees…")
                } else if worktrees.isEmpty {
                    emptyNote("That folder is not a git repository yet.")
                } else {
                    ForEach(worktrees) { lane in
                        laneRow(lane)
                    }
                }

                actionRow("New worktree…", isPrimary: true) {
                    failure = nil
                    mode = .newWorktree
                    Task { await loadBaseBranches() }
                }
                actionRow("Check out an existing branch…", isPrimary: false) {
                    failure = nil
                    branchFilter = ""
                    mode = .existingBranch
                    Task { await loadBranches() }
                }
            }
        }
    }

    private func repoRow(_ repo: RepoChoice) -> some View {
        Button {
            select(repoRoot: repo.root)
            reposExpanded = false
        } label: {
            FlatRow {
                HStack(spacing: Space.s3) {
                    Text(verbatim: "◆")
                        .font(HermesFont.caption)
                        .foregroundStyle(t.action)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: Space.s1) {
                        Text(repo.label)
                            .font(HermesFont.callout)
                            .foregroundStyle(t.text1)
                        Text(repo.root)
                            .font(HermesFont.code)
                            .foregroundStyle(t.text3)
                            .lineLimit(1)
                            .truncationMode(.head)
                    }
                }
            } trailing: {
                if HostPath.isSame(repo.root, repoRoot) {
                    Image(systemName: "checkmark")
                        .foregroundStyle(t.action)
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(pendingLabel != nil)
        .accessibilityLabel("Repository \(repo.label)")
    }

    /// LaneLabel: **ellipsize the head, pin the tail**, because
    /// `ios/coding-context-facts` and `ios/coding-context-persona` truncate to
    /// the same string otherwise.
    private func laneRow(_ lane: GitWorktree) -> some View {
        Button {
            Task { await pick(lane.path, label: lane.label) }
        } label: {
            FlatRow {
                Text(lane.label)
                    .font(HermesFont.code)
                    .foregroundStyle(t.text1)
                    .lineLimit(1)
                    .truncationMode(.head)
            } trailing: {
                HStack(spacing: Space.s3) {
                    if pendingLabel == lane.label {
                        ProgressView().controlSize(.small)
                    } else if HostPath.isSame(lane.path, currentPath) {
                        Image(systemName: "checkmark")
                            .foregroundStyle(t.action)
                    }
                    Text(lane.laneNote)
                        .font(HermesFont.footnote)
                        .foregroundStyle(t.text3)
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(pendingLabel != nil)
        .accessibilityLabel("\(lane.label), \(lane.laneNote)")
    }

    // MARK: New worktree

    @ViewBuilder
    private var newWorktreeBody: some View {
        VStack(alignment: .leading, spacing: Space.s5) {
            // Sanitised as a git ref on every keystroke. Neither SwiftUI
            // spelling of that works during a live edit — see
            // `SanitizedTextField`, which is why it exists.
            SanitizedTextField(
                text: $branchName,
                placeholder: "Branch name",
                textColor: t.text1,
                placeholderColor: t.text3,
                sanitize: GitRef.sanitize,
                onSubmit: { Task { await createWorktree() } }
            )
            .frame(minHeight: 22)
            .padding(Space.s4)
            .background(t.fill2, in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
            .accessibilityLabel("Branch name")

            Button {
                showingBasePicker = true
            } label: {
                HStack(spacing: Space.s3) {
                    Text("Branch off")
                        .font(HermesFont.callout)
                        .foregroundStyle(t.text2)
                    if loadingBranches {
                        ProgressView().controlSize(.small)
                    } else {
                        ValueView(selectedBase.isEmpty ? .unknown : .live) {
                            Text(selectedBase)
                                .font(HermesFont.code)
                                .foregroundStyle(t.action)
                                .lineLimit(1)
                                .truncationMode(.head)
                        }
                    }
                    Text(verbatim: "⌄")
                        .font(HermesFont.caption)
                        .foregroundStyle(t.text4)
                        .accessibilityHidden(true)
                    Spacer(minLength: 0)
                }
                .frame(minHeight: Hit.min)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(baseBranches.isEmpty)
            .accessibilityLabel("Branch off \(selectedBase.isEmpty ? "not chosen" : selectedBase)")

            Button {
                Task { await createWorktree() }
            } label: {
                HStack(spacing: Space.s3) {
                    if pendingLabel == createLabel {
                        ProgressView().controlSize(.small)
                    }
                    Text(pendingLabel == createLabel ? "Creating the worktree on the host…" : "Start work")
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(branchName.trimmingCharacters(in: .whitespaces).isEmpty || pendingLabel != nil)

            // Not a local operation, and the copy does not pretend otherwise.
            VStack(alignment: .leading, spacing: Space.s1) {
                Text(verbatim: "Creates the branch and its worktree on the host, under")
                Text(verbatim: worktreeParentNote)
                    .font(HermesFont.code)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            .font(HermesFont.footnote)
            .foregroundStyle(t.text3)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, Space.s6)
        .padding(.top, Space.s4)
        .sheet(isPresented: $showingBasePicker) {
            BaseBranchPicker(branches: baseBranches, selection: $selectedBase)
        }
    }

    private var createLabel: String { "__create__" }

    private var worktreeParentNote: String {
        HostPath.display(HostPath.joining(repoRoot, ".worktrees"))
    }

    // MARK: Existing branch

    @ViewBuilder
    private var existingBranchBody: some View {
        VStack(alignment: .leading, spacing: 0) {
            TextField("Filter branches", text: $branchFilter)
                .font(HermesFont.code)
                .foregroundStyle(t.text1)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .padding(Space.s4)
                .background(t.fill2, in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
                .padding(.horizontal, Space.s6)
                .padding(.bottom, Space.s4)
                .accessibilityLabel("Filter branches")

            if loadingBranches {
                loadingRow("Reading branches…")
            } else if filteredBranches.isEmpty {
                emptyNote(branches.isEmpty ? "No branches on that repository." : "No branch matches that filter.")
            } else {
                ForEach(filteredBranches) { branch in
                    branchRow(branch)
                }
            }
        }
    }

    private var filteredBranches: [GitBranch] {
        let needle = branchFilter.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return branches }
        return branches.filter { $0.name.lowercased().contains(needle) }
    }

    /// The spec's per-row trailing label: it states what selecting the row will
    /// *do*, not what the row is. Three outcomes, three verbs.
    private func branchRow(_ branch: GitBranch) -> some View {
        Button {
            Task { await checkout(branch) }
        } label: {
            FlatRow {
                Text(branch.name)
                    .font(HermesFont.code)
                    .foregroundStyle(t.text1)
                    .lineLimit(1)
                    .truncationMode(.head)
            } trailing: {
                HStack(spacing: Space.s3) {
                    if pendingLabel == branch.name {
                        ProgressView().controlSize(.small)
                    }
                    Text(branch.action.label)
                        .font(HermesFont.footnote)
                        .foregroundStyle(t.text3)
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(pendingLabel != nil)
        .accessibilityLabel("\(branch.name). \(branch.action.label)")
    }

    // MARK: Shared rows

    private func actionRow(_ label: String, isPrimary: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            FlatRow {
                Text(label)
                    .font(HermesFont.callout)
                    .foregroundStyle(isPrimary ? t.action : t.text1)
            } trailing: {
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(t.text4)
            }
        }
        .buttonStyle(.plain)
        .disabled(pendingLabel != nil)
    }

    private func loadingRow(_ label: String) -> some View {
        HStack(spacing: Space.s4) {
            ProgressView().controlSize(.small)
            Text(label)
                .font(HermesFont.footnote)
                .foregroundStyle(t.text3)
        }
        .padding(.horizontal, Space.s6)
        .padding(.vertical, Space.s5)
    }

    private func emptyNote(_ text: String) -> some View {
        Text(text)
            .font(HermesFont.footnote)
            .foregroundStyle(t.text3)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, Space.s6)
            .padding(.vertical, Space.s5)
    }

    // MARK: Loading

    private func loadRepos() async {
        loadingRepos = true
        defer { loadingRepos = false }
        guard let projectsAPI = app.projectsAPI else {
            failure = "Not connected to a backend."
            return
        }
        failure = nil
        repos = (try? await projectsAPI.discoverRepos()) ?? []

        // Open on the repository the current working directory is already in,
        // so the sheet lands where the conversation is rather than on a list.
        if let containing = repos.first(where: { contains(root: $0.root, path: currentPath) }) {
            select(repoRoot: containing.root)
        } else if !currentPath.isEmpty, let git = app.gitAPI,
                  let root = (try? await git.gitRoot(path: currentPath)) ?? nil {
            select(repoRoot: root)
        } else if let first = repos.first {
            select(repoRoot: first.root)
        }
    }

    private func contains(root: String, path: String) -> Bool {
        guard !path.isEmpty else { return false }
        if HostPath.isSame(root, path) { return true }
        let normalizedRoot = HostPath.normalized(root)
        let normalizedPath = HostPath.normalized(path)
        let prefix = normalizedRoot.hasSuffix("/") ? normalizedRoot : normalizedRoot + "/"
        return HostPath.looksWindows(root)
            ? normalizedPath.lowercased().hasPrefix(prefix.lowercased())
            : normalizedPath.hasPrefix(prefix)
    }

    private func select(repoRoot root: String) {
        if HostPath.isSame(root, repoRoot), !worktrees.isEmpty { return }
        repoRoot = root
        worktrees = []
        branches = []
        baseBranches = []
        selectedBase = ""
        Task { await loadLanes() }
    }

    private func loadLanes() async {
        guard let git = app.gitAPI, !repoRoot.isEmpty else { return }
        loadingLanes = true
        defer { loadingLanes = false }
        do {
            worktrees = try await git.worktrees(path: repoRoot)
        } catch {
            worktrees = []
            failure = message(error)
        }
    }

    private func loadBranches() async {
        guard let git = app.gitAPI, !repoRoot.isEmpty else { return }
        loadingBranches = true
        defer { loadingBranches = false }
        do {
            branches = try await git.branches(path: repoRoot)
        } catch {
            branches = []
            failure = message(error)
        }
    }

    private func loadBaseBranches() async {
        guard let git = app.gitAPI, !repoRoot.isEmpty else { return }
        loadingBranches = true
        defer { loadingBranches = false }
        do {
            baseBranches = try await git.baseBranches(path: repoRoot)
            // `origin/HEAD` when the backend flags one, most-recent ref
            // otherwise — the campaign's own repo flags nothing.
            selectedBase = GitBaseBranch.preferred(in: baseBranches)?.name ?? ""
        } catch {
            baseBranches = []
            failure = message(error)
        }
    }

    // MARK: Mutations

    private func createWorktree() async {
        guard let git = app.gitAPI else { return }
        let branch = branchName.trimmingCharacters(in: .whitespaces)
        guard !branch.isEmpty else { return }
        failure = nil
        pendingLabel = createLabel
        defer { pendingLabel = nil }
        do {
            let result = try await git.addWorktree(
                path: repoRoot,
                name: branch,
                branch: branch,
                base: selectedBase.isEmpty ? nil : selectedBase
            )
            await finish(path: result.path)
        } catch {
            failure = message(error)
        }
    }

    /// The desktop's `convert()`, one for one: an existing worktree is opened,
    /// the default branch moves the home checkout, anything else gets a new
    /// worktree.
    private func checkout(_ branch: GitBranch) async {
        guard let git = app.gitAPI else { return }
        failure = nil
        pendingLabel = branch.name
        defer { pendingLabel = nil }
        do {
            switch branch.action {
            case .openExisting:
                guard let path = branch.worktreePath else {
                    failure = "The backend reports that branch as checked out but names no worktree for it."
                    return
                }
                await finish(path: path)
            case .switchHome:
                _ = try await git.switchBranch(path: repoRoot, branch: branch.name)
                await finish(path: repoRoot)
            case .createWorktree:
                let result = try await git.addWorktree(path: repoRoot, existingBranch: branch.name)
                await finish(path: result.path)
            }
        } catch {
            failure = message(error)
        }
    }

    private func pick(_ path: String, label: String) async {
        failure = nil
        pendingLabel = label
        defer { pendingLabel = nil }
        await finish(path: path)
    }

    /// Lands the choice on the same hook the folder picker uses. The sheet
    /// stays up on failure with the reason attached — never a silent dismiss.
    private func finish(path: String) async {
        if let error = await apply(HostPath.display(path)) {
            failure = error
        } else {
            await loadLanes()
            dismiss()
        }
    }

    private func message(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}

/// The base-branch combobox (`base-branch-picker.tsx`). A filterable list, the
/// remote rows marked, the flagged default starred. Its own sheet rather than a
/// popover — a popover on a phone is a menu, and this list is 100+ rows deep on
/// a real repo.
@MainActor
private struct BaseBranchPicker: View {
    @Environment(\.hermes) private var t
    @Environment(\.dismiss) private var dismiss

    let branches: [GitBaseBranch]
    @Binding var selection: String

    @State private var filter = ""

    private var filtered: [GitBaseBranch] {
        let needle = filter.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return branches }
        return branches.filter { $0.name.lowercased().contains(needle) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Branch off")
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
            .padding(.bottom, Space.s4)

            TextField("Filter branches", text: $filter)
                .font(HermesFont.code)
                .foregroundStyle(t.text1)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .padding(Space.s4)
                .background(t.fill2, in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
                .padding(.horizontal, Space.s6)
                .padding(.bottom, Space.s4)
                .accessibilityLabel("Filter branches")

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(filtered) { branch in
                        Button {
                            selection = branch.name
                            dismiss()
                        } label: {
                            FlatRow {
                                HStack(spacing: Space.s3) {
                                    Text(verbatim: branch.isRemote ? "◇" : "◆")
                                        .font(HermesFont.caption)
                                        .foregroundStyle(t.text4)
                                        .accessibilityHidden(true)
                                    Text(branch.name)
                                        .font(HermesFont.code)
                                        .foregroundStyle(t.text1)
                                        .lineLimit(1)
                                        .truncationMode(.head)
                                }
                            } trailing: {
                                HStack(spacing: Space.s3) {
                                    if branch.isDefault {
                                        Text(verbatim: "★")
                                            .font(HermesFont.caption)
                                            .foregroundStyle(t.text4)
                                            .accessibilityLabel("Default branch")
                                    }
                                    if branch.name == selection {
                                        Image(systemName: "checkmark")
                                            .foregroundStyle(t.action)
                                    }
                                }
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.bottom, Space.s10)
            }
        }
        .background(t.canvas)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .presentationCornerRadius(Radius.sheet)
        .presentationBackground(t.canvas)
    }
}
