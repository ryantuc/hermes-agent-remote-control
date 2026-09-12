import Foundation

// MARK: - Host paths

/// Path arithmetic for a filesystem that is not this device's.
/// The gateway may be Windows and its routes disagree about separators — one answer can mix both in a single string — so no path comparison in this app may use `==`; every one goes through `isSame`.
public enum HostPath: Sendable {
    /// `C:\…`, `\\server\share`, or any path carrying a backslash.
    public static func looksWindows(_ path: String) -> Bool {
        if path.contains("\\") { return true }
        guard path.count >= 2 else { return false }
        let chars = Array(path)
        return chars[0].isLetter && chars[1] == ":"
    }

    public static func separator(of path: String) -> String {
        looksWindows(path) ? "\\" : "/"
    }

    /// Separators folded to `/` and trailing separators dropped (the root keeps its own); for comparison and decomposition, not display.
    public static func normalized(_ path: String) -> String {
        var value = path.replacingOccurrences(of: "\\", with: "/")
        while value.count > 1, value.hasSuffix("/"), !isRoot(value) {
            value.removeLast()
        }
        return value
    }

    /// The comparison every caller must use; Windows paths additionally fold case, because the host does.
    public static func isSame(_ lhs: String, _ rhs: String) -> Bool {
        let a = normalized(lhs)
        let b = normalized(rhs)
        if looksWindows(lhs) || looksWindows(rhs) {
            return a.compare(b, options: .caseInsensitive) == .orderedSame
        }
        return a == b
    }

    /// `/` on POSIX; `C:/` (normalized) or `//server` on Windows.
    private static func isRoot(_ normalizedPath: String) -> Bool {
        if normalizedPath == "/" { return true }
        if normalizedPath.hasSuffix(":/"), normalizedPath.count == 3 { return true }
        return false
    }

    public static func lastComponent(of path: String) -> String {
        let value = normalized(path)
        guard let index = value.lastIndex(of: "/") else { return value }
        let tail = String(value[value.index(after: index)...])
        return tail.isEmpty ? value : tail
    }

    /// `nil` at a root, so the browser drops its `..` row there rather than walking into nothing.
    public static func parent(of path: String) -> String? {
        let windows = looksWindows(path)
        let value = normalized(path)
        if isRoot(value) { return nil }
        guard let index = value.lastIndex(of: "/") else { return nil }
        var head = String(value[value.startIndex..<index])
        if head.isEmpty { head = "/" }
        if head.hasSuffix(":") { head += "/" }
        if isRoot(head), head == value { return nil }
        return windows ? display(head) : head
    }

    public static func joining(_ path: String, _ component: String) -> String {
        let sep = separator(of: path)
        var head = path
        while head.count > 1, head.hasSuffix("/") || head.hasSuffix("\\") {
            head.removeLast()
        }
        if head.hasSuffix(":") { return head + sep + component }
        if head == "/" { return "/" + component }
        return head + sep + component
    }

    /// Back to the host's own separator, for a path we assembled ourselves.
    public static func display(_ path: String) -> String {
        looksWindows(path) ? path.replacingOccurrences(of: "/", with: "\\") : path
    }

    /// The breadcrumb, root first; each crumb carries the absolute path selecting it navigates to.
    public static func breadcrumb(_ path: String) -> [Crumb] {
        let windows = looksWindows(path)
        let value = normalized(path)
        guard !value.isEmpty else { return [] }

        var crumbs: [Crumb] = []
        var pieces = value.split(separator: "/", omittingEmptySubsequences: false).map(String.init)

        var accumulated: String
        if windows {
            let drive = pieces.first ?? ""
            accumulated = drive + "/"
            crumbs.append(Crumb(name: drive, path: display(accumulated)))
            pieces.removeFirst()
        } else {
            accumulated = "/"
            crumbs.append(Crumb(name: "/", path: "/"))
            if !pieces.isEmpty, pieces[0].isEmpty { pieces.removeFirst() }
        }

        for piece in pieces where !piece.isEmpty {
            accumulated = accumulated.hasSuffix("/") ? accumulated + piece : accumulated + "/" + piece
            crumbs.append(Crumb(name: piece, path: windows ? display(accumulated) : accumulated))
        }
        return crumbs
    }

