import Foundation
import HermesServeKit
import Observation
import os

/// A file the user picked but has not sent yet.
struct PendingAttachment: Identifiable, Equatable {
    enum Kind: Equatable {
        /// Goes to `image.attach_bytes`; the pixels contribute nothing to `text`.
        case image
        /// Goes to `file.attach`; returns a `@file:` reference the client splices into the prompt text itself.
        case file
    }

    let id = UUID()
    var filename: String
    var mimeType: String
    var data: Data
    var kind: Kind
    var isUploading = false
    var failure: String?

    var byteDescription: String {
        AttachmentSize.text(data.count)
    }
}

/// One conversation: persisted transcript, live turn state, and the actions the composer and the approval sheet drive.
@MainActor
@Observable
final class ChatModel {
    private unowned let app: AppModel

    private(set) var summary: SessionSummary?
    /// Durable id. Nil until the first prompt writes the DB row — a `session.create` alone persists nothing (reference §4.0).
    private(set) var storedSessionID: String?
    /// Ephemeral 8-hex runtime id, recycled when the backend restarts.
    private(set) var runtimeSessionID: String?
    /// When this chat last acquired a runtime id; `resumeOpenThreads` compares it to the socket's open time and skips a chat already bound on the current socket.
    private(set) var runtimeBoundAt = Date.distantPast

    var title: String
    /// Persisted transcript, projected from `GET /api/sessions/{id}/messages`.
    private(set) var history: [ChatEntry] = []

    /// Live turn state, pushed from the shared `TurnEngine` by AppModel; the setter reconciles the send contract.
    var live: SessionTurnState {
        get { storedLive }
        set {
            let previous = storedLive
            storedLive = newValue
            // For a send issued under an already-running turn `isBusy` is that turn's, so only its ack can end the phase.
            if newValue.isBusy, sendPhase != .idle, !handoffAssignmentInFlight,
               !phaseAttachedToRunningTurn, lastAckStatus != nil {
                sendPhase = .idle
                watchdogTask?.cancel()
                watchdogTask = nil
            }
            // A steered or redirected turn never produces its own `message.start`, so nothing else would end `.queued`.
            if !newValue.isBusy, previous.isBusy {
                phaseAttachedToRunningTurn = false
                if sendPhase == .queued,
                   lastAckStatus == "steered" || lastAckStatus == "redirected" {
                    sendPhase = .idle
                }
                // A turn ended: re-read the automation and process state, as Desktop does after every turn.
                sessionControls.noteTurnEnded()
                backgroundProcesses.noteTurnEnded()
            }
            if needsHistoryReconciliation, previous.isBusy, !newValue.isBusy {
                Task { await self.refreshTranscriptIfQuiet() }
            }
            // `deferred: true` writes apply at end of turn, and end of turn is exactly when the next `session.info` lands.
            if newValue.info != previous.info, newValue.info != nil {
                pendingModelWrite = false
                pendingEffortWrite = false
            }
            if let control = newValue.control, control != previous.control { sessionControls.adopt(control) }
            // Guarded rather than unconditional: reset leaves `live.info` nil and applyResume/performCreateSession assign `info` before `live`.
            if let fresh = newValue.info { info = fresh }
            // The approval-expiry timer follows the head of the FIFO (SEC-006), and every change to `pendingApprovals` funnels through this setter.
            rescheduleApprovalExpiry()
        }
    }
    private var storedLive = SessionTurnState()
    private var needsHistoryReconciliation = false
    private(set) var historyRecoveryNotice: String?
    // Suffix replay cannot certify a timeline whose earlier history was already missing.
    private var checkpointHistoryIncomplete = false
    private var checkpointSavedAt = Date.distantPast
    private var checkpointSaveTask: Task<Void, Never>?
    private(set) var checkpointRecoveryOutcome: String?
    private static let recoveryLog = Logger(subsystem: "com.hermes.mobile", category: "transcript-recovery")

    private func noteCheckpointRecovery(_ outcome: String) {
        checkpointRecoveryOutcome = outcome
        // Fixed outcome codes only: never log transcript bodies, credentials or session IDs.
        Self.recoveryLog.info("Cold transcript recovery: \(outcome, privacy: .public)")
    }
    var transcriptStore = LiveTranscriptStore.shared

    var checkpointKey: String? {
        guard let profile = app.activeProfile, let storedSessionID else { return nil }
        // A saved connection can be edited in place; its UUID alone is insufficient isolation.
        return [profile.id.uuidString, profile.baseURLString, profile.username,
                profileScope ?? "", storedSessionID].joined(separator: "\u{0}")
    }

