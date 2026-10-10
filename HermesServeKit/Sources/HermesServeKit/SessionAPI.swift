import Foundation

/// `session.branch` result.
public struct SessionBranchResult: Sendable, Equatable {
    public let sessionID: String
    public let storedSessionID: String
    public let title: String
    public let messageCount: Int

    public init(json: JSONValue) {
        sessionID = json["session_id"]?.coercedString ?? ""
        storedSessionID = json["stored_session_id"]?.coercedString ?? ""
        title = json["title"]?.coercedString ?? ""
        messageCount = json["message_count"]?.coercedInt ?? 0
    }
}

// MARK: - Shared sub-shapes

/// The shape of every `messages` array in every RPC result (jsonrpc-methods §1.9.1); distinct from
/// the REST `TranscriptMessage`, where text is `content` and the durable row id is `id`.
public struct DisplayMessage: Sendable, Equatable {
    public let role: MessageRole
    public let text: String
    public let rowID: Int?
    public let displayKind: String
    public let reasoning: String
    /// `role == .tool` rows carry these instead of text.
    public let toolName: String
    public let toolContext: String

    public init(json: JSONValue) {
        role = MessageRole(raw: json["role"]?.coercedString ?? "")
        text = json["text"]?.text ?? ""
        rowID = json["row_id"]?.coercedInt
        displayKind = json["display_kind"]?.coercedString ?? ""
        reasoning = json["reasoning"]?.coercedString
            ?? json["reasoning_content"]?.coercedString
            ?? ""
        toolName = json["name"]?.coercedString ?? ""
        toolContext = json["context"]?.coercedString ?? ""
    }

    public var isBookkeeping: Bool { role == .user && !displayKind.isEmpty && displayKind != "steer" }
}

/// `_session_info` (jsonrpc-methods §1.9.3); the full and the reduced lazy variants both decode
/// into this, so every field is optional.
public struct SessionInfo: Sendable, Equatable {
    public let model: String
    public let provider: String
    public let cwd: String
    public let branch: String
    public let profileName: String
    public let approvalMode: String
    public let reasoningEffort: String
    public let personality: String
    public let title: String
    public let storedSessionID: String
    public let running: Bool
    public let yolo: Bool
    public let lazy: Bool
    /// Monotonic GUI↔backend contract version, the only explicit protocol version in this layer.
    public let desktopContract: Int
    public let version: String
    public let credentialWarning: String
    /// When the running turn began, as the backend measured it; nil on an idle session, an older
    /// backend, and the reduced lazy shape, all three meaning "the backend did not say".
    public let turnStartedAt: Date?
    public let raw: JSONValue

    public init(json: JSONValue) {
        model = json["model"]?.coercedString ?? ""
        provider = json["provider"]?.coercedString ?? ""
        cwd = json["cwd"]?.coercedString ?? ""
        branch = json["branch"]?.coercedString ?? ""
        profileName = json["profile_name"]?.coercedString ?? ""
        approvalMode = json["approval_mode"]?.coercedString ?? ""
        reasoningEffort = json["reasoning_effort"]?.coercedString ?? ""
        personality = json["personality"]?.coercedString ?? ""
        title = json["title"]?.coercedString ?? ""
        storedSessionID = json["stored_session_id"]?.coercedString ?? ""
        running = json["running"]?.coercedBool ?? false
        yolo = json["yolo"]?.coercedBool ?? false
        lazy = json["lazy"]?.coercedBool ?? false
        desktopContract = json["desktop_contract"]?.coercedInt ?? 0
        version = json["version"]?.coercedString ?? ""
        credentialWarning = json["credential_warning"]?.coercedString ?? ""
        turnStartedAt = json["turn_started_at"].flatMap { $0.coercedEpochDate }
        raw = json
    }
}

