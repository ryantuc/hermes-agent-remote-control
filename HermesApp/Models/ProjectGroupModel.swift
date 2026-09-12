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

    static let expansionKey = "hermes.hub.projects.expanded"

    init() {
        expanded = Set(UserDefaults.standard.stringArray(forKey: Self.expansionKey) ?? [])
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
        UserDefaults.standard.set(Array(expanded), forKey: Self.expansionKey)
    }

    func load(api: ProjectsAPI?, force: Bool) async {
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
        defer { loading = false }
        loadError = nil
        do {
            projects = try await api.tree()
            // BUG-005: projects persisted as expanded hydrate now, not after a collapse and re-expand on the next hub open.
            hydrateExpanded(api: api)
        } catch {
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
        defer { hydrateTasks[projectID] = nil }
        do {
            if let full = try await api.projectSessions(projectID: projectID) {
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
