import Foundation

// MARK: - Rendered transcript model

/// One tool invocation card.
public struct ToolActivity: Identifiable, Sendable, Equatable, Codable {
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
public struct ChatEntry: Identifiable, Sendable, Equatable, Codable {
    public enum Kind: String, Sendable, Equatable, Codable {
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
    /// The durable SQLite row this user turn was written to: a REST transcript row's `id`, or the `user_row_id` a `prompt.submit` ack named. `truncate_before_row_id` addresses a turn by it; nil means the client never learned it.
    public var rowID: Int?

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

    /// The ceiling on one entry's streamed answer, in UTF-8 bytes (BUG-074): far above any model's
    /// output limit, so only a runaway stream or a stalled flush loop meets it. It bounds the STREAM;
    /// the authoritative `message.complete` text still replaces a bounded entry whole.
    public static let textLimit = 2 * 1024 * 1024
    /// Head-drop target, a quarter below the limit so a stream at the ceiling drops once, not per delta.
    static let textRetained = textLimit / 4 * 3
    /// What stands where a bounded stream's head was dropped.
    public static let textElision = "… earlier text dropped …\n"

    /// Append streamed answer text, bounded as `appendReasoning` bounds thinking: the head goes, not the tail.
    mutating func appendStreamedText(_ chunk: String) {
        guard !chunk.isEmpty else { return }
        text += chunk
        guard text.utf8.count > Self.textLimit else { return }
        text = Self.textElision + Self.utf8Tail(of: text, bytes: Self.textRetained)
    }

    /// The longest suffix of `text` within `bytes` UTF-8 bytes, cut on a scalar boundary.
    static func utf8Tail(of text: String, bytes: Int) -> String {
        let utf8 = text.utf8
        guard utf8.count > bytes else { return text }
        var start = utf8.index(utf8.endIndex, offsetBy: -bytes)
        // Step off continuation bytes (10xxxxxx) so the cut never splits a scalar.
        while start < utf8.endIndex, (utf8[start] & 0xC0) == 0x80 {
            start = utf8.index(after: start)
        }
        return String(text.unicodeScalars[start...])
    }

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
        reasoningEndedAt: Date? = nil,
        rowID: Int? = nil
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
        self.rowID = rowID
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
    // Only the current execution: durable text already displayed plus live segments.
    var persistedAssistantPrefix = ""
    var assistantSegmentIDs: [String] = []
    public var executionID: String?
    public var turnOwnership: TurnOwnership = .unknown
    var observedExecutions: [String] = []
    var observedInputIDs: Set<String> = []
    public var submissionRevision = -1
    public var queuedInputIDs: Set<String> = []
    public var queuedInputsComplete = false
    public var inputOutcomes: [String: String] = [:]
    public var submissionDispositions: [String: String] = [:]
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
    /// Display queue; identified legacy requests retain their server occurrence ID.
    public var pendingApprovals: [ApprovalRequestEvent] = []
    public var clarify: ClarifyRequestEvent?
    public var sudo: SudoRequestEvent?
    public var secret: SecretRequestEvent?
    public var terminalRead: TerminalReadRequestEvent?
    /// The open `manage_connections` card. Deliberately outside `hasBlockingPrompt`, like `terminalRead`: it is answered by a card in the chat, never by the approval sheet, and the agent keeps the turn while it waits.
    public var connection: ConnectionRequest?
    /// The session's goal, loop and heartbeat state as the last `session.control.update` pushed it; nil until one arrives, and the read on open belongs to the app, not the engine.
    public var control: SessionControlSnapshot?
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
        /// `assistant` overflowed and lost its head before a flush, so everything already on the
        /// entry is older than what was dropped (BUG-074).
        var assistantHeadDropped = false
        var reasoning = ""