/// `_inflight_snapshot` (jsonrpc-methods §1.9.2) — how a reconnecting client recovers a turn whose
/// terminal frame it missed; `error` is the only carrier of a failure lost to the disconnect.
public struct InflightSnapshot: Sendable, Equatable {
    public let raw: JSONValue
    public let startedAt: Date?
    public let correctionOffsets: [Int]
    public let user: String
    public let assistant: String
    public let streaming: Bool
    /// Mid-turn steer/redirect texts, oldest first.
    public let corrections: [String]
    public let error: String
    public let status: String
    public let recoverable: Bool
    /// Which layer failed (FEAT-016); advisory, and absent on most failures.
    public let errorSurface: ErrorSurface?

    public init?(json: JSONValue?) {
        guard let json, !json.isNull else { return nil }
        raw = json
        startedAt = json["started_at"].flatMap { $0.coercedEpochDate }
        correctionOffsets = (json["correction_offsets"]?.arrayValue ?? []).compactMap { $0.coercedInt }
        user = json["user"]?.text ?? ""
        assistant = json["assistant"]?.text ?? ""
        streaming = json["streaming"]?.coercedBool ?? false
        corrections = (json["corrections"]?.arrayValue ?? []).map { $0.text }
        error = json["error"]?.text ?? ""
        status = json["status"]?.coercedString ?? ""
        recoverable = json["recoverable"]?.coercedBool ?? false
        errorSurface = ErrorSurface(json: json["error_surface"])
        // Bail out entirely when every projection field is empty (reference §7.1).
        if user.isEmpty, assistant.isEmpty, corrections.isEmpty, error.isEmpty { return nil }
    }

    public var isFailure: Bool { status == "error" || !error.isEmpty }
}

/// The backend re-submitted a crash-interrupted turn itself; it arrives as a normal `message.start`
/// stream after the resume and must not be treated as a duplicate (jsonrpc-methods §4.6).
public struct AutoContinueNotice: Sendable, Equatable {
    public let attempt: Int
    public let interruptedAt: Double

    public init?(json: JSONValue?) {
        guard let json, !json.isNull, case .object = json else { return nil }
        attempt = json["attempt"]?.coercedInt ?? 1
        interruptedAt = json["interrupted_at"]?.coercedDouble ?? 0
    }
}

public struct SessionCreateResult: Sendable, Equatable {
    /// Ephemeral 8-hex runtime id — what every RPC and every event carries.
    public let sessionID: String
    /// Durable `YYYYMMDD_HHMMSS_xxxxxx` key — what resume, delete and the REST routes take.
    public let storedSessionID: String
    public let messages: [DisplayMessage]
    public let info: SessionInfo
}

public struct SessionResumeResult: Sendable, Equatable {
    public var raw: JSONValue = .null
    public let sessionID: String
    /// Durable id actually bound; resume follows the compression chain to the live tip.
    public let resumed: String
    public let sessionKey: String
    public let messages: [DisplayMessage]
    public let info: SessionInfo
    public let inflight: InflightSnapshot?
    /// A prompt accepted while the session was busy, not yet started.
    public let queued: String?
    public let autoContinue: AutoContinueNotice?
    public let running: Bool
    public let status: String
    /// The gateway accepted this client as a WATCHER, not only the transport owner; per-resume
    /// confirmation only, and false on any backend that does not answer the field.
    public let watching: Bool
    /// The live-session payload's own copy of the running turn's start, preferred over
    /// `info.turnStartedAt` because that `info` can be the reduced shape with no key at all.
    public let turnStartedAt: Date?
    /// The approval still blocking this session; the gateway does not re-emit the event frame to a
    /// reattached client, and absent means nothing pending, never a fabricated prompt (BUG-066).
    public let pendingApproval: ApprovalRequestEvent?
    /// The clarify question still blocking this session, same replay contract.
    public let pendingClarify: ClarifyRequestEvent?
    /// The plan as the backend holds it (FEAT-037); nil on a backend that predates the key or for a
    /// session whose plan store was never written.
    public let todoState: TodoSnapshot?
    /// The open connection operation as its `connection.request` payload, so a client that missed the event restores the card with the server's deadline (`LiveSessionSnapshot.pending_connection`, `tui_gateway/contracts/sessions.py:106-108`, `:108` on an older backend; attached by `server.py:3144-3148`). Nil means nothing is open.
    public let pendingConnection: ConnectionRequest?
}