    public struct Crumb: Sendable, Equatable, Identifiable {
        public let name: String
        public let path: String
        public var id: String { path }

        public init(name: String, path: String) {
            self.name = name
            self.path = path
        }
    }
}

// MARK: - Git refs

/// The branch-name sanitiser, applied as you type.
/// It deliberately does not strip trailing `-./` the way the backend does, because that would make `ios/` un-typable; the backend re-sanitises on submit.
public enum GitRef: Sendable {
    public static func sanitize(_ raw: String) -> String {
        var value = raw
        value = value.replacingOccurrences(of: "\\s+", with: "-", options: .regularExpression)
        value = value.replacingOccurrences(of: "[^\\w./-]", with: "", options: .regularExpression)
        value = value.replacingOccurrences(of: "-{2,}", with: "-", options: .regularExpression)
        value = value.replacingOccurrences(of: "/{2,}", with: "/", options: .regularExpression)
        value = value.replacingOccurrences(of: "\\.{2,}", with: ".", options: .regularExpression)
        value = value.replacingOccurrences(of: "^[-./]+", with: "", options: .regularExpression)
        return value
    }
}

// MARK: - Models

/// One row of `GET /api/git/worktrees`; `branch` is `null` on a detached head.
public struct GitWorktree: Sendable, Equatable, Identifiable {
    public let path: String
    public let branch: String
    public let isMain: Bool
    public let detached: Bool
    public let locked: Bool
    public var id: String { path }

    public init(json: JSONValue) {
        path = json["path"]?.coercedString ?? ""
        branch = json["branch"]?.coercedString ?? ""
        isMain = json["isMain"]?.coercedBool ?? false
        detached = json["detached"]?.coercedBool ?? false
        locked = json["locked"]?.coercedBool ?? false
    }

    /// The lane row's trailing note.
    public var laneNote: String { isMain ? "home" : "worktree" }

    /// The lane's own name: the branch when it has one, otherwise the leaf directory, because a detached lane still has to be nameable.
    public var label: String {
        branch.isEmpty ? HostPath.lastComponent(of: path) : branch
    }
}

/// One row of `GET /api/git/branches`.
public struct GitBranch: Sendable, Equatable, Identifiable {
    public let name: String
    public let checkedOut: Bool
    public let isDefault: Bool
    public let worktreePath: String?
    public var id: String { name }

    public init(json: JSONValue) {
        name = json["name"]?.coercedString ?? ""
        checkedOut = json["checkedOut"]?.coercedBool ?? false
        isDefault = json["isDefault"]?.coercedBool ?? false
        let path = json["worktreePath"]?.coercedString
        worktreePath = (path?.isEmpty == false) ? path : nil
    }

    init(name: String, checkedOut: Bool, isDefault: Bool, worktreePath: String?) {
        self.name = name
        self.checkedOut = checkedOut
        self.isDefault = isDefault
        self.worktreePath = worktreePath
    }

    /// What selecting this row will do, as its trailing label.
    public enum Action: String, Sendable, Equatable {
        case openExisting
        case switchHome
        case createWorktree

        public var label: String {
            switch self {
            case .openExisting: return "Open existing"
            case .switchHome: return "Switch home"
            case .createWorktree: return "Create worktree"
            }
        }
    }

    public var action: Action {
        if checkedOut { return .openExisting }
        return isDefault ? .switchHome : .createWorktree
    }
}

/// One row of `GET /api/git/base-branches`.
public struct GitBaseBranch: Sendable, Equatable, Identifiable {
    public let name: String
    public let isRemote: Bool
    public let isDefault: Bool
    public var id: String { name }

    public init(json: JSONValue) {
        name = json["name"]?.coercedString ?? ""
        isRemote = json["isRemote"]?.coercedBool ?? false
        isDefault = json["isDefault"]?.coercedBool ?? false
    }

    init(name: String, isRemote: Bool, isDefault: Bool) {
        self.name = name
        self.isRemote = isRemote
        self.isDefault = isDefault
    }

