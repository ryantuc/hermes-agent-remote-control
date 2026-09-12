import Foundation

/// `projects.*` — the workspace graph, loaded once and cached until refresh; there is no pagination.
public struct ProjectsAPI: Sendable {
    private let client: HermesClient

    public init(client: HermesClient) {
        self.client = client
    }

    /// One lane (worktree or trunk checkout) inside a repo; `sessions` is empty unless the tree was hydrated by `projects.project_sessions`.
    public struct Lane: Sendable, Equatable, Identifiable {
        public let id: String
        public let label: String
        public let path: String
        public let isMain: Bool
        public let sessions: [SessionSummary]

        public init(json: JSONValue) {
            id = json["id"]?.coercedString ?? ""
            label = json["label"]?.coercedString ?? ""
            path = json["path"]?.coercedString ?? ""
            isMain = json["isMain"]?.coercedBool ?? false
            sessions = (json["sessions"]?.arrayValue ?? []).map(SessionSummary.init(json:))
        }
    }

    public struct Repo: Sendable, Equatable, Identifiable {
        public let id: String
        public let label: String
        public let path: String
        public let sessionCount: Int
        public let lanes: [Lane]

        public init(json: JSONValue) {
            id = json["id"]?.coercedString ?? ""
            label = json["label"]?.coercedString ?? ""
            path = json["path"]?.coercedString ?? ""
            sessionCount = json["sessionCount"]?.coercedInt ?? 0
            lanes = (json["groups"]?.arrayValue ?? []).map(Lane.init(json:))
        }
    }

    public struct Project: Sendable, Equatable, Identifiable {
        public let id: String
        public let label: String
        public let path: String
        public let isNoProject: Bool
        public let sessionCount: Int
        public let lastActive: Double
        public let repos: [Repo]

        public init(json: JSONValue) {
            id = json["id"]?.coercedString ?? ""
            label = json["label"]?.coercedString ?? ""
            path = json["path"]?.coercedString ?? ""
            isNoProject = json["isNoProject"]?.coercedBool ?? false
            sessionCount = json["sessionCount"]?.coercedInt ?? 0
            lastActive = json["lastActive"]?.coercedDouble ?? 0
            repos = (json["repos"]?.arrayValue ?? []).map(Repo.init(json:))
        }
    }

    public struct DiscoveredRepo: Sendable, Equatable, Identifiable {
        public let root: String
        public let label: String
        public let sessions: Int
        public let lastActive: Double
        public var id: String { root }

        public init(json: JSONValue) {
            root = json["root"]?.coercedString ?? ""
            label = json["label"]?.coercedString ?? ""
            sessions = json["sessions"]?.coercedInt ?? 0
            lastActive = json["last_active"]?.coercedDouble ?? 0
        }
    }

    /// `projects.tree` — lanes unhydrated (preview only); not paginated, so cap `session_limit`.
    public func tree(previewLimit: Int = 3, sessionLimit: Int = 2000) async throws -> [Project] {
        let result = try await client.request("projects.tree", params: .object([
            "preview_limit": .number(Double(previewLimit)),
            "session_limit": .number(Double(sessionLimit)),
        ]))
        return (result["projects"]?.arrayValue ?? []).map(Project.init(json:))
    }

    /// `projects.project_sessions` — one project fully hydrated (repo → lane → session rows).
    public func projectSessions(projectID: String) async throws -> Project? {
        let result = try await client.request("projects.project_sessions", params: .object([
            "project_id": .string(projectID),
        ]))
        guard let json = result["project"], json != .null else { return nil }
        return Project(json: json)
    }

    /// `projects.discover_repos` — the flat repo list behind the cwd picker's one-tap targets.
    /// FEAT-013: `scan: true` makes the backend walk its own discovery-policy roots for `.git` before answering, so send it only on an explicit refresh — it is a synchronous disk walk inside the RPC, and a backend too old to know the parameter ignores it.
    public func discoverRepos(scan: Bool = false) async throws -> [DiscoveredRepo] {
        let params: JSONValue = scan ? .object(["scan": .bool(true)]) : .object([:])
        let result = try await client.request("projects.discover_repos", params: params)
        return (result["repos"]?.arrayValue ?? []).map(DiscoveredRepo.init(json:))
    }

    /// `projects.for_cwd` — name a path with its project and branch; one call answers both chips in the top bar.
    /// The project name key is `name`, not the `label` that `projects.tree` synthesises for its own nodes; `label` is read only as a fallback.
    /// `branch` falls back to a short HEAD SHA, so a detached HEAD arrives as a SHA rather than an empty string.
    public func forCwd(_ cwd: String) async throws -> (project: String?, branch: String) {
        let result = try await client.request("projects.for_cwd", params: .object([
            "cwd": .string(cwd),
        ]))
        let project = result["project"]?["name"]?.coercedString
            ?? result["project"]?["label"]?.coercedString
        return (project: project, branch: result["branch"]?.coercedString ?? "")
    }
}
