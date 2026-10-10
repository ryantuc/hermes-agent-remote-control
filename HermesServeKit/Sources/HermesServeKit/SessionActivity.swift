import Foundation

// MARK: - Todos

/// One row of the agent's plan; an update is a whole-list replacement in wire order, never a merge.
public struct TodoItem: Identifiable, Sendable, Equatable, Codable {
    /// The closed status vocabulary the backend emits; an unknown status is dropped, not coerced.
    public enum Status: String, Sendable, Equatable, CaseIterable, Codable {
        case pending
        case inProgress = "in_progress"
        case completed
        case cancelled

        /// The item needs no further work; both terminal states count.
        public var isSettled: Bool { self == .completed || self == .cancelled }
    }

    public let id: String
    /// Clamped on the way in — the backend allows 4,000 chars per item.
    public let content: String
    public let status: Status

    public init(id: String, content: String, status: Status) {
        self.id = id
        self.content = SessionActivity.clamped(content, to: SessionActivity.todoContentLimit)
        self.status = status
    }
}

extension TodoItem {
    /// Strict per-item decode; a malformed item is dropped, not repaired.
    init?(json: JSONValue) {
        guard json.objectValue != nil else { return nil }
        guard let id = json["id"]?.coercedString, !id.isEmpty else { return nil }
        guard let rawContent = json["content"]?.coercedString else { return nil }
        let content = rawContent.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty else { return nil }
        guard let rawStatus = json["status"]?.coercedString,
              let status = Status(rawValue: rawStatus)
        else { return nil }
        self.init(id: id, content: content, status: status)
    }
}

/// A session's current plan. Whole-list replacement, capped on write.
public struct TodoList: Sendable, Equatable, Codable {
    /// `private(set)` on purpose: the cap is enforced in `init`, so nothing can append past it.
    public private(set) var items: [TodoItem]

    /// Truncation keeps the HEAD: this is a priority-ordered plan, not a queue.
    public init(items: [TodoItem] = []) {
        self.items = Array(items.prefix(SessionActivity.todoItemLimit))
    }

    public var total: Int { items.count }
    public var completedCount: Int { items.filter { $0.status == .completed }.count }
    /// Completed or cancelled — what "n of m done" counts.
    public var settledCount: Int { items.filter { $0.status.isSettled }.count }
    public var isEmpty: Bool { items.isEmpty }
    /// Non-empty with every item settled; collapses to its header until the next `message.start`.
    public var isFinished: Bool { !items.isEmpty && items.allSatisfy { $0.status.isSettled } }
    /// Non-empty with work outstanding; a turn end drops this as stale.
    public var isActive: Bool { !items.isEmpty && !isFinished }
    /// The one item the agent says it is on right now, if it named one.
    public var current: TodoItem? { items.first { $0.status == .inProgress } }
}

extension TodoList {
    /// The canonical display name of the tool that owns the plan.
    public static let toolName = "todo"

    /// Both spellings: upstream renamed `todo` to `todo_list` with no alias, so a shipped client
    /// meets both backends (BUG-145).
    public static let toolNames: Set<String> = ["todo", "todo_list"]

    /// Whether `name` is the plan tool; exact, never a substring test.
    public static func isPlanTool(_ name: String) -> Bool { toolNames.contains(name) }

    /// Unwrap at most this many wrapper layers (`{todos: …}`, a JSON string).
    static let maxUnwrapDepth = 2
    /// Refuse to JSON-decode a string longer than this.
    static let maxEncodedBytes = 2_000_000

    /// Precedence `payload.todos` → `result` → `args`; nil means no typed data, not an empty list.
    public static func parse(payload: JSONValue) -> TodoList? {
        for key in ["todos", "result", "args"] {
            guard let value = payload[key] else { continue }
            if let list = parse(value) { return list }
        }
        return nil
    }

