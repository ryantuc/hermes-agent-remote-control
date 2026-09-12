import Foundation
import HermesServeKit
import XCTest

@testable import HermesMobile

/// BUG-001 — the hub's "working" label must follow the gateway's real running
/// signal (`session.active_list`), never the REST `is_active` recency
/// heuristic (5-min window, never cleared on normal turn completion).
///
/// `refreshThreads(force:)` fetches the list over REST (dead in the harness)
/// and then refreshes `liveActiveIDs` from `session.active_list`, so the hub
/// row state can be asserted directly against `AppModel.isLiveWorking(_:)`.
@MainActor
final class HubLiveStatusTests: XCTestCase {

    func testWorkingLabelFollowsActiveList() async throws {
        let harness = await AppHarness.make()
        try await harness.openSocket()

        // No live agent → no row is marked working, whatever the wire's
        // 5-minute heuristic would claim.
        await harness.app.refreshThreads(force: true)
        XCTAssertTrue(harness.app.liveActiveIDs.isEmpty)
        XCTAssertFalse(harness.app.isLiveWorking("stored-1"))
        XCTAssertFalse(harness.app.isLiveWorking("stored-2"))

        // A desktop session mid-turn arrives in `session.active_list` as
        // working → the hub marks exactly that one durable id.
        await harness.backend.stub("session.active_list") { _ in
            .object(["sessions": .array([
                .object([
                    "id": .string("rt-9"),
                    "session_key": .string("stored-1"),
                    "title": .string("Desktop run"),
                    "preview": .string("rewriting the migration"),
                    "status": .string("working"),
                    "last_active": .number(Date().timeIntervalSince1970),
                ]),
            ])])
        }
        await harness.app.refreshThreads(force: true)
        XCTAssertTrue(harness.app.isLiveWorking("stored-1"))
        XCTAssertFalse(harness.app.isLiveWorking("stored-2"))

        // The whole row is kept now, not just the id — `status` is what the hub
        // row prints instead of a hardcoded "working", and `preview` is the one
        // sentence on this device that says what the other client is doing.
        let row = try XCTUnwrap(harness.app.liveStatus(forStoredID: "stored-1"))
        XCTAssertEqual(row.status, "working")
        XCTAssertEqual(row.preview, "rewriting the migration")
        XCTAssertNil(harness.app.liveStatus(forStoredID: "stored-2"))
        XCTAssertNil(harness.app.liveStatus(forStoredID: nil))

        // The turn settles: active_list still lists the session but as `idle`
        // (the runtime survives until teardown) → the label drops immediately.
        // No ~5-minute "working" tail.
        await harness.backend.stub("session.active_list") { _ in
            .object(["sessions": .array([
                .object([
                    "id": .string("rt-9"),
                    "session_key": .string("stored-1"),
                    "title": .string("Desktop run"),
                    "status": .string("idle"),
                    "last_active": .number(Date().timeIntervalSince1970),
                ]),
            ])])
        }
        await harness.app.refreshThreads(force: true)
        XCTAssertFalse(harness.app.isLiveWorking("stored-1"))

        await harness.tearDown()
    }

    func testWaitingSessionCountsAsWorking() async throws {
        let harness = await AppHarness.make()
        try await harness.openSocket()

        // An approval-blocked session reports `waiting`, not `working`, on the
        // wire (approvals never enter `_block`; see LiveSessionStatus docs) —
        // it still needs the user, so the hub keeps its dot.
        await harness.backend.stub("session.active_list") { _ in
            .object(["sessions": .array([
                .object([
                    "id": .string("rt-7"),
                    "session_key": .string("stored-3"),
                    "title": .string("Blocked"),
                    "status": .string("waiting"),
                    "last_active": .number(Date().timeIntervalSince1970),
                ]),
            ])])
        }
        await harness.app.refreshThreads(force: true)
        XCTAssertTrue(harness.app.isLiveWorking("stored-3"))
        // …and the hub row now says so, instead of calling it "working".
        XCTAssertEqual(harness.app.liveStatus(forStoredID: "stored-3")?.status, "waiting")

        await harness.tearDown()
    }
}

