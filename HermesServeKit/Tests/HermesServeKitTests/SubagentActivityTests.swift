import XCTest

@testable import HermesServeKit

/// BUG-011 — the six `subagent.*` types, the registry they drive, and every
/// lifecycle row §4 of the implementation spec assigns to subagents.
///
/// Before this, the union projected all six to `.other`, `TurnEngine.apply`
/// hit `break`, and a multi-agent turn read as a bare "Working…" with no state,
/// no UI and no log. These tests are driven through `TurnEngine.apply` the way
/// the wire drives it, so the routing, the interrupt latch and the reducer are
/// all in the path rather than mocked around.
final class SubagentActivityTests: XCTestCase {
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

    /// One `subagent.*` frame. Every field past the phase is optional on the
    /// wire, so every field past the phase is optional here.
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

    private func rows(_ engine: TurnEngine) -> [SubagentRow] {
        engine.state(for: session).activity.subagents
    }

    /// The case a frame projected to, named, plus the phase its payload
    /// carries. Both, because the two are separate facts that must agree.
    private func caseAndPhase(_ event: HermesEvent) -> (name: String, phase: SubagentEvent.Phase)? {
        switch event {
        case .subagentSpawnRequested(let update): return ("spawnRequested", update.phase)
        case .subagentStart(let update): return ("start", update.phase)
        case .subagentThinking(let update): return ("thinking", update.phase)
        case .subagentTool(let update): return ("tool", update.phase)
        case .subagentProgress(let update): return ("progress", update.phase)
        case .subagentComplete(let update): return ("complete", update.phase)
        default: return nil
        }
    }

    // MARK: - Projection

    /// The case list in `HermesEvent.project` and `Phase`'s raw values are the
    /// same six strings written twice. This is what stops them drifting: every
    /// phase must project to the case of the same name, carrying itself.
    func testEveryRelayedTypeProjectsToItsOwnCase() throws {
        XCTAssertEqual(SubagentEvent.Phase.allCases.count, 6)
        for phase in SubagentEvent.Phase.allCases {
            let projected = HermesEvent.project(subagent(phase, id: "sa-1"))
            let pair = try XCTUnwrap(caseAndPhase(projected),
                                     "\(phase.rawValue) still projects to .other — it will be silently dropped")
            XCTAssertEqual(pair.name, String(describing: phase),
                           "\(phase.rawValue) projected to the .\(pair.name) case")
            XCTAssertEqual(pair.phase, phase)
        }
    }

    /// The two "do not touch" constraints, pinned so a future agent cannot
    /// quietly relax them. `turnScopedEventTypes` is the *unscoped-pinning*
    /// allowlist and adding subagent types to it resurrects exactly the
    /// misrouting its own tests exist to forbid.
    func testTheRelayedTypesAreNeitherPinnedNorFlushForcing() {
        for phase in SubagentEvent.Phase.allCases {
            XCTAssertFalse(
                HermesEvent.turnScopedEventTypes.contains(phase.rawValue),
                "\(phase.rawValue) must never join the unscoped-pinning allowlist"
            )
            XCTAssertFalse(
                HermesEvent.project(subagent(phase, id: "sa-1")).forcesFlush,
                "\(phase.rawValue) arrives in bursts; a forced flush per event is a per-event repaint"
            )
            XCTAssertFalse(HermesEvent.project(subagent(phase, id: "sa-1")).isUserVisibleInterrupt)
        }
    }

    /// The gateway's own comment says older emitters omit fields and clients
    /// must fall back to flat rendering. A frame carrying nothing at all still
    /// has to produce a row rather than throwing it away.
    func testAPayloadMissingEveryOptionalFieldStillProducesAUsableRow() throws {
        let engine = TurnEngine()
        drive(engine, [
            event("message.start"),
            event("subagent.start", payload: .object([:])),
        ])
        let row = try XCTUnwrap(rows(engine).first)
        XCTAssertEqual(rows(engine).count, 1)
        XCTAssertEqual(row.id, "root::", "no id, no parent, no index — the synthetic composite still resolves")
        XCTAssertEqual(row.state, .running)
        XCTAssertTrue(row.goal.isEmpty)
    }

