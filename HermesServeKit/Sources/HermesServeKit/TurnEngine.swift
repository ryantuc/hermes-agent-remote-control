import Foundation

// MARK: - Rendered transcript model

/// One tool invocation card.
public struct ToolActivity: Identifiable, Sendable, Equatable {
    public var id: String
    public var name: String
    /// Argument preview the backend caps at 80 chars.
    public var context: String
    /// Full redacted argument JSON — only present in `verbose` progress mode.
    public var argsText: String
    public var resultText: String
    public var errorText: String
    public var inlineDiff: String
    public var durationSeconds: Double?
    public var isRunning: Bool
    public var startedAt: Date
    /// The typed plan this call reported, when it was the `todo` tool's; nil renders the generic card.
    public var todos: TodoList?
    /// `tool.output_risk` findings, relayed verbatim — the client never rewords a safety finding.
    public var outputRiskFindings: [String]
    /// The band from the same event (`low` / `medium` / `high`, open vocabulary).
    public var outputRisk: String
    /// The backend withheld part of this tool's output.
    public var outputRiskRedacted: Bool

    public var isError: Bool { !errorText.isEmpty }

    /// Whether the card has any safety signal to render.
    public var hasOutputRisk: Bool {
        !outputRiskFindings.isEmpty || !outputRisk.isEmpty || outputRiskRedacted
    }

    public init(
        id: String,
        name: String,
        context: String = "",
        argsText: String = "",
        resultText: String = "",
        errorText: String = "",
        inlineDiff: String = "",
        durationSeconds: Double? = nil,
        isRunning: Bool = true,
        startedAt: Date = Date(),
        todos: TodoList? = nil,
        outputRiskFindings: [String] = [],
        outputRisk: String = "",
        outputRiskRedacted: Bool = false
    ) {
        self.id = id
        self.name = name
        self.context = context
        self.argsText = argsText
        self.resultText = resultText
        self.errorText = errorText
        self.inlineDiff = inlineDiff
        self.durationSeconds = durationSeconds
        self.isRunning = isRunning
        self.startedAt = startedAt
        self.todos = todos
        self.outputRiskFindings = outputRiskFindings
        self.outputRisk = outputRisk
        self.outputRiskRedacted = outputRiskRedacted
    }
}

/// A single renderable row; persisted history and live turn output both project into it.
public struct ChatEntry: Identifiable, Sendable, Equatable {
    public enum Kind: String, Sendable, Equatable {
        case user
        case assistant
        case tool
        /// Client-side annotation: auto-continue, status, corrections, errors.
        case notice
        /// Persistent system row (e.g. `review.summary`).
        case system
    }

    public var id: String
    public var kind: Kind
    public var text: String
    public var reasoning: String
    public var isStreaming: Bool
    /// Sealed by `message.interim`; a following `message.complete` must not
    /// wipe it (reference-clients.md §3.2).
    public var isInterim: Bool
    /// `""` while live; then `complete` | `interrupted` | `error`.
    public var status: String
    public var errorText: String
    /// `partial: true` on an error frame means `text` is streamed output worth
    /// keeping, not the error string.
    public var isPartial: Bool
    /// Which layer failed this turn (FEAT-016); advisory, so never gate rendering of an error on it.
    public var errorSurface: ErrorSurface?
    public var tool: ToolActivity?
    /// `@image:` / `data:` references lifted out of a persisted user turn.
    public var imageRefs: [String]
    public var noticeKind: String
    public var timestamp: Date
    /// Client observations of the stream — the wire carries no reasoning duration on any frame.
    public var reasoningStartedAt: Date?
    public var reasoningEndedAt: Date?

    /// How long the thinking phase ran; nil is a real answer the header must render as one.
    public var reasoningDuration: TimeInterval? {
        guard let start = reasoningStartedAt, let end = reasoningEndedAt, end > start else {
            return nil
        }
        return end.timeIntervalSince(start)
    }

    /// The ceiling on one entry's accumulated thinking.
    public static let reasoningLimit = 256 * 1024
    /// Head-drop target, kept below the limit so a trace that hits the ceiling drops once, not per delta.
    static let reasoningRetained = 192 * 1024
    static let reasoningElision = "… earlier thinking dropped …\n"

    /// Append to the trace, bounded; the head goes, not the tail.
    public mutating func appendReasoning(_ chunk: String) {
        guard !chunk.isEmpty else { return }
        reasoning += chunk
        guard reasoning.utf8.count > Self.reasoningLimit else { return }
        let keep = reasoning.suffix(Self.reasoningRetained / 2)
        reasoning = Self.reasoningElision + String(keep)
    }

    public init(
        id: String,
        kind: Kind,
        text: String = "",
        reasoning: String = "",
        isStreaming: Bool = false,
        isInterim: Bool = false,
        status: String = "",
        errorText: String = "",
        isPartial: Bool = false,
        errorSurface: ErrorSurface? = nil,
        tool: ToolActivity? = nil,
        imageRefs: [String] = [],
        noticeKind: String = "",
        timestamp: Date = Date(),
        reasoningStartedAt: Date? = nil,
        reasoningEndedAt: Date? = nil
    ) {
        self.id = id
        self.kind = kind
        self.text = text
        self.reasoning = reasoning
        self.isStreaming = isStreaming
        self.isInterim = isInterim
        self.status = status
        self.errorText = errorText
        self.isPartial = isPartial
        self.errorSurface = errorSurface
        self.tool = tool
        self.imageRefs = imageRefs
        self.noticeKind = noticeKind
        self.timestamp = timestamp
        self.reasoningStartedAt = reasoningStartedAt
        self.reasoningEndedAt = reasoningEndedAt
    }

    public var isError: Bool { status == "error" || !errorText.isEmpty }
}

/// A keyed, replace-in-place notice occupying one slot: `show` swaps content, `clear` removes it.
public struct Notice: Sendable, Equatable {
    public var key: String
    public var text: String
    public var level: String

    public init(key: String, text: String, level: String) {
        self.key = key
        self.text = text
        self.level = level
    }
}

