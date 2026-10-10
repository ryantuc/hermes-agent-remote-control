import XCTest

@testable import HermesServeKit

/// `subagent.list`, `subagent.tail` and `subagent.steer` against the declared contracts (`tui_gateway/contracts/profiles_vault_complete_foreign_subagents.py:600-665`, `tui_gateway/contracts/billing_delegation_pets.py:400-419`), and the merge of a roster read with what live frames already drew.
final class SubagentRosterTests: XCTestCase {
    private let session = "a1b2c3d4"

    // MARK: Wire shapes

    private static let listReply: JSONValue = .object([
        "subagents": .array([
            .object([
                "subagent_id": .string("sa-1"), "parent_id": .string("root"), "depth": .number(1),
                "goal": .string("Audit the migration"), "delegation_id": .string("d-1"), "model": .string("m"),
                "started_at": .number(1_790_000_000.5), "status": .string("running"), "tool_count": .number(4),
                "last_tool": .string("read_file"), "accepting_steer": .bool(true),
            ]),
            .object(["subagent_id": .string("sa-2"), "goal": .string("Queued work"), "status": .string("queued")]),
            .object(["goal": .string("No id, so not a row")]),
        ]),
        "delegations": .array([
            .object([
                "delegation_id": .string("d-9"), "task_index": .number(2), "status": .string("timeout"),
                "goal": .string("Scan the logs"), "error": .string("Timed out after 600s"),
                "dispatched_at": .number(1_790_000_000), "completed_at": .number(1_790_000_600),
            ]),
            .object(["task_index": .number(0), "status": .string("failed")]),
        ]),
    ])

    func testAListReplyDecodesItsChildrenAndItsFailedTasks() throws {
        let roster = try XCTUnwrap(SubagentRoster(json: Self.listReply))
        XCTAssertEqual(roster.subagents.map(\.subagentID), ["sa-1", "sa-2"], "a child without the required id is dropped")
        let first = try XCTUnwrap(roster.subagents.first)
        XCTAssertEqual(first.parentID, "root")
        XCTAssertEqual(first.depth, 1)
        XCTAssertEqual(first.delegationID, "d-1")
        XCTAssertEqual(first.startedAt, Date(timeIntervalSince1970: 1_790_000_000.5))
        XCTAssertEqual(first.toolCount, 4)
        XCTAssertEqual(first.lastTool, "read_file")
        XCTAssertEqual(first.acceptingSteer, true)
        XCTAssertTrue(first.hasStarted)
        XCTAssertNil(first.terminalState)
        XCTAssertFalse(roster.subagents[1].hasStarted, "queued is registered but not started")

        XCTAssertEqual(roster.delegations.count, 1, "a failed task without its delegation id is dropped")
        let task = try XCTUnwrap(roster.delegations.first)
        XCTAssertEqual(task.rowID, "delegation:d-9:2")
        XCTAssertEqual(task.status, "timeout")
        XCTAssertEqual(task.error, "Timed out after 600s")
        XCTAssertEqual(task.completedAt, Date(timeIntervalSince1970: 1_790_000_600))
    }

    func testAReplyWithoutASubagentsListIsNoAnswer() {
        XCTAssertNil(SubagentRoster(json: .object([:])), "an older backend's empty object must never read as 'nothing is running'")
        XCTAssertNil(SubagentRoster(json: .null))
        XCTAssertEqual(SubagentRoster(json: .object(["subagents": .array([])])), SubagentRoster(), "an empty list is an answer")
    }

    func testTerminalStatusesFollowTheBackendsOwnSet() {
        func state(_ status: String) -> SubagentRow.State? {
            SubagentSnapshot(json: .object(["subagent_id": .string("x"), "status": .string(status)]))?.terminalState
        }
        XCTAssertEqual(state("completed"), .completed)
        XCTAssertEqual(state("interrupted"), .interrupted)
        XCTAssertEqual(state("failed"), .failed)
        XCTAssertEqual(state("error"), .failed)
        XCTAssertEqual(state("timeout"), .failed)
        XCTAssertNil(state("running"))
        XCTAssertNil(state("queued"))
    }