    func saveLiveCheckpoint(force: Bool = false) {
        guard app.containsChat(self), let key = checkpointKey, let runtimeSessionID, !isBinding, !isSending,
              outbound.isEmpty else { return }
        let acceptedCorrection = sendPhase == .queued && (lastAckStatus == "steered" || lastAckStatus == "redirected")
        guard sendPhase == .idle || acceptedCorrection else { return }
        guard !checkpointHistoryIncomplete else { return }
        let now = Date()
        let delay = 0.5 - now.timeIntervalSince(checkpointSavedAt)
        if !force, live.isBusy, delay > 0 {
            if checkpointSaveTask == nil {
                checkpointSaveTask = Task { [weak self] in
                    do { try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
                    catch { return }
                    guard !Task.isCancelled, let self else { return }
                    self.checkpointSaveTask = nil
                    guard self.checkpointKey == key, self.runtimeSessionID == runtimeSessionID,
                          self.app.containsChat(self) else { return }
                    self.saveLiveCheckpoint(force: true)
                }
            }
            return
        }
        checkpointSaveTask?.cancel()
        checkpointSaveTask = nil
        checkpointSavedAt = now
        let record = app.engine.checkpoint(sessionID: runtimeSessionID).map {
            LiveTranscriptStore.Record(savedAt: now, history: history, ordinals: historyOrdinals, turn: $0)
        }
        // An unmatched risk signal may make only the newest display unsafe to save.
        // Keep the earlier valid cursor so replay can still bridge that interval.
        guard record != nil || !live.isBusy || live.interrupted else { return }
        Task { await transcriptStore.save(record, key: key, at: now) }
    }

    // MARK: Send contract (spec §2)

    /// The pre-turn leg of the send contract; everything from `message.start` on is derived from `live` instead.
    enum SendPhase: Equatable {
        case idle
        /// Local state painted; ensure/upload/submit still in flight, no ack.
        case sending
        /// The submit RPC acknowledged; the turn has not started.
        case queued
        /// 8 s with no acknowledgement.
        case stalled
    }

    private(set) var sendPhase: SendPhase = .idle

    /// What the last `prompt.submit` ack said — `queued`, `steered` or `redirected` (PromptAPI.swift).
    private var lastAckStatus: String?

    /// True from the moment a send is issued under an already-running turn until that turn ends; unlike `sendJoinedRunningTurn` it outlives the send pipeline.
    private var phaseAttachedToRunningTurn = false

    /// A message the user has sent that the turn engine does not own yet — the optimistic bubble.
    struct OutboundMessage: Identifiable, Equatable {
        let id = UUID()
        var text: String
        var attachments: [PendingAttachment]
        /// Expanded skill input is model-facing only; the visible bubble keeps the invocation.
        var promptText: String? = nil
        var failure: String?
        /// BUG-141: which typed active-session refusal produced `failure`, nil for every other failure.
        var refusal: HermesError.ActiveSessionRefusal?
        /// Upload bookkeeping so a retry never re-sends bytes that landed.
        var uploadedIDs: Set<UUID> = []
        var uploadedImageNames: [String] = []
        var uploadedReferenceTexts: [String] = []
        /// Set while the engine renders this message's user entry; the roster keeps the message until the submit is acknowledged.
        var handedOffEntryID: String?
        /// The runtime session id `handedOffEntryID` was appended under — a rollback that crosses a rebind must not strip an entry from the current session.
        var handedOffSessionID: String?
        /// Set for a Retry or an Edit & resend: the user turn this message replaces.
        var replacing: Replacement? = nil

        /// The turn a replacing send cuts before. `rowID` is the durable row when the chat knows it; when it does not, `performSend` looks it up by content before the submit and degrades to a plain send if that fails, as Desktop does (`rewind.ts:285-327`).
        struct Replacement: Equatable {
            let entryID: String
            var rowID: Int?
            let text: String
            /// The target is the chat's latest user turn, which lets a content lookup with several matches take the last (`rewind.ts:213-257`).
            let isLatestUserTurn: Bool
            /// The user turns on screen after the target, and in all, when the person composed this replacement; the cut they agreed to is the target and those turns, so `retryOutbound` refuses a cut once there are more.
            var userTurnsAfter = 0
            var userTurnCount = 0
        }
    }

    private(set) var outbound: [OutboundMessage] = []
    private var sendTask: Task<Void, Never>?
    private var watchdogTask: Task<Void, Never>?

    /// The message `performSend` is flying right now — how a cancel finds its row, which is not always the last row.
    private var inFlightMessageID: UUID?

    /// True when this attempt was issued while a turn was already running, so `live.isBusy` is that turn's and not this handoff's optimism; `stopTapped` turns on the difference.
    private var sendJoinedRunningTurn = false

    /// Set when a `config.set` came back `deferred: true`; cleared by the next `session.info`.
    var pendingModelWrite = false
    var pendingEffortWrite = false

    /// Draft-only model choice: a session-less `config.set` would land on the backend's global default, so the choice rides `session.create` instead.
    var draftModelSlug: String?
    /// The provider that serves `draftModelSlug` — a bare model the current provider cannot serve is silently dropped at agent build.
    var draftProviderSlug: String?
    var draftEffort: String?
    /// The folder a Home draft starts in, carried on `session.create(cwd:)`; a live chat writes `session.cwd.set` instead.
    var draftCwd: String?
    /// True for Home's not-yet-sent conversation; an unresumed history row is not a draft.
    var isDraft: Bool { runtimeSessionID == nil && storedSessionID == nil }

    var draft: String = ""
    let slashCompletion = SlashCompletionModel()
    /// The delegated-agent roster's reads and per-agent controls.
    let subagentRoster = SubagentRosterModel()
    private(set) var isExecutingSlash = false
    private var slashTask: Task<Void, Never>?

    /// A Send has started work whose outcome lands in this conversation's transcript or error row: an ordinary prompt, or a slash command whose output, notice or refusal is written there. Home shows neither, so it promotes its draft on this rather than on `isSending` alone.
    var hasStartedSubmission: Bool { isSending || isExecutingSlash }

    /// Discovery needs only an open connection. A session-less named-profile draft is scoped by the declared `profile` parameter, so typing a slash never creates a backend session.
    var slashCommandAPI: SlashCommandsAPI? {
        guard app.connectionState.isOpen, let client = app.client else { return nil }
        return SlashCommandsAPI(client: client)
    }

    var slashCompletionScope: SlashCompletionScope {
        let profile = app.activeProfile
        return SlashCompletionScope(
            backendID: [profile?.id.uuidString ?? "", profile?.baseURLString ?? "", profile?.username ?? ""].joined(separator: "|"),
            profileID: profileScope ?? "default", sessionID: runtimeSessionID,
            cwd: info?.cwd ?? draftCwd,
            connectionID: "\(app.client.map { String(describing: ObjectIdentifier($0)) } ?? "offline")|\(app.socketOpenedAt.timeIntervalSince1970)|\(app.connectionState.isOpen)",
            profile: profileScope
        )
    }
    var attachments: [PendingAttachment] = []

    /// The one place a picked working directory lands, shared by every surface that picks one; returns an error message to keep the picker up, nil to dismiss.
    func applyCwd(_ path: String) async -> String? {
        if isDraft {
            draftCwd = path
            // FEAT-001: a draft's pick is also the seed for the next draft on this backend.
            LastProjectStore.remember(path, profileID: app.activeProfileID)
            return nil
        }
        guard let sessionID = runtimeSessionID, let sessionAPI = app.sessionAPI else {
            return "Open the conversation first — its session is not resumed yet."
        }
        do {
            try await sessionAPI.setCwd(sessionID: sessionID, path: path)
            return nil
        } catch {
            return (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    /// Transcript fetch in flight; cleared as soon as the persisted page is applied or fails, before resume.
    private(set) var isLoading = false
    /// Create/resume/bind in flight, so A8 cannot drop a chat mid-bind; independent of the spinner flag.
    private(set) var isBinding = false
    private(set) var isSending = false
    private(set) var hasLoadedOnce = false
    /// BUG-052: the last transcript load did not answer.
    private(set) var transcriptLoadFailed = false
    var errorMessage: String?
    /// Model/cwd/branch for the header, from `session.info`.
    private(set) var info: SessionInfo?

    /// When the running turn began as the backend measured it, preferred over the local stopwatch so re-entering a session does not restart the count (FEAT-010); nil on older backends and idle sessions.
    var turnStartedAt: Date? { live.turnStartedAt ?? info?.turnStartedAt }

    /// End-of-turn usage from `message.complete` / `session.usage`; nil until the first turn settles.
    var usage: SessionUsage?

    /// What the agent does on its own in this chat (a goal, a loop, a heartbeat) and what it left running in the background. Both reach the wire through `sessionControlTransport`, so they are silent in demo mode and on a backend without the methods.
    let sessionControls = SessionControlsModel()
    let backgroundProcesses = BackgroundProcessesModel()

    /// The Hermes profile whose forever-chat this is, or nil for an ordinary session; it is the thread's identity, and the session id underneath it is allowed to move.
    private(set) var botProfile: String?
    /// The name the thread header prints, which survives `applyResume` overwriting `title` from `info.title`.
    private(set) var botDisplayName: String?

    private var profileScope: String? {
        // A bot thread lives in ITS profile's state.db, and `profile: "default"` is the correct wire value even from a gateway launched under a named profile.
        if let botProfile { return BotsModel.wireProfile(for: botProfile) }
        let scope = summary?.profile ?? app.activeProfile?.hermesProfile ?? ""
        return scope.isEmpty ? nil : scope
    }

    /// The profile the transcript's images are read under when `/api/media` refuses them.
    var mediaProfile: String? { profileScope }

    init(app: AppModel, summary: SessionSummary?, bot: BotThreadRef? = nil) {
        self.app = app
        self.summary = summary
        storedSessionID = summary?.id
        botProfile = bot?.profile
        botDisplayName = bot?.displayName
        if let bot {
            title = bot.displayName
        } else {
            title = summary?.displayTitle ?? "New conversation"
        }
        sessionControls.transport = { [weak self] in self?.sessionControlTransport }
        sessionControls.onSendDispatch = { [weak self] dispatch in self?.submitControlDispatch(dispatch) ?? false }
        backgroundProcesses.transport = { [weak self] in self?.sessionControlTransport }
    }

    // MARK: - Derived state

    /// The rendered transcript: persisted history, the live turn engine's output, then any optimistic bubbles the engine does not own yet.
    var entries: [ChatEntry] {
        history + live.entries + outboundEntries
    }

    /// `!entries.isEmpty`, without building the concatenation the scroll decision would otherwise allocate on every stream delta.
    var hasEntries: Bool {
        !history.isEmpty
            || !live.entries.isEmpty
            || outbound.contains { $0.handedOffEntryID == nil }
    }

    /// BUG-052 — why this conversation has nothing on screen, so an empty chat and a chat whose history did not arrive are told apart.
    enum TranscriptGap: Equatable {
        /// Nothing is missing: either there are entries, or this really is a new conversation.
        case none
        /// A stored session whose history has not answered yet.
        case pending
        /// A stored session whose history failed, or came back empty when the session list says it has messages.
        case unavailable
    }

    var transcriptGap: TranscriptGap {
        guard !hasEntries else { return .none }
        // A draft has no durable session and therefore nothing to have lost.
        guard storedSessionID != nil else { return .none }
        if transcriptLoadFailed { return .unavailable }
        // Binding alone does not keep the gap pending — once load has answered, empty+loaded is unavailable or none.
        if isLoading || !hasLoadedOnce { return .pending }
        return (summary?.messageCount ?? 0) > 0 ? .unavailable : .none
    }

    private var outboundEntries: [ChatEntry] {
        outbound.compactMap { message in
            // Handed off: the engine's user entry renders this message until the submit acks or fails.
            guard message.handedOffEntryID == nil else { return nil }
            return ChatEntry(
                id: "outbound-\(message.id.uuidString)",
                kind: .user,
                text: message.text,
                status: message.failure == nil ? "" : "error",
                errorText: message.failure ?? "",
                imageRefs: message.attachments.map(\.filename)
            )
        }
    }

    var isBusy: Bool { live.isBusy }

    /// A turn is running on this session that this client did not start; only reachable on a gateway that mirrors session events, which is why no capability check is needed.
    var isForeignTurn: Bool {
        live.isBusy && (live.executionID != nil ? live.turnOwnership == .other : !live.turnStartedLocally)
    }

    /// Stop would end work this client did not start — wider than `isForeignTurn` because a settled parent turn with running agents has `live.isBusy` false.
    var isForeignStop: Bool {
        if isForeignTurn || (live.isBusy && live.executionID != nil && live.turnOwnership == .unknown) { return true }
        return live.activity.runningSubagents.contains { !$0.startedByThisClient }
    }

    var pendingApproval: ApprovalRequestEvent? { live.currentApproval }
    var pendingClarify: ClarifyRequestEvent? { live.clarify }
    var pendingSudo: SudoRequestEvent? { live.sudo }
    var pendingSecret: SecretRequestEvent? { live.secret }
    var hasBlockingPrompt: Bool { live.hasBlockingPrompt }
    var autoContinueNotice: AutoContinueNotice? { live.autoContinue }

    /// The blocking prompt the backend is waiting on; approvals come first because they are the only queued flow and the head is the only one `approval.respond` can answer.
    var currentBlockingPrompt: BlockingPrompt? {
        if let approval = pendingApproval { return .approval(approval) }
        if let clarify = pendingClarify { return .clarify(clarify) }
        if let sudo = pendingSudo { return .sudo(sudo) }
        if let secret = pendingSecret { return .secret(secret) }
        return nil
    }

    /// The sheet item; ChatView binds the sheet to this so a sticky `@State` cannot outlive the prompt (BUG-031).
    func presentedBlockingPrompt(minimised: Bool) -> BlockingPrompt? {
        minimised ? nil : currentBlockingPrompt
    }

    /// Whether this chat can be dropped from `AppModel.chats` once its route leaves the navigation stack (A8); deliberately timid, because re-entry costs only a resume and reload while a wrong release loses a live stream.
    var isReleasable: Bool {
        // Nothing to reload from, and a Home draft's composer state exists only here.
        guard storedSessionID != nil else { return false }
        if live.isBusy || isSending || sendPhase != .idle { return false }
        if !outbound.isEmpty { return false }
        // `terminalRead` and the connection card are not part of `hasBlockingPrompt` and are checked on their own.
        if hasBlockingPrompt || live.needsInput || live.terminalRead != nil || live.connection != nil { return false }
        // Unsent composer work is not in the transcript and no reload brings it back.
        if !draft.isEmpty || !attachments.isEmpty { return false }
        if isLoading || isBinding { return false }
        return true
    }

    /// Desktop-parity busy-input rule (desktop composer/index.tsx:301-314): a non-empty composer keeps the slot a Send even while a turn runs, and the compact secondary Stop beside it interrupts instead.
    var hasComposerPayload: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty
    }

    /// A turn is running, a send is in flight pre-ack, or the activity strip still claims delegated work is under way (BUG-013); composer-facing only, and deliberately not widened into `live.isBusy`, which feeds eviction and the Live Activity roster.
    var isTurnActive: Bool {
        live.isBusy || sendPhase != .idle || !live.activity.runningSubagents.isEmpty
    }

    var canSend: Bool {
        guard app.connectionState.isOpen else { return false }
        if isSending || isExecutingSlash { return false }
        return hasComposerPayload
    }

    var subtitle: String {
        var parts: [String] = []
        if let model = info?.model, !model.isEmpty { parts.append(model) }
        else if let model = summary?.model, !model.isEmpty { parts.append(model) }
        if let branch = info?.branch, !branch.isEmpty { parts.append(branch) }
        return parts.joined(separator: " · ")
    }

    // MARK: - Opening

    func openIfNeeded() async {
        if hasLoadedOnce, !isLoading, !isBinding, !isSending, runtimeSessionID != nil {
            await resumeAfterReconnect(force: true)
            return
        }
        // A send from Home creates the session on demand, so the in-flight send is the guard — not just the runtime id it will eventually produce.
        guard !hasLoadedOnce, !isLoading, !isBinding, runtimeSessionID == nil, !isSending else { return }
        await open()
    }

    func open() async {
        // BUG-121 A2: `isLoading` is the spinner/transcript-fetch flag, `isBinding` the eviction guard around resume/create.
        ColdOpenTrace.mark("open.enter")
        isLoading = true
        isBinding = false
        defer {
            isLoading = false
            isBinding = false
            if needsHistoryReconciliation, !live.isBusy {
                Task { await self.refreshTranscriptIfQuiet() }
            }
        }
        errorMessage = nil

        if let botProfile, storedSessionID == nil {
            // Resolving a bot thread's session id wrong mints a second forever-chat, so this replaces `createSession()` rather than sitting beside it.
            isLoading = false
            isBinding = true
            await resolveBotChat(profile: botProfile)
            hasLoadedOnce = true
            return
        }

        if let storedSessionID = storedSessionID {
            // The persisted transcript is the display authority while idle, so it lands first; the resume supplies the runtime id on top of it (reference §4.3).
            if let page = await loadTranscript(storedSessionID: storedSessionID) {
                ColdOpenTrace.mark("fetch.returned", "rows=\(page.messages.count)")
                await applyTranscriptProjectingOffMain(page)
            }
            // Spinner ends here; the bind continues under isBinding so A8 still waits.
            ColdOpenTrace.mark("spinner.cleared")
            isLoading = false
            isBinding = true
            await resumeAndBind(storedSessionID: storedSessionID)
        } else {
            isLoading = false
            isBinding = true
            await createSession()
        }
        hasLoadedOnce = true
    }

    /// Called after the socket comes back: the runtime id is stale, so re-resume and repaint from `inflight`.
    private var recoveryTask: Task<Void, Never>?

    func resumeAfterReconnect(force: Bool = false) async {
        if let recoveryTask { await recoveryTask.value; return }
        let task = Task { await self.recoverConnection(force: force) }
        recoveryTask = task
        await task.value
        recoveryTask = nil
    }

    private func recoverConnection(force: Bool) async {
        guard let storedSessionID = storedSessionID, app.connectionState.isOpen else { return }
        guard !isBinding else { return }
        guard force || runtimeBoundAt < app.socketOpenedAt else { return }
        if let runtime = runtimeSessionID, let api = app.sessionAPI,
           let seq = app.engine.beginEventRecovery(sessionID: runtime) {
            isBinding = true
            var replay: SessionEventReplay?
            do {
                let activated = try await api.activate(sessionID: runtime)
                if activated.sessionID == runtime {
                    replay = try await api.eventsSince(sessionID: runtime, lastSeen: seq)
                }
            } catch { /* Old server, retired runtime, or unavailable replay: reload below. */ }
            let recovered = app.engine.finishEventRecovery(sessionID: runtime, replay: replay)
            isBinding = false
            if recovered {
                runtimeBoundAt = Date()
                app.publish(sessionID: runtime)
                subagentRoster.hydrate(app: app, sessionID: runtime)
                return
            }
        }
        guard !isSending else { return } // Keep an unconfirmed optimistic send; never reset it away.
        let beforeLoad = app.engine.eventRevision
        let page = await loadTranscript(storedSessionID: storedSessionID)
        // BUG-019: eligibility is re-read on this side of the await and ahead of the history write it governs, because a page loaded for a pass that will not run must not be installed.
        guard force || runtimeBoundAt < app.socketOpenedAt else { return }
        if runtimeBoundAt >= app.socketOpenedAt, let runtime = runtimeSessionID, let api = app.sessionAPI {
            // Same-socket return is an attachment, not a request to recreate
            // an agent. This also works on official servers without replay.
            do {
                let result = try await api.activate(sessionID: runtime)
                guard result.sessionID == runtime else { return }
                let preserve = beforeLoad != app.engine.eventRevision
                if !preserve, let page { applyTranscript(page) }
                applyResume(result, preserveLive: preserve)
            } catch { errorMessage = describe(error) }
            return
        }
        await resumeAndBind(storedSessionID: storedSessionID, transcript: page,
                            preserveLive: beforeLoad != app.engine.eventRevision)
    }

    /// Another client changed this session while this device has it open and idle: repaint from the persisted transcript, deliberately not a `session.resume`, which would rebind the event transport away from whoever is driving.
    func refreshTranscriptIfQuiet() async {
        guard let storedSessionID = storedSessionID,
              app.connectionState.isOpen,
              hasLoadedOnce,
              !isLoading,
              !isBinding,
              !isSending,
              sendPhase == .idle,
              !live.isBusy,
              outbound.isEmpty,
              !live.hasBlockingPrompt,
              live.terminalRead == nil
        else { return }
        let beforeLoad = app.engine.eventRevision
        guard let page = await loadTranscript(storedSessionID: storedSessionID) else { return }
        guard beforeLoad == app.engine.eventRevision, !isSending, !live.isBusy, !isBinding else { return }
        applyTranscript(page)
        needsHistoryReconciliation = false
        if errorMessage == historyRecoveryNotice { errorMessage = nil }
        historyRecoveryNotice = nil
    }

    private func loadTranscript(storedSessionID: String) async -> TranscriptPage? {
        guard let rest = app.rest else { return nil }
        do {
            let page = try await rest.getMessages(sessionID: storedSessionID, profile: profileScope)
            transcriptLoadFailed = false
            return page
        } catch {
            // BUG-052: a conversation whose history did not arrive is not an empty conversation.
            transcriptLoadFailed = true
            checkpointHistoryIncomplete = true
            errorMessage = describe(error)
            return nil
        }
    }

    // Not `private`: the duplication tests drive a transcript replacement directly, because the harness points REST at a closed loopback port.
    func applyTranscript(_ page: TranscriptPage) {
        guard pageIsWorthApplying(page) else { return }
        install(page: page, projected: ColdOpenTrace.measure("project.main") {
            Self.projectTranscriptWithOrdinals(page)
        })
    }

    /// BUG-123 / BUG-125 — the same install with the projection taken off the main actor; only `open()` may use it, because the other callers guard immediately in front of their `applyTranscript` call and a suspension there would weaken the guard.
    func applyTranscriptProjectingOffMain(_ page: TranscriptPage) async {
        guard pageIsWorthApplying(page) else { return }
        let projected = await Self.projectTranscriptOffMain(page)
        // Re-asked on this side of the hop: `history` is main-actor state another writer can reach across the await.
        guard pageIsWorthApplying(page) else { return }
        install(page: page, projected: projected)
    }

    /// The hop: a `nonisolated async` function does not run on its caller's actor (SE-0338), so this executes on the cooperative pool.
    nonisolated private static func projectTranscriptOffMain(
        _ page: TranscriptPage
    ) async -> (entries: [ChatEntry], ordinals: [String: Int]) {
        ColdOpenTrace.measure("project.offmain") { projectTranscriptWithOrdinals(page) }
    }

    /// BUG-052: a page with no rows in it never takes a transcript away, because `history` is a replacement and nothing on the open path asks again.
    private func pageIsWorthApplying(_ page: TranscriptPage) -> Bool {
        !(page.messages.isEmpty && !history.isEmpty)
    }

    private func install(
        page: TranscriptPage,
        projected: (entries: [ChatEntry], ordinals: [String: Int])
    ) {
        // Render against the RESPONSE session_id: the handler follows the compression chain forward, so the id asked for may not be the one holding the messages (rest §6.2).
        if page.sessionID != storedSessionID, !page.sessionID.isEmpty {
            storedSessionID = page.sessionID
            app.chatDidBind(self, storedSessionID: page.sessionID)
        }
        checkpointHistoryIncomplete = false
        history = projected.entries
        historyOrdinals = projected.ordinals
        // Every install is the latest page unless its caller says otherwise afterwards.
        historyWindowRowID = nil
        ColdOpenTrace.mark("history.assigned", "entries=\(projected.entries.count)")
        // BUG-019: `entries` renders `history` then `live.entries` with no id-level dedup, so a page carrying turns the engine still holds must clear them here.
        guard let runtimeSessionID = runtimeSessionID else { return }
        app.engine.replaceEntries(sessionID: runtimeSessionID, with: [])
        app.publish(sessionID: runtimeSessionID)
    }

    /// Backend message ordinal per history entry id — what `session.branch`'s `count` truncates by; live entries have no ordinal until the next transcript reload.
    private(set) var historyOrdinals: [String: Int] = [:]

    /// BUG-052 — install a transcript the client already holds as a first frame only; it is not authoritative, so nothing here touches `storedSessionID`, the engine, or the runtime binding.
    func seedHistory(entries: [ChatEntry], ordinals: [String: Int]) {
        guard !entries.isEmpty, history.isEmpty, !hasLoadedOnce else { return }
        history = entries
        historyOrdinals = ordinals
    }

    // MARK: Prompt timeline

    /// The prompt row the loaded history is a page around, nil while it is the latest page. While set, the history is a window cut from the middle of the conversation: Branch ordinals are unknown, and the scroll-to-latest disc reloads the latest page.
    private(set) var historyWindowRowID: Int?
    /// The backend answered the timeline route with a bare 404: it does not have the route, and the menu stops offering it.
    private(set) var timelineUnavailable = false

    /// Whether the ⋯ menu offers the prompt list: a conversation with prompts in it, outside the demo, on a backend that has not refused the route.
    var offersPromptTimeline: Bool {
        hasEntries && app.demo == nil && !timelineUnavailable
    }

    /// The prompts the sheet can list without the backend: every loaded user turn, oldest first.
    var loadedPrompts: [ChatEntry] {
        entries.filter { $0.kind == .user && !$0.isError }
    }

    /// One page of the backend's prompt timeline; nil when there is no REST, no durable session, or no route (which also sets `timelineUnavailable`).
    func loadPromptTimeline(afterRowID: Int = 0) async throws -> PromptTimelinePage? {
        guard let rest = app.rest, let storedSessionID else { return nil }
        do {
            return try await rest.getTimeline(sessionID: storedSessionID, profile: profileScope, afterRowID: afterRowID)
        } catch where RestAPI.isRouteMissing(error) {
            timelineUnavailable = true
            return nil
        }
    }

    /// The loaded user turn a timeline row points at.
    func loadedPrompt(rowID: Int) -> ChatEntry? {
        entries.first { $0.kind == .user && $0.rowID == rowID }
    }

    /// Replace the history with the page around `rowID`, so a prompt outside the loaded history can be shown. Refused while a turn runs or a send is in flight, because live rows would render under a page from the middle of the conversation. Returns whether the page was installed.
    func loadHistoryAround(rowID: Int) async -> Bool {
        guard let rest = app.rest, let storedSessionID else { return false }
        guard !live.isBusy, !isSending, sendPhase == .idle, outbound.isEmpty else {
            errorMessage = "Wait for the reply to finish before jumping to a prompt that is not loaded."
            return false
        }
        do {
            let result = try await rest.getMessagesAround(sessionID: storedSessionID, rowID: rowID, profile: profileScope)
            guard !result.page.messages.isEmpty, !live.isBusy, !isSending else { return false }
            install(page: result.page, projected: Self.projectTranscriptWithOrdinals(result.page))
            // A page from the middle of the conversation carries no ordinal `session.branch` can count by, and it is reconciled back to the latest page when the next turn ends.
            historyOrdinals = [:]
            historyWindowRowID = result.window.rowID
            needsHistoryReconciliation = true
            return true
        } catch {
            errorMessage = describe(error)
            return false
        }
    }

    /// Back to the latest page after a jump: the scroll-to-latest disc's road home. Only while quiet, for the same reason `refreshTranscriptIfQuiet` is.
    func reloadLatestHistory() async {
        guard historyWindowRowID != nil, let storedSessionID, !live.isBusy, !isSending, sendPhase == .idle else { return }
        guard let page = await loadTranscript(storedSessionID: storedSessionID) else { return }
        applyTranscript(page)
    }

    private func resume(storedSessionID: String) async -> SessionResumeResult? {
        guard let sessionAPI = app.sessionAPI else { return nil }
        do {
            // A 4009 "settling" refusal never reaches here: `SessionAPI.resume` absorbs and retries it (BUG-114).
            let result = try await sessionAPI.resume(
                storedSessionID: storedSessionID,
                profile: profileScope,
                watch: app.sessionMirroring
            )
            return result
        } catch {
            errorMessage = describe(error)
            return nil
        }
    }

    /// Single-flight for `session.resume`: the RPC mints a fresh runtime id per call, so a losing parallel resume rebinds the chat and `forget`s the winner's engine state mid-stream.
    private var resumeTask: Task<SessionResumeResult?, Never>?

    /// Resume this chat's stored session and apply the result, joining an in-flight pass instead of dialing a rival.
    @discardableResult
    private func resumeAndBind(storedSessionID: String, transcript: TranscriptPage? = nil, preserveLive: Bool = false) async -> SessionResumeResult? {
        if let task = resumeTask {
            return await task.value
        }
        let task = Task { () -> SessionResumeResult? in
            let saved = self.runtimeSessionID == nil ? await self.loadLiveCheckpoint() : nil
            let recovering = saved.map { self.app.engine.beginCheckpointRecovery($0.turn) } ?? false
            self.noteCheckpointRecovery(saved == nil ? "checkpoint-absent-or-invalid" :
                (recovering ? "checkpoint-replay-started" : "checkpoint-ineligible"))
            let beforeResume = self.app.engine.eventRevision
            guard let result = await self.resume(storedSessionID: storedSessionID) else {
                if recovering, let saved {
                    self.app.engine.finishEventRecovery(sessionID: saved.turn.sessionID, replay: nil)
                }
                return nil
            }
            if recovering, let saved {
                var replay: SessionEventReplay?
                if result.sessionID == saved.turn.sessionID, result.sessionKey == storedSessionID,
                   result.autoContinue == nil, let api = self.app.sessionAPI {
                    replay = try? await api.eventsSince(sessionID: result.sessionID, lastSeen: saved.turn.sequence)
                }
                if self.app.engine.finishEventRecovery(sessionID: saved.turn.sessionID,
                        replay: replay, checkpoint: saved.turn, resumeSnapshot: result) {
                    self.checkpointHistoryIncomplete = false
                    self.historyRecoveryNotice = nil
                    self.noteCheckpointRecovery("checkpoint-restored")
                    self.history = saved.history
                    self.historyOrdinals = saved.ordinals
                    self.applyResume(result, recoveredCheckpoint: true)
                    // Also reconcile if completion happened while the phone was closed.
                    self.needsHistoryReconciliation = true
                    if !self.live.isBusy { Task { await self.refreshTranscriptIfQuiet() } }
                    return result
                }
            }
            if recovering, let saved {
                let reason: String
                if result.sessionID != saved.turn.sessionID { reason = "runtime-changed" }
                else if result.sessionKey != storedSessionID { reason = "stored-session-changed" }
                else if result.autoContinue != nil { reason = "auto-continue" }
                else { reason = "replay-unavailable-or-incomplete" }
                self.noteCheckpointRecovery(reason)
            }
            let receivedLive = !(self.app.engine.state(for: result.sessionID).entries.isEmpty)
                && (preserveLive || beforeResume != self.app.engine.eventRevision)
            // A snapshot has no atomic event cursor on older official servers.
            // Newer received output wins over a stale REST/resume replacement.
            // Reconcile durable rows when this live turn finishes.
            if !receivedLive, let transcript { self.applyTranscript(transcript) }
            self.applyResume(result, preserveLive: receivedLive)
            return result
        }
        resumeTask = task
        let result = await task.value
        resumeTask = nil
        return result
    }

    private func loadLiveCheckpoint() async -> LiveTranscriptStore.Record? {
        guard let key = checkpointKey else { return nil }
        let record = await transcriptStore.load(key: key)
        return key == checkpointKey ? record : nil
    }

    private func applyResume(_ result: SessionResumeResult, preserveLive: Bool = false, recoveredCheckpoint: Bool = false) {
        if let previousRuntimeID = runtimeSessionID, previousRuntimeID != result.sessionID {
            // Stale live state belongs to a runtime id that no longer exists.
            app.engine.forget(sessionID: previousRuntimeID)
        }
        // The resume payload is an authoritative re-seed, so whatever the previous connection left behind is cleared before the projection.
        if !preserveLive && !recoveredCheckpoint { app.engine.reset(sessionID: result.sessionID, preserveServerRequests: true) }
        runtimeSessionID = result.sessionID
        runtimeBoundAt = Date()
        if !result.sessionKey.isEmpty { storedSessionID = result.sessionKey }
        let recoveredState = app.engine.state(for: result.sessionID)
        let resolvedInfo = recoveredCheckpoint ? (recoveredState.info ?? result.info) : result.info
        let resolvedTitle = recoveredCheckpoint ? (recoveredState.title ?? resolvedInfo.title) : resolvedInfo.title
        info = resolvedInfo
        // `info.title` is "Bot Chat" for every bot, so letting the resume write it would rename every bot to the same thing.
        if let botDisplayName {
            title = botDisplayName
        } else if !resolvedTitle.isEmpty {
            title = resolvedTitle
        }

        // De-duplicate the inflight projection against the persisted tail: a turn persists its user row before inference begins, so the resume returns both (reference §7.1).
        let trailingUserTexts = Self.trailingUserTexts(in: history)
        if preserveLive {
            needsHistoryReconciliation = true
            checkpointHistoryIncomplete = true
            historyRecoveryNotice = "Connected. Some earlier activity may be missing until this turn finishes."
        } else if !recoveredCheckpoint {
            app.engine.applyResumeProjection(
                sessionID: result.sessionID, result: result,
                trailingUserTexts: trailingUserTexts, history: history, preserveTranscript: recoveredCheckpoint)
            if result.running && !recoveredCheckpoint {
                needsHistoryReconciliation = true
                checkpointHistoryIncomplete = true
                historyRecoveryNotice = "Connected. Some earlier activity may be missing until this turn finishes."
            }
        }
        app.publish(sessionID: result.sessionID)
        app.chatDidBind(self, storedSessionID: storedSessionID)
        // Live frames only reach an attached client, so a reopen asks for the agents it missed.
        subagentRoster.hydrate(app: app, sessionID: result.sessionID)
    }

    // MARK: - The Bot Chat resolver

    /// Single-flight for the resolver: two concurrent `open()` calls must produce at most one `session.create`, so it is registered before the first suspension point.
    private var botResolveTask: Task<Void, Never>?

    private func resolveBotChat(profile: String) async {
        if let task = botResolveTask {
            await task.value
            return
        }
        let task = Task { await self.performBotResolve(profile: profile) }
        botResolveTask = task
        await task.value
        botResolveTask = nil
    }

    /// Walk the ladder: a rung ending in an affirmative absence falls through, a rung ending in a failure stops, so minting is reachable only when the backend has twice said there is no such chat.
    private func performBotResolve(profile: String) async {
        guard let sessionAPI = app.sessionAPI else {
            errorMessage = "Not connected to a backend."
            return
        }
        let backend = app.activeProfileID
        let pins = app.bots.store
        let wire = BotsModel.wireProfile(for: profile)

        // Rung 2 — the pin: ours first, then the one Desktop wrote into `ui_meta['hermes-bots'].chat`.
        if let pin = pins.pin(backend: backend, profile: profile) ?? app.bots.serverPinHint(profile) {
            var adopted = false
            do {
                let result = try await sessionAPI.resume(
                    storedSessionID: pin,
                    profile: wire,
                    watch: app.sessionMirroring
                )
                if BotsModel.titleRefutesBotChat(result.info.title) {
                    // BUG-053: the pin is retired, not just declined — a pin proven wrong would otherwise repeat the mis-binding on the next open.
                    pins.removePin(backend: backend, profile: profile)
                } else {
                    // Adopting a server hint as our own pin is the only write here; re-writing our own is a no-op.
                    pins.setPin(pin, backend: backend, profile: profile)
                    await adoptBotResume(result)
                    adopted = true
                }
            } catch let error as HermesError where Self.isBotChatGone(error) {
                pins.removePin(backend: backend, profile: profile)
                // fall through — the chat this named is genuinely not there
            } catch {
                // Never mint on a transient failure; the pin stays, because replacing it is the fork this ladder exists to prevent.
                errorMessage = describe(error)
                return
            }
            if adopted { return }
        }

        // Rung 3 — adopt by title, for a chat another client minted that this device has no pin for.
        do {
            if let match = try await sessionAPI.lookupByTitle(
                BotsModel.canonicalChatTitle,
                profile: wire
            ), match.title == BotsModel.canonicalChatTitle {
                // A gateway that does not know the `title` parameter answers the ordinary windowed listing instead, and adopting its first row would bind this bot's thread to an unrelated session.
                pins.setPin(match.id, backend: backend, profile: profile)
                let target = match.resolvedID.isEmpty ? match.id : match.resolvedID
                let result = try await sessionAPI.resume(
                    storedSessionID: target,
                    profile: wire,
                    watch: app.sessionMirroring
                )
                await adoptBotResume(result)
                return
            }
        } catch {
            errorMessage = describe(error)
            return
        }

        // Rung 4 — resume by title, which overlaps rung 3 deliberately: each degrades silently on a gateway that lacks the other, and silent degradation mints a fork.
        do {
            let result = try await sessionAPI.resume(
                storedSessionID: BotsModel.canonicalChatTitle,
                profile: wire,
                watch: app.sessionMirroring
            )
            if !result.sessionKey.isEmpty {
                pins.setPin(result.sessionKey, backend: backend, profile: profile)
            }
            await adoptBotResume(result)
            return
        } catch let error as HermesError where Self.isBotChatGone(error) {
            // fall through to the mint — the second affirmative absence
        } catch {
            errorMessage = describe(error)
            return
        }

        // Rung 5 — mint. Born hidden so Sessions mode never lists it.
        do {
            let result = try await sessionAPI.create(
                profile: wire,
                title: BotsModel.canonicalChatTitle,
                hidden: true
            )
            if !result.storedSessionID.isEmpty {
                pins.setPin(result.storedSessionID, backend: backend, profile: profile)
            }
            runtimeSessionID = result.sessionID
            runtimeBoundAt = Date()
            storedSessionID = result.storedSessionID.isEmpty ? nil : result.storedSessionID
            info = result.info
            app.engine.reset(sessionID: result.sessionID)
            app.publish(sessionID: result.sessionID)
            app.chatDidBind(self, storedSessionID: storedSessionID)
        } catch {
            errorMessage = describe(error)
            return
        }

        // A kickoff turn is structural: `session.create` alone persists no DB row, so a chat created and never spoken to cannot be found again and the next open mints another one.
        // BUG-084: any text the user typed during the ladder's round trips is sent instead of being replaced by the canned line.
        if !hasComposerPayload { draft = BotsModel.kickoffPrompt }
        sendTapped()
    }

    /// Apply a resume the resolver already holds — deliberately not `resumeAndBind`, which would dial a second `session.resume` and `forget` the engine state the first one bound.
    private func adoptBotResume(_ result: SessionResumeResult) async {
        if !result.sessionKey.isEmpty { storedSessionID = result.sessionKey }
        // Same ordering `open()` uses: the persisted transcript lands first, then the resume projects mid-turn state on top of it.
        if let storedSessionID, let page = await loadTranscript(storedSessionID: storedSessionID) {
            applyTranscript(page)
        }
        applyResume(result)
    }

    /// The one error that means "that chat is gone": 4007 only, never `HermesError.isSessionNotFound`, whose prose matching would let a transient failure delete the pin and fork the bot's history.
    static func isBotChatGone(_ error: HermesError) -> Bool {
        guard case .rpc(let code, _, _) = error else { return false }
        return code == 4007
    }

    /// Single-flight: `open()` and `ensureSession()` must never both dial `session.create`, because the loser's id silently orphans the winner's engine state.
    private var createTask: Task<Void, Never>?

    private func createSession() async {
        if let task = createTask {
            await task.value
            if runtimeSessionID != nil { return }
        }
        let task = Task { await performCreateSession() }
        createTask = task
        await task.value
        createTask = nil
    }

    private func performCreateSession() async {
        guard let sessionAPI = app.sessionAPI else {
            errorMessage = "Not connected to a backend."
            return
        }
        let scope = slashCompletionScope
        let client = app.client
        do {
            // Model, provider and effort ride the create as per-session overrides; a session-less `config.set` would mutate the global default instead.
            let result = try await sessionAPI.create(
                cwd: draftCwd,
                profile: profileScope,
                model: draftModelSlug,
                provider: draftProviderSlug,
                reasoningEffort: draftEffort
            )
            // A slash command's Send can bind a draft while the user switches backend. A late bind belongs only to its original backend.
            guard slashContextMatches(scope), app.client === client else { return }
            runtimeSessionID = result.sessionID
            runtimeBoundAt = Date()
            storedSessionID = result.storedSessionID.isEmpty ? nil : result.storedSessionID
            info = result.info
            app.engine.reset(sessionID: result.sessionID)
            app.publish(sessionID: result.sessionID)
            // FEAT-018: sending under a project is use, and use re-opens the expiry window.
            if let cwd = draftCwd {
                LastProjectStore.remember(cwd, profileID: app.activeProfileID)
            }
            draftModelSlug = nil
            draftProviderSlug = nil
            draftEffort = nil
            draftCwd = nil
        } catch {
            guard slashContextMatches(scope), app.client === client else { return }
            errorMessage = describe(error)
        }
    }

    /// The runtime id, creating or resuming the session if necessary.
    private func ensureSession() async throws -> String {
        if let runtimeSessionID = runtimeSessionID { return runtimeSessionID }
        if let storedSessionID = storedSessionID, let result = await resumeAndBind(storedSessionID: storedSessionID) {
            return result.sessionID
        }
        await createSession()
        guard let runtimeSessionID = runtimeSessionID else {
            throw HermesError.notConnected
        }
        return runtimeSessionID
    }

    // MARK: - Slash command submission

    /// Only an editor-originated command enters this path. Pasted prose remains ordinary input.
    private func sendSlashCommand() {
        guard !isSending, !isExecutingSlash, app.connectionState.isOpen,
              let client = app.client else { return }
        let api = SlashCommandsAPI(client: client)
        let original = draft
        let stagedAttachments = attachments
        let scope = slashCompletionScope
        let previouslyAdvertised = (try? Self.slashInvocation(original)).flatMap { slashCompletion.advertisedEntry(named: $0.name) }
        if let reason = localSlashRefusal(original) {
            errorMessage = reason
            slashCompletion.dismiss()
            return
        }
        isExecutingSlash = true
        errorMessage = nil
        slashCompletion.dismiss()
        slashTask = Task {
            defer { isExecutingSlash = false; slashTask = nil }
            do {
                let invocation = try Self.slashInvocation(original)
                if let reason = SlashCommandSupport.unavailableReason(name: invocation.name, entry: nil) {
                    throw HermesError.unsupported(reason)
                }
                if invocation.name == "stop" {
                    guard invocation.argument.isEmpty else { throw HermesError.unsupported("Use /stop without arguments.") }
                    guard !isForeignStop else {
                        throw HermesError.unsupported("Use the Stop button to confirm stopping another client's work.")
                    }
                    stopTapped()
                    if draft == original { draft = "" }
                    return
                }
                if invocation.name == "btw" {
                    // Desktop's own path (`slash.ts:555-600`): `prompt.btw` answers from a snapshot without steering or interrupting the running turn. Never the slash worker, which prints the answer past its capture window (#99065), and never a turn. The answer arrives as `btw.complete`, which the engine adds to the chat.
                    let question = invocation.argument.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !question.isEmpty else { throw HermesError.unsupported("Use /btw followed by your question.") }
                    guard let promptAPI = app.promptAPI else { throw HermesError.notConnected }
                    let sessionID = try await ensureSession()
                    guard slashContextMatches(scope), app.client === client else { return }
                    _ = try await promptAPI.btw(sessionID: sessionID, question: question)
                    guard slashContextMatches(scope), runtimeSessionID == sessionID, app.client === client else { return }
                    app.engine.appendNotice(sessionID: sessionID, text: "Asked on the side: “\(question)”. The answer will appear here.", kind: "btw-asked")
                    app.publish(sessionID: sessionID)
                    if draft == original { draft = "" }
                    app.chatDidBind(self, storedSessionID: storedSessionID)
                    return
                }
                let sessionID = try await ensureSession()
                guard slashContextMatches(scope), app.client === client else { return }
                // The bound session carries its own profile home and workspace; `cwd` is not a declared parameter.
                let catalog = try? await api.catalog(sessionID: sessionID)
                guard slashContextMatches(scope), runtimeSessionID == sessionID, app.client === client else { return }
                if invocation.name == "help" || invocation.name == "commands" {
                    guard invocation.argument.isEmpty else { throw HermesError.unsupported("Use /help without arguments.") }
                    guard let catalog else {
                        throw HermesError.unsupported("Command discovery is unavailable on this backend. Your draft is preserved.")
                    }
                    let help = catalog.entries.filter {
                        SlashCommandSupport.unavailableReason(name: $0.name, entry: $0) == nil
                    }.map { "\($0.name) — \($0.description)" }.joined(separator: "\n")
                    appendSlashOutput(help.isEmpty ? "No supported commands were advertised." : help, sessionID: sessionID)
                    if let warning = catalog.warning, !warning.isEmpty { appendSlashOutput(warning, sessionID: sessionID) }
                    if draft == original { draft = "" }
                    app.chatDidBind(self, storedSessionID: storedSessionID)
                    return
                }
                let entry = catalog?.entry(named: invocation.name) ?? previouslyAdvertised
                guard let entry else {
                    throw HermesError.unsupported("/\(invocation.name) is unavailable or was not advertised by this backend. Your draft is preserved.")
                }
                let result = try await resolveSlash(invocation, entry: entry, catalog: catalog, api: api,
                    client: client, sessionID: sessionID, scope: scope, depth: 0)
                guard slashContextMatches(scope), runtimeSessionID == sessionID, app.client === client else { return }
                if let warning = result.warning, !warning.isEmpty { appendSlashOutput(warning, sessionID: sessionID) }
                if let notice = result.notice, !notice.isEmpty { appendSlashOutput(notice, sessionID: sessionID) }
                switch result.type {
                case "skill", "send":
                    guard let message = result.message, !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                        throw HermesError.malformedResponse("The command did not return a prompt. Your draft is preserved.")
                    }
                    let display = result.display.flatMap { $0.isEmpty ? nil : $0 } ?? original
                    guard enqueueSend(text: display, attachments: stagedAttachments, promptText: message) else { return }
                    if draft == original { draft = "" }
                    attachments.removeAll { attachment in stagedAttachments.contains { $0.id == attachment.id } }
                case "prefill":
                    guard let message = result.message else { throw HermesError.malformedResponse("Missing command draft.") }
                    if draft == original { draft = message }
                    else { appendSlashOutput("Command draft:\n\(message)", sessionID: sessionID) }
                case nil, "exec", "plugin":
                    guard let output = result.output ?? (result.type == nil ? nil : "(no output)") else { throw HermesError.malformedResponse("Missing command output. Your draft is preserved.") }
                    appendSlashOutput(output.isEmpty ? "(no output)" : output, sessionID: sessionID)
                    if draft == original { draft = "" }
                default:
                    throw HermesError.unsupported("This backend returned an unsupported command action. Your draft is preserved.")
                }
                app.chatDidBind(self, storedSessionID: storedSessionID)
            } catch {
                guard slashContextMatches(scope), app.client === client else { return }
                errorMessage = describe(error)
            }
        }
    }

    /// A refusal the draft decides on its own, given in the tap frame before anything is created or sent; nil when only the backend can judge the command. Synchronous because Home promotes its draft on `hasStartedSubmission`, and a refusal that raised it would open an empty conversation and create a session for a command that never ran.
    private func localSlashRefusal(_ text: String) -> String? {
        let invocation: SlashInvocation
        do { invocation = try Self.slashInvocation(text) } catch { return describe(error) }
        if let reason = SlashCommandSupport.unavailableReason(name: invocation.name, entry: nil)
            ?? slashCompletion.advertisedEntry(named: invocation.name).flatMap({ SlashCommandSupport.unavailableReason(name: invocation.name, entry: $0) }) {
            return reason
        }
        let hasArgument = !invocation.argument.isEmpty
        switch invocation.name {
        case "stop" where hasArgument: return "Use /stop without arguments."
        case "stop" where isForeignStop: return "Use the Stop button to confirm stopping another client's work."
        case "btw" where invocation.argument.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty: return "Use /btw followed by your question."
        case "help", "commands": return hasArgument ? "Use /help without arguments." : nil
        case "status", "save": return hasArgument ? "Use /\(invocation.name) without arguments." : nil
        default: return nil
        }
    }

    private struct SlashInvocation {
        let name: String
        let argument: String
        var line: String { name + (argument.isEmpty ? "" : " " + argument) }
    }

    private static func slashInvocation(_ text: String) throws -> SlashInvocation {
        guard text.hasPrefix("/"), !text.hasPrefix("//") else { throw HermesError.unsupported("Invalid slash command.") }
        let body = text.dropFirst()
        let name = body.prefix { !$0.isWhitespace }
        guard !name.isEmpty, !name.contains("/"), !name.contains("\\"), !name.contains(":") else {
            throw HermesError.unsupported("This text is not a slash command.")
        }
        return SlashInvocation(name: String(name).lowercased(), argument: String(body.dropFirst(name.count).drop(while: { $0.isWhitespace })))
    }

    private func slashContextMatches(_ scope: SlashCompletionScope) -> Bool {
        let current = slashCompletionScope
        return current.backendID == scope.backendID && current.profileID == scope.profileID && current.connectionID == scope.connectionID
    }

    private func appendSlashOutput(_ text: String, sessionID: String) {
        app.engine.appendNotice(sessionID: sessionID, text: text, kind: "slash", isSystem: true)
        app.publish(sessionID: sessionID)
    }

    private func resolveSlash(_ invocation: SlashInvocation, entry: SlashCatalogEntry?, catalog: SlashCommandCatalog?,
        api: SlashCommandsAPI, client: HermesClient, sessionID: String, scope: SlashCompletionScope, depth: Int) async throws -> SlashDispatchResult {
        guard depth < 8 else { throw HermesError.unsupported("Command alias cycle detected. Your draft is preserved.") }
        guard slashContextMatches(scope), runtimeSessionID == sessionID, app.client === client else { throw CancellationError() }
        if let reason = SlashCommandSupport.unavailableReason(name: invocation.name, entry: entry) { throw HermesError.unsupported(reason) }
        if ["help", "commands", "stop"].contains(invocation.name) {
            guard invocation.argument.isEmpty else { throw HermesError.unsupported("Use /\(invocation.name) without arguments.") }
            if invocation.name == "stop" {
                guard !isForeignStop else { throw HermesError.unsupported("Use the Stop button to confirm stopping another client's work.") }
                stopTapped()
                return SlashDispatchResult(json: .object(["type": .string("exec"), "output": .string("Stop requested.")]))
            }
            guard let catalog else { throw HermesError.unsupported("Command discovery is unavailable. Your draft is preserved.") }
            let help = catalog.entries.filter { SlashCommandSupport.supports($0) }
                .map { "\($0.name) — \($0.description)" }.joined(separator: "\n")
            return SlashDispatchResult(json: .object(["type": .string("exec"), "output": .string(help)]))
        }
        let result: SlashDispatchResult
        if invocation.name == "status" || invocation.name == "save" {
            guard invocation.argument.isEmpty else { throw HermesError.unsupported("Use /\(invocation.name) without arguments.") }
            let raw = try await client.request("session.\(invocation.name)", params: .object(["session_id": .string(sessionID)]))
            if invocation.name == "save", let file = raw["file"]?.coercedString {
                result = SlashDispatchResult(json: .object(["output": .string("Saved on the backend: \(file)")]))
            } else { result = SlashDispatchResult(json: raw) }
        } else if entry?.kind == "quick" {
            // The CLI worker consumes aliases locally and cannot return a resolved skill prompt.
            result = try await api.dispatch(sessionID: sessionID, name: invocation.name, argument: invocation.argument)
        } else {
            do { result = try await api.execute(sessionID: sessionID, line: invocation.line) }
            catch {
                // A worker failure may follow side effects. Retry only an absent method or an explicit routing refusal.
                guard case HermesError.rpc(let code, let message, _) = error,
                      code == -32601 || (code == 4018 && message.hasPrefix("skill command: use command.dispatch for /"))
                else { throw error }
                let executionError = error
                guard slashContextMatches(scope), runtimeSessionID == sessionID, app.client === client else { throw CancellationError() }
                do { result = try await api.dispatch(sessionID: sessionID, name: invocation.name, argument: invocation.argument) }
                catch {
                    if case HermesError.rpc(_, let message, _) = error, message.hasPrefix("not a quick/plugin/") { throw executionError }
                    throw error
                }
            }
        }
        if result.type == "alias" {
            guard let target = result.target, !target.isEmpty else { throw HermesError.malformedResponse("Empty command alias.") }
            let expanded = (target.hasPrefix("/") ? target : "/" + target) + (invocation.argument.isEmpty ? "" : " " + invocation.argument)
            let next = try Self.slashInvocation(expanded)
            let targetEntry = catalog?.entry(named: next.name)
            guard targetEntry != nil || SlashCommandSupport.localCommands.contains("/" + next.name) else {
                throw HermesError.unsupported("The alias target /\(next.name) was not advertised by this backend. Your draft is preserved.")
            }
            return try await resolveSlash(next, entry: targetEntry, catalog: catalog, api: api,
                client: client, sessionID: sessionID, scope: scope, depth: depth + 1)
        }
        return result
    }

    // MARK: - Sending (the optimistic contract, spec §2)

    /// Steps 0–2 of the send contract, synchronous so they paint in the frame of the tap and so re-entry is the double-tap guard — `.disabled(!canSend)` lands a render late.
    func sendTapped() {
        guard !isExecutingSlash else { return }
        if let editing = editingEntryID {
            sendEdit(replacing: editing)
            return
        }
        if slashCompletion.commandIntent(for: draft) {
            sendSlashCommand()
            return
        }
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard enqueueSend(text: text, attachments: attachments) else { return }
        draft = ""
        attachments.removeAll()
    }

    /// Send the composer as the replacement for an earlier user turn. The backend refuses a cut while a turn runs (4009, `methods_prompt.py:676-677`), so the edit waits with its draft intact rather than going out as an ordinary message.
    private func sendEdit(replacing entryID: String) {
        guard !live.isBusy else {
            errorMessage = "Hermes is still working. Wait for the turn to finish, or stop it, before replacing an earlier message."
            return
        }
        guard let target = editedEntry(entryID) else {
            // The turn left the transcript (a branch, a cut from another client); what is typed is still the person's.
            editingEntryID = nil
            editingTarget = nil
            errorMessage = "That message is no longer in this conversation. Your text is still in the composer."
            return
        }
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard enqueueSend(text: text, attachments: attachments, replacing: replacement(for: target)) else { return }
        editingEntryID = nil
        editingTarget = nil
        draft = ""
        attachments.removeAll()
    }

    /// Voice chat has its own turn payload and must never borrow the composer's draft or staged attachments.
    @discardableResult
    func sendVoiceTurn(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard app.connectionState.isOpen else {
            errorMessage = "Not connected to a backend."
            return false
        }
        return enqueueSend(text: trimmed, attachments: [])
    }

    /// Start an optimistic send without deciding what a caller owns after it succeeds.
    @discardableResult
    private func enqueueSend(
        text: String,
        attachments: [PendingAttachment],
        promptText: String? = nil,
        replacing: OutboundMessage.Replacement? = nil
    ) -> Bool {
        guard !isSending else { return false }
        guard !text.isEmpty || !attachments.isEmpty else { return false }
        guard app.promptAPI != nil else {
            errorMessage = "Not connected to a backend."
            return false
        }

        var message = OutboundMessage(text: text, attachments: attachments, promptText: promptText)
        message.replacing = replacing
        outbound.append(message)
        errorMessage = nil
        isSending = true
        lastAckStatus = nil
        sendPhase = .sending
        HapticFeedback.sent()
        armWatchdog()
        inFlightMessageID = message.id
        sendJoinedRunningTurn = live.isBusy
        phaseAttachedToRunningTurn = live.isBusy
        sendTask = Task { await performSend(messageID: message.id) }
        return true
    }

    /// Re-run a failed (or cancelled) outbound message.
    func retryOutbound(id: UUID) {
        guard !isSending, let index = outbound.firstIndex(where: { $0.id == id }) else { return }
        outbound[index].failure = nil
        outbound[index].refusal = nil
        errorMessage = nil
        // The cut takes the target and everything after it, so a replacement retried after newer turns were sent would delete them; it goes out as a plain message instead, and says so.
        if let replacement = outbound[index].replacing, newerTurnsFollow(replacement, retrying: id) {
            outbound[index].replacing = nil
            errorMessage = Self.replacementOvertakenNotice
        }
        isSending = true
        lastAckStatus = nil
        sendPhase = .sending
        armWatchdog()
        inFlightMessageID = id
        sendJoinedRunningTurn = live.isBusy
        phaseAttachedToRunningTurn = live.isBusy
        sendTask = Task { await performSend(messageID: id) }
    }

    /// The stall row's Cancel: abandon the wait; the attempt may still land server-side, so the bubble stays, marked failed.
    func cancelStalledSend() {
        guard sendPhase == .stalled else { return }
        cancelPendingSend()
    }

    /// Send and stop share one position: Stop interrupts a running turn, and before the ack it cancels the attempt instead.
    ///
    /// BUG-013: delegated agents are stopped by their own RPC, not this one — `session.interrupt` gates on the session being busy and the background dispatch path detaches every child from the parent's interrupt propagation.
    ///
    /// The ids are sampled here, in the frame of the tap, because `interrupt()` clears the whole activity surface on its way past.
    func stopTapped() {
        let agentIDs = live.activity.interruptibleSubagentIDs
        let unkillable = live.activity.unkillableRunningSubagents.count
        if sendPhase == .sending || sendPhase == .stalled, !sendJoinedRunningTurn {
            // Deliberately does not kill the agents: this tap cancels an unacknowledged send, and a second tap lands in the branch below, which does kill them.
            cancelPendingSend()
        } else if live.isBusy || sendPhase == .queued {
            // The backend's `session.interrupt` also clears the queued prompt, so the `.queued` phase must end here.
            if sendPhase == .queued {
                sendPhase = .idle
                phaseAttachedToRunningTurn = false
                lastAckStatus = nil
            }
            // Sequenced, not raced: the turn dies first so it cannot dispatch another fan-out into the window.
            stopWorkTask = Task {
                await interrupt()
                await stopBackgroundAgents(ids: agentIDs, unkillableCount: unkillable)
            }
        } else if !agentIDs.isEmpty || unkillable > 0 {
            // No turn, no send in flight, and the strip still drawing delegated work: nothing here is interruptible through the session.
            stopWorkTask = Task { await stopBackgroundAgents(ids: agentIDs, unkillableCount: unkillable) }
        }
    }

    /// The Stop's own work once it leaves the tap: the session interrupt where there is one, then the per-agent kills and the reconcile.
    private(set) var stopWorkTask: Task<Void, Never>?

    /// Stop every delegated agent this client can name, and be honest about the ones it cannot.
    ///
    /// `found: false` means opposite things for a row that started (it ended and its `subagent.complete` was lost, so retire it) and one that never started (queued behind the delegation limit, so it stays).
    private func stopBackgroundAgents(ids: [String], unkillableCount: Int) async {
        guard !ids.isEmpty || unkillableCount > 0 else { return }
        // Single-flight, and the flag a test waits on when the honest outcome is that nothing changed.
        guard !isStoppingAgents else { return }
        isStoppingAgents = true
        defer { isStoppingAgents = false }
        // Clear only the sentences this function writes, so a send failure or turn-stop failure stays where it is.
        if let current = errorMessage, Self.agentStopMessages.contains(where: current.hasPrefix) {
            errorMessage = nil
        }
        guard let sessionAPI = app.sessionAPI else {
            errorMessage = "Not connected — the agents are still running on the backend."
            return
        }

        var failure: String?
        var reached = 0
        for id in ids {
            do {
                let result = try await sessionAPI.interruptSubagent(subagentID: id, sessionID: runtimeSessionID ?? "")
                if result.found {
                    reached += 1
                } else if let sessionID = runtimeSessionID {
                    // Re-read the runtime id every time: a resume can rebind the chat across any of these awaits.
                    if app.engine.markSubagentInterrupted(sessionID: sessionID, wireSubagentID: id) {
                        app.publish(sessionID: sessionID)
                    }
                }
            } catch {
                // First error wins the banner; the loop continues, because one failure is no reason to leave the others running.
                if failure == nil { failure = describe(error) }
            }
        }

        await reconcileRemainingAgents()

        // A turn-stop failure written by `interrupt()` is the more serious one and must not be painted over by a report about its children.
        if errorMessage?.hasPrefix(Self.turnStopFailurePrefix) == true { return }

        if let failure {
            errorMessage = "Couldn't stop every background agent: \(failure)"
            return
        }
        // Both counts are re-read here, after the kills and the reconcile: the tap-time count is not evidence about what is left on screen.
        let remaining = live.activity.runningSubagents
        guard reached == 0, !remaining.isEmpty else { return }
        if remaining.contains(where: { $0.wireSubagentID.isEmpty }) {
            errorMessage = "This backend didn't send ids for the delegated agents, so they can't be stopped from here."
        } else {
            errorMessage = "Those agents haven't started yet — the backend has nothing to stop until they do."
        }
    }

    /// True while `stopBackgroundAgents` is working.
    private(set) var isStoppingAgents = false

    private static let turnStopFailurePrefix = "Couldn't stop the turn:"
    /// Everything `stopBackgroundAgents` can write, so it clears only its own stale output.
    private static let agentStopMessages = [
        "Couldn't stop every background agent:",
        "This backend didn't send ids",
        "Those agents haven't started yet",
        "Not connected — the agents",
    ]

    /// The closing check: if anything is still drawn as running after the kills, ask the backend whether anything at all is delegating.
    ///
    /// Only an empty `active` retires anything, a paused registry is not idle, and the rows are named from before the call so a fan-out that lands mid-flight is not dropped.
    private func reconcileRemainingAgents() async {
        guard let sessionAPI = app.sessionAPI,
              let sessionID = runtimeSessionID
        else { return }
        let observed = live.activity.runningSubagents.map(\.id)
        guard !observed.isEmpty else { return }
        guard let status = try? await sessionAPI.delegationStatus(),
              status.isIdle,
              !status.paused
        else { return }
        guard let current = runtimeSessionID, current == sessionID else { return }
        if app.engine.markSubagentsInterrupted(sessionID: current, ids: observed) > 0 {
            app.publish(sessionID: current)
        }
    }

    /// Abandon the in-flight attempt; the parked RPC rides on because `HermesClient.request` has no cancellation handler, and its `Task.isCancelled` guards keep the superseded pipeline from undoing this verdict.
    private func cancelPendingSend() {
        sendTask?.cancel()
        sendTask = nil
        watchdogTask?.cancel()
        watchdogTask = nil
        isSending = false
        sendPhase = .idle
        // Read and clear unconditionally, before the guard: leaving the id set would let a later cancel stamp a row no send is flying.
        let messageID = inFlightMessageID
        inFlightMessageID = nil
        sendJoinedRunningTurn = false
        phaseAttachedToRunningTurn = false
        lastAckStatus = nil
        // First verdict wins: a row that already failed keeps its more specific reason.
        guard let messageID,
              outbound.contains(where: { $0.id == messageID && $0.failure == nil })
        else { return }
        markFailed(messageID, reason: "Cancelled — the backend did not acknowledge the send.")
    }

    // MARK: Status line (steps 2–6)

    /// The never-empty status slot's text, or nil once a streaming bubble owns the surface or nothing is in flight.
    var statusLineText: String? {
        // BUG-020: a turn parked on the user is not work.
        if live.hasBlockingPrompt || live.needsInput {
            return "Waiting for your answer"
        }
        // The agent's tool is blocked on the connection card until it settles or its deadline passes.
        if live.connection != nil {
            return "Waiting for you to connect an app"
        }
        // BUG-030: a steer only happens while a turn is streaming, so this branch must beat the streaming-bubble guard below.
        if sendPhase == .queued, lastAckStatus == "steered" || lastAckStatus == "redirected" {
            return "Update accepted for this turn"
        }
        if live.entries.contains(where: { $0.isStreaming }) { return nil }
        // BUG-030: `appendUserEntry` claims `isBusy` before the submit ack, so an idle send is distinguished from a mid-turn steer here.
        if sendPhase == .sending, !sendJoinedRunningTurn {
            return "Sending…"
        }
        if live.isBusy {
            // A mirrored turn renders exactly as a local one does, so say whose it is.
            let prefix = isForeignTurn ? "Working in another client · " : ""
            if let tool = live.entries.last(where: { $0.kind == .tool && $0.tool?.isRunning == true })?.tool {
                return prefix + "Thinking · \(tool.name)"
            }
            if !live.statusText.isEmpty { return prefix + live.statusText }
            return prefix + "Thinking"
        }
        // Placed after the `live.isBusy` branch on purpose: `session.active_list` reports our own running turn as working too.
        if sendPhase == .idle,
           let elsewhere = app.liveStatus(forStoredID: storedSessionID),
           elsewhere.isWorking {
            var text = elsewhere.needsInput
                ? "Waiting for input in another client"
                : "Working in another client"
            let preview = elsewhere.preview.trimmingCharacters(in: .whitespacesAndNewlines)
            if !preview.isEmpty { text += " · \(preview)" }
            return text
        }
        switch sendPhase {
        case .sending: return "Sending…"
        case .queued: return "Queued — waiting for the turn to start"
        case .stalled, .idle: return nil
        }
    }

    var isSendStalled: Bool { sendPhase == .stalled }

    /// Any Stop — composer primary, composer secondary, nav-bar insurance; hidden while a blocking prompt is up (BUG-020), where Stop cancelled the question the user was being asked.
    var showsInterruptControl: Bool { isTurnActive && !hasBlockingPrompt }

    var showsStopControl: Bool { showsInterruptControl && !hasComposerPayload }

    /// The compact secondary Stop beside Send, for a composer that holds text; a phone has no Esc to interrupt a typed draft with.
    var showsSecondaryStop: Bool { showsInterruptControl && hasComposerPayload }

    /// The stall row's Retry: the submit RPC cannot be cancelled safely because a resend could double-run the turn, so retry nudges the connection instead.
    func retryStalledConnection() {
        Task { await app.client?.wake() }
    }

    private func armWatchdog() {
        watchdogTask?.cancel()
        watchdogTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            guard !Task.isCancelled, let self else { return }
            if self.sendPhase == .sending { self.sendPhase = .stalled }
        }
    }

    /// True only across the two handoff `live` assignments in `performSend`.
    private var handoffAssignmentInFlight = false

    /// Publish the engine state after this send's own handoff without ending the pre-turn phases, since `appendUserEntry`'s `isBusy` claim is this client's optimism and not the backend's turn arriving.
    ///
    /// Still through `AppModel.publish`, never a bare `live =`: the funnel is what tells the Live Activity roster this session moved (BUG-003).
    private func publishHandoff(sessionID: String) {
        handoffAssignmentInFlight = true
        app.publish(sessionID: sessionID)
        handoffAssignmentInFlight = false
    }

    /// Whether the engine entry this send handed its bubble to is in the state the transcript is actually reading, which a resume across the send's awaits can make false.
    ///
    /// Deliberately reads `live` and not `app.engine.state(for:)`, which would answer true for the captured id right up until `forget` runs.
    private func handoffIsOnScreen(_ entryID: String) -> Bool {
        live.entries.contains { $0.id == entryID }
    }

    /// Stamp the user's bubble with what the backend said it did with the message (BUG-021); a `streaming` ack is an ordinary turn and gets no label.
    ///
    /// Published through `publishHandoff`, not a bare `app.publish`: this write lands while `sendPhase` is still `.sending` and the setter's reconciliation would throw the phase away.
    private func stampAck(onEntry entryID: String) {
        guard let sessionID = runtimeSessionID else { return }
        let kind: String
        switch lastAckStatus {
        case "steered", "redirected": kind = "correction"
        case "queued": kind = "queued"
        default: return
        }
        app.engine.setNoticeKind(sessionID: sessionID, entryID: entryID, kind: kind)
        publishHandoff(sessionID: sessionID)
    }

    private func performSend(messageID: UUID) async {
        defer {
            // Nothing here once a cancel superseded this attempt: a newer send may own the shared state by now.
            if !Task.isCancelled {
                inFlightMessageID = nil
                sendJoinedRunningTurn = false
                isSending = false
                // Persist the confirmed correction even when no further event follows its reply.
                saveLiveCheckpoint(force: true)
                if sendPhase == .sending || sendPhase == .stalled {
                    // The pipeline ended without an ack transition, so the status line must not keep promising progress.
                    if outbound.contains(where: { $0.id == messageID && $0.failure != nil }) {
                        sendPhase = .idle
                        watchdogTask?.cancel()
                        watchdogTask = nil
                    }
                }
            }
        }

        guard let promptAPI = app.promptAPI else {
            markFailed(messageID, reason: "Not connected to a backend.")
            return
        }

        do {
            let sessionID = try await ensureSession()
            guard outbound.contains(where: { $0.id == messageID }) else { return }

            await uploadAttachments(messageID: messageID, sessionID: sessionID)
            guard let message = outbound.first(where: { $0.id == messageID }) else { return }
            if message.failure != nil { return }

            // Attachments are never inline in `prompt.submit`: only textual references ride in `text` (reference §6.3), so a picture-only message needs a default question.
            var blocks: [String] = []
            if !message.uploadedReferenceTexts.isEmpty {
                blocks.append(message.uploadedReferenceTexts.joined(separator: "\n"))
            }
            let promptText = message.promptText ?? message.text
            if !promptText.isEmpty { blocks.append(promptText) }
            var body = blocks.joined(separator: "\n\n")
            if body.isEmpty, !message.uploadedImageNames.isEmpty {
                body = "What do you see in this image?"
            }

            // Desktop parity: a Retry or an Edit names the durable row it replaces, looked up by content when the chat never learned it; without one it goes out as a plain send.
            var replacingRowID = message.replacing?.rowID
            if let replacement = message.replacing, replacingRowID == nil {
                replacingRowID = await resolveDurableRowID(for: replacement)
                guard !Task.isCancelled, outbound.contains(where: { $0.id == messageID }) else { return }
            }

            // Handoff: the engine's user entry fronts for the optimistic bubble, because events can arrive before the submit's own response frame.
            app.engine.clearInterrupted(sessionID: sessionID)
            // BUG-019: `live.isBusy` is read here, at the handoff, where it cannot yet be this send's own optimism.
            let handoffID = app.engine.appendUserEntry(
                sessionID: sessionID,
                text: message.promptText == nil ? body : message.text,
                imageRefs: message.uploadedImageNames,
                joiningRunningTurn: live.isBusy
            )
            app.engine.registerSubmission(sessionID: sessionID, ref: messageID.uuidString, entryID: handoffID)
            mutateOutbound(messageID) {
                $0.handedOffEntryID = handoffID
                $0.handedOffSessionID = sessionID
            }
            publishHandoff(sessionID: sessionID)
            if !handoffIsOnScreen(handoffID) {
                // The publish reached no chat, or a different one, so keep the optimistic bubble — it is the only copy left.
                mutateOutbound(messageID) { $0.handedOffEntryID = nil }
            }

            var ackEndedVoiceChat = false
            // Where the acknowledged bubble lives; the resume-and-retry path below moves both.
            var ackedSessionID = sessionID
            var ackedEntryID = handoffID
            do {
                let ack = try await promptAPI.submit(sessionID: sessionID, text: body,
                    submissionRef: app.engine.sharedSessionSupported ? messageID.uuidString : nil,
                    replacingRowID: replacingRowID)
                app.engine.acknowledgeSubmission(sessionID: sessionID, ack: ack)
                lastAckStatus = ack.effectiveStatus
                ackEndedVoiceChat = ack.voiceStopped
                if let rowID = ack.userRowID {
                    // Published now: a turn that fails fast may already have sent its last frame, and a Retry reads `live`.
                    app.engine.setRowID(sessionID: sessionID, entryID: handoffID, rowID: rowID)
                    publishHandoff(sessionID: sessionID)
                }
            } catch let error as HermesError where Self.shouldResumeAndRetrySubmit(error) {
                // First statement in this block, deliberately: `resumeAndBind` applies its result destructively and cancellation does not propagate into `await task.value` of a `Task<_, Never>`.
                guard !Task.isCancelled else { return }
                // Safe recoveries only (reference §7.4): a stale runtime id, a gateway request timeout, or a frame that never left the device. Wire failures that leave the submit unconfirmable are excluded, because a blind resend would run the turn twice.
                guard let storedSessionID = storedSessionID,
                      let result = await resumeAndBind(storedSessionID: storedSessionID)
                else { throw error }
                let retryHandoffID = app.engine.appendUserEntry(
                    sessionID: result.sessionID,
                    text: message.promptText == nil ? body : message.text,
                    joiningRunningTurn: live.isBusy
                )
                app.engine.registerSubmission(sessionID: result.sessionID, ref: messageID.uuidString, entryID: retryHandoffID)
                mutateOutbound(messageID) {
                    $0.handedOffEntryID = retryHandoffID
                    $0.handedOffSessionID = result.sessionID
                }
                publishHandoff(sessionID: result.sessionID)
                if !handoffIsOnScreen(retryHandoffID) {
                    mutateOutbound(messageID) { $0.handedOffEntryID = nil }
                }
                let ack = try await promptAPI.submit(sessionID: result.sessionID, text: body,
                    submissionRef: app.engine.sharedSessionSupported ? messageID.uuidString : nil,
                    replacingRowID: replacingRowID)
                app.engine.acknowledgeSubmission(sessionID: result.sessionID, ack: ack)
                lastAckStatus = ack.effectiveStatus
                ackEndedVoiceChat = ack.voiceStopped
                ackedSessionID = result.sessionID
                ackedEntryID = retryHandoffID
                if let rowID = ack.userRowID {
                    app.engine.setRowID(sessionID: result.sessionID, entryID: retryHandoffID, rowID: rowID)
                    publishHandoff(sessionID: result.sessionID)
                }
            } catch let error as HermesError where replacingRowID != nil && Self.isStaleReplacementTarget(error) {
                // The replaced row was compressed away or deleted on another client, so a Retry naming it again is refused the same way. Desktop re-resolves the turn from a fresh transcript and tries once more (`use-prompt-actions/index.ts:1170-1207`); a turn that cannot be found again leaves the bubble with a Retry that sends the text as a new message, and says so.
                guard !Task.isCancelled, let replacement = message.replacing else { return }
                let resolved = await refindReplacedRow(for: replacement)
                guard !Task.isCancelled, outbound.contains(where: { $0.id == messageID }) else { return }
                guard let resolved, resolved != replacingRowID else {
                    mutateOutbound(messageID) { $0.replacing = nil }
                    throw ReplacementTargetGone()
                }
                replacingRowID = resolved
                mutateOutbound(messageID) { $0.replacing?.rowID = resolved }
                let ack: PromptAck
                do {
                    ack = try await promptAPI.submit(sessionID: sessionID, text: body,
                        submissionRef: app.engine.sharedSessionSupported ? messageID.uuidString : nil,
                        replacingRowID: resolved)
                } catch let again as HermesError where Self.isStaleReplacementTarget(again) {
                    mutateOutbound(messageID) { $0.replacing = nil }
                    throw ReplacementTargetGone()
                }
                app.engine.acknowledgeSubmission(sessionID: sessionID, ack: ack)
                lastAckStatus = ack.effectiveStatus
                ackEndedVoiceChat = ack.voiceStopped
                if let rowID = ack.userRowID {
                    app.engine.setRowID(sessionID: sessionID, entryID: handoffID, rowID: rowID)
                    publishHandoff(sessionID: sessionID)
                }
            }

            // Acknowledged: the engine owns the entry for good now, unless Stop landed while the ack was in flight and the cancelled bubble already carries its verdict.
            if !Task.isCancelled {
                // A stop phrase is answered before any cut is made (`methods_prompt.py:600`), so only a real turn drops what it replaced.
                if let replacement = message.replacing, replacingRowID != nil, !ackEndedVoiceChat {
                    dropSupersededTurn(replacement, keeping: ackedEntryID, sessionID: ackedSessionID)
                }
                let handedOff = outbound.first { $0.id == messageID }
                if ackEndedVoiceChat {
                    // A typed stop phrase was never a message, so the optimistic entry comes back unconditionally — nothing else would ever release the handoff's `isBusy` claim.
                    if let entryID = handedOff?.handedOffEntryID,
                       let sessionID = handedOff?.handedOffSessionID {
                        app.engine.removeEntry(sessionID: sessionID, entryID: entryID)
                        app.publish(sessionID: sessionID)
                    }
                    outbound.removeAll { $0.id == messageID }
                } else if let entryID = handedOff?.handedOffEntryID, handoffIsOnScreen(entryID) {
                    stampAck(onEntry: entryID)
                    outbound.removeAll { $0.id == messageID }
                } else {
                    // BUG-021: the engine's entry is not on screen, and the backend has the message, so dropping the roster row would erase an accepted message from the transcript.
                    mutateOutbound(messageID) { $0.handedOffEntryID = nil }
                }

                // `voice_stopped` is the one ack that promises no turn at all, so `.queued` there would wait on a turn that is never coming.
                if sendPhase == .sending || sendPhase == .stalled {
                    // BUG-135: the test is a streaming entry and NOT `live.isBusy`, which `appendUserEntry` claims optimistically for every send.
                    let turnAlreadyStreaming = live.entries.contains { $0.isStreaming }
                        && !phaseAttachedToRunningTurn
                    sendPhase = (ackEndedVoiceChat || turnAlreadyStreaming) ? .idle : .queued
                    if ackEndedVoiceChat { phaseAttachedToRunningTurn = false }
                    watchdogTask?.cancel()
                    watchdogTask = nil
                }
            }
            // Outside the guard on purpose: for a Home draft's first send this is the only place the chat is registered under its durable key.
            app.chatDidBind(self, storedSessionID: storedSessionID)
        } catch {
            // A cancel that landed mid-flight owns the bubble's verdict.
            guard !Task.isCancelled else { return }
            if let disposition = live.submissionDispositions[messageID.uuidString],
               ["executing", "queued", "terminal", "absorbed", "cancelled"].contains(disposition) {
                // Positive server evidence survived a lost reply. Never offer a
                // blind retry that would create another occurrence.
                lastAckStatus = disposition == "queued" ? "queued" : "streaming"
                if let entryID = outbound.first(where: { $0.id == messageID })?.handedOffEntryID,
                   handoffIsOnScreen(entryID) { outbound.removeAll { $0.id == messageID } }
                sendPhase = disposition == "queued" ? .queued : .idle
                return
            }
            // BUG-141: a 4090 that names why it refused gets plain language; everything else goes through `describe(error)` untouched.
            let refusal = (error as? HermesError)?.activeSessionRefusal
            markFailed(
                messageID,
                reason: Self.failureText(refusal: refusal, fallback: describe(error)),
                refusal: refusal
            )
        }
    }

    /// The user-facing sentence for a failed send; the `nil` arm returns `fallback` untouched.
    static func failureText(
        refusal: HermesError.ActiveSessionRefusal?,
        fallback: String
    ) -> String {
        switch refusal {
        case .sessionNotOwned:
            return "This conversation is open on another device. Close it there, or start a new chat."
        case .coordinationUnavailable:
            return "Hermes can't verify who owns this conversation. This needs attention on the computer running Hermes."
        case .maxConcurrentSessions, nil:
            // Capacity is genuinely transient, and `nil` is the old backend, which must not change.
            return fallback
        }
    }

    /// BUG-141: what the view needs to decide which actions a failed bubble may honestly offer; nil for every row that is not a labelled 4090 refusal.
    func outboundRefusal(for id: UUID) -> HermesError.ActiveSessionRefusal? {
        outbound.first { $0.id == id }?.refusal
    }

    /// Failure rolls the optimistic bubble back visibly — it dims and gains an inline Retry, never silently removed.
    private func markFailed(
        _ messageID: UUID,
        reason: String,
        refusal: HermesError.ActiveSessionRefusal? = nil
    ) {
        if let index = outbound.firstIndex(where: { $0.id == messageID }) {
            if let entryID = outbound[index].handedOffEntryID {
                // The session the handoff was made under, not the one this chat is bound to now.
                if let sessionID = outbound[index].handedOffSessionID {
                    app.engine.removeEntry(sessionID: sessionID, entryID: entryID)
                    app.publish(sessionID: sessionID)
                }
                outbound[index].handedOffEntryID = nil
            }
            outbound[index].failure = reason
            outbound[index].refusal = refusal
        } else {
            errorMessage = reason
        }
        sendPhase = .idle
        phaseAttachedToRunningTurn = false
        lastAckStatus = nil
        watchdogTask?.cancel()
        watchdogTask = nil
    }

    private func uploadAttachments(messageID: UUID, sessionID: String) async {
        guard let attachmentAPI = app.attachmentAPI,
              let snapshot = outbound.first(where: { $0.id == messageID }),
              !snapshot.attachments.isEmpty
        else { return }
        for attachment in snapshot.attachments where !snapshot.uploadedIDs.contains(attachment.id) {
            do {
                switch attachment.kind {
                case .image:
                    let result = try await attachmentAPI.attachImageBytes(
                        sessionID: sessionID,
                        data: attachment.data,
                        filename: attachment.filename
                    )
                    // The bubble is keyed by the gateway's own path, the name history will carry, and the bytes stay on the phone under it so the thumbnail never has to come back over the wire.
                    let ref = result.path.isEmpty ? attachment.filename : result.path
                    MediaByteCache.shared.remember(attachment.data, keys: [attachment.filename, ref])
                    mutateOutbound(messageID) {
                        $0.uploadedIDs.insert(attachment.id)
                        $0.uploadedImageNames.append(ref)
                    }
                case .file:
                    let result = try await attachmentAPI.attachFile(
                        sessionID: sessionID,
                        data: attachment.data,
                        filename: attachment.filename,
                        mimeType: attachment.mimeType
                    )
                    mutateOutbound(messageID) {
                        $0.uploadedIDs.insert(attachment.id)
                        if !result.refText.isEmpty { $0.uploadedReferenceTexts.append(result.refText) }
                    }
                }
            } catch {
                // A cancel that landed mid-upload owns the bubble's verdict.
                guard !Task.isCancelled else { return }
                mutateOutbound(messageID) { message in
                    message.failure = "\(attachment.filename): \(self.describe(error))"
                }
                return
            }
        }
    }

    private func mutateOutbound(_ id: UUID, _ change: (inout OutboundMessage) -> Void) {
        guard let index = outbound.firstIndex(where: { $0.id == id }) else { return }
        change(&outbound[index])
    }

    // MARK: - Interrupt

    func interrupt() async {
        guard let sessionID = runtimeSessionID, let sessionAPI = app.sessionAPI else { return }
        // Finalise locally first so the composer re-enables immediately and stale in-flight events are ignored (reference §3.5).
        app.engine.markInterrupted(sessionID: sessionID)
        app.publish(sessionID: sessionID)
        do {
            try await sessionAPI.interrupt(sessionID: sessionID)
        } catch let error as HermesError where error.isSessionNotFound {
            guard let storedSessionID = storedSessionID, let result = await resumeAndBind(storedSessionID: storedSessionID) else { return }
            // The resume cleared `interrupted`, so re-assert the Stop through `markInterrupted` — a bare flag write would leave `interruptedAt` stale.
            app.engine.markInterrupted(sessionID: result.sessionID)
            live = app.engine.state(for: result.sessionID)
            do {
                try await sessionAPI.interrupt(sessionID: result.sessionID)
            } catch {
                // Both interrupts failed, and the bare error renders as "session not found", which never says it was the Stop that did not land.
                errorMessage = "Couldn't stop the turn: \(describe(error))"
            }
        } catch {
            errorMessage = describe(error)
        }
    }

    // MARK: - Blocking prompts

    func respond(to approval: ApprovalRequestEvent, choice: ApprovalChoice) async {
        guard let approvalAPI = app.approvalAPI, let sessionID = runtimeSessionID else { return }
        // `approval.respond` is positional FIFO with no request id, so answering a non-head approval would consume whatever prompt is at the head.
        guard live.currentApproval?.id == approval.id else { return }
        HapticFeedback.decisionSubmitted(isDeny: choice == .deny)
        // Disarm the expiry timer across the await, or it can fire mid-flight and claim the approval expired while the backend is running the command.
        cancelApprovalExpiry()
        do {
            let resolved = try await approvalAPI.respond(sessionID: sessionID, choice: choice, serverRequest: approval.serverRequest, legacyRequestID: approval.legacyRequestID)
            app.engine.removeApproval(sessionID: sessionID, id: approval.id)
            app.publish(sessionID: sessionID)
            if resolved == false {
                // `nil` is not `false`: a backend that sent no `resolved` key made no claim, and inventing one would accuse the user of being too late on every tap.
                errorMessage = "Too late — this request was no longer waiting (it expired or was answered elsewhere), so your choice did not apply."
            }
        } catch {
            errorMessage = describe(error)
            rescheduleApprovalExpiry()
        }
    }

    // MARK: - Approval expiry (SEC-006)

    /// The head approval's countdown budget, or nil when none may be drawn: one source for the sheet's countdown, the docked bar's and the dismissal timer, so they cannot disagree.
    ///
    /// The anchor is `receivedAt` at this client, one transport hop behind the backend's own deadline, so the timer can only fire after the backend has already given up (BUG-073).
    func approvalBudget(for approval: ApprovalRequestEvent) -> (received: Date, seconds: TimeInterval)? {
        // Current requests expire through request.cancel, never a guessed local deadline.
        guard approval.serverRequest == nil, let seconds = app.settings.approvalTimeoutSeconds(), seconds > 0 else { return nil }
        return (approval.receivedAt, seconds)
    }

    /// The approval the dismissal timer is armed for.
    private var approvalExpiryID: UUID?
    private var approvalExpiryDeadline: Date?
    private var approvalExpiryTask: Task<Void, Never>?

    /// Keep the dismissal timer aimed at the head of the approval FIFO; a no-op unless the head or its effective deadline changed, which is how a late configuration load replaces the fallback timeout.
    private func rescheduleApprovalExpiry() {
        let head = storedLive.currentApproval
        let budget = head.flatMap { approvalBudget(for: $0) }
        let deadline = budget.map { $0.received.addingTimeInterval($0.seconds) }
        guard head?.id != approvalExpiryID || deadline != approvalExpiryDeadline else { return }
        cancelApprovalExpiry()
        guard let head, let deadline else { return }
        approvalExpiryID = head.id
        approvalExpiryDeadline = deadline
        approvalExpiryTask = Task { [weak self] in
            // Re-check the wall clock on every wake: sleeps pause with a suspended app, and the deadline must hold across backgrounding.
            while !Task.isCancelled {
                let remaining = deadline.timeIntervalSinceNow
                if remaining <= 0 { break }
                try? await Task.sleep(nanoseconds: UInt64(min(remaining, 1) * 1_000_000_000))
            }
            guard !Task.isCancelled else { return }
            self?.expireApproval(id: head.id)
        }
    }

    private func cancelApprovalExpiry() {
        approvalExpiryTask?.cancel()
        approvalExpiryTask = nil
        approvalExpiryID = nil
        approvalExpiryDeadline = nil
    }

    /// The countdown reached zero: the backend has already refused the command with no frame to say so, so stop showing a consent prompt for it (SEC-006).
    private func expireApproval(id: UUID) {
        approvalExpiryTask = nil
        approvalExpiryID = nil
        approvalExpiryDeadline = nil
        guard let sessionID = runtimeSessionID,
              live.currentApproval?.id == id else { return }
        app.engine.removeApproval(sessionID: sessionID, id: id)
        app.publish(sessionID: sessionID)
        ApprovalNotifications.clear(sessionID: sessionID)
        errorMessage = "The approval expired with no decision, so the backend refused the command. Nothing was run."
    }

    func respondClarify(_ answer: String, requestID: String) async {
        guard let approvalAPI = app.approvalAPI,
              let request = live.clarify,
              request.id == requestID,
              let sessionID = runtimeSessionID
        else { return }
        // Never silently consent: a dismissal sends an empty string, not "no response" (reference §5.3).
        do {
            _ = try await approvalAPI.respondClarify(requestID: request.id, answer: answer, serverRequest: request.serverRequest, isBatch: request.isBatch)
            if request.serverRequest == nil || live.clarify?.id == request.id {
                app.engine.clearClarify(sessionID: sessionID)
            }
            app.publish(sessionID: sessionID)
        } catch {
            errorMessage = describe(error)
        }
    }

    /// Batch clarify: lock one question's answer, addressed by its qid, and return the acknowledgment plus its client revision; clearing the card is `finishClarify`'s job once the whole set has landed.
    func lockClarifyAnswer(_ answer: String, questionID: String, requestID: String) async -> ClarifyRespondResult? {
        guard let approvalAPI = app.approvalAPI,
              let request = live.clarify,
              request.id == requestID
        else { return nil }
        do {
            let result = try await approvalAPI.respondClarify(
                requestID: request.id, answer: answer, questionID: questionID, serverRequest: request.serverRequest
            )
            return result.status != "expired" ? result : nil
        } catch {
            errorMessage = describe(error)
            return nil
        }
    }

    /// Tear a batch clarify card down once every answer has landed; the final lock already resumed the turn server-side.
    func finishClarify(requestID: String) {
        guard let sessionID = runtimeSessionID, live.clarify?.id == requestID else { return }
        app.engine.clearClarify(sessionID: sessionID)
        app.publish(sessionID: sessionID)
    }

    func respondSudo(_ password: String, requestID: String) async {
        guard let approvalAPI = app.approvalAPI,
              let request = live.sudo,
              request.id == requestID,
              let sessionID = runtimeSessionID
        else { return }
        do {
            _ = try await approvalAPI.respondSudo(requestID: request.id, password: password, serverRequest: request.serverRequest)
            if request.serverRequest == nil || live.sudo?.id == request.id {
                app.engine.clearSudo(sessionID: sessionID)
            }
            app.publish(sessionID: sessionID)
        } catch {
            errorMessage = describe(error)
        }
    }

    func respondSecret(_ value: String, requestID: String) async {
        guard let approvalAPI = app.approvalAPI,
              let request = live.secret,
              request.id == requestID,
              let sessionID = runtimeSessionID
        else { return }
        do {
            _ = try await approvalAPI.respondSecret(requestID: request.id, value: value, serverRequest: request.serverRequest)
            if request.serverRequest == nil || live.secret?.id == request.id {
                app.engine.clearSecret(sessionID: sessionID)
            }
            app.publish(sessionID: sessionID)
        } catch {
            errorMessage = describe(error)
        }
    }

    func dismissAutoContinueNotice() {
        guard let sessionID = runtimeSessionID else { return }
        app.engine.clearAutoContinue(sessionID: sessionID)
        app.publish(sessionID: sessionID)
    }

    // MARK: - Attachments

    func addAttachment(data: Data, filename: String, mimeType: String) {
        let isImage = AttachmentAPI.isAttachableAsImage(filename: filename, mimeType: mimeType)
        if isImage, data.count > AttachmentAPI.imageByteLimit {
            errorMessage = HermesError
                .attachmentTooLarge(bytes: data.count, limit: AttachmentAPI.imageByteLimit)
                .localizedDescription
            return
        }
        attachments.append(
            PendingAttachment(
                filename: filename,
                mimeType: mimeType,
                data: data,
                kind: isImage ? .image : .file
            )
        )
        // The optimistic bubble names the pick by its filename; holding the bytes under it draws the thumbnail before the upload answers.
        if isImage { MediaByteCache.shared.remember(data, keys: [filename]) }
    }

    func removeAttachment(id: UUID) {
        attachments.removeAll { $0.id == id }
    }

    // MARK: - Message actions

    /// Branch this conversation into a new chat, truncated at `entry` when it carries a backend ordinal; returns the new durable id on success.
    func branch(fromEntryID entryID: String, name: String) async -> String? {
        guard let sessionAPI = app.sessionAPI, let runtimeSessionID else {
            errorMessage = "Not connected to a backend."
            return nil
        }
        do {
            let result = try await sessionAPI.branch(
                sessionID: runtimeSessionID,
                count: historyOrdinals[entryID],
                name: name.trimmingCharacters(in: .whitespacesAndNewlines)
            )
            // BUG-052: hand the child its transcript before anything navigates to it, or the screen draws the new-conversation greeting until its own history call answers.
            seedBranchedChild(storedSessionID: result.storedSessionID, throughEntryID: entryID)
            await app.refreshThreads(force: true)
            return result.storedSessionID.isEmpty ? nil : result.storedSessionID
        } catch {
            errorMessage = describe(error)
            return nil
        }
    }

    /// The rows the branch just copied, as this chat already has them, so the client need not wait for the backend to read back what it just wrote.
    private func seedBranchedChild(storedSessionID: String, throughEntryID entryID: String) {
        guard !storedSessionID.isEmpty,
              let cut = history.firstIndex(where: { $0.id == entryID })
        else { return }
        // The branch wrote the child's copies under new durable rows, so the parent's would aim a Retry in the child at rows it does not have (4018).
        let rows = history[...cut].map { row -> ChatEntry in
            var copy = row
            copy.rowID = nil
            return copy
        }
        var ordinals: [String: Int] = [:]
        for row in rows where historyOrdinals[row.id] != nil {
            ordinals[row.id] = historyOrdinals[row.id]
        }
        app.seedBranchedTranscript(storedSessionID: storedSessionID, entries: rows, ordinals: ordinals)
    }

    /// The message count a branch at `entry` would carry; nil for live entries, which have no ordinal yet.
    func branchCount(forEntryID entryID: String) -> Int? {
        historyOrdinals[entryID]
    }

    /// Retry: replace the user turn preceding `entry`, and everything after it, with the same text. `prompt.submit`'s `truncate_before_row_id` drops the old turn instead of appending a duplicate the model also sees; a turn with no durable row degrades to a plain resend, which appends, as Desktop's does.
    ///
    /// BUG-146: through `enqueueSend`, the one send prologue, so a retry with no backend is refused up front rather than spawning a send that can only fail, and with no copy of the prologue left to drift (the old copy's `live.isBusy` writes were dead behind its own `!live.isBusy` guard).
    func resendPrecedingUserTurn(before entryID: String) {
        guard let userEntry = precedingUserEntry(before: entryID) else { return }
        guard !live.isBusy else { return }
        enqueueSend(text: userEntry.text, attachments: [], replacing: replacement(for: userEntry))
    }

    /// The user turn a Retry or an Edit on the reply `entryID` acts on.
    func precedingUserEntry(before entryID: String) -> ChatEntry? {
        guard let index = entries.firstIndex(where: { $0.id == entryID }) else { return nil }
        return entries[..<index].last(where: { $0.kind == .user })
    }

    /// What a Retry or an Edit of `entry` replaces, or nil when it can only go out as a plain send: a queued, mid-turn or optimistic row is not an addressable turn, and a turn with images cannot be rebuilt from its text without dropping them from what the model sees.
    private func replacement(for entry: ChatEntry) -> OutboundMessage.Replacement? {
        guard entry.kind == .user, entry.noticeKind.isEmpty, entry.imageRefs.isEmpty,
              !entry.id.hasPrefix("outbound-") else { return nil }
        let users = entries.filter { $0.kind == .user && $0.noticeKind.isEmpty }
        let after = users.firstIndex { $0.id == entry.id }.map { users.count - $0 - 1 } ?? 0
        return OutboundMessage.Replacement(entryID: entry.id, rowID: entry.rowID, text: entry.text,
                                           isLatestUserTurn: users.last?.id == entry.id,
                                           userTurnsAfter: after, userTurnCount: users.count)
    }

    static let replacementOvertakenNotice = "Newer messages follow the one this was replacing, so it was sent as a new message and nothing was deleted."

    struct ReplacementTargetGone: LocalizedError {
        static let notice = "The message this was replacing is no longer in the conversation, so it could not be replaced. Retry sends it as a new message."
        var errorDescription: String? { Self.notice }
    }

    /// 4018 is also the backend's code for an oversized PDF, so the sentence decides, as Desktop's check does (`use-prompt-actions/index.ts:1133-1134`).
    nonisolated static func isStaleReplacementTarget(_ error: HermesError) -> Bool {
        guard case let .rpc(code, message, _) = error, code == 4018 else { return false }
        let text = message.lowercased()
        return text.contains("no longer in session history") || text.contains("not in session history")
    }

    /// Whether the chat now shows more user turns than when `replacement` was composed, in all or after its target — the turns a cut would now delete that the person never agreed to lose. The retried message's own failed bubble is not one of them.
    private func newerTurnsFollow(_ replacement: OutboundMessage.Replacement, retrying messageID: UUID) -> Bool {
        let own = "outbound-\(messageID.uuidString)"
        let users = entries.filter { $0.kind == .user && $0.noticeKind.isEmpty && $0.id != own }
        if users.count > replacement.userTurnCount { return true }
        // Found by id, or by row once a reload has renamed it `rest-<rowID>`; a target found by neither leaves the count above as the whole test.
        let restID = replacement.rowID.map { "rest-\($0)" }
        guard let index = users.firstIndex(where: { entry in
            entry.id == replacement.entryID || entry.id == restID
                || (replacement.rowID != nil && entry.rowID == replacement.rowID)
        }) else { return false }
        return users.count - index - 1 > replacement.userTurnsAfter
    }

    /// The backend accepted the replacement, so the superseded turn leaves the screen now rather than at the next reload; the transcript reload when the new turn ends is still the authoritative picture, and it rebinds any survivor row the cut rewrote (`survivor_row_id_map`).
    private func dropSupersededTurn(_ replacement: OutboundMessage.Replacement, keeping keepEntryID: String, sessionID: String) {
        needsHistoryReconciliation = true
        guard handoffIsOnScreen(keepEntryID) else { return }
        if let cut = history.firstIndex(where: { $0.id == replacement.entryID }) {
            for entry in history[cut...] { historyOrdinals[entry.id] = nil }
            history.removeSubrange(cut...)
            // Everything live sits below the REST history, so all of it before the replacement went with the cut.
            app.engine.dropEntries(sessionID: sessionID, from: nil, before: keepEntryID)
        } else {
            app.engine.dropEntries(sessionID: sessionID, from: replacement.entryID, before: keepEntryID)
        }
        publishHandoff(sessionID: sessionID)
    }

    /// Desktop's `resolveDurableRowId` (`apps/desktop/src/app/session/hooks/use-prompt-actions/rewind.ts:213-257`) over the REST transcript, for a turn whose row this chat never learned (a mirrored turn, an older backend's ack). Nil sends the text as a plain message; it never guesses a cut.
    private func resolveDurableRowID(for replacement: OutboundMessage.Replacement) async -> Int? {
        guard let rest = app.rest, let storedSessionID else { return nil }
        guard let page = try? await rest.getMessages(sessionID: storedSessionID, profile: profileScope) else { return nil }
        return Self.durableRowID(matching: replacement.text, in: page.messages, targetIsLatest: replacement.isLatestUserTurn)
    }

    /// The replaced turn looked up again after the backend refused its row with 4018, from a fresh REST page.
    private func refindReplacedRow(for replacement: OutboundMessage.Replacement) async -> Int? {
        guard let rest = app.rest, let storedSessionID else { return nil }
        guard let page = try? await rest.getMessages(sessionID: storedSessionID, profile: profileScope) else { return nil }
        return Self.refoundRowID(for: replacement, in: page.messages)
    }

    /// Which row of `rows` is the replaced turn, once the backend has said its old row is gone.
    ///
    /// A text match alone is not enough here: the old row is gone by the backend's word, so a lone match may be a different message that reads the same, before or after it, and a cut there deletes turns the person never agreed to lose. The match counts only where the person saw the replaced turn: as many user turns in all as when they chose it, and as many after it.
    nonisolated static func refoundRowID(for replacement: OutboundMessage.Replacement, in rows: [TranscriptMessage]) -> Int? {
        guard let found = durableRowID(matching: replacement.text, in: rows, targetIsLatest: replacement.isLatestUserTurn) else { return nil }
        let users = rows.filter { $0.role == .user && $0.displayKind.isEmpty && $0.id > 0 }
        guard users.count == replacement.userTurnCount,
              let index = users.firstIndex(where: { $0.id == found }),
              users.count - index - 1 == replacement.userTurnsAfter
        else { return nil }
        return found
    }

    /// Exact-or-nothing: a unique trimmed-text match among real user rows wins; with several, the last one only when the target is the latest user turn and that match is the latest user row.
    nonisolated static func durableRowID(matching text: String, in rows: [TranscriptMessage], targetIsLatest: Bool) -> Int? {
        let wanted = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !wanted.isEmpty else { return nil }
        let users = rows.filter { $0.role == .user && $0.displayKind.isEmpty && $0.id > 0 }
        let matches = users.filter {
            DisplayRedaction.stripImageDirectives($0.content.plainText).body
                .trimmingCharacters(in: .whitespacesAndNewlines) == wanted
        }
        if matches.count == 1 { return matches[0].id }
        if matches.count > 1, targetIsLatest, let last = matches.last, users.last?.id == last.id { return last.id }
        return nil
    }

    // MARK: - Edit & resend

    /// The user turn the composer is replacing; nil for an ordinary send.
    private(set) var editingEntryID: String?

    /// Whether `entryID` is a user turn this chat can load into the composer and replace.
    func canEdit(entryID: String) -> Bool {
        guard let entry = entries.first(where: { $0.id == entryID }) else { return false }
        return replacement(for: entry) != nil
    }

    /// Load the user turn into the composer; Send then replaces it and everything after it. Refused while the composer holds other unsent work, which this would overwrite.
    @discardableResult
    func beginEditing(entryID: String) -> Bool {
        guard canEdit(entryID: entryID), let entry = entries.first(where: { $0.id == entryID }) else { return false }
        let pending = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (pending.isEmpty || pending == entry.text) && attachments.isEmpty else {
            errorMessage = "Send or clear what is in the composer before editing an earlier message."
            return false
        }
        editingEntryID = entryID
        editingTarget = replacement(for: entry)
        draft = entry.text
        errorMessage = nil
        return true
    }

    /// Leave edit mode and discard the edit; the earlier message is untouched.
    func cancelEditing() {
        guard editingEntryID != nil else { return }
        editingEntryID = nil
        editingTarget = nil
        draft = ""
    }

    /// The turn being edited as it was when editing began. An edit may begin while its turn runs, and the reload when the turn ends replaces every live entry with `rest-<rowID>` rows (`install(page:)`), so Send must be able to find the turn again without its old id.
    private var editingTarget: OutboundMessage.Replacement?

    /// The entry the edit replaces now: by id; once a reload has renamed it, by durable row, or, for a turn whose row this chat never learned, by the exact-text rule `durableRowID(matching:in:targetIsLatest:)` applies to the REST rows. Nil only when the turn has really left the transcript.
    private func editedEntry(_ entryID: String) -> ChatEntry? {
        if let entry = entries.first(where: { $0.id == entryID }) { return entry }
        guard let target = editingTarget, target.entryID == entryID else { return nil }
        let users = entries.filter { $0.kind == .user && $0.noticeKind.isEmpty && !$0.id.hasPrefix("outbound-") }
        if let rowID = target.rowID {
            return users.first { $0.rowID == rowID || $0.id == "rest-\(rowID)" }
        }
        let wanted = target.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !wanted.isEmpty else { return nil }
        let matches = users.filter { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) == wanted }
        if matches.count == 1 { return matches[0] }
        if matches.count > 1, target.isLatestUserTurn, let last = matches.last, users.last?.id == last.id { return last }
        return nil
    }

