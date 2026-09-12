import Foundation
import HermesServeKit
import XCTest

@testable import HermesMobile

/// BUG-032 — the Command Center's per-row Interrupt was a bare
/// `session.interrupt`: one tap, no confirmation, no ownership question, no
/// optimistic finalise, no interrupt latch, no publish, and no reach into
/// delegated agents. The app admits the divergence in three separate places
/// (`ChatView`'s numbered list, `ForeignStopConfirmation`'s contract, and a
/// commit message) and none of them was filed until BUG-032.
///
/// **The shipped defect was not observable from any test target this repo has.**
/// It lived in a `private func` inside a SwiftUI `View`; `HermesAppTests` has no
/// UI tests and asserts on the model a view renders; and `HermesUITests` cannot
/// reach the session list, which loads from `sessionAPI.activeList()` behind a
/// screenshot route with no backend. That unreachability was itself part of the
/// defect, and lifting the routing out of the view is what removes it.
@MainActor
final class CommandCenterStopRoutingTests: XCTestCase {

    private static let foreignOrigin = "desktop-transport-9"

    private static func subagentPayload(id: String, goal: String) -> JSONValue {
        .object([
            "subagent_id": .string(id),
            "goal": .string(goal),
            "task_index": .number(0),
            "task_count": .number(1),
        ])
    }

    /// A busy session on this socket that no chat on this phone owns — the
    /// Command Center's ordinary row.
    private func stageUnattendedForeignSession(
        _ harness: AppHarness,
        sessionID: String
    ) async -> Bool {
        await harness.backend.emit(
            "message.start", sessionID: sessionID, origin: Self.foreignOrigin
        )
        return await waitUntil { harness.app.engine.state(for: sessionID).isBusy }
    }

    // MARK: T1 — the unknowable case asks

    func testAnUnattendedLiveSessionRequiresConfirmationBeforeItIsStopped() async throws {
        let harness = await AppHarness.make()
        await harness.backend.setSessionMirroring(true)
        try await harness.openSocket()

        let staged = await stageUnattendedForeignSession(harness, sessionID: "rt-desktop")
        XCTAssertTrue(staged, "precondition: the foreign turn never went busy")

        XCTAssertEqual(
            harness.app.stopRoute(forRuntimeSessionID: "rt-desktop"),
            .confirmThenStopUnattended,
            "another client's turn, killed by one tap, with no way back — this is CommandCenterView's per-row Interrupt as filed"
        )

        await harness.tearDown()
    }

    // MARK: T2 — the hole that makes the flag untrustworthy

    /// Fails if someone later "simplifies" the routing to
    /// `engine.state(for:).turnStartedLocally == false`, which reads identically
    /// for a blank state — right for the wrong reason, and wrong the moment the
    /// flag's default changes.
    func testASessionTheEngineHasNeverHeardOfStillRequiresConfirmation() async throws {
        let harness = await AppHarness.make()
        try await harness.openSocket()

        XCTAssertFalse(
            harness.app.engine.trackedSessionIDs.contains("rt-never-seen"),
            "precondition: the engine must not know this session"
        )
        XCTAssertEqual(
            harness.app.stopRoute(forRuntimeSessionID: "rt-never-seen"),
            .confirmThenStopUnattended,
            "untracked and foreign are the same bits at this level; treating unknown as ours waves through most of this list"
        )

        await harness.tearDown()
    }

    // MARK: T3 — the control: our own attended turn stops without an alert

    func testTheClientsOwnAttendedTurnIsStoppedWithoutAnAlert() async throws {
        let harness = await AppHarness.make()
        await harness.backend.setSessionMirroring(true)
        try await harness.openSocket()

        let chat = harness.chat(storedID: "20260819_100000_own")
        await chat.open()
        chat.errorMessage = nil
        let runtimeID = try XCTUnwrap(chat.runtimeSessionID)
        chat.draft = "do the thing"
        chat.sendTapped()
        let sent = await waitUntil { await harness.backend.callCount("prompt.submit") == 1 }
        XCTAssertTrue(sent, "the send never reached the backend")
        await harness.backend.emit(
            "message.start", sessionID: runtimeID, origin: ScriptedBackend.transportOrigin
        )
        let busy = await waitUntil { chat.live.isBusy }
        XCTAssertTrue(busy, "the turn never went busy")
        XCTAssertFalse(chat.isForeignTurn, "precondition: a turn this client submitted is its own")

        let route = harness.app.stopRoute(forRuntimeSessionID: runtimeID)
        XCTAssertEqual(route, .stopAttendedChat)
        XCTAssertFalse(
            route.needsConfirmation,
            "the fix must not simply confirm everything — a turn the phone provably owns stops the way the chat screen stops it"
        )

        await harness.tearDown()
    }

    // MARK: T4 — an attended foreign turn defers to the chat's own verdict

    func testAForeignTurnOnAnOpenChatConfirmsThroughTheChatsOwnVerdict() async throws {
        let harness = await AppHarness.make()
        await harness.backend.setSessionMirroring(true)
        try await harness.openSocket()

        let chat = harness.chat(storedID: "20260819_100100_foreignopen")
        await chat.open()
        chat.errorMessage = nil
        let runtimeID = try XCTUnwrap(chat.runtimeSessionID)
        await harness.backend.emit(
            "message.start", sessionID: runtimeID, origin: Self.foreignOrigin
        )
        let busy = await waitUntil { chat.live.isBusy }
        XCTAssertTrue(busy, "the foreign turn never went busy")
        XCTAssertTrue(chat.isForeignTurn, "precondition: the origin stamp must make this foreign")

        XCTAssertEqual(
            harness.app.stopRoute(forRuntimeSessionID: runtimeID),
            .confirmThenStopAttendedChat
        )
        XCTAssertEqual(
            harness.app.stopRoute(forRuntimeSessionID: runtimeID).needsConfirmation,
            chat.isForeignStop,
            "the Command Center must never disagree with the chat screen about the same session"
        )

        await harness.tearDown()
    }