    /// Parse one candidate; an empty array is a SUCCESSFUL parse meaning the agent cleared its plan.
    public static func parse(_ value: JSONValue, depth: Int = 0) -> TodoList? {
        switch value {
        case .array(let raw):
            // Order is preserved exactly; malformed items are dropped in place.
            return TodoList(items: raw.compactMap(TodoItem.init(json:)))
        case .object:
            guard depth < maxUnwrapDepth, let nested = value["todos"] else { return nil }
            return parse(nested, depth: depth + 1)
        case .string(let encoded):
            guard depth < maxUnwrapDepth, encoded.utf8.count <= maxEncodedBytes else { return nil }
            guard let data = encoded.data(using: .utf8),
                  let decoded = try? JSONDecoder().decode(JSONValue.self, from: data)
            else { return nil }
            return parse(decoded, depth: depth + 1)
        case .null, .bool, .number:
            return nil
        }
    }
}

/// The backend's authoritative plan snapshot, `todo_state: {todos, revision}` on a `session.resume`
/// or `session.activate` result (FEAT-037; `tui_gateway/tool_progress.py:110-155`, contract
/// `tui_gateway/contracts/sessions.py:62-66`). Absent on a backend that predates it, and absent for a
/// store that was never written (the backend suppresses an empty list at revision 0); an empty list
/// at a later revision is the agent clearing its plan.
public struct TodoSnapshot: Sendable, Equatable {
    public let todos: TodoList
    public let revision: Int?

    /// Nil unless `todos` is a list, which is the backend's own acceptance rule.
    public init?(json: JSONValue?) {
        guard let json, json.objectValue != nil, let raw = json["todos"], raw.arrayValue != nil,
              let todos = TodoList.parse(raw) else { return nil }
        self.todos = todos
        revision = json["revision"]?.coercedInt
    }
}

// MARK: - Subagents

/// One subagent's row in the shared activity surface.
public struct SubagentRow: Identifiable, Sendable, Equatable {
    /// Terminal by event type, not status string: falling through to `running` never prunes.
    public enum State: String, Sendable, Equatable {
        case running
        case completed
        case failed
        case interrupted
        /// It finished while this client was not watching: the backend's roster no longer lists it and no `subagent.complete` arrived, so the outcome is unknown.
        case ended

        public var isTerminal: Bool { self != .running }

        /// Anything unrecognised on `subagent.complete`, an absent status included, is `failed`.
        public init(completeStatus: String?) {
            switch (completeStatus ?? "").lowercased() {
            case "completed", "complete", "ok", "success": self = .completed
            case "interrupted", "cancelled", "canceled": self = .interrupted
            default: self = .failed
            }
        }
    }

    /// `subagent_id` when the wire carried one, else a synthetic composite.
    public let id: String
    /// The backend's own `subagent_id`; only a non-empty value may be sent on the wire.
    public var wireSubagentID: String
    /// The turn that announced this agent was started by this client; stamped once, never revised.
    public var startedByThisClient: Bool
    /// This client saw `subagent.start`; absence from the backend means staleness only for a
    /// started row, because a queued child has no registry entry either.
    public var hasStarted: Bool
    public var goal: String {
        didSet { goal = SessionActivity.clamped(goal, to: SessionActivity.subagentTextLimit) }
    }
    public var summary: String {
        didSet { summary = SessionActivity.clamped(summary, to: SessionActivity.subagentTextLimit) }
    }
    public var state: State
    /// The delegating agent's id, `""` at the root; the only tree edge, as the wire has no children.
    public var parentID: String
    /// The child's own session id, kept as a cross-surface identifier; this client never resumes it.
    public var childSessionID: String
    public var model: String {
        didSet { model = SessionActivity.clamped(model, to: SessionActivity.subagentLabelLimit) }
    }
    /// The tool this agent is running right now, cleared when it finishes.
    public var currentTool: String {
        didSet { currentTool = SessionActivity.clamped(currentTool, to: SessionActivity.subagentLabelLimit) }
    }
    /// Cumulative, and merged monotonically — see `SubagentEvent.merge`.
    public var toolCount: Int
    /// This agent's position in its fan-out batch, as the wire reported it.
    public var taskIndex: Int?
    public var taskCount: Int?
    public var depth: Int?
    /// When this client first heard of the agent — not when the backend spawned it.
    public let startedAt: Date
    /// The last frame that changed anything; freezes the elapsed readout once the row is terminal.
    public var updatedAt: Date
    /// `duration_seconds` from the wire, preferred over wall time as the backend's own measurement.
    public var durationSeconds: Double?
    /// Newest last; the cap and the consecutive dedupe live in `appendStream`.
    public private(set) var stream: [String]
    /// The runtime session that delegated this agent; the address its tail, steer and stop calls use.
    public var sessionID: String
    /// The fan-out batch it belongs to, when the wire said; with `taskIndex` it identifies a failed async task.
    public var delegationID: String
    /// From `subagent.list` only; nil when no roster has described this agent.
    public var acceptingSteer: Bool?
    /// First seen in a roster read, which says nothing about who started it, so `startedByThisClient` is a guess here and a Stop must not claim either way.
    public var originUnknown: Bool