    // MARK: - Connection card

    /// The `manage_connections` operation the agent is blocked on in this chat.
    var pendingConnection: ConnectionRequest? { live.connection }

    /// True while an answer to the card is on the wire, so its buttons cannot double-send.
    private(set) var isAnsweringConnection = false

    /// Not now on one row.
    func skipConnectionTarget(_ name: String) {
        answerConnection { api, sessionID, opID in
            try await api.skip(sessionID: sessionID, opID: opID, targets: [name])
        }
    }

    /// End the operation now with whatever is unresolved; the agent continues without it.
    func continueConnection() {
        answerConnection { api, sessionID, opID in
            try await api.continueOperation(sessionID: sessionID, opID: opID)
        }
    }

    /// The browser leg of a sign-in came back: ask the backend to read the account now instead of at its next tick. Best effort; the backend's own watcher reads it regardless.
    func wakeConnection() {
        guard let card = live.connection, let client = app.client else { return }
        Task { await ConnectorsAPI(client: client).wake(sessionID: card.sessionID, opID: card.opID) }
    }

    /// One answer at a time. The card itself never changes here: only the backend's `connection.update` (or its settlement) moves a row, because the card is a projection of the operation (`connectors_operation.py:1-8`).
    private func answerConnection(
        _ send: @escaping (ConnectorsAPI, String, String) async throws -> ConnectionRespondResult
    ) {
        guard !isAnsweringConnection, let card = live.connection, let client = app.client else { return }
        isAnsweringConnection = true
        errorMessage = nil
        Task {
            defer { isAnsweringConnection = false }
            do {
                _ = try await send(ConnectorsAPI(client: client), card.sessionID, card.opID)
            } catch {
                guard live.connection?.opID == card.opID else { return }
                errorMessage = "Couldn't answer the connection request: \(describe(error))"
            }
        }
    }