    func testListTailAndSteerSendExactlyTheDeclaredParams() async throws {
        let (client, transport) = try await ScriptedGateway.connected(replies: [
            "subagent.list": [Self.listReply],
            "subagent.tail": [.object(["subagent_id": .string("sa-1"), "available": .bool(true), "text": .string("line one\nline two"), "truncated": .bool(true)])],
            "subagent.steer": [.object(["status": .string("queued"), "subagent_id": .string("sa-1"), "text": .string("skip the tests")])],
        ])
        let api = SubagentsAPI(client: client)

        let roster = try await api.list(sessionID: session)
        XCTAssertEqual(roster?.subagents.count, 2)
        let listParams = await transport.sentParams("subagent.list")
        XCTAssertEqual(listParams, .object(["session_id": .string(session)]))

        let tail = try await api.tail(sessionID: session, subagentID: "sa-1")
        XCTAssertEqual(tail, SubagentTail(json: .object(["available": .bool(true), "text": .string("line one\nline two"), "truncated": .bool(true)]), requested: "sa-1"))
        XCTAssertTrue(tail.available)
        XCTAssertTrue(tail.truncated)
        let tailParams = await transport.sentParams("subagent.tail")
        XCTAssertEqual(tailParams, .object(["session_id": .string(session), "subagent_id": .string("sa-1")]))

        let receipt = try await api.steer(sessionID: session, subagentID: "sa-1", text: "  skip the tests \n")
        XCTAssertTrue(receipt.isQueued)
        let steerParams = await transport.sentParams("subagent.steer")
        XCTAssertEqual(steerParams, .object(["session_id": .string(session), "subagent_id": .string("sa-1"), "text": .string("skip the tests")]),
                       "trimmed, because the gateway refuses blank text with 4002")
        await client.disconnect()
    }

    func testARejectedSteerAndAMissingMethodAreToldApart() async throws {
        let (client, _) = try await ScriptedGateway.connected(replies: [
            "subagent.steer": [.object(["status": .string("rejected"), "subagent_id": .string("sa-1"), "text": .string("hi")])],
            "subagent.list": [ScriptedGateway.rpcError(code: -32601, message: "unknown method: subagent.list")],
            "subagent.tail": [ScriptedGateway.rpcError(code: 4001, message: "session not found or not owned by this transport")],
        ])
        let api = SubagentsAPI(client: client)
        let receipt = try await api.steer(sessionID: session, subagentID: "sa-1", text: "hi")
        XCTAssertFalse(receipt.isQueued)
        do {
            _ = try await api.list(sessionID: session)
            XCTFail("a missing method must throw")
        } catch {
            XCTAssertTrue(SubagentsAPI.isUnsupported(error))
        }
        do {
            _ = try await api.tail(sessionID: session, subagentID: "sa-1")
            XCTFail("an ownership refusal must throw")
        } catch {
            XCTAssertFalse(SubagentsAPI.isUnsupported(error), "an ownership refusal is not a missing feature")
        }
        await client.disconnect()
    }

    func testATailLongerThanTheBackendsWindowIsClampedToItsEnd() {
        let long = String(repeating: "a", count: SubagentTail.byteLimit) + "THE END"
        let tail = SubagentTail(json: .object(["available": .bool(true), "text": .string(long)]), requested: "sa-1")
        XCTAssertEqual(tail.text.utf8.count, SubagentTail.byteLimit)
        XCTAssertTrue(tail.text.hasSuffix("THE END"))
        XCTAssertEqual(tail.subagentID, "sa-1")
    }

    // MARK: The merge

    private func event(_ phase: SubagentEvent.Phase, id: String, extra: [String: JSONValue] = [:]) -> GatewayEvent {
        var payload: [String: JSONValue] = ["goal": .string("Goal \(id)"), "task_count": .number(2), "task_index": .number(0), "subagent_id": .string(id)]
        for (key, value) in extra { payload[key] = value }
        return GatewayEvent(type: phase.rawValue, sessionID: session, payload: .object(payload),
                            params: .object(["type": .string(phase.rawValue), "session_id": .string(session), "payload": .object(payload)]))
    }

