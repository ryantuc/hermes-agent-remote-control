import Foundation

// MARK: - Status

/// `GET /api/status` (public in both modes — rest-api-and-auth.md §4).
public struct ServerStatus: Sendable, Equatable {
    public let version: String
    public let releaseDate: String
    /// **The mode flag a client branches on.**
    public let authRequired: Bool
    /// `[]` on loopback; `["cookie"]` or `["cookie","native_pkce"]` when gated.
    public let authFlows: [String]
    public let authProviders: [String]
    public let gatewayRunning: Bool
    public let gatewayState: String
    public let activeSessions: Int
    public let activeAgents: Int
    public let overall: String
    public let profiles: [String]
    /// Full payload, for the diagnostics dump (sanitized before display).
    public let raw: JSONValue

    public init(json: JSONValue) {
        version = json["version"]?.coercedString ?? ""
        releaseDate = json["release_date"]?.coercedString ?? ""
        authRequired = json["auth_required"]?.coercedBool ?? false
        authFlows = (json["auth_flows"]?.arrayValue ?? []).compactMap { $0.coercedString }
        authProviders = (json["auth_providers"]?.arrayValue ?? []).compactMap { $0.coercedString }
        gatewayRunning = json["gateway_running"]?.coercedBool ?? false
        gatewayState = json["gateway_state"]?.coercedString ?? ""
        activeSessions = json["active_sessions"]?.coercedInt ?? 0
        activeAgents = json["active_agents"]?.coercedInt ?? 0
        overall = json["overall"]?.coercedString ?? ""
        profiles = (json["profiles"]?.arrayValue ?? []).compactMap { $0.coercedString }
        raw = json
    }

    /// `native_pkce` present ⇒ the backend offers the RFC 8252 flow. Absent on
    /// older gateways ⇒ fall back to cookie login (rest-api-and-auth.md §4).
    public var supportsNativePKCE: Bool { authFlows.contains("native_pkce") }

    /// Recommended auth mode for a fresh profile.
    public var suggestedAuthMode: BackendAuthMode { authRequired ? .password : .sessionToken }

    /// Diagnostics-safe copy: loopback-only recon fields (`hermes_home`,
    /// `config_path`, `env_path`, `gateway_pid`, `gateway_health_url`,
    /// `gateways`) are dropped even though the route itself is public.
    public var sanitizedDump: JSONValue {
        guard case .object(var object) = raw else { return raw }
        for key in ["hermes_home", "config_path", "env_path", "gateway_pid", "gateway_health_url", "gateways"] {
            object[key] = nil
        }
        return .object(object)
    }
}

// MARK: - Sessions

/// One row from `GET /api/sessions` (rest-api-and-auth.md §6.1).
public struct SessionSummary: Sendable, Equatable, Identifiable, Hashable {
    public let id: String
    public let title: String?
    public let preview: String
    public let source: String
    public let model: String
    public let cwd: String
    public let gitBranch: String
    public let startedAt: Double
    /// **There is no `updated_at`** — recency is `last_active`
    /// (PROTOCOL.md "Sessions"; rest §6.1).
    public let lastActive: Double
    public let endedAt: Double?
    public let messageCount: Int
    public let toolCallCount: Int
    public let isActive: Bool
    public let archived: Bool
    public let pinned: Bool
    public let profile: String
    public let parentSessionID: String?

    public init(json: JSONValue) {
        id = json["id"]?.coercedString ?? ""
        let rawTitle = json["title"]?.coercedString
        title = (rawTitle?.isEmpty == false) ? rawTitle : nil
        preview = json["preview"]?.coercedString ?? ""
        source = json["source"]?.coercedString ?? ""
        model = json["model"]?.coercedString ?? ""
        cwd = json["cwd"]?.coercedString ?? ""
        gitBranch = json["git_branch"]?.coercedString ?? ""
        startedAt = json["started_at"]?.coercedDouble ?? 0
        lastActive = json["last_active"]?.coercedDouble ?? json["started_at"]?.coercedDouble ?? 0
        endedAt = json["ended_at"]?.coercedDouble
        messageCount = json["message_count"]?.coercedInt ?? 0
        toolCallCount = json["tool_call_count"]?.coercedInt ?? 0
        isActive = json["is_active"]?.coercedBool ?? false
        // `archived`/`pinned` are real bools on the list endpoints but raw
        // SQLite 0/1 ints on `GET /api/sessions/{id}` (rest §6.1 / §6.3).
        archived = json["archived"]?.coercedBool ?? false
        pinned = json["pinned"]?.coercedBool ?? false
        profile = json["profile"]?.coercedString ?? ""
        let parent = json["parent_session_id"]?.coercedString
        parentSessionID = (parent?.isEmpty == false) ? parent : nil
    }

