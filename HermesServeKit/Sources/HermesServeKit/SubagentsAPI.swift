import Foundation

/// One live child as `subagent.list` reports it (`SubagentSnapshot`, `tui_gateway/contracts/profiles_vault_complete_foreign_subagents.py:603-616`).
public struct SubagentSnapshot: Sendable, Equatable {
    public let subagentID: String
    public let parentID: String
    public let depth: Int?
    public let goal: String
    public let delegationID: String
    public let model: String
    /// The backend's spawn time, epoch seconds on the wire.
    public let startedAt: Date?
    /// The `SubagentStatus` value as sent (`contracts/common.py:182-198`); `""` when absent.
    public let status: String
    public let toolCount: Int?
    /// The last tool the child called, which is not the same as a tool running now.
    public let lastTool: String
    public let acceptingSteer: Bool?

    /// Nil without a `subagent_id`, the one field the contract requires.
    public init?(json: JSONValue) {
        guard json.objectValue != nil, let id = json["subagent_id"]?.coercedString, !id.isEmpty else { return nil }
        subagentID = id
        parentID = json["parent_id"]?.coercedString ?? ""
        depth = json["depth"]?.coercedInt
        goal = json["goal"]?.text ?? ""
        delegationID = json["delegation_id"]?.coercedString ?? ""
        model = json["model"]?.coercedString ?? ""
        startedAt = json["started_at"]?.coercedDouble.flatMap { $0 > 0 ? Date(timeIntervalSince1970: $0) : nil }
        status = (json["status"]?.coercedString ?? "").lowercased()
        toolCount = json["tool_count"]?.coercedInt
        lastTool = json["last_tool"]?.coercedString ?? ""
        acceptingSteer = json["accepting_steer"]?.coercedBool
    }

    /// `queued` children are registered before they run, so they have not started.
    public var hasStarted: Bool { status != "queued" }

    /// The row state for a status the backend calls terminal, nil while the child is still working.
    public var terminalState: SubagentRow.State? {
        switch status {
        case "completed": return .completed
        case "interrupted": return .interrupted
        case "failed", "error", "timeout": return .failed
        default: return nil
        }
    }
}

/// One failed task of an async delegation, read from the backend's durable store (`FailedDelegation`, `profiles_vault_complete_foreign_subagents.py:619-628`; `tools/async_delegation.py:578-618`, a 24-hour window).
public struct FailedDelegation: Sendable, Equatable {
    public let delegationID: String
    public let taskIndex: Int
    public let status: String
    public let goal: String
    public let error: String
    public let dispatchedAt: Date?
    public let completedAt: Date?

    public init?(json: JSONValue) {
        guard json.objectValue != nil, let id = json["delegation_id"]?.coercedString, !id.isEmpty else { return nil }
        delegationID = id
        taskIndex = json["task_index"]?.coercedInt ?? 0
        status = (json["status"]?.coercedString ?? "").lowercased()
        goal = json["goal"]?.text ?? ""
        error = json["error"]?.text ?? ""
        dispatchedAt = json["dispatched_at"]?.coercedDouble.flatMap { $0 > 0 ? Date(timeIntervalSince1970: $0) : nil }
        completedAt = json["completed_at"]?.coercedDouble.flatMap { $0 > 0 ? Date(timeIntervalSince1970: $0) : nil }
    }

    /// The row id this task is drawn under; Desktop uses the same shape (`apps/desktop/src/store/subagents.ts:244`).
    public var rowID: String { "delegation:\(delegationID):\(taskIndex)" }
}

/// What `subagent.list` answered: the live children this session owns, plus recently failed async tasks the live roster has already forgotten (`SubagentListResult`, `:631-639`; handler `tui_gateway/methods_subagents.py:53-63`).
public struct SubagentRoster: Sendable, Equatable {
    public let subagents: [SubagentSnapshot]
    public let delegations: [FailedDelegation]

    public init(subagents: [SubagentSnapshot] = [], delegations: [FailedDelegation] = []) {
        self.subagents = subagents
        self.delegations = delegations
    }

