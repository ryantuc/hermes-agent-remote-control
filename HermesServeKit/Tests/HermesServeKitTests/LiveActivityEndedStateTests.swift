import XCTest

@testable import HermesServeKit

/// BUG-003, the kit's half: what a card says once its turn is over.
///
/// These are specification tests for pure API the fix introduces — the ended
/// snapshot and the one-line status under the card's title. They live in the
/// kit for the same reason the rest of `LiveActivityDerivation` does: a widget
/// body cannot be asserted on, and this line is exactly where the bug's
/// "Working…, forever" lived.
final class LiveActivityEndedStateTests: XCTestCase {
    /// A card mid-turn: seven of twelve tools done, a shell running, and — when
    /// asked for — an approval waiting on the glass with a live Deny button.
    private func busySnapshot(approval: Bool = false) -> LiveActivitySnapshot {
        LiveActivitySnapshot(
            title: "Build check",
            toolName: "shell",
            toolDetail: "swift test",
            toolsCompleted: 7,
            toolsTotal: 12,
            isBusy: true,
            statusText: "Running tools",
            startedAt: Date(timeIntervalSince1970: 1_000_000),
            approvalToken: approval ? "4C3E9B0A-0000-0000-0000-000000000001" : "",
            approvalCommand: approval ? "rm -rf build" : "",
            approvalDescription: approval ? "delete the build directory" : "",
            approvalFitsIsland: approval
        )
    }

    // MARK: The ended snapshot

    /// Every card is live until something stamps it. The field is trailing and
    /// defaulted precisely so no existing call site accidentally ends a turn.
    func testASnapshotStartsUnended() {
        let snapshot = busySnapshot()
        XCTAssertNil(snapshot.endedAt)
        XCTAssertFalse(snapshot.hasEnded)
    }

    func testEndedStampsTheCardAndQuietsIt() {
        let at = Date(timeIntervalSince1970: 1_000_042)
        let ended = LiveActivityDerivation.ended(busySnapshot(), at: at)

        XCTAssertEqual(ended.endedAt, at)
        XCTAssertTrue(ended.hasEnded)
        XCTAssertFalse(ended.isBusy, "a finished turn's dot must not keep pulsing")
        XCTAssertEqual(ended.toolName, "", "the tool that was running is not running")
        XCTAssertEqual(ended.toolDetail, "")
        XCTAssertEqual(ended.statusText, "", "a successful turn says nothing, and `toolLine` fills in Done")
        // The frozen bar is what the turn honestly did.
        XCTAssertEqual(ended.toolsCompleted, 7)
        XCTAssertEqual(ended.toolsTotal, 12)
        XCTAssertEqual(ended.title, "Build check")
        XCTAssertEqual(ended.startedAt, busySnapshot().startedAt, "the timer's origin does not move")
    }

    /// A finished card must not keep offering Deny over a queue that no longer
    /// exists. The gate would refuse the press; the button existing at all is
    /// the lie.
    func testEndedStripsTheApproval() {
        let ended = LiveActivityDerivation.ended(busySnapshot(approval: true), at: Date())
        XCTAssertFalse(ended.hasApproval)
        XCTAssertEqual(ended.approvalToken, "")
        XCTAssertEqual(ended.approvalCommand, "")
        XCTAssertEqual(ended.approvalDescription, "")
        XCTAssertFalse(ended.approvalFitsIsland)
    }

    /// A card that goes quiet and vanishes is indistinguishable from one whose
    /// work succeeded — and the case where the difference matters most is the
    /// one nobody was watching.
    func testEndedCarriesTheFailure() {
        let ended = LiveActivityDerivation.ended(busySnapshot(), at: Date(), failed: true)
        XCTAssertEqual(ended.statusText, "Failed")
        XCTAssertTrue(ended.hasEnded)
        XCTAssertFalse(ended.isBusy)
    }

    // MARK: The status line

    func testToolLineSaysDoneOnAnEndedCard() {
        let ended = LiveActivityDerivation.ended(busySnapshot(), at: Date())
        XCTAssertEqual(LiveActivityDerivation.toolLine(for: ended, isStale: false), "Done")
    }

    func testToolLineSaysFailedOnAnEndedFailure() {
        let ended = LiveActivityDerivation.ended(busySnapshot(), at: Date(), failed: true)
        XCTAssertEqual(LiveActivityDerivation.toolLine(for: ended, isStale: false), "Failed")
    }

    /// A card the app can no longer update has to say so: this is the only
    /// honesty available to a card whose process is gone.
    func testToolLineSaysSoWhenStale() {
        XCTAssertEqual(
            LiveActivityDerivation.toolLine(for: busySnapshot(), isStale: true),
            "No longer updating"
        )
    }