/// Everything the UI needs to know about one session's live turn.
public struct SessionTurnState: Sendable, Equatable {
    public var entries: [ChatEntry] = []
    /// The single keyed notice slot, shown above the composer rather than
    /// appended into the transcript as a `.notice` row.
    public var notice: Notice?
    /// The composer's shared status surface: the agent's live plan and its running subagents.
    ///
    /// Never consult this from `isQuiescent(sessionID:)` — it is derived display state, and a
    /// lingering finished checklist would hold a session alive against the idle sweep.
    public var activity = SessionActivity()
    /// A turn is running.
    public var isBusy = false
    /// Whether the running turn was started by this client; false for a fan-out turn another drove.
    public var turnStartedLocally = false
    /// When the running turn began, as the BACKEND measured it — nil when the backend has not said.
    ///
    /// Adopted, never erased, by `session.info`: only some emitters carry the key, so clearing on a
    /// missing key would let one frame wipe a start the fuller frames established.
    public var turnStartedAt: Date?
    /// A blocking prompt is waiting on the user.
    public var needsInput = false
    /// Local barge-in latch against a cooperative cancel's in-flight events (reference §3.5).
    public var interrupted = false
    public var statusText = ""
    /// FIFO: `approval.request` has no `request_id`, so order is the only correlation available.
    public var pendingApprovals: [ApprovalRequestEvent] = []
    public var clarify: ClarifyRequestEvent?
    public var sudo: SudoRequestEvent?
    public var secret: SecretRequestEvent?
    public var terminalRead: TerminalReadRequestEvent?
    public var lastError: String?
    /// The backend auto-resubmitted a turn that died with the process.
    public var autoContinue: AutoContinueNotice?
    public var title: String?
    public var info: SessionInfo?

    /// Explicit because a public struct's synthesized initializer is internal.
    public init() {}

    public var currentApproval: ApprovalRequestEvent? { pendingApprovals.first }

    public var hasBlockingPrompt: Bool {
        currentApproval != nil || clarify != nil || sudo != nil || secret != nil
    }
}

// MARK: - TurnEngine

/// Per-session turn state machine.
///
/// Deltas accumulate per SESSION, not per message id — one streaming bubble per session, and
/// unscoped events pin to the session that received the last `message.start` (reference §3.1, §3.3).
/// Not an actor and not `Sendable`: confined to one isolation domain, which keeps `flush()` synchronous.
public final class TurnEngine {
    /// ≈30 fps floor (`STREAM_DELTA_FLUSH_MS`).
    public static let flushFloor: TimeInterval = 0.033
    /// 4 fps ceiling (`MAX_STREAM_FLUSH_GAP_MS`) — text must never update slower than this.
    public static let flushCeiling: TimeInterval = 0.250
    /// Start-only backstop after a local Stop: body events stay latched with no timer (BUG-068A).
    public static let interruptGrace: TimeInterval = 5
    /// The reserved `origin` on an auto-continue kickoff; it names no client, so it decides no ownership.
    public static let autoContinueOrigin = "auto_continue"

    private struct DeltaBuffer {
        var assistant = ""
        var reasoning = ""
        /// `reasoning.available` replaces the whole block instead of appending.
        var reasoningReplaces = false
        /// Stamped at event receipt, not at flush, so the 33 ms coalescing window does not blur it.
        var reasoningFirstAt: Date?
        var reasoningLastAt: Date?

        mutating func stampReasoning(_ moment: Date) {
            if reasoningFirstAt == nil { reasoningFirstAt = moment }
            reasoningLastAt = moment
        }
    }

    /// How many unmatched `tool.output_risk` signals to hold per session.
    private static let heldRiskLimit = 16

    private var states: [String: SessionTurnState] = [:]
    private var buffers: [String: DeltaBuffer] = [:]
    /// Risk signals whose tool card did not exist yet, per session.
    private var heldRisks: [String: [ToolOutputRiskEvent]] = [:]
    /// When Stop was last pressed, per session; `state.interrupted` records that it was.
    private var interruptedAt: [String: Date] = [:]
    /// Id of the assistant entry currently accumulating text, per session.
    private var streamingEntryIDs: [String: String] = [:]
    /// The session that received the most recent `message.start`.
    private(set) public var pinnedSessionID: String?
    /// This connection's transport id from `gateway.ready`; empty on a backend that does not fan out.
    private(set) public var localOrigin = ""
    private var entryCounter = 0
    private var syntheticToolCounter = 0

    public init() {}

    // MARK: Reading

    public func state(for sessionID: String) -> SessionTurnState {
        states[sessionID] ?? SessionTurnState()
    }

    public var trackedSessionIDs: [String] { Array(states.keys) }

    /// O(1) roster size, for callers that only need the count.
    public var trackedSessionCount: Int { states.count }

    public var hasPendingDeltas: Bool {
        buffers.values.contains { !$0.assistant.isEmpty || !$0.reasoning.isEmpty || $0.reasoningReplaces }
    }

    /// Whether this session's state can be discarded without losing anything a future event
    /// cannot rebuild; a quiescent verdict is permission to `forget`, never an instruction.
    ///
    /// `state.activity` is deliberately not consulted, subagents included: a running row can be
    /// orphaned by a dropped frame, and the engine is timer-free, so one would pin the state forever.
    public func isQuiescent(sessionID: String) -> Bool {
        guard let state = states[sessionID] else { return true }
        if state.isBusy || state.needsInput || state.hasBlockingPrompt { return false }
        if state.terminalRead != nil { return false }
        // Any interrupt bookkeeping keeps the session: a sweep must never reset the stale-frame latch.
        if state.interrupted || interruptedAt[sessionID] != nil { return false }
        if let buffer = buffers[sessionID],
           !buffer.assistant.isEmpty || !buffer.reasoning.isEmpty || buffer.reasoningReplaces {
            return false
        }
        if streamingEntryIDs[sessionID] != nil { return false }
        if let held = heldRisks[sessionID], !held.isEmpty { return false }
        // The pinned session is where the next unscoped event lands; forgetting it misroutes it.
        if pinnedSessionID == sessionID { return false }
        return true
    }

    // MARK: Session bookkeeping

    /// Record this connection's transport id, taken from `gateway.ready`.
    public func setLocalOrigin(_ origin: String) {
        localOrigin = origin
    }

