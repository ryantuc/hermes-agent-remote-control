import Foundation
import HermesServeKit
import Observation

/// Whether the connected backend has a method family at all. Decided from the first answer per session binding: `-32601` or `4000` says no and hides the entry point for that session; any other failure (not connected, session not live yet, a 5xxx) is passing and says nothing.
enum BackendMethodSupport: Equatable {
    case unknown
    case supported
    case unsupported
}

/// How a strip group reaches the wire. Built by the owning `ChatModel` each time it is asked, so a rebind or a disconnect is seen on the next call rather than cached; nil means there is nothing to talk to, which includes demo mode.
struct SessionControlTransport {
    let client: HermesClient
    let sessionID: String
    let profile: String?
}

/// The one line the strip draws for a group: the title carries the kind and its state, `detail` a short tabular fact, `note` the free text that truncates first.
struct SessionStripLine: Equatable {
    let title: String
    let detail: String?
    let note: String?
    let spoken: String
}

// MARK: - Goal, loop and heartbeat

/// The automation state of one chat (goal, loop, heartbeat), read with `session.control.read` when the session binds and at every end of turn (`session.info` is what lands then), kept live by `session.control.update`, and acted on with `session.control`. Desktop hydrates on the same two edges (`status-stack/index.tsx:173-177`, `store/session-control.ts:866-872`).
@MainActor
@Observable
final class SessionControlsModel {
    private(set) var snapshot: SessionControlSnapshot?
    private(set) var support: BackendMethodSupport = .unknown
    /// The action in flight; every control is disabled while one is.
    private(set) var pendingAction: SessionControlAction?
    /// The last failure, in words for a person; cleared by the next action or by the sheet.
    private(set) var lastError: String?

    @ObservationIgnored var transport: () -> SessionControlTransport? = { nil }
    /// A `goal.resume` can answer `type: "send"` with the kickoff prompt; the chat submits it the way it submits any `send`-type slash result and answers whether it went.
    @ObservationIgnored var onSendDispatch: ((SessionControlDispatch) -> Bool)?
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    /// A trigger that landed while a read was in flight; the read runs once more when the current one ends, so an end of turn arriving during the open read is not lost.
    @ObservationIgnored private var refreshPending = false
    @ObservationIgnored private var boundSessionID: String?
    /// Whether the Automation sheet is open. Held here rather than in the strip line's own state so the line's host can stay mounted while the sheet is up: a goal cleared from the sheet takes the line away, and a sheet whose presenter leaves the tree is dismissed under the person.
    var isSheetPresented = false

    /// Only a backend that answered, and only when it has something to show.
    var isVisible: Bool { support == .supported && snapshot?.isEmpty == false }

    var isBusy: Bool { pendingAction != nil }

    /// A pushed snapshot is authoritative and also proves the method family exists.
    func adopt(_ control: SessionControlSnapshot) {
        snapshot = control
        support = .supported
    }

    /// A turn ended (`isBusy` fell), which is when the backend's own `/goal` and `/loop` bookkeeping has settled.
    func noteTurnEnded() {
        scheduleRefresh()
    }

    /// The chat bound a runtime session: one read per binding and none for the same id again, because the ack of every send also passes through the bind seam.
    func noteSessionBound() {
        guard let transport = transport(), transport.sessionID != boundSessionID else { return }
        scheduleRefresh()
    }

    /// One read at a time; a session that rebinds under it starts from nothing.
    func scheduleRefresh() {
        guard let transport = transport() else { return }
        if transport.sessionID != boundSessionID {
            boundSessionID = transport.sessionID
            snapshot = nil
            support = .unknown
            lastError = nil
        }
        guard support != .unsupported else { return }
        if refreshTask != nil {
            refreshPending = true
            return
        }
        refreshTask = Task { [weak self] in
            guard let self else { return }
            repeat {
                refreshPending = false
                await refresh()
            } while refreshPending && support != .unsupported
            refreshTask = nil
        }
    }

    func refresh() async {
        guard let transport = transport(), support != .unsupported else { return }
        let api = SessionControlAPI(client: transport.client)
        do {
            let control = try await api.read(sessionID: transport.sessionID, profile: transport.profile)
            guard boundSessionID == transport.sessionID else { return }
            snapshot = control
            support = .supported
        } catch let error as HermesError where error.isUnknownMethod {
            guard boundSessionID == transport.sessionID else { return }
            support = .unsupported
            snapshot = nil
        } catch {
            // Not connected, or the session is not live yet: the next edge reads again.
        }
    }

