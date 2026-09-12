import Foundation

// MARK: - Payload projections

/// Which layer of the stack failed a turn, from the backend's own classification (FEAT-016).
///
/// Advisory, and absence is normal: the backend's builders swallow their own errors, so any turn
/// may fail without one. Nothing may gate the rendering of an error on this being present.
public struct ErrorSurface: Sendable, Equatable {
    /// `provider` | `streaming` | `auth` | `gateway` | `runtime` | … — open-ended, and an
    /// unrecognised layer is rendered as a plain error, never dropped.
    public let layer: String
    /// A short machine token (`agent_init_failed`, …). Not shown to a user.
    public let code: String
    /// Nil is not `false`: it means the backend did not say, and the retry affordance stands.
    public let retryable: Bool?

    public init(layer: String, code: String, retryable: Bool?) {
        self.layer = layer
        self.code = code
        self.retryable = retryable
    }

    /// Nil unless the payload carries a descriptor with something in it.
    public init?(json: JSONValue?) {
        guard let json, case .object = json else { return nil }
        let layer = json["layer"]?.coercedString?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let code = json["code"]?.coercedString?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let retryable = json["retryable"]?.coercedBool
        guard !layer.isEmpty || !code.isEmpty || retryable != nil else { return nil }
        self.layer = layer
        self.code = code
        self.retryable = retryable
    }

    /// The layers this client has words for; anything else falls through to the generic wording.
    private static let knownLayers: [String: String] = [
        "provider": "The model provider rejected the request.",
        "streaming": "The reply stopped mid-stream.",
        "auth": "The backend could not authenticate with the provider.",
        "gateway": "The Hermes gateway failed before the model ran.",
        "runtime": "Hermes failed to start the agent.",
        "tool": "A tool failed and the turn could not continue.",
        "config": "The backend's configuration would not load.",
    ]

    /// One sentence naming the layer; nil is normal, and the caller renders the error it had.
    public var layerNote: String? {
        Self.knownLayers[layer.lowercased()]
    }

    /// True only when the backend affirmatively said so; silence is not a yes.
    public var isRetryable: Bool { retryable == true }
    /// True only when the backend affirmatively said it is not.
    public var isNotRetryable: Bool { retryable == false }
}

public struct GatewayReadyEvent: Sendable, Equatable {
    /// Backend-pushed skin name.
    public let skinName: String
    /// The raw `resolve_skin()` dict; the client maps four seeds per polarity and ignores the rest.
    public let skin: JSONValue
    /// The backend broadcasts `sessions.changed` &co, so polling can be demoted (jsonrpc-methods §6.2).
    public let changeEvents: Bool
    /// The backend mirrors a session's events to every connected client and accepts `watch` on
    /// `session.resume`; absent reads as false.
    public let sessionMirroring: Bool
    /// This connection's transport id; comparing it to a frame's `origin` is how a foreign turn is
    /// recognised. Empty when not advertised.
    public let origin: String
}

public struct TextDeltaEvent: Sendable, Equatable {
    public let sessionID: String
    public let text: String
}

public struct MessageInterimEvent: Sendable, Equatable {
    public let sessionID: String
    public let text: String
    public let alreadyStreamed: Bool
}

/// The terminal frame of a turn; a failed turn ends here with `status: "error"` and there is no
/// separate error event (jsonrpc-methods §2.2).
public struct MessageCompleteEvent: Sendable, Equatable {
    public let sessionID: String
    public let text: String
    /// Server-rendered ANSI markdown; this client renders natively and uses it only as a fallback.
    public let rendered: String
    /// `complete` | `interrupted` | `error`.
    public let status: String
    public let error: String
    /// `true` means `text` is streamed output worth keeping, not the error string (reference §3.6).
    public let partial: Bool
    public let recoverable: Bool
    public let warning: String
    public let usage: JSONValue
    /// Which layer failed (FEAT-016); advisory, and nil on any turn, including failed ones.
    public let errorSurface: ErrorSurface?

    public var isError: Bool { status == "error" }
    public var isInterrupted: Bool { status == "interrupted" }

    /// The text to display, with the desktop's fallback order.
    public var displayText: String { text.isEmpty ? rendered : text }
}

