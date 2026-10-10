import XCTest

@testable import HermesServeKit

/// `session.control.read` and `session.control` against the declared contracts (`tui_gateway/contracts/config_free_tier_control.py:591-651`): what goes on the wire, and what a real snapshot decodes to. An undeclared param answers 4000 before any handler runs (`tui_gateway/rpc_dispatch.py:27-31`), so the param sets are pinned exactly.
final class SessionControlAPITests: XCTestCase {
    private let session = "rt-a1b2c3"

    /// `_snapshot_control` output (`methods_session_control.py:138-159`) with every kind present: a goal behind an `until` wait barrier, a loop deferred by that goal, a paused heartbeat that never fired.
    static let fullSnapshot: JSONValue = .object([
        "goal": .object([
            "title": .string("Ship the release notes"),
            "status": .string("active"),
            "turns_used": .number(3),
            "max_turns": .number(20),
            "contract": .object([
                "outcome": .string("Notes approved and tag pushed"),
                "verification": .string(""),
                "constraints": .string(""),
                "boundaries": .string(""),
                "stop_when": .string("Tag is on origin"),
            ]),
            "subgoals": .array([.string("Changelog reviewed"), .string("Tag pushed")]),
            "gates": .array([.object([
                "command": .string("npm test"),
                "timeout_seconds": .number(600),
                "max_retries": .number(2),
                "attempts": .number(1),
                "last_exit_code": .number(0),
            ])]),
            "created_at": .number(1_759_900_000),
            "updated_at": .number(1_759_900_300.5),
            "paused_reason": .null,
            "last_verdict": .string("continue"),
            "last_reason": .string("Tests pass; notes drafted"),
            "wait_barrier": .object([
                "type": .string("until"),
                "until_at": .number(1_759_903_600),
                "reason": .string("CI window"),
            ]),
        ]),
        "loop": .object([
            "prompt": .string("Check the deploy status"),
            "status": .string("active"),
            "mode": .string("interval"),
            "interval_seconds": .number(1800),
            "current_delay": .number(1800),
            "times": .number(5),
            "until": .string(""),
            "max_ticks": .number(0),
            "ticks_fired": .number(2),
            "created_at": .number(1_759_896_000),
            "last_fired_at": .number(1_759_899_600),
            "next_due_at": .number(1_759_901_400),
            "awaiting_response": .bool(false),
            "deferred_by_goal": .bool(true),
            "paused_reason": .null,
            "last_stop_reason": .null,
        ]),
        "heartbeat": .object([
            "prompt": .string("Anything new in the inbox?"),
            "status": .string("paused"),
            "interval_seconds": .number(3600),
            "created_at": .number(1_759_890_000),
            "last_fired_at": .number(0),
            "fire_count": .number(4),
        ]),
        "revision": .string("a3f9c2"),
        "updated_at": .number(1_759_900_300.5),
    ])

    /// A session with no automation at all: three nulls and the empty revision (`methods_session_control.py:164-165`).
    static let emptySnapshot: JSONValue = .object([
        "goal": .null,
        "loop": .null,
        "heartbeat": .null,
        "revision": .string(""),
        "updated_at": .number(0),
    ])

    // MARK: Decoding