    private init(copying other: SessionSummary, title: String?) {
        id = other.id
        self.title = title
        preview = other.preview
        source = other.source
        model = other.model
        cwd = other.cwd
        gitBranch = other.gitBranch
        startedAt = other.startedAt
        lastActive = other.lastActive
        endedAt = other.endedAt
        messageCount = other.messageCount
        toolCallCount = other.toolCallCount
        isActive = other.isActive
        archived = other.archived
        pinned = other.pinned
        profile = other.profile
        parentSessionID = other.parentSessionID
    }

    /// Patch the title in place after a rename or a `session.title` event.
    public func withTitle(_ newTitle: String?) -> SessionSummary {
        SessionSummary(copying: self, title: (newTitle?.isEmpty == false) ? newTitle : nil)
    }

    /// Title falls back to preview: `title` is nullable in the DB.
    public var displayTitle: String {
        if let title = title, !title.isEmpty { return title }
        if !preview.isEmpty { return Redaction.truncated(preview, limit: 80) }
        return "Untitled conversation"
    }

    /// A running session the REST list has not persisted yet (BUG-028).
    /// Keyed by durable `session_key` when the backend sent one, otherwise
    /// the runtime id — enough to light the hub, not enough to resume.
    public init(fromLive status: LiveSessionStatus) {
        let key = status.sessionKey.isEmpty ? status.id : status.sessionKey
        id = key
        title = status.title.isEmpty ? nil : status.title
        preview = status.preview
        source = ""
        model = ""
        cwd = ""
        gitBranch = ""
        startedAt = status.lastActive
        lastActive = status.lastActive
        endedAt = nil
        messageCount = 0
        toolCallCount = 0
        isActive = status.isWorking
        archived = false
        pinned = false
        profile = ""
        parentSessionID = nil
    }

    public var lastActiveDate: Date { Date(timeIntervalSince1970: lastActive) }
}

public struct SessionListPage: Sendable, Equatable {
    public let sessions: [SessionSummary]
    public let total: Int
    public let limit: Int
    public let offset: Int

    /// `len(sessions)` can exceed `limit` because pinned rows are back-filled
    /// past it — never use the count as a "there's more" signal (rest §6.1).
    public var hasMore: Bool { offset + sessions.count < total }
}

// MARK: - Transcript

public enum MessageRole: String, Sendable, Equatable {
    case user, assistant, tool, system, unknown

    init(raw: String) { self = MessageRole(rawValue: raw) ?? .unknown }
}

/// `content` is `str | OpenAI content-part list | null` (rest §6.2).
public enum MessageContent: Sendable, Equatable {
    case text(String)
    case parts([ContentPart])
    case empty

    public var plainText: String {
        switch self {
        case .text(let s): return s
        case .parts(let parts):
            return parts.compactMap { part -> String? in
                if case .text(let t) = part { return t }
                return nil
            }.joined(separator: "\n")
        case .empty: return ""
        }
    }

    public var imageReferences: [String] {
        guard case .parts(let parts) = self else { return [] }
        return parts.compactMap { part in
            if case .imageURL(let url) = part { return url }
            return nil
        }
    }
}

public enum ContentPart: Sendable, Equatable {
    case text(String)
    /// `{"type":"image_url","image_url":{"url":"data:…"|"/abs/path"}}`. A
    /// gateway-local path must be resolved through `GET /api/media?path=`.
    case imageURL(String)
    case other(JSONValue)

    init(json: JSONValue) {
        let type = json["type"]?.coercedString ?? ""
        switch type {
        case "text":
            self = .text(json["text"]?.text ?? "")
        case "image_url":
            let url = json["image_url"]?["url"]?.coercedString ?? json["image_url"]?.coercedString ?? ""
            self = .imageURL(url)
        default:
            self = .other(json)
        }
    }
}

