import Foundation
import HermesServeKit
import XCTest

@testable import HermesMobile

/// A8 — every conversation ever opened stays in memory for the life of the
/// process.
///
/// `AppModel.chats` (AppModel.swift:119) caches a `ChatModel` per route and
/// `chat(for:)` (AppModel.swift:758) never drops one. The `TurnEngine` keys a
/// `SessionTurnState` alongside it (TurnEngine.swift:230). Between them they
/// hold the full history, the live entries, the outbound roster and any image
/// bitmaps, for every thread the user has visited. Removal exists only in
/// `deleteThread` and teardown; leaving a chat frees nothing, so a power user
/// walking up to the 100-session cap is holding hundreds of MB.
///
/// **The constraint is the interesting half.** A chat whose turn is still
/// running must not be evicted: its deltas are still arriving and the state
/// they accumulate into is the stream. Nor may one holding a blocking prompt —
/// that is a request the agent is stalled on. Eviction is only safe for a chat
/// that is idle, unprompted and off screen. `open()` reloads the transcript, so
/// re-entry costs a reload; getting the predicate wrong costs an answer.
///
/// `releaseChats(keeping:)` is what RootView calls from the `NavigationStack`
/// path binding — the navigation layer's own record of what is on the stack,
/// written back on the back button, the edge swipe and a programmatic pop
/// alike. Passing an empty set is "everything popped".
final class ChatEvictionTests: XCTestCase {

    /// Open a chat, leave it idle, pop its route. It — and the turn state the
    /// engine keeps beside it — must go.
    @MainActor
    func testPoppingAnIdleChatReleasesItAndItsEngineState() async throws {
        let harness = await AppHarness.make()
        try await harness.openSocket()

        let storedID = "20260804_101500_a8idle"
        let chat = harness.chat(storedID: storedID)
        await chat.open()
        let bound = await waitUntil { chat.runtimeSessionID != nil }
        XCTAssertTrue(bound, "the chat never bound a runtime session id")
        chat.errorMessage = nil
        guard let runtimeID = chat.runtimeSessionID else {
            return XCTFail("no runtime session id to track")
        }
        XCTAssertTrue(
            harness.app.engine.trackedSessionIDs.contains(runtimeID),
            "precondition: the engine must be holding turn state for this session"
        )

        let routeKey = ThreadRoute.Key.existing(storedID).rawValue

        // Still on screen: nothing may be released.
        harness.app.releaseChats(keeping: [routeKey])
        XCTAssertTrue(
            harness.app.chat(runtimeSessionID: runtimeID) === chat,
            "a chat whose route is still on the navigation stack must never be released"
        )

        // The route pops.
        harness.app.releaseChats(keeping: [])

        XCTAssertNil(
            harness.app.chat(runtimeSessionID: runtimeID),
            """
            the chat for a route that left the navigation stack is still cached in \
            AppModel.chats (AppModel.swift:119). It is idle, unprompted and off \
            screen, and it is holding its history, its live entries, its outbound \
            roster and any image bitmaps for the life of the process.
            """
        )
        XCTAssertFalse(
            harness.app.engine.trackedSessionIDs.contains(runtimeID),
            """
            the turn engine is still holding SessionTurnState for \(runtimeID) \
            (TurnEngine.swift:230) after the only chat watching it went away. \
            Tracked now: \(harness.app.engine.trackedSessionIDs.sorted())
            """
        )

        // Re-entry rebuilds rather than resurrecting: `open()` reloads the
        // transcript, which is why releasing costs a reload and not an answer.
        let reopened = harness.chat(storedID: storedID)
        XCTAssertFalse(
            reopened === chat,
            "re-entering the thread must build a fresh chat, not hand back the retained one"
        )

        await harness.tearDown()
    }

    /// The hard constraint. A turn is running: the deltas are still arriving and
    /// the engine state they accumulate into IS the stream. Popping the route
    /// must not touch it.
    @MainActor
    func testAChatWithARunningTurnSurvivesItsRoutePopping() async throws {
        let harness = await AppHarness.make()
        try await harness.openSocket()

        let chat = harness.chat(storedID: "20260804_101500_a8running")
        await chat.open()
        let bound = await waitUntil { chat.runtimeSessionID != nil }
        XCTAssertTrue(bound, "the chat never bound a runtime session id")
        chat.errorMessage = nil
        guard let runtimeID = chat.runtimeSessionID else {
            return XCTFail("no runtime session id to stream into")
        }

        // A turn starts, and the first token lands.
        await harness.backend.emitAssistantText("working on it", sessionID: runtimeID)
        let running = await waitUntil { chat.live.isBusy }
        XCTAssertTrue(running, "the turn never started at the app layer")

        // The user backs out of the chat while it is still streaming — which is
        // exactly what someone does while waiting for a long turn.
        harness.app.releaseChats(keeping: [])

        XCTAssertTrue(
            harness.app.chat(runtimeSessionID: runtimeID) === chat,
            """
            a chat with a RUNNING TURN was released when its route popped. Its \
            stream is now going nowhere: the deltas still arriving have no chat \
            to paint into, and the engine state they accumulate into was dropped \
            with it. Backing out of a chat to wait for a long turn is normal use.
            """
        )
        XCTAssertTrue(
            harness.app.engine.trackedSessionIDs.contains(runtimeID),
            "the running turn's engine state must survive the pop"
        )

        // And it really was still live: the rest of the turn still paints.
        await harness.backend.emit(
            "message.delta",
            sessionID: runtimeID,
            payload: .object(["text": .string(" — done")])
        )
        let painted = await waitUntil {
            chat.entries.contains { $0.text.contains("done") }
        }
        XCTAssertTrue(painted, "the surviving chat must still receive the rest of its stream")

        await harness.tearDown()
    }

