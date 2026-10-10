import Foundation

/// What `connection.respond` answered (`ConnectionRespondResult`, `tui_gateway/contracts/connectors_operation.py:232-234`).
public struct ConnectionRespondResult: Sendable, Equatable {
    /// The operation settled with this answer; the agent's tool returns and the turn moves on.
    public let settled: Bool

    public init(json: JSONValue) {
        settled = json["settled"]?.coercedBool ?? false
    }
}

/// The card's answers to an open connection operation. The phone offers Skip and Continue on every row and Open on a row with a sign-in link; it never approves an install, which runs code on the host.
///
/// Params: `ConnectionOperationParams` = `owner` + `op_id` (+ inherited `profile`), `connectors_operation.py:186-188`; `ConnectionRespondParams` adds `result` (`:228-229`); `owner` is `{type: "session", session_id}` (`contracts/common.py:240-249`). An older backend declares `session_id` where current upstream declares `owner`, and answers `owner` with 4000 at dispatch (`tui_gateway/rpc_dispatch.py:27-31`), before any handler runs, so nothing moved and the same answer is sent once more in that backend's shape — the pattern `SessionAPI.create` uses for `cwd_explicit`.
public struct ConnectorsAPI: Sendable {
    private let client: HermesClient

    public init(client: HermesClient) {
        self.client = client
    }

    /// Not now on these rows (`ConnectionAnswerTarget.status = "skipped"`, `connectors_operation.py:203-217`).
    public func skip(sessionID: String, opID: String, targets: [String]) async throws -> ConnectionRespondResult {
        let rows: [JSONValue] = targets.map { .object(["name": .string($0), "status": .string("skipped")]) }
        return try await respond(sessionID: sessionID, opID: opID, result: .object(["targets": .array(rows)]))
    }

    /// End the operation now with whatever is unresolved (`settled_by: "continue"`, `connectors_operation.py:220-225`).
    public func continueOperation(sessionID: String, opID: String) async throws -> ConnectionRespondResult {
        try await respond(sessionID: sessionID, opID: opID, result: .object(["settled_by": .string("continue")]))
    }

    /// The browser leg came back: ask the backend to read the account now instead of at its next tick (`connectors.operation.wake`, `connectors_operation.py:195-200`; handler `tui_gateway/methods_connectors.py:333-343`). Best effort, as Desktop's is (`apps/desktop/src/components/assistant-ui/connector-tool.tsx:82-97`): an older backend has no such method, and an operation that already settled answers 4004. Answers whether the backend took it.
    @discardableResult
    public func wake(sessionID: String, opID: String) async -> Bool {
        let params: JSONValue = .object(["owner": Self.owner(sessionID), "op_id": .string(opID)])
        return (try? await client.request("connectors.operation.wake", params: params)) != nil
    }

    private func respond(sessionID: String, opID: String, result: JSONValue) async throws -> ConnectionRespondResult {
        var params: [String: JSONValue] = ["owner": Self.owner(sessionID), "op_id": .string(opID), "result": result]
        let reply: JSONValue
        do {
            reply = try await client.request("connection.respond", params: .object(params))
        } catch let error as HermesError where Self.rejectsOwner(error) {
            params.removeValue(forKey: "owner")
            params["session_id"] = .string(sessionID)
            reply = try await client.request("connection.respond", params: .object(params))
        }
        return ConnectionRespondResult(json: reply)
    }

    private static func owner(_ sessionID: String) -> JSONValue {
        .object(["type": .string("session"), "session_id": .string(sessionID)])
    }

    /// An older backend's text for the key it does not declare: `invalid params for connection.respond: owner: Extra inputs are not permitted — …` (`contracts/registry.py:100-115` on an older backend). A backend that declares `owner` never names it in a 4000, and any other refusal reaches the caller.
    static func rejectsOwner(_ error: HermesError) -> Bool {
        guard case .rpc(let code, let message, _) = error, code == 4000 else { return false }
        return message.contains("connection.respond: owner")
    }
}