    public var isTerminal: Bool { state.isTerminal }

    public init(
        id: String,
        wireSubagentID: String = "",
        startedByThisClient: Bool = true,
        hasStarted: Bool = false,
        goal: String = "",
        summary: String = "",
        state: State = .running,
        parentID: String = "",
        childSessionID: String = "",
        model: String = "",
        currentTool: String = "",
        toolCount: Int = 0,
        taskIndex: Int? = nil,
        taskCount: Int? = nil,
        depth: Int? = nil,
        startedAt: Date = Date(),
        durationSeconds: Double? = nil,
        sessionID: String = "",
        delegationID: String = "",
        acceptingSteer: Bool? = nil,
        originUnknown: Bool = false
    ) {
        self.id = id
        self.wireSubagentID = wireSubagentID
        self.startedByThisClient = startedByThisClient
        self.hasStarted = hasStarted
        // `didSet` does not fire for the initial value, so clamp here too.
        self.goal = SessionActivity.clamped(goal, to: SessionActivity.subagentTextLimit)
        self.summary = SessionActivity.clamped(summary, to: SessionActivity.subagentTextLimit)
        self.state = state
        self.parentID = parentID
        self.childSessionID = childSessionID
        self.model = SessionActivity.clamped(model, to: SessionActivity.subagentLabelLimit)
        self.currentTool = SessionActivity.clamped(currentTool, to: SessionActivity.subagentLabelLimit)
        self.toolCount = toolCount
        self.taskIndex = taskIndex
        self.taskCount = taskCount
        self.depth = depth
        self.startedAt = startedAt
        self.updatedAt = startedAt
        self.durationSeconds = durationSeconds
        self.stream = []
        self.sessionID = sessionID
        self.delegationID = delegationID
        self.acceptingSteer = acceptingSteer
        self.originUnknown = originUnknown
    }

    /// The ids a later roster read could name this row by; retiring a row retires all of them.
    var retirementKeys: [String] {
        var keys = [id]
        if !wireSubagentID.isEmpty, wireSubagentID != id { keys.append(wireSubagentID) }
        if !delegationID.isEmpty { keys.append("delegation:\(delegationID):\(taskIndex ?? 0)") }
        return keys
    }

    /// How long this agent has been working; a terminal row measures to its last update, not now.
    public func elapsed(now: Date = Date()) -> TimeInterval {
        if let durationSeconds { return durationSeconds }
        return max(0, (isTerminal ? updatedAt : now).timeIntervalSince(startedAt))
    }

    /// Append one stream line: collapsed, clamped, deduped, and dropped from the front past the cap.
    public mutating func appendStream(_ line: String) {
        let collapsed = SessionActivity.collapsed(line, to: SessionActivity.streamLineLimit)
        guard !collapsed.isEmpty else { return }
        guard stream.last != collapsed else { return }
        stream.append(collapsed)
        if stream.count > SessionActivity.streamLimit {
            stream.removeFirst(stream.count - SessionActivity.streamLimit)
        }
    }
}

// MARK: - The shared surface

/// Everything the composer's status strip draws, for one session.
///
/// Never consult this from `TurnEngine.isQuiescent(sessionID:)` — it is derived display state. Two
/// reducers, one surface: at turn end an active todo list is dropped while a subagent is kept.
public struct SessionActivity: Sendable, Equatable {
    public var todos = TodoList()
    /// The backend's write counter for the plan `todos` was last set from, nil when no frame said.
    /// Monotonic per session store, so it orders a resume snapshot against live updates (FEAT-037);
    /// clearing the display at `message.start` deliberately leaves it, so that same plan cannot be
    /// seeded back from a snapshot of the same revision.
    public var todoRevision: Int?
    public var subagents: [SubagentRow] = []
    /// Agents this surface already retired, oldest first, so a roster read cannot draw them again; a failed async task stays in the backend's store for a day.
    public private(set) var retiredSubagentIDs: [String] = []

