import HermesServeKit
import SwiftUI

/// The top-bar chip pair: the project you act on, and an adaptive branch chip for the line of work inside it.
@MainActor
struct WorkspaceChips: View {
    @Environment(\.hermes) private var t
    @Environment(AppModel.self) private var app

    /// The working directory the chips describe.
    let cwd: String
    /// Where a pick lands; returns an error to keep the sheet up, nil to dismiss it.
    let apply: (String) async -> String?

    @State private var resolution = Resolution()
    @State private var showingProjects = false
    @State private var showingWorktree = false

    var body: some View {
        // BUG-115: `WorkspaceChipsRow`, not an `HStack` — an `HStack` divides width; this row ranks it.
        WorkspaceChipsRow(spacing: Space.s3) {
            // BUG-063 (2): an invisible twin of the branch chip, so the project pill is centred whether or not the branch chip is there.
            branchChip
                .hidden()
                // `.hidden()` is a rendering change only: the button stays in the responder chain and the accessibility tree.
                .allowsHitTesting(false)
                .accessibilityHidden(true)
                .workspaceChipSlot(.shim)
            projectChip
                .workspaceChipSlot(.pill)
            branchChip
                .workspaceChipSlot(.branch)
        }
        // Keyed on the socket as well as the path: a chip mounted before the connection opens must resolve when it does, or it latches on the empty answer.
        .task(id: resolveKey) { await resolve() }
        .sheet(isPresented: $showingProjects) {
            ProjectPickerSheet(currentPath: effectiveCwd, apply: apply)
        }
        .sheet(isPresented: $showingWorktree) {
            WorktreeSheet(currentPath: effectiveCwd, apply: apply)
        }
    }

    private var resolveKey: String { "\(cwd)|\(app.connectionState.isOpen)" }

    /// The path the chips actually describe, identical to `cwd` except under the screenshot harness.
    private var effectiveCwd: String {
        #if DEBUG
        if let demo = Self.demo { return demo.cwd }
        #endif
        return cwd
    }

    // MARK: Project pill

    /// The 225 pt cap lives in `WorkspaceChipsRow.pillCap`: a `.frame(maxWidth:)` here would answer an unspecified proposal with the cap rather than the label's own width, starving the shim.
    private var projectChip: some View {
        ComposerPill(isInteractive: true, action: { showingProjects = true }) {
            HStack(spacing: Space.s3) {
                Circle()
                    .fill(dotColor)
                    .frame(width: 7, height: 7)
                    .accessibilityHidden(true)
                projectLabel
                Text(verbatim: "⌄")
                    .font(HermesFont.caption)
                    .foregroundStyle(t.text4)
                    .accessibilityHidden(true)
            }
        }
        .valueState(app.connectionState.isOpen ? .live : .stale)
        .accessibilityLabel(projectAccessibilityLabel)
    }

    @ViewBuilder
    private var projectLabel: some View {
        switch project {
        case .unknown:
            // `ValueState.unknown`: an em dash, never a spinner and never an error.
            Text(verbatim: "—")
                .foregroundStyle(t.text3)
                .accessibilityHidden(true)
        case .unselected:
            // A prompt, not a value: monospace here would read as a project literally called that.
            Text("No project")
                .font(HermesFont.subhead)
                .foregroundStyle(t.text3)
                .lineLimit(1)
        case .unnamed(let leaf, let isResolved):
            HStack(spacing: Space.s2) {
                Text(leaf)
                    .font(HermesFont.code)
                    .lineLimit(1)
                    // Tail, not head: names read left to right and the leading characters are the identifying ones.
                    .truncationMode(.tail)
                if isResolved {
                    // This directory is in no first-class project.
                    Text(verbatim: "◇")
                        .font(HermesFont.caption)
                        .foregroundStyle(t.text4)
                        .accessibilityHidden(true)
                }
            }
        case .named(let name):
            Text(name)
                .font(HermesFont.code)
                .lineLimit(1)
                .truncationMode(.tail)
        }
    }

    /// The dot is the connection, except with nothing to describe, where no value's freshness is being reported.
    private var dotColor: Color {
        switch project {
        case .unknown, .unselected: return t.text4
        case .named, .unnamed: break
        }
        switch app.connectionState {
        case .open: return t.ok
        case .connecting, .reconnecting: return t.warn
        case .offline, .unauthorized: return t.danger
        case .idle: return t.text4
        }
    }

