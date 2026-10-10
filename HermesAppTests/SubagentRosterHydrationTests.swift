import HermesServeKit
import XCTest

@testable import HermesMobile

/// The strip above the composer used to be fed by live `subagent.*` frames alone, so reopening a chat or relaunching the app while agents were working lost the roster, and a child that failed while the phone was away was never shown. A chat that opens or reattaches now asks `subagent.list` (`tui_gateway/methods_subagents.py:53-63`) and merges the answer with what live frames draw.
final class SubagentRosterHydrationTests: XCTestCase {

    private static func snapshot(_ id: String, goal: String, status: String, extra: [String: JSONValue] = [:]) -> JSONValue {
        var row: [String: JSONValue] = [
            "subagent_id": .string(id), "parent_id": .string("root-agent"), "depth": .number(1), "goal": .string(goal),
            "delegation_id": .null, "model": .string("deepseek-v4-flash"), "started_at": .number(Date().timeIntervalSince1970 - 30),
            "status": .string(status), "tool_count": .number(3), "last_tool": .string("read_file"), "accepting_steer": .bool(true),
        ]
        for (key, value) in extra { row[key] = value }
        return .object(row)
    }

    private static let fanOut: JSONValue = .object([
        "subagents": .array([
            snapshot("sa-1", goal: "Audit the migration", status: "running"),
            snapshot("sa-2", goal: "Draft the release notes", status: "queued"),
        ]),
        "delegations": .array([.object([
            "delegation_id": .string("d-9"), "task_index": .number(1), "status": .string("failed"),
            "goal": .string("Scan the logs"), "error": .string("The model refused the request."),
            "dispatched_at": .number(Date().timeIntervalSince1970 - 120), "completed_at": .number(Date().timeIntervalSince1970 - 60),
        ])]),
    ])

    @MainActor
    private func open(_ harness: AppHarness, storedID: String) async throws -> (ChatModel, String) {
        let chat = harness.chat(storedID: storedID)
        await chat.open()
        let bound = await waitUntil { chat.runtimeSessionID != nil }
        XCTAssertTrue(bound, "open() never bound a runtime id")
        return (chat, try XCTUnwrap(chat.runtimeSessionID))
    }

    /// The reported shape: leave a chat while its agents work, come back, and the strip has to be there again.
    @MainActor
    func testReopeningAChatMidFanOutRestoresItsAgentsAndTheFailedTask() async throws {
        let harness = await AppHarness.make()
        await harness.backend.stub("subagent.list") { _ in Self.fanOut }
        try await harness.openSocket()
        let storedID = "20261009_180000_fan"
        let (first, _) = try await open(harness, storedID: storedID)

        harness.app.releaseChats(keeping: [])
        let (reopened, runtimeID) = try await open(harness, storedID: storedID)
        XCTAssertFalse(reopened === first, "precondition: the reopen built a fresh chat")

        let hydrated = await waitUntil { reopened.live.activity.subagents.count == 3 }
        XCTAssertTrue(hydrated, "the reopened chat's strip is empty: \(reopened.live.activity.subagents.map(\.id))")

        let rows = reopened.live.activity.subagents
        XCTAssertEqual(rows.map(\.id), ["sa-1", "sa-2", "delegation:d-9:1"])
        XCTAssertEqual(rows.map(\.state), [.running, .running, .failed])
        XCTAssertEqual(rows.map(\.wireSubagentID), ["sa-1", "sa-2", ""], "only live children can be stopped or steered")
        XCTAssertEqual(rows.map(\.hasStarted), [true, false, true], "a queued child has not started")
        XCTAssertEqual(rows.first?.goal, "Audit the migration")
        XCTAssertEqual(rows.first?.toolCount, 3)
        XCTAssertEqual(rows.first?.currentTool, "", "a roster's last tool is history, not a tool running now")
        XCTAssertEqual(rows.last?.summary, "The model refused the request.")
        XCTAssertEqual(reopened.live.activity.runningSubagents.count, 2)

        let calls = await harness.backend.calls(to: "subagent.list")
        XCTAssertEqual(calls.last?.params, .object(["session_id": .string(runtimeID)]),
                       "exactly the declared params; anything else draws 4000")

        await harness.tearDown()
    }