public struct ToolCallRecord: Sendable, Equatable, Identifiable {
    public let id: String
    public let name: String
    public let argumentsJSON: String

    init(json: JSONValue) {
        id = json["id"]?.coercedString ?? ""
        name = json["function"]?["name"]?.coercedString ?? json["name"]?.coercedString ?? ""
        argumentsJSON = json["function"]?["arguments"]?.coercedString ?? ""
    }
}

/// One row of `GET /api/sessions/{id}/messages` (rest §6.2).
public struct TranscriptMessage: Sendable, Equatable, Identifiable {
    /// AUTOINCREMENT rowid — **the ordering key**.
    public let id: Int
    public let sessionID: String
    public let role: MessageRole
    public let content: MessageContent
    public let toolCalls: [ToolCallRecord]
    public let toolCallID: String?
    public let toolName: String?
    public let timestamp: Double
    public let reasoning: String
    /// `hidden`, `model_switch`, `auto_continue`, … — a non-empty value on a
    /// `user` row means bookkeeping, not a real user turn.
    public let displayKind: String

    public init(json: JSONValue) {
        id = json["id"]?.coercedInt ?? 0
        sessionID = json["session_id"]?.coercedString ?? ""
        role = MessageRole(raw: json["role"]?.coercedString ?? "")
        switch json["content"] {
        case .some(.string(let s)):
            content = s.isEmpty ? .empty : .text(s)
        case .some(.array(let items)):
            content = .parts(items.map(ContentPart.init(json:)))
        default:
            content = .empty
        }
        toolCalls = (json["tool_calls"]?.arrayValue ?? []).map(ToolCallRecord.init(json:))
        let callID = json["tool_call_id"]?.coercedString
        toolCallID = (callID?.isEmpty == false) ? callID : nil
        let name = json["tool_name"]?.coercedString
        toolName = (name?.isEmpty == false) ? name : nil
        timestamp = json["timestamp"]?.coercedDouble ?? 0
        reasoning = json["reasoning"]?.coercedString
            ?? json["reasoning_content"]?.coercedString
            ?? ""
        displayKind = json["display_kind"]?.coercedString ?? ""
    }

    /// Bookkeeping rows every other Hermes surface filters out
    /// (rest §6.4 step 6).
    public var isBookkeeping: Bool {
        role == .user && !displayKind.isEmpty && displayKind != "steer"
    }

    public var isHidden: Bool { displayKind == "hidden" }

    /// Whether this row is one `session.branch` counts: its `count` truncates the backend's VISIBLE
    /// history, so an ordinal over every row addresses the wrong position (BUG-037).
    ///
    /// Two easy mistakes. `display_kind` is NOT filtered, so hidden and bookkeeping rows still
    /// count; and "non-empty text" is the server's coercion, which folds image and audio parts into
    /// the string, so an image-only row is non-empty there and looks empty to `plainText`.
    public var countsTowardBranchOrdinal: Bool {
        guard role == .user || role == .assistant else { return false }
        switch content {
        case .empty:
            return false
        case .text(let s):
            return !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .parts(let parts):
            return parts.contains { part in
                switch part {
                case .text(let t):
                    return !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                // Both render as a non-empty placeholder or URL server-side.
                case .imageURL, .other:
                    return true
                }
            }
        }
    }
}

public struct TranscriptPage: Sendable, Equatable {
    /// Render against THIS, not the id you asked for: the handler follows the compression chain and
    /// may redirect you forward (rest §6.2).
    public let sessionID: String
    public let messages: [TranscriptMessage]
    public let limit: Int?
    public let offset: Int
    public let returned: Int

    /// The memberwise initialiser, made public so a caller can build a fixture page without a
    /// network call.
    public init(
        sessionID: String,
        messages: [TranscriptMessage],
        limit: Int? = nil,
        offset: Int = 0,
        returned: Int? = nil
    ) {
        self.sessionID = sessionID
        self.messages = messages
        self.limit = limit
        self.offset = offset
        self.returned = returned ?? messages.count
    }

