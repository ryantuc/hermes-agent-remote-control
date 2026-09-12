import HermesServeKit
import XCTest

@testable import HermesMobile

/// **BUG-013, wave 2 item 0** — the hole wave 1 knowingly shipped.
///
/// Wave 1 widened `isTurnActive` so a Stop is on screen whenever the strip
/// claims work, including the state the report was about: the parent turn has
/// settled and delegated agents are still running. But `stopTapped` only reached
/// `interrupt()` when the turn was busy or a prompt was queued, so in exactly
/// that state the tap was swallowed — a button that appears, acknowledges, and
/// stops nothing.
///
/// It could not simply be widened either. `session.interrupt` cannot touch a
/// background agent twice over: the handler gates on `session["running"]`, which
/// is false the instant a fan-out is dispatched, and the background dispatch
/// path explicitly detaches every child from the parent's interrupt-propagation
/// list. Removing the busy guard would have produced a Stop that reports success
/// and stops nothing — a worse lie than the silence.
///
/// `subagent.interrupt` is the mechanism that works. These tests drive the
/// shipped `ChatModel` against the scripted gateway and assert on **what the
/// backend was actually asked**, because "the button is enabled" was never the
/// claim in doubt.
@MainActor
final class StopStopsAgentsTests: XCTestCase {

    private static func subagentPayload(
        id: String?,
        goal: String,
        taskIndex: Int = 0,
        extra: [String: JSONValue] = [:]
    ) -> JSONValue {
        var payload: [String: JSONValue] = [
            "goal": .string(goal),
            "task_index": .number(Double(taskIndex)),
            "task_count": .number(1),
        ]
        if let id { payload["subagent_id"] = .string(id) }
        for (key, value) in extra { payload[key] = value }
        return .object(payload)
    }

    /// Join the Stop's own work — the kills **and** the reconcile.
    ///
    /// Without this, a test that asserts "nothing was retired" is racing the
    /// code it is testing: it would assert before `stopBackgroundAgents` had
    /// processed the reply, and pass whether or not the logic is right. The
    /// backend's call count is the wrong signal — it fires when the request
    /// *arrives*, not when the answer has been acted on — and polling a flag is
    /// no better, since against an in-process backend both of its edges can land
    /// between two 20 ms polls. Awaiting the task is exact.
    private func waitForStopToSettle(_ chat: ChatModel) async {
        await chat.stopWorkTask?.value
    }

    /// `chat.errorMessage`, but only when Stop wrote it.
    ///
    /// The harness points REST at a port that refuses instantly (README, "What
    /// is not scripted"), so "Could not connect to the server." lands in this
    /// same slot at unpredictable moments. Asserting on the raw optional makes
    /// every test here a coin flip on timing; asserting on *this* makes them
    /// assertions about Stop.
    private func stopMessage(_ chat: ChatModel) -> String? {
        guard let message = chat.errorMessage else { return nil }
        let written = [
            "Couldn't stop every background agent:",
            "This backend didn't send ids",
            "Those agents haven't started yet",
        ]
        return written.contains(where: message.hasPrefix) ? message : nil
    }

    private func openChat(_ harness: AppHarness, storedID: String) async throws -> (ChatModel, String) {
        let chat = harness.chat(storedID: storedID)
        await chat.open()
        let bound = await waitUntil { chat.runtimeSessionID != nil }
        XCTAssertTrue(bound, "open() never bound a runtime id — nothing after this proves anything")
        chat.errorMessage = nil
        return (chat, try XCTUnwrap(chat.runtimeSessionID))
    }

    /// Answer `subagent.interrupt` the way a backend that still has the agent
    /// does. `found: false` is the interesting case and each test that wants it
    /// stubs it itself.
    private func stubKillsSucceed(_ harness: AppHarness) async {
        await harness.backend.stub("subagent.interrupt") { call in
            .object([
                "found": .bool(true),
                "subagent_id": .string(call.params["subagent_id"]?.coercedString ?? ""),
            ])
        }
    }