public struct ToolStartEvent: Sendable, Equatable {
    public let sessionID: String
    /// `tool_id`, falling back to `tool_call_id` / `id`; empty when the stream started without one.
    public let toolID: String
    public let name: String
    /// Argument preview, capped at 80 chars server-side.
    public let context: String
    /// Only sent in `verbose` tool-progress mode; already redacted and capped server-side.
    public let argsText: String
}

public struct ToolCompleteEvent: Sendable, Equatable {
    public let sessionID: String
    public let toolID: String
    public let name: String
    public let resultText: String
    public let summary: String
    public let error: String
    public let durationSeconds: Double?
    public let inlineDiff: String
    /// The agent's plan, typed; `tool.complete` is the sole authority, because `tool.start`'s
    /// `args.todos` may be a partial merge and `tool.progress` never carries todos. `nil` means no
    /// typed data, while an empty non-nil list means the agent cleared its plan.
    public let todos: TodoList?
    public var isError: Bool { !error.isEmpty }

    public init(
        sessionID: String,
        toolID: String,
        name: String,
        resultText: String,
        summary: String,
        error: String,
        durationSeconds: Double?,
        inlineDiff: String,
        todos: TodoList? = nil
    ) {
        self.sessionID = sessionID
        self.toolID = toolID
        self.name = name
        self.resultText = resultText
        self.summary = summary
        self.error = error
        self.durationSeconds = durationSeconds
        self.inlineDiff = inlineDiff
        self.todos = todos
    }
}

/// `approval.request` — the one blocking prompt with no `request_id`; resolution is FIFO on a
/// per-session queue (reference §5.1, §5.2).
public struct ApprovalRequestEvent: Sendable, Equatable, Identifiable {
    /// Client-side identity only. The wire carries nothing to correlate on.
    public let id: UUID
    public let sessionID: String
    /// Already redacted server-side; re-scrubbed here for defence in depth.
    public let command: String
    public let description: String
    /// `false` only when a tirith warning forbids permanence; an omitted field reads as `true`.
    public let allowPermanent: Bool
    public let smartDenied: Bool
    /// Effective button set, synthesised client-side for emitters that send no `choices`
    /// (jsonrpc-methods §3.1).
    public let choices: [ApprovalChoice]
    public let receivedAt: Date

    init(sessionID: String, payload: JSONValue) {
        id = UUID()
        self.sessionID = sessionID
        command = Redaction.text(payload["command"]?.text ?? "")
        let described = payload["description"]?.coercedString ?? ""
        description = described.isEmpty ? "dangerous command" : described
        // The backend identity-checks against the Python `False` singleton, so int 0 is not False
        // there and Always is still offered; do not coerce numbers or strings before the check.
        let permanent: Bool? = {
            guard let raw = payload["allow_permanent"] else { return nil }
            if case .bool(let b) = raw { return b }
            // Anything else (int 0, strings, …) → Always offered, same as absent.
            return true
        }()
        allowPermanent = permanent != false
        smartDenied = payload["smart_denied"]?.coercedBool == true
        receivedAt = Date()

        if let raw = payload["choices"]?.arrayValue {
            let parsed = raw.compactMap { $0.coercedString }.compactMap(ApprovalChoice.init(rawValue:))
            choices = parsed.isEmpty ? Self.synthesize(smartDenied: smartDenied, allowPermanent: permanent) : parsed
        } else {
            choices = Self.synthesize(smartDenied: smartDenied, allowPermanent: permanent)
        }
    }

    /// Mirrors the backend's synthesis, with `allowPermanent !== false` for an absent key.
    static func synthesize(smartDenied: Bool, allowPermanent: Bool?) -> [ApprovalChoice] {
        if smartDenied { return [.once, .deny] }
        if allowPermanent == false { return [.once, .session, .deny] }
        return [.once, .session, .always, .deny]
    }

    /// Convenience for a UI that wants a plain-language risk hint.
    public var isLikelyDestructive: Bool {
        let lowered = command.lowercased()
        let markers = ["rm -rf", "rm -r", "sudo", "mkfs", "dd if=", "shutdown", "reboot",
                       "drop table", "git push --force", "curl", "chmod 777", ":(){"]
        return markers.contains { lowered.contains($0) }
    }
}

