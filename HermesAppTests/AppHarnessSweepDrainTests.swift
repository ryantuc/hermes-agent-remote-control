import Foundation
import HermesServeKit
import XCTest

@testable import HermesMobile

/// **BUG-132.** The app suite's cross-run flake is one harness defect, not a
/// family of unrelated ones: `AppHarness.openSocket()` promises the app is
/// quiet when it returns, and the signal it waits on is satisfied three steps
/// before the app is quiet.
///
/// `AppModel`'s post-open sweep is five statements
/// (`AppModel.swift:1239-1248`): `publishAll()`, `refreshThreads(force: true)`,
/// `bots.refresh()`, `resumeOpenThreads()`, `startPolling()`. `threadsError`
/// is assigned inside the second — so a test that returns on it runs its body
/// alongside the last three, each of which writes state the tests assert on:
///
/// - `bots.refresh()` is single-flighted (`BotsModel.swift:151-155`), so a
///   `refresh()` the test issues while the sweep's is in flight **joins it and
///   returns without a call of its own** — the pins the test just set never
///   reach `profiles.list`. That is both `BotsModelTests` failures
///   (`preferred_session_ids` empty; roster from the pre-stub answer).
/// - `resumeOpenThreads()` ends in `publishAll()` (`AppModel.swift:2086`),
///   which writes `chat.live` with the send pipeline's own optimistic `isBusy`
///   still set. `ChatModel.swift:77-82` reads that as "the backend's turn
///   started" and resets `sendPhase` to `.idle`. That is
///   `ChatModelSendingStatusTests.testIdleSendSaysSendingUntilAck` reading
///   `idle`/`Thinking` where it staged `sending`/`Sending…`.
/// - `resumeAfterReconnect()` re-loads the transcript (`ChatModel.swift:605`)
///   over the harness's deliberately dead REST port, so
///   `errorMessage = describe(error)` (`ChatModel.swift:676`) lands *after* a
///   test has cleared it. That is `ApprovalCountdownTests.swift:118` failing on
///   `"Could not connect to the server."` — the same coin flip
///   `StopStopsAgentsTests.swift:59-64` and
///   `ChatModelResumeSettlingTests.swift:82-88` already diagnosed and worked
///   around one file at a time.
///
/// `startPolling()` is the sweep's last statement and its only caller
/// (`AppModel.swift:1248`, `:1478`), and `isPollingThreads` (`:1476`) is
/// already exposed for exactly this kind of pinning. "The sweep has finished"
/// and "the app is polling threads" are therefore the same fact.
@MainActor
final class AppHarnessSweepDrainTests: XCTestCase {

    /// The invariant `openSocket()` claims. Deterministic once the drain is in
    /// place; before it, this is the flake itself, caught at its source instead
    /// of in whichever unlucky test the sweep happened to land on.
    func testOpenSocketReturnsOnlyAfterThePostOpenSweepHasFinished() async throws {
        let harness = await AppHarness.make()
        try await harness.openSocket()

        XCTAssertTrue(
            harness.app.isPollingThreads,
            "openSocket() returned while the post-open sweep was still running. Every chat registered, pin set or send tapped after this line is racing bots.refresh(), resumeOpenThreads() and the publishAll() that closes it."
        )

        await harness.tearDown()
    }

    /// The mechanism, staged rather than waited for: with the sweep's own
    /// roster refresh parked, `threadsError` still goes non-nil — proving that
    /// the old predicate answers "yes" while the sweep is provably three
    /// statements from done.
    func testTheThreadsErrorSignalIsSatisfiedWhileTheSweepIsStillRunning() async throws {
        let harness = await AppHarness.make()
        // Park step 3 of 5 (`AppModel.swift:1246`). The gate leaves the socket
        // writable, so everything else in the sweep proceeds normally.
        await harness.backend.gate("profiles.list")

        guard let client = harness.app.client else {
            return XCTFail("no client — activate() did not run")
        }
        try await client.connect()
        let open = await waitUntil { harness.app.connectionState.isOpen }
        XCTAssertTrue(open, "the socket never reached .open at the app layer")

        // This is the whole of what `openSocket()` used to wait on.
        let reached = await waitUntil { harness.app.threadsError != nil }
        XCTAssertTrue(reached, "the post-open sweep never reached refreshThreads")

        let parked = await waitUntil {
            let count = await harness.backend.parkedCount
            return count > 0
        }
        XCTAssertTrue(parked, "the sweep's own profiles.list never reached the backend")
        XCTAssertFalse(
            harness.app.isPollingThreads,
            "the sweep cannot have finished with its roster refresh still parked, yet threadsError already said it had"
        )

        await harness.backend.ungate("profiles.list")
        await harness.backend.releaseParked()
        let finished = await waitUntil { harness.app.isPollingThreads }
        XCTAssertTrue(finished, "the sweep never finished after its roster refresh was released")

        await harness.tearDown()
    }
}