    /// The only "more?" signal available — there is no `total`, no cursor.
    public var mayHaveMore: Bool {
        guard let limit = limit else { return false }
        return returned >= limit
    }
}

// MARK: - Uploads

public struct ChatImageUploadResult: Sendable, Equatable {
    /// A gateway-local absolute **filesystem path**, not a URL.
    public let path: String
    public let name: String
    public let bytes: Int
    public let mimeType: String
}

public struct ManagedFileUploadResult: Sendable, Equatable {
    public let path: String
    public let name: String
    public let size: Int
    public let mimeType: String
}

// MARK: - Ops

/// The two halves of `POST /api/ops/backup`, as values rather than expressions inside a network
/// call, so they can be asserted without an HTTP stub (BUG-106).
public enum BackupCall {

    /// The body the route requires: an empty object, never `.null`, because a zero-length body
    /// under a JSON content type is a missing-field error to the handler's required model.
    public static func body(output: String) -> JSONValue {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .object([:]) }
        return .object(["output": .string(trimmed)])
    }

    /// Where the backup went: `archive`, which the route sends whenever it chose the path itself —
    /// so for this client, always. It has never sent `path` or `file`.
    public static func archive(from response: JSONValue) -> String {
        response["archive"]?.coercedString ?? ""
    }
}

// MARK: - RestAPI

/// Typed wrappers over the dashboard REST surface; only the routes a chat client needs.
public struct RestAPI: Sendable {
    public static let chatImageUploadLimit = 25 * 1024 * 1024
    public static let managedFileUploadLimit = 100 * 1024 * 1024
    /// Cap on assembling a multipart body in RAM, distinct from what the server accepts, so a
    /// one-shot body cannot jetsam the app.
    public static let managedFileInMemoryAssemblyLimit = 64 * 1024 * 1024

    private let auth: AuthenticationClient

    public init(auth: AuthenticationClient) {
        self.auth = auth
    }

    // MARK: Status

    /// Public in both modes — this is the probe that decides the auth mode.
    public func getStatus(profile: String? = nil) async throws -> ServerStatus {
        var query: [URLQueryItem] = []
        if let profile, !profile.isEmpty { query.append(URLQueryItem(name: "profile", value: profile)) }
        let request = await auth.makeRequest("/api/status", query: query, authenticated: false)
        return ServerStatus(json: try await auth.performJSON(request))
    }

    /// Cheap liveness probe that skips gateway/platform/MCP discovery.
    public func getHealth() async throws -> Bool {
        let request = await auth.makeRequest("/api/health", authenticated: false)
        let json = try await auth.performJSON(request)
        return json["ok"]?.coercedBool ?? false
    }

    // MARK: Config — the settings tree

    /// `GET /api/config` — the full web-normalized configuration document; per-key `config.get`
    /// answers only a handful of special keys and 4002s everything else.
    public func getConfig(profile: String? = nil) async throws -> JSONValue {
        var query: [URLQueryItem] = []
        if let profile, !profile.isEmpty { query.append(URLQueryItem(name: "profile", value: profile)) }
        let request = await auth.makeRequest("/api/config", query: query)
        return try await auth.performJSON(request)
    }

    /// `GET /api/config/schema`; options are merged per request, so this is the source of truth for
    /// dynamic option sets like `memory.provider`.
    public func getConfigSchema(profile: String? = nil) async throws -> JSONValue {
        var query: [URLQueryItem] = []
        if let profile, !profile.isEmpty { query.append(URLQueryItem(name: "profile", value: profile)) }
        let request = await auth.makeRequest("/api/config/schema", query: query)
        return try await auth.performJSON(request)
    }

    /// `PUT /api/config` — deep-merges the partial over what is on disk, so callers send just the
    /// changed subtree.
    public func putConfig(_ partial: JSONValue, profile: String? = nil) async throws {
        var body: [String: JSONValue] = ["config": partial]
        if let profile, !profile.isEmpty { body["profile"] = .string(profile) }
        let data = try JSONRPCCodec.encodeLine(.object(body)).data(using: .utf8) ?? Data()
        let request = await auth.makeRequest(
            "/api/config",
            method: "PUT",
            body: data,
            contentType: "application/json"
        )
        _ = try await auth.perform(request)
    }

    // MARK: Workspace pages

