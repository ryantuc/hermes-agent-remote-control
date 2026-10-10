import HermesServeKit
import SwiftUI
import UIKit
import XCTest

@testable import HermesMobile

/// The automation line (goal, loop, heartbeat) and the processes line above the composer: they appear only when the backend reports something running, they stay away on a backend without the methods and in demo mode, and each costs one 44 pt line like the strip's other groups.
final class SessionControlsStripTests: XCTestCase {

    private static let width: CGFloat = 393

    private static let goalSnapshot: JSONValue = .object([
        "goal": .object([
            "title": .string("Ship the release notes"),
            "status": .string("active"),
            "turns_used": .number(3),
            "max_turns": .number(20),
            "contract": .object([:]),
            "subgoals": .array([]),
            "gates": .array([]),
        ]),
        "loop": .null,
        "heartbeat": .null,
        "revision": .string("r1"),
        "updated_at": .number(1_759_900_000),
    ])

    private static let emptySnapshot: JSONValue = .object([
        "goal": .null, "loop": .null, "heartbeat": .null, "revision": .string(""), "updated_at": .number(0),
    ])

    private static let runningProcess: JSONValue = .object([
        "session_id": .string("proc_7f3a"),
        "command": .string("npm run dev"),
        "cwd": .string("/Users/you/app"),
        "pid": .number(48213),
        "started_at": .string("2026-10-09T16:40:12"),
        "uptime_seconds": .number(95),
        "status": .string("running"),
        "output_preview": .string("ready"),
    ])

    @MainActor
    private func openChat(_ harness: AppHarness, storedID: String) async throws -> (ChatModel, String) {
        let chat = harness.chat(storedID: storedID)
        await chat.open()
        let bound = await waitUntil { chat.runtimeSessionID != nil }
        XCTAssertTrue(bound, "open() never bound a runtime id")
        return (chat, try XCTUnwrap(chat.runtimeSessionID))
    }