    // MARK: T5 — the finalise and the latch, measured on the wire

    func testTheCommandCenterStopFinalisesLocallyBeforeItReachesTheBackend() async throws {
        let harness = await AppHarness.make()
        await harness.backend.setSessionMirroring(true)
        try await harness.openSocket()

        let staged = await stageUnattendedForeignSession(harness, sessionID: "rt-desktop")
        XCTAssertTrue(staged, "precondition: the foreign turn never went busy")

        try await harness.app.stopUnattendedSession(runtimeSessionID: "rt-desktop")

        let state = harness.app.engine.state(for: "rt-desktop")
        XCTAssertTrue(
            state.interrupted,
            "the bare RPC skipped markInterrupted, so the row kept saying it was working until the next poll"
        )
        XCTAssertFalse(state.isBusy, "the optimistic finalise must land in the frame of the tap")
        let interrupts = await harness.backend.callCount("session.interrupt")
        XCTAssertEqual(interrupts, 1)
        let addressed = await harness.backend.calls(to: "session.interrupt").last?.sessionID
        XCTAssertEqual(addressed, "rt-desktop")

        // The latch is the thing the bare RPC skipped, and this is the only
        // assertion that shows it working: a stale in-flight frame from the
        // cancelled turn must be swallowed rather than reviving the row.
        await harness.backend.emit("message.delta", sessionID: "rt-desktop", payload: .object([
            "text": .string("a frame that was already in flight"),
        ]))
        let revived = await waitUntil(timeout: 1) {
            harness.app.engine.state(for: "rt-desktop").isBusy
        }
        XCTAssertFalse(revived, "the interrupt latch must swallow the cancelled turn's stale frames")

        await harness.tearDown()
    }

    // MARK: T6 — computing the route dials nothing

    /// Forecloses the double-dial shape the approval path already has a finding
    /// open on.
    func testComputingTheRouteDialsNothing() async throws {
        let harness = await AppHarness.make()
        await harness.backend.setSessionMirroring(true)
        try await harness.openSocket()
        _ = await stageUnattendedForeignSession(harness, sessionID: "rt-desktop")

        _ = harness.app.stopRoute(forRuntimeSessionID: "rt-desktop")
        _ = harness.app.stopRoute(forRuntimeSessionID: "rt-never-seen")

        let dialled = await harness.backend.callCount("session.interrupt")
        XCTAssertEqual(dialled, 0, "asking who owns a turn must not stop it")

        await harness.tearDown()
    }

    // MARK: T7 — the delegated-agent leg

    func testStoppingAnUnattendedSessionAlsoStopsItsDelegatedAgents() async throws {
        let harness = await AppHarness.make()
        await harness.backend.setSessionMirroring(true)
        try await harness.openSocket()
        await harness.backend.stub("subagent.interrupt") { call in
            .object([
                "found": .bool(true),
                "subagent_id": .string(call.params["subagent_id"]?.coercedString ?? ""),
            ])
        }

        let staged = await stageUnattendedForeignSession(harness, sessionID: "rt-desktop")
        XCTAssertTrue(staged, "precondition: the foreign turn never went busy")
        await harness.backend.emit(
            "subagent.start",
            sessionID: "rt-desktop",
            payload: Self.subagentPayload(id: "sa-remote", goal: "Long background job")
        )
        let hasAgent = await waitUntil {
            harness.app.engine.state(for: "rt-desktop").activity.runningSubagents.count == 1
        }
        XCTAssertTrue(hasAgent, "precondition: no delegated agent to stop")

        try await harness.app.stopUnattendedSession(runtimeSessionID: "rt-desktop")

        let killed = await waitUntil { await harness.backend.callCount("subagent.interrupt") == 1 }
        XCTAssertTrue(
            killed,
            "session.interrupt gates on the session being running and reaches no detached child — the same hole BUG-013 wave 2 closed on the chat screen"
        )
        let killedID = await harness.backend.calls(to: "subagent.interrupt").last?
            .params["subagent_id"]?.coercedString
        XCTAssertEqual(killedID, "sa-remote")

        await harness.tearDown()
    }

    // MARK: T8 — stopping an untracked session must not create a roster entry

    func testAnUntrackedSessionIsNotAddedToTheEngineRosterByStoppingIt() async throws {
        let harness = await AppHarness.make()
        try await harness.openSocket()

        try await harness.app.stopUnattendedSession(runtimeSessionID: "rt-never-seen")

        XCTAssertFalse(
            harness.app.engine.trackedSessionIDs.contains("rt-never-seen"),
            "markInterrupted on an untracked id creates a roster entry that isQuiescent then refuses to evict, and on a backend that sends this client no terminal frame for it, nothing ever clears it — a per-tap leak of exactly the shape BUG-004 exists to prevent"
        )
        let reached = await harness.backend.callCount("session.interrupt")
        XCTAssertEqual(reached, 1, "the stop must still reach the backend")

        await harness.tearDown()
    }
}
