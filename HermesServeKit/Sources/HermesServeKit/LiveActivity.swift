import Foundation

// MARK: - The payload

/// The ActivityKit `ContentState`; ActivityKit silently rejects one over 4 KB, so every string
/// here is capped where it is built, never trusted from the wire.
public struct LiveActivitySnapshot: Codable, Hashable, Sendable {
    /// Chat title, already resolved (never an id, never empty).
    public var title: String
    /// `tool.start`'s name for the running tool, `""` when nothing is running.
    public var toolName: String
    public var toolDetail: String
    public var toolsCompleted: Int
    /// Tool calls seen so far in the current turn; `7/12` is `toolsCompleted`/`toolsTotal`.
    public var toolsTotal: Int
    public var isBusy: Bool
    public var statusText: String
    /// When the turn started; ActivityKit ticks the card's timer from here without updates.
    public var startedAt: Date

    // MARK: The approval half

    /// The head approval's client-side identity; approvals carry no `request_id` on the wire.
    public var approvalToken: String
    /// The redacted, capped command; rendered only in the expanded island, never on the Lock Screen.
    public var approvalCommand: String
    public var approvalDescription: String
    /// Whether the expanded island can show ALL of this command; false means Deny only.
    public var approvalFitsIsland: Bool

    // MARK: The wind-down

    /// When the turn ended; not derived from `isBusy`, because a card can be idle between tools.
    public var endedAt: Date?

    public var hasEnded: Bool { endedAt != nil }

    public var hasApproval: Bool { !approvalToken.isEmpty }

    // MARK: The presentation split

    /// Which presentations this card may fill; optional for decode safety, since an activity
    /// outlives the process that started it and an older archived state predates the field.
    public var surfaces: LiveActivitySurfaces?

    /// The surfaces this card may fill, defaulting to both.
    public var shownSurfaces: LiveActivitySurfaces { surfaces ?? .both }

    /// Draw the full Lock Screen card; false means the reduced one, which cannot be removed.
    public var showsOnLockScreen: Bool { shownSurfaces.lockScreen }

    public var showsInIsland: Bool { shownSurfaces.island }

    public init(
        title: String = "",
        toolName: String = "",
        toolDetail: String = "",
        toolsCompleted: Int = 0,
        toolsTotal: Int = 0,
        isBusy: Bool = false,
        statusText: String = "",
        startedAt: Date = Date(),
        approvalToken: String = "",
        approvalCommand: String = "",
        approvalDescription: String = "",
        approvalFitsIsland: Bool = false,
        endedAt: Date? = nil,
        surfaces: LiveActivitySurfaces? = nil
    ) {
        self.title = title
        self.toolName = toolName
        self.toolDetail = toolDetail
        self.toolsCompleted = toolsCompleted
        self.toolsTotal = toolsTotal
        self.isBusy = isBusy
        self.statusText = statusText
        self.startedAt = startedAt
        self.approvalToken = approvalToken
        self.approvalCommand = approvalCommand
        self.approvalDescription = approvalDescription
        self.approvalFitsIsland = approvalFitsIsland
        self.endedAt = endedAt
        self.surfaces = surfaces
    }
}

// MARK: - The two presentations

/// Which of a Live Activity's two presentations Hermes fills — a presentation split, not two
/// activities: `lockScreen == false` strips the card to a state word rather than removing it,
/// `island == false` cannot suppress the system's own pill, and both false means no request at all.
public struct LiveActivitySurfaces: Codable, Hashable, Sendable {
    public var lockScreen: Bool
    public var island: Bool

    public init(lockScreen: Bool = true, island: Bool = true) {
        self.lockScreen = lockScreen
        self.island = island
    }

    /// Everything Hermes has ever shown, and the value an older card decodes to.
    public static let both = LiveActivitySurfaces()

    public var isEmpty: Bool { !lockScreen && !island }
}

// MARK: - When a card is earned

/// Which turns earn a Live Activity at all; `everyTurn` is the shipped default.
public enum LiveActivityShowPolicy: String, Codable, Hashable, Sendable, CaseIterable {
    /// Any running turn, plus every question.
    case everyTurn
    /// Only a turn blocked on a person, as `SessionTurnState.hasBlockingPrompt` defines it.
    case questionsOnly

    /// Does a session in this state earn a card? A question always does, under either policy.
    public func admits(isBusy: Bool, hasBlockingPrompt: Bool) -> Bool {
        if hasBlockingPrompt { return true }
        switch self {
        case .everyTurn: return isBusy
        case .questionsOnly: return false
        }
    }

    /// The label the settings picker shows.
    public var label: String {
        switch self {
        case .everyTurn: return "Every turn"
        case .questionsOnly: return "Questions"
        }
    }
}

/// The four skin seeds, carried into the widget process because the extension has its own
/// `UserDefaults`; changing skin mid-turn does not repaint a live card.
public struct LiveActivitySkinSeed: Codable, Hashable, Sendable {
    public var fg: UInt32
    public var accent: UInt32
    public var bg: UInt32
    public var card: UInt32
    /// `true` when the app resolved to its dark polarity at request time.
    public var isDark: Bool

