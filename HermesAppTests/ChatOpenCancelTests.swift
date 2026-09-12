import Foundation
import HermesServeKit
import XCTest

@testable import HermesMobile

/// BUG-121 pressure tests for candidates C1 and C4.
///
/// C1 isolation result: the
/// kickoff's "unstructured resumeTask keeps applying after Back cancels the
/// view `.task`" shape is **not** what runs. Cancelling the Task that awaits
/// `open()` leaves `runtimeSessionID` nil after the gated `session.resume`
/// is later released — `applyResume` does not land on the cancelled open.
/// These two tests pin that refutation so a regression that *does* apply
/// late is visible.
///
/// **C4 isolation result (same run):** `releaseChats(keeping: [])` on five
/// idle chats is sub-millisecond on the sim host. It is not the multi-second
/// dead-Home cause.
@MainActor
final class ChatOpenCancelTests: XCTestCase {

    private enum Wire {
        static func resumeResult(runtime: String, key: String) -> JSONValue {
            .object([
                "session_id": .string(runtime),
                "session_key": .string(key),
                "resumed": .string(key),
                "messages": .array([]),
                "running": .bool(false),
                "status": .string("idle"),
                "watching": .bool(false),
            ])
        }
    }

    /// C1 REFUTED: cancel `open()` while `session.resume` is gated; release the
    /// RPC afterwards. The cancelled open must **not** bind a runtime id.
    func testCancelledOpenDoesNotApplyResumeWhenTheRPCLandsLate() async throws {
        let harness = await AppHarness.make()
        try await harness.openSocket()

        let storedID = "20260828_bug121_cancel_open"
        await harness.backend.gate("session.resume")
        await harness.backend.stub("session.resume") { call in
            Wire.resumeResult(runtime: "rt-bug121-cancel", key: call.sessionID)
        }

        let chat = harness.chat(storedID: storedID)
        let openTask = Task { await chat.open() }

        let parked = await waitUntil(timeout: 3) {
            await harness.backend.parkedCount >= 1
        }
        XCTAssertTrue(parked, "session.resume never parked — gate did not catch the open")
        // A2: load settled before resume; spinner flag is off, bind flag is on.
        XCTAssertFalse(chat.isLoading, "A2: isLoading clears before gated resume")
        XCTAssertTrue(chat.isBinding, "A2: isBinding holds while resume is gated")
        XCTAssertNil(chat.runtimeSessionID, "precondition: resume has not applied yet")

        openTask.cancel()
        _ = await openTask.result

        XCTAssertFalse(
            chat.isLoading,
            "open()'s defer must clear isLoading even when cancelled"
        )
        XCTAssertFalse(
            chat.isBinding,
            "open()'s defer must clear isBinding even when cancelled"
        )

        await harness.backend.ungate("session.resume")
        await harness.backend.releaseParked()

        // Give a late apply a real window (longer than one run-loop turn).
        try? await Task.sleep(nanoseconds: 250_000_000)

        XCTAssertNil(
            chat.runtimeSessionID,
            """
            C1 REFUTED as the multi-second dead-Home mechanism: a cancelled open() \
            did not apply session.resume after the parent returned. If this starts \
            binding (runtime=\(chat.runtimeSessionID ?? "nil")), the unstructured \
            resumeTask is leaking applyResume onto the main actor after Back and \
            C1 is back in play.
            """
        )

        await harness.tearDown()
    }

    /// C1 REFUTED (reinsert half): after cancel + releaseChats, a late resume
    /// must not put the old instance back under the route key.
    func testCancelledOpenDoesNotReinsertViaChatDidBindAfterRelease() async throws {
        let harness = await AppHarness.make()
        try await harness.openSocket()

        let storedID = "20260828_bug121_reinsert"
        await harness.backend.gate("session.resume")
        await harness.backend.stub("session.resume") { call in
            Wire.resumeResult(runtime: "rt-bug121-reinsert", key: call.sessionID)
        }

        let chat = harness.chat(storedID: storedID)
        let openTask = Task { await chat.open() }

        let parked = await waitUntil(timeout: 3) {
            await harness.backend.parkedCount >= 1
        }
        XCTAssertTrue(parked, "session.resume never parked")

        openTask.cancel()
        _ = await openTask.result
        XCTAssertFalse(chat.isLoading)
        XCTAssertFalse(chat.isBinding)

        let released = harness.app.releaseChats(keeping: [])
        XCTAssertGreaterThanOrEqual(released, 1, "cancelled idle open must be releasable")

        let afterRelease = harness.chat(storedID: storedID)
        XCTAssertFalse(
            afterRelease === chat,
            "precondition: releaseChats must have dropped the cancelled chat"
        )
        _ = harness.app.releaseChats(keeping: [])

        await harness.backend.ungate("session.resume")
        await harness.backend.releaseParked()
        try? await Task.sleep(nanoseconds: 250_000_000)

        XCTAssertNil(
            chat.runtimeSessionID,
            "cancelled chat must not bind a runtime id after release"
        )
        let lookedUp = harness.chat(storedID: storedID)
        XCTAssertFalse(
            lookedUp === chat,
            """
            C1 reinsert REFUTED: late resume did not chatDidBind the released \
            instance back into the cache. If lookedUp === chat, C1 is back.
            """
        )

        await harness.tearDown()
    }

    /// C4: releaseChats on a handful of idle chats must be cheap.
    func testReleaseChatsOnIdleChatsIsSub50Milliseconds() async throws {
        let harness = await AppHarness.make()
        try await harness.openSocket()

        var runtimeIDs: [String] = []
        for i in 0..<5 {
            let storedID = "20260828_bug121_rel_\(i)"
            let chat = harness.chat(storedID: storedID)
            await chat.open()
            let bound = await waitUntil { chat.runtimeSessionID != nil }
            XCTAssertTrue(bound, "chat \(i) never bound")
            chat.errorMessage = nil
            if let id = chat.runtimeSessionID { runtimeIDs.append(id) }
        }
        XCTAssertEqual(runtimeIDs.count, 5)

        let start = ContinuousClock.now
        let released = harness.app.releaseChats(keeping: [])
        let elapsed = ContinuousClock.now - start
        let ms = elapsed.intervalMilliseconds

        XCTAssertEqual(released, 5, "all five idle chats must release")
        XCTAssertLessThan(
            ms,
            50,
            """
            releaseChats alone took \(ms) ms for 5 idle chats. If this is hundreds \
            of ms or more it could contribute to dead Home; under 50 ms it is not \
            the multi-second freeze.
            """
        )

        await harness.tearDown()
    }
}

private extension Duration {
    var intervalMilliseconds: Double {
        let comps = self.components
        return Double(comps.seconds) * 1000 + Double(comps.attoseconds) / 1e15
    }
}
