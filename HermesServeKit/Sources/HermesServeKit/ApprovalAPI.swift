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

/// Answering the five blocking-prompt flows, which share no mechanism: `approval.request` is session-keyed FIFO with no `request_id`, while clarify / sudo / secret / terminal-read each carry a `request_id` and a different answer key (reference-clients.md §5).
public struct ApprovalAPI: Sendable {
    private let client: HermesClient

    public init(client: HermesClient) {
        self.client = client
    }

    /// `approval.respond {session_id, choice, all?}` → `{resolved}`, taking the runtime session id.
    /// Tri-state on purpose: `resolved` is 1 when the head was resolved and 0 when there was nothing left, and `nil` means the backend made no claim, which must not be folded into false and reported as a late approval.
    @discardableResult
    public func respond(
        sessionID: String,
        choice: ApprovalChoice,
        all: Bool = false
    ) async throws -> Bool? {
        var params: [String: JSONValue] = [
            "session_id": .string(sessionID),
            "choice": .string(choice.rawValue),
        ]
        if all { params["all"] = .bool(true) }
        let result = try await client.request("approval.respond", params: .object(params))
        return result["resolved"]?.coercedBool
    }

    /// `clarify.respond {request_id, answer, question_id?}`, where a dismissal sends an empty string rather than no response (reference-clients.md §5.3).
    /// `questionID` is the batch form's per-question address, and omitting it on a batch request is not a neutral default but the cancel-all path.
    @discardableResult
    public func respondClarify(
        requestID: String,
        answer: String,
        questionID: String? = nil
    ) async throws -> ClarifyRespondResult {
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
    public func respondSudo(requestID: String, password: String) async throws -> String {
        try await respondBlocking(method: "sudo.respond", requestID: requestID, key: "password", value: password)
    }

    /// `secret.respond {request_id, value}`, where an empty value is treated as skipped.
    @discardableResult
    public func respondSecret(requestID: String, value: String) async throws -> String {
        try await respondBlocking(method: "secret.respond", requestID: requestID, key: "value", value: value)
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

    public init(status: String, remaining: [String]?) {
        self.status = status
        self.remaining = remaining
    }
}