/// `session.active_list` item; absence is authoritative — a runtime seen last poll but not this one
/// has settled (reference §4.6).
public struct LiveSessionStatus: Sendable, Equatable, Identifiable {
    public let id: String
    public let sessionKey: String
    public let title: String
    public let preview: String
    public let lastActive: Double
    /// `waiting | starting | working | idle`.
    public let status: String

    public init(json: JSONValue) {
        id = json["id"]?.coercedString ?? ""
        sessionKey = json["session_key"]?.coercedString ?? ""
        title = json["title"]?.coercedString ?? ""
        preview = json["preview"]?.coercedString ?? ""
        lastActive = json["last_active"]?.coercedDouble ?? 0
        status = json["status"]?.coercedString ?? "idle"
    }

    /// Known gap: an approval-blocked session reports `working`, never `waiting` (reference §5.5).
    public var needsInput: Bool { status == "waiting" }
    public var isWorking: Bool { status == "working" || needsInput }
}

/// `subagent.interrupt` result; `found: false` means a started agent ended with no
/// `subagent.complete`, or a `spawn_requested` one is queued and has not run — see `hasStarted`.
public struct SubagentInterruptResult: Sendable, Equatable {
    public let found: Bool
    public let subagentID: String

    public init(json: JSONValue, requested: String) {
        found = json["found"]?.coercedBool ?? false
        let echoed = json["subagent_id"]?.coercedString ?? ""
        subagentID = echoed.isEmpty ? requested : echoed
    }
}

/// `delegation.status` — `{active, paused, max_spawn_depth, max_concurrent_children}`.
///
/// Process-global, not session-scoped, which is what makes an EMPTY `active` usable as evidence.
/// Absence of one id from a NON-empty list proves nothing: this client cannot tell how a queued
/// child or a grandchild is represented there.
public struct DelegationStatus: Sendable, Equatable {
    /// Ids reported live, in wire order, read from a bare string or `subagent_id` / `id` / `agent_id`.
    public let activeIDs: [String]
    /// How many entries `active` carried; read this, not `activeIDs.count`, because an element
    /// whose id this decode missed is still an active delegation.
    public let activeCount: Int
    public let paused: Bool
    public let maxSpawnDepth: Int?
    public let maxConcurrentChildren: Int?

    public var isIdle: Bool { activeCount == 0 }

    public init?(json: JSONValue) {
        // No `active` key is "no answer", never "nothing is running": the caller retires on empty.
        guard let rows = json["active"]?.arrayValue else { return nil }
        activeCount = rows.count
        activeIDs = rows.compactMap { row in
            if case .string(let id) = row { return id.isEmpty ? nil : id }
            let id = row["subagent_id"]?.coercedString
                ?? row["id"]?.coercedString
                ?? row["agent_id"]?.coercedString
                ?? ""
            return id.isEmpty ? nil : id
        }
        paused = json["paused"]?.coercedBool ?? false
        maxSpawnDepth = json["max_spawn_depth"]?.coercedInt
        maxConcurrentChildren = json["max_concurrent_children"]?.coercedInt
    }
}

/// The one row `session.list` returns from its exact-title branch — a registry lookup, not a
/// listing. `startedAt` is the root's while `messageCount` and `preview` are the tip's, and
/// `preview` is always empty here, so a caller wanting one reads `profiles.list` instead.
public struct SessionTitleMatch: Sendable, Equatable {
    /// The row that carries the title right now — the durable id to pin.
    public let id: String
    /// The live compression tip — the id to open; falls back to `id` on a gateway without the key.
    public let resolvedID: String
    public let title: String
    public let preview: String
    public let startedAt: Double
    public let messageCount: Int
    public let source: String

    public init(
        id: String,
        resolvedID: String,
        title: String = "",
        preview: String = "",
        startedAt: Double = 0,
        messageCount: Int = 0,
        source: String = ""
    ) {
        self.id = id
        self.resolvedID = resolvedID
        self.title = title
        self.preview = preview
        self.startedAt = startedAt
        self.messageCount = messageCount
        self.source = source
    }

