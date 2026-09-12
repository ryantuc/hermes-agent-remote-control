import Foundation
import HermesServeKit
import XCTest

@testable import HermesMobile

/// A11 — `AppModel.resumeOpenThreads` (AppModel.swift:817-832).
///
/// The eligibility guard is `chat.runtimeBoundAt < socketOpenedAt`, and
/// `runtimeBoundAt` is only written *inside* `applyResume` — after the
/// `session.resume` round trip. So the guard is read from state that the await
/// it guards is what changes. Three callers reach `resumeOpenThreads` around a
/// single socket-open (`connect()`, the state pump's `.open` transition, and
/// `handleForeground()`), and when two of them overlap both pass the guard and
/// both resume the same chat.
///
/// Two resumes bind two runtime ids to one conversation. The chat keeps the
/// last one; the other is still a live session server-side, and every event the
/// backend sends under it fails `chats.values.first { $0.runtimeSessionID == … }`
/// and is dropped. The transcript stops mid-turn with no error anywhere.
final class AppModelResumeTests: XCTestCase {

    @MainActor
    func testTwoCallersAroundOneSocketOpenResumeOnce() async throws {
        let harness = await AppHarness.make()

        // A conversation that was live on a previous socket. Registered before
        // this socket opens, which is what puts it in scope for the post-open
        // sweep — the everyday case: the app was backgrounded mid-turn.
        let chat = harness.chat(storedID: "20260804_090000_zzz999")
        XCTAssertNil(chat.runtimeSessionID, "the chat starts unbound")

        // Hold every resume's REPLY. The frame is still recorded on arrival and
        // the socket stays writable, so the second caller's resume is not
        // queued behind the first — both are genuinely in flight, which is the
        // condition the guard has to survive.
        await harness.backend.gate("session.resume")

        // Caller 1: the state pump's `.open` transition (AppModel.swift:390-393).
        try await harness.openSocket()
        let firstInFlight = await waitUntil {
            await harness.backend.callCount("session.resume") == 1
        }
        XCTAssertTrue(firstInFlight, "the post-open resume sweep never ran")

        // Caller 2: the app returning to the foreground while that resume is
        // still in flight — a lock-screen glance during a turn.
        let foreground = Task { @MainActor in await harness.app.handleForeground() }

        // On unfixed code the second resume is already on the wire.
        _ = await waitUntil(timeout: 2) {
            await harness.backend.callCount("session.resume") > 1
        }

        await harness.backend.ungate("session.resume")
        await harness.backend.releaseParked()
        await foreground.value
        let settled = await waitUntil { chat.runtimeSessionID != nil }
        XCTAssertTrue(settled, "the chat never bound a runtime session id")

        let resumes = await harness.backend.calls(to: "session.resume")
        XCTAssertEqual(
            resumes.count,
            1,
            """
            one chat and one socket-open produced \(resumes.count) session.resume calls. \
            The eligibility guard at AppModel.swift:828 is read before the await that \
            updates the value it tests, so two overlapping callers both pass it.
            """
        )

        let issued = await harness.backend.issuedRuntimeIDs
        let orphans = issued.filter { $0 != chat.runtimeSessionID }
        XCTAssertEqual(
            orphans,
            [],
            "runtime ids bound to this chat that nothing is listening to: \(orphans). "
                + "The chat holds \(chat.runtimeSessionID ?? "nil")."
        )

        // The harm, end to end: the backend streams the running turn under the
        // runtime id it bound first. If a second resume moved the chat onto a
        // different id, those events reach no chat and the transcript freezes.
        guard let firstBound = issued.first else {
            await harness.tearDown()
            return XCTFail("the backend never bound a runtime id")
        }
        await harness.backend.emitAssistantText("the migration finished", sessionID: firstBound)
        let painted = await waitUntil(timeout: 2) {
            chat.entries.contains { $0.text.contains("the migration finished") }
        }
        XCTAssertTrue(
            painted,
            "the turn streaming under \(firstBound) never reached the transcript — "
                + "the chat is listening on \(chat.runtimeSessionID ?? "nil")"
        )

        await harness.tearDown()
    }