    /// Whether the turn that produced `entry` ran tools that mutate state, in which case retrying discards work and the affordance escalates to a hold.
    /// The demo's tool rows are scripted and nothing ran, so none of its turns did.
    func turnMutatedState(before entryID: String) -> Bool {
        guard app.demo == nil else { return false }
        guard let index = entries.firstIndex(where: { $0.id == entryID }) else { return false }
        guard let userIndex = entries[..<index].lastIndex(where: { $0.kind == .user }) else { return false }
        return entries[userIndex...index].contains { entry in
            guard entry.kind == .tool, let tool = entry.tool else { return false }
            switch ToolCardView.Family(toolName: tool.name) {
            case .terminal, .edit: return true
            case .file: return tool.name.lowercased().contains("write")
            // `.todo` writes only the agent's own plan, so re-running discards nothing on the user's machine.
            case .search, .browser, .todo, .other: return false
            }
        }
    }

    #if DEBUG
    /// Screenshot harness: the cold-open loading state, held open with no backend; `hasLoadedOnce` stays false so `transcriptGap` reads `.pending` as it would on a real cold open.
    func seedLoadingState() {
        history = []
        isLoading = true
        hasLoadedOnce = false
    }

    /// Screenshot harness: a canned transcript exercising every tool-card state, including an output past the elision budget.
    func seedDemoTranscript() {
        let now = Date()
        let longOutput = (1...2_500)
            .map { "line \($0)  ── a reasonably wide line of terminal output to prove the horizontal axis scrolls" }
            .joined(separator: "\n")
        history = [
            ChatEntry(id: "demo-u1", kind: .user, text: "Run the test suite and fix whatever fails.", timestamp: now),
            ChatEntry(id: "demo-a1", kind: .assistant, text: "Running the suite now.", status: "complete", timestamp: now),
            ChatEntry(id: "demo-t1", kind: .tool, tool: ToolActivity(
                id: "demo-t1", name: "terminal",
                context: "swift test --package-path HermesServeKit",
                resultText: longOutput, durationSeconds: 42.3, isRunning: false
            ), timestamp: now),
            ChatEntry(id: "demo-t2", kind: .tool, tool: ToolActivity(
                id: "demo-t2", name: "read", context: "HermesApp/Views/ChatView.swift",
                resultText: "import SwiftUI\n…", durationSeconds: 0.2, isRunning: false
            ), timestamp: now),
            ChatEntry(id: "demo-t3", kind: .tool, tool: ToolActivity(
                id: "demo-t3", name: "read", context: "HermesApp/Views/ComposerView.swift",
                resultText: "import SwiftUI\n…", durationSeconds: 0.3, isRunning: false
            ), timestamp: now),
            ChatEntry(id: "demo-t4", kind: .tool, tool: ToolActivity(
                id: "demo-t4", name: "read", context: "HermesApp/Models/ChatModel.swift",
                resultText: "import Foundation\n…", durationSeconds: 0.2, isRunning: false
            ), timestamp: now),
            ChatEntry(id: "demo-t5", kind: .tool, tool: ToolActivity(
                id: "demo-t5", name: "edit", context: "TurnEngine.swift",
                inlineDiff: "--- a/TurnEngine.swift\n+++ b/TurnEngine.swift\n@@ -635,6 +635,8 @@\n     state.secret = nil\n     state.terminalRead = nil\n+    // Risk signals are scoped to their turn.\n+    heldRisks[sessionID] = nil\n-    let finalText = event.text\n+    let finalText = event.displayText",
                durationSeconds: 0.8, isRunning: false
            ), timestamp: now),
            ChatEntry(id: "demo-t6", kind: .tool, tool: ToolActivity(
                id: "demo-t6", name: "terminal", context: "xcodebuild -scheme HermesMobile build",
                resultText: "error: no signing certificate found",
                errorText: "exit status 65", durationSeconds: 12.1, isRunning: false
            ), timestamp: now),
            ChatEntry(id: "demo-t7", kind: .tool, tool: ToolActivity(
                id: "demo-t7", name: "terminal", context: "swift build --package-path HermesServeKit",
                isRunning: true
            ), timestamp: now),
        ]
        hasLoadedOnce = true
    }