    func testAFullSnapshotDecodesEveryKind() {
        let snapshot = SessionControlSnapshot(json: Self.fullSnapshot)

        XCTAssertFalse(snapshot.isEmpty)
        XCTAssertEqual(snapshot.revision, "a3f9c2")
        XCTAssertEqual(snapshot.updatedAt?.timeIntervalSince1970 ?? 0, 1_759_900_300.5, accuracy: 0.001)

        let goal = snapshot.goal!
        XCTAssertEqual(goal.title, "Ship the release notes")
        XCTAssertEqual(goal.turnsUsed, 3)
        XCTAssertEqual(goal.maxTurns, 20)
        XCTAssertEqual(goal.subgoals, ["Changelog reviewed", "Tag pushed"])
        XCTAssertEqual(goal.gates.count, 1)
        XCTAssertTrue(goal.gates[0].isPassing)
        XCTAssertEqual(goal.contract.outcome, "Notes approved and tag pushed")
        XCTAssertEqual(goal.contract.stopWhen, "Tag is on origin")
        XCTAssertFalse(goal.contract.isEmpty)
        XCTAssertNil(goal.pausedReason, "a JSON null is nil, not an empty string")
        XCTAssertEqual(goal.lastReason, "Tests pass; notes drafted")
        XCTAssertEqual(goal.state, .waiting, "a wait barrier wins over an active status, as Desktop draws it")
        XCTAssertFalse(goal.isBlocked)
        guard case .until(let at, let reason) = goal.waitBarrier else { return XCTFail("the until barrier was not decoded") }
        XCTAssertEqual(at.timeIntervalSince1970, 1_759_903_600, accuracy: 0.001)
        XCTAssertEqual(reason, "CI window")

        let loop = snapshot.loop!
        XCTAssertEqual(loop.prompt, "Check the deploy status")
        XCTAssertEqual(loop.intervalSeconds, 1800)
        XCTAssertEqual(loop.times, 5)
        XCTAssertEqual(loop.ticksFired, 2)
        XCTAssertTrue(loop.deferredByGoal)
        XCTAssertEqual(loop.state, .deferred, "deferral is shown before the status")
        XCTAssertEqual(loop.nextDueAt?.timeIntervalSince1970 ?? 0, 1_759_901_400, accuracy: 0.001)
        XCTAssertFalse(loop.isSelfPaced)

        let heartbeat = snapshot.heartbeat!
        XCTAssertEqual(heartbeat.prompt, "Anything new in the inbox?")
        XCTAssertTrue(heartbeat.isPaused)
        XCTAssertEqual(heartbeat.intervalSeconds, 3600)
        XCTAssertEqual(heartbeat.fireCount, 4)
        XCTAssertNil(heartbeat.lastFiredAt, "the backend writes 0 for never fired")
        XCTAssertEqual(heartbeat.nextDueAt?.timeIntervalSince1970 ?? 0, 1_759_890_000 + 3600, accuracy: 0.001, "next due falls back to creation plus the interval")
    }

    func testAnEmptySnapshotIsEmpty() {
        let snapshot = SessionControlSnapshot(json: Self.emptySnapshot)
        XCTAssertTrue(snapshot.isEmpty)
        XCTAssertNil(snapshot.goal)
        XCTAssertNil(snapshot.loop)
        XCTAssertNil(snapshot.heartbeat)
        XCTAssertEqual(snapshot.revision, "")
        XCTAssertNil(snapshot.updatedAt, "0 means no persisted timestamp")
    }

    func testGoalStateFollowsStatusWithoutABarrier() {
        func goal(_ status: String, verdict: String? = nil) -> GoalSnapshot {
            GoalSnapshot(json: .object([
                "title": .string("t"), "status": .string(status), "turns_used": .number(1), "max_turns": .number(0),
                "contract": .object([:]), "subgoals": .array([]), "gates": .array([]),
                "last_verdict": verdict.map(JSONValue.string) ?? .null,
            ]))!
        }
        XCTAssertEqual(goal("active").state, .active)
        XCTAssertEqual(goal("paused").state, .paused)
        XCTAssertEqual(goal("done").state, .done)
        XCTAssertTrue(goal("active", verdict: "blocked").isBlocked)
    }

    func testTheUpdateEventProjectsToItsOwnCase() {
        let event = GatewayEvent(
            type: "session.control.update",
            sessionID: session,
            payload: .object(["control": Self.fullSnapshot]),
            params: .null
        )
        guard case .sessionControlUpdate(let update) = HermesEvent.project(event) else {
            return XCTFail("session.control.update fell through to .other")
        }
        XCTAssertEqual(update.sessionID, session)
        XCTAssertEqual(update.control.goal?.title, "Ship the release notes")
        XCTAssertEqual(update.control.revision, "a3f9c2")
    }

