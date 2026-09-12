import Foundation
import HermesServeKit
import XCTest

@testable import HermesMobile

/// BUG-003 — Live Activity cards that never end, and lie while they wait.
///
/// The recon's headline was wrong and the design says so: a terminal frame that
/// **arrives** already ends the card, through `handle(event:)` → `engine.apply`
/// → `publish` → `reconcile` → `plan.end`. Nothing belongs in the
/// `.messageComplete` arm. What is actually broken is what the card *says* on
/// the way out, and the three ways a turn can end without the card hearing:
///
/// 1. **The wind-down lies.** `end()` hands ActivityKit `lastPushed`, which is
///    the last *busy* snapshot, so a finished turn sits on the Lock Screen for
///    the whole 8 s dismissal saying "Working…" with a ticking timer.
/// 2. **Lost terminal frames strand cards.** Attended: the reconnect re-seed
///    (`publishAll`, and twelve `ChatModel` sites) writes `chat.live` directly
///    and never reconciles the roster. Chatless: nothing settles engine state
///    at all if the socket was down when the turn ended — the worst gap, and
///    the one only `session.active_list` can close.
/// 3. **End/start thrash.** A queued prompt draining seconds after the complete
///    gets a *new* card: the elapsed timer resets and the island slot is lost.
///
/// Plus the cold-launch orphan race — `adoptExisting` runs once at `install`,
/// when `Activity.activities` is often still empty, so a card that survived the
/// last process is never adopted and never counted against the cap.
///
/// These are the **app-layer** reds. They compile against stage 0 and fail on
/// assertions, which is the point: a red that fails to build proves nothing
/// about behaviour. The design's kit tests (`ended`, `toolLine`,
/// `settleFromStatus`) are specification tests for API that does not exist yet
/// and are compile errors until the fix lands, so they ride with it.
@MainActor
final class LiveActivityLifecycleTests: XCTestCase {

    // MARK: - Staging

    /// An `AppHarness` whose `LiveActivityController` is built on a recording
    /// fake instead of ActivityKit, with the Live Activity preferences forced on
    /// for the duration.
    @MainActor
    private struct Controlled {
        let harness: AppHarness
        let fake: FakeLiveActivitySurface
        let controller: LiveActivityController
        let savedEnabled: Bool
        let savedCron: Bool

        func tearDown() async {
            await harness.tearDown()
            LiveActivityPreferences.enabled = savedEnabled
            LiveActivityPreferences.autoStartForCron = savedCron
            // `install(app:)` pointed the island's intent bridge at this test's
            // controller. Put the app's own back: the bridge holds its handler
            // weakly, and a nil handler makes every later island button a
            // silent no-op.
            ApprovalActivityBridge.handler = LiveActivityController.shared
        }
    }

    /// The master toggle defaults **off** and cron auto-start defaults on; both
    /// are forced here, because a test about when cards end has nothing to say
    /// if no card ever starts. Restored in `tearDown` — these are real
    /// `UserDefaults` keys in the test host.
    private func makeControlled() async throws -> Controlled {
        let savedEnabled = LiveActivityPreferences.enabled
        let savedCron = LiveActivityPreferences.autoStartForCron
        LiveActivityPreferences.enabled = true
        LiveActivityPreferences.autoStartForCron = true

        let harness = await AppHarness.make()
        // D3 fan-out: every session on the host reaches this socket, which is
        // what makes a chatless card ordinary rather than exotic.
        await harness.backend.setSessionMirroring(true)

        let fake = FakeLiveActivitySurface()
        let controller = LiveActivityController(surface: fake)
        harness.app.liveActivities = controller
        controller.install(app: harness.app)

        try await harness.openSocket()
        return Controlled(
            harness: harness,
            fake: fake,
            controller: controller,
            savedEnabled: savedEnabled,
            savedCron: savedCron
        )
    }

    /// `emitAssistantText` emits `message.start` + `message.delta` **only** —
    /// its own doc comment says otherwise and is wrong. Every completed turn in
    /// this file therefore emits its terminal frame explicitly.
    private func completeTurn(
        _ controlled: Controlled,
        sessionID: String,
        text: String = "done"
    ) async {
        await controlled.harness.backend.emit("message.complete", sessionID: sessionID, payload: .object([
            "text": .string(text),
            "status": .string("complete"),
        ]))
    }

