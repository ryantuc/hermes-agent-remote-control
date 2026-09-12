import XCTest

@testable import HermesServeKit

/// BUG-068 — what the interrupt latch still let through.
///
/// The latch redesign gated sixteen turn-scoped reducers on `!latched` and left
/// three residues behind: `errorEvent` and `toolOutputRisk` were never gated at
/// all, a risk held before the Stop stayed held across into the next turn, and
/// the delta buffer was not sealed against the window between a Stop and the
/// resend that follows it.
///
/// These are transcript-integrity assertions. Nothing here is about a crash:
/// every failure they pin shows the user words, a status, or a safety band that
/// belongs to a turn they cancelled.
final class TurnEngineLatchResidualTests: XCTestCase {
    private let session = "a1b2c3d4"

    private func start(_ engine: TurnEngine) {
        engine.apply(GatewayEvent(type: "message.start", sessionID: session, payload: .null, params: .null))
    }

    private func delta(_ engine: TurnEngine, _ text: String) {
        engine.apply(GatewayEvent(
            type: "message.delta",
            sessionID: session,
            payload: .object(["text": .string(text)]),
            params: .null
        ))
    }

    private func errorEvent(_ engine: TurnEngine, _ message: String) {
        engine.apply(GatewayEvent(
            type: "error",
            sessionID: session,
            payload: .object(["message": .string(message)]),
            params: .null
        ))
    }

    private func risk(_ engine: TurnEngine, tool name: String, id: String, band: String) {
        engine.apply(GatewayEvent(
            type: "tool.output_risk",
            sessionID: session,
            payload: .object([
                "tool_id": .string(id),
                "name": .string(name),
                "risk": .string(band),
                "findings": .array([.string("Output contains an instruction to exfiltrate ~/.ssh/id_rsa")]),
                "redacted": .bool(false),
            ]),
            params: .null
        ))
    }

    private func toolStart(_ engine: TurnEngine, name: String, id: String) {
        engine.apply(GatewayEvent(
            type: "tool.start",
            sessionID: session,
            payload: .object(["tool_id": .string(id), "name": .string(name), "context": .string("ls")]),
            params: .null
        ))
    }

    private func toolComplete(_ engine: TurnEngine, name: String, id: String) {
        engine.apply(GatewayEvent(
            type: "tool.complete",
            sessionID: session,
            payload: .object(["tool_id": .string(id), "name": .string(name), "result": .string("done")]),
            params: .null
        ))
    }

    // MARK: - B: `errorEvent` while latched

    /// The stopped bubble already says what happened. A late failure from the
    /// turn the user cancelled must not rewrite it to `status = "error"`, and —
    /// since `markInterrupted` nils the streaming pointer — must not append a
    /// second, duplicate error notice underneath it either.
    func testALateErrorFromTheCancelledTurnLeavesTheStoppedBubbleAlone() {
        let engine = TurnEngine()
        engine.appendUserEntry(sessionID: session, text: "go")
        start(engine)
        delta(engine, "partial")
        engine.flush()
        engine.markInterrupted(sessionID: session)

        let before = engine.state(for: session)
        XCTAssertEqual(before.entries.last?.status, "interrupted", "precondition")
        let countBefore = before.entries.count

        errorEvent(engine, "the turn was cancelled by the server")

        let state = engine.state(for: session)
        XCTAssertEqual(state.entries.count, countBefore, "a late error must not append a duplicate notice")
        XCTAssertEqual(state.entries.last?.status, "interrupted", "the stopped bubble keeps its own status")
        XCTAssertEqual(state.entries.last?.errorText, "", "the stopped bubble is not relabelled a failure")
        XCTAssertNil(state.lastError, "the cancelled turn's failure is not news")
    }

    /// The control that keeps the guard honest. Once the latch is gone — a
    /// resend cleared it — an error is an ordinary error and must still be
    /// shown. A guard that swallowed those would trade one silent failure for
    /// a worse one.
    func testAnErrorOnANewTurnStillReportsNormally() {
        let engine = TurnEngine()
        engine.appendUserEntry(sessionID: session, text: "go")
        start(engine)
        engine.markInterrupted(sessionID: session)
        engine.clearInterrupted(sessionID: session)
        engine.appendUserEntry(sessionID: session, text: "again")
        start(engine)

        errorEvent(engine, "the model refused")

        let state = engine.state(for: session)
        XCTAssertEqual(state.lastError, "the model refused")
        XCTAssertFalse(state.isBusy)
    }

    /// A foreign-origin failure still reports after a local Stop: that turn
    /// was never cancelled here. Own-origin / unstamped late errors stay dropped
    /// (the case covered by `testALateErrorFromTheCancelledTurnLeavesTheStoppedBubbleAlone`).
    func testAForeignOriginErrorAfterStopStillReports() {
        let engine = TurnEngine()
        engine.setLocalOrigin("phone")
        engine.appendUserEntry(sessionID: session, text: "go")
        start(engine)
        engine.markInterrupted(sessionID: session, at: Date().addingTimeInterval(-60))

        engine.apply(GatewayEvent(
            type: "error",
            sessionID: session,
            payload: .object(["message": .string("the desktop's turn failed")]),
            params: .object(["origin": .string("desktop")])
        ))

        XCTAssertEqual(engine.state(for: session).lastError, "the desktop's turn failed")
    }

    // MARK: - B: `toolOutputRisk` while latched

