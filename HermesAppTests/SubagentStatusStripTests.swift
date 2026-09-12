import HermesServeKit
import XCTest

@testable import HermesMobile

/// BUG-011 — when a session delegated work to subagents the phone showed
/// **nothing**: the events arrived on the parent session id, projected to
/// `.other`, and were dropped with no state, no UI and no log. A multi-agent
/// turn read as a bare "Working…".
///
/// The strip is a view and this target has no UI tests, so what is asserted
/// here is the state the view renders: that the six relayed events reach the
/// open chat's `live.activity` through the real `AppModel` publish funnel rather
/// than only inside the engine, that the retention rules hold end to end, and
/// that the pure tree/formatting functions the sheet draws behave on the
/// malformed input nobody can produce by tapping around.
final class SubagentStatusStripTests: XCTestCase {

    // MARK: Wire helpers

    private static func subagentPayload(
        id: String? = nil,
        goal: String,
        parent: String? = nil,
        index: Int = 0,
        count: Int = 2,
        extra: [String: JSONValue] = [:]
    ) -> JSONValue {
        var payload: [String: JSONValue] = [
            "goal": .string(goal),
            "task_index": .number(Double(index)),
            "task_count": .number(Double(count)),
        ]
        if let id { payload["subagent_id"] = .string(id) }
        if let parent { payload["parent_id"] = .string(parent) }
        for (key, value) in extra { payload[key] = value }
        return .object(payload)
    }

    @MainActor
    private func openChat(_ harness: AppHarness, storedID: String) async throws -> (ChatModel, String) {
        let chat = harness.chat(storedID: storedID)
        await chat.open()
        let bound = await waitUntil { chat.runtimeSessionID != nil }
        XCTAssertTrue(bound, "open() never bound a runtime id — nothing after this proves anything")
        return (chat, try XCTUnwrap(chat.runtimeSessionID))
    }

    // MARK: - The bug

    /// The whole point of the report: a fan-out has to arrive somewhere the
    /// strip can draw it.
    @MainActor
    func testDelegatedAgentsReachTheOpenChatsActivity() async throws {
        let harness = await AppHarness.make()
        try await harness.openSocket()
        let (chat, runtimeID) = try await openChat(harness, storedID: "20260814_020000_sub")

        await harness.backend.emit("message.start", sessionID: runtimeID)
        await harness.backend.emit("subagent.spawn_requested", sessionID: runtimeID,
                                   payload: Self.subagentPayload(id: "sa-1", goal: "Audit the migration",
                                                                 parent: "root-agent", index: 0))
        await harness.backend.emit("subagent.start", sessionID: runtimeID,
                                   payload: Self.subagentPayload(id: "sa-1", goal: "Audit the migration",
                                                                 parent: "root-agent", index: 0,
                                                                 extra: ["model": .string("deepseek-v4-flash")]))
        // The second agent carries NO id — identity falls back to the synthetic
        // composite, and getting that wrong collapses a fan-out into one row.
        await harness.backend.emit("subagent.start", sessionID: runtimeID,
                                   payload: Self.subagentPayload(goal: "Draft the release notes",
                                                                 parent: "root-agent", index: 1))
        await harness.backend.emit("subagent.tool", sessionID: runtimeID,
                                   payload: Self.subagentPayload(id: "sa-1", goal: "Audit the migration",
                                                                 extra: ["tool_name": .string("read_file"),
                                                                         "tool_count": .number(1)]))

        // Poll on the LAST thing emitted, not the first. `subagents.count == 2`
        // goes true the moment the second `start` lands, which is before the
        // `tool` frame behind it has been applied — a predicate that stops
        // short reads a half-applied roster and fails intermittently.
        let arrived = await waitUntil {
            chat.live.activity.subagents.count == 2
                && chat.live.activity.subagents.first?.currentTool == "read_file"
        }
        XCTAssertTrue(arrived, """
            the delegated agents never reached ChatModel.live.activity — the strip has \
            nothing to draw, which is exactly the reported bug. Rows now: \
            \(chat.live.activity.subagents.map { "\($0.id)/\($0.currentTool)" })
            """)

        let agents = chat.live.activity.subagents
        XCTAssertEqual(agents.map(\.id), ["sa-1", "root-agent:1:Draft the release notes"])
        XCTAssertEqual(agents.first?.goal, "Audit the migration")
        XCTAssertEqual(agents.first?.model, "deepseek-v4-flash")
        XCTAssertEqual(agents.first?.currentTool, "read_file")
        XCTAssertEqual(agents.first?.toolCount, 1)
        XCTAssertTrue(agents.allSatisfy { $0.state == .running })
        XCTAssertEqual(chat.live.activity.runningSubagents.count, 2)
        XCTAssertFalse(chat.live.activity.isEmpty, "…and the strip's own visibility gate opens")

        await harness.tearDown()
    }