    public init(fg: UInt32, accent: UInt32, bg: UInt32, card: UInt32, isDark: Bool) {
        self.fg = fg
        self.accent = accent
        self.bg = bg
        self.card = card
        self.isDark = isDark
    }
}

// MARK: - Derivation

/// Turns a session's live turn state into the snapshot above, as pure functions on plain values.
public enum LiveActivityDerivation {
    /// Longest command carried in a content state, so nothing pushes it past ActivityKit's 4 KB.
    public static let commandCap = 480
    /// Caps for the two free-text lines.
    public static let lineCap = 120

    /// How long a card may go without an update before it is greyed out; 300 s is the approval budget.
    public static let staleWindow: TimeInterval = 300

    public static func staleDate(from date: Date) -> Date {
        date.addingTimeInterval(staleWindow)
    }

    /// The terminal snapshot for a card winding down; everything interactive is stripped.
    public static func ended(
        _ snapshot: LiveActivitySnapshot,
        at date: Date,
        failed: Bool = false
    ) -> LiveActivitySnapshot {
        var ended = snapshot
        ended.endedAt = date
        ended.isBusy = false
        ended.statusText = failed ? "Failed" : ""
        ended.toolName = ""
        ended.toolDetail = ""
        ended.approvalToken = ""
        ended.approvalCommand = ""
        ended.approvalDescription = ""
        ended.approvalFitsIsland = false
        return ended
    }

    /// The one-line status under the card's title; ended beats stale, stale beats live (BUG-003).
    public static func toolLine(for state: LiveActivitySnapshot, isStale: Bool) -> String {
        if state.hasEnded { return state.statusText.isEmpty ? "Done" : state.statusText }
        if isStale { return "No longer updating" }
        if !state.toolName.isEmpty {
            return state.toolDetail.isEmpty ? state.toolName : "\(state.toolName) · \(state.toolDetail)"
        }
        if !state.statusText.isEmpty { return state.statusText }
        return state.isBusy ? "Working…" : "Idle"
    }

    /// The one label the trimmed card carries: `7/12` and the state word share a slot, state word
    /// wins, and it is empty before the first tool call because `0/0` is noise.
    public static func progressLabel(for state: LiveActivitySnapshot, isStale: Bool) -> String {
        if state.hasEnded { return state.statusText.isEmpty ? "Done" : state.statusText }
        if isStale { return "No longer updating" }
        guard state.toolsTotal > 0 else { return "" }
        return "\(state.toolsCompleted)/\(state.toolsTotal)"
    }

    /// All a card says with its Lock Screen presentation off; every return is a constant, so no
    /// session content can reach this text.
    public static func reducedLine(for state: LiveActivitySnapshot, isStale: Bool) -> String {
        if state.hasEnded { return "Finished" }
        if isStale { return "No longer updating" }
        if state.hasApproval { return "Waiting for you" }
        return state.isBusy ? "Running" : "Idle"
    }

    /// The current turn's tool calls — everything after the last `.user` row, since counting across
    /// the whole transcript would make `7/12` climb forever.
    public static func currentTurnTools(in entries: [ChatEntry]) -> [ToolActivity] {
        let start = entries.lastIndex { $0.kind == .user }.map { $0 + 1 } ?? 0
        guard start <= entries.count else { return [] }
        return entries[start...].compactMap { $0.tool }
    }

    /// `toolsCompleted` / `toolsTotal`; the denominator is tools seen so far, never a promise.
    public static func progress(in entries: [ChatEntry]) -> (completed: Int, total: Int) {
        let tools = currentTurnTools(in: entries)
        return (tools.filter { !$0.isRunning }.count, tools.count)
    }

    /// The running tool, if one is; nil is not a failure, as a turn spends most time between tools.
    public static func runningTool(in entries: [ChatEntry]) -> ToolActivity? {
        currentTurnTools(in: entries).last { $0.isRunning }
    }

    /// Clip to `limit` characters on a nearby whitespace boundary, with an ellipsis.
    public static func clipped(_ text: String, to limit: Int) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > limit, limit > 1 else { return trimmed }
        let head = trimmed.prefix(limit - 1)
        // Prefer a word boundary, but not at the cost of most of the budget.
        if let space = head.lastIndex(where: { $0 == " " || $0 == "\n" }),
           head.distance(from: head.startIndex, to: space) > limit / 2 {
            return head[head.startIndex..<space] + "…"
        }
        return head + "…"
    }

    /// Build the content state for one session; the caller resolves `title`.
    public static func snapshot(
        from state: SessionTurnState,
        title: String,
        startedAt: Date,
        redactCommand: (String) -> String = { $0 },
        // In the content state, not the attributes, which are immutable for an activity's life.
        surfaces: LiveActivitySurfaces = .both
    ) -> LiveActivitySnapshot {
        let counts = progress(in: state.entries)
        let running = runningTool(in: state.entries)
        let approval = state.currentApproval

        let command = approval.map { clipped(redactCommand($0.command), to: commandCap) } ?? ""

        return LiveActivitySnapshot(
            title: clipped(title.isEmpty ? "Conversation" : title, to: lineCap),
            toolName: clipped(running?.name ?? "", to: 40),
            toolDetail: clipped(running?.context ?? "", to: lineCap),
            toolsCompleted: counts.completed,
            toolsTotal: counts.total,
            isBusy: state.isBusy,
            statusText: clipped(state.statusText, to: lineCap),
            startedAt: startedAt,
            approvalToken: approval?.id.uuidString ?? "",
            approvalCommand: command,
            approvalDescription: clipped(approval?.description ?? "", to: lineCap),
            // Measured UNCLIPPED: a command that only fits because it was truncated is not read.
            approvalFitsIsland: approval.map {
                IslandCommandBudget.fits(redactCommand($0.command))
            } ?? false,
            surfaces: surfaces
        )
    }
}