    /// The pair the app-level single-flight does NOT cover: the post-open
    /// sweep racing the chat's own `open()`. The sweep sees a chat that is
    /// registered but not yet bound — `runtimeBoundAt` is still `.distantPast`,
    /// which passes the `< socketOpenedAt` guard — and resumes it in parallel
    /// with `open()`. Two resumes mint two runtime ids; the loser's late
    /// `applyResume` rebinds the chat and `forget`s the winner's engine state,
    /// killing a streaming turn with no error anywhere. Caught live by
    /// ChatEvictionTests' running-turn case; fixed by
    /// `ChatModel.resumeAndBind`'s per-chat single flight.
    @MainActor
    func testOpenJoinsTheSweepsInFlightResumeInsteadOfDialingARival() async throws {
        let harness = await AppHarness.make()

        // Registered before the socket opens, so the post-open sweep will
        // resume it. Holding every resume's reply keeps that resume in flight
        // while `open()` arrives — the interleaving the eviction tests hit by
        // accident, staged deterministically.
        let chat = harness.chat(storedID: "20260804_093000_xxx777")
        await harness.backend.gate("session.resume")
        try await harness.openSocket()
        let sweepDialed = await waitUntil {
            await harness.backend.callCount("session.resume") == 1
        }
        XCTAssertTrue(sweepDialed, "the post-open sweep never resumed the registered chat")

        // The user taps into the thread while the sweep's resume is parked.
        let opening = Task { @MainActor in await chat.open() }
        // On unfixed code the rival resume is on the wire within this window.
        _ = await waitUntil(timeout: 1) {
            await harness.backend.callCount("session.resume") > 1
        }

        await harness.backend.ungate("session.resume")
        await harness.backend.releaseParked()
        await opening.value
        let bound = await waitUntil { chat.runtimeSessionID != nil }
        XCTAssertTrue(bound, "the chat never bound a runtime session id")

        let resumes = await harness.backend.callCount("session.resume")
        XCTAssertEqual(
            resumes,
            1,
            """
            open() must join the sweep's in-flight resume, not dial a rival: \
            the loser's applyResume rebinds the chat to a second runtime id \
            and forgets the winner's engine state mid-turn.
            """
        )

        // The harm, end to end: a turn streaming under the one bound id still
        // paints after its route pops — the assertion the eviction test makes.
        guard let runtimeID = chat.runtimeSessionID else {
            await harness.tearDown()
            return XCTFail("no runtime session id to stream into")
        }
        await harness.backend.emitAssistantText("still here", sessionID: runtimeID)
        let running = await waitUntil { chat.live.isBusy }
        XCTAssertTrue(running, "the turn never started at the app layer")
        harness.app.releaseChats(keeping: [])
        await harness.backend.emit(
            "message.delta",
            sessionID: runtimeID,
            payload: .object(["text": .string(" — and painting")])
        )
        let painted = await waitUntil {
            chat.entries.contains { $0.text.contains("painting") }
        }
        XCTAssertTrue(painted, "the surviving chat must still receive its stream after the pop")

        await harness.tearDown()
    }

    /// The control: a chat that bound its runtime id on *this* socket is
    /// already live and must not be re-resumed. This is the guard's real job
    /// and it works today — a fix for the race must not achieve determinism by
    /// resuming everything unconditionally.
    @MainActor
    func testChatBoundOnThisSocketIsNotResumedAgain() async throws {
        let harness = await AppHarness.make()

        // Bound by the post-open sweep, so `runtimeBoundAt` lands after
        // `socketOpenedAt` — the chat is live on the socket it is holding.
        let chat = harness.chat(storedID: "20260804_091500_yyy888")
        try await harness.openSocket()
        let bound = await waitUntil { chat.runtimeSessionID != nil }
        XCTAssertTrue(bound, "the chat never bound a runtime session id")
        let afterOpen = await harness.backend.callCount("session.resume")
        XCTAssertEqual(afterOpen, 1, "the post-open sweep resumes exactly once")

        await harness.app.handleForeground()
        // Give a wrongly-eligible resume time to reach the backend.
        _ = await waitUntil(timeout: 1) {
            await harness.backend.callCount("session.resume") > afterOpen
        }

        let total = await harness.backend.callCount("session.resume")
        XCTAssertEqual(
            total,
            afterOpen,
            "a chat already live on this socket must not be resumed again — "
                + "a redundant resume rebuilds the agent and drops the per-session model override"
        )

        await harness.tearDown()
    }
}