    /// A transcript with the shape BUG-016 needs: many rows, most of them unrealized, each carrying a greppable index.
    ///
    /// Deliberately heterogeneous — a lazy stack's estimate is accurate when every row is the same size, so uniform rows cannot reproduce the blanking at all.
    func seedLongDemoTranscript(entries: Int = 60) {
        let start = Date().addingTimeInterval(-Double(entries) * 30)
        // Sized like a real conversation: a 2,500-line dump repeated here wedges the main thread for 30 s and the harness fails waiting for the first row.
        let dump = (1...120)
            .map { "line \($0)  ── a reasonably wide line of terminal output, wide enough to scroll" }
            .joined(separator: "\n")
        let wall = (1...8)
            .map { "Paragraph \($0) of a long answer that wraps several times on a phone width." }
            .joined(separator: "\n\n")

        history = (0..<entries).map { index in
            let timestamp = start.addingTimeInterval(Double(index) * 30)
            // The ratio matters more than the exact numbers: most rows are cheap and stay unrealized, and the few that are not are wildly outside the average.
            if index % 8 == 3 {
                return ChatEntry(id: "long-t\(index)", kind: .tool, tool: ToolActivity(
                    id: "long-t\(index)", name: "terminal",
                    context: "transcript row \(index) — swift test",
                    resultText: dump, durationSeconds: 42.3, isRunning: false
                ), timestamp: timestamp)
            }
            if index % 4 == 1 {
                return ChatEntry(
                    id: "long-a\(index)",
                    kind: .assistant,
                    text: "transcript row \(index) — answer \(index / 2 + 1)\n\n\(wall)",
                    status: "complete",
                    timestamp: timestamp
                )
            }
            return index.isMultiple(of: 2)
                ? ChatEntry(
                    id: "long-u\(index)",
                    kind: .user,
                    text: "transcript row \(index) — question \(index / 2 + 1)",
                    timestamp: timestamp
                )
                : ChatEntry(
                    id: "long-a\(index)",
                    kind: .assistant,
                    text: "transcript row \(index) — answer \(index / 2 + 1)",
                    status: "complete",
                    timestamp: timestamp
                )
        }
        hasLoadedOnce = true
    }

