import Foundation

// MARK: - Snapshots

/// `GoalContractSnapshot` (`tui_gateway/contracts/config_free_tier_control.py:502-509`): the five contract fields `/goal` was given, each `""` when unset.
public struct GoalContract: Sendable, Equatable {
    public let outcome: String
    public let verification: String
    public let constraints: String
    public let boundaries: String
    public let stopWhen: String

    public init(outcome: String = "", verification: String = "", constraints: String = "", boundaries: String = "", stopWhen: String = "") {
        self.outcome = outcome
        self.verification = verification
        self.constraints = constraints
        self.boundaries = boundaries
        self.stopWhen = stopWhen
    }

    init(json: JSONValue?) {
        outcome = json?["outcome"]?.text ?? ""
        verification = json?["verification"]?.text ?? ""
        constraints = json?["constraints"]?.text ?? ""
        boundaries = json?["boundaries"]?.text ?? ""
        stopWhen = json?["stop_when"]?.text ?? ""
    }

    public var isEmpty: Bool {
        [outcome, verification, constraints, boundaries, stopWhen].allSatisfy(\.isEmpty)
    }
}

/// `GoalGateSnapshot` (`config_free_tier_control.py:512-517`): a command the goal must pass before it counts as done.
public struct GoalGate: Sendable, Equatable {
    public let command: String
    public let timeoutSeconds: Int
    public let maxRetries: Int
    public let attempts: Int
    public let lastExitCode: Int?

    init?(json: JSONValue) {
        guard let command = json["command"]?.coercedString else { return nil }
        self.command = command
        timeoutSeconds = json["timeout_seconds"]?.coercedInt ?? 0
        maxRetries = json["max_retries"]?.coercedInt ?? 0
        attempts = json["attempts"]?.coercedInt ?? 0
        lastExitCode = json["last_exit_code"]?.coercedInt
    }

    /// A gate that has run and exited 0.
    public var isPassing: Bool { lastExitCode == 0 }
}

/// What a waiting goal waits for (`WaitBarrierUntil` | `WaitBarrierTarget`, `config_free_tier_control.py:520-529`, discriminated on `type`).
public enum WaitBarrier: Sendable, Equatable {
    case until(Date, reason: String)
    case session(String, reason: String)
    case pid(Int, reason: String)

    init?(json: JSONValue?) {
        guard let json, case .object = json else { return nil }
        let reason = json["reason"]?.text ?? ""
        switch json["type"]?.coercedString ?? "" {
        case "until":
            guard let at = json["until_at"]?.coercedEpochDate else { return nil }
            self = .until(at, reason: reason)
        case "session":
            self = .session(json["target"]?.text ?? "", reason: reason)
        case "pid":
            self = .pid(json["target"]?.coercedInt ?? 0, reason: reason)
        default:
            return nil
        }
    }

    public var reason: String {
        switch self {
        case .until(_, let reason), .session(_, let reason), .pid(_, let reason): return reason
        }
    }
}

/// `GoalSnapshot` (`config_free_tier_control.py:532-547`): the frontend-safe subset of the goal `_safe_goal_snapshot` publishes. A cleared goal is never shipped (the backend returns `None` for it, `methods_session_control.py:50-51`), so `status` is `active` | `paused` | `done`.
public struct GoalSnapshot: Sendable, Equatable {
    public let title: String
    public let status: String
    public let turnsUsed: Int
    public let maxTurns: Int
    public let contract: GoalContract
    public let subgoals: [String]
    public let gates: [GoalGate]
    public let createdAt: Date?
    public let updatedAt: Date?
    public let pausedReason: String?
    public let lastVerdict: String?
    public let lastReason: String?
    public let waitBarrier: WaitBarrier?

    /// Desktop's visible state (`session-control-goal.tsx:160-166`): a wait barrier wins over the status, a blocked verdict colours the mark red.
    public enum State: Sendable, Equatable {
        case active, waiting, paused, done
    }

    public var state: State {
        if waitBarrier != nil { return .waiting }
        switch status {
        case "paused": return .paused
        case "done": return .done
        default: return .active
        }
    }

    public var isBlocked: Bool { lastVerdict == "blocked" }