    /// Page-local payloads ride raw JSON — their shapes belong to the pages that render them.
    public func getJSON(_ path: String, query: [URLQueryItem] = []) async throws -> JSONValue {
        let request = await auth.makeRequest(path, query: query)
        return try await auth.performJSON(request)
    }

    /// PUT/POST with a JSON body, returning the response JSON (`.null` for an empty body) and throwing `malformedResponse` for a body that is not JSON.
    @discardableResult
    public func sendJSON(_ method: String, _ path: String, body: JSONValue = .null) async throws -> JSONValue {
        let data: Data
        if body == .null {
            data = Data()
        } else {
            data = try JSONRPCCodec.encodeLine(body).data(using: .utf8) ?? Data()
        }
        let request = await auth.makeRequest(
            path,
            method: method,
            body: data,
            contentType: "application/json"
        )
        let (responseData, _) = try await auth.perform(request)
        return try Self.sendResponseBody(responseData)
    }

    /// What `sendJSON` makes of a 2xx body; separate so the decision can be pinned without a network stub.
    /// It used to answer `.null` for a body it could not decode, the same value as an empty 204, so a captive portal's page read as success and each caller filled in a default (BUG-146); it now judges the body exactly as `performJSON` does for every read.
    static func sendResponseBody(_ data: Data) throws -> JSONValue {
        try AuthenticationClient.decodeBody(data)
    }

    // MARK: Ops

    /// `POST /api/ops/backup` — spawn `hermes backup`, and answer with where the archive is going.
    ///
    /// The fix belongs here rather than in `sendJSON`'s default, which would silently alter every
    /// other `.null`-bodied POST — the neighbouring `/api/gateway/restart` takes a query parameter.
    ///
    /// - Parameter output: where to write the archive; empty lets the backend pick and name it back.
    /// - Returns: the archive path the backend named, or `""` when the caller chose the path.
    @discardableResult
    public func runBackup(output: String = "") async throws -> String {
        let result = try await sendJSON(
            "POST",
            "/api/ops/backup",
            body: BackupCall.body(output: output)
        )
        return BackupCall.archive(from: result)
    }

    // MARK: Sessions

    /// `GET /api/sessions` — the legacy single-profile list the web dashboard
    /// uses and the one a new client should start with (reference-clients §4.1).
    public func listSessions(
        limit: Int = 50,
        offset: Int = 0,
        minMessages: Int = 1,
        order: String = "recent",
        archived: String = "exclude",
        profile: String? = nil
    ) async throws -> SessionListPage {
        var query = [
            URLQueryItem(name: "limit", value: String(limit)),
            URLQueryItem(name: "offset", value: String(offset)),
            URLQueryItem(name: "min_messages", value: String(minMessages)),
            URLQueryItem(name: "order", value: order),
            URLQueryItem(name: "archived", value: archived),
        ]
        if let profile, !profile.isEmpty { query.append(URLQueryItem(name: "profile", value: profile)) }
        let request = await auth.makeRequest("/api/sessions", query: query)
        let json = try await auth.performJSON(request)
        let rows = (json["sessions"]?.arrayValue ?? []).map(SessionSummary.init(json:))
        return SessionListPage(
            sessions: rows,
            total: json["total"]?.coercedInt ?? rows.count,
            limit: json["limit"]?.coercedInt ?? limit,
            offset: json["offset"]?.coercedInt ?? offset
        )
    }

    /// `GET /api/sessions/{id}/messages`.
    ///
    /// Omitting `limit` returns the entire transcript. The response's
    /// `session_id` is authoritative and may differ from the requested id.
    public func getMessages(
        sessionID: String,
        profile: String? = nil,
        limit: Int? = nil,
        offset: Int = 0
    ) async throws -> TranscriptPage {
        var query: [URLQueryItem] = []
        if let limit { query.append(URLQueryItem(name: "limit", value: String(min(limit, 500)))) }
        if offset > 0 { query.append(URLQueryItem(name: "offset", value: String(offset))) }
        if let profile, !profile.isEmpty { query.append(URLQueryItem(name: "profile", value: profile)) }
        let path = "/api/sessions/\(Self.escapePathComponent(sessionID))/messages"
        let request = await auth.makeRequest(path, query: query)
        let json = try await auth.performJSON(request)
        let rows = (json["messages"]?.arrayValue ?? []).map(TranscriptMessage.init(json:))
        return TranscriptPage(
            sessionID: json["session_id"]?.coercedString ?? sessionID,
            messages: rows,
            limit: json["pagination"]?["limit"]?.coercedInt ?? limit,
            offset: json["pagination"]?["offset"]?.coercedInt ?? offset,
            returned: json["pagination"]?["returned"]?.coercedInt ?? rows.count
        )
    }

