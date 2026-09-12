import Foundation

/// Typed callers for the config / model / usage RPCs, parsed defensively because `model.options`'s shape is defined outside the protocol layer and a missing field is normal rather than an error.
public struct ConfigAPI: Sendable {
    private let client: HermesClient

    public init(client: HermesClient) {
        self.client = client
    }

    /// `config.get` — returns the raw result, since each key has its own `{value: …}` shape.
    public func get(_ key: String, sessionID: String? = nil) async throws -> JSONValue {
        var params: [String: JSONValue] = ["key": .string(key)]
        if let sessionID { params["session_id"] = .string(sessionID) }
        return try await client.request("config.get", params: .object(params))
    }

    /// `config.get key`'s common `{value: <str>}` shape, unwrapped.
    public func getValue(_ key: String, sessionID: String? = nil) async throws -> String {
        try await get(key, sessionID: sessionID)["value"]?.coercedString ?? ""
    }

    /// `config.set` — a write emits `session.info`, which is how the UI reconciles, and a mid-turn write may come back `deferred: true`.
    @discardableResult
    public func set(
        _ key: String,
        value: JSONValue,
        sessionID: String? = nil,
        scope: String? = nil,
        confirmExpensiveModel: Bool = false
    ) async throws -> ConfigSetResult {
        var params: [String: JSONValue] = ["key": .string(key), "value": value]
        if let sessionID { params["session_id"] = .string(sessionID) }
        if let scope { params["scope"] = .string(scope) }
        if confirmExpensiveModel { params["confirm_expensive_model"] = .bool(true) }
        let result = try await client.request("config.set", params: .object(params))
        return ConfigSetResult(json: result)
    }

    /// `model.options` — the provider/model catalogue with capability flags.
    public func modelOptions() async throws -> ModelCatalogue {
        let result = try await client.request("model.options", params: .object([:]))
        return ModelCatalogue(json: result)
    }

    /// `session.usage` — poll at end-of-turn only, never on a timer, and context fields exist only when a compressor does.
    public func usage(sessionID: String) async throws -> SessionUsage {
        let result = try await client.request(
            "session.usage",
            params: .object(["session_id": .string(sessionID)])
        )
        return SessionUsage(json: result)
    }
}

// MARK: - Results

/// `config.set` result. Mirrors `hermes-web` `ConfigSetResult`.
public struct ConfigSetResult: Sendable, Equatable {
    public let key: String
    public let value: String
    public let warning: String
    public let confirmRequired: Bool
    public let confirmMessage: String
    public let scope: String
    /// The write was queued because a turn is running, and it is the one producer of `ValueState.pending`.
    public let deferred: Bool

    public init(json: JSONValue) {
        key = json["key"]?.coercedString ?? ""
        value = json["value"]?.coercedString ?? ""
        warning = json["warning"]?.text ?? ""
        confirmRequired = json["confirm_required"]?.coercedBool ?? false
        confirmMessage = json["confirm_message"]?.text ?? ""
        scope = json["scope"]?.coercedString ?? ""
        deferred = json["deferred"]?.coercedBool ?? false
    }
}

/// `session.usage`, where the context fields are present only when a context compressor exists.
public struct SessionUsage: Sendable, Equatable {
    public let model: String
    public let total: Int
    public let input: Int
    public let output: Int
    public let contextUsed: Int?
    public let contextMax: Int?
    public let contextPercent: Double?
    public let compressions: Int?

    public init(json: JSONValue) {
        model = json["model"]?.coercedString ?? ""
        total = json["total"]?.coercedInt ?? 0
        input = json["input"]?.coercedInt ?? 0
        output = json["output"]?.coercedInt ?? 0
        contextUsed = json["context_used"]?.coercedInt
        contextMax = json["context_max"]?.coercedInt
        contextPercent = json["context_percent"]?.coercedDouble
        compressions = json["compressions"]?.coercedInt
    }

    /// A context ring is meaningful only when the backend reports context state.
    public var hasContext: Bool {
        contextPercent != nil || (contextMax ?? 0) > 0
    }

    /// 0…1 for the ring. Falls back to used/max when percent is absent.
    public var contextFraction: Double? {
        if let percent = contextPercent { return min(max(percent / 100, 0), 1) }
        if let used = contextUsed, let max = contextMax, max > 0 {
            return min(Double(used) / Double(max), 1)
        }
        return nil
    }
}