    func testTheEngineKeepsTheLatestSnapshotOnTheSession() {
        let engine = TurnEngine()
        _ = engine.apply(GatewayEvent(type: "session.control.update", sessionID: session, payload: .object(["control": Self.fullSnapshot]), params: .null))
        XCTAssertEqual(engine.state(for: session).control?.goal?.turnsUsed, 3)

        _ = engine.apply(GatewayEvent(type: "session.control.update", sessionID: session, payload: .object(["control": Self.emptySnapshot]), params: .null))
        XCTAssertEqual(engine.state(for: session).control?.isEmpty, true, "the whole snapshot is replaced, never merged")
    }

    // MARK: Encoding

    func testReadSendsOnlyTheSessionID() async throws {
        let (client, socket) = try await ScriptedGateway.connected(replies: [
            "session.control.read": [.object(["control": Self.fullSnapshot])],
        ])

        let snapshot = try await SessionControlAPI(client: client).read(sessionID: session)

        XCTAssertEqual(snapshot.goal?.title, "Ship the release notes")
        let sent = await socket.sentParams("session.control.read")
        let params = try XCTUnwrap(sent)
        XCTAssertEqual(Set(params.objectValue?.keys.map { $0 } ?? []), ["session_id"], "`SessionControlReadParams` declares session_id and profile only")
        XCTAssertEqual(params["session_id"]?.stringValue, session)

        await client.disconnect()
    }

    func testReadCarriesTheProfileOnlyWhenGiven() async throws {
        let (client, socket) = try await ScriptedGateway.connected(replies: [
            "session.control.read": [.object(["control": Self.emptySnapshot])],
        ])

        _ = try await SessionControlAPI(client: client).read(sessionID: session, profile: "work")

        let sent = await socket.sentParams("session.control.read")
        let params = try XCTUnwrap(sent)
        XCTAssertEqual(Set(params.objectValue?.keys.map { $0 } ?? []), ["session_id", "profile"])
        XCTAssertEqual(params["profile"]?.stringValue, "work")

        await client.disconnect()
    }

    func testAPlainActionSendsNoArgs() async throws {
        let (client, socket) = try await ScriptedGateway.connected(replies: [
            "session.control": [.object(["control": Self.fullSnapshot, "dispatch": .object(["type": .null, "output": .null, "notice": .null, "message": .null, "display": .null])])],
        ])

        let result = try await SessionControlAPI(client: client).perform(.goalPause, sessionID: session)

        XCTAssertEqual(result.control.goal?.title, "Ship the release notes")
        XCTAssertFalse(result.dispatch.isSend)
        let sent = await socket.sentParams("session.control")
        let params = try XCTUnwrap(sent)
        XCTAssertEqual(Set(params.objectValue?.keys.map { $0 } ?? []), ["session_id", "action"], "`SessionControlParams` is session_id, action, optional args, optional profile")
        XCTAssertEqual(params["action"]?.stringValue, "goal.pause")

        await client.disconnect()
    }

    func testSubgoalAddSendsTextAndRemoveSendsAOneBasedIndex() async throws {
        let (client, socket) = try await ScriptedGateway.connected(replies: [
            "session.control": [
                .object(["control": Self.fullSnapshot, "dispatch": .object([:])]),
                .object(["control": Self.fullSnapshot, "dispatch": .object([:])]),
            ],
        ])
        let api = SessionControlAPI(client: client)

        _ = try await api.perform(.subgoalAdd, sessionID: session, text: "Tag pushed")
        var sent = await socket.sentParams("session.control")
        var params = try XCTUnwrap(sent)
        XCTAssertEqual(params["action"]?.stringValue, "subgoal.add")
        XCTAssertEqual(Set(params["args"]?.objectValue?.keys.map { $0 } ?? []), ["text"], "`SessionControlArgs` declares text and index; nothing else may ride in args")
        XCTAssertEqual(params["args"]?["text"]?.stringValue, "Tag pushed")

        _ = try await api.perform(.subgoalRemove, sessionID: session, index: 2)
        sent = await socket.sentParams("session.control")
        params = try XCTUnwrap(sent)
        XCTAssertEqual(params["action"]?.stringValue, "subgoal.remove")
        XCTAssertEqual(Set(params["args"]?.objectValue?.keys.map { $0 } ?? []), ["index"])
        XCTAssertEqual(params["args"]?["index"]?.intValue, 2, "the handler wants a true integer, 1-based (`_validate_action_args`)")

        await client.disconnect()
    }

