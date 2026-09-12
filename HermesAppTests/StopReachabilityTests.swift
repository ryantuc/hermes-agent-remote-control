import HermesServeKit
import XCTest

@testable import HermesMobile

/// **BUG-013 (A)** — a Stop control is on screen whenever the screen claims
/// work is happening.
///
/// The trap this pins: the subagent reducer deliberately does not claim
/// `isBusy` (a background agent outlives its turn) and terminal rows are pruned
/// only at the next `message.start`, so a settled parent turn leaves the
/// activity strip drawing a running agent while the composer's only "is
/// anything running" signal reads false. Both Stop controls are gated on that
/// signal, so on a device agents spin with no way to interrupt them.
///
/// These are state assertions, not view assertions — this target has no UI
/// tests. What they establish is that the two `ChatModel` derivations the
/// composer and the toolbar read say "show Stop" in the state that produced the
/// report, and still say "hide it" when nothing is running at all.
@MainActor
final class StopReachabilityTests: XCTestCase {

    private static func subagentPayload(
        id: String,
        goal: String,
        extra: [String: JSONValue] = [:]
    ) -> JSONValue {
        var payload: [String: JSONValue] = [
            "subagent_id": .string(id),
            "goal": .string(goal),
            "task_index": .number(0),
            "task_count": .number(1),
        ]
        for (key, value) in extra { payload[key] = value }
        return .object(payload)
    }

    private func openChat(_ harness: AppHarness, storedID: String) async throws -> (ChatModel, String) {
        let chat = harness.chat(storedID: storedID)
        await chat.open()
        let bound = await waitUntil { chat.runtimeSessionID != nil }
        XCTAssertTrue(bound, "open() never bound a runtime id — nothing after this proves anything")
        return (chat, try XCTUnwrap(chat.runtimeSessionID))
    }

    /// The reported state, end to end: parent turn complete, one agent still
    /// running. Before the fix `isTurnActive` was false here and the screen had
    /// no Stop in either composer state.
    func testStopStaysReachableWhileAnAgentOutlivesItsTurn() async throws {
        let harness = await AppHarness.make()
        try await harness.openSocket()
        let (chat, runtimeID) = try await openChat(harness, storedID: "20260814_030000_stop")
        chat.errorMessage = nil

        await harness.backend.emit("message.start", sessionID: runtimeID)
        await harness.backend.emit("subagent.start", sessionID: runtimeID,
                                   payload: Self.subagentPayload(id: "sa-live", goal: "Long background job"))
        await harness.backend.emit("message.complete", sessionID: runtimeID, payload: .object([
            "text": .string("Kicked it off."),
            "status": .string("complete"),
        ]))

        let staged = await waitUntil {
            !chat.live.isBusy && chat.live.activity.runningSubagents.count == 1
        }
        XCTAssertTrue(staged, """
            precondition: a settled turn with one agent still running. \
            isBusy=\(chat.live.isBusy) running=\(chat.live.activity.runningSubagents.count)
            """)

        XCTAssertTrue(chat.isTurnActive, """
            the strip is drawing a running agent, so the composer must agree that \
            something is running — this is the whole of BUG-013 mechanism 1
            """)
        XCTAssertTrue(chat.showsStopControl,
                      "an empty composer over a running agent must put Stop in the send slot")
        XCTAssertFalse(chat.showsSecondaryStop,
                       "no secondary Stop while the primary slot already is one")

        // …and the typed-draft state routes to the compact secondary Stop, so
        // the control exists whatever the field holds.
        chat.draft = "steer it"
        XCTAssertFalse(chat.showsStopControl, "text in the field keeps the primary slot a Send")
        XCTAssertTrue(chat.showsSecondaryStop,
                      "…and moves the Stop to the compact control beside it")
        chat.draft = ""

        await harness.tearDown()
    }

    /// The other half, and the reason this is a widening rather than a Stop
    /// that is always on: once the last agent reports terminal, the composer
    /// goes quiet again. A Stop that never leaves would be the same lie in the
    /// other direction.
    func testStopGoesAwayWhenTheLastAgentFinishes() async throws {
        let harness = await AppHarness.make()
        try await harness.openSocket()
        let (chat, runtimeID) = try await openChat(harness, storedID: "20260814_030100_stop")
        chat.errorMessage = nil

        await harness.backend.emit("message.start", sessionID: runtimeID)
        await harness.backend.emit("subagent.start", sessionID: runtimeID,
                                   payload: Self.subagentPayload(id: "sa-live", goal: "Short background job"))
        await harness.backend.emit("message.complete", sessionID: runtimeID, payload: .object([
            "text": .string("Kicked it off."),
            "status": .string("complete"),
        ]))
        let staged = await waitUntil {
            !chat.live.isBusy && chat.live.activity.runningSubagents.count == 1
        }
        XCTAssertTrue(staged, "precondition: a settled turn with one agent still running")
        XCTAssertTrue(chat.isTurnActive, "precondition: Stop is showing")

        await harness.backend.emit("subagent.complete", sessionID: runtimeID,
                                   payload: Self.subagentPayload(id: "sa-live", goal: "Short background job",
                                                                 extra: ["status": .string("completed"),
                                                                         "summary": .string("All clear."),
                                                                         "duration_seconds": .number(3)]))
        let finished = await waitUntil { chat.live.activity.runningSubagents.isEmpty }
        XCTAssertTrue(finished, "the agent never reported terminal")

        XCTAssertFalse(chat.isTurnActive,
                       "nothing is running any more, so the composer must stop claiming it is")
        XCTAssertFalse(chat.showsStopControl, "…and the send slot goes back to Send")

        await harness.tearDown()
    }

    /// The plain negative control: a session that never delegated anything is
    /// unaffected by the third term.
    func testAnIdleSessionWithNoAgentsShowsNoStop() async throws {
        let harness = await AppHarness.make()
        try await harness.openSocket()
        let (chat, _) = try await openChat(harness, storedID: "20260814_030200_stop")
        chat.errorMessage = nil

        XCTAssertTrue(chat.live.activity.runningSubagents.isEmpty, "precondition: no agents at all")
        XCTAssertFalse(chat.isTurnActive)
        XCTAssertFalse(chat.showsStopControl)
        XCTAssertFalse(chat.showsSecondaryStop)

        await harness.tearDown()
    }
}
