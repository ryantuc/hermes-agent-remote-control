import Foundation
import HermesServeKit
import Observation

/// The hub's Projects-mode state machine, extracted from `ProjectGroupList` so the app-layer tests can pin it (BUG-005).
///
/// `projects.tree` is expensive server-side, so it loads once per hub visit and an in-flight hydrate is never duplicated and never thrown away on collapse.
///
/// The invariant: `sectionBody(for:)` is nil iff the project is collapsed, so the chevron can never say "expanded" over an empty body.
@MainActor
@Observable
final class ProjectGroupModel {
    /// What an expanded section shows; `loading` is the default rather than a flag, because expanded without rows or an error is loading.
    enum SectionBody: Equatable {
        case rows(ProjectsAPI.Project)
        case loading
        case error(String)
    }

    private(set) var projects: [ProjectsAPI.Project] = []
    private(set) var loading = false
    private(set) var loadError: String?

    private var hydrated: [String: ProjectsAPI.Project] = [:]
    private var hydrationErrors: [String: String] = [:]
    /// At most one in-flight hydrate per project id; entries are removed by the task itself, so the de-dupe guard holds across a cancel that has not unwound yet.
    private var hydrateTasks: [String: Task<Void, Never>] = [:]
    private var expanded: Set<String>
    /// The backend whose projects and expansion set these are (BUG-143); captured at init because the hub builds this model with no arguments, and re-read on every `load` so a model that outlives a backend switch does not open the previous machine's groups.
    private var backendID: UUID?
    private let defaults: UserDefaults

    /// The pre-BUG-143 key: one set of project paths shared by every backend. The first backend to load adopts it and it is removed, so no second backend inherits it.
    static let expansionKey = "hermes.hub.projects.expanded"

    /// One set per backend profile, like `LastProjectStore`: a project id is a path, and two machines can share one.
    static func backendExpansionKey(_ backendID: UUID?) -> String {
        Self.expansionKey + "." + (backendID?.uuidString ?? "none")
    }

    init(backendID: UUID? = BackendProfileStore.loadActiveID(), defaults: UserDefaults = .standard) {
        self.backendID = backendID
        self.defaults = defaults
        expanded = Self.loadExpansion(backendID: backendID, defaults: defaults)
    }

    private static func loadExpansion(backendID: UUID?, defaults: UserDefaults) -> Set<String> {
        let key = backendExpansionKey(backendID)
        if let own = defaults.stringArray(forKey: key) { return Set(own) }
        guard let shared = defaults.stringArray(forKey: Self.expansionKey) else { return [] }
        defaults.set(shared, forKey: key)
        defaults.removeObject(forKey: Self.expansionKey)
        return Set(shared)
    }

    /// Drop a deleted backend's expansion set.
    static func forgetExpansion(backendID: UUID, defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: backendExpansionKey(backendID))
    }

    /// The active backend changed under a live model: start over as if built for it, dropping every cached tree, hydrate and error from the previous machine.
    private func rebindIfBackendChanged(to current: UUID?) {
        guard current != backendID else { return }
        backendID = current
        expanded = Self.loadExpansion(backendID: current, defaults: defaults)
        for task in hydrateTasks.values { task.cancel() }
        hydrateTasks = [:]
        hydrated = [:]
        hydrationErrors = [:]
        projects = []
        loading = false
        loadError = nil
    }

    // MARK: Render inputs

    /// Empty projects do not render, and "No project" sinks to the bottom like the desktop.
    var displayProjects: [ProjectsAPI.Project] {
        projects
            .filter { $0.sessionCount > 0 }
            .sorted { a, b in
                if a.isNoProject != b.isNoProject { return !a.isNoProject }
                return a.lastActive > b.lastActive
            }
    }

    func isExpanded(_ projectID: String) -> Bool { expanded.contains(projectID) }

    func sectionBody(for projectID: String) -> SectionBody? {
        guard expanded.contains(projectID) else { return nil }
        if let full = hydrated[projectID] { return .rows(full) }
        if let message = hydrationErrors[projectID] { return .error(message) }
        return .loading
    }

    // MARK: Actions

    func toggle(_ projectID: String, api: ProjectsAPI?) {
        if expanded.contains(projectID) {
            expanded.remove(projectID)
            // The in-flight hydrate, if any, keeps running: its result fills the cache the re-expand reads.
        } else {
            expanded.insert(projectID)
            ensureHydrated(projectID, api: api)
        }
        defaults.set(Array(expanded), forKey: Self.backendExpansionKey(backendID))
    }

    func load(api: ProjectsAPI?, force: Bool, activeBackendID: UUID? = BackendProfileStore.loadActiveID()) async {
        rebindIfBackendChanged(to: activeBackendID)
        let owner = backendID
        guard force || projects.isEmpty, !loading else {
            // `.task` re-fired on a warm model: heal any expanded section whose hydrate was cancelled on disappear.
            hydrateExpanded(api: api)
            return
        }
        guard let api else {
            loadError = "Not connected to a backend."
            return
        }
        loading = true
        defer { if owner == backendID { loading = false } }
        loadError = nil
        do {
            let tree = try await api.tree()
            // A tree that set out before a backend switch is the previous machine's.
            guard owner == backendID else { return }
            projects = tree
            // BUG-005: projects persisted as expanded hydrate now, not after a collapse and re-expand on the next hub open.
            hydrateExpanded(api: api)
        } catch {
            guard owner == backendID else { return }
            loadError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    /// Start a hydrate unless the rows are cached or one is in flight for this id; also the retry affordance, since entering clears a previous error.
    func ensureHydrated(_ projectID: String, api: ProjectsAPI?) {
        guard hydrated[projectID] == nil, hydrateTasks[projectID] == nil else { return }
        hydrationErrors[projectID] = nil
        guard let api else {
            hydrationErrors[projectID] = "Not connected to a backend."
            return
        }
        hydrateTasks[projectID] = Task { await hydrate(projectID, api: api) }
    }

    /// The hub closed; `client.request` is not cancellation-aware, so this does not interrupt the wire call, only stops a late failure from writing state nobody renders.
    func cancelHydration() {
        for task in hydrateTasks.values { task.cancel() }
    }

    private func hydrateExpanded(api: ProjectsAPI?) {
        for project in displayProjects where expanded.contains(project.id) {
            ensureHydrated(project.id, api: api)
        }
    }

    private func hydrate(_ projectID: String, api: ProjectsAPI) async {
        let owner = backendID
        // After a backend switch the task table was rebuilt, and this entry is no longer ours to clear.
        defer { if owner == backendID { hydrateTasks[projectID] = nil } }
        do {
            let full = try await api.projectSessions(projectID: projectID)
            guard owner == backendID else { return }
            if let full {
                hydrated[projectID] = full
            } else {
                // The backend answered but knows no such project, and BUG-005 says that is surfaced, never blank.
                hydrationErrors[projectID] = "This project is no longer on the backend."
            }
        } catch is CancellationError {
            // Cancelled on hub close; no one renders this state.
        } catch {
            guard !Task.isCancelled else { return }
            hydrationErrors[projectID] = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }
}