    /// A respawned backend recycles runtime ids, so state must move with the thread (reference §7.2).
    public func rebind(from oldSessionID: String, to newSessionID: String) {
        guard oldSessionID != newSessionID else { return }
        if let existing = states.removeValue(forKey: oldSessionID) {
            states[newSessionID] = existing
        }
        if let buffer = buffers.removeValue(forKey: oldSessionID) {
            buffers[newSessionID] = buffer
        }
        if let streaming = streamingEntryIDs.removeValue(forKey: oldSessionID) {
            streamingEntryIDs[newSessionID] = streaming
        }
        if let risks = heldRisks.removeValue(forKey: oldSessionID) {
            heldRisks[newSessionID] = risks
        }
        if let interrupted = interruptedAt.removeValue(forKey: oldSessionID) {
            interruptedAt[newSessionID] = interrupted
        }
        if pinnedSessionID == oldSessionID { pinnedSessionID = newSessionID }
    }

    public func reset(sessionID: String) {
        states[sessionID] = SessionTurnState()
        buffers[sessionID] = nil
        streamingEntryIDs[sessionID] = nil
        heldRisks[sessionID] = nil
        interruptedAt[sessionID] = nil
        if pinnedSessionID == sessionID { pinnedSessionID = nil }
    }

    public func forget(sessionID: String) {
        states[sessionID] = nil
        buffers[sessionID] = nil
        streamingEntryIDs[sessionID] = nil
        heldRisks[sessionID] = nil
        interruptedAt[sessionID] = nil
        if pinnedSessionID == sessionID { pinnedSessionID = nil }
    }

    // MARK: Local mutations

    /// Optimistic user bubble, inserted the moment Send is tapped.
    ///
    /// - Parameter joiningRunningTurn: true for a steer or redirect issued under a running turn,
    ///   whose streaming pointer must stay because its `message.complete` still settles onto it.
    ///   Never drop the pointer while the entry still carries `isStreaming` (BUG-019).
    @discardableResult
    public func appendUserEntry(
        sessionID: String,
        text: String,
        imageRefs: [String] = [],
        joiningRunningTurn: Bool = false
    ) -> String {
        flush()
        var state = state(for: sessionID)
        let entry = ChatEntry(
            id: nextID(sessionID, "user"),
            kind: .user,
            text: text,
            imageRefs: imageRefs
        )
        state.entries.append(entry)
        state.isBusy = true
        state.turnStartedLocally = true
        state.interrupted = false
        state.lastError = nil
        // Read the pointer BEFORE it is dropped, and against the local `state`.
        let streaming = streamingIndex(for: sessionID, in: state)
        if !joiningRunningTurn, let index = streaming {
            state.entries[index].isStreaming = false
        }
        states[sessionID] = state
        // A dangling pointer is cleared on both branches; only a live one survives a steer.
        if !joiningRunningTurn || streaming == nil {
            streamingEntryIDs[sessionID] = nil
        }
        interruptedAt[sessionID] = nil
        pinnedSessionID = sessionID
        return entry.id
    }

    /// Roll back a locally-appended entry after a hard submit failure; a no-op once the id is gone.
    public func removeEntry(sessionID: String, entryID: String) {
        guard var state = states[sessionID] else { return }
        guard let index = state.entries.firstIndex(where: { $0.id == entryID }) else { return }
        state.entries.remove(at: index)
        // `appendUserEntry` claimed `isBusy` for this send; release it unless something holds the turn.
        if streamingEntryIDs[sessionID] == nil, !state.hasBlockingPrompt {
            state.isBusy = false
        }
        states[sessionID] = state
        if pinnedSessionID == sessionID { pinnedSessionID = nil }
    }

    @discardableResult
    public func appendNotice(
        sessionID: String,
        text: String,
        kind: String,
        isSystem: Bool = false
    ) -> String {
        var state = state(for: sessionID)
        let entry = ChatEntry(
            id: nextID(sessionID, "notice"),
            kind: isSystem ? .system : .notice,
            text: text,
            noticeKind: kind
        )
        state.entries.append(entry)
        states[sessionID] = state
        return entry.id
    }

    /// Label an entry after the fact — the ack saying what the backend did arrives after it exists.
    ///
    /// Returns whether an entry was found, so a caller can tell "labelled" from "no longer here".
    @discardableResult
    public func setNoticeKind(sessionID: String, entryID: String, kind: String) -> Bool {
        guard var state = states[sessionID],
              let index = state.entries.firstIndex(where: { $0.id == entryID })
        else { return false }
        state.entries[index].noticeKind = kind
        states[sessionID] = state
        return true
    }

    /// Finalise locally before awaiting `session.interrupt`, so the composer re-enables (reference §3.5).
    public func markInterrupted(sessionID: String, at moment: Date = Date()) {
        flush()
        var state = state(for: sessionID)
        state.interrupted = true
        interruptedAt[sessionID] = moment
        state.isBusy = false
        state.turnStartedLocally = false
        state.turnStartedAt = nil
        state.needsInput = false
        state.pendingApprovals.removeAll()
        state.clarify = nil
        state.sudo = nil
        state.secret = nil
        state.terminalRead = nil
        // Stop clears the whole surface unconditionally, finished or not.
        state.activity = SessionActivity()
        if let index = streamingIndex(for: sessionID, in: state) {
            state.entries[index].isStreaming = false
            state.entries[index].status = "interrupted"
        }
        states[sessionID] = state
        streamingEntryIDs[sessionID] = nil
        // Nothing buffered before a Stop survives it (BUG-068A).
        buffers[sessionID] = nil
        // `flush()` does not touch `heldRisks`, and a held risk would land on a same-named card
        // in the NEXT turn — a safety band on the wrong tool call.
        heldRisks[sessionID] = nil
        if pinnedSessionID == sessionID { pinnedSessionID = nil }
    }

    /// Retire one delegated agent the backend says it has never heard of.
    ///
    /// Touches one activity row and no turn state at all: the parent turn is settled in the case
    /// this exists for, so claiming an interrupt on the session would fabricate one.
    @discardableResult
    public func markSubagentInterrupted(
        sessionID: String,
        wireSubagentID: String,
        at moment: Date = Date()
    ) -> Bool {
        guard var state = states[sessionID] else { return false }
        let changed = state.activity.markSubagentInterrupted(wireSubagentID: wireSubagentID, at: moment)
        guard changed else { return false }
        states[sessionID] = state
        return true
    }