    // MARK: - (a) The wind-down lies

    /// RED. A chatless turn completes; the last thing pushed to its card must
    /// say the turn is over.
    func testTurnCompleteWindsDownAChatlessCard() async throws {
        let controlled = try await makeControlled()

        await controlled.harness.backend.emitAssistantText("rotating the logs", sessionID: "cron-winddown")
        let carded = await waitUntil { controlled.fake.handle(for: "cron-winddown") != nil }
        XCTAssertTrue(carded, "precondition: the cron turn never put a card up — nothing below proves anything")

        await completeTurn(controlled, sessionID: "cron-winddown", text: "rotating the logs — done")
        _ = await waitUntil { !controlled.harness.app.engine.state(for: "cron-winddown").isBusy }

        let handle = try XCTUnwrap(controlled.fake.handle(for: "cron-winddown"))
        let honest = await waitUntil { handle.lastContent?.hasEnded == true }
        XCTAssertTrue(
            honest,
            """
            the turn completed but the card's last content still claims a \
            running turn — no ended snapshot was ever pushed. `end()` hands the \
            card `lastPushed`, which is the last BUSY snapshot, so it sits on \
            the Lock Screen for the whole dismissal window saying "Working…" \
            over a finished turn, with a timer still ticking (BUG-003 defect \
            1). Card: \(handle.describeContent)
            """
        )

        await controlled.tearDown()
    }

    /// RED. The same, for a turn that failed: the card must say so rather than
    /// fading out mid-sentence as though the work had finished.
    func testAFailedTurnWindsDownWithFailure() async throws {
        let controlled = try await makeControlled()

        await controlled.harness.backend.emitAssistantText("half a build", sessionID: "cron-failed")
        let carded = await waitUntil { controlled.fake.handle(for: "cron-failed") != nil }
        XCTAssertTrue(carded, "precondition: the cron turn never put a card up")

        await controlled.harness.backend.emit("message.complete", sessionID: "cron-failed", payload: .object([
            "status": .string("error"),
            "error": .string("the provider returned 500"),
        ]))
        let recorded = await waitUntil {
            controlled.harness.app.engine.state(for: "cron-failed").lastError != nil
        }
        XCTAssertTrue(recorded, "precondition: the engine never recorded the failure")

        let handle = try XCTUnwrap(controlled.fake.handle(for: "cron-failed"))
        let saidSo = await waitUntil { handle.lastContent?.statusText == "Failed" }
        XCTAssertTrue(
            saidSo,
            """
            the failed turn never wound its card down. A card that goes quiet \
            and disappears is indistinguishable from one whose work succeeded, \
            and this is the case where the difference matters most — nobody was \
            watching. Card: \(handle.describeContent)
            """
        )
        XCTAssertEqual(
            handle.lastContent?.hasEnded, true,
            "a failed turn's final content must also be stamped ended, or the timer keeps running"
        )

        await controlled.tearDown()
    }

    // MARK: - (b) Lost terminal frames

    /// RED. The attended strand: the socket dies mid-turn, so the terminal
    /// frame never arrives. On reconnect the resume re-seeds live state — and
    /// that is *all* it does. Nothing reconciles the roster, so the card
    /// outlives the turn it was drawn for.
    func testReconnectReSeedReconcilesAStrandedCard() async throws {
        let controlled = try await makeControlled()

        let chat = controlled.harness.chat(storedID: "stored-stranded")
        await chat.open()
        let runtimeID = try XCTUnwrap(chat.runtimeSessionID, "open() binds a runtime id off session.resume")

        await controlled.harness.backend.emit("message.start", sessionID: runtimeID)
        let carded = await waitUntil { controlled.fake.handle(for: runtimeID) != nil }
        XCTAssertTrue(carded, "precondition: the attended turn never put a card up")
        let handle = try XCTUnwrap(controlled.fake.handle(for: runtimeID))

        await controlled.harness.backend.dropConnection()
        let reopened = await waitUntil(timeout: 10) { controlled.harness.app.connectionState.isOpen }
        XCTAssertTrue(reopened, "precondition: the client never reconnected after the drop")
        // `applyResume` forgets the old runtime id and re-seeds under a new one,
        // so the rebind is the observable for "the resume has landed".
        let rebound = await waitUntil(timeout: 10) { chat.runtimeSessionID != runtimeID }
        XCTAssertTrue(rebound, "precondition: the reconnect never re-resumed the open chat")

        let ended = await waitUntil { handle.isEnded }
        XCTAssertTrue(
            ended,
            """
            the reconnect re-seeded live state but never reconciled the roster \
            — the card outlived its turn. `publishAll` writes `chat.live` \
            straight from the engine instead of going through `publish`, so \
            `sessionDidUpdate` never fires and the controller is never told the \
            turn it is drawing is gone. The session behind this card no longer \
            even exists in the engine. Card: \(handle.describeContent)
            """
        )

        await controlled.tearDown()
    }