    /// The other half of the constraint. A pending approval is a command the
    /// agent is blocked on, waiting for this user to allow or deny. Dropping it
    /// on a pop would strand the agent and lose the consent surface.
    @MainActor
    func testAChatWithAPendingApprovalSurvivesItsRoutePopping() async throws {
        let harness = await AppHarness.make()
        try await harness.openSocket()

        let chat = harness.chat(storedID: "20260804_101500_a8approval")
        await chat.open()
        let bound = await waitUntil { chat.runtimeSessionID != nil }
        XCTAssertTrue(bound, "the chat never bound a runtime session id")
        chat.errorMessage = nil
        guard let runtimeID = chat.runtimeSessionID else {
            return XCTFail("no runtime session id to address the approval to")
        }

        await harness.backend.emit("approval.request", sessionID: runtimeID, payload: .object([
            "command": .string("rm -rf ~/Library/Caches/hermes"),
            "description": .string("clear the cache directory"),
        ]))
        let prompted = await waitUntil { chat.pendingApproval != nil }
        XCTAssertTrue(prompted, "the approval never reached the chat")

        harness.app.releaseChats(keeping: [])

        XCTAssertTrue(
            harness.app.chat(runtimeSessionID: runtimeID) === chat,
            """
            a chat holding a PENDING APPROVAL was released when its route popped. \
            The agent is blocked on "rm -rf ~/Library/Caches/hermes" and the \
            surface that answers it is gone — the request cannot be allowed or \
            denied, and `approval.respond` is positional FIFO, so nothing else \
            can answer it either.
            """
        )
        XCTAssertEqual(
            chat.pendingApproval?.command,
            "rm -rf ~/Library/Caches/hermes",
            "the approval must still be answerable on the surviving chat"
        )
        XCTAssertTrue(
            harness.app.engine.trackedSessionIDs.contains(runtimeID),
            "the blocked session's engine state must survive the pop"
        )

        await harness.tearDown()
    }

    /// Unsent composer work is not recoverable by a reload. A typed draft and a
    /// picked photo live only on the `ChatModel` — `open()` cannot rebuild
    /// either — so a chat holding them is not idle in the sense that matters,
    /// however quiet the session is.
    @MainActor
    func testUnsentComposerWorkKeepsAChatAlive() async throws {
        let harness = await AppHarness.make()
        try await harness.openSocket()

        let storedID = "20260804_101500_a8draft"
        let chat = harness.chat(storedID: storedID)
        await chat.open()
        let bound = await waitUntil { chat.runtimeSessionID != nil }
        XCTAssertTrue(bound, "the chat never bound a runtime session id")
        chat.errorMessage = nil
        guard let runtimeID = chat.runtimeSessionID else {
            return XCTFail("no runtime session id")
        }

        // Typed but not sent, and a photo picked but not sent.
        chat.draft = "before you run that, check the migration order"
        chat.addAttachment(
            data: Data(repeating: 0xFF, count: 64_000),
            filename: "screenshot.png",
            mimeType: "image/png"
        )
        XCTAssertEqual(chat.attachments.count, 1, "precondition: the photo must be staged")

        harness.app.releaseChats(keeping: [])

        XCTAssertTrue(
            harness.app.chat(runtimeSessionID: runtimeID) === chat,
            """
            a chat holding unsent composer work was released when its route \
            popped, and nothing can bring it back — `open()` reloads the \
            transcript, not the draft. The user loses a typed message and a \
            picked photo for tapping Back.
            """
        )
        XCTAssertEqual(
            chat.draft,
            "before you run that, check the migration order",
            "the typed draft must survive the pop"
        )

        // Once the composer is empty the session is genuinely idle and goes.
        chat.draft = ""
        chat.attachments.removeAll()
        harness.app.releaseChats(keeping: [])
        XCTAssertNil(
            harness.app.chat(runtimeSessionID: runtimeID),
            "with nothing unsent left, an off-screen idle chat must be released"
        )

        await harness.tearDown()
    }
}
