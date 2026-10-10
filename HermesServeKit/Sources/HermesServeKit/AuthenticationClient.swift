import Foundation

/// Identity returned by `GET /api/auth/me` (rest-api-and-auth.md §2.6).
public struct AuthIdentity: Sendable, Equatable {
    public let userID: String
    public let email: String
    public let displayName: String
    public let orgID: String
    public let provider: String
    public let expiresAt: Double?

    public init(json: JSONValue) {
        userID = json["user_id"]?.coercedString ?? ""
        email = json["email"]?.coercedString ?? ""
        displayName = json["display_name"]?.coercedString ?? ""
        orgID = json["org_id"]?.coercedString ?? ""
        provider = json["provider"]?.coercedString ?? ""
        expiresAt = json["expires_at"]?.coercedDouble
    }

    public var bestName: String {
        if !displayName.isEmpty { return displayName }
        if !email.isEmpty { return email }
        return userID
    }
}

/// One entry from `GET /api/auth/providers` (public; 503 when none registered).
public struct AuthProviderInfo: Sendable, Equatable, Identifiable {
    public let name: String
    public let displayName: String
    public let supportsPassword: Bool

    public var id: String { name }

    public init(json: JSONValue) {
        name = json["name"]?.coercedString ?? ""
        displayName = json["display_name"]?.coercedString ?? ""
        supportsPassword = json["supports_password"]?.coercedBool ?? false
    }
}

