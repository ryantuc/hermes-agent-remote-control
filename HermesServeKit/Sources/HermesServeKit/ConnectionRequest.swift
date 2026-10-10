import Foundation

/// One row of a connection operation's card: an app, MCP server, plugin or skill the agent asked to connect.
///
/// Shape: `ConnectionOperationTarget` (`tui_gateway/contracts/connectors_operation.py:104-137`); an older backend sends a subset of the same keys. Every frame carries the full snapshot and the card never derives a state of its own.
public struct ConnectionTarget: Sendable, Equatable, Identifiable {
    public var id: String { name }
    public let name: String
    /// `connector` | `mcp` | `plugin` | `skill`; open, so an unknown kind still renders as a row.
    public let kind: String
    /// `authorize` | `connect` | `enable` | `install` | `reconnect`.
    public let action: String
    /// `pending` | `initiated` | `connected` | `skipped` | `failed` | `expired` | `not_connected` (`ConnectionTargetState`, `:37-46`).
    public let state: String
    public let detail: String
    public let instructions: String
    /// The sign-in link the backend minted, offered only when it is HTTPS with no embedded credentials (Desktop's rule, `apps/desktop/src/lib/connector-tools.ts:180-195`).
    public let connectURL: URL?
    /// A catalog row's display name; empty on connector and MCP rows.
    public let display: String

    public init(json: JSONValue) {
        name = json["name"]?.coercedString ?? ""
        kind = json["kind"]?.coercedString ?? ""
        action = json["action"]?.coercedString ?? ""
        state = json["state"]?.coercedString ?? "pending"
        detail = json["detail"]?.text ?? ""
        instructions = json["instructions"]?.text ?? ""
        display = json["display"]?.text ?? ""
        connectURL = Self.safeLink(json["connect_url"]?.coercedString)
    }

    /// The name a person reads: the catalog's display name when there is one.
    public var title: String { display.isEmpty ? name : display }

    /// Connected or skipped: nothing left for the person to do on this row.
    public var isResolved: Bool { state == "connected" || state == "skipped" }

    /// The states a user may move to `skipped` (`tools/connectors/contract.py:45-54`); `not_connected` has no edge, and a skip there answers 4002.
    public var canSkip: Bool { ["pending", "initiated", "failed", "expired"].contains(state) }

    /// Desktop offers Connect on `pending` and `initiated` rows that carry a link (`apps/desktop/src/components/assistant-ui/connector-tool.tsx:191-199`, `:338-345`).
    public var canOpen: Bool { connectURL != nil && (state == "pending" || state == "initiated") }

    static func safeLink(_ raw: String?) -> URL? {
        guard let raw, let url = URL(string: raw), url.scheme?.lowercased() == "https",
              url.host?.isEmpty == false, url.user == nil, url.password == nil else { return nil }
        return url
    }
}

/// The `manage_connections` card for one session: opened by `connection.request`, moved by `connection.update`, restored from a resume's `pending_connection`.
///
/// The backend emits `connection.request` as a session-scoped EVENT (`tui_gateway/agent_callbacks.py:176`), not as a server→client JSON-RPC request, so there is no request id to answer; the card answers through the `connection.respond` method by `op_id` (`ConnectorsAPI`). The agent's tool blocks until the operation settles or its deadline passes (300 s, `tools/connectors/operation.py:14`), so a client that draws nothing leaves the turn hanging on "Working".
public struct ConnectionRequest: Sendable, Equatable, Identifiable {
    public var id: String { opID }
    /// The runtime session the operation belongs to.
    public let sessionID: String
    public let opID: String
    /// Monotonic per-operation write counter (`connectors_operation.py:145-147`); nil on an older backend, which predates it, where every frame is taken as newer.
    public let seq: Int?
    /// When the backend gives up and settles the operation as `deadline`.
    public let deadlineAt: Date?
    public let targets: [ConnectionTarget]
    /// Only `connection.update` carries this; a `connection.request` is open by definition.
    public let settled: Bool
    /// `all_resolved` | `continue` | `deadline` | `interrupt`, once settled.
    public let settledBy: String
    /// The model's tool call that opened the operation.
    public let toolCallID: String

    /// Nil for a payload with no `op_id`, which no card can answer.
    public init?(sessionID: String, payload: JSONValue?) {
        guard let payload, payload.objectValue != nil,
              let opID = payload["op_id"]?.coercedString, !opID.isEmpty else { return nil }
        self.sessionID = sessionID
        self.opID = opID
        seq = payload["seq"]?.coercedInt
        deadlineAt = payload["deadline_at"]?.coercedEpochDate
        targets = (payload["targets"]?.arrayValue ?? []).map(ConnectionTarget.init(json:)).filter { !$0.name.isEmpty }
        settled = payload["settled"]?.coercedBool ?? false
        settledBy = payload["settled_by"]?.coercedString ?? ""
        toolCallID = payload["tool_call_id"]?.coercedString ?? ""
    }

    /// Rows still waiting on the person; Continue is offered while any remain.
    public var unresolvedTargets: [ConnectionTarget] { targets.filter { !$0.isResolved } }

    /// Whether `frame` may replace this snapshot: same operation, and not older by `seq` when both carry one.
    public func isSupersededBy(_ frame: ConnectionRequest) -> Bool {
        guard frame.opID == opID else { return true }
        guard let mine = seq, let theirs = frame.seq else { return true }
        return theirs > mine
    }
}

/// `connection.update`: a session operation's transition or settlement with the full snapshot (`ConnectionUpdatePayload`, `connectors_operation.py:171-182`).
///
/// An ACCOUNT operation (Settings → Connectors on Desktop) is broadcast to every client with `owner.type == "account"` and an empty envelope session (`tui_gateway/methods_connectors.py:403-412`); it belongs to no chat and projects to nil.
public struct ConnectionUpdateEvent: Sendable, Equatable {
    public let snapshot: ConnectionRequest

    public init?(sessionID: String, payload: JSONValue?) {
        let owner = payload?["owner"]
        if owner?["type"]?.coercedString == "account" { return nil }
        // The owner names the session when the envelope does not; an older backend sends no owner at all.
        let named = owner?["session_id"]?.coercedString ?? ""
        let session = sessionID.isEmpty ? named : sessionID
        guard !session.isEmpty, let snapshot = ConnectionRequest(sessionID: session, payload: payload) else { return nil }
        self.snapshot = snapshot
    }
}
