import Foundation
import XCTest

@testable import HermesMobile

/// BUG-024 — the post-open ceremony lived in the tail of `AppModel.connect()`,
/// and `connect()` has exactly one caller: `activate(profileID:connect:)`. So
/// the whole tail ran once per explicit activation and never again for the life
/// of that client. Every other way a socket opens — the backoff loop after a
/// failed first dial, `wake()` on foreground, the reconnect after a drop —
/// reached `.open` and got two of its eleven steps: threads and resumes.
///
/// No test in this repo had ever executed `AppModel.connect()`. `AppHarness`
/// dials the kit client directly, so all 150+ app-layer tests reach `.open`
/// through the pump and therefore through the defective path — the harness
/// modelled the broken state and asserted nothing about it. That is why these
/// reds are cheap.
///
/// The counter throughout is `config.get`: `refreshDefaultCwd()` makes exactly
/// three (`project`, `provider`, `reasoning`), so the call count is a precise
/// multiple of "the ceremony ran".
@MainActor
final class ConnectionLifecycleTests: XCTestCase {

    /// RED-1 — a pump-driven socket open loads the backend defaults.
    func testASocketOpenLoadsTheBackendDefaults() async throws {
        let harness = await AppHarness.make()
        try await harness.openSocket()

        let asked = await waitUntil {
            await harness.backend.callCount("config.get") >= 3
        }
        XCTAssertTrue(
            asked,
            "the socket is open and this client never asked the backend for a single default — refreshDefaultCwd() is reachable only from the tail of AppModel.connect(), which runs once per activate(connect: true)"
        )
        XCTAssertEqual(harness.app.defaultCwd, "/scripted", "the new-conversation cwd was never read")
        XCTAssertEqual(harness.app.defaultModel, "scripted-model", "Home's draft pill has no model to show")

        await harness.tearDown()
    }

    /// RED-2 — a pump-driven socket open requests the config document.
    ///
    /// REST points at a closed port in this harness, so a *failed* load is the
    /// proof the load was attempted at all. What must not happen is nothing
    /// happening. (This is why the harness's dead REST port must stay dead: it
    /// is this test's oracle, not merely an accepted limitation.)
    func testASocketOpenRequestsTheConfigDocument() async throws {
        let harness = await AppHarness.make()
        try await harness.openSocket()

        let attempted = await waitUntil { harness.app.settings.loadError != nil }
        XCTAssertTrue(
            attempted,
            "the config document was never requested for this connection, so approvals.timeout and agent.clarify_timeout are unknown for its whole life: the approval sheet draws no countdown and arms no dismissal timer"
        )

        await harness.tearDown()
    }

    /// RED-3 — a pump-driven socket open arms the thread poll.
    func testASocketOpenArmsTheThreadPoll() async throws {
        let harness = await AppHarness.make()
        try await harness.openSocket()

        let armed = await waitUntil { harness.app.isPollingThreads }
        XCTAssertTrue(
            armed,
            "the socket is open and no list poll is armed. sessions.changed demotes polling to a backstop, it does not replace it — on a backend without change events this is the ONLY thing that refreshes the hub"
        )

        await harness.tearDown()
    }

    /// RED-4 — a reconnect runs the post-open work again. The reported repro end
    /// to end, written as a delta so it is red whether or not RED-1 is fixed.
    func testAReconnectRunsThePostOpenWorkAgain() async throws {
        let harness = await AppHarness.make()
        try await harness.openSocket()
        let before = await harness.backend.callCount("config.get")

        await harness.backend.dropConnection()
        let dropped = await waitUntil { !harness.app.connectionState.isOpen }
        XCTAssertTrue(dropped, "precondition: the app never saw the socket close")
        let reopened = await waitUntil(timeout: 10) { harness.app.connectionState.isOpen }
        XCTAssertTrue(reopened, "precondition: the client never reconnected after the drop")

        let reloaded = await waitUntil(timeout: 5) {
            await harness.backend.callCount("config.get") > before
        }
        XCTAssertTrue(
            reloaded,
            "the socket came back and this client asked the new connection nothing. A reconnect can land on a DIFFERENT hermes serve process sharing only state.db, so the config document, the defaults and the identity this client holds are the previous connection's and may be wrong"
        )

        await harness.tearDown()
    }

    /// CONTROL-1 — one socket open runs the ceremony exactly once.
    ///
    /// Guards the mistake the fix could introduce. A second pass re-enters
    /// `resumeOpenThreads()` against a socket whose chats are already bound to
    /// it, which is two `session.resume` calls for one conversation and one
    /// runtime id nothing is listening to — the defect `AppModelResumeTests`
    /// exists to pin. Single ownership makes that structurally impossible; this
    /// control keeps it that way if someone later re-adds a call from
    /// `connect()`.
    func testOneSocketOpenRunsThePostOpenWorkOnce() async throws {
        let harness = await AppHarness.make()
        try await harness.openSocket()
        _ = await waitUntil { await harness.backend.callCount("config.get") >= 3 }
        // Give a second pass time to land if one exists.
        _ = await waitUntil(timeout: 1) { await harness.backend.callCount("config.get") > 3 }

        let total = await harness.backend.callCount("config.get")
        XCTAssertEqual(
            total,
            3,
            "one socket open ran the post-open work \(total / 3)x"
        )

        await harness.tearDown()
    }
}