    public init(json: JSONValue) {
        let rowID = json["id"]?.coercedString ?? ""
        id = rowID
        let resolved = json["resolved_id"]?.coercedString ?? ""
        resolvedID = resolved.isEmpty ? rowID : resolved
        title = json["title"]?.coercedString ?? ""
        preview = json["preview"]?.coercedString ?? ""
        startedAt = json["started_at"]?.coercedDouble ?? 0
        messageCount = json["message_count"]?.coercedInt ?? 0
        source = json["source"]?.coercedString ?? ""
    }
}

// MARK: - SessionAPI

/// Typed wrappers over the session lifecycle RPCs.
public struct SessionAPI: Sendable {
    /// Terminal width for server-side markdown rendering; only affects the `rendered` field we ignore.
    public static let defaultColumns = 96
    /// DB `source` tag for rows this client creates.
    public static let sourceTag = "ios"

    private let client: HermesClient

    public init(client: HermesClient) {
        self.client = client
    }

    /// `session.create` — creates a live record; no DB row is written until the first prompt, so a
    /// brand-new chat is invisible in the thread list until it is used (reference §4.0).
    ///
    /// `hidden: true` is deferred intent: the flag is applied when the row materialises on the
    /// first `prompt.submit`, and keeps it out of `session.list` and `GET /api/sessions`.
    ///
    /// A sent `cwd` always rides with `cwd_explicit: true`. The app sends `cwd` only for a
    /// folder the user chose — picked on this draft (`ChatModel.applyCwd`) or the remembered pick the
    /// folder chip shows (`HomeView.seedDraftProject`) — and sends none otherwise, so the backend's own
    /// default still applies when nothing was chosen. Without the flag current upstream lets a
    /// named profile's configured folder beat the request's (`tui_gateway/session_workdir.py:43-45`).
    /// A backend that predates the flag rejects it, see `rejectsCwdExplicit`.
    public func create(
        columns: Int = defaultColumns,
        cwd: String? = nil,
        profile: String? = nil,
        model: String? = nil,
        provider: String? = nil,
        reasoningEffort: String? = nil,
        title: String? = nil,
        hidden: Bool = false
    ) async throws -> SessionCreateResult {
        var params: [String: JSONValue] = [
            "cols": .number(Double(columns)),
            "source": .string(Self.sourceTag),
        ]
        if let cwd, !cwd.isEmpty {
            params["cwd"] = .string(cwd)
            params["cwd_explicit"] = .bool(true)
        }
        if let profile, !profile.isEmpty { params["profile"] = .string(profile) }
        if let model, !model.isEmpty { params["model"] = .string(model) }
        // Model and provider ship together: a bare model the current provider does not serve is
        // silently dropped at agent build, and `info.model` still echoes the requested override.
        if let provider, !provider.isEmpty { params["provider"] = .string(provider) }
        if let reasoningEffort, !reasoningEffort.isEmpty {
            params["reasoning_effort"] = .string(reasoningEffort)
        }
        if let title, !title.isEmpty { params["title"] = .string(title) }
        // Sent only when true; the backend reads an omitted key as false anyway.
        if hidden { params["hidden"] = .bool(true) }
        let result: JSONValue
        do {
            result = try await client.request("session.create", params: .object(params))
        } catch let error as HermesError where params["cwd_explicit"] != nil && Self.rejectsCwdExplicit(error) {
            // The 4000 is answered at dispatch, before the handler runs, so nothing was created and the
            // same create can go once more without the flag. Such a backend lets the request's `cwd`
            // win on its own (`session_workdir.py:23-35` on an older backend), so the folder is still honored.
            params.removeValue(forKey: "cwd_explicit")
            result = try await client.request("session.create", params: .object(params))
        }
        return SessionCreateResult(
            sessionID: result["session_id"]?.coercedString ?? "",
            storedSessionID: result["stored_session_id"]?.coercedString ?? "",
            messages: (result["messages"]?.arrayValue ?? []).map(DisplayMessage.init(json:)),
            info: SessionInfo(json: result["info"] ?? .null)
        )
    }