    /// BUG-123's cost fixture: a tool-heavy page, not a history, so it goes through the same projection a real transcript does — and deliberately not randomised, since a fixture that changes between runs cannot compare two builds.
    nonisolated static func toolHeavyTranscriptPage(turns count: Int = 240) -> TranscriptPage {
        let start: Double = 1_700_000_000
        // 120 lines is a believable `swift test` tail; a 2,500-line dump measures nothing but the main thread wedging.
        let dump = (1...120)
            .map { "line \($0)  -- a reasonably wide line of terminal output, wide enough to scroll" }
            .joined(separator: "\n")
        let diff = """
        --- a/HermesApp/Views/ChatView.swift
        +++ b/HermesApp/Views/ChatView.swift
        @@ -524,7 +524,7 @@
        -                LazyVStack(alignment: .leading, spacing: Space.s7) {
        +                VStack(alignment: .leading, spacing: Space.s7) {
                             if hiddenEarlierCount > 0 {
        """
        // The expensive answer: every block kind `MarkdownText` knows, because each one becomes its own `SelectableText`.
        let structured = """
        ## What I found

        The transcript is laid out by a plain stack now, so **every** row in the window is in the hierarchy on open.

        1. `ChatModel.applyTranscript` writes `history` on the main actor.
        2. `MarkdownText` parses blocks per row, then `MarkdownParser.inline` per line.
        3. Each line becomes a read-only `UITextView` through `SelectableText`.

        - The parse is memoised per view identity, so a *cold* open never hits the cache.
        - `sizeThatFits` runs a full TextKit layout for each of those views.
        - Tool cards and reasoning traces are the tallest rows in the app.

        > The window is counted in entries, which charges the same for a one-line reply and a thousand-line dump.

        ```swift
        VStack(alignment: .leading, spacing: Space.s7) {
            ForEach(items) { item in row(item) }
        }
        ```

        | Stage | Where | Actor |
        |---|---|---|
        | decode | `RestAPI.getMessages` | background |
        | project | `ChatModel.applyTranscript` | main |
        | layout | `ChatView.transcript` | main |
        """
        let reasoning = (1...6)
            .map { "Considering approach \($0): the placement ladder resolves against the content height, so an exact height changes what every rung computes." }
            .joined(separator: "\n\n")

        var rows: [TranscriptMessage] = []
        var id = 0
        func push(_ fields: [String: JSONValue]) {
            id += 1
            var object = fields
            object["id"] = .number(Double(id))
            object["session_id"] = .string("cold-open-fixture")
            object["timestamp"] = .number(start + Double(id) * 45)
            rows.append(TranscriptMessage(json: .object(object)))
        }

        for index in 0..<count {
            switch index % 6 {
            case 0:
                push([
                    "role": .string("user"),
                    "content": .string("row \(index) -- can you look at the transcript view and tell me why it is slow?"),
                ])
            case 1:
                push(["role": .string("assistant"), "content": .string("row \(index) -- reading the view now.")])
            case 2:
                push([
                    "role": .string("assistant"),
                    "content": .null,
                    "tool_calls": .array([.object([
                        "id": .string("call-t\(index)"),
                        "function": .object([
                            "name": .string("terminal"),
                            "arguments": .string("{\"command\":\"swift test --package-path HermesServeKit\"}"),
                        ]),
                    ])]),
                ])
                push([
                    "role": .string("tool"),
                    "tool_call_id": .string("call-t\(index)"),
                    "tool_name": .string("terminal"),
                    "content": .string(dump),
                ])
            case 3:
                push([
                    "role": .string("assistant"),
                    "content": .string("row \(index) -- here is what the ladder does on first paint."),
                    "reasoning": .string(reasoning),
                ])
            case 4:
                push([
                    "role": .string("assistant"),
                    "content": .null,
                    "tool_calls": .array([.object([
                        "id": .string("call-e\(index)"),
                        "function": .object([
                            "name": .string("edit"),
                            "arguments": .string("{\"path\":\"HermesApp/Views/ChatView.swift\"}"),
                        ]),
                    ])]),
                ])
                push([
                    "role": .string("tool"),
                    "tool_call_id": .string("call-e\(index)"),
                    "tool_name": .string("edit"),
                    "content": .string(diff),
                ])
            default:
                push([
                    "role": .string("assistant"),
                    "content": .string("row \(index) -- the answer\n\n\(structured)"),
                ])
            }
        }
        return TranscriptPage(sessionID: "", messages: rows)
    }