        /// Bounded like the entry it feeds: a stalled flush loop must not let the buffer hold it all.
        mutating func appendAssistant(_ chunk: String) {
            assistant += chunk
            guard assistant.utf8.count > ChatEntry.textLimit else { return }
            assistant = ChatEntry.utf8Tail(of: assistant, bytes: ChatEntry.textRetained)
            assistantHeadDropped = true
        }
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
    // Latest transport projection, including authoritative empty updates. Transcript replay
    // may replace turn state, but cannot decide whether a current server request is open.
    private var currentServerRequests: [String: [ServerRequest]] = [:]
    public private(set) var eventRevision: UInt64 = 0
    private let recovery = SessionEventRecovery()
    private let observer = SharedSessionObserver()
    public var sharedSessionSupported: Bool { !observer.socketID.isEmpty }
    public func setSharedSession(_ value: JSONValue?) {
        observer.socketID = value?["version"]?.coercedInt == 1 ? value?["socket_id"]?.coercedString ?? "" : ""
    }
    public func registerSubmission(sessionID: String, ref: String, entryID: String) {
        observer.register(sessionID: sessionID, ref: ref, entryID: entryID)
    }
    public func acknowledgeSubmission(sessionID: String, ack: PromptAck) {
        observer.acknowledge(sessionID: sessionID, ack: ack)
    }
    public func setReplayEpoch(_ epoch: String) {
        if recovery.epoch != epoch {
            observer.resetEpoch()
            for sid in Array(states.keys) {
                states[sid]?.executionID = nil
                states[sid]?.turnOwnership = .unknown
                states[sid]?.observedExecutions = []
                states[sid]?.observedInputIDs = []
                states[sid]?.submissionRevision = -1
                states[sid]?.queuedInputIDs = []
                states[sid]?.queuedInputsComplete = false
                states[sid]?.inputOutcomes = [:]
                states[sid]?.submissionDispositions = [:]
            }
        }
        recovery.setEpoch(epoch)
    }
    public func beginEventRecovery(sessionID: String) -> Int? { recovery.begin(sessionID) }
    @discardableResult
    public func finishEventRecovery(sessionID: String, replay: SessionEventReplay?, checkpoint: TurnCheckpoint? = nil, resumeSnapshot: SessionResumeResult? = nil) -> Bool {
        let validCheckpoint = checkpoint == nil || (checkpoint?.epoch == recovery.epoch && checkpoint?.sessionID == sessionID)
        let result = recovery.finish(sessionID, replay: validCheckpoint ? replay : nil)
        if result.complete, let checkpoint {
            var restored = SessionTurnState()
            restored.entries = checkpoint.entries
            restored.persistedAssistantPrefix = checkpoint.persistedAssistantPrefix
            restored.assistantSegmentIDs = checkpoint.assistantSegmentIDs
            restored.executionID = checkpoint.executionID
            restored.observedExecutions = checkpoint.observedExecutions
            restored.observedInputIDs = checkpoint.observedInputIDs
            restored.turnStartedAt = checkpoint.turnStartedAt
            restored.isBusy = true
            states[sessionID] = restored
            observer.restoreCheckpoint(checkpoint)
            streamingEntryIDs[sessionID] = checkpoint.streamingEntryID
            entryCounter = max(entryCounter, checkpoint.entryCounter)
            syntheticToolCounter = max(syntheticToolCounter, checkpoint.syntheticToolCounter)
            pinnedSessionID = sessionID
        }
        var crossedTurnBoundary = false
        var replayedMetadata = false
        for event in result.events {
            guard apply(event) != nil, let checkpoint,
                  (event.params["seq"]?.coercedInt ?? 0) > checkpoint.sequence else { continue }
            if ["message.start", "message.complete", "error"].contains(event.type) {
                crossedTurnBoundary = true
            }
            if event.type == "session.info" || event.type == "session.title" { replayedMetadata = true }
        }
        flush(sessionID: sessionID)
        if result.complete, checkpoint != nil, let resumeSnapshot, resumeSnapshot.sessionID == sessionID {
            // The snapshot predates this replay. A current prompt after a turn boundary has
            // its own request in the complete suffix; an old snapshot must not revive one.
            applyResumeProjection(sessionID: sessionID, result: resumeSnapshot, trailingUserTexts: [],
                preserveTranscript: true, hydratePendingPrompts: !crossedTurnBoundary,
                preserveCurrentMetadata: crossedTurnBoundary || replayedMetadata)
        }
        // Apply the freshest transport projection after every replayed terminal/start frame
        // and legacy snapshot hydration. A cancellation received during recovery stays empty.
        projectCurrentServerRequests(sessionID: sessionID)
        // Do not discard frames received while the RPC was in flight even if
        // replay failed. Also never advance past a gap and call it recovered.
        if !result.complete { recovery.forget(sessionID) }
        return result.complete
    }

