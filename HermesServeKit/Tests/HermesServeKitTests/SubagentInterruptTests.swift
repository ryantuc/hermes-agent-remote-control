import XCTest

@testable import HermesServeKit

/// **BUG-013, second fix** — what Stop needs from this layer to actually stop
/// a delegated agent.
///
/// The first fix widened `isTurnActive` so Stop appears whenever the strip claims work,
/// including the state where a background agent outlives the turn that spawned
/// it. In that state `session.interrupt` reaches nothing: the handler gates on
/// the session being busy, and the background dispatch path detaches every child
/// from the parent's interrupt propagation. `subagent.interrupt` is the only
/// thing that stops one, and it is addressed by the backend's own
/// `subagent_id` — which is exactly the thing a `SubagentRow.id` is allowed not
/// to be.
///
/// So these pin three separate facts:
///
/// 1. A row remembers the id the wire gave it, separately from the id this
///    client hashes it under, and remembers whether it ever **started**.
/// 2. Retiring a row locally is legal only on the evidence that proves it: an
///    agent that started and that the backend no longer has. A queued child
///    answers identically to a dead one and must survive.
/// 3. The two result decodes keep "the gateway said no" apart from "the gateway
///    did not answer" — the distinction the reconcile hangs on.
final class SubagentInterruptTests: XCTestCase {
    private let session = "a1b2c3d4"

    // MARK: Wire helpers

    private func event(_ type: String, payload: JSONValue = .object([:])) -> GatewayEvent {
        GatewayEvent(
            type: type,
            sessionID: session,
            payload: payload,
            params: .object([
                "type": .string(type),
                "session_id": .string(session),
                "payload": payload,
            ])
        )
    }

    private func subagent(
        _ phase: SubagentEvent.Phase,
        id: String? = nil,
        goal: String = "Do the thing",
        parent: String? = nil,
        taskIndex: Int? = 0,
        extra: [String: JSONValue] = [:]
    ) -> GatewayEvent {
        var payload: [String: JSONValue] = ["goal": .string(goal), "task_count": .number(2)]
        if let id { payload["subagent_id"] = .string(id) }
        if let parent { payload["parent_id"] = .string(parent) }
        if let taskIndex { payload["task_index"] = .number(Double(taskIndex)) }
        for (key, value) in extra { payload[key] = value }
        return event(phase.rawValue, payload: .object(payload))
    }

    private func drive(_ engine: TurnEngine, _ events: [GatewayEvent]) {
        for event in events { engine.apply(event) }
        engine.flush()
    }

    private func activity(_ engine: TurnEngine) -> SessionActivity {
        engine.state(for: session).activity
    }

    // MARK: 1 — what the row remembers

    /// The id the wire gave, kept apart from the id the upsert hashes on.
    ///
    /// `SubagentRow.id` falls back to a synthetic `"{parent}:{index}:{goal}"`
    /// composite when no frame carried a `subagent_id`, because the upsert needs
    /// *something* stable to hash. Sending that composite to
    /// `subagent.interrupt` would ask the backend to kill an id that only exists
    /// on this phone.
    func testARowSeparatesTheWireIdFromTheIdItIsHashedUnder() throws {
        let engine = TurnEngine()
        drive(engine, [
            event("message.start"),
            subagent(.start, id: "sa-real", goal: "Audit the migration"),
            subagent(.start, goal: "Draft the release notes", parent: "root-agent", taskIndex: 1),
        ])

        let rows = activity(engine).subagents
        let real = try XCTUnwrap(rows.first { $0.goal == "Audit the migration" })
        XCTAssertEqual(real.id, "sa-real")
        XCTAssertEqual(real.wireSubagentID, "sa-real", "the wire named this one and Stop can address it")

        let synthetic = try XCTUnwrap(rows.first { $0.goal == "Draft the release notes" })
        XCTAssertEqual(synthetic.id, "root-agent:1:Draft the release notes")
        XCTAssertEqual(synthetic.wireSubagentID, "", """
            no frame for this row carried a subagent_id, so there is nothing to send. \
            A composite on the wire would be a kill aimed at an id the backend never had
            """)
    }

