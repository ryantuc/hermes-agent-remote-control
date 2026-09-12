import Foundation

/// How this client authenticates to one backend.
/// Per rest-api-and-auth.md §2.1: the backend picks its mode by bind host (loopback ⇒ ungated) and advertises it on `GET /api/status` as `auth_required`.
public enum BackendAuthMode: String, Sendable, Codable, CaseIterable, Identifiable {
    /// Decide from `/api/status` at connect time.
    case auto
    /// Loopback bind, no credential at all.
    case none
    /// Loopback `_SESSION_TOKEN`, sent as `X-Hermes-Session-Token` on REST and `?token=` on the WS upgrade (rest-api-and-auth.md §2.3).
    case sessionToken
    /// Gated mode with a provider-minted access token, sent as `Authorization: Bearer` on every REST route; no cookie jar (rest-api-and-auth.md §2.4).
    case bearer
    /// Gated mode via `POST /auth/password-login`, which hands back cookies only, no token in the body (rest-api-and-auth.md §2.5).
    case password

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .auto: return "Detect automatically"
        case .none: return "No authentication"
        case .sessionToken: return "Session token (loopback)"
        case .bearer: return "Bearer token"
        case .password: return "Username & password"
        }
    }

    /// Whether the WS upgrade needs a freshly minted single-use ticket rather than a long-lived `?token=`.
    public var usesWebSocketTicket: Bool {
        switch self {
        case .bearer, .password: return true
        case .auto, .none, .sessionToken: return false
        }
    }
}

/// Everything needed to address one `hermes serve` backend.
/// Per reference-clients.md §2.6: scheme, host and reverse-proxy prefix all derive from one user-supplied `https://host[/prefix]` base URL.
public struct BackendConfiguration: Sendable, Equatable, Codable {
    /// Normalized base URL: scheme + host + optional path prefix, no trailing slash, query or fragment.
    public var baseURL: URL
    public var authMode: BackendAuthMode
    /// Auth provider name for password login; empty means "the only one".
    public var providerName: String
    /// Username for password login; the password itself lives in the Keychain.
    public var username: String
    /// Optional `?profile=` scoping for REST reads.
    public var profile: String?

    public init(
        baseURL: URL,
        authMode: BackendAuthMode = .auto,
        providerName: String = "",
        username: String = "",
        profile: String? = nil
    ) {
        self.baseURL = baseURL
        self.authMode = authMode
        self.providerName = providerName
        self.username = username
        self.profile = profile
    }

    // MARK: - Base URL normalization

    /// Accepts what a human types: adds a missing scheme, rejects non-HTTP(S), strips query, fragment and trailing slashes.
    public static func normalizeBaseURL(_ raw: String) throws -> URL {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw HermesError.invalidURL("the address is empty")
        }
        let withScheme: String
        if trimmed.contains("://") {
            withScheme = trimmed
        } else {
            // Loopback and private addresses are overwhelmingly plain http; anything else defaults to https.
            withScheme = Self.looksLoopbackOrPrivate(trimmed) ? "http://\(trimmed)" : "https://\(trimmed)"
        }
        guard var components = URLComponents(string: withScheme) else {
            throw HermesError.invalidURL("could not parse \"\(trimmed)\"")
        }
        let scheme = (components.scheme ?? "").lowercased()
        guard scheme == "http" || scheme == "https" else {
            throw HermesError.invalidURL("only http:// and https:// are supported (got \(scheme)://)")
        }
        components.scheme = scheme
        guard let host = components.host, !host.isEmpty else {
            throw HermesError.invalidURL("no host in \"\(trimmed)\"")
        }
        components.host = host.lowercased()
        components.query = nil
        components.fragment = nil
        components.user = nil
        components.password = nil
        var path = components.path
        while path.hasSuffix("/") { path.removeLast() }
        components.path = path
        guard let url = components.url else {
            throw HermesError.invalidURL("could not rebuild \"\(trimmed)\"")
        }
        return url
    }

    private static func looksLoopbackOrPrivate(_ candidate: String) -> Bool {
        let host = candidate.split(separator: "/").first.map(String.init) ?? candidate
        let bare = host.split(separator: ":").first.map(String.init)?.lowercased() ?? host.lowercased()
        if bare == "localhost" || bare == "127.0.0.1" || bare == "::1" || bare.hasSuffix(".local") {
            return true
        }
        if bare.hasPrefix("192.168.") || bare.hasPrefix("10.") { return true }
        // Tailscale CGNAT range 100.64.0.0/10.
        if bare.hasPrefix("100.") {
            let parts = bare.split(separator: ".")
            if parts.count == 4, let second = Int(parts[1]), (64...127).contains(second) { return true }
        }
        if bare.hasPrefix("172.") {
            let parts = bare.split(separator: ".")
            if parts.count == 4, let second = Int(parts[1]), (16...31).contains(second) { return true }
        }
        return false
    }

    // MARK: - Derived URLs

    /// Reverse-proxy path prefix (`""` when served at root).
    public var basePath: String {
        var path = baseURL.path
        while path.hasSuffix("/") { path.removeLast() }
        return path
    }

    public var host: String { baseURL.host ?? "" }

    /// `host:port` as it appears in the `Host` header, which the backend's DNS-rebinding guard compares against its bind address (rest-api-and-auth.md §2.9).
    public var displayHost: String {
        guard let port = baseURL.port else { return host }
        return "\(host):\(port)"
    }

    public var isSecure: Bool { baseURL.scheme == "https" }

    /// Build a REST URL under this backend's prefix.
    public func restURL(_ path: String, query: [URLQueryItem] = []) -> URL {
        let normalizedPath = path.hasPrefix("/") ? path : "/" + path
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
            ?? URLComponents()
        components.path = basePath + normalizedPath
        var items = query.filter { $0.value?.isEmpty == false }
        if let profile, !profile.isEmpty, !items.contains(where: { $0.name == "profile" }) {
            items.append(URLQueryItem(name: "profile", value: profile))
        }
        components.queryItems = items.isEmpty ? nil : items
        guard let url = components.url else { return baseURL }
        return url
    }

    /// `wss://host{prefix}/api/ws?<auth>` (reference-clients.md §2.6); the auth parameter is `ticket` in gated mode and `token` on loopback.
    /// It is re-derived on every attempt because tickets are single-use with a 30 s TTL.
    public func webSocketURL(authParam: (name: String, value: String)?) throws -> URL {
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
            ?? URLComponents()
        components.scheme = isSecure ? "wss" : "ws"
        components.path = basePath + "/api/ws"
        if let authParam, !authParam.value.isEmpty {
            components.queryItems = [URLQueryItem(name: authParam.name, value: authParam.value)]
        } else {
            components.queryItems = nil
        }
        guard let url = components.url else {
            throw HermesError.invalidURL("could not build a WebSocket URL from \(baseURL.absoluteString)")
        }
        return url
    }
}