    public init(title: String, status: String, turnsUsed: Int = 0, maxTurns: Int = 0, contract: GoalContract = GoalContract(), subgoals: [String] = [], gates: [GoalGate] = [], createdAt: Date? = nil, updatedAt: Date? = nil, pausedReason: String? = nil, lastVerdict: String? = nil, lastReason: String? = nil, waitBarrier: WaitBarrier? = nil) {
        self.title = title
        self.status = status
        self.turnsUsed = turnsUsed
        self.maxTurns = maxTurns
        self.contract = contract
        self.subgoals = subgoals
        self.gates = gates
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.pausedReason = pausedReason
        self.lastVerdict = lastVerdict
        self.lastReason = lastReason
        self.waitBarrier = waitBarrier
    }

    init?(json: JSONValue?) {
        guard let json, case .object = json else { return nil }
        title = json["title"]?.text ?? ""
        status = json["status"]?.coercedString ?? "active"
        turnsUsed = json["turns_used"]?.coercedInt ?? 0
        maxTurns = json["max_turns"]?.coercedInt ?? 0
        contract = GoalContract(json: json["contract"])
        subgoals = (json["subgoals"]?.arrayValue ?? []).compactMap(\.coercedString)
        gates = (json["gates"]?.arrayValue ?? []).compactMap(GoalGate.init(json:))
        createdAt = json["created_at"]?.coercedEpochDate
        updatedAt = json["updated_at"]?.coercedEpochDate
        pausedReason = json["paused_reason"]?.coercedString
        lastVerdict = json["last_verdict"]?.coercedString
        lastReason = json["last_reason"]?.coercedString
        waitBarrier = WaitBarrier(json: json["wait_barrier"])
    }
}

/// `LoopSnapshot` (`config_free_tier_control.py:550-567`): a prompt the agent re-runs on a cadence. `status` is `active` | `paused` | `done`; `mode` is `interval` or `self_paced`.
public struct LoopSnapshot: Sendable, Equatable {
    public let prompt: String
    public let status: String
    public let mode: String
    public let intervalSeconds: Double
    public let currentDelay: Double
    public let times: Int
    public let until: String
    public let maxTicks: Int
    public let ticksFired: Int
    public let createdAt: Date?
    public let lastFiredAt: Date?
    public let nextDueAt: Date?
    public let awaitingResponse: Bool
    /// An active goal owns the session and the loop's ticks are held (`methods_session_control.py:143-149`).
    public let deferredByGoal: Bool
    public let pausedReason: String?
    public let lastStopReason: String?

    public enum State: Sendable, Equatable {
        case active, deferred, paused, done
    }

    /// Desktop's precedence (`session-control-loop.tsx:79-87`): deferral is shown before the status.
    public var state: State {
        if deferredByGoal { return .deferred }
        switch status {
        case "paused": return .paused
        case "done": return .done
        default: return .active
        }
    }

    public var isSelfPaced: Bool { mode == "self_paced" }

    public init(prompt: String, status: String, mode: String = "interval", intervalSeconds: Double = 0, currentDelay: Double = 0, times: Int = 0, until: String = "", maxTicks: Int = 0, ticksFired: Int = 0, createdAt: Date? = nil, lastFiredAt: Date? = nil, nextDueAt: Date? = nil, awaitingResponse: Bool = false, deferredByGoal: Bool = false, pausedReason: String? = nil, lastStopReason: String? = nil) {
        self.prompt = prompt
        self.status = status
        self.mode = mode
        self.intervalSeconds = intervalSeconds
        self.currentDelay = currentDelay
        self.times = times
        self.until = until
        self.maxTicks = maxTicks
        self.ticksFired = ticksFired
        self.createdAt = createdAt
        self.lastFiredAt = lastFiredAt
        self.nextDueAt = nextDueAt
        self.awaitingResponse = awaitingResponse
        self.deferredByGoal = deferredByGoal
        self.pausedReason = pausedReason
        self.lastStopReason = lastStopReason
    }

    init?(json: JSONValue?) {
        guard let json, case .object = json else { return nil }
        prompt = json["prompt"]?.text ?? ""
        status = json["status"]?.coercedString ?? "active"
        mode = json["mode"]?.coercedString ?? "interval"
        intervalSeconds = json["interval_seconds"]?.coercedDouble ?? 0
        currentDelay = json["current_delay"]?.coercedDouble ?? 0
        times = json["times"]?.coercedInt ?? 0
        until = json["until"]?.text ?? ""
        maxTicks = json["max_ticks"]?.coercedInt ?? 0
        ticksFired = json["ticks_fired"]?.coercedInt ?? 0
        createdAt = json["created_at"]?.coercedEpochDate
        lastFiredAt = json["last_fired_at"]?.coercedEpochDate
        nextDueAt = json["next_due_at"]?.coercedEpochDate
        awaitingResponse = json["awaiting_response"]?.coercedBool ?? false
        deferredByGoal = json["deferred_by_goal"]?.coercedBool ?? false
        pausedReason = json["paused_reason"]?.coercedString
        lastStopReason = json["last_stop_reason"]?.coercedString
    }
}