    /// Stage the reported state: a turn that started agents and then settled,
    /// leaving them running.
    private func stageSettledTurnWithAgent(
        _ harness: AppHarness,
        runtimeID: String,
        chat: ChatModel,
        agentID: String? = "sa-1",
        goal: String = "Long background job"
    ) async {
        await harness.backend.emit("message.start", sessionID: runtimeID)
        await harness.backend.emit("subagent.start", sessionID: runtimeID,
                                   payload: Self.subagentPayload(id: agentID, goal: goal))
        await harness.backend.emit("message.complete", sessionID: runtimeID, payload: .object([
            "text": .string("Kicked it off."),
            "status": .string("complete"),
        ]))
        let staged = await waitUntil {
            !chat.live.isBusy && chat.live.activity.runningSubagents.count == 1
        }
        XCTAssertTrue(staged, """
            precondition: a settled turn with one agent still running. \
            isBusy=\(chat.live.isBusy) running=\(chat.live.activity.runningSubagents.count)
            """)
    }

    // MARK: The hole itself

    /// The tap that used to do nothing. Stop over a settled turn with a running
    /// agent must send that agent's own kill.
    func testStopKillsTheAgentThatOutlivedItsTurn() async throws {
        let harness = await AppHarness.make()
        try await harness.openSocket()
        let (chat, runtimeID) = try await openChat(harness, storedID: "20260815_100000_kill")
        await stubKillsSucceed(harness)
        await stageSettledTurnWithAgent(harness, runtimeID: runtimeID, chat: chat)

        chat.stopTapped()

        let killed = await waitUntil { await harness.backend.callCount("subagent.interrupt") == 1 }
        XCTAssertTrue(killed, """
            Stop over a settled turn with a running agent sent no subagent.interrupt — \
            the button is back to acknowledging a tap and stopping nothing \
            (ChatModel.stopTapped)
            """)
        let kills = await harness.backend.calls(to: "subagent.interrupt")
        let call = try XCTUnwrap(kills.first)
        XCTAssertEqual(call.params["subagent_id"]?.coercedString, "sa-1")

        // …and the session interrupt is NOT dialed: the turn is already settled,
        // the backend would no-op it, and the local finalise it drives would wipe
        // the activity surface of agents this Stop has not accounted for yet.
        let sessionInterrupts = await harness.backend.callCount("session.interrupt")
        XCTAssertEqual(sessionInterrupts, 0, "there is no turn to interrupt in this state")

        await harness.tearDown()
    }

    /// The other half: a turn that is genuinely running AND has agents under it
    /// gets both calls, turn first.
    func testStopUnderARunningTurnKillsTheTurnAndItsAgents() async throws {
        let harness = await AppHarness.make()
        try await harness.openSocket()
        let (chat, runtimeID) = try await openChat(harness, storedID: "20260815_100100_kill")
        await stubKillsSucceed(harness)

        await harness.backend.emit("message.start", sessionID: runtimeID)
        await harness.backend.emit("subagent.start", sessionID: runtimeID,
                                   payload: Self.subagentPayload(id: "sa-a", goal: "One", taskIndex: 0))
        await harness.backend.emit("subagent.start", sessionID: runtimeID,
                                   payload: Self.subagentPayload(id: "sa-b", goal: "Two", taskIndex: 1))
        let staged = await waitUntil {
            chat.live.isBusy && chat.live.activity.runningSubagents.count == 2
        }
        XCTAssertTrue(staged, "precondition: a running turn with two agents under it")

        chat.stopTapped()

        let bothKilled = await waitUntil { await harness.backend.callCount("subagent.interrupt") == 2 }
        XCTAssertTrue(bothKilled, """
            a Stop under a running turn left its background agents running: \
            session.interrupt does not propagate to a detached child, so every agent \
            needs its own kill
            """)
        let sessionInterrupts = await harness.backend.callCount("session.interrupt")
        XCTAssertEqual(sessionInterrupts, 1)
        let killedIDs = await harness.backend.calls(to: "subagent.interrupt")
            .compactMap { $0.params["subagent_id"]?.coercedString }
        XCTAssertEqual(Set(killedIDs), ["sa-a", "sa-b"])

        // The ids were sampled in the frame of the tap. `markInterrupted` wipes
        // the whole activity surface on its way past, so a `stopTapped` that read
        // them after awaiting the session interrupt would find nothing to kill —
        // which is the regression this assertion exists to catch.
        XCTAssertTrue(chat.live.activity.runningSubagents.isEmpty,
                      "the local finalise cleared the surface, exactly as it does for a real Stop")

        await harness.tearDown()
    }

    // MARK: What `found: false` is allowed to mean

