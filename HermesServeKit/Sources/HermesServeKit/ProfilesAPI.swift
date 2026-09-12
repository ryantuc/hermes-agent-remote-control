import Foundation

// MARK: - Row shapes

/// One session summary hanging off a `profiles.list` row; three producers decode into it and they
/// do NOT send the same keys, so `resolved_id` and `root_title` fall back rather than failing a row.
public struct ProfileSessionSummary: Sendable, Equatable {
    /// The durable registry row.
    public let id: String
    /// The live tip of `id`'s compression lineage — what to open; falls back to `id`.
    public let resolvedID: String
    /// Title on the pinned/root row; compression TRANSFERS the title to the continuation and NULLs
    /// the ancestor, so this goes empty after the first rotation while `title` keeps the name.
    public let rootTitle: String
    /// Title on the tip row.
    public let title: String
    /// Newest message on the tip — messaging-app semantics, not `session.list`'s first-message preview.
    public let preview: String
    public let startedAt: Double
    public let lastActive: Double
    public let messageCount: Int

    public init(
        id: String,
        resolvedID: String,
        rootTitle: String = "",
        title: String = "",
        preview: String = "",
        startedAt: Double = 0,
        lastActive: Double = 0,
        messageCount: Int = 0
    ) {
        self.id = id
        self.resolvedID = resolvedID
        self.rootTitle = rootTitle
        self.title = title
        self.preview = preview
        self.startedAt = startedAt
        self.lastActive = lastActive
        self.messageCount = messageCount
    }

    public init(json: JSONValue) {
        let rowID = json["id"]?.coercedString ?? ""
        id = rowID
        let resolved = json["resolved_id"]?.coercedString ?? ""
        resolvedID = resolved.isEmpty ? rowID : resolved
        rootTitle = json["root_title"]?.coercedString ?? ""
        title = json["title"]?.coercedString ?? ""
        preview = json["preview"]?.coercedString ?? ""
        startedAt = json["started_at"]?.coercedDouble ?? 0
        lastActive = json["last_active"]?.coercedDouble ?? 0
        messageCount = json["message_count"]?.coercedInt ?? 0
    }

    /// Before compression the pinned row itself is titled `Bot Chat`; after one the title has moved
    /// to the tip and the root's is empty. Both are the same conversation, so both count.
    public var isCanonicalBotChat: Bool {
        rootTitle == BotChat.title || (rootTitle.isEmpty && title == BotChat.title)
    }
}

/// `worker_session` — the newest kanban/tool row for a profile, a liveness hint only.
public struct ProfileWorkerSummary: Sendable, Equatable {
    public let id: String
    public let source: String
    public let title: String
    public let lastActive: Double

    public init(id: String, source: String = "", title: String = "", lastActive: Double = 0) {
        self.id = id
        self.source = source
        self.title = title
        self.lastActive = lastActive
    }

    public init(json: JSONValue) {
        id = json["id"]?.coercedString ?? ""
        source = json["source"]?.coercedString ?? ""
        title = json["title"]?.coercedString ?? ""
        lastActive = json["last_active"]?.coercedDouble ?? 0
    }
}

/// The three answers `profiles.list` can give about a profile's forever-chat — three, not two.
///
/// A newer gateway resolves the chat by title into `canonical_session`; an older one echoed back a
/// caller-supplied pin as `preferred_session`. An absent key means nobody asked, a null means asked
/// and the answer is no, and collapsing the two is what mints a second forever-chat.
public enum PreferredSession: Sendable, Equatable {
    /// Neither `canonical_session` nor `preferred_session` on the row.
    case absent
    /// The key is present and `null` — the forever-chat does not resolve.
    case gone
    case present(ProfileSessionSummary)

    public var summary: ProfileSessionSummary? {
        if case .present(let summary) = self { return summary }
        return nil
    }

    /// True only for `.gone`. `.absent` must never drive a re-derivation.
    public var isResolvedMissing: Bool { self == .gone }