    private var projectAccessibilityLabel: String {
        switch project {
        case .unknown: return "Project not reported"
        case .unselected: return "No project selected"
        case .unnamed(let leaf, _): return "Folder: \(leaf), not in a project"
        case .named(let name): return "Project: \(name)"
        }
    }

    // MARK: Branch chip — adaptive

    /// Width is spent only when it buys safety: a bare 44 pt glyph on the trunk, `t.warn` and the branch name anywhere else.
    /// It describes the repository the working directory is in, not the project, since `Project.repos` is an array.
    @ViewBuilder
    private var branchChip: some View {
        switch branch {
        case .removed:
            // Removed, not disabled: there is no repository to describe.
            EmptyView()
        case .bare:
            Button {
                showingWorktree = true
            } label: {
                Image(systemName: "arrow.triangle.branch")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(t.text3)
            }
            .buttonStyle(IconButtonStyle())
            .accessibilityLabel("Repository and branch")
        case .offTrunk(let name):
            ComposerPill(isInteractive: true, action: { showingWorktree = true }) {
                HStack(spacing: Space.s3) {
                    Image(systemName: "arrow.triangle.branch")
                        .font(.system(size: 13, weight: .medium))
                    Text(name)
                        .font(HermesFont.footnote)
                        .lineLimit(1)
                        // Head, as everywhere else this app draws a branch: branch names share long prefixes.
                        .truncationMode(.head)
                }
                .foregroundStyle(t.warn)
            }
            .frame(maxWidth: 102)
            .accessibilityLabel("Branch \(name), not the default branch")
        }
    }

    private enum BranchDisplay: Equatable {
        case removed
        case bare
        case offTrunk(String)
    }

    /// Fails toward bare: when the backend can name no trunk every branch reports `isDefault: false`, so all-false is unknown and not "off trunk".
    private var branch: BranchDisplay {
        switch project {
        case .unknown, .unselected: return .removed
        case .named, .unnamed: break
        }
        guard !resolution.branch.isEmpty else { return .removed }
        guard !resolution.defaultBranch.isEmpty else { return .bare }
        // A detached HEAD arrives as a short SHA, matches no branch name, and so lands in `offTrunk` carrying the SHA.
        return resolution.defaultBranch == resolution.branch ? .bare : .offTrunk(resolution.branch)
    }

    // MARK: State

    private enum ProjectDisplay: Equatable {
        /// Nothing has been able to say yet.
        case unknown
        /// Nothing selected at all.
        case unselected
        /// A directory that belongs to no first-class project; the bool is whether the backend has said so yet, since claiming `◇` early makes every chip flicker.
        case unnamed(String, isResolved: Bool)
        case named(String)
    }

    private var project: ProjectDisplay {
        guard !effectiveCwd.isEmpty else {
            // Not "there is no project" until the backend has had the chance to say so.
            return app.connectionState.isOpen ? .unselected : .unknown
        }
        if !resolution.projectName.isEmpty { return .named(resolution.projectName) }
        return .unnamed(HostPath.lastComponent(of: effectiveCwd), isResolved: resolution.didResolve)
    }

    /// What one `projects.for_cwd` answered, plus what the branch chip needs from `GET /api/git/branches`.
    private struct Resolution: Equatable {
        var projectName = ""
        var branch = ""
        /// The repo's trunk when the backend can name one; empty means unknown, not "off trunk".
        var defaultBranch = ""
        var didResolve = false
    }

    private func resolve() async {
        #if DEBUG
        if let demo = Self.demo {
            resolution = demo.resolution
            return
        }
        #endif
        guard app.connectionState.isOpen, !cwd.isEmpty else {
            resolution = Resolution()
            return
        }
        var next = Resolution()
        if let projectsAPI = app.projectsAPI,
           let answer = try? await projectsAPI.forCwd(cwd) {
            next.projectName = answer.project ?? ""
            next.branch = answer.branch
        }
        // `isDefault` exists nowhere on the projects payload, only on `GET /api/git/branches?path=`, which is one call per repository.
        if !next.branch.isEmpty, let git = app.gitAPI,
           let branches = try? await git.branches(path: cwd) {
            next.defaultBranch = branches.first(where: { $0.isDefault })?.name ?? ""
        }
        next.didResolve = true
        resolution = next
    }

    #if DEBUG
    /// Screenshot harness: `-hermesScreenshotWorkspace project|worktree|detached|unnamed`.
    private struct Demo {
        let cwd: String
        let resolution: Resolution
    }