    /// A row this client watched **start** that the backend no longer has is a
    /// row whose `subagent.complete` was eaten — a WS drop while backgrounded, a
    /// gateway restart, `display.tool_progress` flipped to `off`, a stall
    /// force-finalisation. Nothing is ever coming for it, so Stop retires it and
    /// the strip stops claiming work that ended.
    func testAStartedAgentTheBackendHasNeverHeardOfIsRetiredLocally() async throws {
        let harness = await AppHarness.make()
        try await harness.openSocket()
        let (chat, runtimeID) = try await openChat(harness, storedID: "20260815_100200_kill")
        await harness.backend.stub("subagent.interrupt") { _ in .object(["found": .bool(false)]) }
        await stageSettledTurnWithAgent(harness, runtimeID: runtimeID, chat: chat)
        XCTAssertTrue(chat.isTurnActive, "precondition: the strip claims work, so Stop is on screen")

        chat.stopTapped()

        await waitForStopToSettle(chat)
        XCTAssertTrue(chat.live.activity.runningSubagents.isEmpty, """
            the backend says it has no such agent and this client watched it start, so the \
            row is stale — leaving it running keeps Stop on screen over work that ended \
            (ChatModel.stopBackgroundAgents)
            """)
        XCTAssertEqual(chat.live.activity.subagents.first?.state, .interrupted,
                       "retired, not deleted — the row stays in the strip's history")
        XCTAssertFalse(chat.isTurnActive, "…and the composer stops claiming something is running")
        XCTAssertNil(stopMessage(chat), """
            the Stop achieved what it could; there is nothing to report. Asserted after the \
            work settled, not the moment the strip emptied — the message tail runs last
            """)

        await harness.tearDown()
    }

    /// The same answer, the opposite meaning. A child queued behind
    /// `delegation.max_concurrent_children` (default 3) has a row on screen and
    /// no registry entry **yet**. Retiring it would erase an agent that has not
    /// run. It keeps spinning and Stop stays reachable.
    func testAQueuedAgentThatNeverStartedSurvivesTheSameAnswer() async throws {
        let harness = await AppHarness.make()
        try await harness.openSocket()
        let (chat, runtimeID) = try await openChat(harness, storedID: "20260815_100300_kill")
        await harness.backend.stub("subagent.interrupt") { _ in .object(["found": .bool(false)]) }

        await harness.backend.emit("message.start", sessionID: runtimeID)
        await harness.backend.emit("subagent.spawn_requested", sessionID: runtimeID,
                                   payload: Self.subagentPayload(id: "sa-queued", goal: "Fourth of four"))
        await harness.backend.emit("message.complete", sessionID: runtimeID, payload: .object([
            "text": .string("Dispatched."),
            "status": .string("complete"),
        ]))
        let staged = await waitUntil {
            !chat.live.isBusy && chat.live.activity.runningSubagents.count == 1
        }
        XCTAssertTrue(staged, "precondition: one announced-but-not-started agent")

        chat.stopTapped()

        let asked = await waitUntil { await harness.backend.callCount("subagent.interrupt") == 1 }
        XCTAssertTrue(asked, "the kill is still worth sending — the backend may have started it since")
        _ = await waitUntil { self.stopMessage(chat) != nil }
        XCTAssertEqual(chat.live.activity.runningSubagents.count, 1, """
            a queued child answers `found: false` for the opposite reason a dead one does. \
            Retiring it here erases an agent that has not run yet
            """)
        XCTAssertEqual(stopMessage(chat),
                       "Those agents haven't started yet — the backend has nothing to stop until they do.",
                       "and the tap says what it could not do rather than looking like it worked")

        await harness.tearDown()
    }

    // MARK: The id this client is not allowed to invent