    /// A safety band arriving after Stop belongs to the cancelled turn. It must
    /// not band that turn's card…
    func testALateRiskDoesNotBandTheCancelledTurnsCard() {
        let engine = TurnEngine()
        engine.appendUserEntry(sessionID: session, text: "go")
        start(engine)
        toolStart(engine, name: "terminal", id: "call_1")
        engine.markInterrupted(sessionID: session)

        risk(engine, tool: "terminal", id: "call_1", band: "high")

        let card = engine.state(for: session).entries.compactMap(\.tool).first { $0.name == "terminal" }
        XCTAssertEqual(card?.outputRisk ?? "", "", "a risk from the cancelled turn must not band its card")
        XCTAssertFalse(card?.hasOutputRisk ?? true)
    }

    /// …and, the worse half, must not be *held* — because `attachRisk` matches
    /// by tool name with `requireRunning: false`, so a held band finds the next
    /// turn's same-named card and puts a safety finding on a tool call that
    /// never produced it.
    func testALateRiskIsNotHeldForTheNextTurnsSameNamedCard() {
        let engine = TurnEngine()
        engine.appendUserEntry(sessionID: session, text: "go")
        start(engine)
        engine.markInterrupted(sessionID: session)

        // No card exists, so the old code held this rather than dropping it.
        risk(engine, tool: "terminal", id: "call_1", band: "high")

        // A new turn runs `terminal` again.
        engine.clearInterrupted(sessionID: session)
        engine.appendUserEntry(sessionID: session, text: "now list the directory")
        start(engine)
        toolStart(engine, name: "terminal", id: "call_2")
        toolComplete(engine, name: "terminal", id: "call_2")

        let cards = engine.state(for: session).entries.compactMap(\.tool).filter { $0.name == "terminal" }
        let banded = cards.filter(\.hasOutputRisk)
        XCTAssertTrue(banded.isEmpty, "the cancelled turn's finding attached to the next turn's card")
    }

    /// The Stop itself clears anything already held. A risk that arrived before
    /// the Stop and never found its card is the cancelled turn's, and
    /// `markInterrupted` is the other end of the same turn `message.start`
    /// already clears this for.
    func testStopDropsARiskHeldFromBeforeIt() {
        let engine = TurnEngine()
        engine.appendUserEntry(sessionID: session, text: "go")
        start(engine)
        // Tool progress off: the risk beats its card, so it is held.
        risk(engine, tool: "web_fetch", id: "call_12", band: "high")
        engine.markInterrupted(sessionID: session)

        engine.clearInterrupted(sessionID: session)
        engine.appendUserEntry(sessionID: session, text: "fetch it again")
        start(engine)
        toolComplete(engine, name: "web_fetch", id: "call_13")

        let card = engine.state(for: session).entries.compactMap(\.tool).last { $0.name == "web_fetch" }
        XCTAssertNotNil(card, "precondition: the next turn produced a web_fetch card")
        XCTAssertFalse(card?.hasOutputRisk ?? true, "a risk held before the Stop leaked into the next turn")
    }

    /// The control for the risk guard: an ordinary live turn still bands.
    func testAnOrdinaryRiskStillReachesItsCard() {
        let engine = TurnEngine()
        engine.appendUserEntry(sessionID: session, text: "go")
        start(engine)
        toolStart(engine, name: "terminal", id: "call_1")
        risk(engine, tool: "terminal", id: "call_1", band: "high")

        let card = engine.state(for: session).entries.compactMap(\.tool).first { $0.name == "terminal" }
        XCTAssertEqual(card?.outputRisk, "high")
        XCTAssertEqual(card?.outputRiskFindings.count, 1)
    }

    // MARK: - A: the buffer seal across Stop → resend

    /// The headline under the no-timer latch. A backend still emitting a
    /// minute after Stop is still latched, so the tail never buffers; the
    /// resend's buffer seal remains belt-and-braces if anything did.
    func testTheResendDoesNotDrainTheCancelledTurnsTailIntoTheNextTurn() {
        let engine = TurnEngine()
        engine.appendUserEntry(sessionID: session, text: "go")
        start(engine)
        delta(engine, "partial")
        engine.flush()

        // Stop a minute ago. Without a wall-clock exit the latch still holds,
        // so the cancelled tail is dropped rather than buffered.
        engine.markInterrupted(sessionID: session, at: Date().addingTimeInterval(-60))
        delta(engine, " and here is the rest of the cancelled answer")
        XCTAssertFalse(engine.hasPendingDeltas, "a latched post-Stop tail must not buffer")

        // The resend, exactly as `performSend` sequences it.
        engine.clearInterrupted(sessionID: session)
        engine.appendUserEntry(sessionID: session, text: "second question")
        engine.flush()

        let state = engine.state(for: session)
        for entry in state.entries {
            XCTAssertFalse(
                entry.text.contains("the rest of the cancelled answer"),
                "turn A's tail was materialised into turn B"
            )
        }
        XCTAssertEqual(state.entries.last?.kind, .user, "nothing was appended after the new user message")
        XCTAssertEqual(state.entries.last?.text, "second question")

        let assistants = state.entries.filter { $0.kind == .assistant }
        XCTAssertEqual(assistants.count, 1, "the cancelled turn's tail must not seed a second bubble")
        XCTAssertEqual(assistants.first?.text, "partial", "the stopped bubble keeps what it had shown")
        XCTAssertEqual(assistants.first?.status, "interrupted")
    }

    /// The seal is scoped to the resend and must not eat a live turn's stream.
    /// A buffer filled by a turn that is genuinely running is flushed as
    /// normal.
    func testAnOrdinaryFlushStillMaterialisesItsBuffer() {
        let engine = TurnEngine()
        engine.appendUserEntry(sessionID: session, text: "go")
        start(engine)
        delta(engine, "hello ")
        delta(engine, "world")
        engine.flush()

        let assistants = engine.state(for: session).entries.filter { $0.kind == .assistant }
        XCTAssertEqual(assistants.last?.text, "hello world")
    }
}
