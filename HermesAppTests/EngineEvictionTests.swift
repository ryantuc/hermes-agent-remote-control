import Foundation
import HermesServeKit
import XCTest

@testable import HermesMobile

/// BUG-004 — the engine's roster of watched-but-unopened sessions.
///
/// `ChatEvictionTests` pins the chat-bound half of A8: a chat and its engine
/// state are released together, and never mid-turn or mid-prompt. This file
/// pins the other half — sessions the engine tracks with **no ChatModel at
/// all**. Under D3 fan-out every session on the host reaches this socket, so a
/// cron run, a desktop turn and a kanban sweep each mint a `SessionTurnState`
/// (`TurnEngine.route` returns any event's session id, no membership check),
/// and before the BUG-004 sweep nothing ever removed one: every `forget` call
/// site is chat-bound. Growth was unbounded for the life of the process, and
/// every flush tick and Live Activity reconcile walked the whole roster — the
/// restart-cures-it chrome lag.
///
/// The retention rule these tests guard (A8, `AppModel.releaseChats`): a
/// chatless session that is busy or holding a blocking prompt KEEPS its state,
/// because `liveSessions()` draws Lock Screen cards from it — the case a card
/// is most useful for. Eviction is only for chatless sessions that are
/// quiescent in the engine and card-less.
///
/// The sweep is event-driven (terminal frames plus a high-water valve), so
/// these tests trigger it by emitting turns rather than calling a sweep API —
/// which is also what lets this file compile and run RED against the pre-fix
/// tree.
final class EngineEvictionTests: XCTestCase {

    /// (a) The A8 guardrail: a chatless BUSY session is never evicted — its
    /// state is the Lock Screen card's feed. Green before and after the fix.
    @MainActor
    func testAChatlessBusySessionIsRetained() async throws {
        let harness = await AppHarness.make()
        await harness.backend.setSessionMirroring(true)
        try await harness.openSocket()

        // A cron run starts a turn; no chat exists for it on this phone.
        await harness.backend.emitAssistantText("nightly digest under way", sessionID: "cron-busy")
        let tracked = await waitUntil {
            harness.app.engine.trackedSessionIDs.contains("cron-busy")
        }
        XCTAssertTrue(tracked, "precondition: the busy cron session never reached the engine")
        XCTAssertTrue(harness.app.engine.state(for: "cron-busy").isBusy, "precondition: it must be mid-turn")
        XCTAssertNil(harness.app.chat(runtimeSessionID: "cron-busy"), "precondition: no chat may exist for it")

        // Another foreign session completes a turn — post-fix, that terminal
        // frame runs the eviction sweep over the whole roster, synchronously
        // inside handle(event:). Note: `emitAssistantText` does NOT emit the
        // terminal frame; it is emitted explicitly here.
        await harness.backend.emitAssistantText("done elsewhere", sessionID: "cron-other")
        await harness.backend.emit("message.complete", sessionID: "cron-other", payload: .object([
            "text": .string("done elsewhere"), "status": .string("complete"),
        ]))
        _ = await waitUntil { !harness.app.engine.state(for: "cron-other").isBusy }

        XCTAssertTrue(
            harness.app.engine.trackedSessionIDs.contains("cron-busy"),
            """
            a chatless session with a RUNNING turn was evicted. Its state is \
            what `liveSessions()` draws the Lock Screen card from (A8, \
            AppModel.releaseChats) — evicting mid-turn breaks Live Activities \
            for exactly their most useful case.
            """
        )
        XCTAssertTrue(
            harness.app.engine.state(for: "cron-busy").isBusy,
            "the retained state must still be the live turn"
        )

        await harness.tearDown()
    }