    /// Retire the named running agents and answer how many changed; only for `delegation.status`.
    @discardableResult
    public func markSubagentsInterrupted(
        sessionID: String,
        ids: [String],
        at moment: Date = Date()
    ) -> Int {
        guard var state = states[sessionID] else { return 0 }
        let changed = state.activity.markSubagentsInterrupted(ids: ids, at: moment)
        guard changed > 0 else { return 0 }
        states[sessionID] = state
        return changed
    }

    public func clearInterrupted(sessionID: String) {
        guard var state = states[sessionID] else { return }
        state.interrupted = false
        interruptedAt[sessionID] = nil
        // Anything buffered now arrived after the Stop and before the new prompt: the resend must
        // not materialise the cancelled turn's tail under the user's new message (BUG-068A).
        buffers[sessionID] = nil
        states[sessionID] = state
    }

    /// Settle a turn whose terminal frame never arrived; absence from `session.active_list` is
    /// authoritative (reference §4.6). Turn flags only, and deliberately NOT `markInterrupted`.
    public func settleFromStatus(sessionID: String) {
        guard var state = states[sessionID] else { return }
        state.isBusy = false
        state.turnStartedLocally = false
        state.turnStartedAt = nil
        state.needsInput = false
        state.statusText = ""
        state.pendingApprovals.removeAll()
        state.clarify = nil
        state.sudo = nil
        state.secret = nil
        state.terminalRead = nil
        dropStaleTodos(&state)
        if let index = streamingIndex(for: sessionID, in: state) {
            state.entries[index].isStreaming = false
        }
        states[sessionID] = state
        buffers[sessionID] = nil
        streamingEntryIDs[sessionID] = nil
    }

    /// Pop the head of the FIFO after `approval.respond` succeeds.
    public func removeApproval(sessionID: String, id: UUID) {
        guard var state = states[sessionID] else { return }
        state.pendingApprovals.removeAll { $0.id == id }
        state.needsInput = state.hasBlockingPrompt
        states[sessionID] = state
    }

    public func clearClarify(sessionID: String) { clearPrompt(sessionID) { $0.clarify = nil } }
    public func clearSudo(sessionID: String) { clearPrompt(sessionID) { $0.sudo = nil } }
    public func clearSecret(sessionID: String) { clearPrompt(sessionID) { $0.secret = nil } }
    public func clearTerminalRead(sessionID: String) { clearPrompt(sessionID) { $0.terminalRead = nil } }

    private func clearPrompt(_ sessionID: String, _ mutate: (inout SessionTurnState) -> Void) {
        guard var state = states[sessionID] else { return }
        mutate(&state)
        state.needsInput = state.hasBlockingPrompt
        states[sessionID] = state
    }

    public func clearAutoContinue(sessionID: String) {
        guard var state = states[sessionID] else { return }
        state.autoContinue = nil
        states[sessionID] = state
    }

    /// Replace the live entries with a fresh set; `activity` is deliberately left alone.
    public func replaceEntries(sessionID: String, with entries: [ChatEntry]) {
        var state = state(for: sessionID)
        state.entries = entries
        states[sessionID] = state
        streamingEntryIDs[sessionID] = nil
    }

    // MARK: - Event application

    /// Apply one raw gateway event; nil for a global broadcast or a dropped unscoped `subagent.*`.
    @discardableResult
    public func apply(_ event: GatewayEvent, at moment: Date = Date()) -> String? {
        let projected = HermesEvent.project(event)
        guard let sessionID = route(event) else {
            return nil
        }
        if projected.forcesFlush { flush(sessionID: sessionID) }
        // `origin` rides on the event's params, not its payload.
        apply(
            projected,
            to: sessionID,
            origin: event.params["origin"]?.coercedString ?? "",
            at: moment
        )
        return sessionID
    }

    /// Event → session routing: an explicit `session_id` wins, unscoped `subagent.*` is dropped,
    /// and everything else unscoped belongs to the pinned turn.
    private func route(_ event: GatewayEvent) -> String? {
        if !event.sessionID.isEmpty {
            if event.type == "message.start" { pinnedSessionID = event.sessionID }
            if event.type == "message.complete" || event.type == "error" {
                if pinnedSessionID == event.sessionID { pinnedSessionID = nil }
            }
            return event.sessionID
        }
        if event.type.hasPrefix("subagent.") { return nil }
        guard HermesEvent.turnScopedEventTypes.contains(event.type) else { return nil }
        return pinnedSessionID
    }

    /// Whether the local interrupt latch should still swallow this event.
    ///
    /// The latch is narrower than the `interrupted` flag: it claims only that the cancelled turn's
    /// own stale events may still be in flight, and it holds until that turn's terminal frame, a
    /// local resend, or a foreign-origin frame — never on age alone (BUG-068A).
    private func isLatched(sessionID: String, state: SessionTurnState, origin: String) -> Bool {
        guard state.interrupted else { return false }
        if !origin.isEmpty, !localOrigin.isEmpty, origin != localOrigin { return false }
        return true
    }