    /// The retention asymmetry, end to end. A background agent legitimately
    /// outlives the turn that spawned it, so turn end keeps it and only the
    /// next turn retires what has actually finished.
    @MainActor
    func testARunningAgentOutlivesItsTurnAndFinishedOnesRetireAtTheNextTurn() async throws {
        let harness = await AppHarness.make()
        try await harness.openSocket()
        let (chat, runtimeID) = try await openChat(harness, storedID: "20260814_020100_sub")

        await harness.backend.emit("message.start", sessionID: runtimeID)
        await harness.backend.emit("subagent.start", sessionID: runtimeID,
                                   payload: Self.subagentPayload(id: "sa-done", goal: "Finished work"))
        await harness.backend.emit("subagent.start", sessionID: runtimeID,
                                   payload: Self.subagentPayload(id: "sa-live", goal: "Ongoing work", index: 1))
        await harness.backend.emit("subagent.complete", sessionID: runtimeID,
                                   payload: Self.subagentPayload(id: "sa-done", goal: "Finished work",
                                                                 extra: ["status": .string("completed"),
                                                                         "summary": .string("All clear."),
                                                                         "duration_seconds": .number(4)]))
        let arrived = await waitUntil { chat.live.activity.subagents.count == 2 }
        XCTAssertTrue(arrived, "the agents never arrived")

        await harness.backend.emit("message.complete", sessionID: runtimeID, payload: .object([
            "text": .string("The audit is done; the notes agent is still running."),
            "status": .string("complete"),
        ]))
        let settled = await waitUntil { !chat.live.isBusy }
        XCTAssertTrue(settled, "the turn never settled")
        XCTAssertEqual(chat.live.activity.subagents.count, 2, """
            turn end must leave subagents alone — a background agent outlives the turn \
            that spawned it, which is the deliberate opposite of the todo rule
            """)
        XCTAssertEqual(chat.live.activity.runningSubagents.map(\.id), ["sa-live"])

        await harness.backend.emit("message.start", sessionID: runtimeID)
        let pruned = await waitUntil { chat.live.activity.subagents.count == 1 }
        XCTAssertTrue(pruned, "the next turn starting is what retires a finished agent")
        XCTAssertEqual(chat.live.activity.subagents.first?.id, "sa-live",
                       "…and it must keep the one still working")

        await harness.tearDown()
    }

    /// **The desktop bug this client must not copy**, through the whole stack.
    /// Desktop's status mapper falls through anything unrecognised to
    /// `running`, so an agent that ends with `status: "timeout"` never becomes
    /// terminal, never prunes, and spins over the composer forever.
    @MainActor
    func testATimedOutAgentBecomesTerminalRatherThanSpinningForever() async throws {
        let harness = await AppHarness.make()
        try await harness.openSocket()
        let (chat, runtimeID) = try await openChat(harness, storedID: "20260814_020200_sub")

        await harness.backend.emit("message.start", sessionID: runtimeID)
        await harness.backend.emit("subagent.start", sessionID: runtimeID,
                                   payload: Self.subagentPayload(id: "sa-1", goal: "Never finishes"))
        await harness.backend.emit("subagent.complete", sessionID: runtimeID,
                                   payload: Self.subagentPayload(id: "sa-1", goal: "Never finishes",
                                                                 extra: ["status": .string("timeout")]))

        let terminal = await waitUntil { chat.live.activity.subagents.first?.isTerminal == true }
        XCTAssertTrue(terminal, """
            an agent that ended with status 'timeout' is still rendering as running. \
            It will never prune at the next message.start and the strip will never empty.
            """)
        XCTAssertEqual(chat.live.activity.subagents.first?.state, .failed,
                       "unrecognised means failed, never running")
        XCTAssertTrue(chat.live.activity.runningSubagents.isEmpty)

        // …and the next turn actually retires it, which is the consequence that
        // matters and the thing desktop never reaches.
        await harness.backend.emit("message.start", sessionID: runtimeID)
        let retired = await waitUntil { chat.live.activity.subagents.isEmpty }
        XCTAssertTrue(retired, "a timed-out agent must prune like any other finished one")

        await harness.tearDown()
    }