    public init() {}

    /// What Stop leaves behind: an empty surface that still remembers every agent it cleared, so a roster read already in flight cannot put them back.
    public func clearedForStop() -> SessionActivity {
        var cleared = SessionActivity()
        cleared.retiredSubagentIDs = retiredSubagentIDs
        cleared.retire(subagents)
        return cleared
    }

    mutating func retire(_ rows: [SubagentRow]) {
        for key in rows.flatMap(\.retirementKeys) where !retiredSubagentIDs.contains(key) {
            retiredSubagentIDs.append(key)
        }
        if retiredSubagentIDs.count > Self.retiredLimit {
            retiredSubagentIDs.removeFirst(retiredSubagentIDs.count - Self.retiredLimit)
        }
    }

    public var isEmpty: Bool { todos.items.isEmpty && subagents.isEmpty }

    // MARK: Bounds

    /// Matches the backend's own ceiling.
    public static let todoItemLimit = 256
    /// Per rendered item.
    public static let todoContentLimit = 200
    /// Rows per session.
    public static let subagentLimit = 32
    /// `goal` / `summary`.
    public static let subagentTextLimit = 240
    /// `model` / `currentTool` — short wire labels rendered on one line beside a goal.
    public static let subagentLabelLimit = 80
    /// Entries per row.
    public static let streamLimit = 24
    /// Per stream line.
    public static let streamLineLimit = 220
    /// Remembered retirements per session.
    public static let retiredLimit = 256

    /// The write barrier on the row count; call it at the end of every mutation of `subagents`.
    public mutating func enforceBounds() {
        guard subagents.count > Self.subagentLimit else { return }
        var excess = subagents.count - Self.subagentLimit
        // One pass (BUG-146): the oldest finished rows go first, in order, then the oldest of the rest.
        var rows: [SubagentRow] = []
        rows.reserveCapacity(subagents.count - excess)
        for row in subagents {
            if excess > 0, row.isTerminal {
                excess -= 1
                continue
            }
            rows.append(row)
        }
        if excess > 0 { rows.removeFirst(excess) }
        subagents = rows
    }

    // MARK: Shared clamps

    /// Truncate to `limit` characters with a single-character ellipsis; never widens past `limit`.
    static func clamped(_ text: String, to limit: Int) -> String {
        guard text.count > limit, limit > 1 else {
            return text.count > limit ? String(text.prefix(limit)) : text
        }
        return String(text.prefix(limit - 1)) + "…"
    }

    /// Whitespace-collapsed and clamped — what a one-line stream entry needs.
    static func collapsed(_ text: String, to limit: Int) -> String {
        let parts = text.split(whereSeparator: { $0.isWhitespace || $0.isNewline })
        return clamped(parts.joined(separator: " "), to: limit)
    }
}

// MARK: - The subagent reducer

extension SubagentEvent {
    /// Fold this frame's fields into a row; every assignment is conditional because subagent frames
    /// are partial by design.
    func merge(into row: inout SubagentRow) {
        // Never unset either of these, however partial the later frames are.
        if !subagentID.isEmpty { row.wireSubagentID = subagentID }
        if row.sessionID.isEmpty { row.sessionID = sessionID }
        if !delegationID.isEmpty { row.delegationID = delegationID }
        if phase == .start { row.hasStarted = true }
        if !goal.isEmpty { row.goal = goal }
        if !parentID.isEmpty { row.parentID = parentID }
        if !childSessionID.isEmpty { row.childSessionID = childSessionID }
        if !model.isEmpty { row.model = model }
        if !summary.isEmpty { row.summary = summary }
        if let taskIndex { row.taskIndex = taskIndex }
        if let taskCount { row.taskCount = taskCount }
        if let depth { row.depth = depth }
        if let durationSeconds { row.durationSeconds = durationSeconds }
        // Monotonic: `tool_count` is cumulative, so a decrease is a reordered or stale frame.
        if let toolCount { row.toolCount = max(row.toolCount, toolCount) }
        if phase == .tool, !toolName.isEmpty { row.currentTool = toolName }
        // A no-op when this phase contributes no line.
        row.appendStream(streamLine)
        // Terminal by EVENT TYPE; do not "simplify" this into a status lookup.
        if phase.isTerminal {
            row.state = SubagentRow.State(completeStatus: status)
            // Nothing is running, so a "now doing X" label would be a lie the row keeps telling.
            row.currentTool = ""
        }
        row.updatedAt = Date()
    }
}

