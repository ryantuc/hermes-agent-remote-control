import Foundation
import XCTest

@testable import HermesServeKit

/// From 0.22.1 the session write routes refuse a rename, pin, archive or delete that does not name the session's counters: `request_id` plus `expected_revision`, and `expected_generation` for a delete (`hermes_cli/web_server_sessions.py:269-275`, `hermes_state_runtime.py:493-521`). The counters come from `GET /api/sessions/{id}/mutation-snapshot` (`hermes_cli/web_routers/sessions.py:586-598`). Older backends have no such route and must get exactly the request they always got.
final class SessionMutationFenceTests: XCTestCase {

    private let base = URL(string: "http://192.0.2.10:9119")!

    override func tearDown() {
        FenceBackend.reset()
        super.tearDown()
    }

    private func rest() -> RestAPI {
        let auth = AuthenticationClient(
            configuration: BackendConfiguration(baseURL: base, authMode: .none),
            profileID: "session-fence-\(UUID().uuidString)",
            keychain: KeychainStore(service: "hermes.tests.session-fence.\(UUID().uuidString)"),
            persistsSecrets: false,
            protocolClasses: [FenceBackend.self]
        )
        return RestAPI(auth: auth)
    }

    // MARK: A backend with the fence

    func testAPinOnAFencedBackendNamesTheSnapshotsRevisionAndARequestID() async throws {
        FenceBackend.mode = .fenced(revision: 7, generation: 2)

        try await rest().patchSession(sessionID: "s1", pinned: true, profile: "work")

        let writes = FenceBackend.requests.filter { $0.method == "PATCH" }
        XCTAssertEqual(writes.count, 1)
        let body = try XCTUnwrap(writes.first?.json)
        XCTAssertEqual(body["pinned"] as? Bool, true)
        XCTAssertEqual(body["profile"] as? String, "work")
        XCTAssertEqual(body["expected_revision"] as? Int, 7)
        let requestID = try XCTUnwrap(body["request_id"] as? String)
        XCTAssertFalse(requestID.isEmpty)
        XCTAssertLessThanOrEqual(requestID.count, 1024)
        XCTAssertNil(body["expected_generation"], "a sidebar edit does not need the generation, and naming it would let a rewind or compression in between refuse it")
        XCTAssertTrue(writes[0].rawBody.contains(#""expected_revision":7"#), "the route's model is a strict integer, so 7.0 would be refused: \(writes[0].rawBody)")
        let snapshot = try XCTUnwrap(FenceBackend.requests.first { $0.path.hasSuffix("/mutation-snapshot") })
        XCTAssertEqual(snapshot.method, "GET")
        XCTAssertEqual(snapshot.path, "/api/sessions/s1/mutation-snapshot")
        XCTAssertEqual(snapshot.query["profile"], "work", "the counters must come from the store the write goes to")
    }

    func testARenameAndAnArchiveCarryTheSameFence() async throws {
        FenceBackend.mode = .fenced(revision: 3, generation: 1)

        try await rest().patchSession(sessionID: "s1", title: "Groceries")
        try await rest().patchSession(sessionID: "s1", archived: true)

        let bodies = FenceBackend.requests.filter { $0.method == "PATCH" }.compactMap(\.json)
        XCTAssertEqual(bodies.count, 2)
        XCTAssertEqual(bodies[0]["title"] as? String, "Groceries")
        XCTAssertEqual(bodies[0]["expected_revision"] as? Int, 3)
        XCTAssertEqual(bodies[1]["archived"] as? Bool, true)
        XCTAssertEqual(bodies[1]["expected_revision"] as? Int, 4, "each write reads the counters afresh; the first write moved the revision on")
        XCTAssertNotEqual(bodies[0]["request_id"] as? String, bodies[1]["request_id"] as? String, "two intents are two request ids; the backend replays a reused one")
    }

    func testADeleteOnAFencedBackendNamesAllThreeCountersInTheQuery() async throws {
        FenceBackend.mode = .fenced(revision: 7, generation: 2)

        try await rest().deleteSession(sessionID: "s1", profile: "work")

        let deletes = FenceBackend.requests.filter { $0.method == "DELETE" }
        XCTAssertEqual(deletes.count, 1)
        let query = try XCTUnwrap(deletes.first?.query)
        XCTAssertEqual(query["expected_revision"], "7")
        XCTAssertEqual(query["expected_generation"], "2", "a delete without the generation is answered 400")
        XCTAssertEqual(query["profile"], "work")
        XCTAssertFalse((query["request_id"] ?? "").isEmpty)
        XCTAssertNil(deletes.first?.json, "the route takes its fence in the query, not a body")
    }

    func testADeleteOfASessionTheBackendNoLongerHasSendsNoDelete() async throws {
        FenceBackend.mode = .fenced(revision: 0, generation: nil, exists: false)

        try await rest().deleteSession(sessionID: "gone")

        XCTAssertTrue(FenceBackend.requests.filter { $0.method == "DELETE" }.isEmpty, "already gone is what a delete asks for")
    }

    /// The desktop app never reads a fresh precondition after a conflict (`apps/shared/src/session-http-mutations.ts:45-48`): the conversation changed after the person decided, and a silent retry would overwrite that change.
    func testARevisionConflictReachesTheCallerAndNothingIsResent() async throws {
        FenceBackend.mode = .fenced(revision: 5, generation: 1)
        FenceBackend.conflicts = 1

        do {
            try await rest().patchSession(sessionID: "s1", pinned: true)
            XCTFail("a conflicted write must reach the caller")
        } catch HermesError.httpStatus(let code, let message) {
            XCTAssertEqual(code, 409)
            XCTAssertEqual(message, "revision_conflict")
        }
        XCTAssertEqual(FenceBackend.requests.filter { $0.method == "PATCH" }.count, 1, "no retry")
        XCTAssertEqual(FenceBackend.requests.filter { $0.path.hasSuffix("/mutation-snapshot") }.count, 1, "no second read of the counters")
    }

    func testADeleteConflictIsNotRetried() async throws {
        FenceBackend.mode = .fenced(revision: 5, generation: 1)
        FenceBackend.conflicts = 1

        do {
            try await rest().deleteSession(sessionID: "s1")
            XCTFail("a refused delete must reach the caller")
        } catch HermesError.httpStatus(let code, let message) {
            XCTAssertEqual(code, 409)
            XCTAssertEqual(message, "revision_conflict")
        }
        XCTAssertEqual(FenceBackend.requests.filter { $0.method == "DELETE" }.count, 1)
    }

    func testARefusalReachesTheCallerWithTheBackendsOwnReason() async throws {
        FenceBackend.mode = .fenced(revision: 0, generation: 0)
        FenceBackend.refusal = (404, "not_found")

        do {
            try await rest().patchSession(sessionID: "s1", archived: true)
            XCTFail("a refused write must reach the caller")
        } catch HermesError.httpStatus(let code, let message) {
            XCTAssertEqual(code, 404)
            XCTAssertEqual(message, "not_found")
        }
        do {
            try await rest().deleteSession(sessionID: "s1")
            XCTFail("a refused delete must reach the caller")
        } catch HermesError.httpStatus(let code, let message) {
            XCTAssertEqual(code, 404)
            XCTAssertEqual(message, "not_found")
        }
    }

    func testASnapshotFailureThatIsNotAMissingRouteSendsNoWrite() async throws {
        FenceBackend.mode = .snapshotFails(status: 503, body: #"{"detail":"owner_unreachable"}"#)

        do {
            try await rest().patchSession(sessionID: "s1", pinned: true)
            XCTFail("a write whose counters could not be read must not go out unfenced")
        } catch HermesError.httpStatus(let code, _) {
            XCTAssertEqual(code, 503)
        }
        XCTAssertTrue(FenceBackend.requests.filter { $0.method == "PATCH" }.isEmpty)
    }

    func testASnapshotThatDoesNotSayWhetherTheSessionExistsDeletesNothing() async throws {
        FenceBackend.mode = .snapshotFails(status: 200, body: #"{"session_id":"s1"}"#)

        do {
            try await rest().deleteSession(sessionID: "s1")
            XCTFail("a delete must not read a missing answer as already gone, nor go out unfenced")
        } catch {}
        XCTAssertTrue(FenceBackend.requests.filter { $0.method == "DELETE" }.isEmpty)
    }

    // MARK: A backend from before the fence

    /// What an unrouted GET answers on 0.21.x through 0.22.0 and on 0.22.2: headless `hermes serve`'s catch-all, the dashboard's, and FastAPI's own (`hermes_cli/web_server_dashboard.py:122-139`, `:227-233` at 0.22.0).
    private static let unroutedBodies = [
        #"{"error":"Headless backend (hermes serve): web UI disabled — use `hermes dashboard` for the browser UI."}"#,
        #"{"detail":"No such API endpoint: /api/sessions/s1/mutation-snapshot"}"#,
        #"{"detail":"Not Found"}"#,
    ]

    func testABackendWithoutTheSnapshotRouteGetsTodaysPatchUnchanged() async throws {
        for body in Self.unroutedBodies {
            FenceBackend.reset()
            FenceBackend.mode = .legacy(snapshotBody: body)

            try await rest().patchSession(sessionID: "s1", pinned: true, profile: "work")

            let writes = FenceBackend.requests.filter { $0.method == "PATCH" }
            XCTAssertEqual(writes.count, 1, body)
            XCTAssertEqual(Set((writes.first?.json ?? [:]).keys), ["pinned", "profile"], "nothing added for a backend that never asked for it: \(body)")
        }
    }

    func testOnlyTheCatchAllsReadAsABackendWithoutTheFence() {
        XCTAssertTrue(RestAPI.isUnroutedPath(HermesError.httpStatus(code: 404, message: "Headless backend (hermes serve): web UI disabled — use `hermes dashboard` for the browser UI.")))
        XCTAssertTrue(RestAPI.isUnroutedPath(HermesError.httpStatus(code: 404, message: "No such API endpoint: /api/sessions/s1/mutation-snapshot")))
        XCTAssertTrue(RestAPI.isUnroutedPath(HermesError.httpStatus(code: 404, message: "Not Found")))
        XCTAssertFalse(RestAPI.isUnroutedPath(HermesError.httpStatus(code: 404, message: "Session not found")))
        XCTAssertFalse(RestAPI.isUnroutedPath(HermesError.httpStatus(code: 404, message: "not_found")))
        XCTAssertFalse(RestAPI.isUnroutedPath(HermesError.httpStatus(code: 503, message: "No such API endpoint: /api/x")))
        XCTAssertFalse(RestAPI.isUnroutedPath(HermesError.connectFailed("refused")))
    }

    func testTheSnapshotDecodesOnlyAnAnswerThatSaysAllOfIt() throws {
        func decode(_ text: String) throws -> SessionMutationSnapshot? {
            SessionMutationSnapshot(json: try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8)))
        }
        XCTAssertEqual(try decode(#"{"session_id":"s","exists":true,"runtime_revision":4,"runtime_generation":2}"#)?.generation, 2)
        XCTAssertEqual(try decode(#"{"session_id":"s","exists":false,"runtime_revision":0,"runtime_generation":null}"#)?.exists, false)
        XCTAssertNil(try decode(#"{"session_id":"s","runtime_revision":0}"#), "no exists")
        XCTAssertNil(try decode(#"{"session_id":"s","exists":"yes","runtime_revision":0,"runtime_generation":0}"#), "exists is not a bool")
        XCTAssertNil(try decode(#"{"session_id":"s","exists":true,"runtime_revision":1.5,"runtime_generation":0}"#), "a revision that is not a whole number")
        XCTAssertNil(try decode(#"{"session_id":"s","exists":true,"runtime_revision":1,"runtime_generation":null}"#), "an existing session always has a generation")
    }

    func testABackendWithoutTheSnapshotRouteGetsTodaysDeleteUnchanged() async throws {
        for body in Self.unroutedBodies {
            FenceBackend.reset()
            FenceBackend.mode = .legacy(snapshotBody: body)

            try await rest().deleteSession(sessionID: "s1", profile: "work")

            let deletes = FenceBackend.requests.filter { $0.method == "DELETE" }
            XCTAssertEqual(deletes.count, 1, body)
            XCTAssertEqual(deletes.first?.query, ["profile": "work"], body)
        }
    }
}

/// Answers the session write routes the way 0.22.5 does (`.fenced`), the way 0.22.0 does (`.legacy`), or with a snapshot read that fails.
private final class FenceBackend: URLProtocol {
    enum Mode {
        case fenced(revision: Int, generation: Int?, exists: Bool = true)
        case legacy(snapshotBody: String)
        case snapshotFails(status: Int, body: String)
    }

    struct Recorded {
        let method: String
        let path: String
        let query: [String: String]
        let rawBody: String
        var json: [String: Any]? {
            guard !rawBody.isEmpty else { return nil }
            return (try? JSONSerialization.jsonObject(with: Data(rawBody.utf8))) as? [String: Any]
        }
    }

    private static let lock = NSLock()
    private static var _mode: Mode = .legacy(snapshotBody: #"{"detail":"Not Found"}"#)
    private static var _requests: [Recorded] = []
    private static var _conflicts = 0
    private static var _refusal: (Int, String)?
    private static var _revision = 0

    static var mode: Mode {
        get { lock.withLock { _mode } }
        set {
            lock.withLock {
                _mode = newValue
                if case .fenced(let revision, _, _) = newValue { _revision = revision }
            }
        }
    }

    static var conflicts: Int {
        get { lock.withLock { _conflicts } }
        set { lock.withLock { _conflicts = newValue } }
    }

    static var refusal: (Int, String)? {
        get { lock.withLock { _refusal } }
        set { lock.withLock { _refusal = newValue } }
    }

    static var requests: [Recorded] { lock.withLock { _requests } }

    static func reset() {
        lock.withLock {
            _mode = .legacy(snapshotBody: #"{"detail":"Not Found"}"#)
            _requests = []
            _conflicts = 0
            _refusal = nil
            _revision = 0
        }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let url = request.url!
        let method = request.httpMethod ?? "GET"
        var query: [String: String] = [:]
        for item in URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? [] {
            query[item.name] = item.value ?? ""
        }
        let raw = String(data: Self.bodyData(of: request), encoding: .utf8) ?? ""
        let recorded = Recorded(method: method, path: url.path, query: query, rawBody: raw)
        Self.lock.withLock { Self._requests.append(recorded) }

        let (status, body) = Self.answer(recorded)
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func answer(_ request: Recorded) -> (Int, String) {
        lock.withLock {
            let isSnapshot = request.method == "GET" && request.path.hasSuffix("/mutation-snapshot")
            switch _mode {
            case .legacy(let snapshotBody):
                if isSnapshot { return (404, snapshotBody) }
                return (200, #"{"ok":true,"title":""}"#)
            case .snapshotFails(let status, let body):
                if isSnapshot { return (status, body) }
                return (200, #"{"ok":true,"title":""}"#)
            case .fenced(_, let generation, let exists):
                if isSnapshot {
                    let gen = generation.map(String.init) ?? "null"
                    return (200, #"{"session_id":"s1","exists":\#(exists),"runtime_revision":\#(_revision),"runtime_generation":\#(gen)}"#)
                }
                // The route's own precondition checks, in its order (`web_server_sessions.py:269-275`, `hermes_state_runtime.py:495-521`).
                let fields: [String: Any]
                if request.method == "DELETE" {
                    var fromQuery: [String: Any] = [:]
                    if let id = request.query["request_id"] { fromQuery["request_id"] = id }
                    if let rev = request.query["expected_revision"].flatMap(Int.init) { fromQuery["expected_revision"] = rev }
                    if let gen = request.query["expected_generation"].flatMap(Int.init) { fromQuery["expected_generation"] = gen }
                    fields = fromQuery
                } else {
                    fields = request.json ?? [:]
                }
                let requestID = fields["request_id"] as? String
                let revision = fields["expected_revision"] as? Int
                if requestID == nil, revision == nil, fields["expected_generation"] == nil {
                    return (409, #"{"detail":"client_upgrade_required: this app is out of sync (different versions) with the Hermes backend; update the app to edit sessions"}"#)
                }
                guard requestID != nil, let revision else { return (409, #"{"detail":"mutation_identity_required"}"#) }
                if request.method == "DELETE", fields["expected_generation"] == nil {
                    return (400, #"{"detail":"invalid_params"}"#)
                }
                if let refusal = _refusal { return (refusal.0, #"{"detail":"\#(refusal.1)"}"#) }
                if _conflicts > 0 {
                    _conflicts -= 1
                    _revision += 1
                    return (409, #"{"detail":"revision_conflict"}"#)
                }
                guard revision == _revision else { return (409, #"{"detail":"revision_conflict"}"#) }
                _revision += 1
                return (200, #"{"ok":true,"title":""}"#)
            }
        }
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