    /// RED. The chatless strand, and the worst of the three: no chat, no
    /// terminal frame, nothing on this device that will ever settle the turn.
    /// `session.active_list` is authoritative in both directions — a session it
    /// does not report is a session that is not running — and the poll is the
    /// only thing that can close this.
    func testActiveListSettlesAStrandedChatlessSession() async throws {
        let controlled = try await makeControlled()

        await controlled.harness.backend.emitAssistantText("nightly digest", sessionID: "cron-lost")
        let carded = await waitUntil { controlled.fake.handle(for: "cron-lost") != nil }
        XCTAssertTrue(carded, "precondition: the cron turn never put a card up")
        XCTAssertNil(
            controlled.harness.app.chat(runtimeSessionID: "cron-lost"),
            "precondition: this session must be unattended — no chat may hold it"
        )

        // The gateway is asked what is genuinely running, and answers: nothing.
        // Absence is the authoritative signal here, which is why the stub is
        // empty rather than reporting the session idle.
        await controlled.harness.backend.stub("session.active_list") { _ in
            .object(["sessions": .array([])])
        }
        await controlled.harness.app.refreshThreads(force: true)

        let settled = await waitUntil { !controlled.harness.app.engine.state(for: "cron-lost").isBusy }
        XCTAssertTrue(
            settled,
            """
            the gateway says nothing is running but the engine still holds the \
            cron session busy — the card survived the poll. No terminal frame \
            is ever coming for this session, and without a settle its Lock \
            Screen card claims "Working…" until the process dies.
            """
        )

        await controlled.tearDown()
    }

    /// GREEN today and after the fix — the guard on the sweep above.
    ///
    /// An **attended** chat mid-send sets `isBusy` before `prompt.submit` even
    /// returns, and an `active_list` snapshot generated a beat earlier would
    /// wrongly settle it: `turnStartedLocally` would be cleared and the user's
    /// own turn re-labelled as another client's. Attended chats are repaired by
    /// the resume path instead. The wait here is inverted and bounded, so a
    /// pass means "it did not happen" rather than "we did not wait long enough".
    func testActiveListSweepLeavesAttendedChatsAlone() async throws {
        let controlled = try await makeControlled()

        let chat = controlled.harness.chat(storedID: "stored-attended")
        await chat.open()
        let runtimeID = try XCTUnwrap(chat.runtimeSessionID)

        await controlled.harness.backend.emit("message.start", sessionID: runtimeID)
        let busy = await waitUntil { controlled.harness.app.engine.state(for: runtimeID).isBusy }
        XCTAssertTrue(busy, "precondition: the attended chat never went busy")

        await controlled.harness.backend.stub("session.active_list") { _ in
            .object(["sessions": .array([])])
        }
        await controlled.harness.app.refreshThreads(force: true)

        let settled = await waitUntil(timeout: 1) {
            !controlled.harness.app.engine.state(for: runtimeID).isBusy
        }
        XCTAssertFalse(
            settled,
            """
            the active_list sweep settled an ATTENDED chat's running turn. A \
            poll snapshot can predate this device's own send, so settling here \
            clears `turnStartedLocally` and renders the user's own turn as \
            another client's.
            """
        )

        await controlled.tearDown()
    }

    // MARK: - (c) End/start thrash