extension SubagentSnapshot {
    /// Fill what a live row is missing; only `settling` (no frame since the read went out) lets the roster end a row.
    func fill(_ row: inout SubagentRow, settling: Bool, at moment: Date) {
        if row.wireSubagentID.isEmpty { row.wireSubagentID = subagentID }
        if row.goal.isEmpty, !goal.isEmpty { row.goal = goal }
        if row.model.isEmpty, !model.isEmpty { row.model = model }
        if row.parentID.isEmpty, !parentID.isEmpty { row.parentID = parentID }
        if row.delegationID.isEmpty, !delegationID.isEmpty { row.delegationID = delegationID }
        if row.depth == nil { row.depth = depth }
        if let toolCount { row.toolCount = max(row.toolCount, toolCount) }
        if hasStarted { row.hasStarted = true }
        row.acceptingSteer = acceptingSteer
        if settling, let terminalState {
            row.state = terminalState
            row.currentTool = ""
            row.updatedAt = moment
        }
    }
}

extension SessionActivity {
    /// The subagent reducer: upsert by identity, per-field merge, terminal freeze; nil when the
    /// frame was discarded. `turnStartedLocally` is stamped only onto rows this call creates.
    @discardableResult
    public mutating func upsert(_ update: SubagentEvent, turnStartedLocally: Bool) -> String? {
        let id = update.identity
        defer { enforceBounds() }

        if let index = subagents.firstIndex(where: { $0.id == id }) {
            // A terminal row freezes: a row revived back to `running` would never prune. The one exception is a late `complete` naming the real outcome of a row the roster could only call `ended`.
            guard !subagents[index].isTerminal || (subagents[index].state == .ended && update.phase.isTerminal) else { return nil }
            update.merge(into: &subagents[index])
            return id
        }

        // A frame for an id nobody announced is DISCARDED, not promoted into a headless row.
        guard update.phase.createsRow else { return nil }
        var row = SubagentRow(id: id, startedByThisClient: turnStartedLocally, sessionID: update.sessionID)
        update.merge(into: &row)
        subagents.append(row)
        return id
    }

    /// Retire finished agents and keep working ones; called at `message.start` and nowhere else.
    public mutating func pruneTerminalSubagents() {
        guard subagents.contains(where: \.isTerminal) else { return }
        retire(subagents.filter(\.isTerminal))
        subagents.removeAll(where: \.isTerminal)
        enforceBounds()
    }