    /// BUG-011: labels settle instead of sticking on "running", the fraction climbs, and the strip is empty at the next turn.
    @MainActor
    func testAnAgentWhoseCompleteNeverArrivedSettlesOnTheNextReadAndRetiresAtTheNextTurn() async throws {
        let harness = await AppHarness.make()
        await harness.backend.stub("subagent.list") { _ in .object(["subagents": .array([]), "delegations": .array([])]) }
        try await harness.openSocket()
        let (chat, runtimeID) = try await open(harness, storedID: "20261009_180100_lost")
        let hydratedOnce = await waitUntil { await harness.backend.callCount("subagent.list") == 1 }
        XCTAssertTrue(hydratedOnce, "opening the chat asks for the roster once")

        await harness.backend.emit("message.start", sessionID: runtimeID)
        await harness.backend.emit("subagent.start", sessionID: runtimeID, payload: .object([
            "subagent_id": .string("sa-1"), "goal": .string("Audit the migration"), "task_index": .number(0), "task_count": .number(1),
        ]))
        await harness.backend.emit("message.complete", sessionID: runtimeID, payload: .object(["text": .string("Started it."), "status": .string("complete")]))
        let running = await waitUntil { chat.live.activity.runningSubagents.map(\.id) == ["sa-1"] && !chat.live.isBusy }
        XCTAssertTrue(running, "precondition: one agent drawn as working after its turn ended")

        // Its `subagent.complete` never comes. The strip's next read finds it gone (looped only because the open's own read may still be in flight, and a second read joins it).
        let settled = await waitUntil {
            let supported = await chat.subagentRoster.refresh(app: harness.app, sessionID: runtimeID)
            return supported && chat.live.activity.subagents.first?.state == .ended
        }
        XCTAssertTrue(settled, "still drawn as: \(chat.live.activity.subagents.map(\.state))")
        XCTAssertEqual(chat.live.activity.subagents.map(\.state), [.ended])
        XCTAssertEqual(StripProgress.agents(chat.live.activity.subagents), "1/1")
        XCTAssertTrue(chat.live.activity.runningSubagents.isEmpty)
        XCTAssertFalse(chat.isTurnActive, "nothing is working, so the composer offers Send, not Stop")

        await harness.backend.emit("message.start", sessionID: runtimeID)
        let emptied = await waitUntil { chat.live.activity.subagents.isEmpty }
        XCTAssertTrue(emptied, "the next turn retires the finished agent")
        await harness.tearDown()
    }

    /// An older backend has no `subagent.list`: nothing breaks, nothing is said, and it is not asked again on this connection.
    @MainActor
    func testABackendWithoutTheRosterIsAskedOnceAndLeavesTheChatAlone() async throws {
        let harness = await AppHarness.make()
        await harness.backend.failRPC("subagent.list", code: -32601, message: "unknown method: subagent.list")
        try await harness.openSocket()
        let (chat, runtimeID) = try await open(harness, storedID: "20261009_180200_old")
        // The harness's REST port is closed, so the transcript load has already written its own refusal; only what the roster read writes is under test.
        chat.errorMessage = nil
        let asked = await waitUntil { await harness.backend.callCount("subagent.list") == 1 }
        XCTAssertTrue(asked)
        let gaveUp = await waitUntil { !(await chat.subagentRoster.refresh(app: harness.app, sessionID: runtimeID)) }
        XCTAssertTrue(gaveUp, "the roster read must report that this backend does not answer it")
        let calls = await harness.backend.callCount("subagent.list")
        XCTAssertEqual(calls, 1, "a missing method answers the same way every time on this connection")
        XCTAssertTrue(chat.live.activity.subagents.isEmpty)
        XCTAssertNil(chat.errorMessage)
        await harness.tearDown()
    }