    /// Coerced accessors, never a strict decode: the gateway emits ints and
    /// floats interchangeably and the payload header says so.
    func testNumbersDecodeAsIntsAndFloatsInterchangeably() throws {
        let asFloat = SubagentEvent(sessionID: session, phase: .progress, payload: .object([
            "task_index": .number(3.0), "task_count": .number(9.0),
            "tool_count": .number(4.0), "depth": .number(2.0),
            "duration_seconds": .number(12), "subagent_id": .number(77),
        ]))
        XCTAssertEqual(asFloat.taskIndex, 3)
        XCTAssertEqual(asFloat.taskCount, 9)
        XCTAssertEqual(asFloat.toolCount, 4)
        XCTAssertEqual(asFloat.depth, 2)
        XCTAssertEqual(try XCTUnwrap(asFloat.durationSeconds), 12, accuracy: 0.001)
        XCTAssertEqual(asFloat.subagentID, "77", "a numeric id still identifies a row")

        let asString = SubagentEvent(sessionID: session, phase: .progress, payload: .object([
            "tool_count": .string("6"), "duration_seconds": .string("1.5"),
        ]))
        XCTAssertEqual(asString.toolCount, 6)
        XCTAssertEqual(try XCTUnwrap(asString.durationSeconds), 1.5, accuracy: 0.001)
    }

    func testIdentityPrefersSubagentIdAndFallsBackToTheSyntheticComposite() {
        let withID = SubagentEvent(sessionID: session, phase: .start, payload: .object([
            "subagent_id": .string("sa-9"), "parent_id": .string("root-agent"),
            "task_index": .number(1), "goal": .string("Write it up"),
        ]))
        XCTAssertEqual(withID.identity, "sa-9", "a real id always wins")

        let withoutID = SubagentEvent(sessionID: session, phase: .start, payload: .object([
            "parent_id": .string("root-agent"), "task_index": .number(1),
            "goal": .string("Write it up"),
        ]))
        XCTAssertEqual(withoutID.identity, "root-agent:1:Write it up")

        let orphan = SubagentEvent(sessionID: session, phase: .start, payload: .object([
            "task_index": .number(0), "goal": .string("Write it up"),
        ]))
        XCTAssertEqual(orphan.identity, "root:0:Write it up", "no parent means root")
    }

    /// Each phase contributes at most one stream line, and the two spawn phases
    /// contribute none — their content is the goal, which is already the title.
    func testStreamLineIsDerivedPerPhase() {
        func line(_ phase: SubagentEvent.Phase, _ payload: [String: JSONValue]) -> String {
            SubagentEvent(sessionID: session, phase: phase, payload: .object(payload)).streamLine
        }
        XCTAssertEqual(line(.spawnRequested, ["goal": .string("G"), "text": .string("noise")]), "")
        XCTAssertEqual(line(.start, ["goal": .string("G")]), "")
        XCTAssertEqual(line(.thinking, ["text": .string("weighing it up")]), "weighing it up")
        XCTAssertEqual(line(.tool, ["tool_name": .string("read_file"), "tool_preview": .string("a.swift")]),
                       "read_file a.swift")
        XCTAssertEqual(line(.tool, ["tool_name": .string("read_file")]), "read_file",
                       "no preview is not a trailing space")
        XCTAssertEqual(line(.progress, ["output_tail": .string("tail wins when text is absent")]),
                       "tail wins when text is absent")
        XCTAssertEqual(line(.progress, ["text": .string("text first"), "output_tail": .string("tail")]),
                       "text first")
        XCTAssertEqual(line(.complete, ["summary": .string("done and dusted")]), "done and dusted")
        XCTAssertEqual(line(.progress, [:]), "", "a frame with nothing to say says nothing")
    }

    // MARK: - The wire shape end to end