    /// `hasStarted` is set by the event type and never unset, which is the whole
    /// of what separates a dead agent from a queued one later on.
    func testHasStartedTracksTheStartFrameAndSurvivesLaterPartialFrames() throws {
        let engine = TurnEngine()
        drive(engine, [event("message.start"), subagent(.spawnRequested, id: "sa-1")])
        XCTAssertFalse(try XCTUnwrap(activity(engine).subagents.first).hasStarted,
                       "spawn_requested announces an agent; it does not dispatch one")

        drive(engine, [subagent(.start, id: "sa-1")])
        XCTAssertTrue(try XCTUnwrap(activity(engine).subagents.first).hasStarted)

        // A later frame that omits everything must not walk it back.
        drive(engine, [subagent(.progress, id: "sa-1", extra: ["text": .string("still going")])])
        XCTAssertTrue(try XCTUnwrap(activity(engine).subagents.first).hasStarted,
                      "a partial frame may not unset a fact an earlier frame established")
    }

    /// A `spawn_requested` with no id followed by a `start` that has one is two
    /// rows, not one — the identities genuinely differ — but the started row is
    /// the one that carries the wire id, so Stop still reaches the agent.
    func testAnIdArrivingLateIsPickedUpByWhicheverRowCarriesIt() throws {
        let engine = TurnEngine()
        drive(engine, [
            event("message.start"),
            subagent(.spawnRequested, goal: "Late id", taskIndex: 3),
            subagent(.start, id: "sa-late", goal: "Late id", taskIndex: 3),
        ])
        XCTAssertEqual(activity(engine).interruptibleSubagentIDs, ["sa-late"])

        // And the cost of that, stated rather than glossed: the two frames hash
        // to different identities, so this is TWO rows for one agent. The ghost
        // is the `spawn_requested` one — no wire id, never started, and the real
        // `subagent.complete` will carry `sa-late` and terminate the other row,
        // so nothing on the wire will ever retire it.
        XCTAssertEqual(activity(engine).subagents.count, 2,
                       "an id that arrives late does not merge backwards; the composite row stays")
        XCTAssertEqual(activity(engine).unkillableRunningSubagents.count, 1)

        // Which is exactly why the idle sweep may not require `hasStarted`.
        // With the guard the ghost would be immortal, `runningSubagents` would
        // never empty, and Stop would sit on the screen forever.
        var surface = activity(engine)
        let observed = surface.runningSubagents.map(\.id)
        XCTAssertEqual(surface.markSubagentsInterrupted(ids: observed), 2)
        XCTAssertTrue(surface.runningSubagents.isEmpty,
                      "a proven-idle backend clears the ghost too, or nothing ever will")
    }

    // MARK: 2 — what Stop is allowed to send, and to retire

    func testInterruptibleIdsAreRunningNamedAndDeduped() {
        let engine = TurnEngine()
        drive(engine, [
            event("message.start"),
            subagent(.start, id: "sa-1", goal: "One", taskIndex: 0),
            subagent(.start, id: "sa-2", goal: "Two", taskIndex: 1),
            subagent(.start, goal: "Nameless", parent: "p", taskIndex: 2),
            subagent(.complete, id: "sa-2", goal: "Two", taskIndex: 1,
                     extra: ["status": .string("completed")]),
        ])

        let ids = activity(engine).interruptibleSubagentIDs
        XCTAssertEqual(ids, ["sa-1"], """
            sa-2 has finished and re-killing it would ask about an id the backend has \
            legitimately forgotten; the nameless row has nothing to send
            """)
        XCTAssertEqual(activity(engine).unkillableRunningSubagents.map(\.goal), ["Nameless"],
                       "the row Stop cannot address has to be countable, so Stop can say so")
    }

