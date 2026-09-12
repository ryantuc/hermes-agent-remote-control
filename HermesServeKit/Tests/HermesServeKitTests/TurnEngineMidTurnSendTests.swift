import XCTest

@testable import HermesServeKit

/// BUG-019 — `appendUserEntry` dropped the streaming pointer without clearing
/// `isStreaming` on the entry it pointed at, so a send issued while the
/// assistant was streaming orphaned that bubble. Nothing can find an orphan
/// again: `settleTurn` writes the turn's final text onto a SECOND bubble beside
/// the one that streamed the prefix, `ChatModel.statusLineText` returns nil
/// forever on its `live.entries.contains { $0.isStreaming }` guard, and
/// `MessageBubbleView` draws a typing indicator on a settled turn.
///
/// Every sibling in `TurnEngine` — `sealInterim`, `markInterrupted`,
/// `settleFromStatus` — clears the flag before it drops the pointer. This one
/// did not.
final class TurnEngineMidTurnSendTests: XCTestCase {
    private let session = "a1b2c3d4"

    private func start(_ engine: TurnEngine) {
        engine.apply(GatewayEvent(type: "message.start", sessionID: session, payload: .null, params: .null))
    }

    private func delta(_ text: String, on engine: TurnEngine) {
        engine.apply(GatewayEvent(
            type: "message.delta",
            sessionID: session,
            payload: .object(["text": .string(text)]),
            params: .null
        ))
        engine.flush()
    }

    private func complete(_ text: String, on engine: TurnEngine) {
        engine.apply(GatewayEvent(
            type: "message.complete",
            sessionID: session,
            payload: .object([
                "text": .string(text),
                "status": .string("complete"),
            ]),
            params: .null
        ))
    }

    /// T1 — a mid-turn send (a steer) keeps the running turn's streaming bubble.
    func testMidTurnSendDoesNotOrphanTheStreamingBubble() throws {
        let engine = TurnEngine()
        engine.appendUserEntry(sessionID: session, text: "check the files")
        start(engine)
        delta("Let me check the fi", on: engine)

        var state = engine.state(for: session)
        XCTAssertEqual(state.entries.filter { $0.kind == .assistant }.count, 1)
        XCTAssertTrue(
            state.entries.contains { $0.kind == .assistant && $0.isStreaming },
            "no streaming bubble — the orphan this test is about could not be created"
        )

        engine.appendUserEntry(sessionID: session, text: "actually do X", joiningRunningTurn: true)

        delta("les. Done.", on: engine)
        complete("Let me check the files. Done.", on: engine)

        state = engine.state(for: session)
        XCTAssertEqual(
            state.entries.filter { $0.kind == .assistant }.count,
            1,
            "the reply rendered twice: the bubble that streamed the prefix was orphaned when appendUserEntry dropped the streaming pointer, so message.complete settled its full text onto a second bubble"
        )
        XCTAssertEqual(
            state.entries.first { $0.kind == .assistant }?.text,
            "Let me check the files. Done."
        )
        XCTAssertFalse(
            state.entries.contains { $0.isStreaming },
            "a settled turn may not leave an entry flagged streaming — statusLineText returns nil forever on that flag and MessageBubbleView draws a typing indicator"
        )
    }

    /// T2 — an idle send still opens a fresh bubble, and seals the stale one it
    /// found. This is the regression rail for the `false` branch: the fix must
    /// not turn every idle send into a steer. The stale bubble is the
    /// missed-terminal-frame case (backgrounded socket, gateway restart) —
    /// staged here by streaming a turn that never completes.
    func testIdleSendSealsAStaleBubbleAndStartsAFreshOne() throws {
        let engine = TurnEngine()
        engine.appendUserEntry(sessionID: session, text: "first")
        start(engine)
        delta("half a rep", on: engine)

        engine.appendUserEntry(sessionID: session, text: "second")

        var state = engine.state(for: session)
        XCTAssertFalse(
            state.entries.contains { $0.isStreaming },
            "an idle send abandons the stale turn, so it must seal the bubble it is walking away from"
        )
        XCTAssertEqual(state.entries.last { $0.kind == .assistant }?.text, "half a rep")

        start(engine)
        delta("a fresh reply", on: engine)
        complete("a fresh reply", on: engine)

        state = engine.state(for: session)
        let assistants = state.entries.filter { $0.kind == .assistant }
        XCTAssertEqual(assistants.count, 2, "the new turn must not extend the abandoned bubble")
        XCTAssertEqual(assistants.first?.text, "half a rep")
        XCTAssertEqual(assistants.last?.text, "a fresh reply")
        XCTAssertFalse(state.entries.contains { $0.isStreaming })
    }

    /// T3 — `joiningRunningTurn: true` with no open stream is a no-op. This
    /// pins the `streaming == nil` leg of the pointer condition, which is the
    /// one an implementer is most likely to drop: a caller reading a stale
    /// `isBusy` must not be able to leave a dangling pointer behind.
    func testJoiningWithNoOpenStreamIsANoOp() throws {
        let engine = TurnEngine()
        engine.appendUserEntry(sessionID: session, text: "first", joiningRunningTurn: true)

        var state = engine.state(for: session)
        XCTAssertFalse(state.entries.contains { $0.isStreaming })
        XCTAssertEqual(state.entries.filter { $0.kind == .assistant }.count, 0)

        // A pointer left over from the join would make this delta extend an
        // entry that does not exist; a nil one opens exactly one fresh bubble.
        start(engine)
        delta("a reply", on: engine)
        complete("a reply", on: engine)

        state = engine.state(for: session)
        XCTAssertEqual(state.entries.filter { $0.kind == .assistant }.count, 1)
        XCTAssertEqual(state.entries.last { $0.kind == .assistant }?.text, "a reply")
        XCTAssertFalse(state.entries.contains { $0.isStreaming })
    }

    /// BUG-021 T6 - `setNoticeKind` labels a known entry and refuses an unknown
    /// one. `ChatModel.stampAck` relies on that refusal to stay safe after a
    /// rebind has forgotten the state the entry lived in.
    func testSetNoticeKindLabelsAKnownEntryAndRefusesAnUnknownOne() throws {
        let engine = TurnEngine()
        let entryID = engine.appendUserEntry(sessionID: session, text: "do it differently")

        XCTAssertTrue(engine.setNoticeKind(sessionID: session, entryID: entryID, kind: "correction"))
        XCTAssertEqual(
            engine.state(for: session).entries.first { $0.id == entryID }?.noticeKind,
            "correction"
        )

        XCTAssertFalse(engine.setNoticeKind(sessionID: session, entryID: "no-such-entry", kind: "queued"))
        XCTAssertFalse(engine.setNoticeKind(sessionID: "no-such-session", entryID: entryID, kind: "queued"))
        XCTAssertEqual(
            engine.state(for: session).entries.first { $0.id == entryID }?.noticeKind,
            "correction",
            "a refused call must mutate nothing"
        )
    }
}