    /// `GET /api/sessions/{id}/timeline`: the session's prompts, metadata only, at most 500 a page, oldest first.
    /// A backend without the route answers 404, the same status an unknown session gets; `isRouteMissing(_:)` tells the two apart as far as the body allows.
    public func getTimeline(
        sessionID: String,
        profile: String? = nil,
        afterRowID: Int = 0,
        limit: Int = 500
    ) async throws -> PromptTimelinePage {
        var query: [URLQueryItem] = [URLQueryItem(name: "limit", value: String(min(max(limit, 1), 500)))]
        if afterRowID > 0 { query.append(URLQueryItem(name: "after_row_id", value: String(afterRowID))) }
        if let profile, !profile.isEmpty { query.append(URLQueryItem(name: "profile", value: profile)) }
        let path = "/api/sessions/\(Self.escapePathComponent(sessionID))/timeline"
        let request = await auth.makeRequest(path, query: query)
        let json = try await auth.performJSON(request)
        return PromptTimelinePage(json: json, requestedSessionID: sessionID)
    }

    /// `GET /api/sessions/{id}/messages/around?row_id=`: at most 120 display rows starting at one of the timeline's prompts, in the `/messages` row shape.
    public func getMessagesAround(
        sessionID: String,
        rowID: Int,
        profile: String? = nil,
        limit: Int = 120
    ) async throws -> (page: TranscriptPage, window: TranscriptWindow) {
        var query: [URLQueryItem] = [
            URLQueryItem(name: "row_id", value: String(rowID)),
            URLQueryItem(name: "limit", value: String(min(max(limit, 1), 120))),
        ]
        if let profile, !profile.isEmpty { query.append(URLQueryItem(name: "profile", value: profile)) }
        let path = "/api/sessions/\(Self.escapePathComponent(sessionID))/messages/around"
        let request = await auth.makeRequest(path, query: query)
        let json = try await auth.performJSON(request)
        let rows = (json["messages"]?.arrayValue ?? []).map(TranscriptMessage.init(json:))
        let page = TranscriptPage(
            sessionID: json["session_id"]?.coercedString ?? sessionID,
            messages: rows,
            limit: json["pagination"]?["limit"]?.coercedInt ?? limit,
            offset: json["pagination"]?["offset"]?.coercedInt ?? 0,
            returned: json["pagination"]?["returned"]?.coercedInt ?? rows.count
        )
        return (page, TranscriptWindow(json: json, rowID: rowID))
    }

    /// Whether a failure from one of the timeline routes means the backend does not have the route at all, as opposed to not having the session or the prompt. FastAPI answers an unrouted path with `{"detail": "Not Found"}`; the session routes answer their own sentence.
    public static func isRouteMissing(_ error: Error) -> Bool {
        guard case .httpStatus(let code, let message) = error as? HermesError, code == 404 else { return false }
        return message.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "not found"
    }

    /// `PATCH /api/sessions/{id}` — rename / archive / pin. All-nil ⇒ 400.
    @discardableResult
    public func patchSession(
        sessionID: String,
        title: String? = nil,
        archived: Bool? = nil,
        pinned: Bool? = nil,
        profile: String? = nil
    ) async throws -> String? {
        var body: [String: JSONValue] = [:]
        if let title { body["title"] = .string(title) }
        if let archived { body["archived"] = .bool(archived) }
        if let pinned { body["pinned"] = .bool(pinned) }
        if let profile, !profile.isEmpty { body["profile"] = .string(profile) }
        guard !body.isEmpty else { return nil }
        let data = try JSONRPCCodec.encodeLine(.object(body)).data(using: .utf8) ?? Data()
        let request = await auth.makeRequest(
            "/api/sessions/\(Self.escapePathComponent(sessionID))",
            method: "PATCH",
            body: data,
            contentType: "application/json"
        )
        let json = try await auth.performJSON(request)
        return json["title"]?.coercedString
    }