    /// The `found: false` retire, and its guard.
    func testOnlyAStartedRunningRowMayBeRetiredLocally() throws {
        var surface = SessionActivity()
        surface.subagents = [
            SubagentRow(id: "sa-started", wireSubagentID: "sa-started", hasStarted: true, goal: "Started"),
            SubagentRow(id: "sa-queued", wireSubagentID: "sa-queued", hasStarted: false, goal: "Queued"),
            SubagentRow(id: "sa-done", wireSubagentID: "sa-done", hasStarted: true, goal: "Done", state: .completed),
        ]

        XCTAssertTrue(surface.markSubagentInterrupted(wireSubagentID: "sa-started"))
        XCTAssertEqual(try XCTUnwrap(surface.subagents.first { $0.id == "sa-started" }).state, .interrupted)

        XCTAssertFalse(surface.markSubagentInterrupted(wireSubagentID: "sa-queued"), """
            a child queued behind delegation.max_concurrent_children answers `found: false` \
            for the opposite reason a dead one does — retiring it erases an agent that has \
            not run yet
            """)
        XCTAssertEqual(try XCTUnwrap(surface.subagents.first { $0.id == "sa-queued" }).state, .running)

        XCTAssertFalse(surface.markSubagentInterrupted(wireSubagentID: "sa-done"),
                       "already terminal — nothing changed, and the caller must not be told it did")
        XCTAssertEqual(try XCTUnwrap(surface.subagents.first { $0.id == "sa-done" }).state, .completed,
                       "…and the state it finished in is not overwritten")

        XCTAssertFalse(surface.markSubagentInterrupted(wireSubagentID: "sa-never-heard-of"))
        XCTAssertFalse(surface.markSubagentInterrupted(wireSubagentID: ""),
                       "an empty id must never match the rows that have no wire id")
    }

    /// The whole-surface sweep, for the one caller that can prove it: nothing at
    /// all is delegating on this backend.
    ///
    /// **`hasStarted` is not a guard here, and that asymmetry is the point.** A
    /// per-id `found: false` cannot tell a dead agent from a queued one, so it
    /// needs the guard. Process-wide idleness can: if nothing is delegating
    /// anywhere then nothing is queued anywhere either. Holding a never-started
    /// row back from *this* sweep would leave a row nothing in the system can
    /// ever retire — no completion is coming, `pruneTerminalSubagents` only
    /// removes terminal rows — so the strip would claim work forever and Stop
    /// would sit on screen writing the same false sentence on every tap.
    func testTheIdleSweepRetiresEveryRowItWasToldAbout() throws {
        var surface = SessionActivity()
        surface.subagents = [
            SubagentRow(id: "sa-1", wireSubagentID: "sa-1", hasStarted: true, goal: "One"),
            SubagentRow(id: "sa-2", wireSubagentID: "", hasStarted: true, goal: "Nameless but started"),
            SubagentRow(id: "sa-3", wireSubagentID: "sa-3", hasStarted: false, goal: "Queued"),
        ]

        XCTAssertEqual(surface.markSubagentsInterrupted(ids: ["sa-1", "sa-2", "sa-3"]), 3)
        XCTAssertTrue(surface.runningSubagents.isEmpty, """
            an unnameable row and a never-started one are both retirable on this evidence — \
            leaving either behind strands a row that nothing can ever clear
            """)
        XCTAssertEqual(surface.markSubagentsInterrupted(ids: ["sa-1"]), 0, "idempotent")
    }

