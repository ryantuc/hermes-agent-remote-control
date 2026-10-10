import Foundation

/// One provider + model pair as the backend's config carries it: the main model, a `fallback_providers` entry, an auxiliary task slot, or the delegation pin.
public struct ModelPair: Sendable, Equatable, Hashable {
    public var provider: String
    public var model: String

    public init(provider: String, model: String) {
        self.provider = provider.trimmingCharacters(in: .whitespacesAndNewlines)
        self.model = model.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The pair read off two sibling config keys. `auto` is how an auxiliary slot spells "no provider of its own", so it reads as none here.
    public init(providerValue: JSONValue?, modelValue: JSONValue?) {
        let provider = providerValue?.coercedString ?? ""
        self.init(
            provider: provider.lowercased() == "auto" ? "" : provider,
            model: modelValue?.coercedString ?? ""
        )
    }

    /// A pair with no model at all, which every consumer reads as "use the main model".
    public var isEmpty: Bool { model.isEmpty }

    /// `provider/model` for the eye; the bare model when no provider is known.
    public var displayText: String {
        provider.isEmpty ? model : "\(provider)/\(model)"
    }

    /// A typed `provider/model`, split at the first slash the way Desktop's fallback editor reads a legacy string entry; no slash means no provider.
    public static func parsing(_ text: String) -> ModelPair {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let slash = trimmed.firstIndex(of: "/"), slash != trimmed.startIndex else {
            return ModelPair(provider: "", model: trimmed)
        }
        return ModelPair(
            provider: String(trimmed[..<slash]),
            model: String(trimmed[trimmed.index(after: slash)...])
        )
    }
}

/// One entry of `fallback_providers`: the pair the editor changes, plus every other key the entry carries (`base_url`, `key_env`, `api_mode`, …), which ride along untouched so a saved chain never loses the routing someone wrote by hand.
public struct FallbackEntry: Sendable, Identifiable {
    public let id: UUID
    public var pair: ModelPair
    public var extras: [String: JSONValue]

    public init(pair: ModelPair, extras: [String: JSONValue] = [:], id: UUID = UUID()) {
        self.id = id
        self.pair = pair
        self.extras = extras.filter { $0.key != "provider" && $0.key != "model" }
    }

    public init(provider: String, model: String) {
        self.init(pair: ModelPair(provider: provider, model: model))
    }

    /// Complete enough for the backend to use: it drops an entry missing either half.
    public var isComplete: Bool { !pair.provider.isEmpty && !pair.model.isEmpty }

    public var json: JSONValue {
        var object = extras
        object["provider"] = .string(pair.provider)
        object["model"] = .string(pair.model)
        return .object(object)
    }
}

extension FallbackEntry: Equatable {
    /// Identity is for the list's benefit only; two entries are the same chain content regardless of it.
    public static func == (lhs: FallbackEntry, rhs: FallbackEntry) -> Bool {
        lhs.pair == rhs.pair && lhs.extras == rhs.extras
    }
}

/// The `fallback_providers` list: tried in order when the main model fails. The backend replaces the whole list on a write rather than merging it, so the editor always sends every entry.
public enum FallbackChain {
    public static let key = "fallback_providers"

    /// The entries a config value holds. Objects are the shape; a legacy `provider/model` string is tolerated the way Desktop tolerates it; anything else reads as no chain.
    public static func entries(from value: JSONValue?) -> [FallbackEntry] {
        let items: [JSONValue]
        switch value {
        case .array(let list)?: items = list
        case .object(let single)?: items = [.object(single)]
        default: return []
        }
        return items.compactMap { item in
            switch item {
            case .object(let object):
                return FallbackEntry(
                    pair: ModelPair(providerValue: object["provider"], modelValue: object["model"]),
                    extras: object
                )
            case .string(let text):
                return FallbackEntry(pair: ModelPair.parsing(text))
            default:
                return nil
            }
        }
    }

    /// The value to write: complete entries only, in order, extras preserved.
    public static func json(_ entries: [FallbackEntry]) -> JSONValue {
        .array(entries.filter(\.isComplete).map(\.json))
    }
}

/// `POST /api/model/set`: the route Desktop's model picker writes through for the main model and the auxiliary slots. It validates the pick against the provider's catalogue and credentials, normalises the slug, and asks before an expensive model.
public struct ModelAssignmentAPI: Sendable {
    private let auth: AuthenticationClient

    public init(auth: AuthenticationClient) {
        self.auth = auth
    }

    public enum Slot: Sendable, Equatable {
        /// `model.provider` + `model.default`, what every new conversation starts with.
        case main
        /// `auxiliary.<task>.provider` + `.model`.
        case auxiliary(task: String)
    }

    /// The request body, apart from the call so the shape can be pinned without a server.
    public static func body(slot: Slot, pair: ModelPair, confirmExpensive: Bool) -> JSONValue {
        var object: [String: JSONValue] = [
            "provider": .string(pair.provider),
            "model": .string(pair.model),
        ]
        switch slot {
        case .main:
            object["scope"] = .string("main")
        case .auxiliary(let task):
            object["scope"] = .string("auxiliary")
            object["task"] = .string(task)
        }
        if confirmExpensive { object["confirm_expensive_model"] = .bool(true) }
        return .object(object)
    }

    public func assign(
        _ pair: ModelPair,
        to slot: Slot,
        confirmExpensive: Bool = false,
        profile: String? = nil
    ) async throws -> ModelAssignmentResult {
        var query: [URLQueryItem] = []
        if let profile, !profile.isEmpty { query.append(URLQueryItem(name: "profile", value: profile)) }
        let body = Self.body(slot: slot, pair: pair, confirmExpensive: confirmExpensive)
        let data = try JSONRPCCodec.encodeLine(body).data(using: .utf8) ?? Data()
        let request = await auth.makeRequest(
            "/api/model/set",
            method: "POST",
            query: query,
            body: data,
            contentType: "application/json"
        )
        return ModelAssignmentResult(json: try await auth.performJSON(request))
    }
}

/// What `POST /api/model/set` answers: the pair as the backend normalised it, or a confirmation it wants first.
public struct ModelAssignmentResult: Sendable, Equatable {
    public let ok: Bool
    public let provider: String
    public let model: String
    public let confirmRequired: Bool
    public let confirmMessage: String

    public init(json: JSONValue) {
        ok = json["ok"]?.coercedBool ?? false
        provider = json["provider"]?.coercedString ?? ""
        model = json["model"]?.coercedString ?? ""
        confirmRequired = json["confirm_required"]?.coercedBool ?? false
        confirmMessage = json["confirm_message"]?.text ?? ""
    }
}