    /// Run one allowlisted action; the snapshot the backend answers with replaces ours, so the sheet shows exactly what was persisted.
    @discardableResult
    func perform(_ action: SessionControlAction, text: String? = nil, index: Int? = nil) async -> Bool {
        guard support != .unsupported, pendingAction == nil, let transport = transport() else { return false }
        pendingAction = action
        lastError = nil
        defer { pendingAction = nil }
        let api = SessionControlAPI(client: transport.client)
        do {
            let result = try await api.perform(action, sessionID: transport.sessionID, text: text, index: index, profile: transport.profile)
            guard boundSessionID == transport.sessionID else { return true }
            snapshot = result.control
            support = .supported
            // The backend has already resumed; a kickoff the chat could not send (another message in flight, no socket) is said, not swallowed.
            if result.dispatch.isSend, onSendDispatch?(result.dispatch) == false {
                lastError = "Resumed, but its first message could not be sent while another message is still going out. Send any message to continue the goal."
            }
            return true
        } catch let error as HermesError where error.isUnknownMethod {
            support = .unsupported
            snapshot = nil
            return false
        } catch {
            lastError = Self.describe(error, action: action)
            return false
        }
    }

    func clearError() {
        lastError = nil
    }

    /// Fixture state for the screenshot harness and tests; stands in for a backend that answered.
    func seed(_ control: SessionControlSnapshot) {
        snapshot = control
        support = .supported
    }

    static func describe(_ error: Error, action: SessionControlAction) -> String {
        let verb: String
        switch action {
        case .goalPause, .loopPause, .heartbeatPause: verb = "pause"
        case .goalResume, .loopResume, .heartbeatResume, .goalUnwait: verb = "resume"
        case .goalClear, .heartbeatClear, .subgoalClear: verb = "clear"
        case .loopStop: verb = "stop"
        case .subgoalAdd: verb = "add"
        case .subgoalRemove: verb = "remove"
        }
        if case HermesError.rpc(_, let message, _) = error, !message.isEmpty {
            return "Could not \(verb): \(message)"
        }
        return "Could not \(verb). \(error.localizedDescription)"
    }

    // MARK: The strip line

    /// Goal first, then loop, then heartbeat; the others are named after the leading one so the line says everything that is running without growing.
    var line: SessionStripLine? {
        guard isVisible, let snapshot else { return nil }
        var kinds: [(line: SessionStripLine, name: String)] = []
        if let goal = snapshot.goal { kinds.append((Self.goalLine(goal), "goal")) }
        if let loop = snapshot.loop { kinds.append((Self.loopLine(loop), "loop")) }
        if let heartbeat = snapshot.heartbeat { kinds.append((Self.heartbeatLine(heartbeat), "heartbeat")) }
        guard let lead = kinds.first else { return nil }
        let rest = kinds.dropFirst()
        guard !rest.isEmpty else { return lead.line }
        return SessionStripLine(
            title: ([lead.line.title] + rest.map(\.name)).joined(separator: " · "),
            detail: lead.line.detail,
            note: lead.line.note,
            spoken: ([lead.line.spoken] + rest.map(\.line.spoken)).joined(separator: ". ")
        )
    }

    static func goalLine(_ goal: GoalSnapshot) -> SessionStripLine {
        let state = SessionControlFormat.goalState(goal)
        let title = state == "active" ? "◎ Goal" : "◎ Goal \(state)"
        let detail = SessionControlFormat.goalTurns(goal)
        return SessionStripLine(
            title: title,
            detail: detail,
            note: goal.title,
            spoken: "Goal \(state)\(detail.map { ", \($0)" } ?? ""). \(goal.title)"
        )
    }

    static func loopLine(_ loop: LoopSnapshot) -> SessionStripLine {
        let state = SessionControlFormat.loopState(loop)
        let title = state == "active" ? "↻ Loop" : "↻ Loop \(state)"
        let detail = SessionControlFormat.loopRuns(loop)
        return SessionStripLine(
            title: title,
            detail: detail,
            note: loop.prompt,
            spoken: "Loop \(state), \(detail). \(loop.prompt)"
        )
    }

    static func heartbeatLine(_ heartbeat: HeartbeatSnapshot) -> SessionStripLine {
        let title = heartbeat.isPaused ? "♥ Heartbeat paused" : "♥ Heartbeat"
        let detail = SessionControlFormat.interval(seconds: Double(heartbeat.intervalSeconds))
        return SessionStripLine(
            title: title,
            detail: detail,
            note: heartbeat.prompt,
            spoken: "Heartbeat \(heartbeat.isPaused ? "paused" : "active"), \(detail). \(heartbeat.prompt)"
        )
    }
}