// MARK: - The read gate, ported to a surface that cannot scroll

/// How much command text the expanded island can show IN FULL, and so when Approve may exist there;
/// deliberately conservative, because the widget renders at the viewer's unknowable Dynamic Type size.
public enum IslandCommandBudget {
    public static let columns = 38
    public static let lines = 4

    /// Lines the command needs when hard-wrapped at `columns`; an empty command is zero, not one.
    public static func wrappedLineCount(_ command: String, columns: Int = columns) -> Int {
        guard columns > 0 else { return .max }
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return 0 }
        return trimmed.split(separator: "\n", omittingEmptySubsequences: false).reduce(0) { total, line in
            total + max(1, Int((Double(line.count) / Double(columns)).rounded(.up)))
        }
    }

    /// True when every character of the command can be shown at once.
    public static func fits(_ command: String, columns: Int = columns, lines: Int = lines) -> Bool {
        let needed = wrappedLineCount(command, columns: columns)
        return needed > 0 && needed <= lines
    }
}

// MARK: - The consent gate

/// What a Live Activity button is allowed to do.
public enum IslandApprovalDecision: String, Sendable, Equatable {
    /// Send the answer.
    case submit
    /// Nothing is waiting — usually a relaunch the in-memory queue did not survive.
    case refuseNoRequest
    /// Something is waiting, but not the request this button was drawn for.
    case refuseStaleToken
    /// The backend did not offer this choice for this request.
    case refuseChoiceUnavailable
    /// The second factor failed, was cancelled, or could not be evaluated.
    case refuseUnauthenticated
    /// The command does not fit the island, so it was never approvable there.
    case refuseUnread
}

/// The rule for answering an approval from outside the sheet, and no weaker: the narrowest allow
/// (`once` only), a biometric, and a refusal on any command too long to show whole. The token check
/// matters because `approval.request` is answered positionally with no request id.
public enum IslandApprovalGate {
    /// Approve; every clause must hold. Call it twice — once with `authenticated: true` before
    /// prompting, again with the real result, because the queue can move while the prompt is up.
    public static func decideApprove(
        token: String,
        headToken: String?,
        headChoices: [ApprovalChoice],
        commandFitsIsland: Bool,
        authenticated: Bool
    ) -> IslandApprovalDecision {
        guard let headToken, !headToken.isEmpty else { return .refuseNoRequest }
        guard !token.isEmpty, headToken == token else { return .refuseStaleToken }
        guard commandFitsIsland else { return .refuseUnread }
        guard headChoices.contains(.once) else { return .refuseChoiceUnavailable }
        guard authenticated else { return .refuseUnauthenticated }
        return .submit
    }

    /// Deny: no second factor and no read gate, but the token must still match.
    public static func decideDeny(token: String, headToken: String?) -> IslandApprovalDecision {
        guard let headToken, !headToken.isEmpty else { return .refuseNoRequest }
        guard !token.isEmpty, headToken == token else { return .refuseStaleToken }
        return .submit
    }
}

// MARK: - The roster

/// Which chats hold a Live Activity, and what to do when more want one than the cap allows.
public struct LiveActivityRosterPlan: Sendable, Equatable {
    public var start: [String]
    public var end: [String]
    /// Sessions that keep the activity they already have.
    public var keep: [String]

    public var isEmpty: Bool { start.isEmpty && end.isEmpty }
}

public enum LiveActivityRoster {
    /// `Chats on Lock Screen (n of 2)`.
    public static let cap = 2

    /// Reconcile what the user wants against what is running; `desired` is most recently active
    /// first, so oldest loses, and a chat already on screen is updated rather than restarted.
    public static func plan(desired: [String], current: [String], cap: Int = cap) -> LiveActivityRosterPlan {
        var seen = Set<String>()
        let ordered = desired.filter { seen.insert($0).inserted }
        let survivors = Array(ordered.prefix(max(0, cap)))
        let survivorSet = Set(survivors)
        let currentSet = Set(current)

        return LiveActivityRosterPlan(
            start: survivors.filter { !currentSet.contains($0) },
            end: current.filter { !survivorSet.contains($0) },
            keep: survivors.filter { currentSet.contains($0) }
        )
    }
}