    private func snapshot(_ id: String, status: String = "running", extra: [String: JSONValue] = [:]) -> SubagentSnapshot {
        var row: [String: JSONValue] = ["subagent_id": .string(id), "goal": .string("Goal \(id)"), "status": .string(status)]
        for (key, value) in extra { row[key] = value }
        return SubagentSnapshot(json: .object(row))!
    }

    private func apply(_ engine: TurnEngine, _ event: GatewayEvent) {
        engine.apply(event)
        engine.flush()
    }

    private func engineWithLiveRows(_ events: [GatewayEvent]) -> TurnEngine {
        let engine = TurnEngine()
        apply(engine, GatewayEvent(type: "message.start", sessionID: session, payload: .null,
                                  params: .object(["type": .string("message.start"), "session_id": .string(session)])))
        for event in events { engine.apply(event) }
        engine.flush()
        return engine
    }

    func testARosterMergesIntoLiveRowsWithoutDuplicatesAndAddsWhatWasMissed() {
        let engine = engineWithLiveRows([event(.start, id: "sa-1"), event(.tool, id: "sa-1", extra: ["tool_name": .string("grep"), "tool_count": .number(2)])])
        let observedAt = Date()
        let roster = SubagentRoster(subagents: [snapshot("sa-1", extra: ["tool_count": .number(1), "model": .string("m")]), snapshot("sa-3")])
        XCTAssertTrue(engine.reconcileSubagents(sessionID: session, roster: roster, observedAt: observedAt))

        let rows = engine.state(for: session).activity.subagents
        XCTAssertEqual(rows.map(\.id), ["sa-1", "sa-3"], "the live row is filled, not duplicated")
        XCTAssertEqual(rows[0].toolCount, 2, "a stale roster count never lowers the live one")
        XCTAssertEqual(rows[0].currentTool, "grep", "the live tool survives the read")
        XCTAssertEqual(rows[0].model, "m", "a field the frames never carried is filled in")
        XCTAssertEqual(rows[1].sessionID, session)
        XCTAssertEqual(rows[1].wireSubagentID, "sa-3")
        XCTAssertFalse(rows[0].originUnknown, "a frame-fed row keeps the origin its turn said")
        XCTAssertTrue(rows[1].originUnknown, "a roster says nothing about who started an agent")

        // Applying the same answer again changes nothing.
        XCTAssertFalse(engine.reconcileSubagents(sessionID: session, roster: roster, observedAt: observedAt))
        // A live frame for a hydrated row lands on it.
        apply(engine, event(.complete, id: "sa-3", extra: ["status": .string("completed")]))
        XCTAssertEqual(engine.state(for: session).activity.subagents.map(\.state), [.running, .completed])
    }

    /// BUG-011: an agent whose `subagent.complete` never reached the phone used to read "running" until the app was killed.
    func testAStartedAgentTheRosterNoLongerListsSettlesAndTheStripEmptiesAtTheNextTurn() {
        let engine = engineWithLiveRows([event(.start, id: "sa-1"), event(.start, id: "sa-2"), event(.spawnRequested, id: "sa-queued")])
        let observedAt = Date().addingTimeInterval(1)
        XCTAssertTrue(engine.reconcileSubagents(sessionID: session, roster: SubagentRoster(subagents: [snapshot("sa-2")]), observedAt: observedAt))
        let rows = engine.state(for: session).activity.subagents
        XCTAssertEqual(rows.map(\.state), [.ended, .running, .running],
                       "a started agent the backend no longer has ended; a queued one may not be registered yet")
        XCTAssertEqual(engine.state(for: session).activity.runningSubagents.map(\.id), ["sa-2", "sa-queued"])

        apply(engine, event(.complete, id: "sa-2", extra: ["status": .string("completed")]))
        apply(engine, GatewayEvent(type: "message.start", sessionID: session, payload: .null,
                                  params: .object(["type": .string("message.start"), "session_id": .string(session)])))
        XCTAssertEqual(engine.state(for: session).activity.subagents.map(\.id), ["sa-queued"], "finished rows retire at the next turn")
    }

