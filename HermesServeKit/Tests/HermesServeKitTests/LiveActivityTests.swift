import XCTest

@testable import HermesServeKit

/// The Lock Screen card and the Dynamic Island are the two surfaces in
/// this app that cannot be inspected in a running view hierarchy and cannot be
/// photographed off a tethered device, so everything about them that arithmetic
/// can decide is decided in `LiveActivity.swift` and asserted here.
final class LiveActivityDerivationTests: XCTestCase {
    private func tool(_ id: String, running: Bool, name: String = "shell", context: String = "") -> ChatEntry {
        ChatEntry(
            id: id,
            kind: .tool,
            tool: ToolActivity(id: id, name: name, context: context, isRunning: running)
        )
    }

    private func user(_ id: String) -> ChatEntry {
        ChatEntry(id: id, kind: .user, text: "go")
    }

    // MARK: Turn boundary

    /// The denominator counts **this turn's** tools. Counting the whole
    /// transcript would make `7/12` climb across a long conversation and never
    /// come back down.
    func testProgressCountsOnlyTheCurrentTurn() {
        let entries = [
            user("u1"),
            tool("t1", running: false),
            tool("t2", running: false),
            user("u2"),
            tool("t3", running: false),
            tool("t4", running: true),
        ]
        let counts = LiveActivityDerivation.progress(in: entries)
        XCTAssertEqual(counts.completed, 1)
        XCTAssertEqual(counts.total, 2)
    }

    /// A turn whose tools arrived before any user row (a resumed transcript
    /// projected without its opening turn) still counts from the start rather
    /// than crashing on a missing boundary.
    func testProgressWithNoUserRowCountsEverything() {
        let entries = [tool("t1", running: false), tool("t2", running: true)]
        let counts = LiveActivityDerivation.progress(in: entries)
        XCTAssertEqual(counts.completed, 1)
        XCTAssertEqual(counts.total, 2)
    }

    /// The user row is the last thing in the transcript: an optimistic bubble
    /// with the turn not yet started. Zero of zero, not a crash and not a 1.
    func testProgressImmediatelyAfterSendIsZero() {
        let entries = [tool("t1", running: false), user("u1")]
        let counts = LiveActivityDerivation.progress(in: entries)
        XCTAssertEqual(counts.completed, 0)
        XCTAssertEqual(counts.total, 0)
    }

    func testRunningToolIsTheLastRunningOneInTheTurn() {
        let entries = [
            user("u1"),
            tool("t1", running: false, name: "read"),
            tool("t2", running: true, name: "shell"),
        ]
        XCTAssertEqual(LiveActivityDerivation.runningTool(in: entries)?.name, "shell")
    }

    func testNoRunningToolBetweenCalls() {
        let entries = [user("u1"), tool("t1", running: false)]
        XCTAssertNil(LiveActivityDerivation.runningTool(in: entries))
    }

    // MARK: Clipping

    func testClippedLeavesShortTextAlone() {
        XCTAssertEqual(LiveActivityDerivation.clipped("ls -la", to: 40), "ls -la")
    }

    func testClippedNeverExceedsTheLimit() {
        let long = String(repeating: "a", count: 500)
        XCTAssertEqual(LiveActivityDerivation.clipped(long, to: 80).count, 80)
    }

    func testClippedPrefersAWordBoundaryNearTheEnd() {
        let text = "run the build and then the whole test suite twice"
        let clipped = LiveActivityDerivation.clipped(text, to: 30)
        XCTAssertTrue(clipped.hasSuffix("…"))
        XCTAssertFalse(clipped.contains("  "))
        XCTAssertLessThanOrEqual(clipped.count, 30)
    }

    // MARK: Snapshot

    private func makeState(busy: Bool, entries: [ChatEntry], approval: ApprovalRequestEvent? = nil) -> SessionTurnState {
        var state = SessionTurnState()
        state.entries = entries
        state.isBusy = busy
        state.statusText = "Running tools"
        if let approval { state.pendingApprovals = [approval] }
        return state
    }