/// `model.options` — the provider/model catalogue, whose shape is defined outside the protocol layer, so everything is optional.
public struct ModelCatalogue: Sendable, Equatable {
    public let providers: [ProviderRow]

    public init(json: JSONValue) {
        let raw = json["providers"]?.arrayValue ?? json.arrayValue ?? []
        // A slug is not guaranteed and two providers may repeat one, so each row gets an id it does not share.
        var claimed: Set<String> = []
        providers = raw.enumerated().map { index, entry in
            let slug = entry["slug"]?.coercedString ?? ""
            var id = slug.isEmpty ? "provider-\(index)" : slug
            if !claimed.insert(id).inserted {
                id = "\(id)#\(index)"
                claimed.insert(id)
            }
            return ProviderRow(json: entry, id: id)
        }
    }
}

/// One provider in the catalogue.
public struct ProviderRow: Sendable, Equatable, Identifiable {
    public let slug: String
    public let name: String
    public let isCurrent: Bool
    public let authenticated: Bool
    public let warning: String
    public let models: [ModelRow]
    public let featuredModels: [String]
    /// Per-model reasoning capability, defaulting to true when uncatalogued, because the effort dial is a no-op on models that ignore it and hiding it from a capable model is the worse failure.
    public let reasoningCapable: [String: Bool]
    /// Per-model `can_disable_reasoning`, stored only where the backend actually said it, since omission means "no restriction known" and must not be mistaken for a granted permission (FEAT-014).
    /// The catalogue warms in the background, so read this per picker open and never cache it across one.
    public let reasoningDisablable: [String: Bool]

    /// Unique within its catalogue; never send this to the backend, send `slug`.
    public let id: String

    public init(json: JSONValue, id: String? = nil) {
        let resolvedSlug = json["slug"]?.coercedString ?? ""
        slug = resolvedSlug
        self.id = id ?? resolvedSlug
        name = json["name"]?.coercedString ?? resolvedSlug
        isCurrent = json["is_current"]?.coercedBool ?? false
        authenticated = json["authenticated"]?.coercedBool ?? false
        warning = json["warning"]?.text ?? ""
        // A model row is its slug, so a slug-less entry is unselectable and a repeated one is the same model twice, and neither survives here.
        var seenModels: Set<String> = []
        models = (json["models"]?.arrayValue ?? [])
            .map(ModelRow.init(json:))
            .filter { !$0.slug.isEmpty && seenModels.insert($0.slug).inserted }
        featuredModels = (json["featured_models"]?.arrayValue ?? []).compactMap { $0.coercedString }
        var capabilities: [String: Bool] = [:]
        var disablable: [String: Bool] = [:]
        if case .object(let capsMap) = json["capabilities"] ?? .null {
            for (model, caps) in capsMap {
                capabilities[model] = caps["reasoning"]?.coercedBool ?? true
                // No `?? true` here: an absent key must stay absent so `canDisableReasoning` can tell "the backend says no" from "the backend has not said".
                if let stated = caps["can_disable_reasoning"]?.coercedBool {
                    disablable[model] = stated
                }
            }
        }
        reasoningCapable = capabilities
        reasoningDisablable = disablable
    }

    /// Whether `model` accepts the reasoning-effort dial. Unknown → true.
    public func supportsReasoning(_ model: String) -> Bool {
        reasoningCapable[model] ?? true
    }

    /// Whether `model` will honour an effort of `off`, unknown meaning true; on a reasoning-mandatory route this is the only warning the client gets, because the backend clamps `off` to the nearest supported level and the request silently succeeds (FEAT-014).
    public func canDisableReasoning(_ model: String) -> Bool {
        reasoningDisablable[model] ?? true
    }
}

/// One model. Entries arrive as either a bare string or an object.
public struct ModelRow: Sendable, Equatable, Identifiable {
    public let slug: String
    public let name: String
    public let isCurrent: Bool

    public var id: String { slug }

    public init(json: JSONValue) {
        if case .string(let s) = json {
            slug = s
            name = s
            isCurrent = false
            return
        }
        let resolved = json["slug"]?.coercedString
            ?? json["id"]?.coercedString
            ?? json["model"]?.coercedString
            ?? ""
        slug = resolved
        name = json["name"]?.coercedString ?? resolved
        isCurrent = json["is_current"]?.coercedBool ?? false
    }
}