/// Owns credentials and every authenticated HTTP round trip.
/// Secrets live only in the Keychain and this actor's memory; request logging records the method, the redacted URL and the status code, never headers or bodies.
public actor AuthenticationClient {
    /// Keychain-backed secret slots, namespaced per backend profile.
    public enum SecretKind: String, Sendable, CaseIterable {
        /// Loopback `_SESSION_TOKEN`.
        case sessionToken
        /// Gated-mode provider access token.
        case bearerToken
        /// Gated-mode password-provider password.
        case password
        /// Native-flow refresh token (`POST /auth/native/refresh`).
        case refreshToken
    }

    private(set) public var configuration: BackendConfiguration
    private let profileID: String
    private let keychain: KeychainStore
    private let persistsSecrets: Bool
    private let log: ConnectionLog?
    private let session: URLSession

    /// In-memory mirror of the Keychain, populated lazily.
    private var secrets: [SecretKind: String] = [:]
    private var secretsLoaded = false

    /// - Parameter persistsSecrets: when false, secret writes stay in this actor's memory and never reach the Keychain (reads are unaffected), so a provisional profile the user cancels leaves nothing behind.
    /// - Parameter protocolClasses: URL protocols tried before the system's, so a test can answer this client's requests without a server.
    public init(
        configuration: BackendConfiguration,
        profileID: String,
        keychain: KeychainStore = KeychainStore(),
        persistsSecrets: Bool = true,
        log: ConnectionLog? = nil,
        protocolClasses: [AnyClass] = []
    ) {
        self.configuration = configuration
        self.profileID = profileID
        self.keychain = keychain
        self.persistsSecrets = persistsSecrets
        self.log = log

        let config = URLSessionConfiguration.default
        // Per rest-api-and-auth.md §2.5: gated password login hands back HttpOnly cookies and nothing else, so the cookie jar is load-bearing for that one mode.
        config.httpCookieAcceptPolicy = .always
        config.httpShouldSetCookies = true
        config.httpCookieStorage = HTTPCookieStorage.shared
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 30
        config.waitsForConnectivity = false
        if !protocolClasses.isEmpty {
            config.protocolClasses = protocolClasses + (config.protocolClasses ?? [])
        }
        self.session = URLSession(configuration: config)
    }

    public func updateConfiguration(_ configuration: BackendConfiguration) {
        self.configuration = configuration
    }

    // MARK: - Secret storage

    private static func account(profileID: String, kind: SecretKind) -> String {
        "\(profileID).\(kind.rawValue)"
    }

    private func account(for kind: SecretKind) -> String {
        Self.account(profileID: profileID, kind: kind)
    }

    /// Erase every Keychain slot belonging to `profileID`.
    /// Static because a deleted profile has to be cleaned up without a live client: its address may no longer parse, and once the profile row is gone nothing else knows the namespace.
    public static func clearSecrets(profileID: String, keychain: KeychainStore = KeychainStore()) {
        for kind in SecretKind.allCases {
            try? keychain.delete(account: account(profileID: profileID, kind: kind))
        }
    }

    /// Delete every cookie stored for `baseURL`; static for the same reason as `clearSecrets`.
    /// Cookies are per-host, not per-profile, so this signs the host out for every profile pointing at it.
    public static func clearCookies(for baseURL: URL) {
        let storage = HTTPCookieStorage.shared
        for cookie in storage.cookies(for: baseURL) ?? [] {
            storage.deleteCookie(cookie)
        }
    }

    private func loadSecretsIfNeeded() {
        guard !secretsLoaded else { return }
        secretsLoaded = true
        for kind in SecretKind.allCases {
            if let value = try? keychain.string(for: account(for: kind)), !value.isEmpty {
                secrets[kind] = value
            }
        }
    }

    public func setSecret(_ value: String?, kind: SecretKind) throws {
        loadSecretsIfNeeded()
        guard let value, !value.isEmpty else {
            secrets[kind] = nil
            if persistsSecrets { try keychain.delete(account: account(for: kind)) }
            return
        }
        secrets[kind] = value
        if persistsSecrets { try keychain.setString(value, for: account(for: kind)) }
    }

    public func hasSecret(_ kind: SecretKind) -> Bool {
        loadSecretsIfNeeded()
        return secrets[kind]?.isEmpty == false
    }

    /// Only the transport layer should call this; the secret never leaves the actor except as a header value or a WS query parameter.
    private func secret(_ kind: SecretKind) -> String? {
        loadSecretsIfNeeded()
        return secrets[kind]
    }

    public func clearAllSecrets() {
        loadSecretsIfNeeded()
        for kind in SecretKind.allCases {
            secrets[kind] = nil
        }
        if persistsSecrets { Self.clearSecrets(profileID: profileID, keychain: keychain) }
    }

    // MARK: - Request building

    /// Attach whatever credential this mode uses.
    /// Per rest-api-and-auth.md §2.4: the gate checks `Authorization: Bearer` before the cookie path and does not fall through on failure, so password mode must not send a bearer header at all.
    private func authorize(_ request: inout URLRequest) {
        switch configuration.authMode {
        case .none:
            break
        case .sessionToken, .auto:
            if let token = secret(.sessionToken) {
                request.setValue(token, forHTTPHeaderField: "X-Hermes-Session-Token")
                request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            } else if let bearer = secret(.bearerToken) {
                request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
            }
        case .bearer:
            if let bearer = secret(.bearerToken) {
                request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
            }
        case .password:
            break // cookie jar only
        }
    }

    public func makeRequest(
        _ path: String,
        method: String = "GET",
        query: [URLQueryItem] = [],
        body: Data? = nil,
        contentType: String? = nil,
        authenticated: Bool = true
    ) -> URLRequest {
        var request = URLRequest(url: configuration.restURL(path, query: query))
        request.httpMethod = method
        request.httpBody = body
        if let contentType { request.setValue(contentType, forHTTPHeaderField: "Content-Type") }
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        // Deliberately no Origin header: an absent Origin is allowed on both REST and the WS upgrade, and CORS does not apply to URLSession (rest-api-and-auth.md §2.10).
        if authenticated { authorize(&request) }
        return request
    }

    // MARK: - Transport

    @discardableResult
    public func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let method = request.httpMethod ?? "GET"
        let redactedURL = request.url.map(Redaction.url) ?? "<no url>"
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw HermesError.malformedResponse("non-HTTP response")
            }
            await log?.debug("http", "\(method) \(redactedURL) → \(http.statusCode)")
            try Self.validate(status: http.statusCode, data: data)
            return (data, http)
        } catch let error as HermesError {
            throw error
        } catch {
            let mapped = HermesError.from(error)
            await log?.warning("http", "\(method) \(redactedURL) failed: \(mapped.localizedDescription)")
            throw mapped
        }
    }

    public func performJSON(_ request: URLRequest) async throws -> JSONValue {
        let (data, _) = try await perform(request)
        return try Self.decodeBody(data)
    }

    /// A 2xx body as JSON: empty is `.null`, the 204 case, and anything else must decode, because a body that does not is a page or a cut-off reply from something other than the route, not a success the caller can read. `RestAPI.sendJSON` shares it so a write is judged like a read (BUG-146).
    static func decodeBody(_ data: Data) throws -> JSONValue {
        if data.isEmpty { return .null }
        do {
            return try JSONDecoder().decode(JSONValue.self, from: data)
        } catch {
            let preview = String(data: data.prefix(200), encoding: .utf8) ?? ""
            throw HermesError.malformedResponse("expected JSON, got: \(Redaction.text(preview))")
        }
    }

    /// Map the gate's documented failure envelopes onto typed errors (rest-api-and-auth.md §2.11).
    /// Internal rather than private so the status mapping can be pinned without a network stub.
    static func validate(status: Int, data: Data) throws {
        guard !(200...299).contains(status) else { return }
        let json = try? JSONDecoder().decode(JSONValue.self, from: data)
        // A structured detail carries its sentence one level down (`{"detail": {"error": …, "message": …}}`, the session store's 503s), and without this the raw envelope reached the screen.
        let detail = json?["detail"]?.coercedString
            ?? json?["detail"]?["message"]?.coercedString
            ?? json?["error"]?.coercedString
            ?? String(data: data.prefix(300), encoding: .utf8)
            ?? ""
        switch status {
        case 401:
            let reason = json?["error"]?.coercedString ?? ""
            if reason == "session_expired" {
                throw HermesError.unauthorized("Your session expired. Sign in again.")
            }
            throw HermesError.unauthorized(detail.isEmpty ? "Not authorized." : detail)
        case 413:
            throw HermesError.httpStatus(code: status, message: detail.isEmpty ? "Payload too large" : detail)
        default:
            // A 503 lands here with no special case (FEAT-038). The session routes answer 503 for an unreadable `state.db` since 0.21.0, and every auth-gate 503 already names its provider in the detail, so the backend's own sentence is the truth and the client has no cause of its own to add.
            throw HermesError.httpStatus(code: status, message: Redaction.text(detail))
        }
    }

    // MARK: - Auth flows

    /// `GET /api/auth/providers` — public; 503 means none registered.
    public func providers() async throws -> [AuthProviderInfo] {
        let request = makeRequest("/api/auth/providers", authenticated: false)
        let json = try await performJSON(request)
        let list = json["providers"]?.arrayValue ?? []
        return list.map(AuthProviderInfo.init(json:))
    }

    /// The provider a password sign-in names: the one typed, else the backend's only password provider.
    /// The route declares `provider` with no default and answers 422 without it, so a blank field cannot simply be omitted; with several password providers the person has to choose, and nothing is sent until they do.
    static func passwordProvider(typed: String, advertised: [AuthProviderInfo]) throws -> String {
        let typed = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        if !typed.isEmpty { return typed }
        let candidates = advertised.filter(\.supportsPassword).map(\.name).filter { !$0.isEmpty }
        switch candidates.count {
        case 1:
            return candidates[0]
        case 0:
            throw HermesError.unauthorized("This backend does not offer password sign-in. Choose another method.")
        default:
            throw HermesError.missingCredential("This backend has more than one way to sign in. Enter one of these in Provider: \(candidates.joined(separator: ", ")).")
        }
    }

    /// Asked once per client: the provider list only changes when the backend's auth plugins do.
    private var advertisedPasswordProvider: String?

    private func resolvePasswordProvider(_ typed: String) async throws -> String {
        let trimmed = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        if let advertisedPasswordProvider { return advertisedPasswordProvider }
        let advertised: [AuthProviderInfo]
        do {
            advertised = try await providers()
        } catch HermesError.httpStatus(let code, _) where code == 503 || code == 404 {
            advertised = []
        }
        let resolved = try Self.passwordProvider(typed: "", advertised: advertised)
        advertisedPasswordProvider = resolved
        return resolved
    }

    /// `POST /auth/password-login` — 200 + `Set-Cookie`, no token in the body, rate limited to 10 attempts per IP per 60 s (rest-api-and-auth.md §2.5).
    public func passwordLogin(provider typedProvider: String, username: String, password: String) async throws {
        let provider = try await resolvePasswordProvider(typedProvider)
        let body: [String: JSONValue] = [
            "provider": .string(provider),
            "username": .string(username),
            "password": .string(password),
            "next": .string(""),
        ]
        let data = try JSONRPCCodec.encodeLine(.object(body)).data(using: .utf8) ?? Data()
        var request = URLRequest(url: configuration.restURL("/auth/password-login"))
        request.httpMethod = "POST"
        request.httpBody = data
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        do {
            _ = try await perform(request)
        } catch let error as HermesError {
            if case .httpStatus(let code, _) = error, code == 429 {
                throw HermesError.httpStatus(code: 429, message: "Too many login attempts. Try again shortly.")
            }
            if case .httpStatus(let code, _) = error, code == 404 {
                throw HermesError.unauthorized("Unknown provider, or it does not support password login.")
            }
            throw error
        }
        try setSecret(password, kind: .password)
        // BUG-072C: the account name is deliberately absent, because this log is copied into shareable bug reports and `Redaction.text` cannot pattern-match a username.
        await log?.info(
            "auth", "password login succeeded (provider: \(provider)\(typedProvider.isEmpty ? ", chosen automatically" : ""))")
    }

    /// Re-run a stored password login after a 401, since the cookies are 15-minute access tokens (rest-api-and-auth.md §2.6).
    public func reauthenticateIfPossible() async throws -> Bool {
        guard configuration.authMode == .password,
              let password = secret(.password),
              !configuration.username.isEmpty
        else { return false }
        try await passwordLogin(
            provider: configuration.providerName,
            username: configuration.username,
            password: password
        )
        return true
    }

    /// `GET /api/auth/me` — works with either a cookie or a bearer.
    public func identity() async throws -> AuthIdentity {
        let json = try await performJSON(makeRequest("/api/auth/me"))
        return AuthIdentity(json: json)
    }

    /// `POST /auth/logout` responds 302, not JSON, and there is no bearer revocation endpoint, so for a bearer client logout is discard-locally (rest-api-and-auth.md §2.12).
    public func logout() async {
        var request = URLRequest(url: configuration.restURL("/auth/logout"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        _ = try? await session.data(for: request)
        Self.clearCookies(for: configuration.baseURL)
        clearAllSecrets()
        await log?.info("auth", "signed out and cleared stored credentials")
    }

    /// `POST /api/auth/ws-ticket` → `{ticket, ttl_seconds}`.
    /// Per reference-clients.md §2.4: single-use with a 30 s TTL, so mint a fresh one before every connect attempt.
    public func mintWebSocketTicket() async throws -> String {
        var request = makeRequest("/api/auth/ws-ticket", method: "POST")
        request.httpBody = Data()
        let json = try await performJSON(request)
        guard let ticket = json["ticket"]?.coercedString, !ticket.isEmpty else {
            throw HermesError.malformedResponse("/api/auth/ws-ticket returned no ticket")
        }
        return ticket
    }

    /// The session token, for the one HTTP route that accepts a query credential: `GET /api/files/download` (rest-api-and-auth.md §2.3).
    /// Returns nil in gated mode, where the query token is not honoured; no other caller may use it.
    public func queryTokenForDownload() -> String? {
        switch configuration.authMode {
        case .sessionToken, .auto: return secret(.sessionToken)
        case .none, .bearer, .password: return nil
        }
    }

    /// Resolve the WS URL for one connect attempt: all a loopback dial, or any caller indifferent to subprotocols, needs.
    public func webSocketURL(authRequired: Bool) async throws -> URL {
        try await webSocketDial(authRequired: authRequired, preferSubprotocol: false).url
    }

    /// Resolve one connect attempt: where to dial, and what to offer in `Sec-WebSocket-Protocol`.
    /// `authRequired` comes from the live `/api/status` probe rather than the stored mode, so a backend rebound from loopback to a LAN address is handled without the user editing settings.
    /// FEAT-015: `preferSubprotocol` moves a gated dial's ticket into the protocol header and changes nothing on the loopback path, whose `?token=` the server reads only from the query.
    public func webSocketDial(
        authRequired: Bool,
        preferSubprotocol: Bool = false
    ) async throws -> GatewayDial {
        if authRequired {
            if configuration.authMode == .password, !hasSecret(.password), !hasSecret(.bearerToken) {
                throw HermesError.missingCredential("This backend requires sign-in. Add credentials in Settings.")
            }
            if configuration.authMode == .bearer, !hasSecret(.bearerToken) {
                throw HermesError.missingCredential("This backend requires a bearer token. Add one in Settings.")
            }
            do {
                let ticket = try await mintWebSocketTicket()
                return try ticketDial(ticket, preferSubprotocol: preferSubprotocol)
            } catch let error as HermesError where error.isAuthenticationFailure {
                // Cookies expire every ~15 minutes, so try one silent re-login before surfacing "sign in again".
                if try await reauthenticateIfPossible() {
                    let ticket = try await mintWebSocketTicket()
                    return try ticketDial(ticket, preferSubprotocol: preferSubprotocol)
                }
                throw error
            }
        }
        // Loopback: `?token=` is the only accepted credential, and it is rejected outright in gated mode (rest-api-and-auth.md §2.10).
        if let token = secret(.sessionToken), !token.isEmpty {
            return GatewayDial(url: try configuration.webSocketURL(authParam: (name: "token", value: token)))
        }
        return GatewayDial(url: try configuration.webSocketURL(authParam: nil))
    }

    /// The two shapes a gated dial can take.
    /// The subprotocol shape builds its URL with no auth parameter, which is the point: the credential leaves the part of the request that gets logged, proxied and captured in crash reports.
    private func ticketDial(_ ticket: String, preferSubprotocol: Bool) throws -> GatewayDial {
        if preferSubprotocol {
            return GatewayDial(
                url: try configuration.webSocketURL(authParam: nil),
                protocols: GatewayWSProtocol.offer(ticket: ticket)
            )
        }
        return GatewayDial(url: try configuration.webSocketURL(authParam: (name: "ticket", value: ticket)))
    }
}