    private static var demo: Demo? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "-hermesScreenshotWorkspace"),
              index + 1 < arguments.count else { return nil }
        let root = "/Users/you/Developer/myproject"
        switch arguments[index + 1] {
        case "project":
            // A named project sitting on its trunk: the chip is a bare glyph.
            return Demo(
                cwd: root,
                resolution: Resolution(
                    projectName: "hermesmobile", branch: "main",
                    defaultBranch: "main", didResolve: true
                )
            )
        case "worktree":
            // Off trunk with a trunk positively identified — the one case that earns the label.
            return Demo(
                cwd: "\(root)/.worktrees/feat-composer-chrome",
                resolution: Resolution(
                    projectName: "hermesmobile", branch: "feat/composer-chrome",
                    defaultBranch: "main", didResolve: true
                )
            )
        case "detached":
            return Demo(
                cwd: root,
                resolution: Resolution(
                    projectName: "hermesmobile", branch: "38ebc98",
                    defaultBranch: "main", didResolve: true
                )
            )
        case "unknown-trunk":
            // The field case: `isDefault` false on every row, which must render bare and not like `worktree`.
            return Demo(
                cwd: root,
                resolution: Resolution(
                    projectName: "hermesmobile", branch: "feat/composer-chrome",
                    defaultBranch: "", didResolve: true
                )
            )
        case "unnamed":
            return Demo(
                cwd: "/Users/you/Desktop/scratch",
                resolution: Resolution(branch: "main", defaultBranch: "main", didResolve: true)
            )
        case "long":
            // BUG-115's long end: 40 characters, so the pass is that it fills the row and truncates at the cap, not that it fits.
            return Demo(
                cwd: root,
                resolution: Resolution(
                    projectName: "an-extremely-long-project-name-goes-here",
                    branch: "main", defaultBranch: "main", didResolve: true
                )
            )
        case "short":
            // BUG-115's short end: three characters, which must read in full.
            return Demo(
                cwd: "\(root)/api",
                resolution: Resolution(
                    projectName: "api",
                    branch: "main", defaultBranch: "main", didResolve: true
                )
            )
        default:
            return nil
        }
    }
    #endif
}

// MARK: - The project picker

/// What the project pill opens; rows are `projects.tree`'s own and carry no branch state, because `isDefault` is one request per repository.
@MainActor
struct ProjectPickerSheet: View {
    @Environment(\.hermes) private var t
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss

    let currentPath: String
    let apply: (String) async -> String?

    @State private var projects: [ProjectsAPI.Project] = []
    @State private var loading = true
    @State private var failure: String?
    @State private var pendingID: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            // A failure lives outside the scroll content, so it cannot be scrolled away from the control that produced it.
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
                    if loading && projects.isEmpty {
                        HStack(spacing: Space.s4) {
                            ProgressView().controlSize(.small)
                            Text("Loading projects…")
                                .font(HermesFont.footnote)
                                .foregroundStyle(t.text3)
                        }
                        .padding(Space.s6)
                    } else {
                        ForEach(rows) { row in
                            projectRow(row)
                        }
                        // Keyed on there being no named project, not on there being no rows: the "No project" pin is always there once the backend names its default.
                        if !rows.contains(where: { !$0.isHome }) {
                            Text("No projects on this backend yet. Pick a working directory from the + sheet — a folder becomes a project once it is named one.")
                                .font(HermesFont.footnote)
                                .foregroundStyle(t.text3)
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(Space.s6)
                        }
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
        .task(id: app.connectionState.isOpen) { await load() }
    }