    private func apply(
        _ event: HermesEvent,
        to sessionID: String,
        origin: String = "",
        at moment: Date = Date()
    ) {
        var state = state(for: sessionID)
        // Computed once: every guard below must reach the same verdict for this one event.
        let latched = isLatched(sessionID: sessionID, state: state, origin: origin)

        switch event {
        case .messageStart:
            // A held risk that never found its card belongs to the previous turn and would
            // otherwise attach to a fresh same-named card in this one.
            heldRisks[sessionID] = nil
            // Start-only backstop: a start past the cooperative-cancel window opens a new turn,
            // while one inside it is the cancelled turn's own stale start (BUG-068A).
            if latched {
                let age: TimeInterval
                if let since = interruptedAt[sessionID] {
                    age = Date().timeIntervalSince(since)
                } else {
                    age = 0
                }
                guard age >= Self.interruptGrace else { break }
                state.interrupted = false
                interruptedAt[sessionID] = nil
            }
            // Whose turn this is, decided from the fan-out stamp — the one point on the wire that
            // says so. An unstamped frame, an unknown local origin, and the reserved auto-continue
            // stamp each decide nothing.
            if !origin.isEmpty, !localOrigin.isEmpty, origin != Self.autoContinueOrigin {
                state.turnStartedLocally = (origin == localOrigin)
            }
            // The finished-checklist linger ends HERE, and nowhere else — held until the next
            // start rather than on a timer, because the engine is synchronous by design.
            if state.activity.todos.isFinished { state.activity.todos = TodoList() }
            // The opposite rule for subagents: terminal rows retire, RUNNING rows survive, because
            // a background subagent legitimately outlives the turn that spawned it.
            state.activity.pruneTerminalSubagents()
            state.isBusy = true
            state.lastError = nil
            state.statusText = ""
            states[sessionID] = state
            streamingEntryIDs[sessionID] = nil
            return

        case .messageDelta(let delta):
            // Dropped while latched, or a late delta seeds a new bubble under the next user message.
            guard !latched else { break }
            guard !delta.text.isEmpty else { break }
            var buffer = buffers[sessionID] ?? DeltaBuffer()
            buffer.assistant += delta.text
            buffers[sessionID] = buffer
            state.isBusy = true
            states[sessionID] = state
            return

        case .reasoningDelta(let delta):
            guard !latched else { break }
            guard !delta.text.isEmpty else { break }
            var buffer = buffers[sessionID] ?? DeltaBuffer()
            buffer.reasoning += delta.text
            // Stamped here rather than in `flush` so the 33 ms window is not folded into the answer.
            buffer.stampReasoning(moment)
            buffers[sessionID] = buffer
            states[sessionID] = state
            return

        case .reasoningAvailable(let delta):
            guard !latched else { break }
            var buffer = buffers[sessionID] ?? DeltaBuffer()
            buffer.reasoning = delta.text
            buffer.reasoningReplaces = true
            buffer.stampReasoning(moment)
            buffers[sessionID] = buffer
            states[sessionID] = state
            return

        case .thinkingDelta:
            // Deliberately dropped: it carries spinner status, not reasoning.
            return

        case .messageInterim(let interim):
            guard !latched else { break }
            sealInterim(sessionID: sessionID, state: &state, text: interim.text)

        case .messageComplete(let completion):
            settleTurn(sessionID: sessionID, state: &state, event: completion, latched: latched)

        case .toolStart(let tool), .toolProgress(let tool):
            guard !latched else { break }
            upsertTool(sessionID: sessionID, state: &state, start: tool)

        case .toolComplete(let tool):
            guard !latched else { break }
            completeTool(sessionID: sessionID, state: &state, event: tool)

        case .toolGenerating:
            // Status only — no id and no args yet, so no row is materialised.
            guard !latched else { break }
            state.isBusy = true

        case .subagentSpawnRequested(let update), .subagentStart(let update),
             .subagentThinking(let update), .subagentTool(let update),
             .subagentProgress(let update), .subagentComplete(let update):
            // Behind the latch: letting a cancelled turn's subagent tail through would repopulate
            // the strip with rows whose `complete` was cancelled too, so they would never prune.
            guard !latched else { break }
            // Deliberately does NOT set `isBusy` — a subagent event is no evidence the parent turn
            // is running. The origin must be read HERE, while `turnStartedLocally` still describes
            // the turn that spawned the row.
            state.activity.upsert(update, turnStartedLocally: state.turnStartedLocally)

        case .approvalRequest(let request):
            guard !latched else { break }
            state.pendingApprovals.append(request)
            state.needsInput = true

        case .clarifyRequest(let request):
            guard !latched else { break }
            state.clarify = request
            state.needsInput = true

        case .clarifyExpire(_, let requestID):
            if state.clarify?.id == requestID || requestID.isEmpty { state.clarify = nil }
            state.needsInput = state.hasBlockingPrompt

        case .sudoRequest(let request):
            guard !latched else { break }
            state.sudo = request
            state.needsInput = true

        case .sudoExpire(_, let requestID):
            if state.sudo?.id == requestID || requestID.isEmpty { state.sudo = nil }
            state.needsInput = state.hasBlockingPrompt

        case .secretRequest(let request):
            guard !latched else { break }
            state.secret = request
            state.needsInput = true

        case .secretExpire(_, let requestID):
            if state.secret?.id == requestID || requestID.isEmpty { state.secret = nil }
            state.needsInput = state.hasBlockingPrompt

        case .terminalReadRequest(let request):
            guard !latched else { break }
            state.terminalRead = request

        case .terminalReadExpire(_, let requestID):
            if state.terminalRead?.id == requestID || requestID.isEmpty { state.terminalRead = nil }

        case .sessionInfo(let info):
            state.info = info.info
            if !info.info.title.isEmpty { state.title = info.info.title }
            // Adopt-only — see `SessionTurnState.turnStartedAt`.
            if let started = info.info.turnStartedAt { state.turnStartedAt = started }

        case .sessionTitle(let title):
            if !title.title.isEmpty { state.title = title.title }

        case .statusUpdate(let update):
            state.statusText = update.text
            if update.kind == "compacting" || update.kind == "compressing" {
                state.statusText = update.text.isEmpty ? "Compacting the conversation…" : update.text
            }

        case .notificationShow(let note):
            // One keyed slot above the composer, never a stack.
            if note.text.isEmpty {
                state.notice = nil
            } else {
                state.notice = Notice(
                    key: note.key.isEmpty ? "notification" : note.key,
                    text: note.text,
                    level: note.level
                )
            }

        case .notificationClear(_, let key):
            if state.notice?.key == key || key.isEmpty { state.notice = nil }

        case .reviewSummary(_, let text):
            guard !text.isEmpty else { break }
            state.entries.append(ChatEntry(
                id: nextID(sessionID, "review"),
                kind: .system,
                text: text,
                noticeKind: "review"
            ))

        case .backgroundComplete(let background):
            guard !background.text.isEmpty else { break }
            state.entries.append(ChatEntry(
                id: nextID(sessionID, "background"),
                kind: .notice,
                text: background.text,
                noticeKind: "background"
            ))

        case .errorEvent(_, let message):
            // BUG-068B: a late error from the turn the user stopped would rewrite the finalised
            // "interrupted" bubble and clear prompt queues that belong to the next turn.
            guard !latched else { break }
            state.isBusy = false
            state.turnStartedLocally = false
            state.turnStartedAt = nil
            state.needsInput = false
            state.pendingApprovals.removeAll()
            state.clarify = nil
            state.sudo = nil
            state.secret = nil
            state.lastError = message
            dropStaleTodos(&state)
            if let index = streamingIndex(for: sessionID, in: state) {
                state.entries[index].isStreaming = false
                state.entries[index].status = "error"
                state.entries[index].errorText = message
            } else {
                state.entries.append(ChatEntry(
                    id: nextID(sessionID, "error"),
                    kind: .notice,
                    text: message,
                    status: "error",
                    errorText: message,
                    noticeKind: "error"
                ))
            }
            streamingEntryIDs[sessionID] = nil

        case .toolOutputRisk(let risk):
            // Findings are relayed verbatim, and never dropped: a band-only or `redacted`-only
            // event still reaches the card, and one arriving early is held rather than discarded.
            // Verbatim relay is the rule within a LIVE turn only — a risk arriving under the latch
            // belongs to the stopped turn and would band a card in the next one (BUG-068B).
            guard !latched else { break }
            guard risk.hasSignal else { break }
            if !attachRisk(risk, to: &state) { hold(risk, for: sessionID) }

        case .gatewayReady, .sessionsChanged, .skinChanged, .other:
            // Skin is a presentation concern owned by AppModel/Theme, not turn state.
            break
        }

        states[sessionID] = state
    }