    /// Fold a `subagent.list` answer into the roster without duplicating what live frames already drew; answers whether anything changed.
    ///
    /// Live frames stay authoritative: `observedAt` is when the read went out, and a row a frame touched after it is neither overwritten nor retired by this answer. A started agent the roster no longer lists ended out of sight and settles as `ended`; a queued one may not be registered yet, so it stays.
    @discardableResult
    public mutating func reconcile(
        _ roster: SubagentRoster,
        observedAt: Date,
        turnStartedLocally: Bool,
        sessionID: String,
        now: Date = Date()
    ) -> Bool {
        let before = subagents
        defer { enforceBounds() }
        let retired = Set(retiredSubagentIDs)

        for child in roster.subagents where !retired.contains(child.subagentID) {
            if let index = subagents.firstIndex(where: {
                $0.id == child.subagentID || $0.wireSubagentID == child.subagentID
            }) {
                guard !subagents[index].isTerminal else { continue }
                let settling = subagents[index].updatedAt <= observedAt
                child.fill(&subagents[index], settling: settling, at: now)
                continue
            }
            var row = SubagentRow(
                id: child.subagentID,
                wireSubagentID: child.subagentID,
                startedByThisClient: turnStartedLocally,
                hasStarted: child.hasStarted,
                goal: child.goal,
                state: child.terminalState ?? .running,
                parentID: child.parentID,
                model: child.model,
                toolCount: child.toolCount ?? 0,
                depth: child.depth,
                startedAt: child.startedAt ?? now,
                sessionID: sessionID,
                delegationID: child.delegationID,
                acceptingSteer: child.acceptingSteer,
                originUnknown: true
            )
            // A roster names the last tool, not one running now, so it seeds history and never `currentTool`.
            if !child.lastTool.isEmpty { row.appendStream(child.lastTool) }
            row.updatedAt = now
            subagents.append(row)
        }

        let listed = Set(roster.subagents.map(\.subagentID))
        for index in subagents.indices {
            let row = subagents[index]
            guard !row.isTerminal, row.hasStarted, !row.wireSubagentID.isEmpty,
                  !listed.contains(row.wireSubagentID), row.updatedAt <= observedAt else { continue }
            subagents[index].state = .ended
            subagents[index].currentTool = ""
            subagents[index].updatedAt = now
        }

        for task in roster.delegations where !retired.contains(task.rowID) {
            let covered = subagents.contains {
                $0.id == task.rowID
                    || (!$0.delegationID.isEmpty && $0.delegationID == task.delegationID && ($0.taskIndex ?? 0) == task.taskIndex)
            }
            guard !covered else { continue }
            let finished = task.completedAt ?? now
            var row = SubagentRow(
                id: task.rowID,
                startedByThisClient: turnStartedLocally,
                hasStarted: true,
                goal: task.goal,
                summary: task.error,
                state: SubagentRow.State(completeStatus: task.status),
                taskIndex: task.taskIndex,
                startedAt: task.dispatchedAt ?? finished,
                durationSeconds: task.dispatchedAt.map { max(0, finished.timeIntervalSince($0)) },
                sessionID: sessionID,
                delegationID: task.delegationID,
                originUnknown: true
            )
            row.updatedAt = finished
            subagents.append(row)
        }

        return subagents != before
    }

    /// Rows still working; the strip's header count.
    public var runningSubagents: [SubagentRow] { subagents.filter { !$0.isTerminal } }

    // MARK: Stopping what is running

    /// The `subagent_id`s Stop may send to `subagent.interrupt`: running rows with a wire id, deduped.
    public var interruptibleSubagentIDs: [String] {
        var seen = Set<String>()
        var ids: [String] = []
        for row in subagents where !row.isTerminal && !row.wireSubagentID.isEmpty {
            if seen.insert(row.wireSubagentID).inserted { ids.append(row.wireSubagentID) }
        }
        return ids
    }

    /// Running rows this client cannot ask the backend to kill; Stop has to say so.
    public var unkillableRunningSubagents: [SubagentRow] {
        subagents.filter { !$0.isTerminal && $0.wireSubagentID.isEmpty }
    }

    /// Retire a started row the backend answered `subagent.interrupt` with `found: false` for; a
    /// queued child answers the same way, so `hasStarted` is not an optional guard.
    @discardableResult
    public mutating func markSubagentInterrupted(
        wireSubagentID: String,
        at moment: Date = Date()
    ) -> Bool {
        guard !wireSubagentID.isEmpty,
              let index = subagents.firstIndex(where: {
                  $0.wireSubagentID == wireSubagentID && !$0.isTerminal && $0.hasStarted
              })
        else { return false }
        subagents[index].state = .interrupted
        subagents[index].currentTool = ""
        subagents[index].updatedAt = moment
        return true
    }

    /// Retire the named running rows; only for `delegation.status` answering with an EMPTY `active`
    /// list, and `ids` bounds it to the rows the caller saw before it asked.
    @discardableResult
    public mutating func markSubagentsInterrupted(ids: [String], at moment: Date = Date()) -> Int {
        guard !ids.isEmpty else { return 0 }
        let named = Set(ids)
        var changed = 0
        for index in subagents.indices
        where !subagents[index].isTerminal && named.contains(subagents[index].id) {
            subagents[index].state = .interrupted
            subagents[index].currentTool = ""
            subagents[index].updatedAt = moment
            changed += 1
        }
        return changed
    }
}