    public func checkpoint(sessionID: String) -> TurnCheckpoint? {
        guard !recovery.epoch.isEmpty, let sequence = recovery.watermarks[sessionID],
              state(for: sessionID).isBusy, !state(for: sessionID).interrupted,
              heldRisks[sessionID]?.isEmpty != false else { return nil }
        // The cursor must never cover text still waiting in the coalescing buffer.
        flush(sessionID: sessionID)
        let state = state(for: sessionID)
        return TurnCheckpoint(sessionID: sessionID, epoch: recovery.epoch, sequence: sequence,
            entries: state.entries, persistedAssistantPrefix: state.persistedAssistantPrefix,
            assistantSegmentIDs: state.assistantSegmentIDs, executionID: state.executionID,
            observedExecutions: state.observedExecutions, observedInputIDs: state.observedInputIDs,
            turnStartedAt: state.turnStartedAt, streamingEntryID: streamingEntryIDs[sessionID],
            entryCounter: entryCounter, syntheticToolCounter: syntheticToolCounter,
            references: observer.checkpointReferences(sessionID), bindings: observer.checkpointBindings(sessionID))
    }

    /// Hold new arrivals before the resume RPC can attach this socket. Import the saved display
    /// only after replay proves that no event between the checkpoint and now has been lost.
    public func beginCheckpointRecovery(_ checkpoint: TurnCheckpoint) -> Bool {
        guard checkpoint.epoch == recovery.epoch, !checkpoint.epoch.isEmpty,
              states[checkpoint.sessionID]?.entries.isEmpty != false,
              checkpoint.sequence > 0 else { return false }
        recovery.watermarks[checkpoint.sessionID] = checkpoint.sequence
        return recovery.begin(checkpoint.sessionID) != nil
    }
    private var buffers: [String: DeltaBuffer] = [:]
    /// Risk signals whose tool card did not exist yet, per session.
    private var heldRisks: [String: [ToolOutputRiskEvent]] = [:]
    /// When Stop was last pressed, per session; `state.interrupted` records that it was.
    private var interruptedAt: [String: Date] = [:]
    /// Id of the assistant entry currently accumulating text, per session.
    private var streamingEntryIDs: [String: String] = [:]
    /// The session that received the most recent `message.start`.
    private(set) public var pinnedSessionID: String? {
        // Any other writer of the pin supersedes the optimistic claim a send made on it.
        didSet { pinClaim = nil }
    }
    /// The pin as `appendUserEntry` set it: which entry claimed it and what it displaced, so the
    /// rollback of that one send can undo exactly its own claim and nothing else (BUG-146).
    private struct PinClaim {
        let sessionID: String
        let entryID: String
        let displaced: String?
    }
    private var pinClaim: PinClaim?
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
        if state.terminalRead != nil || state.connection != nil { return false }
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

    public func reset(sessionID: String, preserveServerRequests: Bool = false) {
        recovery.forget(sessionID)
        if !preserveServerRequests { currentServerRequests[sessionID] = nil }
        states[sessionID] = SessionTurnState()
        if preserveServerRequests { projectCurrentServerRequests(sessionID: sessionID) }
        buffers[sessionID] = nil
        streamingEntryIDs[sessionID] = nil
        heldRisks[sessionID] = nil
        interruptedAt[sessionID] = nil
        if pinnedSessionID == sessionID { pinnedSessionID = nil }
    }