    // MARK: Turn transitions

    private func sealInterim(sessionID: String, state: inout SessionTurnState, text: String) {
        if let index = streamingIndex(for: sessionID, in: state) {
            if !text.isEmpty { state.entries[index].text = text }
            state.entries[index].isStreaming = false
            state.entries[index].isInterim = true
        } else if !text.isEmpty {
            state.entries.append(ChatEntry(
                id: nextID(sessionID, "assistant"),
                kind: .assistant,
                text: text,
                isInterim: true
            ))
        }
        streamingEntryIDs[sessionID] = nil
    }

    private func settleTurn(
        sessionID: String,
        state: inout SessionTurnState,
        event: MessageCompleteEvent,
        latched: Bool
    ) {
        state.isBusy = false
        state.turnStartedLocally = false
        state.turnStartedAt = nil
        state.needsInput = false
        state.statusText = ""
        state.pendingApprovals.removeAll()
        state.clarify = nil
        state.sudo = nil
        state.secret = nil
        state.terminalRead = nil
        // Risk signals are scoped to their turn; anything still held can only mis-attach later.
        heldRisks[sessionID] = nil
        dropStaleTodos(&state)
        // Drop deltas buffered between the interrupt and this frame so no flush seeds a bubble.
        buffers[sessionID] = nil

        // Late completion of an already-cancelled turn: settle the flags and bail without applying
        // the text, then RELEASE the latch — this frame is that turn's end, so anything after it
        // belongs to a different turn and must render rather than vanish.
        if latched {
            if let index = streamingIndex(for: sessionID, in: state) {
                state.entries[index].isStreaming = false
            }
            state.interrupted = false
            interruptedAt[sessionID] = nil
            streamingEntryIDs[sessionID] = nil
            return
        }

        state.interrupted = false

        let finalText = event.displayText
        let failure = event.isError
            ? (event.error.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? (finalText.isEmpty ? "Hermes reported an error" : finalText)
                : event.error)
            : ""

        var targetIndex = streamingIndex(for: sessionID, in: state)
        if targetIndex == nil {
            // Settle onto a trailing interim bubble when the final text continues it (reference §3.6).
            if let last = state.entries.indices.last,
               state.entries[last].kind == .assistant,
               state.entries[last].isInterim,
               Self.continues(interim: state.entries[last].text, final: finalText) {
                targetIndex = last
                state.entries[last].isInterim = false
            }
        }

        if let index = targetIndex {
            // The final frame is authoritative when it carries text; an empty one keeps what streamed.
            if !finalText.isEmpty {
                state.entries[index].text = finalText
            }
            state.entries[index].isStreaming = false
            state.entries[index].isInterim = false
            state.entries[index].status = event.status
            state.entries[index].errorText = failure
            state.entries[index].isPartial = event.partial
            // Assigned unconditionally, including nil: a descriptor left over from the last failure
            // on this bubble would name the wrong layer (FEAT-016).
            state.entries[index].errorSurface = failure.isEmpty ? nil : event.errorSurface
        } else if !finalText.isEmpty || !failure.isEmpty {
            state.entries.append(ChatEntry(
                id: nextID(sessionID, "assistant"),
                kind: .assistant,
                text: finalText,
                status: event.status,
                errorText: failure,
                isPartial: event.partial,
                errorSurface: failure.isEmpty ? nil : event.errorSurface
            ))
        }

        if event.isError { state.lastError = failure }
        streamingEntryIDs[sessionID] = nil
    }

    /// Either string being a prefix of the other means the final text continues the interim.
    static func continues(interim: String, final: String) -> Bool {
        guard !interim.isEmpty, !final.isEmpty else { return false }
        return final.hasPrefix(interim) || interim.hasPrefix(final)
    }

    // MARK: Tools

    private func upsertTool(sessionID: String, state: inout SessionTurnState, start: ToolStartEvent) {
        state.isBusy = true
        let id = stableToolID(start.toolID, name: start.name)
        if let index = toolIndex(in: state, id: id, name: start.name, requireRunning: true) {
            var activity = state.entries[index].tool
            let resolvedContext = start.context.isEmpty ? (activity?.context ?? "") : start.context
            activity?.context = resolvedContext
            if !start.argsText.isEmpty { activity?.argsText = start.argsText }
            state.entries[index].tool = activity
            drainHeldRisks(sessionID: sessionID, state: &state)
            return
        }
        // Seal a streaming bubble that holds only reasoning so the card renders beneath it; safe
        // only while the bubble has no text, which `message.complete` would otherwise duplicate.
        if let index = streamingIndex(for: sessionID, in: state), state.entries[index].text.isEmpty {
            state.entries[index].isStreaming = false
            streamingEntryIDs[sessionID] = nil
        }
        let activity = ToolActivity(
            id: id,
            name: start.name,
            context: start.context,
            argsText: start.argsText,
            isRunning: true
        )
        state.entries.append(ChatEntry(
            id: nextID(sessionID, "tool"),
            kind: .tool,
            tool: activity
        ))
        drainHeldRisks(sessionID: sessionID, state: &state)
    }