    /// True for the backend's "undeclared key" refusal of `cwd_explicit`: 4000 with the key path in
    /// the message (`contracts/registry.py:100-115` on an older backend; the flag was
    /// declared upstream in `66bc259712` on 2026-09-25). The probe is the rejection itself: no
    /// capability or contract version names the flag (`DESKTOP_BACKEND_CONTRACT` 8 predates it), and a
    /// backend that declares the key never names it in a 4000. Any other rejection is the caller's.
    static func rejectsCwdExplicit(_ error: HermesError) -> Bool {
        guard case .rpc(let code, let message, _) = error else { return false }
        return code == 4000 && message.contains("cwd_explicit")
    }

    /// `session.cwd.set` — repoint an idle session's working directory; the chip reconciles off the
    /// resulting `session.info`, so do not also set it optimistically. 4009 while a turn runs.
    public func setCwd(sessionID: String, path: String) async throws {
        _ = try await client.request("session.cwd.set", params: .object([
            "session_id": .string(sessionID),
            "cwd": .string(path),
        ]))
    }

    /// `session.resume` — takes the DURABLE id and returns a new runtime id, and is also the
    /// mid-turn reconnect path carrying `inflight` / `queued` / `auto_continue` (jsonrpc-methods
    /// §1.1, §4.6). `storedSessionID` may also be an exact title, which the gateway retries as a
    /// title lookup when the id misses.
    public func resume(
        storedSessionID: String,
        columns: Int = defaultColumns,
        profile: String? = nil,
        lazy: Bool = false,
        watch: Bool = false
    ) async throws -> SessionResumeResult {
        var params: [String: JSONValue] = [
            "session_id": .string(storedSessionID),
            "cols": .number(Double(columns)),
            "source": .string(Self.sourceTag),
        ]
        if lazy { params["lazy"] = .bool(true) }
        // Sent ONLY when the gateway advertised `session_mirroring` on ready; do not probe by
        // sending, because a backend without it ignores the param silently.
        if watch { params["watch"] = .bool(true) }
        if let profile, !profile.isEmpty { params["profile"] = .string(profile) }
        let result = try await requestResumeAbsorbingSettle(params: .object(params))
        return Self.decodeResume(result, requested: storedSessionID, includeLegacyPrompts: await client.serverRequestMethods.isEmpty)
    }

    /// The refusal lasts only as long as the disconnect interrupt takes to settle, so a short pause
    /// clears it and more attempts would be a spinner the caller cannot escape.
    private static let resumeSettleRetryDelay: TimeInterval = 0.75
    private static let resumeSettleRetryLimit = 2

    /// `session.resume`, absorbing the transient 4009 raised while the WS-orphan reaper finishes
    /// interrupting a turn — the session is alive and the next attach succeeds (BUG-114). Every
    /// other error, 4001 and 4007 included, is rethrown: those mean the session is gone.
    private func requestResumeAbsorbingSettle(params: JSONValue) async throws -> JSONValue {
        var attempt = 0
        while true {
            do {
                return try await client.request("session.resume", params: params)
            } catch let error as HermesError where error.isResumeSettling
                && attempt < Self.resumeSettleRetryLimit {
                attempt += 1
                try? await Task.sleep(
                    nanoseconds: UInt64(Self.resumeSettleRetryDelay * 1_000_000_000)
                )
            }
        }
    }

    /// `session.activate` — the warm path; modern backends require it to rebind a live session's
    /// event transport to a newly opened socket (reference §4.3).
    public func activate(sessionID: String, columns: Int = defaultColumns) async throws -> SessionResumeResult {
        let params: JSONValue = .object([
            "session_id": .string(sessionID),
            "cols": .number(Double(columns)),
        ])
        let result = try await client.request("session.activate", params: params)
        return Self.decodeResume(result, requested: sessionID, includeLegacyPrompts: await client.serverRequestMethods.isEmpty)
    }

    public func eventsSince(sessionID: String, lastSeen: Int) async throws -> SessionEventReplay? {
        let result = try await client.request("session.events.since", params: .object([
            "session_id": .string(sessionID), "last_seen": .number(Double(lastSeen))
        ]))
        return SessionEventReplay(json: result)
    }