    public func forget(sessionID: String) {
        observer.forget(sessionID)
        recovery.forget(sessionID)
        currentServerRequests[sessionID] = nil
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
        let displaced = pinnedSessionID
        pinnedSessionID = sessionID
        // After the assignment: the pin's own `didSet` clears any claim.
        pinClaim = PinClaim(sessionID: sessionID, entryID: entry.id, displaced: displaced)
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
        // Undo only this send's own claim on the pin, restoring what it displaced. A pin that a
        // `message.start`, a resume or a later send set since belongs to them, and a turn running on
        // this session before the send keeps its unscoped target (BUG-146).
        if let claim = pinClaim, claim.entryID == entryID, claim.sessionID == sessionID, pinnedSessionID == sessionID {
            // A displaced session forgotten meanwhile is not restored as a routing target.
            pinnedSessionID = claim.displaced.flatMap { states[$0] != nil ? $0 : nil }
        }
    }

    /// Record the durable row a `prompt.submit` ack named for this send's user entry, so a later Retry or Edit can address the turn (`user_row_id`).
    public func setRowID(sessionID: String, entryID: String, rowID: Int) {
        guard var state = states[sessionID],
              let index = state.entries.firstIndex(where: { $0.id == entryID }) else { return }
        state.entries[index].rowID = rowID
        states[sessionID] = state
    }