/// `HeartbeatSnapshot` (`config_free_tier_control.py:571-577`): a check-in prompt that fires every `intervalSeconds` while the session is idle. `status` is `active` | `paused` (a cleared one is not shipped, `hermes_cli/heartbeat.py:119`).
public struct HeartbeatSnapshot: Sendable, Equatable {
    public let prompt: String
    public let status: String
    public let intervalSeconds: Int
    public let createdAt: Date?
    public let lastFiredAt: Date?
    public let fireCount: Int

    public var isPaused: Bool { status == "paused" }

    /// When the next check-in is due, as Desktop computes it (`session-control-heartbeat.tsx:95-96`): the last firing, or the creation, plus the interval. A `last_fired_at` of 0 means never fired.
    public var nextDueAt: Date? {
        guard let base = lastFiredAt ?? createdAt else { return nil }
        return base.addingTimeInterval(TimeInterval(intervalSeconds))
    }

    public init(prompt: String, status: String, intervalSeconds: Int, createdAt: Date? = nil, lastFiredAt: Date? = nil, fireCount: Int = 0) {
        self.prompt = prompt
        self.status = status
        self.intervalSeconds = intervalSeconds
        self.createdAt = createdAt
        self.lastFiredAt = lastFiredAt
        self.fireCount = fireCount
    }

    init?(json: JSONValue?) {
        guard let json, case .object = json else { return nil }
        prompt = json["prompt"]?.text ?? ""
        status = json["status"]?.coercedString ?? "active"
        intervalSeconds = json["interval_seconds"]?.coercedInt ?? 0
        createdAt = json["created_at"]?.coercedEpochDate
        // The backend writes 0 for "never"; `coercedEpochDate` reads a non-positive number as nil.
        lastFiredAt = json["last_fired_at"]?.coercedEpochDate
        fireCount = json["fire_count"]?.coercedInt ?? 0
    }
}

/// `SessionControlSnapshot` (`config_free_tier_control.py:580-588`): the three automation states of one session, as `session.control.read` answers them and `session.control.update` pushes them. `revision` hashes the visible state and is `""` when all three are absent (`methods_session_control.py:162-172`).
public struct SessionControlSnapshot: Sendable, Equatable {
    public let goal: GoalSnapshot?
    public let loop: LoopSnapshot?
    public let heartbeat: HeartbeatSnapshot?
    public let revision: String
    public let updatedAt: Date?

    public var isEmpty: Bool { goal == nil && loop == nil && heartbeat == nil }

    public init(goal: GoalSnapshot? = nil, loop: LoopSnapshot? = nil, heartbeat: HeartbeatSnapshot? = nil, revision: String = "", updatedAt: Date? = nil) {
        self.goal = goal
        self.loop = loop
        self.heartbeat = heartbeat
        self.revision = revision
        self.updatedAt = updatedAt
    }

    public init(json: JSONValue) {
        goal = GoalSnapshot(json: json["goal"])
        loop = LoopSnapshot(json: json["loop"])
        heartbeat = HeartbeatSnapshot(json: json["heartbeat"])
        revision = json["revision"]?.coercedString ?? ""
        updatedAt = json["updated_at"]?.coercedEpochDate
    }
}

/// `session.control.update {control}` (`tui_gateway/contracts/events.py:438-442`), emitted on the runtime session whenever persisted goal, loop or heartbeat state changes.
public struct SessionControlUpdateEvent: Sendable, Equatable {
    public let sessionID: String
    public let control: SessionControlSnapshot
}

// MARK: - Actions

/// The allowlist `session.control` accepts (`SessionControlAction`, `config_free_tier_control.py:603-616`); anything else, and every `goal.gate*`, answers 4004 (`methods_session_control.py:258-264`).
public enum SessionControlAction: String, Sendable, Equatable, CaseIterable {
    case goalPause = "goal.pause"
    case goalResume = "goal.resume"
    case goalClear = "goal.clear"
    case goalUnwait = "goal.unwait"
    case loopPause = "loop.pause"
    case loopResume = "loop.resume"
    case loopStop = "loop.stop"
    case subgoalAdd = "subgoal.add"
    case subgoalRemove = "subgoal.remove"
    case subgoalClear = "subgoal.clear"
    case heartbeatPause = "heartbeat.pause"
    case heartbeatResume = "heartbeat.resume"
    case heartbeatClear = "heartbeat.clear"