// MARK: - Background processes

/// The background processes the agent started in this chat, from `process.list`. Read when the session binds and at every end of turn, then every five seconds only while the sheet is open (Desktop's `BACKGROUND_POLL_MS`, `status-stack/index.tsx:52`, and only while its pane is visible, `:190-200`). Nothing polls with the sheet closed.
@MainActor
@Observable
final class BackgroundProcessesModel {
    private(set) var processes: [BackgroundProcess] = []
    private(set) var support: BackendMethodSupport = .unknown
    /// Ids with a `process.kill` in flight.
    private(set) var stopping: Set<String> = []
    private(set) var lastError: String?
    /// What the last stop answered, for the sheet's one-line confirmation.
    private(set) var lastOutcome: String?

    @ObservationIgnored var transport: () -> SessionControlTransport? = { nil }
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var refreshPending = false
    @ObservationIgnored private var boundSessionID: String?
    /// Whether the Processes sheet is open; see `SessionControlsModel.isSheetPresented`. Stopping the last process must not close the sheet that reports it stopped.
    var isSheetPresented = false

    static let pollInterval: Duration = .seconds(5)

    var running: [BackgroundProcess] { processes.filter(\.isRunning) }
    var finished: [BackgroundProcess] { processes.filter { !$0.isRunning } }

    /// Something is running. A finished process is still listed in the sheet but does not earn a line above the composer, because the registry keeps finished rows for a long time.
    var isVisible: Bool { support == .supported && !running.isEmpty }

    var line: SessionStripLine? {
        guard isVisible else { return nil }
        let count = running.count
        let detail = "\(count) running"
        let note = running.first?.command
        return SessionStripLine(
            title: "$ Processes",
            detail: detail,
            note: note,
            spoken: "Background processes, \(detail)\(note.map { ". \($0)" } ?? "")"
        )
    }

    func noteTurnEnded() {
        scheduleRefresh()
    }

    func noteSessionBound() {
        guard let transport = transport(), transport.sessionID != boundSessionID else { return }
        scheduleRefresh()
    }

    func scheduleRefresh() {
        guard let transport = transport() else { return }
        if transport.sessionID != boundSessionID {
            boundSessionID = transport.sessionID
            processes = []
            support = .unknown
            lastError = nil
            lastOutcome = nil
        }
        guard support != .unsupported else { return }
        if refreshTask != nil {
            refreshPending = true
            return
        }
        refreshTask = Task { [weak self] in
            guard let self else { return }
            repeat {
                refreshPending = false
                await refresh()
            } while refreshPending && support != .unsupported
            refreshTask = nil
        }
    }

    func refresh() async {
        guard let transport = transport(), support != .unsupported else { return }
        let api = ProcessesAPI(client: transport.client)
        do {
            let rows = try await api.list(sessionID: transport.sessionID, profile: transport.profile)
            guard boundSessionID == transport.sessionID else { return }
            processes = rows
            support = .supported
        } catch let error as HermesError where error.isUnknownMethod {
            guard boundSessionID == transport.sessionID else { return }
            support = .unsupported
            processes = []
        } catch {
            // Transient; the next edge or poll tick reads again.
        }
    }

    /// Runs for as long as the sheet is on screen: one read now, then one every `pollInterval`.
    func pollWhilePresented() async {
        while !Task.isCancelled {
            await refresh()
            guard support != .unsupported else { return }
            try? await Task.sleep(for: Self.pollInterval)
        }
    }

    /// `process.kill` one row, then re-read so the row shows what it became.
    @discardableResult
    func stop(_ id: String) async -> ProcessKillOutcome? {
        guard support != .unsupported, !stopping.contains(id), let transport = transport() else { return nil }
        stopping.insert(id)
        lastError = nil
        lastOutcome = nil
        defer { stopping.remove(id) }
        let api = ProcessesAPI(client: transport.client)
        do {
            let outcome = try await api.kill(sessionID: transport.sessionID, processID: id, profile: transport.profile)
            lastOutcome = outcome.summary
            if !outcome.isGone, outcome.status != "not_found" { lastError = outcome.summary }
            await refresh()
            return outcome
        } catch let error as HermesError where error.isUnknownMethod {
            support = .unsupported
            processes = []
            return nil
        } catch {
            if case HermesError.rpc(_, let message, _) = error, !message.isEmpty {
                lastError = "Could not stop it: \(message)"
            } else {
                lastError = "Could not stop it. \(error.localizedDescription)"
            }
            return nil
        }
    }

