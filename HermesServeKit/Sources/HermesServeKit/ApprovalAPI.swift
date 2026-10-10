import Foundation

/// The canonical gateway approval choices; there is no separate "always allow" method, since "always" is just `choice: "always"` (reference-clients.md §5.2).
public enum ApprovalChoice: String, Sendable, CaseIterable, Identifiable {
    case once
    case session
    case always
    case deny

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .once: return "Allow once"
        case .session: return "Allow for this session"
        case .always: return "Always allow"
        case .deny: return "Deny"
        }
    }

    public var subtitle: String {
        switch self {
        case .once: return "Run this one command."
        case .session: return "Stop asking until this conversation ends."
        case .always: return "Write the pattern to the backend's permanent allowlist."
        case .deny: return "Refuse and tell the agent."
        }
    }

    /// "always" writes a pattern key into the backend's `config.yaml` allowlist, which is a durable change to the user's machine and so deserves a confirmation step.
    public var isDestructiveToDefaults: Bool { self == .always }
}

/// Explicit adapters for current JSON-RPC server requests and legacy blocking-prompt RPCs.
/// Legacy approval emitters may provide a queue ID; only truly ID-less emitters use FIFO.
public struct ApprovalAPI: Sendable {
    private let client: HermesClient

    public init(client: HermesClient) {
        self.client = client
    }

    /// Legacy `approval.respond {session_id, choice, all?, request_id?}` → `{resolved}`;
    /// identified current requests instead receive a JSON-RPC result with their exact ID.
    /// Tri-state on purpose: `resolved` is 1 when the head was resolved and 0 when there was nothing left, and `nil` means the backend made no claim, which must not be folded into false and reported as a late approval.
    @discardableResult
    public func respond(
        sessionID: String,
        choice: ApprovalChoice,
        all: Bool = false,
        serverRequest: ServerRequestIdentity? = nil,
        legacyRequestID: String? = nil
    ) async throws -> Bool? {
        if let serverRequest {
            var result: [String: JSONValue] = ["choice": .string(choice.rawValue)]
            if all { result["all"] = .bool(true) }
            try await client.respond(to: serverRequest, result: .object(result))
            return nil // A response frame is sent without an acceptance acknowledgement.
        }
        var params: [String: JSONValue] = [
            "session_id": .string(sessionID),
            "choice": .string(choice.rawValue),
        ]
        if all { params["all"] = .bool(true) }
        if let legacyRequestID, !legacyRequestID.isEmpty { params["request_id"] = .string(legacyRequestID) }
        let result = try await client.request("approval.respond", params: .object(params))
        return result["resolved"]?.coercedBool
    }

    /// `clarify.respond {request_id, answer, question_id?}`, where a dismissal sends an empty string rather than no response (reference-clients.md §5.3).
    /// `questionID` is the batch form's per-question address, and omitting it on a batch request is not a neutral default but the cancel-all path.
    @discardableResult
    public func respondClarify(
        requestID: String,
        answer: String,
        questionID: String? = nil,
        serverRequest: ServerRequestIdentity? = nil,
        isBatch: Bool = false
    ) async throws -> ClarifyRespondResult {
        if let serverRequest {
            if let questionID, !questionID.isEmpty {
                return try await client.lockClarify(serverRequest, questionID: questionID, answer: answer)
            }
            try await client.respond(to: serverRequest, result: .object(isBatch ? [:] : ["answer": .string(answer)]))
            return ClarifyRespondResult(status: "sent", remaining: nil)
        }
        var extra: [String: JSONValue] = [:]
        // An empty string is read as absent, which is the cancel-all path, so only a real qid goes on the wire.
        if let questionID, !questionID.isEmpty {
            extra["question_id"] = .string(questionID)
        }
        let result = try await respondRaw(
            method: "clarify.respond",
            requestID: requestID,
            key: "answer",
            value: answer,
            extra: extra
        )
        return ClarifyRespondResult(
            status: result["status"]?.coercedString ?? "ok",
            remaining: result["remaining"]?.arrayValue.map { $0.compactMap(\.coercedString) }
        )
    }

    /// `sudo.respond {request_id, password}`. 120 s server timeout.
    @discardableResult
    public func respondSudo(requestID: String, password: String, serverRequest: ServerRequestIdentity? = nil) async throws -> String {
        if let serverRequest {
            try await client.respond(to: serverRequest, result: .object(["value": .string(password)]))
            return "sent"
        }
        return try await respondBlocking(method: "sudo.respond", requestID: requestID, key: "password", value: password)
    }

    /// `secret.respond {request_id, value}`, where an empty value is treated as skipped.
    @discardableResult
    public func respondSecret(requestID: String, value: String, serverRequest: ServerRequestIdentity? = nil) async throws -> String {
        if let serverRequest {
            let valueMethods = ["secret", "vault.unlock_prompt", "vault.code", "vault.save_login",
                                "terminal.read", "preview.read", "preview.act", "window.read", "tour"]
            if valueMethods.contains(serverRequest.method) {
                try await client.respond(to: serverRequest, result: .object(["value": .string(value)]))
            } else {
                try await client.declineUnsupportedRequest(serverRequest)
            }
            return "sent"
        }
        return try await respondBlocking(method: "secret.respond", requestID: requestID, key: "value", value: value)
    }

    /// `terminal.read.respond {request_id, text}`: a phone has no terminal pane, so this client answers with an empty string promptly rather than letting the 30 s timeout stall a tool.
    @discardableResult
    public func respondTerminalRead(requestID: String, text: String = "") async throws -> String {
        try await respondBlocking(method: "terminal.read.respond", requestID: requestID, key: "text", value: text)
    }

    private func respondBlocking(
        method: String,
        requestID: String,
        key: String,
        value: String
    ) async throws -> String {
        let result = try await respondRaw(
            method: method, requestID: requestID, key: key, value: value, extra: [:]
        )
        // All four responders are `allow_expired=True`, so a late answer returns `{"status": "expired"}` rather than erroring.
        return result["status"]?.coercedString ?? "ok"
    }

    private func respondRaw(
        method: String,
        requestID: String,
        key: String,
        value: String,
        extra: [String: JSONValue]
    ) async throws -> JSONValue {
        var object: [String: JSONValue] = [
            "request_id": .string(requestID),
            key: .string(value),
        ]
        for (name, entry) in extra { object[name] = entry }
        do {
            return try await client.request(method, params: .object(object))
        } catch let error as HermesError where error.isMissingPendingPrompt {
            // 4009 on an already-resolved prompt is benign: a backend without allow_expired, or a race with the timeout.
            return .object(["status": .string("expired")])
        }
    }
}

/// What one `clarify.respond` came back with.
public struct ClarifyRespondResult: Sendable, Equatable {
    /// `"ok"` on a lock the backend accepted, `"expired"` on a late reply it had already given up on.
    public let status: String
    /// Batch clarify only: the qids still unanswered after this lock, where empty means the turn has resumed and `nil` is no claim at all and must never be read as "nothing is left".
    public let remaining: [String]?

    /// Client-local revision committed when this lock was acknowledged, independent of UI projection delivery.
    public let sourceRevision: Int?

    public init(status: String, remaining: [String]?, sourceRevision: Int? = nil) {
        self.status = status
        self.remaining = remaining
        self.sourceRevision = sourceRevision
    }
}