    /// (b) The fix itself: a chatless session whose turn has completed — idle,
    /// unprompted, card-less — is evicted by the terminal-frame sweep.
    /// RED before the fix: nothing removes a watched-only session, ever.
    @MainActor
    func testAChatlessIdleCardlessSessionIsEvictedAfterItsTurnCompletes() async throws {
        let harness = await AppHarness.make()
        await harness.backend.setSessionMirroring(true)
        try await harness.openSocket()

        await harness.backend.emitAssistantText("rotating the logs", sessionID: "cron-idle")
        let tracked = await waitUntil {
            harness.app.engine.trackedSessionIDs.contains("cron-idle")
        }
        XCTAssertTrue(tracked, "precondition: the cron session never reached the engine")

        await harness.backend.emit("message.complete", sessionID: "cron-idle", payload: .object([
            "text": .string("rotating the logs — done"), "status": .string("complete"),
        ]))

        let evicted = await waitUntil {
            !harness.app.engine.trackedSessionIDs.contains("cron-idle")
        }
        XCTAssertTrue(
            evicted,
            """
            the engine is still holding SessionTurnState for cron-idle after \
            its turn completed, with no chat open for it on this phone and no \
            Live Activity card. Nothing ever removes a watched-only session, so \
            under fan-out the roster grows for the life of the process and \
            every flush tick walks it (BUG-004). Tracked now: \
            \(harness.app.engine.trackedSessionIDs.sorted())
            """
        )

        await harness.tearDown()
    }

    /// (c) Boundedness under a flood: forty foreign sessions each run a full
    /// turn on the socket — the shape of a working day of cron and desktop
    /// traffic. RED before the fix: the roster ends at forty and never shrinks.
    @MainActor
    func testAFloodOfForeignTurnsLeavesTheRosterBounded() async throws {
        let harness = await AppHarness.make()
        await harness.backend.setSessionMirroring(true)
        try await harness.openSocket()

        for index in 0..<40 {
            let sessionID = String(format: "cron-flood-%02d", index)
            await harness.backend.emitAssistantText("run \(index)", sessionID: sessionID)
            await harness.backend.emit("message.complete", sessionID: sessionID, payload: .object([
                "text": .string("run \(index) done"), "status": .string("complete"),
            ]))
        }

        let drained = await waitUntil { harness.app.engine.trackedSessionIDs.isEmpty }
        XCTAssertTrue(
            drained,
            """
            after 40 foreign sessions each completed a turn, the engine still \
            tracks \(harness.app.engine.trackedSessionIDs.count) of them. \
            Watched-but-unopened session state is never evicted, so it grows \
            without bound for the life of the process (BUG-004).
            """
        )

        await harness.tearDown()
    }

    /// (c′) The high-water valve: sessions that only ever emit non-terminal
    /// chatter (session.info here) never hand the sweep a terminal frame, so
    /// growth past the high-water mark must trigger it instead. RED before the
    /// fix: all forty stay.
    @MainActor
    func testAnInfoOnlyFloodIsBoundedByTheHighWaterValve() async throws {
        let harness = await AppHarness.make()
        await harness.backend.setSessionMirroring(true)
        try await harness.openSocket()

        for index in 0..<40 {
            await harness.backend.emitSessionInfo(sessionID: String(format: "cron-info-%02d", index))
        }
        _ = await waitUntil {
            harness.app.engine.trackedSessionIDs.contains("cron-info-39")
        }

        // 24 == AppModel.engineRosterHighWater. Hardcoded so this file
        // compiles (and runs red) against the pre-fix tree; keep in sync.
        XCTAssertLessThanOrEqual(
            harness.app.engine.trackedSessionIDs.count, 24,
            """
            an info-only flood pushed the engine roster past the high-water \
            mark and nothing swept it. Sessions that never complete a turn on \
            this socket (title/info chatter) accumulate forever without the \
            valve (BUG-004).
            """
        )

        await harness.tearDown()
    }

    /// (d) A chatless session holding a pending approval is never evicted: the
    /// prompt is a request the agent is stalled on, `approval.respond` is
    /// positional FIFO per session, and the surface that answers it draws from
    /// this state. Green before and after the fix.
    @MainActor
    func testAChatlessSessionWithAPendingApprovalIsRetained() async throws {
        let harness = await AppHarness.make()
        await harness.backend.setSessionMirroring(true)
        try await harness.openSocket()

        await harness.backend.emit("approval.request", sessionID: "cron-approval", payload: .object([
            "command": .string("systemctl restart hermes"),
            "description": .string("restart the agent service"),
        ]))
        let prompted = await waitUntil {
            harness.app.engine.state(for: "cron-approval").hasBlockingPrompt
        }
        XCTAssertTrue(prompted, "precondition: the approval never reached the engine")

        // A terminal frame elsewhere runs the sweep post-fix.
        await harness.backend.emitAssistantText("done elsewhere", sessionID: "cron-other")
        await harness.backend.emit("message.complete", sessionID: "cron-other", payload: .object([
            "status": .string("complete"),
        ]))
        _ = await waitUntil { !harness.app.engine.state(for: "cron-other").isBusy }

        XCTAssertTrue(
            harness.app.engine.trackedSessionIDs.contains("cron-approval"),
            """
            a chatless session holding a PENDING APPROVAL was evicted. \
            approval.respond is positional FIFO per session — dropping the \
            queue strands the agent and loses the consent surface.
            """
        )
        XCTAssertNotNil(
            harness.app.engine.state(for: "cron-approval").currentApproval,
            "the approval must still be present on the retained state"
        )

        await harness.tearDown()
    }