    private func completeTool(sessionID: String, state: inout SessionTurnState, event: ToolCompleteEvent) {
        let id = event.toolID.isEmpty ? "" : event.toolID
        let index = toolIndex(in: state, id: id, name: event.name, requireRunning: true)
            ?? toolIndex(in: state, id: id, name: event.name, requireRunning: false)
        guard let index, var activity = state.entries[index].tool else {
            // A completion with no matching start still deserves a card.
            let activity = ToolActivity(
                id: id.isEmpty ? syntheticToolID(name: event.name) : id,
                name: event.name,
                resultText: event.resultText,
                errorText: event.error,
                inlineDiff: event.inlineDiff,
                durationSeconds: event.durationSeconds,
                isRunning: false,
                todos: event.todos
            )
            state.entries.append(ChatEntry(id: nextID(sessionID, "tool"), kind: .tool, tool: activity))
            applyTodos(event, to: &state)
            drainHeldRisks(sessionID: sessionID, state: &state)
            return
        }
        activity.resultText = event.resultText.isEmpty ? event.summary : event.resultText
        activity.errorText = event.error
        activity.inlineDiff = event.inlineDiff
        activity.durationSeconds = event.durationSeconds
        activity.isRunning = false
        activity.todos = event.todos ?? activity.todos
        state.entries[index].tool = activity
        applyTodos(event, to: &state)
        drainHeldRisks(sessionID: sessionID, state: &state)
        // A clarify tool completing clears the "needs input" flag it raised.
        if event.name == "clarify" { state.clarify = nil }
        state.needsInput = state.hasBlockingPrompt
    }

    /// Three-tier correlation: exact id, else the newest pending row with that tool name, else any
    /// row with it (reference §3.4).
    private func toolIndex(
        in state: SessionTurnState,
        id: String,
        name: String,
        requireRunning: Bool
    ) -> Int? {
        if !id.isEmpty,
           let exact = state.entries.lastIndex(where: { $0.kind == .tool && $0.tool?.id == id }) {
            return exact
        }
        guard !name.isEmpty else { return nil }
        return state.entries.lastIndex {
            $0.kind == .tool && $0.tool?.name == name && (!requireRunning || $0.tool?.isRunning == true)
        }
    }

    // MARK: Session activity — the composer's status strip

    /// The todo reducer: whole-list replacement, never a merge, re-sort or re-dedupe — the wire
    /// order is the user's priority order, and `nil` means "no typed data on this frame", not "no plan".
    private func applyTodos(_ event: ToolCompleteEvent, to state: inout SessionTurnState) {
        // BUG-145: either spelling of the plan tool's registry name.
        guard TodoList.isPlanTool(event.name), let todos = event.todos else { return }
        state.activity.todos = todos
        state.activity.enforceBounds()
    }

    /// Turn end drops an active plan and keeps a finished one until the next `message.start`;
    /// deliberately silent about `subagents`, where a running row is kept alive on purpose.
    private func dropStaleTodos(_ state: inout SessionTurnState) {
        if state.activity.todos.isActive { state.activity.todos = TodoList() }
    }

    // MARK: Output risk

    /// Attach a `tool.output_risk` signal to its card, correlating the three ways `tool.complete`
    /// does — exact id alone misses a card given a synthetic `live-tool:` id.
    private func attachRisk(_ risk: ToolOutputRiskEvent, to state: inout SessionTurnState) -> Bool {
        guard let index = toolIndex(in: state, id: risk.toolID, name: risk.name, requireRunning: false),
              var activity = state.entries[index].tool
        else { return false }
        // Never clear findings already shown: a later band-only event must not erase a warning.
        if !risk.findings.isEmpty { activity.outputRiskFindings = risk.findings }
        if !risk.risk.isEmpty { activity.outputRisk = risk.risk }
        if risk.redacted { activity.outputRiskRedacted = true }
        state.entries[index].tool = activity
        return true
    }

    /// A risk event can beat its card: with tool progress off the card is only materialised at
    /// `tool.complete`, after the output scan, so hold the signal until a card can match it.
    private func hold(_ risk: ToolOutputRiskEvent, for sessionID: String) {
        var held = heldRisks[sessionID] ?? []
        held.append(risk)
        // Bounded: anything unmatched after this many tool events never will be, and a queue leaks.
        if held.count > Self.heldRiskLimit { held.removeFirst(held.count - Self.heldRiskLimit) }
        heldRisks[sessionID] = held
    }

    /// Retry every held signal against the rows that now exist.
    private func drainHeldRisks(sessionID: String, state: inout SessionTurnState) {
        guard let held = heldRisks[sessionID], !held.isEmpty else { return }
        let unmatched = held.filter { !attachRisk($0, to: &state) }
        heldRisks[sessionID] = unmatched.isEmpty ? nil : unmatched
    }

    private func stableToolID(_ raw: String, name: String) -> String {
        raw.isEmpty ? syntheticToolID(name: name) : raw
    }

    private func syntheticToolID(name: String) -> String {
        syntheticToolCounter += 1
        return "live-tool:\(name):\(syntheticToolCounter)"
    }

    // MARK: - Flushing

    /// Apply every buffered delta. Returns the sessions whose entries changed.
    @discardableResult
    public func flush() -> Set<String> {
        guard !buffers.isEmpty else { return [] }
        var touched: Set<String> = []
        // Snapshot the keys: `flush(sessionID:)` mutates `buffers`.
        for sessionID in Array(buffers.keys) {
            if flush(sessionID: sessionID) { touched.insert(sessionID) }
        }
        buffers.removeAll()
        return touched
    }