    func testTheFanOutFixtureMaterializesBothAgentsAndSurvivesTurnEnd() throws {
        let engine = TurnEngine()
        for event in try Fixtures.events("subagent-lifecycle") { engine.apply(event) }
        engine.flush()

        let state = engine.state(for: session)
        let agents = state.activity.subagents
        XCTAssertEqual(agents.count, 2, "two agents were announced; `sa-ghost` announced nothing")
        XCTAssertNil(agents.first { $0.id == "sa-ghost" },
                     "a progress frame for an unknown id must not create a headless row")

        let audited = try XCTUnwrap(agents.first { $0.id == "sa-1" })
        XCTAssertEqual(audited.goal, "Audit the migration for dropped indexes")
        XCTAssertEqual(audited.state, .completed)
        XCTAssertEqual(audited.parentID, "root-agent")
        XCTAssertEqual(audited.childSessionID, "20260814_090000_child1")
        XCTAssertEqual(audited.model, "deepseek-v4-flash")
        XCTAssertEqual(audited.toolCount, 3)
        XCTAssertEqual(audited.taskIndex, 0)
        XCTAssertEqual(audited.taskCount, 2)
        XCTAssertEqual(audited.depth, 1)
        XCTAssertEqual(audited.summary, "Found two indexes missing from the down migration.")
        XCTAssertEqual(try XCTUnwrap(audited.durationSeconds), 12.5, accuracy: 0.001)
        XCTAssertEqual(audited.currentTool, "", "a finished agent is not running a tool")
        XCTAssertEqual(audited.stream, [
            "The schema dump is the place to start",
            "read_file db/schema.sql",
            "Two indexes are missing from the down migration",
            "Found two indexes missing from the down migration.",
        ], "thinking, tool, progress and the closing summary — in wire order, whitespace collapsed")

        // The second agent carried no `subagent_id` at all and is identified by
        // the synthetic composite.
        let notes = try XCTUnwrap(agents.first { $0.id == "root-agent:1:Draft the release notes" })
        XCTAssertEqual(notes.state, .running)
        XCTAssertEqual(notes.currentTool, "write_file")

        XCTAssertFalse(state.isBusy, "message.complete ended the parent turn")
        XCTAssertEqual(state.activity.runningSubagents.count, 1,
                       "the running agent outlives the turn that spawned it")
        XCTAssertTrue(state.entries.compactMap(\.tool).isEmpty,
                      "subagent frames materialise no transcript tool cards")
    }

    /// **The status trap, at the reducer.** Desktop's mapper falls through
    /// anything unrecognised to `running`, so a timed-out agent never becomes
    /// terminal, never prunes and spins forever above the composer.
    func testACompletionIsTerminalWhateverTheStatusStringSays() throws {
        for status in ["timeout", "error", "", "who knows", "queued"] {
            let engine = TurnEngine()
            drive(engine, [
                event("message.start"),
                subagent(.start, id: "sa-1"),
                subagent(.complete, id: "sa-1", extra: ["status": .string(status)]),
            ])
            let row = try XCTUnwrap(rows(engine).first)
            XCTAssertEqual(row.state, .failed, "status '\(status)' must land on failed, never running")
            XCTAssertTrue(row.isTerminal)
        }

        // …and a completion with no `status` key at all is still terminal.
        let engine = TurnEngine()
        drive(engine, [
            event("message.start"),
            subagent(.start, id: "sa-1"),
            subagent(.complete, id: "sa-1"),
        ])
        XCTAssertEqual(try XCTUnwrap(rows(engine).first).state, .failed)

        // The happy paths still map where they should.
        for (status, expected) in [("completed", SubagentRow.State.completed),
                                   ("interrupted", .interrupted),
                                   ("cancelled", .interrupted)] {
            let engine = TurnEngine()
            drive(engine, [
                event("message.start"),
                subagent(.start, id: "sa-1"),
                subagent(.complete, id: "sa-1", extra: ["status": .string(status)]),
            ])
            XCTAssertEqual(try XCTUnwrap(rows(engine).first).state, expected)
        }
    }

    // MARK: - The registry