    /// The agent's page reads its tail, sends it a message and stops it, each with exactly the declared params.
    @MainActor
    func testTheAgentPageReadsTheTailSteersAndStopsThroughTheDeclaredCalls() async throws {
        let harness = await AppHarness.make()
        await harness.backend.stub("subagent.list") { _ in Self.fanOut }
        await harness.backend.stub("subagent.tail") { _ in
            .object(["subagent_id": .string("sa-1"), "available": .bool(true), "text": .string("Reading migrations/0042.sql"), "truncated": .bool(false)])
        }
        await harness.backend.stub("subagent.steer") { call in
            .object(["status": .string("queued"), "subagent_id": .string("sa-1"), "text": call.params["text"] ?? .string("")])
        }
        await harness.backend.stub("subagent.interrupt") { _ in .object(["found": .bool(true), "subagent_id": .string("sa-1")]) }
        try await harness.openSocket()
        let (chat, runtimeID) = try await open(harness, storedID: "20261009_180300_ctl")
        let hydrated = await waitUntil { chat.live.activity.subagents.count == 3 }
        XCTAssertTrue(hydrated)
        let row = try XCTUnwrap(chat.live.activity.subagents.first)
        XCTAssertEqual(row.sessionID, runtimeID)

        let tail = await chat.subagentRoster.tail(app: harness.app, row: row)
        XCTAssertEqual(tail, .text("Reading migrations/0042.sql", truncated: false))
        let tailCall = await harness.backend.calls(to: "subagent.tail").last
        XCTAssertEqual(tailCall?.params, .object(["session_id": .string(runtimeID), "subagent_id": .string("sa-1")]))

        XCTAssertTrue(chat.subagentRoster.canSteer(app: harness.app, row: row))
        let steered = await chat.subagentRoster.steer(app: harness.app, row: row, text: " Skip the tests. ")
        XCTAssertEqual(steered, .done("Sent. The agent reads it before its next step."))
        let steerCall = await harness.backend.calls(to: "subagent.steer").last
        XCTAssertEqual(steerCall?.params, .object(["session_id": .string(runtimeID), "subagent_id": .string("sa-1"), "text": .string("Skip the tests.")]))

        let stopped = await chat.subagentRoster.stop(app: harness.app, row: row)
        XCTAssertEqual(stopped, .done("Asked the agent to stop."))
        let stopCall = await harness.backend.calls(to: "subagent.interrupt").last
        XCTAssertEqual(stopCall?.params, .object(["subagent_id": .string("sa-1"), "session_id": .string(runtimeID)]))

        // A stored failure has no live child behind it, so it offers neither control.
        let failed = try XCTUnwrap(chat.live.activity.subagents.last)
        XCTAssertFalse(chat.subagentRoster.canSteer(app: harness.app, row: failed))
        let refused = await chat.subagentRoster.stop(app: harness.app, row: failed)
        guard case .refused = refused else { return XCTFail("a finished task cannot be stopped") }
        await harness.tearDown()
    }

    /// `found: false` is either "already ended" or "not this connection's to stop"; an agent the roster still lists is never drawn as finished.
    @MainActor
    func testAnAgentTheBackendStillListsIsNotClaimedFinishedWhenStopFindsNothing() async throws {
        let harness = await AppHarness.make()
        await harness.backend.stub("subagent.list") { _ in Self.fanOut }
        await harness.backend.stub("subagent.interrupt") { _ in .object(["found": .bool(false), "subagent_id": .string("sa-1")]) }
        try await harness.openSocket()
        let (chat, _) = try await open(harness, storedID: "20261009_180350_owned")
        let hydrated = await waitUntil { chat.live.activity.subagents.count == 3 }
        XCTAssertTrue(hydrated)
        let row = try XCTUnwrap(chat.live.activity.subagents.first)
        let outcome = await chat.subagentRoster.stop(app: harness.app, row: row)
        guard case .refused(let message) = outcome else { return XCTFail("claimed success: \(outcome)") }
        XCTAssertTrue(message.contains("would not stop it from this phone"), message)
        XCTAssertEqual(chat.live.activity.subagents.first?.state, .running, "still working on the backend, so still drawn as working")
        await harness.tearDown()
    }

    /// End to end: on a backend that counts declines, a preview request never becomes a "Continue in Desktop" card on the phone.
    @MainActor
    func testAPreviewRequestIsDeclinedWithoutACardWhenTheBackendCountsDeclines() async throws {
        let harness = await AppHarness.make(handlesServerRequests: true)
        await harness.backend.stub("client.capabilities") { _ in
            .object(["server_requests": .array([.string("clarify"), .string("preview.read")]), "declines_not_shown": .bool(true)])
        }
        try await harness.openSocket()
        let (chat, runtimeID) = try await open(harness, storedID: "20261009_180400_preview")
        await harness.backend.emitServerRequest(id: "srq-preview", method: "preview.read", sessionID: runtimeID)
        let declined = await waitUntil { await harness.backend.receivedResponses.contains { $0.id == .string("srq-preview") } }
        XCTAssertTrue(declined)
        let reply = await harness.backend.receivedResponses.first { $0.id == .string("srq-preview") }
        XCTAssertEqual(reply?.error?.code, 4404)
        XCTAssertNil(chat.pendingSecret, "no 'Continue in Desktop' card: the agent was told at once and carries on")
        XCTAssertFalse(chat.hasBlockingPrompt)
        await harness.tearDown()
    }
}