    static func decodeResume(_ result: JSONValue, requested: String, includeLegacyPrompts: Bool = true) -> SessionResumeResult {
        // Current official snapshots retain pending_approval as a compatibility summary. It is
        // not a second FIFO prompt when open_requests owns the actionable identity.
        let legacyPrompts = includeLegacyPrompts && result["open_requests"]?.arrayValue == nil
        return SessionResumeResult(
            raw: result,
            sessionID: result["session_id"]?.coercedString ?? "",
            resumed: result["resumed"]?.coercedString ?? requested,
            sessionKey: result["session_key"]?.coercedString
                ?? result["resumed"]?.coercedString ?? requested,
            messages: (result["messages"]?.arrayValue ?? []).map(DisplayMessage.init(json:)),
            info: SessionInfo(json: result["info"] ?? .null),
            inflight: InflightSnapshot(json: result["inflight"]),
            queued: result["queued"]?["user"]?.coercedString,
            autoContinue: AutoContinueNotice(json: result["auto_continue"]),
            running: result["running"]?.coercedBool ?? false,
            status: result["status"]?.coercedString ?? "idle",
            watching: result["watching"]?.coercedBool ?? false,
            turnStartedAt: result["turn_started_at"].flatMap { $0.coercedEpochDate },
            // BUG-066: both keys are absent unless something is blocking, so `nil` means "nothing
            // pending". Null is checked too, because a fabricated prompt is worse than a missed one.
            pendingApproval: Self.pendingPayload(legacyPrompts ? result["pending_approval"] : nil).map {
                ApprovalRequestEvent(sessionID: result["session_id"]?.coercedString ?? "", payload: $0)
            },
            pendingClarify: Self.pendingPayload(legacyPrompts ? result["pending_clarify"] : nil).map {
                ClarifyRequestEvent(sessionID: result["session_id"]?.coercedString ?? "", payload: $0)
            },
            todoState: TodoSnapshot(json: result["todo_state"]),
            pendingConnection: ConnectionRequest(sessionID: result["session_id"]?.coercedString ?? "",
                                                 payload: Self.pendingPayload(result["pending_connection"]))
        )
    }

    /// A replayed prompt snapshot, or nil for absent / null / non-object.
    private static func pendingPayload(_ value: JSONValue?) -> JSONValue? {
        guard let value, case .object(let object) = value, !object.isEmpty else { return nil }
        return value
    }

    /// `session.interrupt` — there is no `prompt.interrupt`; it also releases pending
    /// clarify/sudo/secret prompts and denies every pending approval (jsonrpc-methods §1.1).
    /// Finalise local state before awaiting it (reference §3.5).
    public func interrupt(sessionID: String) async throws {
        _ = try await client.request(
            "session.interrupt",
            params: .object(["session_id": .string(sessionID)])
        )
    }

    /// `subagent.interrupt` — the only thing that stops a background agent. `session.interrupt`
    /// cannot: it gates on `session["running"]`, false the instant a fan-out is dispatched, and the
    /// background path detaches every child from the parent's interrupt propagation.
    ///
    /// `session_id` is required from hermes-agent 0.21.1, which also demands the caller's transport be attached to it, and is ignored by older backends (BUG-147).
    @discardableResult
    public func interruptSubagent(subagentID: String, sessionID: String) async throws -> SubagentInterruptResult {
        let result = try await client.request(
            "subagent.interrupt",
            params: .object(["subagent_id": .string(subagentID), "session_id": .string(sessionID)])
        )
        return SubagentInterruptResult(json: result, requested: subagentID)
    }

    /// `delegation.status` — read-only, process-wide; `nil` means the gateway did not answer, kept
    /// distinct from an empty list because the caller retires rows when nothing is active.
    public func delegationStatus() async throws -> DelegationStatus? {
        let result = try await client.request("delegation.status", params: .object([:]))
        return DelegationStatus(json: result)
    }