/// `sessions.changed` must also repaint the conversation the user has OPEN —
/// it is the only notice a client gets that another client moved a session on
/// a backend that does not mirror session events.
///
/// REST is dead in this harness by design, so the transcript reload cannot
/// return content. What is asserted here is therefore the GATING, not the
/// content: whether the attempt was made at all. `ChatModel.errorMessage`
/// becoming non-nil is the observable — `loadTranscript` sets it on the
/// connection-refused that every REST call here produces.
///
/// The two tests are each other's control. If the gated one ever fails, check
/// the ungated one first: a green "no attempt" assertion means nothing if the
/// pathway is broken and no attempt is ever made.
@MainActor
final class OpenTranscriptRefreshTests: XCTestCase {

    /// A quiet open chat: the refresh is attempted.
    func testSessionsChangedRefreshesAQuietOpenTranscript() async throws {
        let harness = await AppHarness.make()
        try await harness.openSocket()

        let chat = harness.chat(storedID: "stored-quiet")
        await chat.open()
        XCTAssertTrue(chat.hasLoadedOnce, "open() must have run for the refresh to be eligible")
        XCTAssertNotNil(chat.runtimeSessionID, "open() binds a runtime id off session.resume")

        // Clear what `open()`'s own dead-REST transcript load left behind, so
        // the next non-nil can only come from the refresh.
        chat.errorMessage = nil

        await harness.backend.emit("sessions.changed", sessionID: "")
        let attempted = await waitUntil { chat.errorMessage != nil }
        XCTAssertTrue(attempted, "sessions.changed did not reach the open transcript")

        await harness.tearDown()
    }

    /// The same event while a turn is running: no attempt. A repaint landing
    /// mid-turn would swap the live entries out from under the stream.
    func testSessionsChangedSkipsABusyOpenTranscript() async throws {
        let harness = await AppHarness.make()
        try await harness.openSocket()

        let chat = harness.chat(storedID: "stored-busy")
        await chat.open()
        let runtimeID = try XCTUnwrap(chat.runtimeSessionID)

        await harness.backend.emit("message.start", sessionID: runtimeID)
        let busy = await waitUntil { chat.live.isBusy }
        XCTAssertTrue(busy, "the chat never went busy — the rest of this test proves nothing")

        chat.errorMessage = nil
        await harness.backend.emit("sessions.changed", sessionID: "")
        let attempted = await waitUntil(timeout: 1) { chat.errorMessage != nil }
        XCTAssertFalse(attempted, "a busy chat must not be repainted from the persisted transcript")

        await harness.tearDown()
    }

    /// The D3 handshake end to end at the app layer: `session_mirroring` on
    /// `gateway.ready` turns on the `watch` param, and `origin` reaches the
    /// turn engine so it can tell its own turns from another client's.
    func testSessionMirroringHandshakeTurnsOnWatchOnResume() async throws {
        let harness = await AppHarness.make()
        // Before the socket opens: the handshake happens exactly once.
        await harness.backend.setSessionMirroring(true)
        try await harness.openSocket()

        let advertised = await waitUntil { harness.app.sessionMirroring }
        XCTAssertTrue(advertised, "gateway.ready advertised session_mirroring and the app missed it")
        XCTAssertEqual(harness.app.engine.localOrigin, ScriptedBackend.transportOrigin)

        let chat = harness.chat(storedID: "stored-mirrored")
        await chat.open()

        let resumes = await harness.backend.calls(to: "session.resume")
        let last = try XCTUnwrap(resumes.last, "the chat never resumed")
        XCTAssertEqual(
            last.params["watch"]?.coercedBool, true,
            "a mirroring gateway must be asked to watch, not just to resume"
        )

        await harness.tearDown()
    }

    /// …and the same resume against the default (unpatched) backend must put
    /// no `watch` field on the wire at all. Capability detection lives on the
    /// handshake; this is the assertion that keeps it there.
    func testUnpatchedBackendNeverSendsWatch() async throws {
        let harness = await AppHarness.make()
        try await harness.openSocket()
        XCTAssertFalse(harness.app.sessionMirroring)

        let chat = harness.chat(storedID: "stored-plain")
        await chat.open()

        let resumes = await harness.backend.calls(to: "session.resume")
        let last = try XCTUnwrap(resumes.last, "the chat never resumed")
        XCTAssertNil(last.params["watch"], "`watch` must be absent, not false, on an unpatched backend")

        await harness.tearDown()
    }
}