    init(row: JSONValue) {
        // `canonical_session` first: the server's own title lookup is better evidence than an echo
        // of a pointer we supplied, so if a build sends both, the resolved one wins.
        if let value = row["canonical_session"] {
            self = value.isNull ? .gone : .present(ProfileSessionSummary(json: value))
            return
        }
        guard let value = row["preferred_session"] else {
            self = .absent
            return
        }
        if value.isNull {
            self = .gone
            return
        }
        self = .present(ProfileSessionSummary(json: value))
    }
}

/// One `profiles.list` row; `ui_meta` and the forever-chat key are conditional, and `model` and
/// `provider` are genuinely nullable on the wire, hence optional rather than empty strings.
public struct HermesProfile: Sendable, Equatable, Identifiable {
    /// The profile slug is the identity — there is no other stable key.
    public var id: String { name }

    public let name: String
    /// The profile's HERMES_HOME on disk.
    public let path: String
    public let isDefault: Bool
    public let model: String?
    public let provider: String?
    public let description: String
    public let displayName: String
    public let skillCount: Int
    /// Newest *visible* human session. **Never the Bot Chat**: the lookup omits
    /// `include_hidden` and canonical Bot Chats are born hidden
    /// (`methods_profiles.py:159-161`, filter at `hermes_state.py:9486`).
    public let lastSession: ProfileSessionSummary?
    public let workerSession: ProfileWorkerSummary?
    public let preferredSession: PreferredSession
    /// Opaque client-namespaced blob, `.null` when the row omitted the key —
    /// which is the ordinary case on an install Bot Mode never touched.
    public let uiMeta: JSONValue
    public let hasAvatar: Bool

    public init(
        name: String,
        path: String = "",
        isDefault: Bool = false,
        model: String? = nil,
        provider: String? = nil,
        description: String = "",
        displayName: String = "",
        skillCount: Int = 0,
        lastSession: ProfileSessionSummary? = nil,
        workerSession: ProfileWorkerSummary? = nil,
        preferredSession: PreferredSession = .absent,
        uiMeta: JSONValue = .null,
        hasAvatar: Bool = false
    ) {
        self.name = name
        self.path = path
        self.isDefault = isDefault
        self.model = model
        self.provider = provider
        self.description = description
        self.displayName = displayName
        self.skillCount = skillCount
        self.lastSession = lastSession
        self.workerSession = workerSession
        self.preferredSession = preferredSession
        self.uiMeta = uiMeta
        self.hasAvatar = hasAvatar
    }

    public init(json: JSONValue) {
        name = json["name"]?.coercedString ?? ""
        path = json["path"]?.coercedString ?? ""
        isDefault = json["is_default"]?.coercedBool ?? false
        model = json["model"]?.coercedString
        provider = json["provider"]?.coercedString
        description = json["description"]?.coercedString ?? ""
        displayName = json["display_name"]?.coercedString ?? ""
        skillCount = json["skill_count"]?.coercedInt ?? 0
        lastSession = json["last_session"].flatMap { value in
            value.isNull ? nil : ProfileSessionSummary(json: value)
        }
        workerSession = json["worker_session"].flatMap { value in
            value.isNull ? nil : ProfileWorkerSummary(json: value)
        }
        preferredSession = PreferredSession(row: json)
        uiMeta = json["ui_meta"] ?? .null
        hasAvatar = json["has_avatar"]?.coercedBool ?? false
    }

    /// Desktop's pin for this bot's forever-chat: a HINT, never authority, since nothing in the
    /// backend reads it and it goes stale the moment Desktop moves. Read it only with no local pin.
    public var botChatPinHint: String? {
        guard let pin = uiMeta["hermes-bots"]?["chat"]?.coercedString, !pin.isEmpty else {
            return nil
        }
        return pin
    }
}

/// `profiles.list` result — exactly two top-level keys.
public struct ProfilesListResult: Sendable, Equatable {
    public let profiles: [HermesProfile]
    /// Presence-based capability flag: the backend injects the Bot Mode teammate protocol itself,
    /// so a client must not write it into SOUL.md. Never sent as `false`, only absent.
    public let botModeProtocol: Bool