    /// The picker's opening value: `origin/HEAD` when the backend flags one, otherwise the most recently committed ref, since a repo with no `origin/HEAD` returns `isDefault: false` on every row.
    public static func preferred(in branches: [GitBaseBranch]) -> GitBaseBranch? {
        branches.first(where: \.isDefault) ?? branches.first
    }
}

public struct WorktreeAddResult: Sendable, Equatable {
    public let path: String
    public let branch: String
    public let repoRoot: String

    public init(json: JSONValue) {
        path = json["path"]?.coercedString ?? ""
        branch = json["branch"]?.coercedString ?? ""
        repoRoot = json["repoRoot"]?.coercedString ?? ""
    }
}

/// One row of `GET /api/fs/list`.
public struct DirectoryEntry: Sendable, Equatable, Identifiable {
    public let name: String
    public let path: String
    public let isDirectory: Bool
    public var id: String { path }

    public init(json: JSONValue) {
        name = json["name"]?.coercedString ?? ""
        path = json["path"]?.coercedString ?? ""
        isDirectory = json["isDirectory"]?.coercedBool ?? false
    }

    init(name: String, path: String, isDirectory: Bool) {
        self.name = name
        self.path = path
        self.isDirectory = isDirectory
    }
}

/// `GET /api/fs/list` answers an unreadable directory with HTTP 200 and an `error` string rather than a status code, so a caller that only catches thrown errors would render it as convincingly empty.
public struct DirectoryListing: Sendable, Equatable {
    public let entries: [DirectoryEntry]
    public let error: String?

    public var directories: [DirectoryEntry] { entries.filter(\.isDirectory) }

    /// Human copy for the four codes the route actually emits.
    public var errorMessage: String? {
        switch error {
        case .none: return nil
        case .some("ENOENT"): return "That folder no longer exists on the host."
        case .some("ENOTDIR"): return "That path is a file, not a folder."
        case .some("EACCES"): return "The gateway is not allowed to read that folder."
        case .some(let raw): return raw
        }
    }
}

// MARK: - GitAPI

/// The remote half of the desktop's coding rail and the host directory browser; all REST, no RPC.
public struct GitAPI: Sendable {
    private let rest: RestAPI

    public init(rest: RestAPI) {
        self.rest = rest
    }

    // MARK: Git

    public func worktrees(path: String) async throws -> [GitWorktree] {
        let json = try await rest.getJSON("/api/git/worktrees", query: [URLQueryItem(name: "path", value: path)])
        return (json["worktrees"]?.arrayValue ?? []).map(GitWorktree.init(json:))
    }

    public func branches(path: String) async throws -> [GitBranch] {
        let json = try await rest.getJSON("/api/git/branches", query: [URLQueryItem(name: "path", value: path)])
        return (json["branches"]?.arrayValue ?? []).map(GitBranch.init(json:))
    }

    public func baseBranches(path: String) async throws -> [GitBaseBranch] {
        let json = try await rest.getJSON("/api/git/base-branches", query: [URLQueryItem(name: "path", value: path)])
        return (json["branches"]?.arrayValue ?? []).map(GitBaseBranch.init(json:))
    }

    /// `POST /api/git/worktree/add`; a rejected add is a 400 with git's stderr in `detail`, which is surfaced verbatim rather than summarised.
    @discardableResult
    public func addWorktree(
        path: String,
        name: String? = nil,
        branch: String? = nil,
        base: String? = nil,
        existingBranch: String? = nil
    ) async throws -> WorktreeAddResult {
        var body: [String: JSONValue] = ["path": .string(path)]
        if let name, !name.isEmpty { body["name"] = .string(name) }
        if let branch, !branch.isEmpty { body["branch"] = .string(branch) }
        if let base, !base.isEmpty { body["base"] = .string(base) }
        if let existingBranch, !existingBranch.isEmpty { body["existingBranch"] = .string(existingBranch) }
        let json = try await rest.sendJSON("POST", "/api/git/worktree/add", body: .object(body))
        return WorktreeAddResult(json: json)
    }