    /// (d) An interrupt latch is engine bookkeeping a sweep must not discard:
    /// while it holds, the cancelled turn's stale in-flight frames are being
    /// swallowed, and evicting the session would reset that defence (A3).
    /// Green before and after the fix.
    @MainActor
    func testASessionWithAnInterruptLatchIsRetained() async throws {
        let harness = await AppHarness.make()
        await harness.backend.setSessionMirroring(true)
        try await harness.openSocket()

        await harness.backend.emitAssistantText("half a thought", sessionID: "cron-latched")
        _ = await waitUntil { harness.app.engine.state(for: "cron-latched").isBusy }
        harness.app.engine.markInterrupted(sessionID: "cron-latched")
        XCTAssertTrue(
            harness.app.engine.state(for: "cron-latched").interrupted,
            "precondition: the latch must be set"
        )

        await harness.backend.emitAssistantText("done elsewhere", sessionID: "cron-other")
        await harness.backend.emit("message.complete", sessionID: "cron-other", payload: .object([
            "status": .string("complete"),
        ]))
        _ = await waitUntil { !harness.app.engine.state(for: "cron-other").isBusy }

        XCTAssertTrue(
            harness.app.engine.trackedSessionIDs.contains("cron-latched"),
            """
            a session with an interrupt latch was evicted. The latch \
            (TurnEngine.interruptedAt) is what swallows the cancelled turn's \
            stale in-flight frames; evicting resets it, and the cancelled \
            turn's tail would seed a fresh bubble (A3).
            """
        )

        await harness.tearDown()
    }

    /// (d) The card gate, on the predicate rather than through a sweep:
    /// ActivityKit cannot start a real activity in a test host, so the app-side
    /// fact is passed in. A session the engine calls quiescent and no chat
    /// holds is still kept while a Live Activity card is drawing from it — the
    /// card's every update reads `engine.state(for:)`, and BUG-003's wind-down
    /// keeps the handle for the linger, which is what defers the eviction past
    /// a resurrection. Rides with the fix because it names post-fix API.
    @MainActor
    func testACardedSessionIsNeverEvictable() async throws {
        let harness = await AppHarness.make()
        await harness.backend.setSessionMirroring(true)
        try await harness.openSocket()

        // Info-only chatter: tracked, idle, unpinned, no chat — quiescent by
        // every kit measure, so the card gate is the only thing left deciding.
        await harness.backend.emitSessionInfo(sessionID: "cron-carded")
        let tracked = await waitUntil {
            harness.app.engine.trackedSessionIDs.contains("cron-carded")
        }
        XCTAssertTrue(tracked, "precondition: the session never reached the engine")
        XCTAssertNil(harness.app.chat(runtimeSessionID: "cron-carded"), "precondition: no chat may exist for it")
        XCTAssertTrue(
            harness.app.engine.isQuiescent(sessionID: "cron-carded"),
            "precondition: the kit's half of the verdict must be yes, or this test proves nothing"
        )

        XCTAssertFalse(
            harness.app.engineSessionIsEvictable("cron-carded", hasCard: true),
            """
            a session with a Live Activity card up was declared evictable. The \
            card draws its every update from this engine state — forgetting it \
            leaves a card on the Lock Screen with nothing behind it.
            """
        )
        XCTAssertTrue(
            harness.app.engineSessionIsEvictable("cron-carded", hasCard: false),
            "the same session with no card is evictable — the card is the only thing holding it"
        )

        await harness.tearDown()
    }
}
