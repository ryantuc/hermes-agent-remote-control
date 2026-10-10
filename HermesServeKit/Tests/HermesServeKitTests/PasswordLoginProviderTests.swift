import Foundation
import XCTest

@testable import HermesServeKit

/// `POST /auth/password-login` declares `provider` with no default (`hermes_cli/dashboard_auth/routes.py`, `_PasswordLoginBody`), so a body without it is FastAPI's 422 "field required". The editor labels the field "Provider (optional)" and fills it only after an address probe that found exactly one provider, so a person who signed in without waiting for the probe got the 422 instead of a sign-in.
final class PasswordLoginProviderTests: XCTestCase {

    private let base = URL(string: "http://192.0.2.10:9119")!

    override func tearDown() {
        StubBackend.reset()
        super.tearDown()
    }

    private func client() -> AuthenticationClient {
        AuthenticationClient(
            configuration: BackendConfiguration(baseURL: base, authMode: .password, username: "alice"),
            profileID: "password-provider-\(UUID().uuidString)",
            keychain: KeychainStore(service: "hermes.tests.password-provider.\(UUID().uuidString)"),
            persistsSecrets: false,
            protocolClasses: [StubBackend.self]
        )
    }

    private static func providers(_ entries: [(String, Bool)]) -> Data {
        let list = entries.map { #"{"name":"\#($0.0)","display_name":"\#($0.0)","supports_password":\#($0.1)}"# }
        return Data(#"{"providers":[\#(list.joined(separator: ","))]}"#.utf8)
    }

    func testABlankProviderSignsInWithTheBackendsOnlyPasswordProvider() async throws {
        StubBackend.providersBody = Self.providers([("basic", true)])

        try await client().passwordLogin(provider: "", username: "alice", password: "hunter2")

        XCTAssertEqual(StubBackend.loginProviders, ["basic"], "the sign-in must name the one password provider the backend advertises; without it the route answers 422")
    }

    func testABlankProviderOnABackendWithSeveralAsksForOneAndSendsNothing() async throws {
        StubBackend.providersBody = Self.providers([("basic", true), ("ldap", true), ("github", false)])

        do {
            try await client().passwordLogin(provider: "", username: "alice", password: "hunter2")
            XCTFail("a sign-in that cannot know which provider to use must not succeed")
        } catch HermesError.missingCredential(let message) {
            XCTAssertTrue(message.contains("basic") && message.contains("ldap"), "the message names the providers to choose from: \(message)")
            XCTAssertFalse(message.contains("github"), "a provider without password sign-in is not a choice here: \(message)")
        } catch {
            XCTFail("expected a missing-credential error naming the providers, got \(error)")
        }
        XCTAssertTrue(StubBackend.loginProviders.isEmpty, "no login request goes out until the person has chosen")
    }

    func testATypedProviderIsSentAsTypedWithoutAskingTheBackend() async throws {
        StubBackend.providersBody = Self.providers([("basic", true)])

        try await client().passwordLogin(provider: "ldap", username: "alice", password: "hunter2")

        XCTAssertEqual(StubBackend.loginProviders, ["ldap"])
        XCTAssertEqual(StubBackend.providerListRequests, 0)
    }

    func testTheRuleOnPlainValues() throws {
        let basic = AuthProviderInfo(json: .object(["name": .string("basic"), "supports_password": .bool(true)]))
        let oauth = AuthProviderInfo(json: .object(["name": .string("github"), "supports_password": .bool(false)]))
        XCTAssertEqual(try AuthenticationClient.passwordProvider(typed: "  ldap ", advertised: [basic]), "ldap", "a typed provider wins, trimmed")
        XCTAssertEqual(try AuthenticationClient.passwordProvider(typed: "", advertised: [oauth, basic]), "basic")
        XCTAssertThrowsError(try AuthenticationClient.passwordProvider(typed: "", advertised: [oauth])) { error in
            guard case HermesError.unauthorized = error else { return XCTFail("a backend with no password provider is a wrong method, got \(error)") }
        }
    }
}

/// Answers the two auth routes the way the backend does: the provider list as configured, and the login with 422 when `provider` is missing.
private final class StubBackend: URLProtocol {
    private static let lock = NSLock()
    private static var _providersBody = Data()
    private static var _loginProviders: [String] = []
    private static var _providerListRequests = 0

    static var providersBody: Data {
        get { lock.withLock { _providersBody } }
        set { lock.withLock { _providersBody = newValue } }
    }

    static var loginProviders: [String] { lock.withLock { _loginProviders } }
    static var providerListRequests: Int { lock.withLock { _providerListRequests } }

    static func reset() {
        lock.withLock {
            _providersBody = Data()
            _loginProviders = []
            _providerListRequests = 0
        }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let path = request.url?.path ?? ""
        switch path {
        case "/api/auth/providers":
            Self.lock.withLock { Self._providerListRequests += 1 }
            respond(200, Self.providersBody)
        case "/auth/password-login":
            let body = Self.bodyData(of: request)
            let json = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:]
            guard let provider = json["provider"] as? String else {
                respond(422, Data(#"{"detail":[{"type":"missing","loc":["body","provider"],"msg":"Field required"}]}"#.utf8))
                return
            }
            Self.lock.withLock { Self._loginProviders.append(provider) }
            respond(200, Data(#"{"ok":true,"next":"/"}"#.utf8))
        default:
            respond(404, Data(#"{"detail":"Not Found"}"#.utf8))
        }
    }

    override func stopLoading() {}

    private func respond(_ status: Int, _ body: Data) {
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    /// URLSession hands a protocol the body as a stream, not as `httpBody`.
    private static func bodyData(of request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return data
    }
}
