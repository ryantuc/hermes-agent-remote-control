import Foundation

/// What `prompt.submit` / `session.redirect` / `session.steer` acknowledge; the ack is not turn completion, which is signalled by `message.complete` (PROTOCOL.md "A chat turn").
public struct PromptAck: Sendable, Equatable {
    /// `streaming` | `queued` | `steered` | `redirected` | `rejected`.
    public let status: String
    /// The compute-host path sets this; behaviour is otherwise identical.
    public let turnIsolation: Bool
    /// The text was a bare voice stop phrase and was consumed as such.
    public let voiceStopped: Bool
    public let raw: JSONValue

    public init(json: JSONValue) {
        status = json["status"]?.coercedString ?? ""
        turnIsolation = json["turn_isolation"]?.coercedBool ?? false
        voiceStopped = json["voice_stopped"]?.coercedBool ?? false
        raw = json
    }

    /// The turn started now.
    public var isStreaming: Bool { status == "streaming" }
    /// The session was busy, so the text landed in the single queue slot and runs as the next turn.
    public var isQueued: Bool { status == "queued" }
    /// The live turn was steered in place.
    public var wasSteered: Bool { status == "redirected" || status == "steered" }
}

/// Prompt submission and mid-turn correction.
public struct PromptAPI: Sendable {
    private let client: HermesClient

    public init(client: HermesClient) {
        self.client = client
    }

    /// `prompt.submit {session_id, text}` — never rejected on a busy session, since it queues, steers or redirects per `display.busy_input_mode`, and attachment bytes go out of band with only reference tokens in `text` (jsonrpc-methods §4.8).
    /// Uses the 30-minute timeout, because anything shorter turns a long tool-using turn into a spurious client-side failure.
    public func submit(
        sessionID: String,
        text: String,
        forceQueue: Bool = false
    ) async throws -> PromptAck {
        var params: [String: JSONValue] = [
            "session_id": .string(sessionID),
            "text": .string(text),
        ]
        // `queued: true` overrides the server's busy mode so a client draining its own queue cannot redirect the live turn.
        if forceQueue { params["queued"] = .bool(true) }
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

    /// `session.steer` — inject into the next tool result without interrupting.
    public func steer(sessionID: String, text: String) async throws -> PromptAck {
        let result = try await client.request(
            "session.steer",
            params: .object(["session_id": .string(sessionID), "text": .string(text)])
        )
        return PromptAck(json: result)
    }
}