    /// The guard that replaced it, and the reason it is `ids` and not a
    /// predicate: an answer about the backend at time T says nothing about a row
    /// that appeared at T+1. A mirrored peer's fan-out can land inside a single
    /// round trip, and retiring one of its agents would drop a live agent off
    /// the strip on evidence that never covered it.
    func testTheIdleSweepLeavesRowsItWasNotToldAboutAlone() throws {
        var surface = SessionActivity()
        surface.subagents = [
            SubagentRow(id: "sa-old", wireSubagentID: "sa-old", hasStarted: true, goal: "Observed"),
            SubagentRow(id: "sa-new", wireSubagentID: "sa-new", hasStarted: true, goal: "Landed mid-call"),
        ]

        XCTAssertEqual(surface.markSubagentsInterrupted(ids: ["sa-old"]), 1)
        XCTAssertEqual(surface.runningSubagents.map(\.id), ["sa-new"], """
            the agent that appeared after the question was asked must survive the answer
            """)
        XCTAssertEqual(surface.markSubagentsInterrupted(ids: []), 0, "an empty roster retires nothing")
    }

    /// Who spawned the agent, remembered past the turn that did it.
    ///
    /// `turnStartedLocally` is cleared at `message.complete`, which is where a
    /// background agent's life mostly happens — so the fact has to be stamped on
    /// the row when it is created or it is unrecoverable. Stop reads it to
    /// decide whether to ask before killing a fan-out this phone did not start.
    func testARowRemembersWhoseTurnSpawnedItAfterThatTurnSettles() throws {
        var surface = SessionActivity()
        let foreign = SubagentEvent(sessionID: session, phase: .start, payload: .object([
            "subagent_id": .string("sa-theirs"), "goal": .string("A desktop's fan-out"),
        ]))
        surface.upsert(foreign, turnStartedLocally: false)
        XCTAssertFalse(try XCTUnwrap(surface.subagents.first).startedByThisClient)

        // Every later frame arrives after the parent turn settled, so the flag
        // the reducer reads is false by then for OUR turns too. A merge that
        // restamped would flip a local agent to foreign — and vice versa.
        let ours = SubagentEvent(sessionID: session, phase: .start, payload: .object([
            "subagent_id": .string("sa-ours"), "goal": .string("Our fan-out"),
        ]))
        surface.upsert(ours, turnStartedLocally: true)
        let progress = SubagentEvent(sessionID: session, phase: .progress, payload: .object([
            "subagent_id": .string("sa-ours"), "text": .string("still going"),
        ]))
        surface.upsert(progress, turnStartedLocally: false)

        XCTAssertTrue(try XCTUnwrap(surface.subagents.first { $0.id == "sa-ours" }).startedByThisClient, """
            a later frame may not restamp the origin: it is a fact about the turn that spawned \
            the agent, and that turn is over
            """)
    }

    /// The engine wrappers touch the activity surface and **nothing else**. This
    /// is the difference from `markInterrupted`, which finalises the turn and
    /// wipes the whole surface — correct for a real Stop of a real turn, and
    /// exactly wrong when the turn is already settled and other agents are still
    /// working.
    func testRetiringOneAgentTouchesNoTurnStateAndNoOtherRow() throws {
        let engine = TurnEngine()
        drive(engine, [
            event("message.start"),
            subagent(.start, id: "sa-1", goal: "One", taskIndex: 0),
            subagent(.start, id: "sa-2", goal: "Two", taskIndex: 1),
        ])
        XCTAssertTrue(engine.state(for: session).isBusy, "precondition: the turn is running")

        XCTAssertTrue(engine.markSubagentInterrupted(sessionID: session, wireSubagentID: "sa-1"))
        let state = engine.state(for: session)
        XCTAssertEqual(state.activity.runningSubagents.map(\.id), ["sa-2"],
                       "the other agent is still working and its row must survive")
        XCTAssertTrue(state.isBusy, "retiring an agent is not interrupting the turn")
        XCTAssertFalse(state.interrupted, "…and it must not raise the interrupt latch")

        XCTAssertFalse(engine.markSubagentInterrupted(sessionID: "no-such-session", wireSubagentID: "sa-2"),
                       "an unknown session must not materialise state")
        XCTAssertEqual(engine.markSubagentsInterrupted(sessionID: "no-such-session", ids: ["sa-2"]), 0)
    }