    func testEveryAllowlistedActionIsSpelledAsTheBackendSpellsIt() {
        let declared: Set<String> = [
            "goal.pause", "goal.resume", "goal.clear", "goal.unwait",
            "loop.pause", "loop.resume", "loop.stop",
            "subgoal.add", "subgoal.remove", "subgoal.clear",
            "heartbeat.pause", "heartbeat.resume", "heartbeat.clear",
        ]
        XCTAssertEqual(Set(SessionControlAction.allCases.map(\.rawValue)), declared)
        XCTAssertEqual(Set(SessionControlAction.allCases.filter(\.isDestructive).map(\.rawValue)), ["goal.clear", "loop.stop", "subgoal.remove", "subgoal.clear", "heartbeat.clear"])
    }

    func testAResumeThatWantsAKickoffIsASendDispatch() async throws {
        let (client, _) = try await ScriptedGateway.connected(replies: [
            "session.control": [.object([
                "control": Self.fullSnapshot,
                "dispatch": .object(["type": .string("send"), "output": .null, "notice": .string("Goal resumed."), "message": .string("Continue working towards the goal."), "display": .string("/goal resume")]),
            ])],
        ])

        let result = try await SessionControlAPI(client: client).perform(.goalResume, sessionID: session)

        XCTAssertTrue(result.dispatch.isSend)
        XCTAssertEqual(result.dispatch.message, "Continue working towards the goal.")
        XCTAssertEqual(result.dispatch.display, "/goal resume")
        XCTAssertEqual(result.dispatch.notice, "Goal resumed.")

        await client.disconnect()
    }

    // MARK: The older backend

    func testMethodNotFoundAndUndeclaredParamsBothReadAsUnknownMethod() async throws {
        let (client, _) = try await ScriptedGateway.connected(replies: [
            "session.control.read": [
                ScriptedGateway.rpcError(code: -32601, message: "unknown method: session.control.read — the client and the Hermes backend are out of sync"),
                ScriptedGateway.rpcError(code: 4000, message: "invalid params for session.control.read: session_id: Extra inputs are not permitted"),
                ScriptedGateway.rpcError(code: 5031, message: "session.control.read failed: boom"),
            ],
        ])
        let api = SessionControlAPI(client: client)

        for expected in [true, true, false] {
            do {
                _ = try await api.read(sessionID: session)
                XCTFail("the scripted error did not surface")
            } catch let error as HermesError {
                XCTAssertEqual(error.isUnknownMethod, expected, "\(error)")
            }
        }

        await client.disconnect()
    }

    /// The handler checks `type(index) is not int` (`methods_session_control.py:313`), and Python reads a JSON `2.0` as a float, so the wire text itself is the contract, not the decoded value.
    func testTheRemoveIndexIsAnIntegerOnTheWireText() async throws {
        let (client, socket) = try await ScriptedGateway.connected(replies: [
            "session.control": [.object(["control": Self.emptySnapshot, "dispatch": .object([:])])],
        ])

        _ = try await SessionControlAPI(client: client).perform(.subgoalRemove, sessionID: session, index: 2)

        let lines = await socket.sentLines
        let line = try XCTUnwrap(lines.last(where: { $0.contains("session.control") }))
        XCTAssertTrue(line.contains("\"index\":2"), line)
        XCTAssertFalse(line.contains("\"index\":2.0"), line)

        await client.disconnect()
    }
}