    /// **The BUG-011 quiescence decision, pinned at the app layer.**
    ///
    /// The report asked for running subagents to hold a popped chat in memory.
    /// It is deliberately not implemented, here or in the kit: a row leaves
    /// `running` only when a `subagent.complete` arrives, nothing guarantees one
    /// does (`display.tool_progress: off` suppresses all six types mid-flight),
    /// and the engine is timer-free so it cannot expire a stuck row. One
    /// orphaned row would pin a whole `ChatModel` — transcript, outbound roster
    /// and image bitmaps — for the life of the process. That is BUG-004's exact
    /// shape, traded for a display refinement.
    ///
    /// If this assertion is ever inverted, that trade has to be re-argued.
    @MainActor
    func testAPoppedChatWithRunningAgentsIsStillReleased() async throws {
        let harness = await AppHarness.make()
        try await harness.openSocket()
        let (chat, runtimeID) = try await openChat(harness, storedID: "20260814_020300_sub")
        chat.errorMessage = nil

        await harness.backend.emit("message.start", sessionID: runtimeID)
        await harness.backend.emit("subagent.start", sessionID: runtimeID,
                                   payload: Self.subagentPayload(id: "sa-live", goal: "Long background job"))
        await harness.backend.emit("message.complete", sessionID: runtimeID, payload: .object([
            "text": .string("Kicked it off."),
            "status": .string("complete"),
        ]))
        let ready = await waitUntil {
            !chat.live.isBusy && chat.live.activity.runningSubagents.count == 1
        }
        XCTAssertTrue(ready, "precondition: an idle turn with one agent still running")
        XCTAssertTrue(harness.app.engine.isQuiescent(sessionID: runtimeID),
                      "the kit must not let display state hold a session against the sweep")

        // The route pops.
        harness.app.releaseChats(keeping: [])

        XCTAssertNil(harness.app.chat(runtimeSessionID: runtimeID),
                     "a running subagent must not pin a popped chat in memory")
        XCTAssertFalse(harness.app.engine.trackedSessionIDs.contains(runtimeID),
                       "…nor the engine state beside it")

        await harness.tearDown()
    }

    // MARK: - The tree the sheet draws

    /// `parent_id` is the only edge on the wire — there is no children array —
    /// and a `parent_id` naming an agent that is not itself in the roster is the
    /// common case, not an error.
    func testTheTreeIsBuiltFromParentIdAndFlattensDepthFirst() {
        let rows = [
            SubagentRow(id: "a", goal: "Root A", parentID: "session-agent"),
            SubagentRow(id: "b", goal: "Child of A", parentID: "a"),
            SubagentRow(id: "c", goal: "Grandchild", parentID: "b"),
            SubagentRow(id: "d", goal: "Root D"),
        ]
        let tree = SubagentTree.build(from: rows)
        XCTAssertEqual(tree.map(\.id), ["a", "d"],
                       "a parent that is not a row in the roster is the session's own agent — its children are roots")
        XCTAssertEqual(tree.first?.children.map(\.id), ["b"])
        XCTAssertEqual(tree.first?.children.first?.children.map(\.id), ["c"])

        let flat = SubagentTree.flatten(tree)
        XCTAssertEqual(flat.map(\.node.id), ["a", "b", "c", "d"], "depth first")
        XCTAssertEqual(flat.map(\.level), [0, 1, 2, 0])
    }