    /// After a replacing submit is accepted: drop the superseded live rows, from `firstEntryID` (or the start of the live list when nil) up to but not including `keepEntryID`, the replacement's own bubble. A no-op unless both ends are present in that order, so nothing goes when the replacement is not on screen.
    public func dropEntries(sessionID: String, from firstEntryID: String?, before keepEntryID: String) {
        guard var state = states[sessionID],
              let end = state.entries.firstIndex(where: { $0.id == keepEntryID }) else { return }
        var start = 0
        if let firstEntryID {
            guard let found = state.entries.firstIndex(where: { $0.id == firstEntryID }), found < end else { return }
            start = found
        }
        guard start < end else { return }
        let removed = Set(state.entries[start..<end].map(\.id))
        state.entries.removeSubrange(start..<end)
        state.assistantSegmentIDs.removeAll { removed.contains($0) }
        if let streaming = streamingEntryIDs[sessionID], removed.contains(streaming) {
            streamingEntryIDs[sessionID] = nil
        }
        states[sessionID] = state
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
        // The backend settles the operation as `interrupt` on the same Stop (`ConnectionSettleReason`).
        state.connection = nil
        // Stop clears the whole surface unconditionally, finished or not.
        state.activity = state.activity.clearedForStop()
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

    /// Fold a `subagent.list` answer into a tracked session's roster, stamped with the origin rule live frames use; answers whether anything changed.
    @discardableResult
    public func reconcileSubagents(sessionID: String, roster: SubagentRoster, observedAt: Date) -> Bool {
        guard var state = states[sessionID] else { return false }
        let changed = state.activity.reconcile(roster, observedAt: observedAt,
                                               turnStartedLocally: state.turnStartedLocally, sessionID: sessionID)
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
        state.connection = nil
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

    /// `approval.cancelled`: drop the cards for approvals the backend already deny-resolved. Named
    /// entries go by queue id, whichever path delivered them (a current server request is also
    /// retired by `HermesClient`, so its projection agrees); `request_ids` omits id-less entries, so
    /// the count's remainder takes that many id-less legacy cards, oldest first.
    private func withdrawCancelledApprovals(_ cancelled: ApprovalCancelledEvent, from state: inout SessionTurnState) {
        let named = Set(cancelled.requestIDs)
        var unnamed = max(0, cancelled.cancelledCount - cancelled.requestIDs.count)
        var kept: [ApprovalRequestEvent] = []
        for approval in state.pendingApprovals {
            if let queueID = approval.queueRequestID {
                if named.contains(queueID) { continue }
            } else if approval.serverRequest == nil, unnamed > 0 {
                unnamed -= 1
                continue
            }
            kept.append(approval)
        }
        state.pendingApprovals = kept
        state.needsInput = state.hasBlockingPrompt
    }

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

    private func projectCurrentServerRequests(sessionID: String) {
        guard let requests = currentServerRequests[sessionID] else { return }
        var state = state(for: sessionID)
        state.pendingApprovals.removeAll { $0.serverRequest != nil }
        state.pendingApprovals.append(contentsOf: requests.compactMap(\.approval))
        if state.clarify?.serverRequest != nil { state.clarify = nil }
        if state.sudo?.serverRequest != nil { state.sudo = nil }
        if state.secret?.serverRequest != nil { state.secret = nil }
        state.clarify = requests.compactMap(\.clarify).first ?? state.clarify
        state.sudo = requests.compactMap(\.sudo).first ?? state.sudo
        state.secret = requests.compactMap(\.secret).first ?? state.secret
        state.needsInput = state.hasBlockingPrompt
        states[sessionID] = state
    }

    /// Apply one raw gateway event; nil for a global broadcast or a dropped unscoped `subagent.*`.
    @discardableResult
    public func apply(_ event: GatewayEvent, at moment: Date = Date()) -> String? {
        // Request state is transport-owned, not transcript replay or interrupt-latch state.
        if let requests = event.serverRequests, !event.sessionID.isEmpty {
            currentServerRequests[event.sessionID] = requests
            projectCurrentServerRequests(sessionID: event.sessionID)
            return event.sessionID
        }
        if recovery.hold(event) || !recovery.accepts(event) { return nil }
        let projected = HermesEvent.project(event)
        guard let sessionID = route(event) else {
            return nil
        }
        if projected.forcesFlush || event.type == "message.input" { flush(sessionID: sessionID) }
        var observed = state(for: sessionID)
        guard observer.consume(event, state: &observed) else { return nil }
        eventRevision &+= 1
        if event.type == "message.input", let index = streamingIndex(for: sessionID, in: observed) {
            observed.entries[index].isStreaming = false
            streamingEntryIDs[sessionID] = nil
        }
        states[sessionID] = observed
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
        if event.type == "approval.cancelled" {
            // A broadcast every client receives, naming its session in the payload; one for a
            // session this engine never tracked must not mint state for it.
            let named = event.sessionID.isEmpty ? (event.payload["session_id"]?.coercedString ?? "") : event.sessionID
            return !named.isEmpty && states[named] != nil ? named : nil
        }
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
            state.persistedAssistantPrefix = ""
            state.assistantSegmentIDs = []
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
                if state.executionID == nil { state.turnOwnership = origin == localOrigin ? .local : .other }
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
            buffer.appendAssistant(delta.text)
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
            if let requestID = request.legacyRequestID,
               state.pendingApprovals.contains(where: { $0.legacyRequestID == requestID }) { break }
            state.pendingApprovals.append(request)
            state.needsInput = true

        case .approvalCancelled(let cancelled):
            // Deliberately not behind the latch: a Stop's own deny-resolve is what announces this.
            withdrawCancelledApprovals(cancelled, from: &state)

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

        case .connectionRequest(let request):
            // A Stop leaves no turn to consent for, and the cancelled turn's own late request must not
            // park a card (Desktop drops it the same way, `gateway-event/input-requests.ts:55-60`).
            guard !latched else { break }
            if let current = state.connection, !current.isSupersededBy(request) { break }
            state.connection = request.settled ? nil : request

        case .connectionUpdate(let update):
            // Not behind the latch: the settlement a Stop produces is exactly what closes the card.
            let frame = update.snapshot
            if let current = state.connection {
                guard current.opID == frame.opID, current.isSupersededBy(frame) else { break }
                state.connection = frame.settled ? nil : frame
            } else if !frame.settled, !latched, state.isBusy {
                // A client that attached mid-operation never saw the request; every frame carries the
                // full snapshot. Only under a running turn, so a late frame cannot revive a finished one.
                state.connection = frame
            }

        case .sessionInfo(let info):
            state.info = info.info
            if !info.info.title.isEmpty { state.title = info.info.title }
            // Adopt-only — see `SessionTurnState.turnStartedAt`.
            if let started = info.info.turnStartedAt { state.turnStartedAt = started }
            // A manual compaction holds the session busy and ends with only this frame, `running: false`, no terminal frame. With nothing streaming, that is the turn's end; a chat resumed mid-compaction otherwise stays "working" until Stop.
            if !info.info.running, state.isBusy, !latched, streamingIndex(for: sessionID, in: state) == nil {
                state.isBusy = false
                state.turnStartedLocally = false
                state.turnStartedAt = nil
                state.statusText = ""
            }

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

        case .sideQuestionAnswer(let answer):
            // Not behind the latch: a side answer is not the stopped turn's output, and Desktop keeps it
            // as a persistent system line headed by its question (`gateway-event/status.ts:146-170`).
            let text = answer.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { break }
            let question = answer.question.trimmingCharacters(in: .whitespacesAndNewlines)
            state.entries.append(ChatEntry(
                id: nextID(sessionID, "btw"),
                kind: .system,
                text: question.isEmpty ? text : "On the side: “\(question)”\n\n\(text)",
                noticeKind: "btw"
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
            state.connection = nil
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

        case .sessionControlUpdate(let update):
            // Not behind the latch: automation state is the session's, not the stopped turn's output.
            state.control = update.control

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
            let id = nextID(sessionID, "assistant")
            state.assistantSegmentIDs.append(id)
            state.entries.append(ChatEntry(
                id: id,
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
        // The tool returns only once its operation settles, so a finished turn has no card left to answer.
        state.connection = nil
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

        var finalText = event.displayText
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

        // A resumed snapshot or a backend completion may contain the whole run,
        // while other completions contain only the final response. Remove only
        // an exact prefix already displayed by this execution, never global text.
        let targetID = targetIndex.map { state.entries[$0].id }
        let prefix = state.persistedAssistantPrefix + state.entries.filter {
            state.assistantSegmentIDs.contains($0.id) && $0.id != targetID
        }.map(\.text).joined()
        if !prefix.isEmpty, finalText.hasPrefix(prefix) {
            finalText = String(finalText.dropFirst(prefix.count))
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

    /// Only a newly appended tool closes the preceding assistant segment. A
    /// completion updating an older card must not split the current response.
    private func sealAssistantBeforeNewTool(sessionID: String, state: inout SessionTurnState) {
        if let index = streamingIndex(for: sessionID, in: state) {
            state.entries[index].isStreaming = false
        }
        streamingEntryIDs[sessionID] = nil
    }

    private func upsertTool(sessionID: String, state: inout SessionTurnState, start: ToolStartEvent) {
        state.isBusy = true
        let id = stableToolID(start.toolID, name: start.name)
        if let index = toolIndex(in: state, id: id, name: start.name, requireRunning: true) {
            var activity = state.entries[index].tool
            let resolvedContext = start.context.isEmpty ? (activity?.context ?? "") : start.context
            if let current = activity { activity?.id = correlatedToolID(current.id, incoming: start.toolID) }
            activity?.context = resolvedContext
            if !start.argsText.isEmpty { activity?.argsText = start.argsText }
            state.entries[index].tool = activity
            drainHeldRisks(sessionID: sessionID, state: &state)
            return
        }
        sealAssistantBeforeNewTool(sessionID: sessionID, state: &state)
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
        guard let index, var activity = state.entries[index].tool else {
            // A missed start (for example during reconnect) still establishes a
            // boundary: subsequent thinking belongs after this completed tool.
            sealAssistantBeforeNewTool(sessionID: sessionID, state: &state)
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
        activity.id = correlatedToolID(activity.id, incoming: event.toolID)
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

    /// Exact wire identity wins, including duplicate completions of settled calls.
    /// Name fallback supports legacy missing IDs, but never merges different real IDs.
    /// Completions may name-match only pending calls; risk signals may arrive later.
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
            guard $0.kind == .tool, let tool = $0.tool, tool.name == name,
                  !requireRunning || tool.isRunning else { return false }
            return id.isEmpty || id.hasPrefix("live-tool:") || tool.id.hasPrefix("live-tool:")
        }
    }

    /// Retain the first real identity learned through legacy correlation. The
    /// enclosing ChatEntry keeps its stable UI identity and transcript position.
    private func correlatedToolID(_ current: String, incoming: String) -> String {
        guard current.hasPrefix("live-tool:"), !incoming.isEmpty,
              !incoming.hasPrefix("live-tool:") else { return current }
        return incoming
    }

    // MARK: Session activity — the composer's status strip

    /// The todo reducer: whole-list replacement, never a merge, re-sort or re-dedupe — the wire
    /// order is the user's priority order, and `nil` means "no typed data on this frame", not "no plan".
    private func applyTodos(_ event: ToolCompleteEvent, to state: inout SessionTurnState) {
        // BUG-145: either spelling of the plan tool's registry name.
        guard TodoList.isPlanTool(event.name), let todos = event.todos else { return }
        state.activity.todos = todos
        // A frame without a counter keeps the last known one; it cannot order anything itself.
        if let revision = event.todoRevision { state.activity.todoRevision = revision }
        state.activity.enforceBounds()
    }

    /// FEAT-037 — seed the plan from the backend's own snapshot. A starting value, never a rival:
    /// it is taken only when nothing newer is known, ordered by the store's revision, and then put
    /// through the same turn-end rule the live path applies, so an unfinished plan on a session whose
    /// turn is over is dropped exactly as `settleTurn` would have dropped it.
    private func seedTodos(_ snapshot: TodoSnapshot, into state: inout SessionTurnState) {
        if let known = state.activity.todoRevision {
            guard let revision = snapshot.revision, revision > known else { return }
        } else if !state.activity.todos.isEmpty {
            // A live plan with no counter to compare against outranks a snapshot.
            return
        }
        state.activity.todos = snapshot.todos
        state.activity.todoRevision = snapshot.revision
        if !state.isBusy { dropStaleTodos(&state) }
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
        activity.id = correlatedToolID(activity.id, incoming: risk.toolID)
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
        if buffer.assistantHeadDropped {
            // The buffer overflowed before this flush: what the entry holds is older than the head
            // the buffer already dropped, so the buffer's tail replaces it (BUG-074).
            state.entries[index].text = ChatEntry.textElision + buffer.assistant
        } else if !buffer.assistant.isEmpty {
            state.entries[index].appendStreamedText(buffer.assistant)
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
        state.assistantSegmentIDs.append(entry.id)
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
    /// (reference §7.1). The plan in `activity` is seeded from the payload's own `todo_state` when
    /// the backend sends one (FEAT-037), never parsed out of the REST transcript, which truncates
    /// tool results at 4,000 chars so a large plan arrives unparseable; subagent rows are not rehydrated.
    public func applyResumeProjection(
        sessionID: String,
        result: SessionResumeResult,
        trailingUserTexts: [String],
        history: [ChatEntry] = [],
        preserveTranscript: Bool = false,
        hydratePendingPrompts: Bool = true,
        preserveCurrentMetadata: Bool = false
    ) {
        var state = state(for: sessionID)
        if !preserveCurrentMetadata {
            state.autoContinue = result.autoContinue
            state.title = result.info.title.isEmpty ? state.title : result.info.title
            state.info = result.info
            // The payload's own key first: a lazily-resumed session's info may omit it.
            if !preserveTranscript || state.turnStartedAt == nil {
                state.turnStartedAt = result.turnStartedAt ?? result.info.turnStartedAt
            }
            // The latch and the Stop timestamp behind it go together: a timestamp left alone keeps
            // `isQuiescent` false for good, and the idle sweep never reclaims the session (BUG-146).
            state.interrupted = false
            interruptedAt[sessionID] = nil
        }

        if preserveTranscript {
            // Event replay owns the display/busy state; resume supplies only current metadata
            // and blocking prompts below. In particular its cumulative text is not a delta.
        } else if let inflight = result.inflight {
            let overlap = ResumeHistoryOverlap(history: history, inflight: inflight)
            state.persistedAssistantPrefix = overlap.assistantPrefix
            let displayUser = UserInputDisplay.project(inflight.user)
            let normalized = displayUser.body
            let alreadyPersisted = overlap.userPersisted || (history.isEmpty && trailingUserTexts.contains {
                $0.trimmingCharacters(in: .whitespacesAndNewlines) == normalized
            })
            if (!normalized.isEmpty || !displayUser.refs.isEmpty), !alreadyPersisted {
                state.entries.append(ChatEntry(
                    id: nextID(sessionID, "user"),
                    kind: .user,
                    text: displayUser.body,
                    imageRefs: displayUser.refs
                ))
            }
            var consumed = overlap.assistantPrefix.unicodeScalars.count
            let scalars = Array(inflight.assistant.unicodeScalars)
            func appendAssistant(until end: Int, final: Bool) {
                let stop = min(scalars.count, max(consumed, end))
                let text = String(String.UnicodeScalarView(scalars[consumed..<stop]))
                consumed = stop
                guard !text.isEmpty || (final && inflight.isFailure) else { return }
                let entry = ChatEntry(
                    id: nextID(sessionID, "assistant"),
                    kind: .assistant,
                    text: text,
                    isStreaming: final && inflight.streaming && !inflight.isFailure,
                    status: final && inflight.isFailure ? "error" : "",
                    errorText: final ? inflight.error : "",
                    // FEAT-016: the resume path carries the live frame's descriptor.
                    errorSurface: inflight.isFailure ? inflight.errorSurface : nil
                )
                state.entries.append(entry)
                state.assistantSegmentIDs.append(entry.id)
                streamingEntryIDs[sessionID] = entry.isStreaming ? entry.id : nil
                if inflight.streaming { pinnedSessionID = sessionID }
            }
            for (index, correction) in inflight.corrections.enumerated()
                where index >= overlap.correctionCount && !correction.isEmpty {
                if index < inflight.correctionOffsets.count {
                    appendAssistant(until: inflight.correctionOffsets[index], final: false)
                }
                state.entries.append(ChatEntry(id: nextID(sessionID, "user"), kind: .user,
                                               text: correction, noticeKind: "correction"))
            }
            appendAssistant(until: scalars.count, final: true)
            state.isBusy = inflight.streaming && !inflight.isFailure
            if state.isBusy { pinnedSessionID = sessionID }
            if inflight.isFailure { state.lastError = inflight.error }
        } else {
            state.isBusy = result.running
        }
        // A resume rebinds the event transport to us, so a turn still running is ours to steer.
        if state.isBusy && !preserveTranscript { state.turnStartedLocally = true }

        if !preserveTranscript, let queued = result.queued, !queued.isEmpty {
            state.entries.append(ChatEntry(
                id: nextID(sessionID, "user"),
                kind: .user,
                text: queued,
                noticeKind: "queued"
            ))
        }

        if !preserveTranscript, result.autoContinue != nil {
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
        if hydratePendingPrompts, (!preserveTranscript || state.isBusy), let approval = result.pendingApproval {
            // An identified legacy queue entry is distinct even when its command text repeats.
            // Only emitters without an ID need the historical command-text fallback.
            let duplicate = state.pendingApprovals.contains {
                if let requestID = approval.legacyRequestID { return $0.legacyRequestID == requestID }
                return $0.legacyRequestID == nil && $0.command == approval.command
            }
            if !duplicate {
                state.pendingApprovals.append(approval)
            }
            state.needsInput = true
        }
        if hydratePendingPrompts, (!preserveTranscript || state.isBusy), let clarify = result.pendingClarify {
            if state.clarify == nil { state.clarify = clarify }
            state.needsInput = true
        }
        // The connection card, same replay contract: the event is not re-emitted to a reattached client,
        // and the snapshot carries the server's own deadline (`server.py:776-786`).
        if hydratePendingPrompts, (!preserveTranscript || state.isBusy), let pending = result.pendingConnection {
            if state.connection.map({ $0.isSupersededBy(pending) }) ?? true { state.connection = pending }
        }

        // After `isBusy` is settled above. Under replay the snapshot predates the replayed suffix,
        // and once that suffix crosses a turn boundary (`hydratePendingPrompts` false) it describes a
        // turn that is over, so it must not revive that turn's plan any more than its prompts.
        if (!preserveTranscript || hydratePendingPrompts), let todos = result.todoState {
            seedTodos(todos, into: &state)
        }

        if preserveTranscript {
            // Revision ordering is independent of execution identity. Apply after replay has
            // rebound observed inputs, so terminal outcomes reach their restored display rows.
            if let snapshot = result.raw["submission_state"] {
                observer.applySubmissionState(snapshot, sid: sessionID, state: &state)
            }
        } else {
            observer.restore(result, state: &state)
        }
        states[sessionID] = state
    }
}