    private func approvalEvent(command: String, choices: [String] = ["once", "session", "always", "deny"]) -> ApprovalRequestEvent {
        ApprovalRequestEvent(
            sessionID: "s1",
            payload: .object([
                "command": .string(command),
                "description": .string("dangerous command"),
                "choices": .array(choices.map { .string($0) }),
            ])
        )
    }

    func testSnapshotCarriesProgressAndRunningTool() {
        let state = makeState(busy: true, entries: [
            user("u1"),
            tool("t1", running: false),
            tool("t2", running: true, name: "shell", context: "ls -la /tmp"),
        ])
        let snap = LiveActivityDerivation.snapshot(from: state, title: "Build check", startedAt: Date())
        XCTAssertEqual(snap.title, "Build check")
        XCTAssertEqual(snap.toolName, "shell")
        XCTAssertEqual(snap.toolDetail, "ls -la /tmp")
        XCTAssertEqual(snap.toolsCompleted, 1)
        XCTAssertEqual(snap.toolsTotal, 2)
        XCTAssertTrue(snap.isBusy)
        XCTAssertFalse(snap.hasApproval)
    }

    /// A chat with no title yet must not put an empty string on the Lock
    /// Screen, and must not put a session id there either.
    func testSnapshotFallsBackToAConversationTitle() {
        let snap = LiveActivityDerivation.snapshot(
            from: makeState(busy: true, entries: []),
            title: "",
            startedAt: Date()
        )
        XCTAssertEqual(snap.title, "Conversation")
    }

    func testSnapshotCarriesTheHeadApproval() {
        let approval = approvalEvent(command: "rm -rf /tmp/build")
        let state = makeState(busy: true, entries: [user("u1")], approval: approval)
        let snap = LiveActivityDerivation.snapshot(from: state, title: "T", startedAt: Date())
        XCTAssertTrue(snap.hasApproval)
        XCTAssertEqual(snap.approvalToken, approval.id.uuidString)
        XCTAssertEqual(snap.approvalCommand, "rm -rf /tmp/build")
        XCTAssertTrue(snap.approvalFitsIsland)
    }

    /// The redaction the sheet applies is applied here too — the island shows
    /// the same text the sheet does, or it shows nothing.
    func testSnapshotRunsTheSuppliedRedaction() {
        let state = makeState(busy: true, entries: [], approval: approvalEvent(command: "curl -H 'token: abc'"))
        let snap = LiveActivityDerivation.snapshot(
            from: state,
            title: "T",
            startedAt: Date(),
            redactCommand: { _ in "curl -H 'token: •••'" }
        )
        XCTAssertEqual(snap.approvalCommand, "curl -H 'token: •••'")
    }

    /// The 4 KB content-state limit is a silent failure — the card just stops
    /// updating — so the command is capped where it is built.
    func testSnapshotCapsAPathologicalCommand() {
        let state = makeState(busy: true, entries: [], approval: approvalEvent(command: String(repeating: "x", count: 20_000)))
        let snap = LiveActivityDerivation.snapshot(from: state, title: "T", startedAt: Date())
        XCTAssertLessThanOrEqual(snap.approvalCommand.count, LiveActivityDerivation.commandCap)
    }

    /// **The regression that matters.** A command long enough to be truncated
    /// must not become island-approvable *because* it was truncated. The fit is
    /// measured on the full command, not on what survived the cap.
    func testTruncationNeverMakesACommandApprovable() {
        let state = makeState(busy: true, entries: [], approval: approvalEvent(command: String(repeating: "x", count: 20_000)))
        let snap = LiveActivityDerivation.snapshot(from: state, title: "T", startedAt: Date())
        XCTAssertFalse(snap.approvalFitsIsland)
    }

    func testStaleDateIsTheApprovalBudgetAhead() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertEqual(LiveActivityDerivation.staleDate(from: now).timeIntervalSince(now), 300, accuracy: 0.001)
    }
}