    /// Ended is the stronger, more specific claim: a card that finished and
    /// then aged out finished.
    func testEndedWinsOverStale() {
        let ended = LiveActivityDerivation.ended(busySnapshot(), at: Date())
        XCTAssertEqual(LiveActivityDerivation.toolLine(for: ended, isStale: true), "Done")
    }

    /// The live ladder is unchanged by the move into the kit — tool, then its
    /// argument preview, then the status line, and never an empty row.
    func testTheLiveLadderIsUnchanged() {
        var snapshot = busySnapshot()
        XCTAssertEqual(
            LiveActivityDerivation.toolLine(for: snapshot, isStale: false),
            "shell · swift test"
        )

        snapshot.toolDetail = ""
        XCTAssertEqual(LiveActivityDerivation.toolLine(for: snapshot, isStale: false), "shell")

        snapshot.toolName = ""
        XCTAssertEqual(LiveActivityDerivation.toolLine(for: snapshot, isStale: false), "Running tools")

        snapshot.statusText = ""
        XCTAssertEqual(LiveActivityDerivation.toolLine(for: snapshot, isStale: false), "Working…")

        snapshot.isBusy = false
        XCTAssertEqual(LiveActivityDerivation.toolLine(for: snapshot, isStale: false), "Idle")
    }
}

/// BUG-003's chatless strand, at the engine: the turn ended while this client
/// could not hear it, so `session.active_list` is the only thing left that can
/// settle the state a Lock Screen card is drawing from.
final class TurnEngineSettleFromStatusTests: XCTestCase {
    private let session = "a1b2c3d4"

    private func event(_ type: String, payload: JSONValue = .null) -> GatewayEvent {
        GatewayEvent(type: type, sessionID: session, payload: payload, params: .null)
    }

    /// Everything a person could be waiting on goes quiet together — the turn
    /// flag, the prompt queue, and the status line.
    func testSettleQuietsABusyPromptingSession() {
        let engine = TurnEngine()
        engine.appendUserEntry(sessionID: session, text: "run the nightly")
        engine.apply(event("message.start"))
        engine.apply(event("approval.request", payload: .object([
            "command": .string("systemctl restart hermes"),
            "description": .string("restart the agent service"),
        ])))
        XCTAssertTrue(engine.state(for: session).isBusy, "precondition: the turn must be running")
        XCTAssertTrue(engine.state(for: session).hasBlockingPrompt, "precondition: the prompt must be up")

        engine.settleFromStatus(sessionID: session)

        let state = engine.state(for: session)
        XCTAssertFalse(state.isBusy)
        XCTAssertFalse(state.needsInput)
        XCTAssertFalse(state.hasBlockingPrompt)
        XCTAssertTrue(state.pendingApprovals.isEmpty)
        XCTAssertFalse(state.turnStartedLocally)
        XCTAssertEqual(state.statusText, "")
    }

    /// **Not `markInterrupted`.** Nobody pressed Stop, so there is no latch: a
    /// later turn's events have to land rather than be swallowed for the grace
    /// window.
    func testSettleDoesNotLatch() {
        let engine = TurnEngine()
        engine.appendUserEntry(sessionID: session, text: "run the nightly")
        engine.apply(event("message.start"))
        engine.settleFromStatus(sessionID: session)
        XCTAssertFalse(engine.state(for: session).interrupted)

        engine.apply(event("message.start"))
        XCTAssertTrue(
            engine.state(for: session).isBusy,
            "the next turn's start was swallowed — the settle latched when it must not"
        )
    }

    /// Turn flags only. Whatever streamed stays: there is no authoritative
    /// final text to replace it with, and deleting a partial answer is worse
    /// than keeping one.
    func testSettleLeavesTheEntriesAlone() {
        let engine = TurnEngine()
        engine.appendUserEntry(sessionID: session, text: "run the nightly")
        engine.apply(event("message.start"))
        engine.apply(event("message.delta", payload: .object(["text": .string("half an answer")])))
        engine.flush()

        let before = engine.state(for: session).entries
        XCTAssertEqual(before.count, 2, "precondition: a user row and a streaming assistant row")

        engine.settleFromStatus(sessionID: session)

        let after = engine.state(for: session).entries
        XCTAssertEqual(after.count, before.count)
        XCTAssertEqual(after.map(\.text), before.map(\.text))
        XCTAssertFalse(
            after.contains { $0.isStreaming },
            "the open bubble must stop claiming it is still streaming"
        )
    }

    /// The sweep walks the roster, and a session it does not track is a session
    /// with nothing to settle. It must not conjure state for one.
    func testSettleIgnoresAnUntrackedSession() {
        let engine = TurnEngine()
        engine.settleFromStatus(sessionID: "never-seen")
        XCTAssertTrue(engine.trackedSessionIDs.isEmpty)
    }
}