    /// `SubagentRow.id` falls back to a synthetic `"{parent}:{index}:{goal}"`
    /// composite when no frame carried a `subagent_id`. Sending that would ask
    /// the backend to kill an id that exists only on this phone.
    func testAnAgentWithNoWireIdIsNeverKilledByItsSyntheticId() async throws {
        let harness = await AppHarness.make()
        try await harness.openSocket()
        let (chat, runtimeID) = try await openChat(harness, storedID: "20260815_100400_kill")
        await stubKillsSucceed(harness)
        await stageSettledTurnWithAgent(harness, runtimeID: runtimeID, chat: chat,
                                        agentID: nil, goal: "Nameless work")

        chat.stopTapped()

        let reported = await waitUntil { self.stopMessage(chat) != nil }
        XCTAssertTrue(reported, "a Stop that can do nothing has to say so")
        let kills = await harness.backend.callCount("subagent.interrupt")
        XCTAssertEqual(kills, 0, """
            the row's id is a composite this client invented; sending it would be a kill \
            aimed at an id the backend never had
            """)
        XCTAssertEqual(stopMessage(chat),
                       "This backend didn't send ids for the delegated agents, so they can't be stopped from here.")

        await harness.tearDown()
    }

    // MARK: The reconcile

    /// The closing check. The kills were accepted but no `subagent.complete`
    /// followed — the frames were lost. `delegation.status` answering with an
    /// **empty** `active` says nothing is delegating anywhere on this backend,
    /// which settles it without any assumption about how one row is represented
    /// in a non-empty list.
    func testAnIdleBackendRetiresRowsWhoseCompletionNeverArrived() async throws {
        let harness = await AppHarness.make()
        try await harness.openSocket()
        let (chat, runtimeID) = try await openChat(harness, storedID: "20260815_100500_kill")
        await stubKillsSucceed(harness)
        await harness.backend.stub("delegation.status") { _ in
            .object(["active": .array([]), "paused": .bool(false)])
        }
        await stageSettledTurnWithAgent(harness, runtimeID: runtimeID, chat: chat)

        chat.stopTapped()

        let retired = await waitUntil { chat.live.activity.runningSubagents.isEmpty }
        XCTAssertTrue(retired, """
            every kill was accepted and no completion arrived, and the backend says it is \
            not delegating anything at all — the rows are stale and the strip must stop \
            claiming work (ChatModel.reconcileRemainingAgents)
            """)
        XCTAssertFalse(chat.isTurnActive)

        await harness.tearDown()
    }

    /// …and the other side of that answer. A gateway with no `delegation.status`
    /// answers `{}`, which carries no `active` key at all. That is not an answer
    /// and it must retire nothing — otherwise every old backend looks permanently
    /// idle and Stop deletes live agents off the strip.
    func testAGatewayThatCannotAnswerRetiresNothing() async throws {
        let harness = await AppHarness.make()
        try await harness.openSocket()
        let (chat, runtimeID) = try await openChat(harness, storedID: "20260815_100600_kill")
        await stubKillsSucceed(harness)
        await stageSettledTurnWithAgent(harness, runtimeID: runtimeID, chat: chat)

        chat.stopTapped()

        await waitForStopToSettle(chat)
        let asked = await harness.backend.callCount("delegation.status")
        XCTAssertEqual(asked, 1, "precondition: the reconcile ran and got the fallback `{}`")
        XCTAssertEqual(chat.live.activity.runningSubagents.count, 1, """
            a backend that did not answer the question is not a backend saying nothing is \
            running; the agent is still on screen and Stop is still reachable
            """)
        XCTAssertTrue(chat.isTurnActive)
        XCTAssertNil(stopMessage(chat), "the kill was accepted — there is nothing to report")

        await harness.tearDown()
    }

    /// A failed kill is surfaced. A Stop that failed silently is the failure mode
    /// this whole item exists to remove.
    func testAFailedKillIsReported() async throws {
        let harness = await AppHarness.make()
        try await harness.openSocket()
        let (chat, runtimeID) = try await openChat(harness, storedID: "20260815_100700_kill")
        await harness.backend.failRPC("subagent.interrupt", code: 4000, message: "no such subagent")
        await stageSettledTurnWithAgent(harness, runtimeID: runtimeID, chat: chat)

        chat.stopTapped()

        let reported = await waitUntil { self.stopMessage(chat) != nil }
        XCTAssertTrue(reported, "the kill failed and the user was told nothing")
        XCTAssertTrue(try XCTUnwrap(stopMessage(chat)).hasPrefix("Couldn't stop every background agent:"),
                      "got: \(chat.errorMessage ?? "nil")")
        XCTAssertEqual(chat.live.activity.runningSubagents.count, 1,
                       "and the row stays: nothing proved the agent stopped")

        await harness.tearDown()
    }

    // MARK: Whose work this is