    @MainActor
    private func measure<V: View>(_ view: V) -> CGFloat {
        let host = UIHostingController(rootView: AnyView(view.frame(width: Self.width)))
        host.safeAreaRegions = []
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: Self.width, height: 900))
        window.rootViewController = host
        window.makeKeyAndVisible()
        window.layoutIfNeeded()
        host.view.layoutIfNeeded()
        let size = host.sizeThatFits(in: CGSize(width: Self.width, height: .greatestFiniteMagnitude))
        window.isHidden = true
        return size.height
    }

    // MARK: Appears only when something is active

    /// Opening a chat reads `session.control.read` once; a session with no automation draws nothing, and a goal arriving on `session.control.update` draws the line.
    @MainActor
    func testTheAutomationLineAppearsOnlyWhenTheBackendReportsSomething() async throws {
        let harness = await AppHarness.make()
        await harness.backend.stub("session.control.read") { _ in .object(["control": Self.emptySnapshot]) }
        await harness.backend.stub("process.list") { _ in .object(["processes": .array([])]) }
        try await harness.openSocket()
        let (chat, runtimeID) = try await openChat(harness, storedID: "20261009_170000_goal")

        let read = await waitUntil { chat.sessionControls.support == .supported }
        XCTAssertTrue(read, "the open never read session.control.read")
        let reads = await harness.backend.callCount("session.control.read")
        XCTAssertGreaterThanOrEqual(reads, 1)
        XCTAssertFalse(chat.sessionControls.isVisible, "nothing is running, so nothing is drawn")
        XCTAssertNil(chat.sessionControls.line)
        XCTAssertEqual(measure(SessionActivityStrip(activity: SessionActivity(), controls: chat.sessionControls, processes: chat.backgroundProcesses)), 0, accuracy: 0.5)

        await harness.backend.emit("session.control.update", sessionID: runtimeID, payload: .object(["control": Self.goalSnapshot]))
        let drawn = await waitUntil { chat.sessionControls.isVisible }
        XCTAssertTrue(drawn, "the pushed goal never reached the model")
        let line = try XCTUnwrap(chat.sessionControls.line)
        XCTAssertEqual(line.title, "◎ Goal")
        XCTAssertEqual(line.detail, "turn 3/20")
        XCTAssertEqual(line.note, "Ship the release notes")

        let height = measure(SessionActivityStrip(activity: SessionActivity(), controls: chat.sessionControls, processes: chat.backgroundProcesses))
        XCTAssertEqual(height, Hit.min, accuracy: 1, "one group, one 44 pt line")

        await harness.backend.emit("session.control.update", sessionID: runtimeID, payload: .object(["control": Self.emptySnapshot]))
        let gone = await waitUntil { !chat.sessionControls.isVisible }
        XCTAssertTrue(gone, "clearing the goal must take the line away")

        await harness.tearDown()
    }

    /// The processes line counts what is running and names the first command; a finished process alone earns no line.
    @MainActor
    func testTheProcessesLineAppearsWhileSomethingRuns() async throws {
        let harness = await AppHarness.make()
        await harness.backend.stub("session.control.read") { _ in .object(["control": Self.emptySnapshot]) }
        await harness.backend.stub("process.list") { _ in .object(["processes": .array([Self.runningProcess])]) }
        try await harness.openSocket()
        let (chat, _) = try await openChat(harness, storedID: "20261009_170100_proc")

        let read = await waitUntil { chat.backgroundProcesses.isVisible }
        XCTAssertTrue(read, "the open never read process.list, or the running row was dropped")
        let line = try XCTUnwrap(chat.backgroundProcesses.line)
        XCTAssertEqual(line.title, "$ Processes")
        XCTAssertEqual(line.detail, "1 running")
        XCTAssertEqual(line.note, "npm run dev")
        XCTAssertEqual(measure(SessionActivityStrip(activity: SessionActivity(), controls: chat.sessionControls, processes: chat.backgroundProcesses)), Hit.min, accuracy: 1)

        var exited = Self.runningProcess.objectValue ?? [:]
        exited["status"] = .string("exited")
        exited["exit_code"] = .number(0)
        exited["exited_at"] = .number(1_759_999_999)
        let finished = JSONValue.object(exited)
        await harness.backend.stub("process.list") { _ in .object(["processes": .array([finished])]) }
        await chat.backgroundProcesses.refresh()
        XCTAssertFalse(chat.backgroundProcesses.isVisible, "a finished process is listed in the sheet but earns no line")
        XCTAssertEqual(chat.backgroundProcesses.finished.count, 1)

        await harness.tearDown()
    }

    /// Both lines together cost two lines, and the strip's own groups are unaffected.
    @MainActor
    func testEachNewGroupCostsOneLine() {
        let controls = SessionControlsModel()
        controls.seed(SessionControlSnapshot(json: Self.goalSnapshot))
        let processes = BackgroundProcessesModel()
        processes.seed([BackgroundProcess(json: Self.runningProcess)!])

        let both = measure(SessionActivityStrip(activity: SessionActivity(), controls: controls, processes: processes))
        XCTAssertEqual(both, 2 * Hit.min, accuracy: 1)
        let neither = measure(SessionActivityStrip(activity: SessionActivity(), controls: SessionControlsModel(), processes: BackgroundProcessesModel()))
        XCTAssertEqual(neither, 0, accuracy: 0.5)
        let long = SessionControlsModel()
        long.seed(SessionControlSnapshot(goal: GoalSnapshot(title: String(repeating: "a very long goal title that will not fit ", count: 8), status: "active", turnsUsed: 1, maxTurns: 0), loop: LoopSnapshot(prompt: "p", status: "active"), heartbeat: HeartbeatSnapshot(prompt: "h", status: "active", intervalSeconds: 60), revision: "r"))
        XCTAssertEqual(measure(SessionActivityStrip(activity: SessionActivity(), controls: long)), Hit.min, accuracy: 1, "three kinds and a long title still rest on one line")
        XCTAssertEqual(long.line?.title, "◎ Goal · loop · heartbeat")
    }

    // MARK: Hidden where it cannot work

    /// An older or stock backend without the method family answers -32601 (`tui_gateway/rpc_dispatch.py:23`); the entry points hide and nothing is asked again for that session.
    @MainActor
    func testABackendWithoutTheMethodsHidesBothLines() async throws {
        let harness = await AppHarness.make()
        await harness.backend.failRPC("session.control.read", code: -32601, message: "unknown method: session.control.read — the client and the Hermes backend are out of sync")
        await harness.backend.failRPC("process.list", code: 4000, message: "invalid params for process.list: session_id: Extra inputs are not permitted")
        try await harness.openSocket()
        let (chat, runtimeID) = try await openChat(harness, storedID: "20261009_170200_old")

        let decided = await waitUntil { chat.sessionControls.support == .unsupported && chat.backgroundProcesses.support == .unsupported }
        XCTAssertTrue(decided, "the refusals never settled the support question")
        XCTAssertFalse(chat.sessionControls.isVisible)
        XCTAssertFalse(chat.backgroundProcesses.isVisible)
        XCTAssertNil(chat.sessionControls.lastError, "an absent method is not an error the user is shown")

        // The end-of-turn edge must not ask again.
        await harness.backend.emit("message.start", sessionID: runtimeID)
        await harness.backend.emit("message.complete", sessionID: runtimeID, payload: .object(["text": .string("Done."), "status": .string("complete")]))
        let settled = await waitUntil { !chat.live.isBusy }
        XCTAssertTrue(settled)
        _ = await waitUntil(timeout: 0.5) { false }
        let controlReads = await harness.backend.callCount("session.control.read")
        let processReads = await harness.backend.callCount("process.list")
        XCTAssertEqual(controlReads, 1)
        XCTAssertEqual(processReads, 1)
        let acted = await chat.sessionControls.perform(.goalPause)
        XCTAssertFalse(acted, "an action on an unsupported backend is refused locally")

        await harness.tearDown()
    }

    /// A transient failure is not a verdict: the next edge reads again.
    @MainActor
    func testATransientFailureLeavesTheQuestionOpen() async throws {
        let harness = await AppHarness.make()
        await harness.backend.failNextRPC("session.control.read", code: 5031, message: "session.control.read failed: store locked")
        await harness.backend.stub("session.control.read") { _ in .object(["control": Self.goalSnapshot]) }
        await harness.backend.stub("process.list") { _ in .object(["processes": .array([])]) }
        try await harness.openSocket()
        let (chat, runtimeID) = try await openChat(harness, storedID: "20261009_170300_retry")

        let asked = await waitUntil { await harness.backend.callCount("session.control.read") == 1 }
        XCTAssertTrue(asked)
        XCTAssertEqual(chat.sessionControls.support, .unknown)

        // A turn runs and ends; the end is the edge that reads again.
        await harness.backend.emit("message.start", sessionID: runtimeID)
        let busy = await waitUntil { chat.live.isBusy }
        XCTAssertTrue(busy)
        await harness.backend.emit("message.complete", sessionID: runtimeID, payload: .object(["text": .string("Done."), "status": .string("complete")]))
        let drawn = await waitUntil { chat.sessionControls.isVisible }
        XCTAssertTrue(drawn, "the end-of-turn edge should have read again and found the goal")

        await harness.tearDown()
    }

    /// Demo mode has no backend to ask, so the lines never appear there.
    @MainActor
    func testDemoModeNeverShowsTheLines() async throws {
        let harness = await AppHarness.make()
        await harness.app.enterDemo(playbackSpeed: 50, autoplay: false)
        XCTAssertTrue(harness.app.isDemoActive)
        let chat = harness.app.chat(for: harness.app.demoThreadRoute)

        XCTAssertNil(chat.sessionControlTransport, "demo mode must hand the strip nothing to talk to")
        chat.sessionControls.scheduleRefresh()
        chat.backgroundProcesses.scheduleRefresh()
        _ = await waitUntil(timeout: 0.3) { false }
        XCTAssertEqual(chat.sessionControls.support, .unknown)
        XCTAssertFalse(chat.sessionControls.isVisible)
        XCTAssertFalse(chat.backgroundProcesses.isVisible)

        await harness.app.exitDemo()
        await harness.tearDown()
    }

    // MARK: Acting

    /// A pause goes out as the declared action and the answer's snapshot replaces ours; a resume that answers `type: "send"` submits its kickoff prompt as a turn.
    @MainActor
    func testActionsAdoptTheAnsweredSnapshotAndAResumeSubmitsItsKickoff() async throws {
        let harness = await AppHarness.make()
        await harness.backend.stub("session.control.read") { _ in .object(["control": Self.goalSnapshot]) }
        await harness.backend.stub("process.list") { _ in .object(["processes": .array([])]) }
        var paused = Self.goalSnapshot.objectValue ?? [:]
        var goal = paused["goal"]?.objectValue ?? [:]
        goal["status"] = .string("paused")
        goal["paused_reason"] = .string("Paused from the phone")
        paused["goal"] = .object(goal)
        let pausedSnapshot = JSONValue.object(paused)
        await harness.backend.stub("session.control") { call in
            switch call.params["action"]?.stringValue {
            case "goal.pause":
                return .object(["control": pausedSnapshot, "dispatch": .object(["type": .null, "output": .null, "notice": .null, "message": .null, "display": .null])])
            default:
                return .object(["control": Self.goalSnapshot, "dispatch": .object(["type": .string("send"), "output": .null, "notice": .null, "message": .string("Continue working towards the goal."), "display": .string("/goal resume")])])
            }
        }
        try await harness.openSocket()
        let (chat, runtimeID) = try await openChat(harness, storedID: "20261009_170400_act")
        let drawn = await waitUntil { chat.sessionControls.isVisible }
        XCTAssertTrue(drawn)

        let pausedOK = await chat.sessionControls.perform(.goalPause)
        XCTAssertTrue(pausedOK)
        XCTAssertEqual(chat.sessionControls.snapshot?.goal?.state, .paused)
        XCTAssertEqual(chat.sessionControls.line?.title, "◎ Goal paused")
        let sent = await harness.backend.calls(to: "session.control").last
        XCTAssertEqual(sent?.sessionID, runtimeID)
        XCTAssertEqual(sent?.params["action"]?.stringValue, "goal.pause")
        XCTAssertNil(sent?.params["args"])

        let resumed = await chat.sessionControls.perform(.goalResume)
        XCTAssertTrue(resumed)
        let submitted = await waitUntil { await harness.backend.callCount("prompt.submit") == 1 }
        XCTAssertTrue(submitted, "the send dispatch never became a prompt.submit")
        let prompt = await harness.backend.calls(to: "prompt.submit").first
        XCTAssertEqual(prompt?.text, "Continue working towards the goal.", "the backend's kickoff text is what runs")
        XCTAssertEqual(chat.entries.last(where: { $0.kind == .user })?.text, "/goal resume", "the bubble shows the display text, as a slash command's does")

        await harness.tearDown()
    }

    /// A refused action is explained in words and leaves the snapshot alone.
    @MainActor
    func testARefusedActionIsExplained() async throws {
        let harness = await AppHarness.make()
        await harness.backend.stub("session.control.read") { _ in .object(["control": Self.goalSnapshot]) }
        await harness.backend.stub("process.list") { _ in .object(["processes": .array([])]) }
        await harness.backend.failRPC("session.control", code: 4004, message: "goal is not paused")
        try await harness.openSocket()
        let (chat, _) = try await openChat(harness, storedID: "20261009_170500_refused")
        _ = await waitUntil { chat.sessionControls.isVisible }

        let ok = await chat.sessionControls.perform(.goalResume)
        XCTAssertFalse(ok)
        XCTAssertEqual(chat.sessionControls.lastError, "Could not resume: goal is not paused")
        XCTAssertEqual(chat.sessionControls.support, .supported, "a refused action is not a missing method")
        XCTAssertTrue(chat.sessionControls.isVisible)
        chat.sessionControls.clearError()
        XCTAssertNil(chat.sessionControls.lastError)

        await harness.tearDown()
    }

    /// Stop asks `process.kill` for the row's id and re-reads the list.
    @MainActor
    func testStopKillsTheNamedProcessAndRereads() async throws {
        let harness = await AppHarness.make()
        await harness.backend.stub("session.control.read") { _ in .object(["control": Self.emptySnapshot]) }
        await harness.backend.stub("process.list") { _ in .object(["processes": .array([Self.runningProcess])]) }
        await harness.backend.stub("process.kill") { _ in .object(["status": .string("killed"), "session_id": .string("proc_7f3a"), "command": .string("npm run dev")]) }
        try await harness.openSocket()
        let (chat, runtimeID) = try await openChat(harness, storedID: "20261009_170600_kill")
        _ = await waitUntil { chat.backgroundProcesses.isVisible }

        await harness.backend.stub("process.list") { _ in .object(["processes": .array([])]) }
        let listsBefore = await harness.backend.callCount("process.list")
        let outcome = await chat.backgroundProcesses.stop("proc_7f3a")
        XCTAssertEqual(outcome?.wasKilled, true)
        let kill = await harness.backend.calls(to: "process.kill").last
        XCTAssertEqual(kill?.sessionID, runtimeID)
        XCTAssertEqual(kill?.params["process_id"]?.stringValue, "proc_7f3a")
        XCTAssertEqual(chat.backgroundProcesses.lastOutcome, "Stopped.")
        XCTAssertFalse(chat.backgroundProcesses.isVisible, "the re-read after the kill found nothing running")
        let listsAfter = await harness.backend.callCount("process.list")
        XCTAssertEqual(listsAfter, listsBefore + 1, "a stop re-reads the list exactly once")

        await harness.tearDown()
    }

    // MARK: Words

    func testTheWordsFollowDesktopsRules() {
        XCTAssertEqual(SessionControlFormat.interval(seconds: 45), "every 45s")
        XCTAssertEqual(SessionControlFormat.interval(seconds: 1800), "every 30m")
        XCTAssertEqual(SessionControlFormat.interval(seconds: 7200), "every 2h")
        let now = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertEqual(SessionControlFormat.approximate(until: now.addingTimeInterval(40), now: now), "~40s")
        XCTAssertEqual(SessionControlFormat.approximate(until: now.addingTimeInterval(290), now: now), "~5m")
        XCTAssertEqual(SessionControlFormat.approximate(until: now.addingTimeInterval(3 * 3600), now: now), "~3h")
        XCTAssertEqual(SessionControlFormat.approximate(until: now.addingTimeInterval(-5), now: now), "~0s")
        XCTAssertEqual(SessionControlFormat.countdown(to: now.addingTimeInterval(299), now: now), "00:04:59")
        XCTAssertEqual(SessionControlFormat.countdown(to: now.addingTimeInterval(90_000), now: now), "1d 01:00:00")
        XCTAssertEqual(SessionControlFormat.goalTurns(GoalSnapshot(title: "t", status: "done", turnsUsed: 7)), "7 turns")
        XCTAssertNil(SessionControlFormat.goalTurns(GoalSnapshot(title: "t", status: "active")))
        XCTAssertEqual(SessionControlFormat.loopRuns(LoopSnapshot(prompt: "p", status: "active", ticksFired: 1)), "1 run")
        XCTAssertEqual(SessionControlFormat.loopRuns(LoopSnapshot(prompt: "p", status: "active", times: 5, ticksFired: 2)), "run 2/5")
    }

    /// `next_due_at` is an unbounded float on the wire; a value far outside what `Int` holds must render, not trap (the BUG-112 class).
    func testAnAbsurdDueDateRendersInsteadOfTrapping() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let absurd = Date(timeIntervalSince1970: 1e300)
        XCTAssertFalse(SessionControlFormat.approximate(until: absurd, now: now).isEmpty)
        XCTAssertFalse(SessionControlFormat.countdown(to: absurd, now: now).isEmpty)
        XCTAssertEqual(SessionControlFormat.approximate(until: Date(timeIntervalSince1970: -1e300), now: now), "~0s")
        XCTAssertEqual(SessionControlFormat.countdown(to: Date(timeIntervalSince1970: -1e300), now: now), "00:00:00")
        XCTAssertFalse(SessionControlFormat.approximate(until: Date.distantFuture, now: now).isEmpty)
        XCTAssertFalse(SessionControlFormat.countdown(to: Date.distantFuture, now: now).isEmpty)
    }

    // MARK: Edge cases

    /// Stopping the last process (or clearing the last goal) takes the line away; the sheet reporting it must not go with it, so its host stays while the sheet is open.
    @MainActor
    func testAGroupStaysMountedWhileItsSheetIsOpen() {
        let processes = BackgroundProcessesModel()
        processes.seed([BackgroundProcess(json: Self.runningProcess)!])
        let controls = SessionControlsModel()
        controls.seed(SessionControlSnapshot(json: Self.goalSnapshot))
        let empty = SessionActivity()

        XCTAssertEqual(SessionActivityStrip.groups(activity: empty, controls: controls, processes: processes, compactHeight: false), [.controls, .processes])

        processes.isSheetPresented = true
        processes.seed([])
        XCTAssertFalse(processes.isVisible, "nothing runs, so no line")
        XCTAssertTrue(processes.isSheetPresented, "the sheet's own state survives the list emptying")
        XCTAssertEqual(SessionActivityStrip.groups(activity: empty, controls: controls, processes: processes, compactHeight: false), [.controls, .processes], "the processes host stays for the open sheet")

        controls.isSheetPresented = true
        controls.seed(SessionControlSnapshot(json: Self.emptySnapshot))
        XCTAssertEqual(SessionActivityStrip.groups(activity: empty, controls: controls, processes: processes, compactHeight: false), [.controls, .processes])

        processes.isSheetPresented = false
        controls.isSheetPresented = false
        XCTAssertEqual(SessionActivityStrip.groups(activity: empty, controls: controls, processes: processes, compactHeight: false), [], "closed sheets and empty lines leave nothing")
        XCTAssertEqual(measure(SessionActivityStrip(activity: empty, controls: controls, processes: processes)), 0, accuracy: 0.5)
    }

    /// Four groups are four lines in portrait; a compact height shows the first two, so the keyboard cannot push the composer under the strip.
    @MainActor
    func testACompactHeightShowsAtMostTwoGroups() {
        var activity = SessionActivity()
        activity.todos = TodoList(items: [TodoItem(id: "1", content: "Wire it", status: .inProgress)])
        activity.subagents = [SubagentRow(id: "a", wireSubagentID: "a", hasStarted: true, goal: "Audit", currentTool: "", toolCount: 0, taskIndex: 0, taskCount: 1)]
        let controls = SessionControlsModel()
        controls.seed(SessionControlSnapshot(json: Self.goalSnapshot))
        let processes = BackgroundProcessesModel()
        processes.seed([BackgroundProcess(json: Self.runningProcess)!])

        XCTAssertEqual(SessionActivityStrip.groups(activity: activity, controls: controls, processes: processes, compactHeight: false), [.todos, .agents, .controls, .processes])
        XCTAssertEqual(SessionActivityStrip.groups(activity: activity, controls: controls, processes: processes, compactHeight: true), [.todos, .agents])
        XCTAssertEqual(measure(SessionActivityStrip(activity: activity, controls: controls, processes: processes)), 4 * Hit.min, accuracy: 1)
        XCTAssertEqual(measure(SessionActivityStrip(activity: activity, controls: controls, processes: processes).environment(\.verticalSizeClass, .compact)), 2 * Hit.min, accuracy: 1)
    }

    /// A resume whose kickoff cannot go out (a send is still in flight) says so instead of showing the goal resumed with the agent idle.
    @MainActor
    func testAResumeWhoseKickoffCannotBeSentSaysSo() async throws {
        let harness = await AppHarness.make()
        await harness.backend.stub("session.control.read") { _ in .object(["control": Self.goalSnapshot]) }
        await harness.backend.stub("process.list") { _ in .object(["processes": .array([])]) }
        await harness.backend.stub("session.control") { _ in
            .object(["control": Self.goalSnapshot, "dispatch": .object(["type": .string("send"), "output": .null, "notice": .null, "message": .string("Continue working towards the goal."), "display": .string("/goal resume")])])
        }
        try await harness.openSocket()
        let (chat, _) = try await openChat(harness, storedID: "20261009_190000_inflight")
        _ = await waitUntil { chat.sessionControls.isVisible }

        // A send whose ack never comes back holds `isSending`.
        await harness.backend.gate("prompt.submit")
        chat.draft = "hello"
        chat.sendTapped()
        let inFlight = await waitUntil { await harness.backend.callCount("prompt.submit") == 1 }
        XCTAssertTrue(inFlight)
        XCTAssertTrue(chat.isSending)

        let resumed = await chat.sessionControls.perform(.goalResume)
        XCTAssertTrue(resumed, "the backend did resume the goal")
        let error = try XCTUnwrap(chat.sessionControls.lastError, "the refused kickoff must be reported in the sheet")
        XCTAssertTrue(error.lowercased().contains("could not be sent"), error)
        let submits = await harness.backend.callCount("prompt.submit")
        XCTAssertEqual(submits, 1, "nothing else may have gone out")

        await harness.backend.releaseParked()
        await harness.tearDown()
    }

    /// Desktop reads once when the session opens and once at the end of each turn; the ack of a send is not a third edge.
    @MainActor
    func testASendCostsOneReReadAtTheEndOfItsTurnNotTwo() async throws {
        let harness = await AppHarness.make()
        await harness.backend.stub("session.control.read") { _ in .object(["control": Self.goalSnapshot]) }
        await harness.backend.stub("process.list") { _ in .object(["processes": .array([])]) }
        try await harness.openSocket()
        let (chat, runtimeID) = try await openChat(harness, storedID: "20261009_190100_reads")
        _ = await waitUntil { chat.sessionControls.isVisible }
        _ = await waitUntil(timeout: 0.3) { false }
        let afterOpen = await harness.backend.callCount("session.control.read")
        XCTAssertEqual(afterOpen, 1)

        chat.draft = "hello"
        chat.sendTapped()
        let acked = await waitUntil { !chat.isSending }
        XCTAssertTrue(acked)
        await harness.backend.emit("message.start", sessionID: runtimeID)
        let busy = await waitUntil { chat.live.isBusy }
        XCTAssertTrue(busy)
        await harness.backend.emit("message.complete", sessionID: runtimeID, payload: .object(["text": .string("Done."), "status": .string("complete")]))
        let settled = await waitUntil { !chat.live.isBusy }
        XCTAssertTrue(settled)
        _ = await waitUntil(timeout: 0.5) { false }

        let controlReads = await harness.backend.callCount("session.control.read")
        let processReads = await harness.backend.callCount("process.list")
        XCTAssertEqual(controlReads, 2, "open plus end of turn; the send's ack must not add a third read")
        XCTAssertEqual(processReads, 2)

        await harness.tearDown()
    }
}