    /// Install a fixture page through the main-actor projection.
    func seedFixturePageOnMain(_ page: TranscriptPage) {
        applyTranscript(page)
        hasLoadedOnce = true
    }

    /// Install a fixture page through the off-main projection, which is the path `open()` takes.
    func seedFixturePageOffMain(_ page: TranscriptPage) async {
        await applyTranscriptProjectingOffMain(page)
        hasLoadedOnce = true
    }

    /// BUG-122's fixture: fifty entries past two windows, so the reveal row is there on open and a tap leaves a smaller count behind.
    ///
    /// Cheap on purpose — eight-paragraph walls at this count would put hundreds of `UITextView`s in the accessibility tree and measure BUG-123's cost instead.
    func seedWindowedDemoTranscript(
        entries: Int = 2 * TranscriptScroll.Window.size + 50
    ) {
        // The two rows a reveal is measured against, named by the fixture so a UI test never hard-codes an index derived from the window size.
        let windowEdge = entries - TranscriptScroll.Window.size
        let revealEdge = max(0, entries - 2 * TranscriptScroll.Window.size)
        let start = Date().addingTimeInterval(-Double(entries) * 30)
        history = (0..<entries).map { index in
            let timestamp = start.addingTimeInterval(Double(index) * 30)
            if index == windowEdge || index == revealEdge {
                return ChatEntry(
                    id: "win-u\(index)",
                    kind: .user,
                    text: index == windowEdge
                        ? "transcript row \(index) — window edge"
                        : "transcript row \(index) — reveal edge",
                    timestamp: timestamp
                )
            }
            if index % 10 == 3 {
                return ChatEntry(id: "win-t\(index)", kind: .tool, tool: ToolActivity(
                    id: "win-t\(index)", name: "read",
                    context: "transcript row \(index) — read",
                    resultText: "import SwiftUI\n…", durationSeconds: 0.2, isRunning: false
                ), timestamp: timestamp)
            }
            if index.isMultiple(of: 2) {
                return ChatEntry(
                    id: "win-u\(index)",
                    kind: .user,
                    text: "transcript row \(index) — question",
                    timestamp: timestamp
                )
            }
            return ChatEntry(
                id: "win-a\(index)",
                kind: .assistant,
                text: index % 6 == 1
                    ? "transcript row \(index) — answer\n\nA second paragraph, so the rows this window holds are not all one height."
                    : "transcript row \(index) — answer",
                status: "complete",
                timestamp: timestamp
            )
        }
        hasLoadedOnce = true
    }