/// The read gate, ported to a surface with no scroller.
final class IslandCommandBudgetTests: XCTestCase {
    func testEmptyCommandNeedsNoLinesAndDoesNotFit() {
        XCTAssertEqual(IslandCommandBudget.wrappedLineCount(""), 0)
        XCTAssertFalse(IslandCommandBudget.fits(""))
    }

    func testShortCommandFits() {
        XCTAssertTrue(IslandCommandBudget.fits("rm -rf /tmp/build"))
    }

    func testExactlyFourWrappedLinesFits() {
        let command = String(repeating: "a", count: IslandCommandBudget.columns * 4)
        XCTAssertEqual(IslandCommandBudget.wrappedLineCount(command), 4)
        XCTAssertTrue(IslandCommandBudget.fits(command))
    }

    func testOneCharacterPastTheBudgetDoesNotFit() {
        let command = String(repeating: "a", count: IslandCommandBudget.columns * 4 + 1)
        XCTAssertEqual(IslandCommandBudget.wrappedLineCount(command), 5)
        XCTAssertFalse(IslandCommandBudget.fits(command))
    }

    /// Newlines cost a whole line each. A five-line script of short lines is
    /// not island-approvable even though its character count is tiny — the
    /// point of the gate is what is *on screen*, not how many bytes it is.
    func testNewlinesCostWholeLines() {
        let command = "cd /tmp\nls\npwd\nwhoami\nid"
        XCTAssertEqual(IslandCommandBudget.wrappedLineCount(command), 5)
        XCTAssertFalse(IslandCommandBudget.fits(command))
    }

    /// A blank line in the middle of a script is still a line on screen.
    func testBlankInteriorLinesAreCounted() {
        XCTAssertEqual(IslandCommandBudget.wrappedLineCount("a\n\nb"), 3)
    }

    func testLeadingAndTrailingWhitespaceIsNotCharged() {
        XCTAssertEqual(IslandCommandBudget.wrappedLineCount("\n\n  ls -la  \n\n"), 1)
    }
}

/// The consent gate for a button that lives outside the approval sheet.
final class IslandApprovalGateTests: XCTestCase {
    private let token = "11111111-1111-1111-1111-111111111111"
    private let other = "22222222-2222-2222-2222-222222222222"
    private let all: [ApprovalChoice] = [.once, .session, .always, .deny]

    private func approve(
        token: String? = nil,
        head: String?,
        choices: [ApprovalChoice]? = nil,
        fits: Bool = true,
        authenticated: Bool = true
    ) -> IslandApprovalDecision {
        IslandApprovalGate.decideApprove(
            token: token ?? self.token,
            headToken: head,
            headChoices: choices ?? all,
            commandFitsIsland: fits,
            authenticated: authenticated
        )
    }

    func testApproveSucceedsWhenEveryClauseHolds() {
        XCTAssertEqual(approve(head: token), .submit)
    }

    /// **The cold-launch case.** `openAppWhenRun` relaunches a killed app, and
    /// the approval queue is in-memory only, so the request the button was
    /// drawn for is simply gone. Answering positionally at that point would
    /// answer whatever arrives next, sight unseen.
    func testApproveRefusesWhenNothingIsWaiting() {
        XCTAssertEqual(approve(head: nil), .refuseNoRequest)
        XCTAssertEqual(approve(head: ""), .refuseNoRequest)
    }

    /// The queue moved while the Face ID sheet was up — an approval ages out at
    /// 300 s and the next one takes the head slot.
    func testApproveRefusesADifferentHeadRequest() {
        XCTAssertEqual(approve(head: other), .refuseStaleToken)
    }

    func testApproveRefusesAnEmptyToken() {
        XCTAssertEqual(approve(token: "", head: ""), .refuseNoRequest)
        XCTAssertEqual(approve(token: "", head: other), .refuseStaleToken)
    }

    /// The read gate. A command too long to show whole was never approvable
    /// from the island, and no amount of authentication changes that.
    func testApproveRefusesAnUnreadableCommandEvenWhenAuthenticated() {
        XCTAssertEqual(approve(head: token, fits: false), .refuseUnread)
    }