    /// Nil unless `subagents` is a list, the backend's own shape: a reply without one is no answer, never an empty roster.
    public init?(json: JSONValue) {
        guard let rows = json["subagents"]?.arrayValue else { return nil }
        subagents = rows.compactMap(SubagentSnapshot.init(json:))
        delegations = (json["delegations"]?.arrayValue ?? []).compactMap(FailedDelegation.init(json:))
    }
}

/// The end of one child's live transcript (`SubagentTailResult`, `:655-665`; handler `methods_subagents.py:105-128`).
public struct SubagentTail: Sendable, Equatable {
    /// The backend reads at most this many bytes from the end of the file.
    public static let byteLimit = 16_384

    public let subagentID: String
    /// False while the child has no transcript yet, after it was cleaned up, or when this connection does not own it.
    public let available: Bool
    public let text: String
    /// The transcript is longer than what was sent.
    public let truncated: Bool

    public init(json: JSONValue, requested: String) {
        let echoed = json["subagent_id"]?.coercedString ?? ""
        subagentID = echoed.isEmpty ? requested : echoed
        let body = json["text"]?.stringValue ?? ""
        text = body.utf8.count > Self.byteLimit ? String(decoding: Array(body.utf8.suffix(Self.byteLimit)), as: UTF8.self) : body
        available = json["available"]?.coercedBool ?? false
        truncated = json["truncated"]?.coercedBool ?? false
    }
}

/// What `subagent.steer` answered (`SubagentSteerResult`, `tui_gateway/contracts/billing_delegation_pets.py:405-419`; handler `tui_gateway/methods_session.py:2348-2363`).
public struct SubagentSteerReceipt: Sendable, Equatable {
    /// `queued` or `rejected`. Queued is not delivered: a child past its last tool call never reads it.
    public let status: String
    public let subagentID: String
    public let text: String

    public init(json: JSONValue, requested: String, text sent: String) {
        status = (json["status"]?.coercedString ?? "").lowercased()
        let echoed = json["subagent_id"]?.coercedString ?? ""
        subagentID = echoed.isEmpty ? requested : echoed
        text = json["text"]?.coercedString ?? sent
    }

    public var isQueued: Bool { status == "queued" }
}

/// The per-session subagent roster reads and the steer control. Every call carries exactly the declared params (`SessionParams` + `subagent_id` + `text`); the gateway answers an undeclared key with 4000. Stopping one child stays on `SessionAPI.interruptSubagent`.
public struct SubagentsAPI: Sendable {
    private let client: HermesClient

    public init(client: HermesClient) {
        self.client = client
    }

    /// `subagent.list`; nil when the reply is not a roster.
    public func list(sessionID: String) async throws -> SubagentRoster? {
        let result = try await client.request("subagent.list", params: .object(["session_id": .string(sessionID)]))
        return SubagentRoster(json: result)
    }

    /// `subagent.tail`: the last 16 KB of one owned child's transcript.
    public func tail(sessionID: String, subagentID: String) async throws -> SubagentTail {
        let result = try await client.request("subagent.tail", params: .object([
            "session_id": .string(sessionID), "subagent_id": .string(subagentID),
        ]))
        return SubagentTail(json: result, requested: subagentID)
    }

    /// `subagent.steer`: queue a message into one running child; the text is trimmed first, because the gateway refuses a blank one with 4002.
    public func steer(sessionID: String, subagentID: String, text: String) async throws -> SubagentSteerReceipt {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let result = try await client.request("subagent.steer", params: .object([
            "session_id": .string(sessionID), "subagent_id": .string(subagentID), "text": .string(trimmed),
        ]))
        return SubagentSteerReceipt(json: result, requested: subagentID, text: trimmed)
    }

    /// A backend without the method (-32601) or one that refuses the params (4000) will answer the same way every time on this connection.
    public static func isUnsupported(_ error: Error) -> Bool {
        guard let hermes = error as? HermesError, case .rpc(let code, _, _) = hermes else { return false }
        return code == -32601 || code == 4000
    }
}