    /// `POST /api/git/worktree/remove`; no UI surface yet, because removing a lane is destructive and needs a hold-to-confirm affordance.
    public func removeWorktree(path: String, worktreePath: String, force: Bool = false) async throws {
        _ = try await rest.sendJSON("POST", "/api/git/worktree/remove", body: .object([
            "path": .string(path),
            "worktreePath": .string(worktreePath),
            "force": .bool(force),
        ]))
    }

    /// `POST /api/git/branch/switch` — moves the home checkout, which is why only a default-branch row offers it.
    @discardableResult
    public func switchBranch(path: String, branch: String) async throws -> String {
        let json = try await rest.sendJSON("POST", "/api/git/branch/switch", body: .object([
            "path": .string(path),
            "branch": .string(branch),
        ]))
        return json["branch"]?.coercedString ?? branch
    }

    // MARK: Filesystem

    public func listDirectory(path: String) async throws -> DirectoryListing {
        let json = try await rest.getJSON("/api/fs/list", query: [URLQueryItem(name: "path", value: path)])
        let error = json["error"]?.coercedString
        return DirectoryListing(
            entries: (json["entries"]?.arrayValue ?? []).map(DirectoryEntry.init(json:)),
            error: (error?.isEmpty == false) ? error : nil
        )
    }

    /// `GET /api/fs/default-cwd` — the host's own idea of where a session starts, and the browser's landing spot, because a client must never guess a path for a filesystem that may not be the same OS.
    public func defaultCwd() async -> String {
        guard let json = try? await rest.getJSON("/api/fs/default-cwd") else { return "" }
        return json["cwd"]?.coercedString ?? ""
    }

    /// `GET /api/fs/git-root` walks upwards looking for `.git`, so it answers "which repo is this inside", not "is this a repo" — that is `isRepositoryRoot`.
    public func gitRoot(path: String) async throws -> String? {
        let json = try await rest.getJSON("/api/fs/git-root", query: [URLQueryItem(name: "path", value: path)])
        let root = json["root"]?.coercedString
        return (root?.isEmpty == false) ? root : nil
    }

    /// True exactly when the directory carries its own `.git`, a linked worktree included, since git puts a `.git` file there; pure `os.path` on the host, which is what makes it affordable once per row.
    public func isRepositoryRoot(path: String) async -> Bool {
        guard let root = try? await gitRoot(path: path) else { return false }
        return HostPath.isSame(root, path)
    }

    /// The `git · <branch>` meta line, read off `.git/HEAD` rather than by spawning git per row, because `GET /api/git/status` runs a full `status --porcelain=v2` plus a numstat walk.
    /// Returns nil for a linked worktree, whose `.git` is a file with no `HEAD` beneath it, so the row keeps its diamond and loses only the branch line.
    public func headBranch(path: String) async -> String? {
        let head = HostPath.joining(HostPath.joining(path, ".git"), "HEAD")
        guard let json = try? await rest.getJSON("/api/fs/read-text", query: [URLQueryItem(name: "path", value: head)]),
              let text = json["text"]?.coercedString
        else { return nil }
        return Self.branchName(fromHEAD: text)
    }

    /// `ref: refs/heads/<branch>` → the branch; a detached head holds a raw SHA, abbreviated rather than claimed as a branch that is not there.
    static func branchName(fromHEAD raw: String) -> String? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        let refPrefix = "ref: refs/heads/"
        if text.hasPrefix(refPrefix) {
            let name = String(text.dropFirst(refPrefix.count))
            return name.isEmpty ? nil : name
        }
        if text.hasPrefix("ref: ") {
            let name = String(text.dropFirst(5))
            return name.isEmpty ? nil : name
        }
        let isSHA = text.count >= 7 && text.allSatisfy { $0.isHexDigit }
        return isSHA ? String(text.prefix(7)) : nil
    }

    /// `POST /api/files/mkdir` — `mkdir -p` on the host, a direct host mutation.
    /// It is gated by the managed-files policy and never reaches the approval ladder: a hosted install locks writes under its files root and 403s anything outside it, a self-managed install has no locked root at all.
    @discardableResult
    public func makeDirectory(path: String) async throws -> String {
        let json = try await rest.sendJSON("POST", "/api/files/mkdir", body: .object(["path": .string(path)]))
        return json["path"]?.coercedString ?? path
    }
}