    /// Partial frames are the norm, so a frame that omitted a field must leave
    /// what an earlier frame established rather than blanking it.
    func testUpsertMergesPerFieldAndNeverBlanksWhatAFrameOmitted() throws {
        let engine = TurnEngine()
        drive(engine, [
            event("message.start"),
            subagent(.start, id: "sa-1", goal: "Read the spec", parent: "root-agent",
                     extra: ["model": .string("deepseek-v4-flash"), "depth": .number(2)]),
            // A bare progress frame: no model, no depth, no parent, no goal.
            event("subagent.progress", payload: .object([
                "subagent_id": .string("sa-1"),
                "text": .string("still reading"),
            ])),
        ])

        let row = try XCTUnwrap(rows(engine).first)
        XCTAssertEqual(rows(engine).count, 1, "the second frame updated the row rather than adding one")
        XCTAssertEqual(row.goal, "Read the spec", "an omitted goal is not an empty goal")
        XCTAssertEqual(row.model, "deepseek-v4-flash")
        XCTAssertEqual(row.parentID, "root-agent")
        XCTAssertEqual(row.depth, 2)
        XCTAssertEqual(row.stream, ["still reading"])
    }

    /// `display.tool_progress` can be switched to `off` mid-flight, cutting a
    /// lifecycle in half at an arbitrary point. Half a lifecycle is not an agent.
    func testAFrameForAnUnknownIdIsDiscardedRatherThanCreatingAHeadlessRow() {
        for phase in SubagentEvent.Phase.allCases where !phase.createsRow {
            let engine = TurnEngine()
            drive(engine, [event("message.start"), subagent(phase, id: "sa-unknown")])
            XCTAssertTrue(rows(engine).isEmpty,
                          "\(phase.rawValue) for an unannounced id created a row")
        }
        for phase in SubagentEvent.Phase.allCases where phase.createsRow {
            let engine = TurnEngine()
            drive(engine, [event("message.start"), subagent(phase, id: "sa-new")])
            XCTAssertEqual(rows(engine).count, 1, "\(phase.rawValue) must materialise a row")
        }
    }

    /// A row that flipped back to `running` would never prune at the next
    /// `message.start`, so the strip would never empty.
    func testATerminalRowFreezesAgainstLateEvents() throws {
        let engine = TurnEngine()
        drive(engine, [
            event("message.start"),
            subagent(.start, id: "sa-1", goal: "Read the spec"),
            subagent(.complete, id: "sa-1", extra: [
                "status": .string("completed"),
                "summary": .string("the real outcome"),
            ]),
            // Everything a late or reordered frame could try.
            subagent(.progress, id: "sa-1", extra: ["text": .string("a late progress line")]),
            subagent(.tool, id: "sa-1", extra: ["tool_name": .string("read_file")]),
            subagent(.thinking, id: "sa-1", extra: ["text": .string("more thoughts")]),
            subagent(.complete, id: "sa-1", extra: [
                "status": .string("failed"),
                "summary": .string("a second, contradictory outcome"),
            ]),
        ])

        let row = try XCTUnwrap(rows(engine).first)
        XCTAssertEqual(row.state, .completed, "a finished agent cannot be revived, or re-failed")
        XCTAssertEqual(row.summary, "the real outcome")
        XCTAssertEqual(row.currentTool, "")
        XCTAssertEqual(row.stream.last, "the real outcome", "nothing appended after the freeze")
    }

    /// A fan-out where no agent carries an id is the case that collapses four
    /// agents into one row when identity is wrong.
    func testAgentsWithoutIdsDoNotCollapseIntoOneRow() {
        let engine = TurnEngine()
        var events: [GatewayEvent] = [event("message.start")]
        for index in 0..<4 {
            events.append(subagent(.spawnRequested, id: nil, goal: "Task \(index)",
                                   parent: "root-agent", taskIndex: index))
        }
        drive(engine, events)
        XCTAssertEqual(rows(engine).count, 4)
        XCTAssertEqual(rows(engine).map(\.id), [
            "root-agent:0:Task 0", "root-agent:1:Task 1",
            "root-agent:2:Task 2", "root-agent:3:Task 3",
        ])
    }