    /// `session.title` with a title is a write, without one a read; clearing must go through REST,
    /// because the RPC rejects an empty title with 4021 (reference §4.4).
    @discardableResult
    public func setTitle(sessionID: String, title: String) async throws -> String {
        let result = try await client.request(
            "session.title",
            params: .object(["session_id": .string(sessionID), "title": .string(title)])
        )
        return result["title"]?.coercedString ?? title
    }

    /// `session.list` — the RPC list, with `source: "tool"` rows filtered server-side. This RPC has
    /// no cap and returns no 422; the 100/422 contract belongs to the REST dashboard router, so the
    /// `capped` clamp below is defensive rather than required.
    public func list(limit: Int = 60, profile: String? = nil) async throws -> [SessionSummary] {
        let capped = min(max(limit, 0), 100)
        var params: [String: JSONValue] = ["limit": .number(Double(capped))]
        if let profile, !profile.isEmpty { params["profile"] = .string(profile) }
        let result = try await client.request("session.list", params: .object(params))
        return (result["sessions"]?.arrayValue ?? []).map(SessionSummary.init(json:))
    }

    /// `session.list` with `title` — the exact-title registry lookup, which is how a title becomes
    /// an identity key; a partial UNIQUE index means at most one row per profile carries a title.
    ///
    /// The client-side title check is the compatibility rung: a gateway without the title branch
    /// ignores the parameter and answers with its ordinary windowed listing, so a caller trusting
    /// `sessions[0]` would adopt an unrelated conversation.
    public func lookupByTitle(
        _ title: String,
        profile: String? = nil,
        limit: Int = 200
    ) async throws -> SessionTitleMatch? {
        var params: [String: JSONValue] = [
            "title": .string(title),
            "include_hidden": .bool(true),
            "limit": .number(Double(limit)),
        ]
        if let profile, !profile.isEmpty { params["profile"] = .string(profile) }
        let result = try await client.request("session.list", params: .object(params))
        let rows = result["sessions"]?.arrayValue ?? []
        guard let row = rows.first(where: { $0["title"]?.coercedString == title }) else {
            return nil
        }
        return SessionTitleMatch(json: row)
    }

    /// `session.delete` takes the DURABLE id and refuses an active session with 4023.
    public func delete(storedSessionID: String, profile: String? = nil) async throws {
        var params: [String: JSONValue] = ["session_id": .string(storedSessionID)]
        if let profile, !profile.isEmpty { params["profile"] = .string(profile) }
        _ = try await client.request("session.delete", params: .object(params))
    }

    /// `session.branch` — copy this conversation into a new session, truncated to the first `count`
    /// messages; builds the agent synchronously, and 4008 when there is nothing to branch yet.
    public func branch(sessionID: String, count: Int? = nil, name: String? = nil) async throws -> SessionBranchResult {
        var params: [String: JSONValue] = ["session_id": .string(sessionID)]
        if let count { params["count"] = .number(Double(count)) }
        if let name, !name.isEmpty { params["name"] = .string(name) }
        let result = try await client.request("session.branch", params: .object(params))
        return SessionBranchResult(json: result)
    }

    /// `session.close` — idempotent; unknown sid returns `{"closed": false}`.
    @discardableResult
    public func close(sessionID: String) async throws -> Bool {
        let result = try await client.request(
            "session.close",
            params: .object(["session_id": .string(sessionID)])
        )
        return result["closed"]?.coercedBool ?? false
    }

    /// `session.active_list` — re-seed per-session liveness after a reconnect; read-only, and
    /// tolerant, so a response with no `sessions` key reads as an empty roster. A caller that ACTS
    /// on absence must use `activeListIfAnswered` instead.
    public func activeList() async throws -> [LiveSessionStatus] {
        try await activeListIfAnswered() ?? []
    }

    /// The same call, keeping "nothing is running" (`[]`) distinct from "the gateway did not
    /// answer" (`nil`) — absence of an answer, not an answer of absence.
    public func activeListIfAnswered() async throws -> [LiveSessionStatus]? {
        let result = try await client.request("session.active_list", params: .object([:]))
        guard let rows = result["sessions"]?.arrayValue else { return nil }
        return rows.map(LiveSessionStatus.init(json:))
    }
}