    /// **The confirmation must reach the state this whole item is about.**
    ///
    /// `isForeignTurn` is `live.isBusy && !turnStartedLocally`, and the settled
    /// turn with running agents has `isBusy == false` by construction — so the
    /// gate every Stop control reads was false there, and a tap would have gone
    /// straight through to killing a desktop client's fan-out with no prompt.
    /// A backend before 0.21.1 gates `subagent.interrupt` on nothing at all, so
    /// nothing there would have refused it either.
    func testStopAsksFirstBeforeKillingAnotherClientsAgents() async throws {
        let harness = await AppHarness.make()
        await harness.backend.setSessionMirroring(true)
        try await harness.openSocket()
        let (chat, runtimeID) = try await openChat(harness, storedID: "20260815_100900_kill")

        // A turn this client did not start: a `message.start` stamped with a
        // different connection's origin, which is how a mirroring gateway
        // presents a desktop's turn.
        await harness.backend.emit("message.start", sessionID: runtimeID, origin: "desktop-transport-9")
        let foreign = await waitUntil { chat.live.isBusy && chat.isForeignTurn }
        XCTAssertTrue(foreign, "precondition: a mirrored turn from another client")

        await harness.backend.emit("subagent.start", sessionID: runtimeID,
                                   payload: Self.subagentPayload(id: "sa-theirs", goal: "Their long job"))
        await harness.backend.emit("message.complete", sessionID: runtimeID, payload: .object([
            "text": .string("Dispatched."),
            "status": .string("complete"),
        ]))
        let settled = await waitUntil {
            !chat.live.isBusy && chat.live.activity.runningSubagents.count == 1
        }
        XCTAssertTrue(settled, "precondition: their turn settled, their agent is still running")

        XCTAssertFalse(chat.isForeignTurn, """
            precondition, and the trap: with the turn settled there is no turn left to call \
            foreign, so the old gate reads false here
            """)
        XCTAssertTrue(chat.isForeignStop, """
            the agents on screen belong to another client's fan-out and Stop would kill them \
            outright — the confirmation has to be raised (ChatModel.isForeignStop)
            """)

        // …and the row's own memory is what knows it, since `turnStartedLocally`
        // was cleared by the completion.
        XCTAssertFalse(try XCTUnwrap(chat.live.activity.runningSubagents.first).startedByThisClient)
        XCTAssertFalse(chat.live.turnStartedLocally)

        await harness.tearDown()
    }

    /// The control: this client's own fan-out is not somebody else's work, and
    /// must not put a confirmation in front of an ordinary Stop.
    func testStopDoesNotAskAboutThisClientsOwnAgents() async throws {
        let harness = await AppHarness.make()
        await harness.backend.setSessionMirroring(true)
        try await harness.openSocket()
        let (chat, runtimeID) = try await openChat(harness, storedID: "20260815_101000_kill")

        chat.draft = "delegate this"
        chat.sendTapped()
        let submitted = await waitUntil { await harness.backend.callCount("prompt.submit") == 1 }
        XCTAssertTrue(submitted, "the send never reached the backend")
        await harness.backend.emit("message.start", sessionID: runtimeID,
                                   origin: ScriptedBackend.transportOrigin)
        await harness.backend.emit("subagent.start", sessionID: runtimeID,
                                   payload: Self.subagentPayload(id: "sa-ours", goal: "Our long job"))
        await harness.backend.emit("message.complete", sessionID: runtimeID, payload: .object([
            "text": .string("Dispatched."),
            "status": .string("complete"),
        ]))
        let settled = await waitUntil {
            !chat.live.isBusy && chat.live.activity.runningSubagents.count == 1
        }
        XCTAssertTrue(settled, "precondition: our turn settled, our agent is still running")

        XCTAssertTrue(try XCTUnwrap(chat.live.activity.runningSubagents.first).startedByThisClient)
        XCTAssertFalse(chat.isForeignStop, """
            a confirmation in front of every Stop over a background agent would train the \
            user to dismiss the one that matters
            """)

        await harness.tearDown()
    }

    // MARK: No row may be immortal

