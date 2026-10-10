import Foundation

/// What `prompt.submit` / `session.redirect` / `session.steer` acknowledge; the ack is not turn completion, which is signalled by `message.complete` (PROTOCOL.md "A chat turn").
public struct PromptAck: Sendable, Equatable {
    /// `streaming` | `queued` | `steered` | `redirected` | `rejected`.
    public let status: String
    /// The compute-host path sets this; behaviour is otherwise identical.
    public let turnIsolation: Bool
    /// The text was a bare voice stop phrase and was consumed as such.
    public let voiceStopped: Bool
    /// The durable row written for THIS accepted input (`PromptSubmitResult.user_row_id`, `tui_gateway/contracts/prompt_voice.py:64-75`). Absent on queued, steered and redirected inputs, whenever persistence is not yet proven, and on an older backend, which predates the key.
    public let userRowID: Int?
    public let raw: JSONValue

    public init(json: JSONValue) {
        status = json["status"]?.coercedString ?? ""
        turnIsolation = json["turn_isolation"]?.coercedBool ?? false
        voiceStopped = json["voice_stopped"]?.coercedBool ?? false
        userRowID = json["user_row_id"]?.coercedInt
        raw = json
    }

    /// The turn started now.
    public var isStreaming: Bool { status == "streaming" }
    /// The session was busy, so the text landed in the single queue slot and runs as the next turn.
    public var isQueued: Bool { status == "queued" }
    /// The live turn was steered in place.
    public var wasSteered: Bool { status == "redirected" || status == "steered" }
    public var effectiveStatus: String {
        let disposition = raw["submission"]?["disposition"]?.coercedString
        return disposition == "steered" || disposition == "redirected" ? disposition! : status
    }
}

/// Prompt submission and mid-turn correction.
public struct PromptAPI: Sendable {
    private let client: HermesClient

    public init(client: HermesClient) {
        self.client = client
    }

    /// `prompt.submit {session_id, text}` — never rejected on a busy session, since it queues, steers or redirects per `display.busy_input_mode`, and attachment bytes go out of band with only reference tokens in `text` (jsonrpc-methods §4.8).
    /// Uses the 30-minute timeout, because anything shorter turns a long tool-using turn into a spurious client-side failure.
    ///
    /// `replacingRowID` makes this submit a Retry or Edit & resend: the backend drops the user turn written to that durable row and everything after it, then runs `text` in its place (`truncate_before_row_id` + `confirm_truncate`, `tui_gateway/contracts/prompt_voice.py:27-55`, declared on current and older backends). Consent travels only with a target, never on an ordinary send, because an unconfirmed cut answers 4029 and a leftover one destroyed history upstream (#80763, `tui_gateway/methods_prompt.py:244-276`). `confirm_empty_truncate` rides along as Desktop sends it with every durable-row rewind (`apps/desktop/src/app/session/hooks/use-prompt-actions/rewind.ts:338-360`): replacing the first turn leaves an empty prefix, which the backend otherwise refuses with 4028, and it is ignored when the prefix is not empty (`methods_prompt.py:369-378`). No ordinal is sent: the phone's ordinals are tail-relative, and a mismatch beside a durable row answers 4030. A busy session refuses the cut with 4009 (`methods_prompt.py:676-677`).
    public func submit(
        sessionID: String,
        text: String,
        forceQueue: Bool = false,
        submissionRef: String? = nil,
        replacingRowID: Int? = nil
    ) async throws -> PromptAck {
        var params: [String: JSONValue] = [
            "session_id": .string(sessionID),
            "text": .string(text),
        ]
        // `queued: true` overrides the server's busy mode so a client draining its own queue cannot redirect the live turn.
        if forceQueue { params["queued"] = .bool(true) }
        if let submissionRef { params["submission_ref"] = .string(submissionRef) }
        if let replacingRowID {
            params["truncate_before_row_id"] = .number(Double(replacingRowID))
            params["confirm_truncate"] = .bool(true)
            params["confirm_empty_truncate"] = .bool(true)
        }
        let result = try await client.request(
            "prompt.submit",
            params: .object(params),
            timeout: HermesClient.promptSubmitTimeout
        )
        return PromptAck(json: result)
    }

    /// `session.redirect` — steer the live model turn in place, where `status: "queued"` means it landed in the build window and runs as the next turn instead (reference-clients.md §3.5).
    public func redirect(sessionID: String, text: String) async throws -> PromptAck {
        let result = try await client.request(
            "session.redirect",
            params: .object(["session_id": .string(sessionID), "text": .string(text)])
        )
        return PromptAck(json: result)
    }

    /// `prompt.btw {session_id, text}` — a side question answered from a snapshot of the conversation without steering or interrupting the running turn; the answer arrives later as `btw.complete` carrying the returned task id.
    /// Contract: `SideAgentParams` (`session_id`, `text`) and `TaskIdResult` (`tui_gateway/contracts/prompt_voice.py:225-239`, `:222-223` on an older backend); handler `tui_gateway/methods_prompt.py:965-984`, which answers 4012 for an empty question.
    public func btw(sessionID: String, question: String) async throws -> String {
        let result = try await client.request(
            "prompt.btw",
            params: .object(["session_id": .string(sessionID), "text": .string(question)])
        )
        return result["task_id"]?.coercedString ?? ""
    }

    /// `session.steer` — inject into the next tool result without interrupting.
    public func steer(sessionID: String, text: String) async throws -> PromptAck {
        let result = try await client.request(
            "session.steer",
            params: .object(["session_id": .string(sessionID), "text": .string(text)])
        )
        return PromptAck(json: result)
    }
}