    /// RED. A queued prompt drains seconds after the complete. Today the card
    /// is torn down and a fresh one requested: the elapsed timer restarts from
    /// zero, the Dynamic Island slot is surrendered and re-taken, and for a beat
    /// there are two cards on the glass for one conversation.
    func testAQueuedPromptKeepsTheCardAcrossTheTurnBoundary() async throws {
        let controlled = try await makeControlled()

        await controlled.harness.backend.emitAssistantText("first turn", sessionID: "cron-queued")
        let carded = await waitUntil { controlled.fake.requestCount(for: "cron-queued") == 1 }
        XCTAssertTrue(carded, "precondition: the first turn never put a card up")

        await completeTurn(controlled, sessionID: "cron-queued", text: "first turn done")
        _ = await waitUntil { !controlled.harness.app.engine.state(for: "cron-queued").isBusy }

        // The queued prompt drains — well inside the linger the fix introduces.
        await controlled.harness.backend.emit("message.start", sessionID: "cron-queued")
        let busyAgain = await waitUntil { controlled.harness.app.engine.state(for: "cron-queued").isBusy }
        XCTAssertTrue(busyAgain, "precondition: the queued prompt never started a second turn")

        XCTAssertEqual(
            controlled.fake.requestCount(for: "cron-queued"), 1,
            """
            one conversation was given \(controlled.fake.requestCount(for: "cron-queued")) \
            separate cards across a single queued-prompt boundary. The turn \
            ending tore the card down and the next turn requested a new one, \
            which resets the elapsed timer and loses the island slot — and \
            during the old card's dismissal window both are on the Lock Screen \
            at once (BUG-003 defect 3).
            """
        )
        let handle = try XCTUnwrap(controlled.fake.handle(for: "cron-queued"))
        XCTAssertFalse(
            handle.isEnded,
            "the card the next turn should have taken back was ended instead: \(handle.describeContent)"
        )

        await controlled.tearDown()
    }

    // MARK: - (d) The cold-launch orphan race

    /// RED. A Live Activity outlives the process that requested it. On a cold
    /// launch `Activity.activities` is frequently still empty when `install`
    /// asks, so the surviving card is never adopted, never ended, and never
    /// counted against the cap — which is how a cap of two ends up with five
    /// cards on the glass. Foregrounding must sweep whatever the system is
    /// holding that this process has no handle for.
    func testOrphansSurfacingAfterLaunchAreEndedOnForeground() async throws {
        let controlled = try await makeControlled()

        // The card the last process left behind, surfacing after install asked.
        let orphan = FakeLiveActivityHandle(id: "orphan-activity", sessionKey: "cron-orphan")
        controlled.fake.preexisting = [orphan]

        await controlled.harness.app.handleForeground()

        let ended = await waitUntil { orphan.isEnded }
        XCTAssertTrue(
            ended,
            """
            an orphan card that surfaced after launch survived foregrounding. \
            The turn behind it died with the last process, so nothing can ever \
            update it — it will sit at whatever "7/12" it was showing — and \
            because the controller holds no handle for it, the roster cap does \
            not know it exists.
            """
        )

        await controlled.tearDown()
    }

    // MARK: - (e) The linger actually expires

    /// Ships with the fix rather than red-first: it names `windDownLinger`,
    /// which the fix introduces. The wind-down is not a substitute for ending
    /// the card — it is a delay with a resurrection window inside it, and when
    /// nothing resurrects, the real end must still run and must carry the
    /// ENDED snapshot rather than the busy one the bug shipped.
    func testWindDownEventuallyExecutesTheEndWithTheEndedSnapshot() async throws {
        let controlled = try await makeControlled()
        // 8 s is the shipping linger; a test that waited it out would be the
        // slowest in the suite for no extra proof.
        controlled.controller.windDownLinger = 0.05

        await controlled.harness.backend.emitAssistantText("rotating the logs", sessionID: "cron-linger")
        let carded = await waitUntil { controlled.fake.handle(for: "cron-linger") != nil }
        XCTAssertTrue(carded, "precondition: the cron turn never put a card up")
        let handle = try XCTUnwrap(controlled.fake.handle(for: "cron-linger"))

        await completeTurn(controlled, sessionID: "cron-linger", text: "rotating the logs — done")

        let ended = await waitUntil { handle.isEnded }
        XCTAssertTrue(
            ended,
            """
            the linger expired and the card was never actually ended. A card \
            that winds down and then lives forever is the original bug with an \
            honest first frame. Card: \(handle.describeContent)
            """
        )
        XCTAssertEqual(
            handle.finalSnapshot?.hasEnded, true,
            "the end must carry the ended snapshot, not the last busy one"
        )
        XCTAssertNotNil(handle.removeAt, "never `.immediate`: the finished state is worth a glance")

        await controlled.tearDown()
    }
}