    // MARK: 3 — the two decodes

    func testSubagentInterruptResultKeepsFoundAndEchoesAnIdItWasNotGiven() {
        let killed = SubagentInterruptResult(
            json: .object(["found": .bool(true), "subagent_id": .string("sa-1")]),
            requested: "sa-1"
        )
        XCTAssertTrue(killed.found)
        XCTAssertEqual(killed.subagentID, "sa-1")

        let missing = SubagentInterruptResult(json: .object(["found": .bool(false)]), requested: "sa-9")
        XCTAssertFalse(missing.found)
        XCTAssertEqual(missing.subagentID, "sa-9", "an answer with no echo still identifies what was asked")

        let silent = SubagentInterruptResult(json: .object([:]), requested: "sa-9")
        XCTAssertFalse(silent.found, "no `found` key is not a success")
    }

    /// The distinction the reconcile hangs on: an empty `active` is an answer,
    /// a missing `active` is not. A backend with no `delegation.status` at all
    /// must not read as a quiet one, because the caller retires rows on quiet.
    func testDelegationStatusKeepsNoAnswerApartFromNothingRunning() throws {
        XCTAssertNil(DelegationStatus(json: .object([:])), "no `active` key — the gateway did not answer")
        XCTAssertNil(DelegationStatus(json: .object(["active": .number(3)])),
                     "an `active` that is not a list is a shape this client does not understand")

        let idle = try XCTUnwrap(DelegationStatus(json: .object(["active": .array([])])))
        XCTAssertTrue(idle.isIdle)
        XCTAssertEqual(idle.activeCount, 0)
    }

    func testDelegationStatusReadsBothElementShapesAndCountsWhatItCannotName() throws {
        let status = try XCTUnwrap(DelegationStatus(json: .object([
            "active": .array([
                .string("sa-bare"),
                .object(["subagent_id": .string("sa-obj")]),
                .object(["id": .string("sa-id")]),
                .object(["agent_id": .string("sa-agent")]),
                .object(["something_else": .string("no id at all")]),
            ]),
            "paused": .bool(true),
            "max_spawn_depth": .number(3),
            "max_concurrent_children": .number(3),
        ])))

        XCTAssertEqual(status.activeIDs, ["sa-bare", "sa-obj", "sa-id", "sa-agent"])
        XCTAssertEqual(status.activeCount, 5, """
            an element this decode could not name is still an active delegation. \
            Counting activeIDs instead would report a busy backend as idle and the \
            sweep would retire live rows
            """)
        XCTAssertFalse(status.isIdle)
        XCTAssertTrue(status.paused)
        XCTAssertEqual(status.maxSpawnDepth, 3)
        XCTAssertEqual(status.maxConcurrentChildren, 3)
    }

    // MARK: 4 — what goes out on the wire

    /// hermes-agent 0.21.1 refuses this call with 4001 unless `session_id` is present, and every backend before it ignores the extra key (BUG-147).
    func testInterruptSendsBothTheSubagentIdAndTheSessionId() async throws {
        let (client, socket) = try await ScriptedGateway.connected(replies: [
            "subagent.interrupt": [.object([
                "found": .bool(true),
                "subagent_id": .string("sa-1"),
            ])]
        ])

        let result = try await SessionAPI(client: client)
            .interruptSubagent(subagentID: "sa-1", sessionID: session)

        let sent = await socket.sentParams("subagent.interrupt")
        let params = try XCTUnwrap(sent)
        XCTAssertEqual(params["subagent_id"]?.coercedString, "sa-1")
        XCTAssertEqual(params["session_id"]?.coercedString, session, """
            without it the 0.21.1 handler short-circuits in \
            _current_session_steer_authority and every delegated agent keeps running
            """)
        XCTAssertTrue(result.found)

        await client.disconnect()
    }
}