    /// `DELETE /api/sessions/{id}` — idempotent, **never 404s**.
    public func deleteSession(sessionID: String, profile: String? = nil) async throws {
        var query: [URLQueryItem] = []
        if let profile, !profile.isEmpty { query.append(URLQueryItem(name: "profile", value: profile)) }
        let request = await auth.makeRequest(
            "/api/sessions/\(Self.escapePathComponent(sessionID))",
            method: "DELETE",
            query: query
        )
        _ = try await auth.perform(request)
    }

    /// `GET /api/sessions/{id}/latest-descendant` — has this conversation been
    /// compressed forward since we last rendered it?
    public func latestDescendant(sessionID: String, profile: String? = nil) async throws -> String {
        var query: [URLQueryItem] = []
        if let profile, !profile.isEmpty { query.append(URLQueryItem(name: "profile", value: profile)) }
        let request = await auth.makeRequest(
            "/api/sessions/\(Self.escapePathComponent(sessionID))/latest-descendant",
            query: query
        )
        let json = try await auth.performJSON(request)
        return json["session_id"]?.coercedString ?? sessionID
    }

    // MARK: Uploads

    /// `POST /api/chat/image-upload` — JSON data-URL in, gateway path out.
    /// Images only (png/jpeg/gif/webp/bmp, sniffed by magic bytes), 25 MiB cap.
    public func uploadChatImage(
        data: Data,
        mimeType: String,
        filename: String?,
        profile: String? = nil
    ) async throws -> ChatImageUploadResult {
        guard data.count <= Self.chatImageUploadLimit else {
            throw HermesError.attachmentTooLarge(bytes: data.count, limit: Self.chatImageUploadLimit)
        }
        var body: [String: JSONValue] = [
            "data_url": .string("data:\(mimeType);base64,\(data.base64EncodedString())")
        ]
        if let filename, !filename.isEmpty { body["filename"] = .string(filename) }
        var query: [URLQueryItem] = []
        if let profile, !profile.isEmpty { query.append(URLQueryItem(name: "profile", value: profile)) }
        let payload = try JSONRPCCodec.encodeLine(.object(body)).data(using: .utf8) ?? Data()
        let request = await auth.makeRequest(
            "/api/chat/image-upload",
            method: "POST",
            query: query,
            body: payload,
            contentType: "application/json"
        )
        let json = try await auth.performJSON(request)
        return ChatImageUploadResult(
            path: json["path"]?.coercedString ?? "",
            name: json["name"]?.coercedString ?? (filename ?? ""),
            bytes: json["bytes"]?.coercedInt ?? data.count,
            mimeType: json["mime_type"]?.coercedString ?? mimeType
        )
    }