    @discardableResult
    public func flush(sessionID: String) -> Bool {
        guard let buffer = buffers.removeValue(forKey: sessionID) else { return false }
        guard !buffer.assistant.isEmpty || !buffer.reasoning.isEmpty || buffer.reasoningReplaces else {
            return false
        }
        // BUG-018: taken OUT of the dictionary, not copied from it — a copy leaves the storage
        // multiply referenced, so every `+=` below reallocates the whole accumulated string.
        var state = states.removeValue(forKey: sessionID) ?? SessionTurnState()
        let index = ensureStreamingEntry(sessionID: sessionID, state: &state)
        if !buffer.assistant.isEmpty {
            state.entries[index].text += buffer.assistant
        }
        if buffer.reasoningReplaces {
            // A late `reasoning.available` must not wipe a reply that already started (reference §3.3)…
            if state.entries[index].text.isEmpty {
                // …and must not SHORTEN a trace this client accumulated: some emitters send a
                // truncated summary, and the deltas that built the full trace are gone (BUG-017).
                if buffer.reasoning.count >= state.entries[index].reasoning.count {
                    state.entries[index].reasoning = buffer.reasoning
                    stampReasoning(on: &state.entries[index], from: buffer)
                }
            }
        } else if !buffer.reasoning.isEmpty {
            state.entries[index].appendReasoning(buffer.reasoning)
            stampReasoning(on: &state.entries[index], from: buffer)
        }
        states[sessionID] = state
        return true
    }

    /// Carry the buffer's stamps onto the entry: the start is written once, the end moves forward
    /// with every flush that carries reasoning, so `settleTurn` needs no hook.
    private func stampReasoning(on entry: inout ChatEntry, from buffer: DeltaBuffer) {
        guard let first = buffer.reasoningFirstAt else { return }
        if entry.reasoningStartedAt == nil { entry.reasoningStartedAt = first }
        entry.reasoningEndedAt = buffer.reasoningLastAt ?? first
    }

    private func streamingIndex(for sessionID: String, in state: SessionTurnState) -> Int? {
        guard let id = streamingEntryIDs[sessionID] else { return nil }
        return state.entries.firstIndex { $0.id == id }
    }

    /// One streaming bubble per session, created lazily so tool cards preceding text render above it.
    private func ensureStreamingEntry(sessionID: String, state: inout SessionTurnState) -> Int {
        if let index = streamingIndex(for: sessionID, in: state) { return index }
        let entry = ChatEntry(
            id: nextID(sessionID, "assistant"),
            kind: .assistant,
            isStreaming: true
        )
        state.entries.append(entry)
        streamingEntryIDs[sessionID] = entry.id
        return state.entries.count - 1
    }

    private func nextID(_ sessionID: String, _ prefix: String) -> String {
        entryCounter += 1
        return "\(sessionID)#\(prefix)\(entryCounter)"
    }

    // MARK: - Resume projection

    /// Project a `session.resume` snapshot onto the live state; `inflight` is the only carrier of a
    /// terminal frame lost while disconnected, deduped against the trailing run of user rows
    /// (reference §7.1). `activity` starts empty and is deliberately not rehydrated, because the
    /// REST transcript truncates tool results at 4,000 chars and a large plan arrives unparseable.
    public func applyResumeProjection(
        sessionID: String,
        result: SessionResumeResult,
        trailingUserTexts: [String]
    ) {
        var state = state(for: sessionID)
        state.autoContinue = result.autoContinue
        state.title = result.info.title.isEmpty ? state.title : result.info.title
        state.info = result.info
        // The payload's own key first: a lazily-resumed session's `info` never carries one.
        state.turnStartedAt = result.turnStartedAt ?? result.info.turnStartedAt
        state.interrupted = false

        if let inflight = result.inflight {
            let normalized = inflight.user.trimmingCharacters(in: .whitespacesAndNewlines)
            let alreadyPersisted = trailingUserTexts.contains {
                $0.trimmingCharacters(in: .whitespacesAndNewlines) == normalized
            }
            if !normalized.isEmpty, !alreadyPersisted {
                state.entries.append(ChatEntry(
                    id: nextID(sessionID, "user"),
                    kind: .user,
                    text: inflight.user
                ))
            }
            // Corrections become their own bubbles between prompt and reply.
            for correction in inflight.corrections where !correction.isEmpty {
                state.entries.append(ChatEntry(
                    id: nextID(sessionID, "user"),
                    kind: .user,
                    text: correction,
                    noticeKind: "correction"
                ))
            }
            if !inflight.assistant.isEmpty || inflight.isFailure {
                let entry = ChatEntry(
                    id: nextID(sessionID, "assistant"),
                    kind: .assistant,
                    text: inflight.assistant,
                    isStreaming: inflight.streaming && !inflight.isFailure,
                    status: inflight.isFailure ? "error" : "",
                    errorText: inflight.error,
                    // FEAT-016: the resume path carries the live frame's descriptor.
                    errorSurface: inflight.isFailure ? inflight.errorSurface : nil
                )
                state.entries.append(entry)
                streamingEntryIDs[sessionID] = inflight.streaming && !inflight.isFailure ? entry.id : nil
                if inflight.streaming { pinnedSessionID = sessionID }
            }
            state.isBusy = inflight.streaming && !inflight.isFailure
            if inflight.isFailure { state.lastError = inflight.error }
        } else {
            state.isBusy = result.running
        }
        // A resume rebinds the event transport to us, so a turn still running is ours to steer.
        if state.isBusy { state.turnStartedLocally = true }

        if let queued = result.queued, !queued.isEmpty {
            state.entries.append(ChatEntry(
                id: nextID(sessionID, "user"),
                kind: .user,
                text: queued,
                noticeKind: "queued"
            ))
        }

        if result.autoContinue != nil {
            state.entries.append(ChatEntry(
                id: nextID(sessionID, "notice"),
                kind: .notice,
                text: "Hermes is automatically resuming a turn that was interrupted when the backend restarted.",
                noticeKind: "auto_continue"
            ))
            state.isBusy = true
            state.turnStartedLocally = true
        }

        // BUG-066 — the blocking prompt the gateway is still parked on. The resume payload is the
        // only place a prompt raised during the outage can come from; the gateway does not re-emit
        // the event frame to the reattached transport. Set-only and tri-state on purpose: `nil`
        // means nothing is pending, not "clear whatever the live-event path just raised".
        if let approval = result.pendingApproval {
            // Dedup by command: `ApprovalRequestEvent.id` is a client-side UUID, so an id-based
            // match would double-present the same prompt.
            if !state.pendingApprovals.contains(where: { $0.command == approval.command }) {
                state.pendingApprovals.append(approval)
            }
            state.needsInput = true
        }
        if let clarify = result.pendingClarify {
            if state.clarify == nil { state.clarify = clarify }
            state.needsInput = true
        }

        states[sessionID] = state
    }
}