    func clearError() {
        lastError = nil
    }

    func seed(_ rows: [BackgroundProcess]) {
        processes = rows
        support = .supported
    }
}

// MARK: - Words and numbers

/// The phrases both the strip and the sheets use, kept in one place so the two never disagree; the rules are Desktop's (`status-stack/session-control-utils.ts`).
enum SessionControlFormat {
    static func goalState(_ goal: GoalSnapshot) -> String {
        if goal.isBlocked { return "blocked" }
        switch goal.state {
        case .active: return "active"
        case .waiting: return "waiting"
        case .paused: return "paused"
        case .done: return "done"
        }
    }

    /// `turn 3/20`, `turn 3`, or `20 turns` once done; nil before the first turn with no cap.
    static func goalTurns(_ goal: GoalSnapshot) -> String? {
        if goal.state == .done { return "\(goal.turnsUsed) turn\(goal.turnsUsed == 1 ? "" : "s")" }
        if goal.maxTurns > 0 { return "turn \(goal.turnsUsed)/\(goal.maxTurns)" }
        if goal.turnsUsed > 0 { return "turn \(goal.turnsUsed)" }
        return nil
    }

    static func loopState(_ loop: LoopSnapshot) -> String {
        switch loop.state {
        case .active: return "active"
        case .deferred: return "deferred"
        case .paused: return "paused"
        case .done: return "finished"
        }
    }

    /// `run 2/5` with a cap, else `2 runs`.
    static func loopRuns(_ loop: LoopSnapshot) -> String {
        if loop.times > 0 { return "run \(loop.ticksFired)/\(loop.times)" }
        return "\(loop.ticksFired) run\(loop.ticksFired == 1 ? "" : "s")"
    }

    /// `every 45s`, `every 30m`, `every 2h`: whole hours, then whole minutes, then seconds (`formatInterval`, `session-control-utils.ts:76-86`).
    static func interval(seconds: Double) -> String {
        let whole = Int(seconds.rounded())
        guard whole > 0 else { return "no interval" }
        if whole % 3600 == 0 { return "every \(whole / 3600)h" }
        if whole % 60 == 0 { return "every \(whole / 60)m" }
        return "every \(whole)s"
    }

    /// `~45s`, `~5m`, `~2h`, `~3d` until `date`; `~0s` once passed (`formatApproximateTime`, `session-control-utils.ts:25-58`).
    static func approximate(until date: Date, now: Date = Date()) -> String {
        let seconds = Int(clampedInterval(date.timeIntervalSince(now)).rounded())
        if seconds <= 0 { return "~0s" }
        if seconds < 60 { return "~\(seconds)s" }
        let minutes = Int((Double(seconds) / 60).rounded())
        if minutes < 60 { return "~\(minutes)m" }
        let hours = Int((Double(minutes) / 60).rounded())
        if hours < 24 { return "~\(hours)h" }
        return "~\(Int((Double(hours) / 24).rounded()))d"
    }

    /// `00:04:59`, with a day count ahead of it past 24 h (`formatHeartbeatCountdown`, `session-control-utils.ts:61-73`).
    static func countdown(to date: Date, now: Date = Date()) -> String {
        let remaining = max(0, Int(clampedInterval(date.timeIntervalSince(now)).rounded(.up)))
        let days = remaining / 86_400
        let hours = (remaining % 86_400) / 3_600
        let minutes = (remaining % 3_600) / 60
        let seconds = remaining % 60
        let clock = String(format: "%02d:%02d:%02d", hours, minutes, seconds)
        return days > 0 ? "\(days)d \(clock)" : clock
    }

    /// The wire's due times are unbounded floats and `Int(_:)` traps past Int64, so an interval is held within about 30,000 years either way before it is converted (the BUG-112 class).
    static let intervalCeiling: TimeInterval = 1e12

    static func clampedInterval(_ interval: TimeInterval) -> TimeInterval {
        guard interval.isFinite else { return interval > 0 ? intervalCeiling : 0 }
        return min(max(interval, -intervalCeiling), intervalCeiling)
    }

    /// `12s`, `3m 04s`, `1h 12m` for a process's uptime.
    static func elapsed(_ seconds: TimeInterval) -> String {
        let total = Int(max(0, seconds).rounded())
        if total < 60 { return "\(total)s" }
        let minutes = total / 60
        if minutes < 60 { return String(format: "%dm %02ds", minutes, total % 60) }
        return String(format: "%dh %02dm", minutes / 60, minutes % 60)
    }
}