    /// A cycle leaves every row claimed as somebody's child and no roots at all.
    /// Rendering nothing would be the worst outcome; flat is what the gateway's
    /// own comment tells clients to fall back to.
    func testACycleFallsBackToFlatRatherThanRenderingNothing() {
        let rows = [
            SubagentRow(id: "a", goal: "A", parentID: "b"),
            SubagentRow(id: "b", goal: "B", parentID: "a"),
        ]
        let tree = SubagentTree.build(from: rows)
        XCTAssertEqual(tree.count, 2, "a cycle must not render as an empty sheet")
        XCTAssertTrue(tree.allSatisfy { $0.children.isEmpty })

        // Self-parenting is the degenerate case of the same thing.
        let selfParented = SubagentTree.build(from: [SubagentRow(id: "a", goal: "A", parentID: "a")])
        XCTAssertEqual(selfParented.map(\.id), ["a"])
        XCTAssertTrue(selfParented.first?.children.isEmpty == true)

        XCTAssertTrue(SubagentTree.build(from: []).isEmpty)
    }

    func testElapsedLabelNeverShowsARawFloat() {
        XCTAssertEqual(SubagentTree.elapsedLabel(0), "0s")
        XCTAssertEqual(SubagentTree.elapsedLabel(12.499999), "12s")
        XCTAssertEqual(SubagentTree.elapsedLabel(59.4), "59s")
        XCTAssertEqual(SubagentTree.elapsedLabel(60), "1m 00s")
        XCTAssertEqual(SubagentTree.elapsedLabel(184), "3m 04s")
        XCTAssertEqual(SubagentTree.elapsedLabel(3_600), "1h 00m")
        XCTAssertEqual(SubagentTree.elapsedLabel(4_320), "1h 12m")
        XCTAssertEqual(SubagentTree.elapsedLabel(-5), "0s", "a clock skew is not a negative duration")
    }

    // MARK: BUG-014 — the header fraction

    /// The agent header used to pass `running.count`, so the number COUNTED
    /// DOWN as agents landed — 3 → 2 → 1 — with no denominator, then jumped
    /// back to the total when the last one finished. This walks a three-agent
    /// roster through every landing and asserts the fraction only ever climbs.
    func testTheAgentFractionClimbsRatherThanCountingDown() {
        var rows = [
            SubagentRow(id: "a", goal: "A"),
            SubagentRow(id: "b", goal: "B"),
            SubagentRow(id: "c", goal: "C"),
        ]
        XCTAssertEqual(StripProgress.agents(rows), "0/3", "nothing has landed yet")

        var seen = [StripProgress.agents(rows)]
        for index in rows.indices {
            rows[index].state = .completed
            seen.append(StripProgress.agents(rows))
        }
        XCTAssertEqual(seen, ["0/3", "1/3", "2/3", "3/3"])

        // The old `running.count` sequence was 3, 2, 1, 3. The numerator here
        // is monotonically non-decreasing, which is the property that matters.
        let numerators = seen.map { Int($0.split(separator: "/")[0])! }
        XCTAssertEqual(numerators, numerators.sorted(), "a progress count must never go backwards")
    }

    /// Every terminal state counts as landed, not just the happy one — a failed
    /// or interrupted agent is no longer work in flight, and leaving it out of
    /// the numerator would strand the header at `2/3` forever.
    func testEveryTerminalStateCountsTowardTheAgentFraction() {
        let rows = [
            SubagentRow(id: "a", goal: "A", state: .completed),
            SubagentRow(id: "b", goal: "B", state: .failed),
            SubagentRow(id: "c", goal: "C", state: .interrupted),
            SubagentRow(id: "d", goal: "D", state: .running),
        ]
        XCTAssertEqual(StripProgress.agents(rows), "3/4")
        XCTAssertEqual(StripProgress.agents([]), "0/0", "an empty roster does not divide by anything")
    }
}