    /// A cumulative counter that ticks backwards reads as a bug in the agent
    /// rather than in the client.
    func testToolCountIsMergedMonotonically() throws {
        let engine = TurnEngine()
        drive(engine, [
            event("message.start"),
            subagent(.start, id: "sa-1"),
            subagent(.progress, id: "sa-1", extra: ["tool_count": .number(7)]),
            subagent(.progress, id: "sa-1", extra: ["tool_count": .number(2)]),
        ])
        XCTAssertEqual(try XCTUnwrap(rows(engine).first).toolCount, 7)
    }

    /// The unscoped drop is correct, tested elsewhere, and must stay that way:
    /// background work must never attach to whatever chat is focused. Typing
    /// the six events changed the projection, not the routing.
    func testUnscopedSubagentFramesAreStillDropped() {
        let engine = TurnEngine()
        engine.apply(event("message.start"))
        let unscoped = GatewayEvent(
            type: "subagent.start",
            sessionID: "",
            payload: .object(["subagent_id": .string("sa-1"), "goal": .string("Ghost")]),
            params: .object(["type": .string("subagent.start")])
        )
        XCTAssertNil(engine.apply(unscoped), "an unscoped subagent frame routes nowhere")
        engine.flush()
        XCTAssertTrue(rows(engine).isEmpty)
    }

    // MARK: - Lifecycle

    /// The row that makes subagents different from todos, in one test.
    func testMessageStartPrunesTerminalRowsAndKeepsRunningOnes() {
        let engine = TurnEngine()
        drive(engine, [
            event("message.start"),
            subagent(.start, id: "sa-done", goal: "Finished work"),
            subagent(.start, id: "sa-live", goal: "Ongoing work"),
            subagent(.complete, id: "sa-done", extra: ["status": .string("completed")]),
            event("message.complete", payload: .object(["status": .string("complete")])),
        ])
        XCTAssertEqual(rows(engine).count, 2, "turn end leaves subagents alone — both kinds")

        drive(engine, [event("message.start")])
        XCTAssertEqual(rows(engine).map(\.id), ["sa-live"],
                       "the next turn retires what finished and keeps what is still working")
    }

    /// The asymmetry stated as one assertion: at the same instant, an active
    /// checklist is stale and a running agent is not.
    func testTurnEndDropsAnActiveTodoListWhileKeepingARunningSubagent() {
        let engine = TurnEngine()
        let items: JSONValue = .array([.object([
            "id": .string("1"), "content": .string("Still going"), "status": .string("in_progress"),
        ])])
        drive(engine, [
            event("message.start"),
            event("tool.complete", payload: .object([
                "tool_id": .string("call_todo"), "name": .string("todo"), "todos": items,
            ])),
            subagent(.start, id: "sa-1", goal: "Background work"),
            event("message.complete", payload: .object(["status": .string("complete")])),
        ])
        let activity = engine.state(for: session).activity
        XCTAssertTrue(activity.todos.isEmpty, "an unfinished plan the agent abandoned is stale")
        XCTAssertEqual(activity.subagents.count, 1, "a running agent is not")
        XCTAssertEqual(activity.subagents.first?.state, .running)
    }

    func testAnErrorEventAndASettleFromStatusBothLeaveSubagentsAlone() {
        let engine = TurnEngine()
        drive(engine, [
            event("message.start"),
            subagent(.start, id: "sa-1", goal: "Background work"),
            event("error", payload: .object(["message": .string("agent init failed")])),
        ])
        XCTAssertEqual(rows(engine).count, 1, "an error on the parent says nothing about the children")

        let other = TurnEngine()
        drive(other, [event("message.start"), subagent(.start, id: "sa-1")])
        other.settleFromStatus(sessionID: session)
        XCTAssertEqual(other.state(for: session).activity.subagents.count, 1)
    }

    /// Stop means everything stops. A row left spinning over the composer after
    /// the user pressed Stop says otherwise.
    func testStopClearsSubagentsUnconditionally() {
        let engine = TurnEngine()
        drive(engine, [
            event("message.start"),
            subagent(.start, id: "sa-live"),
            subagent(.start, id: "sa-done", goal: "Other"),
            subagent(.complete, id: "sa-done", extra: ["status": .string("completed")]),
        ])
        XCTAssertEqual(rows(engine).count, 2)

        engine.markInterrupted(sessionID: session)
        XCTAssertTrue(engine.state(for: session).activity.isEmpty, "running and finished alike")
    }