    /// `POST /api/files/upload-stream` — the only true multipart endpoint,
    /// 100 MiB cap, atomic rename server-side.
    public func uploadFile(
        data: Data,
        filename: String,
        destinationPath: String,
        overwrite: Bool = true,
        mimeType: String = "application/octet-stream"
    ) async throws -> ManagedFileUploadResult {
        // The in-memory ceiling is checked FIRST because it is the operative one and sits below
        // the server cap; refuse once, naming the limit that is really enforced.
        guard data.count <= Self.managedFileInMemoryAssemblyLimit else {
            throw HermesError.unsupported(AttachmentSize.tooLargeMessage(bytes: data.count, limit: Self.managedFileInMemoryAssemblyLimit))
        }
        // Kept as a backstop so the constant stays meaningful if the in-memory
        // ceiling is ever raised above the server's.
        guard data.count <= Self.managedFileUploadLimit else {
            throw HermesError.attachmentTooLarge(bytes: data.count, limit: Self.managedFileUploadLimit)
        }
        let boundary = "hermes.\(UUID().uuidString)"
        var body = Data()
        func append(_ string: String) { body.append(Data(string.utf8)) }

        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"path\"\r\n\r\n")
        append("\(destinationPath)\r\n")

        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"overwrite\"\r\n\r\n")
        append("\(overwrite ? "true" : "false")\r\n")

        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"file\"; filename=\"\(Self.escapeQuoted(filename))\"\r\n")
        append("Content-Type: \(mimeType)\r\n\r\n")
        body.append(data)
        append("\r\n--\(boundary)--\r\n")

        let request = await auth.makeRequest(
            "/api/files/upload-stream",
            method: "POST",
            body: body,
            contentType: "multipart/form-data; boundary=\(boundary)"
        )
        let json = try await auth.performJSON(request)
        let entry = json["entry"] ?? .null
        return ManagedFileUploadResult(
            path: json["path"]?.coercedString ?? entry["path"]?.coercedString ?? "",
            name: entry["name"]?.coercedString ?? filename,
            size: entry["size"]?.coercedInt ?? data.count,
            mimeType: entry["mime_type"]?.coercedString ?? mimeType
        )
    }

    // MARK: Downloads / media

    /// `GET /api/files/download?path=` — uniquely also accepts `?token=` in
    /// loopback mode, so an externally opened link works without a header
    /// (rest §2.3, §5.3). In gated mode the token is not honoured and the
    /// caller must fetch the bytes through `perform` instead.
    public func downloadURL(path: String) async -> URL {
        var query = [URLQueryItem(name: "path", value: path)]
        if let token = await auth.queryTokenForDownload(), !token.isEmpty {
            query.append(URLQueryItem(name: "token", value: token))
        }
        return await auth.configuration.restURL("/api/files/download", query: query)
    }

    /// `GET /api/files/download` fetched THROUGH the authenticated client: the query token is only
    /// honoured in loopback mode, so on a gated gateway a bare download URL is a 401 wearing a
    /// filename.
    public func downloadFileData(path: String) async throws -> Data {
        let request = await auth.makeRequest(
            "/api/files/download",
            query: [URLQueryItem(name: "path", value: path)]
        )
        let (data, _) = try await auth.perform(request)
        return data
    }

    /// The server's ceiling on one managed file (`_MANAGED_FILE_MAX_BYTES`, `hermes_cli/web_server.py:870`): `download` and `stream` answer 413 above it.
    public static let managedFileByteLimit = 100 * 1024 * 1024

    /// The authorised request for `GET` or `HEAD /api/files/stream?path=` (`hermes_cli/web_routers/files.py:609-616`): inline, Range-aware, media extensions only, and it answers HEAD, so a caller can read the size before moving the body. Returned as a request rather than performed, because the body belongs on disk and `perform` buffers in memory.
    public func managedFileStreamRequest(path: String, method: String = "GET") async -> URLRequest {
        await auth.makeRequest(
            "/api/files/stream",
            method: method,
            query: [URLQueryItem(name: "path", value: path)]
        )
    }

    /// `GET /api/media?path=` → `{"data_url": "data:…"}`. The route a chat
    /// client uses to display an image the agent just wrote to gateway disk.
    public func mediaDataURL(path: String) async throws -> String {
        let request = await auth.makeRequest("/api/media", query: [URLQueryItem(name: "path", value: path)])
        let json = try await auth.performJSON(request)
        guard let dataURL = json["data_url"]?.coercedString else {
            throw HermesError.malformedResponse("/api/media returned no data_url")
        }
        return dataURL
    }

    /// `GET /api/fs/read-data-url?path=&profile=`: a file under a named Hermes profile's own home, which `/api/media`'s roots (the app-global home) refuse. Answers `{"dataUrl": …}`.
    public func readDataURL(path: String, profile: String) async throws -> String {
        let request = await auth.makeRequest("/api/fs/read-data-url", query: [
            URLQueryItem(name: "path", value: path),
            URLQueryItem(name: "profile", value: profile),
        ])
        let json = try await auth.performJSON(request)
        guard let dataURL = json["dataUrl"]?.coercedString else {
            throw HermesError.malformedResponse("/api/fs/read-data-url returned no dataUrl")
        }
        return dataURL
    }

    // MARK: Helpers

    private static func escapePathComponent(_ raw: String) -> String {
        raw.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-._~")))
            ?? raw
    }

    private static func escapeQuoted(_ raw: String) -> String {
        raw.replacingOccurrences(of: "\"", with: "'")
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
    }
}