    /// Screenshot harness (`-hermesScreenshotRoute markdown`): one assistant reply carrying every prose shape the renderer knows, including the shapes that merge into one text view beside the ones that must not (BUG-124).
    func seedMarkdownShowcase() {
        history = [
            ChatEntry(id: "md-u1", kind: .user, text: "Show me every shape you can draw.", timestamp: Date()),
            ChatEntry(id: "md-a1", kind: .assistant, text: Self.markdownShowcase, status: "complete", timestamp: Date()),
        ]
        hasLoadedOnce = true
    }

    /// The reply that route draws, exposed so a test can count the text views it mints without duplicating the fixture.
    nonisolated static let markdownShowcase = """
            ## What the renderer draws

            A paragraph the model wrapped itself, so this line and the next are two source lines.
            The second line, which used to be a text view of its own and is now part of this one.

            - a bulleted item, long enough to wrap on a phone so the hanging indent is visible under it
            - a second item
              - a nested item at depth one
            - a fourth item

            1. the first step
            2. the second step, also long enough to wrap so its wrapped line hangs under the words rather than under the number
            10. the tenth step, which is where a proportional number would step the list sideways

            > a quotation over two lines,
            > the second of which continues it

            | Surface | Where it runs |
            | --- | --- |
            | The agent | your machine |
            | This app | your phone |

            ```swift
            let answer = 42
            ```

            ---

            A closing paragraph, after the rule.
            """

    /// Screenshot harness: put a real `approval.request` through the real ingestion path, with `gated: true` overflowing the command window so the read gate arms.
    func seedDemoApproval(gated: Bool) {
        let sessionID = "demo-approval"
        let command: String
        if gated {
            // Deliberately far past the window on every device: the read gate is only interesting when the command genuinely cannot be seen at once.
            let steps = (1...12).map { index in
                "  && rm -rf /Users/you/Library/Developer/Xcode/DerivedData/HermesMobile-\(index)/Build/Intermediates.noindex \\"
            }
            command = ([
                "sudo rm -rf /var/lib/hermes/cache/* \\",
                "  && find /Users/you/Developer/myproject -name '*.xcodeproj' -maxdepth 3 -exec rm -rf {} + \\",
                "  && git -C /Users/you/Developer/myproject clean -fdx \\",
                "  && git -C /Users/you/Developer/myproject reset --hard origin/main \\",
            ] + steps + [
                "  && defaults delete io.github.ryantuc.harc \\",
                "  && xcrun simctl erase all \\",
                #"  && echo "workspace reset complete""#,
            ]).joined(separator: "\n")
        } else {
            command = "rm -rf ~/Developer/myproject/build"
        }
        let payload = JSONValue.object([
            "command": .string(command),
            "description": .string("Reset the workspace and clear every derived artefact."),
            "choices": .array([.string("deny"), .string("once"), .string("session"), .string("always")]),
        ])
        _ = app.engine.apply(
            GatewayEvent(type: "approval.request", sessionID: sessionID, payload: payload, params: .null)
        )
        live = app.engine.state(for: sessionID)
    }

    /// Probe seam: binds a chat to a fabricated runtime session id and pushes one approval into the engine under it, so the Live Activity roster and the island's consent gate can be exercised with no backend.
    func seedProbeSession(runtimeID: String, command: String?, choices: [String], busy: Bool = true) {
        runtimeSessionID = runtimeID
        runtimeBoundAt = Date()
        if busy {
            // A running turn with two tool calls, one still going, so the card has a real `1/2` and a real tool line to show.
            _ = app.engine.apply(GatewayEvent(type: "message.start", sessionID: runtimeID, payload: .null, params: .null))
            for (index, name) in ["read_file", "shell"].enumerated() {
                _ = app.engine.apply(GatewayEvent(
                    type: "tool.start",
                    sessionID: runtimeID,
                    payload: .object([
                        "tool_id": .string("probe-\(index)"),
                        "name": .string(name),
                        "context": .string("for i in $(seq 1 12); do sleep 5; ls; done"),
                    ]),
                    params: .null
                ))
            }
            _ = app.engine.apply(GatewayEvent(
                type: "tool.complete",
                sessionID: runtimeID,
                payload: .object(["tool_id": .string("probe-0"), "name": .string("read_file"), "result": .string("ok")]),
                params: .null
            ))
        }
        if let command {
            let payload = JSONValue.object([
                "command": .string(command),
                "description": .string("probe command"),
                "choices": .array(choices.map { .string($0) }),
            ])
            _ = app.engine.apply(
                GatewayEvent(type: "approval.request", sessionID: runtimeID, payload: payload, params: .null)
            )
        }
        live = app.engine.state(for: runtimeID)
    }
    #endif

    // MARK: - Helpers

    /// Whether a failed `prompt.submit` may safely resume the durable id and retry once; unconfirmable wire failures must not, because the first submit may already be running server-side.
    private static func shouldResumeAndRetrySubmit(_ error: HermesError) -> Bool {
        if error.isSessionNotFound { return true }
        switch error {
        case .requestTimedOut, .notConnected:
            return true
        default:
            return false
        }
    }

    private func describe(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }

    /// The contiguous run of user rows ending at the latest one: a mid-turn redirect gives one turn a run of user bubbles, so matching only the last row would let a duplicate through (reference §7.1).
    static func trailingUserTexts(in entries: [ChatEntry]) -> [String] {
        var texts: [String] = []
        for entry in entries.reversed() {
            switch entry.kind {
            case .user:
                texts.append(entry.text)
            case .assistant, .tool:
                return texts
            case .notice, .system:
                continue
            }
        }
        return texts
    }

    static func projectTranscript(_ page: TranscriptPage) -> [ChatEntry] {
        projectTranscriptWithOrdinals(page).entries
    }

    /// Project a persisted transcript into renderable entries, recording each entry's 1-based backend message ordinal.
    ///
    /// Per rest-api-and-auth.md §6.4 step 6: render in array order, skip `role == "user"` rows carrying a `display_kind`, and pair `assistant.tool_calls[].id` with the following `role: "tool"` rows via `tool_call_id`.
    nonisolated static func projectTranscriptWithOrdinals(_ page: TranscriptPage) -> (entries: [ChatEntry], ordinals: [String: Int]) {
        var entries: [ChatEntry] = []
        var ordinals: [String: Int] = [:]
        var currentOrdinal = 0
        var toolIndexByCallID: [String: Int] = [:]

        func record(_ entry: ChatEntry) {
            ordinals[entry.id] = currentOrdinal
            entries.append(entry)
        }
        // Two id-less calls of the same tool in one assistant message would otherwise share a synthetic id, and `ChatEntry.id` feeds `ForEach`.
        var claimedToolIDs: Set<String> = []

        for message in page.messages {
            // BUG-037: ordinals count only the rows `session.branch` counts, and the increment is deliberately not gated on the hidden/bookkeeping skip below — the server does not filter `display_kind`, so those rows still occupy an ordinal.
            if message.countsTowardBranchOrdinal { currentOrdinal += 1 }
            if message.isHidden || message.isBookkeeping { continue }
            let timestamp = Date(timeIntervalSince1970: message.timestamp)

            switch message.role {
            case .user:
                let raw = SteerDisplay.text(message.content.plainText, kind: message.displayKind)
                let stripped = DisplayRedaction.stripImageDirectives(raw)
                let inlineImages = message.content.imageReferences
                let refs = stripped.refs + inlineImages
                if stripped.body.isEmpty && refs.isEmpty { continue }
                record(ChatEntry(
                    id: "rest-\(message.id)",
                    kind: .user,
                    text: stripped.body,
                    imageRefs: refs,
                    noticeKind: message.displayKind == "steer" ? "correction" : "",
                    timestamp: timestamp,
                    // The REST row's `id` is the same durable SQLite row `truncate_before_row_id` addresses (`hermes_state_messages.py:1663-1664` stamps `_row_id` from `row["id"]`).
                    rowID: message.id > 0 ? message.id : nil
                ))

            case .assistant:
                let text = message.content.plainText
                if !text.isEmpty || !message.reasoning.isEmpty {
                    record(ChatEntry(
                        id: "rest-\(message.id)",
                        kind: .assistant,
                        text: text,
                        reasoning: message.reasoning,
                        status: "complete",
                        timestamp: timestamp
                    ))
                }
                // Tool-call-only rows carry `content: null`: the call metadata is the card, and the result arrives as its own `tool` row.
                for (callIndex, call) in message.toolCalls.enumerated() {
                    var toolID = call.id.isEmpty ? "rest-\(message.id)-\(call.name)" : call.id
                    if !claimedToolIDs.insert(toolID).inserted {
                        toolID = "\(toolID)#\(callIndex)"
                        claimedToolIDs.insert(toolID)
                    }
                    let activity = ToolActivity(
                        id: toolID,
                        name: call.name,
                        context: DisplayRedaction.preview(call.argumentsJSON, limit: 80),
                        argsText: call.argumentsJSON,
                        isRunning: false,
                        startedAt: timestamp
                    )
                    record(ChatEntry(
                        id: "rest-\(message.id)-tool-\(activity.id)",
                        kind: .tool,
                        tool: activity,
                        timestamp: timestamp
                    ))
                    toolIndexByCallID[activity.id] = entries.count - 1
                }

            case .tool:
                let resultText = DisplayRedaction.toolOutput(message.content.plainText)
                if let callID = message.toolCallID, let index = toolIndexByCallID[callID] {
                    entries[index].tool?.resultText = resultText
                } else {
                    let activity = ToolActivity(
                        id: message.toolCallID ?? "rest-\(message.id)",
                        name: message.toolName ?? "tool",
                        resultText: resultText,
                        isRunning: false,
                        startedAt: timestamp
                    )
                    record(ChatEntry(
                        id: "rest-\(message.id)-tool",
                        kind: .tool,
                        tool: activity,
                        timestamp: timestamp
                    ))
                }

            case .system, .unknown:
                let text = message.content.plainText
                guard !text.isEmpty else { continue }
                record(ChatEntry(
                    id: "rest-\(message.id)",
                    kind: .system,
                    text: text,
                    timestamp: timestamp
                ))
            }
        }
        return (entries, ordinals)
    }
}

// MARK: - Session automation controls

extension ChatModel {
    /// Nil when there is nothing to talk to: no open socket, no runtime session yet, or demo mode, where the strip must stay silent.
    var sessionControlTransport: SessionControlTransport? {
        guard !app.isDemoActive, app.connectionState.isOpen, let client = app.client, let sessionID = runtimeSessionID else { return nil }
        return SessionControlTransport(client: client, sessionID: sessionID, profile: profileScope)
    }

    /// A `goal.resume` answers `type: "send"` with its kickoff prompt; it goes out the way a `send`-type slash result does, shown as its display text. False when the chat could not take it (a send already in flight, no backend), which the sheet then says.
    @discardableResult
    func submitControlDispatch(_ dispatch: SessionControlDispatch) -> Bool {
        guard let message = dispatch.message?.trimmingCharacters(in: .whitespacesAndNewlines), !message.isEmpty else { return false }
        let display = dispatch.display.flatMap { $0.isEmpty ? nil : $0 } ?? "Continue the goal"
        return enqueueSend(text: display, attachments: [], promptText: message)
    }
}