    /// The latch has to cover this reducer too, or the cancelled turn's
    /// subagent tail repopulates the strip the user just cleared — with rows
    /// whose `complete` was cancelled along with the turn, so they never prune.
    func testTheInterruptLatchSwallowsLateSubagentFrames() {
        let engine = TurnEngine()
        drive(engine, [event("message.start"), subagent(.start, id: "sa-1")])
        engine.markInterrupted(sessionID: session)

        drive(engine, [
            subagent(.spawnRequested, id: "sa-2", goal: "A stale spawn"),
            subagent(.start, id: "sa-2", goal: "A stale spawn"),
            subagent(.progress, id: "sa-1", extra: ["text": .string("a stale line")]),
        ])
        XCTAssertTrue(rows(engine).isEmpty, "nothing gets back in while the latch holds")
    }

    func testRebindCarriesSubagentsAndResetAndForgetFreeThem() {
        let engine = TurnEngine()
        drive(engine, [event("message.start"), subagent(.start, id: "sa-1", goal: "Work")])

        engine.rebind(from: session, to: "new-runtime-id")
        XCTAssertTrue(engine.state(for: session).activity.isEmpty)
        XCTAssertEqual(engine.state(for: "new-runtime-id").activity.subagents.count, 1)

        engine.reset(sessionID: "new-runtime-id")
        XCTAssertTrue(engine.state(for: "new-runtime-id").activity.isEmpty)

        drive(engine, [event("message.start"), subagent(.start, id: "sa-1", goal: "Work")])
        engine.forget(sessionID: session)
        XCTAssertTrue(engine.state(for: session).activity.isEmpty)
    }

    /// v1 is live-only for both halves of the surface. A resume shows no agents
    /// until the wire says otherwise, which is honest.
    func testResumeNeverRehydratesSubagents() throws {
        let engine = TurnEngine()
        let result = SessionAPI.decodeResume(
            try Fixtures.result("response-session-resume-inflight"),
            requested: "20260731_170500_ab12ef"
        )
        engine.applyResumeProjection(sessionID: result.sessionID, result: result, trailingUserTexts: [])
        XCTAssertTrue(engine.state(for: result.sessionID).activity.subagents.isEmpty)
    }

    func testReplaceEntriesLeavesSubagentsAlone() {
        let engine = TurnEngine()
        drive(engine, [event("message.start"), subagent(.start, id: "sa-1", goal: "Work")])
        engine.replaceEntries(sessionID: session, with: [
            ChatEntry(id: "history-1", kind: .user, text: "hello"),
        ])
        XCTAssertEqual(rows(engine).count, 1)
    }

    /// **The BUG-011 quiescence decision, pinned.**
    ///
    /// The bug report asked for a running subagent to hold a session
    /// non-quiescent so a popped chat is retained while its agents work. It is
    /// deliberately NOT implemented: a row leaves `running` only when a
    /// `subagent.complete` arrives, and nothing guarantees one does —
    /// `display.tool_progress: off` suppresses all six types mid-flight, and the
    /// engine is timer-free so it cannot expire a stuck row. One orphaned row
    /// would pin a whole `SessionTurnState` for the life of the process, once
    /// per session and with no ceiling. That is BUG-004's exact shape.
    ///
    /// If this assertion is ever inverted, that trade has to be re-argued.
    func testARunningSubagentDoesNotBlockQuiescence() {
        let engine = TurnEngine()
        drive(engine, [
            event("message.start"),
            subagent(.start, id: "sa-1", goal: "Background work"),
            event("message.complete", payload: .object(["status": .string("complete")])),
        ])
        XCTAssertEqual(engine.state(for: session).activity.runningSubagents.count, 1)
        XCTAssertTrue(engine.isQuiescent(sessionID: session),
                      "activity is derived display state; it must never hold a session against the sweep")
    }

    // MARK: - Elapsed