    public init(profiles: [HermesProfile], botModeProtocol: Bool = false) {
        self.profiles = profiles
        self.botModeProtocol = botModeProtocol
    }

    public init(json: JSONValue) {
        profiles = (json["profiles"]?.arrayValue ?? []).map(HermesProfile.init(json:))
        botModeProtocol = json["bot_mode_protocol"]?.coercedBool ?? false
    }
}

/// A profile asset fetched over `profiles.get_asset`. Only `avatar` exists.
public struct ProfileAsset: Sendable, Equatable {
    public let mime: String
    public let data: Data

    public init(mime: String, data: Data) {
        self.mime = mime
        self.data = data
    }
}

/// The one session title that is an identity rather than a name.
public enum BotChat {
    /// A partial UNIQUE index on `sessions(title)` makes this unique per profile database.
    public static let title = "Bot Chat"
}

// MARK: - ProfilesAPI

/// Typed wrappers over the two read-only `profiles.*` RPCs this client uses; deliberately
/// read-only, because `profiles.configure` writes `ui_meta` whole-object and a blind write clobbers
/// Desktop's metadata for that bot.
public struct ProfilesAPI: Sendable {
    private let client: HermesClient

    public init(client: HermesClient) {
        self.client = client
    }

    /// `profiles.list` — the whole roster, always: no filter, no pagination, default first.
    ///
    /// `preferredSessionIDs` maps profile name to durable pin, and on an older backend it is the
    /// ONLY way a hidden Bot Chat appears in this response. Newer backends ignore it and answer on
    /// `canonical_session`; keep sending it until no supported backend needs it.
    public func list(preferredSessionIDs: [String: String] = [:]) async throws -> ProfilesListResult {
        var params: [String: JSONValue] = ["include_sessions": .bool(true)]
        if !preferredSessionIDs.isEmpty {
            params["preferred_session_ids"] = .object(
                preferredSessionIDs.mapValues { JSONValue.string($0) }
            )
        }
        let result = try await client.request("profiles.list", params: .object(params))
        return ProfilesListResult(json: result)
    }

    /// `profiles.get_asset` — a profile's avatar, as bytes.
    ///
    /// `nil` covers both "no such asset" and "the payload did not decode": a missing asset is
    /// `{found: false}`, not an error, so probing is cheap. Only transport/RPC failures throw.
    public func getAsset(profile: String, asset: String = "avatar") async throws -> ProfileAsset? {
        let result = try await client.request("profiles.get_asset", params: .object([
            "name": .string(profile),
            "asset": .string(asset),
        ]))
        guard result["found"]?.coercedBool ?? false else { return nil }
        guard let url = result["data"]?.coercedString, !url.isEmpty else { return nil }
        guard let decoded = Self.decodeDataURL(url) else { return nil }
        // The response's own `mime` is authoritative — it is what the backend
        // matched the file extension to; the URL's copy is built from it.
        let declared = result["mime"]?.coercedString ?? ""
        return ProfileAsset(mime: declared.isEmpty ? decoded.mime : declared, data: decoded.data)
    }

    /// Split `data:<mime>;base64,<payload>` into its parts; every part is checked, because trusting
    /// the prefix would hand `Data()` to an image decoder on any other shape.
    static func decodeDataURL(_ url: String) -> (mime: String, data: Data)? {
        guard url.hasPrefix("data:"), let comma = url.firstIndex(of: ",") else { return nil }
        let header = url[url.index(url.startIndex, offsetBy: 5)..<comma]
        guard header.hasSuffix(";base64") else { return nil }
        let mime = String(header.dropLast(";base64".count))
        let payload = String(url[url.index(after: comma)...])
        guard let data = Data(base64Encoded: payload, options: [.ignoreUnknownCharacters]),
              !data.isEmpty
        else { return nil }
        return (mime, data)
    }
}