    /// A tirith-flagged approval keeps `once` but a backend that offers only
    /// deny must not be answered with an allow.
    func testApproveRefusesWhenOnceWasNotOffered() {
        XCTAssertEqual(approve(head: token, choices: [.deny]), .refuseChoiceUnavailable)
    }

    /// **The branch that must never regress.** Face ID failed, was cancelled, or
    /// could not be evaluated at all: no submission.
    func testApproveRefusesOnFailedAuthentication() {
        XCTAssertEqual(approve(head: token, authenticated: false), .refuseUnauthenticated)
    }

    /// Ordering: the cheap, silent refusals are reached before the one that
    /// would have raised a biometric prompt, which is what lets the caller
    /// pre-flight with `authenticated: true` and not prompt for a dead request.
    func testStalenessIsCheckedBeforeAuthentication() {
        XCTAssertEqual(approve(head: other, authenticated: false), .refuseStaleToken)
    }

    // MARK: Deny

    /// Deny is the fail-closed answer and is never gated in the sheet either.
    func testDenyNeedsNoAuthenticationOrReadGate() {
        XCTAssertEqual(IslandApprovalGate.decideDeny(token: token, headToken: token), .submit)
    }

    /// It still has to be the *right* request.
    func testDenyRefusesAStaleToken() {
        XCTAssertEqual(IslandApprovalGate.decideDeny(token: token, headToken: other), .refuseStaleToken)
        XCTAssertEqual(IslandApprovalGate.decideDeny(token: token, headToken: nil), .refuseNoRequest)
    }
}

/// Spec §5.3 — `Chats on Lock Screen (n of 2)`.
final class LiveActivityRosterTests: XCTestCase {
    func testCapIsTwo() {
        XCTAssertEqual(LiveActivityRoster.cap, 2)
    }

    func testFirstChatStarts() {
        let plan = LiveActivityRoster.plan(desired: ["a"], current: [])
        XCTAssertEqual(plan.start, ["a"])
        XCTAssertTrue(plan.end.isEmpty)
    }

    /// A chat already on screen is updated, never restarted — an ended and
    /// restarted activity loses its slot in the Dynamic Island and resets its
    /// elapsed timer.
    func testRunningChatIsKeptNotRestarted() {
        let plan = LiveActivityRoster.plan(desired: ["a", "b"], current: ["a"])
        XCTAssertEqual(plan.start, ["b"])
        XCTAssertEqual(plan.keep, ["a"])
        XCTAssertTrue(plan.end.isEmpty)
    }

    /// **The cap under pressure.** A third chat starts a turn: the oldest of the
    /// three loses its card, because `desired` is most-recent-first.
    func testThirdChatEvictsTheOldest() {
        let plan = LiveActivityRoster.plan(desired: ["c", "b", "a"], current: ["a", "b"])
        XCTAssertEqual(plan.start, ["c"])
        XCTAssertEqual(plan.end, ["a"])
        XCTAssertEqual(plan.keep, ["b"])
    }

    func testFinishedChatIsEnded() {
        let plan = LiveActivityRoster.plan(desired: [], current: ["a", "b"])
        XCTAssertEqual(plan.end, ["a", "b"])
        XCTAssertTrue(plan.start.isEmpty)
    }

    func testDuplicatesInDesiredDoNotConsumeTheCapTwice() {
        let plan = LiveActivityRoster.plan(desired: ["a", "a", "b"], current: [])
        XCTAssertEqual(plan.start, ["a", "b"])
    }

    /// A cap of zero is the master toggle off: everything ends, nothing starts.
    func testCapOfZeroEndsEverything() {
        let plan = LiveActivityRoster.plan(desired: ["a", "b"], current: ["a", "b"], cap: 0)
        XCTAssertTrue(plan.start.isEmpty)
        XCTAssertEqual(plan.end, ["a", "b"])
    }

    func testNoChangeIsEmpty() {
        XCTAssertTrue(LiveActivityRoster.plan(desired: ["a"], current: ["a"]).isEmpty)
    }
}