/// One entry of a BATCH `clarify.request`, which the backend emits as
/// `{"questions": [...], "request_id": rid}` instead of the top-level `question` / `choices` pair.
public struct ClarifyQuestion: Sendable, Equatable, Identifiable {
    /// The backend's stable per-question address; an id it does not recognise is refused with 4002,
    /// so this is taken from the wire and never synthesised.
    public let id: String
    public let question: String
    /// Empty means open-ended: a free-text answer, not a broken choice list.
    public let choices: [String]
    /// Honoured only alongside choices — there is nothing to multi-select in free text.
    public let multiSelect: Bool

    public init(id: String, question: String, choices: [String], multiSelect: Bool) {
        self.id = id
        self.question = question
        self.choices = choices
        self.multiSelect = multiSelect
    }

    /// Decode one wire entry; nil when it has no usable address or text, since an entry that cannot
    /// be addressed cannot be answered.
    init?(wire: JSONValue) {
        let qid = (wire["qid"]?.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let text = (wire["question"]?.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !qid.isEmpty, !text.isEmpty else { return nil }
        let offered = (wire["choices"]?.arrayValue ?? [])
            .compactMap { $0.coercedString }
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        self.init(
            id: qid,
            question: text,
            choices: offered,
            multiSelect: (wire["multi_select"]?.coercedBool ?? false) && !offered.isEmpty
        )
    }
}

/// `clarify.request {question, choices, multi_select?, request_id}`, or its batch form
/// `{questions: [...], request_id}`; both shapes still occur, because the batch form was added and
/// not substituted. Timeout is not on the wire today, so callers fall back to configured
/// `agent.clarify_timeout`, then `defaultTimeoutSeconds`.
public struct ClarifyRequestEvent: Sendable, Equatable, Identifiable {
    public let id: String
    public let sessionID: String
    public let question: String
    public let choices: [String]
    public let multiSelect: Bool
    public let receivedAt: Date
    /// Seconds on the wire payload if any; `<= 0` means wait forever.
    public let wireTimeoutSeconds: Double?
    /// The batch form's question list; empty for the single-question shape.
    public let questions: [ClarifyQuestion]
    /// Answers the backend has already locked, keyed by qid; sent only on a reconnect replay, so a
    /// returning card restores its per-question state.
    public let lockedAnswers: [String: String]

    /// Whether this request needs a `question_id` on every `clarify.respond`; a batch answered the
    /// single-question way is discarded server-side as "the user skipped every question".
    public var isBatch: Bool { !questions.isEmpty }
    /// Kit-level last-resort default when neither the payload nor config answers.
    public static let defaultTimeoutSeconds: Double = 3600
    /// Effective timeout for callers with no config document.
    public var timeoutSeconds: Double { wireTimeoutSeconds ?? Self.defaultTimeoutSeconds }

    public init(
        id: String,
        sessionID: String,
        question: String,
        choices: [String],
        multiSelect: Bool,
        receivedAt: Date = Date(),
        wireTimeoutSeconds: Double? = nil,
        questions: [ClarifyQuestion] = [],
        lockedAnswers: [String: String] = [:]
    ) {
        self.id = id
        self.sessionID = sessionID
        self.question = question
        self.choices = choices
        self.multiSelect = multiSelect
        self.receivedAt = receivedAt
        self.wireTimeoutSeconds = wireTimeoutSeconds
        self.questions = questions
        self.lockedAnswers = lockedAnswers
    }

    /// Decode the wire payload — the live frame's and the identical snapshot `session.resume`
    /// replays — through one decoder, so the two paths cannot diverge (BUG-066). `questions`
    /// arrives INSTEAD of `question` / `choices`, and reading only the historical keys is what made
    /// a batch render as a blank card (BUG-041).
    init(sessionID: String, payload: JSONValue) {
        self.init(
            id: payload["request_id"]?.coercedString ?? "",
            sessionID: sessionID,
            question: payload["question"]?.text ?? "",
            choices: (payload["choices"]?.arrayValue ?? []).compactMap { $0.coercedString },
            multiSelect: payload["multi_select"]?.coercedBool ?? false,
            receivedAt: Date(),
            // Not emitted by current backends; accept either name if one appears.
            wireTimeoutSeconds: payload["timeout"]?.coercedDouble
                ?? payload["timeout_seconds"]?.coercedDouble,
            questions: (payload["questions"]?.arrayValue ?? [])
                .compactMap(ClarifyQuestion.init(wire:)),
            lockedAnswers: (payload["answers"]?.objectValue ?? [:])
                .compactMapValues { $0.coercedString }
        )
    }
}

/// `sudo.request {request_id}` — payload carries nothing else. 120 s.
public struct SudoRequestEvent: Sendable, Equatable, Identifiable {
    public let id: String
    public let sessionID: String
    public let receivedAt: Date
    public var timeoutSeconds: Double { 120 }
}

/// `secret.request {prompt, env_var, metadata?, request_id}`. 300 s.
public struct SecretRequestEvent: Sendable, Equatable, Identifiable {
    public let id: String
    public let sessionID: String
    public let prompt: String
    public let envVar: String
    public let receivedAt: Date
    public var timeoutSeconds: Double { 300 }
}

/// `terminal.read.request`; a phone has no terminal buffer, so this client answers immediately
/// with an empty string.
public struct TerminalReadRequestEvent: Sendable, Equatable, Identifiable {
    public let id: String
    public let sessionID: String
    public let start: Int?
    public let count: Int?
    public var timeoutSeconds: Double { 30 }
}

public struct SessionInfoEvent: Sendable, Equatable {
    public let sessionID: String
    public let info: SessionInfo
}

/// `session.title` — `payload.session_id` is the DURABLE key while `params.session_id` is the live
/// runtime id (jsonrpc-methods §2.7).
public struct SessionTitleEvent: Sendable, Equatable {
    public let runtimeSessionID: String
    public let storedSessionID: String
    public let title: String
}

public struct StatusUpdateEvent: Sendable, Equatable {
    public let sessionID: String
    /// Open vocabulary: `status`, `lifecycle`, `compacting`, `process`, `goal`, `ready`, and more.
    public let kind: String
    public let text: String
}

public struct NotificationEvent: Sendable, Equatable {
    public let sessionID: String
    public let key: String
    public let text: String
    public let level: String
}

public struct BackgroundCompleteEvent: Sendable, Equatable {
    public let sessionID: String
    public let taskID: String
    public let text: String
}

/// `tool.output_risk` — a safety signal about a tool's output, relayed verbatim.
public struct ToolOutputRiskEvent: Sendable, Equatable {
    public let sessionID: String
    public let toolID: String
    /// Needed for correlation: a `tool.start` without an id was given a synthetic one, so its card
    /// can never be found by `tool_id` alone.
    public let name: String
    /// The band, e.g. `low` / `medium` / `high`; open vocabulary, displayed and never interpreted.
    public let risk: String
    public let findings: [String]
    /// The backend withheld some output — worth showing even when `findings` is empty.
    public let redacted: Bool

    public init(
        sessionID: String,
        toolID: String,
        name: String = "",
        risk: String,
        findings: [String],
        redacted: Bool
    ) {
        self.sessionID = sessionID
        self.toolID = toolID
        self.name = name
        self.risk = risk
        self.findings = findings
        self.redacted = redacted
    }

    /// Whether the event says anything at all; a band with no findings, or a redaction with no
    /// band, is still a signal the user must see.
    public var hasSignal: Bool {
        !findings.isEmpty || !risk.isEmpty || redacted
    }
}

/// One `subagent.*` frame, decoded leniently: everything but the phase is conditional, so this
/// decode cannot fail and a payload carrying nothing still produces a usable row.
///
/// `subagent.text` is never relayed on the parent session — the child's reply body does not exist
/// on this wire at all, which is why this type describes a tree and never a transcript.
public struct SubagentEvent: Sendable, Equatable {
    /// The six types the gateway relays on the PARENT session; the raw value is the wire type, so
    /// the string-to-phase mapping has exactly one home.
    public enum Phase: String, Sendable, Equatable, CaseIterable {
        case spawnRequested = "subagent.spawn_requested"
        case start = "subagent.start"
        case thinking = "subagent.thinking"
        case tool = "subagent.tool"
        case progress = "subagent.progress"
        case complete = "subagent.complete"

        /// Only these two materialise a row; half a lifecycle is not an agent.
        public var createsRow: Bool { self == .spawnRequested || self == .start }

        /// Terminal by EVENT TYPE, never by status string.
        public var isTerminal: Bool { self == .complete }
    }

    public let sessionID: String
    public let phase: Phase
    /// `""` when the wire carried none — `identity` synthesises one.
    public let subagentID: String
    /// The delegating agent, and the edge the detail sheet builds its tree from.
    public let parentID: String
    public let childSessionID: String
    public let goal: String
    public let taskIndex: Int?
    public let taskCount: Int?
    public let depth: Int?
    public let model: String
    public let toolCount: Int?
    public let toolName: String
    public let toolPreview: String
    public let text: String
    /// `nil` when the key is absent, which is not the same as `""`; only the reducer decides.
    public let status: String?
    public let summary: String
    public let outputTail: String
    public let durationSeconds: Double?

    /// Coerced accessors throughout: the backend emits ints and floats interchangeably.
    public init(sessionID: String, phase: Phase, payload: JSONValue) {
        self.sessionID = sessionID
        self.phase = phase
        subagentID = payload["subagent_id"]?.coercedString ?? ""
        parentID = payload["parent_id"]?.coercedString ?? ""
        childSessionID = payload["child_session_id"]?.coercedString ?? ""
        goal = payload["goal"]?.text ?? ""
        taskIndex = payload["task_index"]?.coercedInt
        taskCount = payload["task_count"]?.coercedInt
        depth = payload["depth"]?.coercedInt
        model = payload["model"]?.coercedString ?? ""
        toolCount = payload["tool_count"]?.coercedInt
        toolName = payload["tool_name"]?.coercedString ?? ""
        toolPreview = payload["tool_preview"]?.text ?? ""
        text = payload["text"]?.text ?? ""
        status = payload["status"]?.coercedString
        summary = payload["summary"]?.text ?? ""
        outputTail = payload["output_tail"]?.text ?? ""
        durationSeconds = payload["duration_seconds"]?.coercedDouble
    }

    /// `subagent_id` when the wire carried one, else a synthetic composite; stable across the whole
    /// lifecycle, or a fan-out of four renders as twenty.
    public var identity: String {
        if !subagentID.isEmpty { return subagentID }
        let parent = parentID.isEmpty ? "root" : parentID
        let index = taskIndex.map(String.init) ?? ""
        return "\(parent):\(index):\(goal)"
    }

    /// The one line this frame contributes to its row's stream; `spawn_requested` and `start` are
    /// deliberately silent, because their goal is already the row's title.
    public var streamLine: String {
        switch phase {
        case .spawnRequested, .start:
            return ""
        case .thinking:
            return text
        case .tool:
            return [toolName, toolPreview].filter { !$0.isEmpty }.joined(separator: " ")
        case .progress:
            // First non-empty: emitters differ about which of these they fill.
            return [text, outputTail, toolPreview, summary].first { !$0.isEmpty } ?? ""
        case .complete:
            return summary
        }
    }
}

// MARK: - The event union

/// Typed projection of a raw `GatewayEvent`, on two rules (jsonrpc-methods §2, §6.3): parse
/// defensively, because `payload` may be absent entirely and optional fields are omitted rather
/// than nulled; and ignore an unrecognised `type` rather than failing on it, hence `.other`.
public enum HermesEvent: Sendable {
    case gatewayReady(GatewayReadyEvent)

    case messageStart(sessionID: String)
    case messageDelta(TextDeltaEvent)
    case reasoningDelta(TextDeltaEvent)
    /// Replaces the whole reasoning block rather than appending.
    case reasoningAvailable(TextDeltaEvent)
    /// Kawaii-spinner status, not reasoning — the desktop deliberately drops it.
    case thinkingDelta(TextDeltaEvent)
    case messageInterim(MessageInterimEvent)
    case messageComplete(MessageCompleteEvent)

    case toolStart(ToolStartEvent)
    case toolProgress(ToolStartEvent)
    case toolComplete(ToolCompleteEvent)
    /// Status only — no id and no args yet, so no row is materialised.
    case toolGenerating(sessionID: String, name: String)

    // Six cases rather than one with a discriminator, so a seventh subagent type the backend adds
    // later is a compile error at the reducer rather than another silent drop (BUG-011).
    case subagentSpawnRequested(SubagentEvent)
    case subagentStart(SubagentEvent)
    case subagentThinking(SubagentEvent)
    case subagentTool(SubagentEvent)
    case subagentProgress(SubagentEvent)
    case subagentComplete(SubagentEvent)

    case approvalRequest(ApprovalRequestEvent)
    case clarifyRequest(ClarifyRequestEvent)
    case clarifyExpire(sessionID: String, requestID: String)
    case sudoRequest(SudoRequestEvent)
    case sudoExpire(sessionID: String, requestID: String)
    case secretRequest(SecretRequestEvent)
    case secretExpire(sessionID: String, requestID: String)
    case terminalReadRequest(TerminalReadRequestEvent)
    case terminalReadExpire(sessionID: String, requestID: String)

    case sessionInfo(SessionInfoEvent)
    case sessionTitle(SessionTitleEvent)
    case statusUpdate(StatusUpdateEvent)
    case notificationShow(NotificationEvent)
    case notificationClear(sessionID: String, key: String)
    case reviewSummary(sessionID: String, text: String)
    case backgroundComplete(BackgroundCompleteEvent)
    case toolOutputRisk(ToolOutputRiskEvent)
    /// Agent init failure, context-injection refusal, host crash — distinct from a failed TURN,
    /// which ends at `message.complete {status: "error"}`.
    case errorEvent(sessionID: String, message: String)

    /// `{}` payload, `session_id: ""` — "something changed, refetch".
    case sessionsChanged
    /// Backend skin changed; broadcast to every client. Carries the raw
    /// `resolve_skin()` dict so the client can remap its seeds.
    case skinChanged(name: String, skin: JSONValue)
    case other(GatewayEvent)

    // MARK: Projection

    public static func project(_ event: GatewayEvent) -> HermesEvent {
        let sid = event.sessionID
        let payload = event.payload

        switch event.type {
        case "gateway.ready":
            return .gatewayReady(GatewayReadyEvent(
                skinName: payload["skin"]?["name"]?.coercedString ?? "",
                skin: payload["skin"] ?? .null,
                changeEvents: payload["change_events"]?.coercedBool ?? false,
                sessionMirroring: payload["session_mirroring"]?.coercedBool ?? false,
                origin: payload["origin"]?.coercedString ?? ""
            ))

        case "skin.changed":
            // Payload is the `resolve_skin()` dict itself, name at top level.
            return .skinChanged(name: payload["name"]?.coercedString ?? "", skin: payload)

        case "message.start":
            return .messageStart(sessionID: sid)

        case "message.delta":
            return .messageDelta(TextDeltaEvent(sessionID: sid, text: payload["text"]?.text ?? ""))

        case "reasoning.delta":
            return .reasoningDelta(TextDeltaEvent(sessionID: sid, text: payload["text"]?.text ?? ""))

        case "reasoning.available":
            return .reasoningAvailable(TextDeltaEvent(sessionID: sid, text: payload["text"]?.text ?? ""))

        case "thinking.delta":
            return .thinkingDelta(TextDeltaEvent(sessionID: sid, text: payload["text"]?.text ?? ""))

        case "message.interim":
            return .messageInterim(MessageInterimEvent(
                sessionID: sid,
                text: payload["text"]?.text ?? "",
                alreadyStreamed: payload["already_streamed"]?.coercedBool ?? false
            ))

        case "message.complete":
            return .messageComplete(MessageCompleteEvent(
                sessionID: sid,
                text: payload["text"]?.text ?? "",
                rendered: payload["rendered"]?.text ?? "",
                status: payload["status"]?.coercedString ?? "complete",
                error: payload["error"]?.text ?? "",
                partial: payload["partial"]?.coercedBool ?? false,
                recoverable: payload["recoverable"]?.coercedBool ?? false,
                warning: payload["warning"]?.text ?? "",
                usage: payload["usage"] ?? .null,
                errorSurface: ErrorSurface(json: payload["error_surface"])
            ))

        case "tool.start", "tool.progress":
            let projected = ToolStartEvent(
                sessionID: sid,
                toolID: toolIdentifier(payload),
                name: payload["name"]?.coercedString ?? "",
                context: payload["context"]?.text ?? "",
                argsText: payload["args_text"]?.text ?? ""
            )
            return event.type == "tool.start" ? .toolStart(projected) : .toolProgress(projected)

        case "tool.complete":
            let toolName = payload["name"]?.coercedString ?? ""
            return .toolComplete(ToolCompleteEvent(
                sessionID: sid,
                toolID: toolIdentifier(payload),
                name: toolName,
                resultText: resultText(payload),
                summary: payload["summary"]?.text ?? "",
                error: payload["error"]?.text ?? "",
                durationSeconds: payload["duration_s"]?.coercedDouble,
                inlineDiff: payload["inline_diff"]?.text ?? "",
                // Gated on an EXACT name match so a tool like `todoist_add_task` cannot hijack the
                // checklist; the plan tool answers to two whole names, never a prefix (BUG-145).
                todos: TodoList.isPlanTool(toolName) ? TodoList.parse(payload: payload) : nil
            ))

        case "tool.generating":
            return .toolGenerating(sessionID: sid, name: payload["name"]?.coercedString ?? "")

        case "subagent.spawn_requested", "subagent.start", "subagent.thinking",
             "subagent.tool", "subagent.progress", "subagent.complete":
            // This case list and `Phase`'s raw values are the same six strings, so the guard is
            // unreachable in practice; it exists because a `!` on a wire-driven lookup is not worth it.
            guard let phase = SubagentEvent.Phase(rawValue: event.type) else { return .other(event) }
            let subagent = SubagentEvent(sessionID: sid, phase: phase, payload: payload)
            switch phase {
            case .spawnRequested: return .subagentSpawnRequested(subagent)
            case .start: return .subagentStart(subagent)
            case .thinking: return .subagentThinking(subagent)
            case .tool: return .subagentTool(subagent)
            case .progress: return .subagentProgress(subagent)
            case .complete: return .subagentComplete(subagent)
            }

        case "approval.request":
            return .approvalRequest(ApprovalRequestEvent(sessionID: sid, payload: payload))

        case "clarify.request":
            return .clarifyRequest(ClarifyRequestEvent(sessionID: sid, payload: payload))

        case "clarify.expire":
            return .clarifyExpire(sessionID: sid, requestID: payload["request_id"]?.coercedString ?? "")

        case "sudo.request":
            return .sudoRequest(SudoRequestEvent(
                id: payload["request_id"]?.coercedString ?? "",
                sessionID: sid,
                receivedAt: Date()
            ))

        case "sudo.expire":
            return .sudoExpire(sessionID: sid, requestID: payload["request_id"]?.coercedString ?? "")

        case "secret.request":
            return .secretRequest(SecretRequestEvent(
                id: payload["request_id"]?.coercedString ?? "",
                sessionID: sid,
                prompt: payload["prompt"]?.text ?? "",
                envVar: payload["env_var"]?.coercedString ?? "",
                receivedAt: Date()
            ))

        case "secret.expire":
            return .secretExpire(sessionID: sid, requestID: payload["request_id"]?.coercedString ?? "")

        case "terminal.read.request":
            return .terminalReadRequest(TerminalReadRequestEvent(
                id: payload["request_id"]?.coercedString ?? "",
                sessionID: sid,
                start: payload["start"]?.coercedInt,
                count: payload["count"]?.coercedInt
            ))

        case "terminal.read.expire":
            return .terminalReadExpire(sessionID: sid, requestID: payload["request_id"]?.coercedString ?? "")

        case "session.info":
            return .sessionInfo(SessionInfoEvent(sessionID: sid, info: SessionInfo(json: payload)))

        case "session.title":
            return .sessionTitle(SessionTitleEvent(
                runtimeSessionID: sid,
                storedSessionID: payload["session_id"]?.coercedString ?? "",
                title: payload["title"]?.text ?? ""
            ))

        case "status.update":
            return .statusUpdate(StatusUpdateEvent(
                sessionID: sid,
                kind: payload["kind"]?.coercedString ?? "",
                text: payload["text"]?.text ?? ""
            ))

        case "notification.show":
            return .notificationShow(NotificationEvent(
                sessionID: sid,
                key: payload["key"]?.coercedString ?? "",
                text: payload["text"]?.text ?? "",
                level: payload["level"]?.coercedString ?? "info"
            ))

        case "notification.clear":
            return .notificationClear(sessionID: sid, key: payload["key"]?.coercedString ?? "")

        case "review.summary":
            return .reviewSummary(sessionID: sid, text: payload["text"]?.text ?? "")

        case "background.complete":
            return .backgroundComplete(BackgroundCompleteEvent(
                sessionID: sid,
                taskID: payload["task_id"]?.coercedString ?? "",
                text: payload["text"]?.text ?? ""
            ))

        case "tool.output_risk":
            return .toolOutputRisk(ToolOutputRiskEvent(
                sessionID: sid,
                toolID: toolIdentifier(payload),
                name: payload["name"]?.coercedString ?? "",
                risk: payload["risk"]?.coercedString ?? "",
                findings: (payload["findings"]?.arrayValue ?? []).compactMap { $0.coercedString },
                redacted: payload["redacted"]?.coercedBool ?? false
            ))

        case "error":
            return .errorEvent(sessionID: sid, message: payload["message"]?.text ?? "Hermes reported an error")

        case "sessions.changed":
            return .sessionsChanged

        default:
            return .other(event)
        }
    }

    /// Stable tool identity with the desktop's fallback chain.
    static func toolIdentifier(_ payload: JSONValue) -> String {
        payload["tool_id"]?.coercedString
            ?? payload["tool_call_id"]?.coercedString
            ?? payload["id"]?.coercedString
            ?? ""
    }

    /// `tool.complete.result` is parsed JSON when parseable, else the raw string (jsonrpc §9.8).
    static func resultText(_ payload: JSONValue) -> String {
        if let text = payload["result_text"]?.coercedString, !text.isEmpty { return text }
        guard let result = payload["result"] else { return "" }
        switch result {
        case .string(let s): return s
        case .null: return ""
        default: return result.prettyJSONString
        }
    }
}

extension HermesEvent {
    /// Event types belonging to the ACTIVE turn, pinned when unscoped to the session that received
    /// `message.start` and never to whatever chat is on screen (reference §3.1).
    public static let turnScopedEventTypes: Set<String> = [
        "approval.request", "browser.progress", "clarify.request", "error",
        "message.complete", "message.delta", "message.interim", "message.start",
        "reasoning.available", "reasoning.delta", "secret.request", "status.update",
        "sudo.request", "thinking.delta", "tool.complete", "tool.generating",
        "tool.output_risk", "tool.progress", "tool.start",
    ]

    /// Events that force a delta flush first, so a tool card or a seal cannot jump ahead of the text
    /// before it (reference §3.3). The `subagent.*` cases are deliberately absent: they order
    /// against nothing in the transcript and arrive in bursts, so they ride the ordinary tick.
    public var forcesFlush: Bool {
        switch self {
        case .toolStart, .toolProgress, .toolComplete, .messageInterim,
             .messageComplete, .errorEvent, .reviewSummary, .messageStart,
             .approvalRequest, .clarifyRequest, .sudoRequest, .secretRequest:
            return true
        default:
            return false
        }
    }

    /// True for events the UI should react to immediately rather than on the
    /// next 33 ms tick.
    public var isUserVisibleInterrupt: Bool {
        switch self {
        case .approvalRequest, .clarifyRequest, .sudoRequest, .secretRequest,
             .terminalReadRequest, .messageComplete, .errorEvent:
            return true
        default:
            return false
        }
    }
}
