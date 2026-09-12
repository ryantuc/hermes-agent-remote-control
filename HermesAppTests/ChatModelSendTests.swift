import Foundation
import HermesServeKit
import XCTest

@testable import HermesMobile

/// A4 — `ChatModel.performSend` (ChatModel.swift:552-567).
///
/// The submit's inner `catch` retries on `isSessionNotFound || isTransportFailure`.
/// `isTransportFailure` is true for `.connectionClosed`, `.connectFailed`,
/// `.notConnected` and `.handshakeTimedOut` — every way the wire can fail. But
/// a wire failure on `prompt.submit` is the one case where the client
/// **cannot know** whether the server got the turn: the frame may have crossed
/// before the failure. Retrying it runs the same turn twice — double tokens,
/// and every tool in that turn a second time on the user's real machine. The
/// desktop reference retries on the two "stale runtime id" predicates only and
/// surfaces a wire failure to the user.
final class ChatModelSendTests: XCTestCase {

    /// The ambiguous write.
    ///
    /// The backend receives `prompt.submit` and the client's write reports
    /// failure anyway. This is the exact knowledge state the socket-dropped
    /// case produces — `URLSessionWebSocketTask.send` reporting failure for a
    /// frame that may already have crossed, or a close arriving before the ack
    /// — and it is the *knowledge state*, not the socket's fate, that the
    /// retry decision turns on. One turn was submitted. The app must not
    /// submit a second one.
    @MainActor
    func testTransportFailureOnSubmitDoesNotResubmitTheTurn() async throws {
        let harness = await AppHarness.make()
        try await harness.openSocket()

        let chat = harness.chat(storedID: "20260804_101500_abc123")
        await chat.open()
        let bound = await waitUntil { chat.runtimeSessionID != nil }
        XCTAssertTrue(bound, "the chat never bound a runtime session id")
        // `open()` also loads the persisted transcript over REST, which is not
        // scripted and always fails here. Clear that so the assertions below
        // are about the send and nothing else.
        chat.errorMessage = nil

        // The server gets the turn; the client is told the write failed.
        await harness.backend.deliverThenFailWrite("prompt.submit")

        chat.draft = "run the database migration"
        chat.sendTapped()

        let settled = await waitUntil { chat.isSending == false }
        XCTAssertTrue(settled, "the send never finished")
        // Let any retry the app decided to make reach the backend.
        _ = await waitUntil(timeout: 1) {
            await harness.backend.callCount("prompt.submit") > 1
        }

        let submits = await harness.backend.calls(to: "prompt.submit")
        XCTAssertEqual(
            submits.count,
            1,
            """
            the turn was submitted \(submits.count)× after ONE tap. A transport \
            failure on prompt.submit cannot tell the client whether the server got \
            the turn, so the retry at ChatModel.swift:552-567 runs it again: double \
            tokens and every tool in the turn a second time. \
            Submitted under session ids: \(submits.map(\.sessionID))
            """
        )
        XCTAssertEqual(
            submits.map(\.text),
            ["run the database migration"],
            "the same prompt text must not reach the backend twice"
        )

        // The other half of the contract: a send the client could not confirm
        // is surfaced, not swallowed. The bubble stays and carries its failure,
        // so re-running the turn is the user's decision.
        XCTAssertEqual(chat.outbound.count, 1, "the unconfirmed message must stay on screen")
        XCTAssertNotNil(
            chat.outbound.first?.failure,
            "an unconfirmable send must be shown as failed, with the inline Retry the user chooses"
        )
        XCTAssertEqual(chat.sendPhase, .idle, "the status line must not keep promising progress")

        await harness.tearDown()
    }

    /// The same contract staged through an actual socket drop rather than a
    /// write failure: the backend has the submit, the socket dies before the
    /// ack, the client reconnects. Still one turn; still must not re-submit.
    ///
    /// This one passes today, and not because the retry is safe. Measured:
    /// on a close, `HermesClient.handle(transportState:)` fails the
    /// pending submit and then reaches `.reconnecting` before `performSend`'s
    /// catch runs, so the retry's `session.resume` is refused with
    /// `.notConnected` before a frame is built and the resubmit never reaches
    /// the wire. The retry decision is just as wrong here — it is the client's
    /// own connection state that happens to block it, a few microseconds wide.
    /// Keep this as the boundary marker: it must stay green after A4 is fixed,
    /// and if it ever goes red the window has widened.
    @MainActor
    func testSocketDropBetweenSubmitAndAckDoesNotResubmitTheTurn() async throws {
        let harness = await AppHarness.make()
        try await harness.openSocket()

        let chat = harness.chat(storedID: "20260804_101500_ghi789")
        await chat.open()
        let bound = await waitUntil { chat.runtimeSessionID != nil }
        XCTAssertTrue(bound, "the chat never bound a runtime session id")
        chat.errorMessage = nil

        // The server takes the submit and never answers it.
        await harness.backend.gate("prompt.submit")
        chat.draft = "delete the stale branches"
        chat.sendTapped()
        let submitted = await waitUntil { await harness.backend.callCount("prompt.submit") == 1 }
        XCTAssertTrue(submitted, "the submit never reached the backend")

        // The socket dies with the turn already running server-side.
        await harness.backend.ungate("prompt.submit")
        await harness.backend.dropConnection()

        // Let the client's backoff reconnect (1 s) and any retry land.
        let reconnected = await waitUntil(timeout: 8) { harness.app.connectionState.isOpen }
        XCTAssertTrue(reconnected, "the client never reconnected after the drop")
        _ = await waitUntil(timeout: 2) { await harness.backend.callCount("prompt.submit") > 1 }

        let submits = await harness.backend.calls(to: "prompt.submit")
        XCTAssertEqual(
            submits.count,
            1,
            "the turn was submitted \(submits.count)× for one tap after a socket drop: \(submits.map(\.sessionID))"
        )

        await harness.tearDown()
    }

    /// The control: a genuinely stale runtime id (4001) *should* resume and
    /// retry — that is the predicate A4 leaves in place. Nothing here is broken
    /// today; it exists so a fix for A4 cannot pass by deleting the retry.
    @MainActor
    func testStaleRuntimeIDStillResumesAndRetriesOnce() async throws {
        let harness = await AppHarness.make()
        try await harness.openSocket()

        let chat = harness.chat(storedID: "20260804_101500_def456")
        await chat.open()
        let bound = await waitUntil { chat.runtimeSessionID != nil }
        XCTAssertTrue(bound, "the chat never bound a runtime session id")
        chat.errorMessage = nil
        let staleRuntimeID = chat.runtimeSessionID

        // 4001 once: the runtime id the client holds no longer exists
        // server-side. The resume mints a fresh one and the retry lands.
        await harness.backend.failNextRPC("prompt.submit", code: 4001, message: "session not found")
        let resumesBeforeSend = await harness.backend.callCount("session.resume")

        chat.draft = "list the open branches"
        chat.sendTapped()

        let resumed = await waitUntil {
            await harness.backend.callCount("session.resume") == resumesBeforeSend + 1
        }
        XCTAssertTrue(resumed, "a 4001 on submit must resume the durable id")
        let submits = await harness.backend.calls(to: "prompt.submit")
        XCTAssertEqual(submits.count, 2, "the retry after a stale id is the one retry that is correct")
        XCTAssertNotEqual(
            submits.last?.sessionID,
            staleRuntimeID,
            "the retry must go out on the runtime id the resume just bound"
        )
        let cleared = await waitUntil { chat.outbound.isEmpty }
        XCTAssertTrue(cleared, "an acknowledged retry hands the message to the engine")

        await harness.tearDown()
    }
}