    /// **A row nothing can retire is the same bug in the other direction.**
    ///
    /// Two rows Stop cannot address: one whose frames never carried an id, and
    /// one queued behind the delegation limit that the per-id answer is not
    /// allowed to retire. Neither will ever receive a `subagent.complete`, and
    /// `pruneTerminalSubagents` only removes terminal rows — so if the idle
    /// sweep held them back too, `runningSubagents` would never empty,
    /// `isTurnActive` would never go false, and Stop would sit on the screen
    /// forever writing the same false explanation on every tap.
    ///
    /// Process-wide idleness is what clears them, and it is sound: if nothing is
    /// delegating anywhere then nothing is queued anywhere either.
    func testAnIdleBackendClearsEvenTheRowsStopCouldNotAddress() async throws {
        let harness = await AppHarness.make()
        try await harness.openSocket()
        let (chat, runtimeID) = try await openChat(harness, storedID: "20260815_101100_kill")
        await harness.backend.stub("subagent.interrupt") { _ in .object(["found": .bool(false)]) }
        await harness.backend.stub("delegation.status") { _ in .object(["active": .array([])]) }

        await harness.backend.emit("message.start", sessionID: runtimeID)
        // Started, and never named by the wire.
        await harness.backend.emit("subagent.start", sessionID: runtimeID,
                                   payload: Self.subagentPayload(id: nil, goal: "Nameless", taskIndex: 0))
        // Named, and never started.
        await harness.backend.emit("subagent.spawn_requested", sessionID: runtimeID,
                                   payload: Self.subagentPayload(id: "sa-queued", goal: "Queued", taskIndex: 1))
        await harness.backend.emit("message.complete", sessionID: runtimeID, payload: .object([
            "text": .string("Dispatched."), "status": .string("complete"),
        ]))
        let staged = await waitUntil {
            !chat.live.isBusy && chat.live.activity.runningSubagents.count == 2
        }
        XCTAssertTrue(staged, "precondition: one unnameable started row and one queued named row")

        chat.stopTapped()
        await waitForStopToSettle(chat)

        XCTAssertTrue(chat.live.activity.runningSubagents.isEmpty, """
            a row this Stop could not address, over a backend that has just proved it is not \
            delegating anything at all, is a dead row. Holding it back leaves the strip \
            claiming work forever with no event that can ever clear it
            """)
        XCTAssertFalse(chat.isTurnActive, "…so the Stop leaves the screen")
        XCTAssertNil(stopMessage(chat), """
            nothing is left to explain: the message is chosen from the roster AFTER the \
            reconcile, not from the counts sampled at the tap
            """)

        await harness.tearDown()
    }

    // MARK: What Stop must NOT do

    /// Cancelling an unacknowledged send is not a licence to take a fan-out down
    /// with it. The tap means "cancel my send"; the agents keep running, the
    /// strip keeps drawing them, and a second tap — which now lands in the kill
    /// branch — stops them.
    func testCancellingAnUnacknowledgedSendLeavesTheAgentsAlone() async throws {
        let harness = await AppHarness.make()
        try await harness.openSocket()
        let (chat, runtimeID) = try await openChat(harness, storedID: "20260815_100800_kill")
        await stubKillsSucceed(harness)
        await stageSettledTurnWithAgent(harness, runtimeID: runtimeID, chat: chat)

        await harness.backend.gate("prompt.submit")
        chat.draft = "and another thing"
        chat.sendTapped()
        let sending = await waitUntil { chat.sendPhase == .sending }
        XCTAssertTrue(sending, "precondition: a send is in flight and unacknowledged")

        chat.stopTapped()

        XCTAssertEqual(chat.sendPhase, .idle, "the send was cancelled, which is what this tap meant")
        // A bounded wait for the thing that must NOT happen. Reading the count
        // straight after the tap would only prove "no kill yet" — the kill
        // branch spawns a `Task`, which need not have run by then.
        _ = await waitUntil(timeout: 0.5) { chat.isStoppingAgents }
        _ = await waitUntil(timeout: 0.5) { await harness.backend.callCount("subagent.interrupt") > 0 }
        let kills = await harness.backend.callCount("subagent.interrupt")
        XCTAssertEqual(kills, 0, """
            taking a background fan-out down as a side effect of cancelling a send is \
            destructive and was not asked for
            """)
        XCTAssertEqual(chat.live.activity.runningSubagents.count, 1)
        XCTAssertTrue(chat.isTurnActive, "…so Stop is still on screen, and the next tap does kill them")

        await harness.backend.ungate("prompt.submit")
        await harness.backend.releaseParked()
        await harness.tearDown()
    }
}
