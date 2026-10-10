import Foundation

/// JSON-RPC IDs preserve their wire type; the string "7" is not numeric 7.
public enum ServerRequestID: Sendable, Hashable {
    case string(String)
    case number(Double)

    public init?(_ value: JSONValue) {
        switch value {
        case .string(let value): self = .string(value)
        case .number(let value) where value.isFinite: self = .number(value)
        default: return nil
        }
    }
    public var wire: JSONValue {
        switch self {
        case .string(let value): return .string(value)
        case .number(let value): return .number(value)
        }
    }
}

/// A UI decision belongs to this socket and exact request, never a FIFO or a later reconnect.
public struct ServerRequestIdentity: Sendable, Hashable {
    public let generation: Int
    public let sessionID: String
    public let id: ServerRequestID
    public let method: String
}

public struct ServerRequest: Sendable, Equatable, Identifiable {
    public let id: UUID
    public let identity: ServerRequestIdentity
    public let params: JSONValue
    public let receivedAt: Date
    let revision: Int
    let order: Int

    public var requiresDesktop: Bool {
        !["approval", "clarify", "sudo", "secret", "vault.unlock_prompt", "vault.code"].contains(identity.method)
    }

    var approval: ApprovalRequestEvent? {
        guard identity.method == "approval" else { return nil }
        return ApprovalRequestEvent(sessionID: identity.sessionID, payload: params,
                                    id: id, serverRequest: identity, receivedAt: receivedAt)
    }
    var clarify: ClarifyRequestEvent? {
        guard identity.method == "clarify" else { return nil }
        var payload = params.objectValue ?? [:]
        payload["request_id"] = .string(id.uuidString)
        return ClarifyRequestEvent(sessionID: identity.sessionID, payload: .object(payload),
                                   serverRequest: identity, receivedAt: receivedAt, sourceRevision: revision)
    }
    var sudo: SudoRequestEvent? {
        guard identity.method == "sudo" else { return nil }
        return SudoRequestEvent(id: id.uuidString, sessionID: identity.sessionID,
                                receivedAt: receivedAt, serverRequest: identity)
    }
    var secret: SecretRequestEvent? {
        guard !["approval", "clarify", "sudo"].contains(identity.method) else { return nil }
        let prompt: String
        switch identity.method {
        case "secret": prompt = params["prompt"]?.text ?? "Credential needed"
        case "vault.unlock_prompt":
            prompt = "Unlock \(params["display_name"]?.text ?? "your password manager") for this session. The password is sent to your backend and is not stored on this device."
        case "vault.code":
            prompt = "Enter the one-time code for \(params["site"]?.text ?? "this sign-in"). \(params["hint"]?.text ?? "")"
        default:
            prompt = "This request needs a Desktop feature that HARC does not provide. Open this session in Desktop to complete it. You can minimize this card and keep reading here."
        }
        return SecretRequestEvent(id: id.uuidString, sessionID: identity.sessionID, prompt: prompt,
                                  envVar: identity.method == "secret" ? params["env_var"]?.text ?? "" : "",
                                  receivedAt: receivedAt, serverRequest: identity)
    }
}

/// Actor-owned by HermesClient. Snapshots are fenced at RPC dispatch, so a delayed snapshot
/// cannot resurrect a resolved request or remove a request delivered after that RPC began.
struct ServerRequestRegistry {
    private(set) var revision = 0
    private(set) var requests: [ServerRequestIdentity: ServerRequest] = [:]
    private var terminal: Set<ServerRequestIdentity> = []
    private var snapshots: [String: Int] = [:]

    var sessions: Set<String> { Set(requests.keys.map(\.sessionID)) }
    func open(in sessionID: String) -> [ServerRequest] {
        requests.values.filter { $0.identity.sessionID == sessionID }.sorted { $0.order < $1.order }
    }
    mutating func reset() { self = Self() }
    mutating func beginSnapshot() -> Int { revision += 1; return revision }

    @discardableResult
    mutating func receive(id: JSONValue, method: String, params: JSONValue, generation: Int) -> String? {
        guard let id = ServerRequestID(id), let sessionID = params["session_id"]?.stringValue,
              !sessionID.isEmpty else { return nil }
        let key = ServerRequestIdentity(generation: generation, sessionID: sessionID, id: id, method: method)
        guard !terminal.contains(key) else { return nil }
        // Live duplicates must not erase accepted batch locks learned from a snapshot.
        guard requests[key] == nil else { return sessionID }
        revision += 1
        requests[key] = ServerRequest(id: UUID(), identity: key, params: params,
                                     receivedAt: Date(), revision: revision, order: revision)
        return sessionID
    }

    mutating func reconcile(_ entries: [JSONValue], sessionID: String, generation: Int, startedAt: Int) {
        guard startedAt >= (snapshots[sessionID] ?? -1) else { return }
        snapshots[sessionID] = startedAt
        var present: Set<ServerRequestIdentity> = []
        for entry in entries {
            guard let id = entry["id"].flatMap(ServerRequestID.init),
                  let method = entry["method"]?.stringValue,
                  let params = entry["params"], params["session_id"]?.stringValue == sessionID else { continue }
            let key = ServerRequestIdentity(generation: generation, sessionID: sessionID, id: id, method: method)
            present.insert(key)
            guard !terminal.contains(key) else { continue }
            if let existing = requests[key] {
                guard existing.revision <= startedAt else { continue }
                requests[key] = ServerRequest(id: existing.id, identity: key, params: params,
                                             receivedAt: existing.receivedAt,
                                             revision: params == existing.params ? existing.revision : startedAt,
                                             order: existing.order)
            } else {
                _ = receive(id: id.wire, method: method, params: params, generation: generation)
            }
        }
        for request in open(in: sessionID) where request.revision <= startedAt && !present.contains(request.identity) {
            retire(request.identity)
        }
    }

    mutating func retire(_ identity: ServerRequestIdentity) {
        requests[identity] = nil
        terminal.insert(identity)
        revision += 1
    }
    mutating func cancel(id: JSONValue, method: String, sessionID: String, generation: Int) {
        guard let id = ServerRequestID(id) else { return }
        retire(ServerRequestIdentity(generation: generation, sessionID: sessionID, id: id, method: method))
    }
    /// `approval.cancelled`: the backend deny-resolved these queue entries itself, so their
    /// `approval` requests are dead even when no `request.cancel` reached this socket. Matched on the
    /// queue `request_id` the request's params carry; answers the sessions it changed.
    mutating func retireApprovals(requestIDs: Set<String>, sessionID: String, generation: Int) -> Set<String> {
        guard !requestIDs.isEmpty else { return [] }
        let doomed = requests.values.filter {
            $0.identity.method == "approval" && $0.identity.generation == generation
                && (sessionID.isEmpty || $0.identity.sessionID == sessionID)
                && requestIDs.contains($0.params["request_id"]?.stringValue ?? "")
        }.map(\.identity)
        for identity in doomed { retire(identity) }
        return Set(doomed.map(\.sessionID))
    }
    mutating func lock(_ identity: ServerRequestIdentity, questionID: String, answer: String) {
        guard let existing = requests[identity] else { return }
        var params = existing.params.objectValue ?? [:]
        var answers = params["answers"]?.objectValue ?? [:]
        answers[questionID] = .string(answer)
        params["answers"] = .object(answers)
        revision += 1
        requests[identity] = ServerRequest(id: existing.id, identity: identity, params: .object(params),
                                         receivedAt: existing.receivedAt, revision: revision, order: existing.order)
    }
}