    private var header: some View {
        HStack(spacing: Space.s3) {
            Text("Projects")
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

    /// One selectable project: a name, and the path the pick will land on.
    struct Row: Identifiable, Equatable {
        let id: String
        /// What the row is, which is not necessarily what it draws; see `displayLabel`.
        let label: String
        let path: String
        /// The pinned "No project" row, this client's and not the backend's, set on exactly one row or none.
        var isHome = false

        /// What the row draws (FEAT-033 (c)): the directory name, falling back to `label` at a filesystem root, which `HostPath.lastComponent` hands back whole rather than empty.
        var displayLabel: String {
            guard isHome else { return label }
            let leaf = HostPath.lastComponent(of: path)
            guard !leaf.isEmpty, !leaf.contains("/") else { return label }
            return leaf
        }
    }

    /// The id of the pinned row; not a project id, since the wire has no project it corresponds to.
    static let homeRowID = "hermes.project.none"

    /// A project with nowhere to go is dropped, and BUG-045's pinned "No project" row applies `AppModel.defaultCwd` so the sheet is not a one-way door.
    static func rows(projects: [ProjectsAPI.Project], defaultCwd: String) -> [Row] {
        // The closure's return type is spelled out because a multi-statement closure gives the compiler nothing to infer `ElementOfResult` from.
        let named: [Row] = projects
            .filter { !$0.isNoProject }
            .compactMap { project -> Row? in
                let path = project.path.isEmpty
                    ? (project.repos.first(where: { !$0.path.isEmpty })?.path ?? "")
                    : project.path
                guard !path.isEmpty else { return nil }
                return Row(id: project.id, label: project.label, path: path)
            }
            .sorted { $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending }

        // No default, no row: a pin applied with an empty path would blank the draft rather than clear it.
        let home = defaultCwd.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !home.isEmpty else { return named }
        return [Row(id: homeRowID, label: "No project", path: home, isHome: true)] + named
    }

    private var rows: [Row] {
        Self.rows(projects: projects, defaultCwd: app.defaultCwd)
    }

    private func projectRow(_ row: Row) -> some View {
        Button {
            Task { await pick(row) }
        } label: {
            FlatRow {
                VStack(alignment: .leading, spacing: Space.s1) {
                    Text(row.displayLabel)
                        .font(HermesFont.callout)
                        .foregroundStyle(t.text1)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    // The path stays visible here rather than in the top bar: it is what you check when two projects share a name.
                    Text(HostPath.display(row.path))
                        .font(HermesFont.code)
                        .foregroundStyle(t.text3)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
            } trailing: {
                if pendingID == row.id {
                    ProgressView().controlSize(.small)
                } else if HostPath.isSame(row.path, currentPath) {
                    Image(systemName: "checkmark")
                        .foregroundStyle(t.action)
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(pendingID != nil)
        // "Project No project" is not a sentence, and the pin draws a directory name, so the spoken label is the one place that carries both.
        .accessibilityLabel(
            row.isHome
                ? "\(row.displayLabel), the backend's default directory. No project"
                : "Project \(row.label)"
        )
    }

    private func load() async {
        guard let projectsAPI = app.projectsAPI else {
            loading = false
            failure = "Not connected to a backend."
            return
        }
        loading = true
        defer { loading = false }
        failure = nil
        do {
            projects = try await projectsAPI.tree()
        } catch {
            failure = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    /// Lands on the shared apply hook; the sheet stays up on failure with the reason attached.
    private func pick(_ row: Row) async {
        failure = nil
        pendingID = row.id
        defer { pendingID = nil }
        if let error = await apply(row.path) {
            failure = error
        } else {
            dismiss()
        }
    }
}

// MARK: - BUG-115: how the top bar's three slots share one row

/// Three ranked slots: the branch chip is never compressed, the pill takes what its label needs up to `pillCap`, and the centring shim gets what is left.
/// `budget` is exactly the width an `HStack` would have taken here, so the row's footprint is unchanged.
struct WorkspaceChipsRow: Layout {
    /// The gap charged between two adjacent slots that both have width.
    var spacing: CGFloat = Space.s3
    /// The pill's ceiling; past this a project name stops being a label and starts being the bar.
    var pillCap: CGFloat = WorkspaceChipsRow.pillCapDefault
    /// The branch chip's ceiling, so "never compressed" does not become "takes whatever a 60-character branch name asks for".
    var branchCap: CGFloat = WorkspaceChipsRow.branchCapDefault

    static let pillCapDefault: CGFloat = 225
    static let branchCapDefault: CGFloat = 102

    /// What each slot ends up with.
    struct Widths: Equatable {
        var shim: CGFloat = 0
        var pill: CGFloat = 0
        var branch: CGFloat = 0
        /// The row's own width: the slots that have width, plus one gap between each adjacent pair, since a slot at zero is charged no gap.
        var total: CGFloat = 0
    }

    /// The whole rule, as arithmetic; `budget` is never exceeded.
    static func resolve(
        budget: CGFloat,
        shimIdeal: CGFloat,
        pillWanted: CGFloat,
        branchIdeal: CGFloat,
        spacing: CGFloat
    ) -> Widths {
        var widths = Widths()
        widths.branch = max(0, min(branchIdeal, budget))
        var remaining = budget - widths.branch - (widths.branch > 0 ? spacing : 0)
        widths.pill = max(0, min(pillWanted, remaining))
        remaining -= widths.pill + (widths.pill > 0 ? spacing : 0)
        widths.shim = max(0, min(shimIdeal, remaining))

        let present = [widths.shim, widths.pill, widths.branch].filter { $0 > 0 }
        widths.total = present.reduce(0, +) + CGFloat(max(0, present.count - 1)) * spacing
        return widths
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let slots = Slots(subviews: subviews, branchCap: branchCap, pillCap: pillCap, spacing: spacing)
        let widths = Self.resolve(
            budget: budget(for: proposal, slots: slots),
            shimIdeal: slots.shimIdeal,
            pillWanted: slots.pillWanted,
            branchIdeal: slots.branchIdeal,
            spacing: spacing
        )
        return CGSize(width: widths.total, height: slots.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let slots = Slots(subviews: subviews, branchCap: branchCap, pillCap: pillCap, spacing: spacing)
        // The granted width, not the proposal: placing against anything else is how a row draws outside itself.
        let widths = Self.resolve(
            budget: max(0, bounds.width),
            shimIdeal: slots.shimIdeal,
            pillWanted: slots.pillWanted,
            branchIdeal: slots.branchIdeal,
            spacing: spacing
        )
        var x = bounds.minX
        for (index, width) in [
            (slots.shimIndex, widths.shim),
            (slots.pillIndex, widths.pill),
            (slots.branchIndex, widths.branch),
        ] {
            guard let index, width > 0 else { continue }
            subviews[index].place(
                at: CGPoint(x: x, y: bounds.midY),
                anchor: .leading,
                proposal: ProposedViewSize(width: width, height: bounds.height)
            )
            x += width + spacing
        }
    }

    /// A concrete proposal is treated as a floor rather than a ceiling, because `HomeView`'s bar hands down `remaining / 3`, which is not the width that is free.
    private func budget(for proposal: ProposedViewSize, slots: Slots) -> CGFloat {
        guard let width = proposal.width, width != .infinity else { return slots.idealTotal }
        return max(width, slots.minimumTotal)
    }

    /// The three slots, found by their `layoutValue` rather than by position: a `branchChip` that resolves to `EmptyView` contributes no subview, and indexing 0/1/2 through that gap makes the pill the shim.
    private struct Slots {
        var shimIndex: Int?
        var pillIndex: Int?
        var branchIndex: Int?
        var shimIdeal: CGFloat = 0
        var pillWanted: CGFloat = 0
        var pillMinimum: CGFloat = 0
        var branchIdeal: CGFloat = 0
        var height: CGFloat = 0
        var idealTotal: CGFloat = 0
        var minimumTotal: CGFloat = 0

        init(subviews: LayoutSubviews, branchCap: CGFloat, pillCap: CGFloat, spacing: CGFloat) {
            for index in subviews.indices {
                let ideal = subviews[index].sizeThatFits(.unspecified)
                height = max(height, ideal.height)
                switch subviews[index][WorkspaceChipSlotKey.self] {
                case .shim:
                    shimIndex = index
                    shimIdeal = min(ideal.width, branchCap)
                case .pill:
                    pillIndex = index
                    pillWanted = min(ideal.width, pillCap)
                    pillMinimum = subviews[index].sizeThatFits(ProposedViewSize(width: 0, height: nil)).width
                case .branch:
                    branchIndex = index
                    branchIdeal = min(ideal.width, branchCap)
                }
            }
            idealTotal = Self.row([shimIdeal, pillWanted, branchIdeal], spacing: spacing)
            minimumTotal = Self.row([shimIdeal, pillMinimum, branchIdeal], spacing: spacing)
        }

        private static func row(_ widths: [CGFloat], spacing: CGFloat) -> CGFloat {
            let present = widths.filter { $0 > 0 }
            return present.reduce(0, +) + CGFloat(max(0, present.count - 1)) * spacing
        }
    }
}

/// Which of `WorkspaceChipsRow`'s three slots a subview is.
enum WorkspaceChipSlot {
    case shim
    case pill
    case branch
}

struct WorkspaceChipSlotKey: LayoutValueKey {
    static let defaultValue = WorkspaceChipSlot.pill
}

extension View {
    func workspaceChipSlot(_ slot: WorkspaceChipSlot) -> some View {
        layoutValue(key: WorkspaceChipSlotKey.self, value: slot)
    }
}