    func testARowAFrameTouchedAfterTheReadWentOutIsNotSettledByIt() {
        let observedAt = Date().addingTimeInterval(-5)
        let engine = engineWithLiveRows([event(.start, id: "sa-new")])
        XCTAssertFalse(engine.reconcileSubagents(sessionID: session, roster: SubagentRoster(), observedAt: observedAt),
                       "the read predates the frame, so its silence about the agent proves nothing")
        XCTAssertEqual(engine.state(for: session).activity.subagents.first?.state, .running)
    }

    func testALateCompleteNamesTheRealOutcomeOfAnEndedRow() {
        let engine = engineWithLiveRows([event(.start, id: "sa-1")])
        engine.reconcileSubagents(sessionID: session, roster: SubagentRoster(), observedAt: Date().addingTimeInterval(1))
        XCTAssertEqual(engine.state(for: session).activity.subagents.first?.state, .ended)
        apply(engine, event(.complete, id: "sa-1", extra: ["status": .string("failed"), "summary": .string("boom")]))
        XCTAssertEqual(engine.state(for: session).activity.subagents.first?.state, .failed)
        apply(engine, event(.progress, id: "sa-1", extra: ["text": .string("late")]))
        XCTAssertEqual(engine.state(for: session).activity.subagents.first?.state, .failed, "a settled row still freezes")
    }

    func testAFailedTaskIsAddedOnceAndNeverDuplicatesItsLiveRow() {
        let engine = engineWithLiveRows([
            event(.start, id: "sa-1", extra: ["delegation_id": .string("d-9"), "task_index": .number(1)]),
            event(.complete, id: "sa-1", extra: ["delegation_id": .string("d-9"), "task_index": .number(1), "status": .string("failed")]),
        ])
        let failed = FailedDelegation(json: .object(["delegation_id": .string("d-9"), "task_index": .number(1), "status": .string("failed"), "goal": .string("x")]))!
        let other = FailedDelegation(json: .object(["delegation_id": .string("d-7"), "task_index": .number(0), "status": .string("interrupted"),
                                                    "goal": .string("Earlier"), "error": .string("Stopped"),
                                                    "dispatched_at": .number(1_790_000_000), "completed_at": .number(1_790_000_030)]))!
        let roster = SubagentRoster(delegations: [failed, other])
        XCTAssertTrue(engine.reconcileSubagents(sessionID: session, roster: roster, observedAt: Date()))
        var rows = engine.state(for: session).activity.subagents
        XCTAssertEqual(rows.map(\.id), ["sa-1", "delegation:d-7:0"], "the live failure already covers d-9 task 1")
        XCTAssertEqual(rows[1].state, .interrupted)
        XCTAssertEqual(rows[1].summary, "Stopped")
        XCTAssertEqual(rows[1].durationSeconds, 30)
        XCTAssertTrue(rows[1].wireSubagentID.isEmpty, "a stored failure is nothing Stop or steer can address")

        // The next turn retires both; the store still reports them for a day, and they must not come back.
        apply(engine, GatewayEvent(type: "message.start", sessionID: session, payload: .null,
                                  params: .object(["type": .string("message.start"), "session_id": .string(session)])))
        XCTAssertFalse(engine.reconcileSubagents(sessionID: session, roster: roster, observedAt: Date()))
        rows = engine.state(for: session).activity.subagents
        XCTAssertTrue(rows.isEmpty)
    }

    func testStopClearsTheStripAndARosterReadInFlightCannotRefillIt() {
        let engine = engineWithLiveRows([event(.start, id: "sa-1")])
        let observedAt = Date()
        engine.markInterrupted(sessionID: session)
        XCTAssertTrue(engine.state(for: session).activity.subagents.isEmpty)
        XCTAssertFalse(engine.reconcileSubagents(sessionID: session, roster: SubagentRoster(subagents: [snapshot("sa-1")]), observedAt: observedAt))
        XCTAssertTrue(engine.state(for: session).activity.subagents.isEmpty)
    }

    func testAnUntrackedSessionIsNeverCreatedByARead() {
        let engine = TurnEngine()
        XCTAssertFalse(engine.reconcileSubagents(sessionID: "gone", roster: SubagentRoster(subagents: [snapshot("sa-1")]), observedAt: Date()))
        XCTAssertFalse(engine.trackedSessionIDs.contains("gone"))
    }
}