    /// Throws away state the user cannot get back; the UI asks first.
    public var isDestructive: Bool {
        switch self {
        case .goalClear, .loopStop, .subgoalRemove, .subgoalClear, .heartbeatClear: return true
        default: return false
        }
    }
}

/// `SessionControlDispatch` (`config_free_tier_control.py:635-642`): the command result's user-visible envelope. `goal.*` and `loop.*` run through the slash dispatcher, so a `goal.resume` can answer `type: "send"` with the kickoff prompt the client is expected to submit, as `/goal resume` does.
public struct SessionControlDispatch: Sendable, Equatable {
    public let type: String?
    public let output: String?
    public let notice: String?
    public let message: String?
    public let display: String?

    public init(type: String? = nil, output: String? = nil, notice: String? = nil, message: String? = nil, display: String? = nil) {
        self.type = type
        self.output = output
        self.notice = notice
        self.message = message
        self.display = display
    }

    init(json: JSONValue?) {
        type = json?["type"]?.coercedString
        output = json?["output"]?.coercedString
        notice = json?["notice"]?.coercedString
        message = json?["message"]?.coercedString
        display = json?["display"]?.coercedString
    }

    /// The backend wants a prompt submitted to carry the action through.
    public var isSend: Bool {
        type == "send" && !(message ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

/// `session.control` result (`config_free_tier_control.py:645-647`): the snapshot after the action, exactly as the backend persisted it.
public struct SessionControlResult: Sendable, Equatable {
    public let control: SessionControlSnapshot
    public let dispatch: SessionControlDispatch

    public init(json: JSONValue) {
        control = SessionControlSnapshot(json: json["control"] ?? .null)
        dispatch = SessionControlDispatch(json: json["dispatch"])
    }
}

// MARK: - The API

/// Goal, loop and heartbeat controls for one live session: `session.control.read` and `session.control` (`tui_gateway/methods_session_control.py:234`, `:251`; contracts `config_free_tier_control.py:591-651`).
public struct SessionControlAPI: Sendable {
    private let client: HermesClient

    public init(client: HermesClient) {
        self.client = client
    }

    /// `session.control.read {session_id, profile?}`.
    public func read(sessionID: String, profile: String? = nil) async throws -> SessionControlSnapshot {
        var params: [String: JSONValue] = ["session_id": .string(sessionID)]
        if let profile, !profile.isEmpty { params["profile"] = .string(profile) }
        let result = try await client.request("session.control.read", params: .object(params))
        return SessionControlSnapshot(json: result["control"] ?? .null)
    }

    /// `session.control {session_id, action, args?, profile?}`. `args` is sent only for the two actions that read it: `subgoal.add` wants `text`, `subgoal.remove` the 1-based `index` (`config_free_tier_control.py:619-623`); an `args` object on any other action is accepted and ignored by the handler, and an undeclared key in it would answer 4000.
    public func perform(_ action: SessionControlAction, sessionID: String, text: String? = nil, index: Int? = nil, profile: String? = nil) async throws -> SessionControlResult {
        var params: [String: JSONValue] = [
            "session_id": .string(sessionID),
            "action": .string(action.rawValue),
        ]
        switch action {
        case .subgoalAdd:
            params["args"] = .object(["text": .string(text ?? "")])
        case .subgoalRemove:
            params["args"] = .object(["index": .number(Double(index ?? 0))])
        default:
            break
        }
        if let profile, !profile.isEmpty { params["profile"] = .string(profile) }
        let result = try await client.request("session.control", params: .object(params))
        return SessionControlResult(json: result)
    }
}

extension HermesError {
    /// The backend does not have this method family: the gateway answers `-32601` for a method it has never heard of (`tui_gateway/rpc_dispatch.py:23`), and `4000` for a declared method whose params it does not recognise (`rpc_dispatch.py:27-31`), which is what an older declaration of the same name looks like from here. Both mean "hide the control", where every other failure means "try again later".
    public var isUnknownMethod: Bool {
        guard case .rpc(let code, let message, _) = self else { return false }
        if code == -32601 || code == 4000 { return true }
        return message.lowercased().contains("method not found")
    }
}