    func testElapsedPrefersTheWiresOwnDurationAndFreezesWhenTerminal() {
        let start = Date(timeIntervalSince1970: 1_000)
        var row = SubagentRow(id: "sa-1", startedAt: start)
        XCTAssertEqual(row.elapsed(now: start.addingTimeInterval(30)), 30, accuracy: 0.001)

        row.durationSeconds = 12.5
        XCTAssertEqual(row.elapsed(now: start.addingTimeInterval(30)), 12.5, accuracy: 0.001,
                       "the backend's own measurement wins over wall time")

        var frozen = SubagentRow(id: "sa-2", startedAt: start)
        frozen.state = .completed
        frozen.updatedAt = start.addingTimeInterval(5)
        XCTAssertEqual(frozen.elapsed(now: start.addingTimeInterval(9_999)), 5, accuracy: 0.001,
                       "a finished agent stops counting up instead of ageing on screen forever")
    }

    // MARK: - Growth

    /// A thousand agents, each flooding stream lines far past every cap, with
    /// oversized goals, models and tool names. Nothing may grow without bound —
    /// this is the cheapest possible insurance against a BUG-004 repeat.
    func testAFloodOfSubagentEventsDoesNotGrowTheState() {
        let engine = TurnEngine()
        let long = String(repeating: "x", count: 900)
        engine.apply(event("message.start"))
        for index in 0..<1_000 {
            engine.apply(subagent(.spawnRequested, id: "sa-\(index)", goal: long))
            engine.apply(subagent(.start, id: "sa-\(index)", goal: long,
                                  extra: ["model": .string(long)]))
            for line in 0..<10 {
                engine.apply(subagent(.thinking, id: "sa-\(index)",
                                      extra: ["text": .string("\(long) \(line)")]))
                engine.apply(subagent(.tool, id: "sa-\(index)",
                                      extra: ["tool_name": .string("\(long)\(line)")]))
            }
        }
        engine.flush()

        let state = engine.state(for: session)
        XCTAssertEqual(state.activity.subagents.count, SessionActivity.subagentLimit)
        for row in state.activity.subagents {
            XCTAssertLessThanOrEqual(row.goal.count, SessionActivity.subagentTextLimit)
            XCTAssertLessThanOrEqual(row.summary.count, SessionActivity.subagentTextLimit)
            XCTAssertLessThanOrEqual(row.model.count, SessionActivity.subagentLabelLimit)
            XCTAssertLessThanOrEqual(row.currentTool.count, SessionActivity.subagentLabelLimit)
            XCTAssertLessThanOrEqual(row.stream.count, SessionActivity.streamLimit)
            XCTAssertTrue(row.stream.allSatisfy { $0.count <= SessionActivity.streamLineLimit })
        }
        XCTAssertTrue(state.entries.isEmpty, "22,000 subagent frames are not 22,000 transcript rows")
    }

    /// The overflow rule spends finished agents first — the cheapest thing to
    /// forget — and only then the oldest row of any kind. Driven through the
    /// wire rather than by appending, so the reducer's own barrier is what is
    /// under test.
    func testOverflowDropsFinishedAgentsBeforeRunningOnes() {
        let engine = TurnEngine()
        engine.apply(event("message.start"))
        // 32 finished agents fill the roster exactly.
        for index in 0..<SessionActivity.subagentLimit {
            engine.apply(subagent(.start, id: "done-\(index)", goal: "Finished \(index)"))
            engine.apply(subagent(.complete, id: "done-\(index)",
                                  extra: ["status": .string("completed")]))
        }
        XCTAssertEqual(rows(engine).count, SessionActivity.subagentLimit)

        // Eight more, all running: the finished ones are what gets spent.
        for index in 0..<8 {
            engine.apply(subagent(.start, id: "live-\(index)", goal: "Running \(index)"))
        }
        engine.flush()

        XCTAssertEqual(rows(engine).count, SessionActivity.subagentLimit)
        XCTAssertEqual(rows(engine).filter { !$0.isTerminal }.count, 8,
                       "every running agent survived")
        XCTAssertNil(rows(engine).first { $0.id == "done-0" }, "the oldest finished row went first")
    }
}
