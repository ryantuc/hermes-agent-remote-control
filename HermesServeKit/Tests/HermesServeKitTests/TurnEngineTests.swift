import XCTest

@testable import HermesServeKit

/// The turn state machine, driven by the same event scripts the backend emits.
final class TurnEngineTests: XCTestCase {
    private let session = "a1b2c3d4"

    private func run(_ fixture: String, on engine: TurnEngine) throws {
        for event in try Fixtures.events(fixture) {
            engine.apply(event)
        }
        engine.flush()
    }

    /// The reference turn timeline end to end (jsonrpc-methods §8).
    func testFullTurnScript() throws {
        let engine = TurnEngine()
        engine.appendUserEntry(sessionID: session, text: "fix the failing test")
        try run("turn-script", on: engine)

        let state = engine.state(for: session)
        XCTAssertFalse(state.isBusy, "message.complete ends the turn")
        XCTAssertFalse(state.needsInput)
        XCTAssertTrue(state.pendingApprovals.isEmpty, "message.complete clears pending prompts")
        XCTAssertNil(state.lastError)

        let user = try XCTUnwrap(state.entries.first { $0.kind == .user })
        XCTAssertEqual(user.text, "fix the failing test")

        // Reasoning accumulates per session (there is no message id on the
        // wire) and seals into its own segment when the tool card opens, so the
        // reply text lands in a fresh bubble below the card.
        let assistants = state.entries.filter { $0.kind == .assistant }
        XCTAssertEqual(assistants.count, 2)
        XCTAssertEqual(assistants[0].reasoning, "The assertion compares the wrong field.")
        XCTAssertTrue(assistants[0].text.isEmpty)
        XCTAssertFalse(assistants[0].isStreaming)

        let assistant = try XCTUnwrap(state.entries.last { $0.kind == .assistant })
        XCTAssertEqual(assistant.text, "I fixed the test.")
        XCTAssertFalse(assistant.isStreaming)
        XCTAssertEqual(assistant.status, "complete")

        let tool = try XCTUnwrap(state.entries.compactMap(\.tool).first)
        XCTAssertEqual(tool.name, "terminal")
        XCTAssertEqual(tool.context, "pytest -q")
        XCTAssertFalse(tool.isRunning, "tool.complete closes the card")
        XCTAssertEqual(tool.resultText, "1 passed in 0.42s")
        XCTAssertEqual(tool.durationSeconds, 4.1)
        XCTAssertFalse(tool.isError)

        // Ordering: the user turn leads, the tool card sits between the
        // reasoning and the reply, and nothing jumps ahead of the text that
        // preceded it.
        XCTAssertEqual(state.entries.first?.kind, .user)
        let toolIndex = try XCTUnwrap(state.entries.firstIndex { $0.kind == .tool })
        let replyIndex = try XCTUnwrap(state.entries.lastIndex { $0.kind == .assistant })
        XCTAssertLessThan(toolIndex, replyIndex, "the tool ran before the reply text streamed")
    }

    /// Deltas are buffered and only materialize on flush — the UI never
    /// re-renders per token (reference §3.3).
    func testDeltasOnlyMaterializeOnFlush() throws {
        let engine = TurnEngine()
        for event in try Fixtures.events("event-message-delta-coalesced") {
            engine.apply(event)
        }
        XCTAssertTrue(engine.hasPendingDeltas)
        XCTAssertTrue(engine.state(for: session).entries.isEmpty, "nothing renders before a flush")

        let touched = engine.flush()
        XCTAssertEqual(touched, [session])
        XCTAssertFalse(engine.hasPendingDeltas)
        XCTAssertEqual(engine.state(for: session).entries.first?.text, "I fixed the test.")
        XCTAssertTrue(engine.state(for: session).entries.first?.isStreaming == true)
    }

    /// A failed turn ends at `message.complete {status: "error"}` — there is no
    /// separate error event — and `partial: true` keeps the streamed text.
    func testErrorStatusCompletion() throws {
        let engine = TurnEngine()
        try run("turn-error-completion", on: engine)

        let state = engine.state(for: session)
        XCTAssertFalse(state.isBusy)
        XCTAssertEqual(state.lastError, "provider returned 529 overloaded")

        let assistant = try XCTUnwrap(state.entries.last { $0.kind == .assistant })
        XCTAssertEqual(assistant.status, "error")
        XCTAssertTrue(assistant.isError)
        XCTAssertTrue(assistant.isPartial)
        XCTAssertEqual(
            assistant.text, "Let me check the log",
            "partial: true means `text` is streamed output worth keeping, not the error string"
        )
        XCTAssertEqual(assistant.errorText, "provider returned 529 overloaded")
        XCTAssertFalse(assistant.isStreaming)
    }

    /// Approvals queue FIFO per session because the event carries no
    /// `request_id`; another session's approval parks separately.
    func testApprovalQueueIsFIFOPerSession() throws {
        let engine = TurnEngine()
        try run("approval-queue", on: engine)

        var state = engine.state(for: session)
        XCTAssertTrue(state.needsInput)
        XCTAssertEqual(state.pendingApprovals.count, 2)
        XCTAssertEqual(state.currentApproval?.command, "rm -rf build")
        XCTAssertTrue(state.currentApproval?.isLikelyDestructive == true)

        // Choices arrive verbatim when the server sent them…
        XCTAssertEqual(state.pendingApprovals[0].choices, [.once, .session, .always, .deny])
        // …and are synthesized when it did not: smart_denied ⇒ [once, deny].
        XCTAssertTrue(state.pendingApprovals[1].smartDenied)
        XCTAssertEqual(state.pendingApprovals[1].choices, [.once, .deny])

        // Resolving the head advances the queue in order.
        engine.removeApproval(sessionID: session, id: state.pendingApprovals[0].id)
        state = engine.state(for: session)
        XCTAssertEqual(state.pendingApprovals.count, 1)
        XCTAssertEqual(state.currentApproval?.command, "curl https://example.com/install.sh | sh")
        XCTAssertTrue(state.needsInput)

        engine.removeApproval(sessionID: session, id: try XCTUnwrap(state.currentApproval?.id))
        XCTAssertFalse(engine.state(for: session).needsInput)

        // A background session's approval waits on its own queue rather than
        // hijacking the foreground.
        let other = engine.state(for: "ffff0000")
        XCTAssertEqual(other.pendingApprovals.count, 1)
        XCTAssertEqual(
            other.currentApproval?.choices, [.once, .session, .deny],
            "allow_permanent: false must remove the Always option"
        )
    }

    /// `allow_permanent` synthesis must match the backend's identity check
    /// (`payload.get("allow_permanent") is False`), not a coerced Bool. Int 0
    /// is not Python False, so Always must still be offered.
    func testAllowPermanentRawJSONSemantics() {
        func choices(for permanent: JSONValue?) -> [ApprovalChoice] {
            var payload: [String: JSONValue] = ["command": .string("ls")]
            if let permanent { payload["allow_permanent"] = permanent }
            return ApprovalRequestEvent(sessionID: session, payload: .object(payload)).choices
        }

        XCTAssertEqual(
            choices(for: nil), [.once, .session, .always, .deny],
            "absent key → Always offered"
        )
        XCTAssertEqual(
            choices(for: .bool(false)), [.once, .session, .deny],
            "explicit boolean false → no Always"
        )
        XCTAssertEqual(
            choices(for: .number(0)), [.once, .session, .always, .deny],
            "int 0 is not Python False → Always still offered"
        )
        XCTAssertEqual(
            choices(for: .bool(true)), [.once, .session, .always, .deny],
            "explicit boolean true → Always offered"
        )
    }

    /// Routing: explicit session wins, unscoped turn events pin to the session
    /// that received `message.start`, `subagent.*` unscoped is dropped, and the
    /// pin clears at `message.complete`.
    func testUnscopedEventsPinToTheStartedSession() throws {
        let engine = TurnEngine()
        let events = try Fixtures.events("unscoped-turn-events")

        engine.apply(events[0])  // message.start on a1b2c3d4
        XCTAssertEqual(engine.pinnedSessionID, session)

        XCTAssertEqual(engine.apply(events[1]), session, "an unscoped delta belongs to the pinned turn")
        XCTAssertNil(engine.apply(events[2]), "unscoped subagent.* must be dropped, never attached")
        XCTAssertEqual(engine.apply(events[3]), session, "an unscoped tool.start pins too")

        engine.flush()
        XCTAssertEqual(engine.state(for: session).entries.first { $0.kind == .assistant }?.text, "pinned text")
        XCTAssertEqual(engine.state(for: session).entries.compactMap(\.tool).first?.name, "read_file")

        engine.apply(events[4])  // message.complete
        XCTAssertNil(engine.pinnedSessionID, "the pin clears at message.complete")

        XCTAssertNil(engine.apply(events[5]), "an unscoped delta with no pin has nowhere to go")
        engine.flush()
        XCTAssertFalse(
            engine.state(for: session).entries.contains { $0.text.contains("orphan") },
            "a post-turn orphan delta must not leak into the last session"
        )
    }

    /// `message.interim` seals the bubble so a later `message.complete` cannot
    /// wipe it; a final text that continues the interim settles onto it rather
    /// than duplicating.
    func testInterimSealAndContinuation() throws {
        let engine = TurnEngine()
        try run("turn-interim-seal", on: engine)

        let state = engine.state(for: session)
        let assistants = state.entries.filter { $0.kind == .assistant }
        XCTAssertEqual(assistants.count, 1, "the final text continued the interim; no duplicate bubble")
        XCTAssertEqual(assistants[0].text, "Checking the repository first. Done.")
        XCTAssertFalse(assistants[0].isInterim, "settling clears the interim flag")
        XCTAssertEqual(assistants[0].status, "complete")

        // An unrelated final text appends instead of overwriting the interim.
        let engine2 = TurnEngine()
        let events = try Fixtures.events("turn-interim-seal")
        for event in events.dropLast() { engine2.apply(event) }
        engine2.flush()
        XCTAssertTrue(engine2.state(for: session).entries.last?.isInterim == true)
        engine2.apply(GatewayEvent(
            type: "message.complete",
            sessionID: session,
            payload: .object(["text": .string("Something else entirely."), "status": .string("complete")]),
            params: .null
        ))
        let entries = engine2.state(for: session).entries.filter { $0.kind == .assistant }
        XCTAssertEqual(entries.count, 2, "an unrelated final text must not overwrite a sealed interim")
        XCTAssertTrue(entries[0].isInterim)
        XCTAssertEqual(entries[1].text, "Something else entirely.")
    }

    /// The local interrupt latch is authoritative: a stale `message.start`
    /// still in flight must not restart the turn (reference §3.5).
    func testInterruptLatchIgnoresStaleStart() throws {
        let engine = TurnEngine()
        engine.appendUserEntry(sessionID: session, text: "go")
        engine.apply(GatewayEvent(type: "message.start", sessionID: session, payload: .null, params: .null))
        engine.apply(GatewayEvent(
            type: "message.delta",
            sessionID: session,
            payload: .object(["text": .string("partial")]),
            params: .null
        ))
        engine.flush()

        engine.markInterrupted(sessionID: session)
        var state = engine.state(for: session)
        XCTAssertFalse(state.isBusy)
        XCTAssertTrue(state.interrupted)
        XCTAssertEqual(state.entries.last?.status, "interrupted")

        // A late start/delta pair from the cancelled turn arrives.
        engine.apply(GatewayEvent(type: "message.start", sessionID: session, payload: .null, params: .null))
        state = engine.state(for: session)
        XCTAssertFalse(state.isBusy, "message.start is skipped entirely while interrupted")
    }

    /// A late `message.delta` after Stop must not buffer or seed a brand-new
    /// assistant bubble (desktop use-message-stream interrupted short-circuit).
    func testInterruptLatchDropsLateDelta() throws {
        let engine = TurnEngine()
        engine.appendUserEntry(sessionID: session, text: "go")
        engine.apply(GatewayEvent(type: "message.start", sessionID: session, payload: .null, params: .null))
        engine.apply(GatewayEvent(
            type: "message.delta",
            sessionID: session,
            payload: .object(["text": .string("partial")]),
            params: .null
        ))
        engine.flush()
        engine.markInterrupted(sessionID: session)

        let entryCountBefore = engine.state(for: session).entries.count
        let textBefore = engine.state(for: session).entries.last { $0.kind == .assistant }?.text

        engine.apply(GatewayEvent(
            type: "message.delta",
            sessionID: session,
            payload: .object(["text": .string(" stale tail")]),
            params: .null
        ))
        engine.flush()

        let state = engine.state(for: session)
        XCTAssertEqual(state.entries.count, entryCountBefore, "late delta must not create an entry")
        XCTAssertEqual(
            state.entries.last { $0.kind == .assistant }?.text, textBefore,
            "late delta must not extend the interrupted bubble"
        )
        XCTAssertFalse(state.isBusy, "late delta must not flip isBusy back on")
        XCTAssertTrue(state.interrupted)
        XCTAssertFalse(engine.hasPendingDeltas, "late delta must not remain buffered")
    }

    /// A late `message.complete` after Stop settles the turn (isBusy false)
    /// without applying the cancelled turn's text onto a fresh bubble.
    func testInterruptLatchSettlesLateCompleteWithoutText() throws {
        let engine = TurnEngine()
        engine.appendUserEntry(sessionID: session, text: "go")
        engine.apply(GatewayEvent(type: "message.start", sessionID: session, payload: .null, params: .null))
        engine.apply(GatewayEvent(
            type: "message.delta",
            sessionID: session,
            payload: .object(["text": .string("partial")]),
            params: .null
        ))
        engine.flush()
        engine.markInterrupted(sessionID: session)

        let entryCountBefore = engine.state(for: session).entries.count
        let textBefore = engine.state(for: session).entries.last { $0.kind == .assistant }?.text

        engine.apply(GatewayEvent(
            type: "message.complete",
            sessionID: session,
            payload: .object([
                "text": .string("partial stale full completion"),
                "status": .string("interrupted"),
            ]),
            params: .null
        ))

        let state = engine.state(for: session)
        XCTAssertFalse(state.isBusy, "late complete must leave isBusy false")
        XCTAssertFalse(state.needsInput)
        XCTAssertEqual(state.entries.count, entryCountBefore, "late complete must not append a bubble")
        XCTAssertEqual(
            state.entries.last { $0.kind == .assistant }?.text, textBefore,
            "late complete must not replace the partial with the cancelled full text"
        )
        // DELIBERATELY REVERSED (was `XCTAssertTrue`). The terminal frame of the
        // cancelled turn now RELEASES the latch: the gateway sends exactly one
        // per turn, so whatever arrives next belongs to a different turn —
        // possibly one another client started — and holding the latch until the
        // next local send would drop that turn entirely.
        XCTAssertFalse(state.interrupted, "the cancelled turn's terminal frame releases the latch")
    }

    /// After an interrupt, a genuine new user message clears the latch and a
    /// following `message.start` flows normally — the app must not freeze.
    func testInterruptLatchAllowsSubsequentGenuineTurn() throws {
        let engine = TurnEngine()
        engine.appendUserEntry(sessionID: session, text: "first")
        engine.apply(GatewayEvent(type: "message.start", sessionID: session, payload: .null, params: .null))
        engine.apply(GatewayEvent(
            type: "message.delta",
            sessionID: session,
            payload: .object(["text": .string("partial")]),
            params: .null
        ))
        engine.flush()
        engine.markInterrupted(sessionID: session)
        XCTAssertTrue(engine.state(for: session).interrupted)

        engine.appendUserEntry(sessionID: session, text: "second")
        var state = engine.state(for: session)
        XCTAssertFalse(state.interrupted, "appendUserEntry clears the interrupt latch")
        XCTAssertTrue(state.isBusy)

        engine.apply(GatewayEvent(type: "message.start", sessionID: session, payload: .null, params: .null))
        engine.apply(GatewayEvent(
            type: "message.delta",
            sessionID: session,
            payload: .object(["text": .string("fresh reply")]),
            params: .null
        ))
        engine.flush()
        engine.apply(GatewayEvent(
            type: "message.complete",
            sessionID: session,
            payload: .object(["text": .string("fresh reply"), "status": .string("complete")]),
            params: .null
        ))

        state = engine.state(for: session)
        XCTAssertFalse(state.isBusy)
        XCTAssertFalse(state.interrupted)
        let assistants = state.entries.filter { $0.kind == .assistant }
        XCTAssertEqual(assistants.last?.text, "fresh reply")
        XCTAssertEqual(assistants.last?.status, "complete")
        XCTAssertTrue(state.entries.contains { $0.kind == .user && $0.text == "second" })
    }

    /// Mid-turn reconnect: the `inflight` snapshot repaints the partial turn,
    /// its user row is de-duplicated against the persisted tail, corrections
    /// become their own bubbles, and `auto_continue` is surfaced.
    func testResumeProjectionDedupesPersistedUserTurn() throws {
        let engine = TurnEngine()
        let result = SessionAPI.decodeResume(
            try Fixtures.result("response-session-resume-inflight"),
            requested: "20260731_170500_ab12ef"
        )
        XCTAssertEqual(result.sessionID, "99887766", "resume mints a NEW runtime id")
        XCTAssertEqual(result.sessionKey, "20260731_170500_ab12ef")

        let inflight = try XCTUnwrap(result.inflight)
        XCTAssertTrue(inflight.streaming)
        XCTAssertEqual(inflight.corrections, ["actually check tests/test_api.py first"])

        // The persisted transcript already ends with that user turn.
        engine.applyResumeProjection(
            sessionID: result.sessionID,
            result: result,
            trailingUserTexts: ["fix the failing test"]
        )
        let state = engine.state(for: result.sessionID)
        let userTexts = state.entries.filter { $0.kind == .user }.map(\.text)
        XCTAssertFalse(
            userTexts.contains("fix the failing test"),
            "the projected prompt duplicates a persisted row and must be suppressed"
        )
        XCTAssertTrue(userTexts.contains("actually check tests/test_api.py first"))
        XCTAssertTrue(userTexts.contains("then open a PR"), "a queued prompt must survive the reconnect")

        let assistant = try XCTUnwrap(state.entries.last { $0.kind == .assistant })
        XCTAssertEqual(assistant.text, "Reading the traceback")
        XCTAssertTrue(assistant.isStreaming)
        XCTAssertTrue(state.isBusy)
        XCTAssertEqual(engine.pinnedSessionID, result.sessionID)
        XCTAssertNotNil(state.autoContinue)
        XCTAssertTrue(state.entries.contains { $0.noticeKind == "auto_continue" })

        // Without the persisted row the projection must keep the prompt.
        let engine2 = TurnEngine()
        engine2.applyResumeProjection(sessionID: result.sessionID, result: result, trailingUserTexts: [])
        XCTAssertTrue(
            engine2.state(for: result.sessionID).entries
                .filter { $0.kind == .user }.map(\.text)
                .contains("fix the failing test")
        )
    }

    /// A respawned backend recycles runtime ids; the live state has to move
    /// with the thread rather than being orphaned (reference §7.2).
    func testRebindMovesStateToTheNewRuntimeID() throws {
        let engine = TurnEngine()
        engine.appendUserEntry(sessionID: session, text: "hello")
        engine.rebind(from: session, to: "deadbeef")

        XCTAssertTrue(engine.state(for: session).entries.isEmpty)
        XCTAssertEqual(engine.state(for: "deadbeef").entries.first?.text, "hello")
        XCTAssertEqual(engine.pinnedSessionID, "deadbeef")
    }

    /// `notification.show` owns **one keyed slot** above the composer, not a
    /// stack in the transcript: the same key swaps in place, a different key
    /// replaces the slot, and `clear` only clears the key that is showing.
    func testNotificationOccupiesOneKeyedSlot() throws {
        let engine = TurnEngine()
        let events = try Fixtures.events("notice-slot")

        engine.apply(events[0])
        var notice = try XCTUnwrap(engine.state(for: session).notice)
        XCTAssertEqual(notice.key, "rate_limit")
        XCTAssertEqual(notice.level, "warn")

        // Same key: content swaps, no second notice appears.
        engine.apply(events[1])
        notice = try XCTUnwrap(engine.state(for: session).notice)
        XCTAssertEqual(notice.text, "Rate limited; retrying in 5s")

        // Different key: replaces the slot outright.
        engine.apply(events[2])
        notice = try XCTUnwrap(engine.state(for: session).notice)
        XCTAssertEqual(notice.key, "mcp")
        XCTAssertEqual(notice.level, "info")

        // A clear for a key that is no longer showing must be ignored —
        // otherwise a stale frame wipes a live warning.
        engine.apply(events[3])
        XCTAssertEqual(engine.state(for: session).notice?.key, "mcp")

        engine.apply(events[4])
        XCTAssertNil(engine.state(for: session).notice)

        // Notices live in the slot, never as transcript rows.
        XCTAssertTrue(
            engine.state(for: session).entries.isEmpty,
            "a keyed notice must not also append a row, or it would stack in the transcript"
        )
    }

    /// The slot's remaining edges: an empty text clears it, a keyless `show`
    /// still gets a slot, and a keyless `clear` clears whatever is there.
    func testNotificationEdgeCases() throws {
        let engine = TurnEngine()
        func show(_ key: String, _ text: String) {
            engine.apply(GatewayEvent(
                type: "notification.show",
                sessionID: session,
                payload: .object(["key": .string(key), "text": .string(text), "level": .string("info")]),
                params: .null
            ))
        }

        show("", "keyless warning")
        XCTAssertEqual(
            engine.state(for: session).notice?.key, "notification",
            "a keyless notice still needs a slot identity to be replaceable"
        )

        show("build", "")
        XCTAssertNil(engine.state(for: session).notice, "an empty text is a clear")

        show("build", "build finished")
        engine.apply(GatewayEvent(
            type: "notification.clear",
            sessionID: session,
            payload: .object(["key": .string("")]),
            params: .null
        ))
        XCTAssertNil(engine.state(for: session).notice, "a keyless clear clears whatever is showing")
    }

    /// `skin.changed` is a global broadcast and a presentation concern owned by
    /// AppModel, so the turn engine must route it nowhere and leave state alone
    /// — while the projection still hands the whole `resolve_skin()` dict up.
    func testSkinChangedIsProjectedWholeAndTouchesNoTurnState() throws {
        let event = try XCTUnwrap(try Fixtures.events("event-skin-changed").first)

        guard case .skinChanged(let name, let skin) = HermesEvent.project(event) else {
            return XCTFail("expected .skinChanged")
        }
        XCTAssertEqual(name, "moss", "skin.changed carries its name at the TOP level, not under `skin`")
        XCTAssertEqual(skin["colors"]?["accent"]?.stringValue, "#6f8f5a")
        XCTAssertEqual(
            skin["light_colors"]?["accent"]?.stringValue, "#3f5a30",
            "both polarities survive: the client picks per appearance, so neither may be dropped"
        )
        XCTAssertEqual(skin["dark_colors"]?["bg"]?.stringValue, "#0b0e09")

        let engine = TurnEngine()
        engine.appendUserEntry(sessionID: session, text: "hello")
        let before = engine.state(for: session)
        XCTAssertNil(engine.apply(event), "a global broadcast routes to no session")
        XCTAssertEqual(engine.state(for: session), before)
    }

    /// A `tool.complete` whose `tool_id` is missing still has to land on the
    /// right card — the three-tier correlation falls back to the newest
    /// running row with the same name (reference §3.4).
    func testToolCompletionCorrelatesByNameWhenIDIsMissing() {
        let engine = TurnEngine()
        engine.apply(GatewayEvent(
            type: "tool.start",
            sessionID: session,
            payload: .object(["name": .string("read_file"), "context": .string("main.swift")]),
            params: .null
        ))
        engine.apply(GatewayEvent(
            type: "tool.complete",
            sessionID: session,
            payload: .object(["name": .string("read_file"), "result": .string("ok")]),
            params: .null
        ))
        let tools = engine.state(for: session).entries.compactMap(\.tool)
        XCTAssertEqual(tools.count, 1, "the completion updated the existing card instead of adding one")
        XCTAssertFalse(tools[0].isRunning)
        XCTAssertEqual(tools[0].resultText, "ok")
    }

    /// The optimistic-handoff rollback: a hard submit failure takes the
    /// engine's user entry back so the outbound bubble can return, failed —
    /// the text must never just vanish (seen live against a dead agent).
    func testRemoveEntryRollsBackTheHandoff() {
        let engine = TurnEngine()
        let entryID = engine.appendUserEntry(sessionID: session, text: "hello?")
        XCTAssertTrue(engine.state(for: session).isBusy, "appendUserEntry claims the turn")

        engine.removeEntry(sessionID: session, entryID: entryID)
        let state = engine.state(for: session)
        XCTAssertTrue(state.entries.isEmpty, "the phantom user entry is gone")
        XCTAssertFalse(state.isBusy, "the rollback releases the busy claim")
        XCTAssertNil(engine.pinnedSessionID)

        // Unknown ids are a no-op — a settled turn owns its entries.
        engine.appendUserEntry(sessionID: session, text: "second")
        engine.removeEntry(sessionID: session, entryID: "not-a-real-id")
        XCTAssertEqual(engine.state(for: session).entries.count, 1)
    }

    // MARK: - The interrupt latch expires (multi-client remote control)

    /// The time backstop. A Stop pressed a minute ago cannot still be
    /// swallowing events: by then anything in flight from the cancelled turn
    /// has long landed, and what arrives now is a NEW turn — here, one another
    /// client started, which on a mirroring gateway reaches this device
    /// without any local send to clear the latch first.
    ///
    /// This is the frozen-transcript failure the latch used to cause: no
    /// error, no spinner, nothing — the reply simply never appeared.
    func testLatchExpiresAndRendersAForeignTurn() throws {
        let engine = TurnEngine()
        engine.appendUserEntry(sessionID: session, text: "go")
        engine.apply(GatewayEvent(type: "message.start", sessionID: session, payload: .null, params: .null))
        engine.flush()

        // Stop, a minute ago. `interruptGrace` is 5 s.
        engine.markInterrupted(sessionID: session, at: Date().addingTimeInterval(-60))
        XCTAssertTrue(engine.state(for: session).interrupted, "the flag itself stays set")

        // A turn nobody on this device started, arriving in full.
        engine.apply(GatewayEvent(type: "message.start", sessionID: session, payload: .null, params: .null))
        XCTAssertTrue(engine.state(for: session).isBusy, "the expired latch must not swallow message.start")
        engine.apply(GatewayEvent(
            type: "message.delta",
            sessionID: session,
            payload: .object(["text": .string("the desktop's reply")]),
            params: .null
        ))
        engine.flush()
        engine.apply(GatewayEvent(
            type: "message.complete",
            sessionID: session,
            payload: .object([
                "text": .string("the desktop's reply"),
                "status": .string("complete"),
            ]),
            params: .null
        ))

        let state = engine.state(for: session)
        XCTAssertFalse(state.isBusy, "the foreign turn settles like any other")
        let assistants = state.entries.filter { $0.kind == .assistant }
        XCTAssertEqual(assistants.last?.text, "the desktop's reply", "the foreign turn must render")
        XCTAssertEqual(assistants.last?.status, "complete")
    }

    /// The terminal-frame release. The gateway sends exactly one terminal
    /// frame per turn, so the cancelled turn's own `message.complete` is the
    /// last event that can possibly belong to it — everything after it belongs
    /// to a different turn and must render, with NO intervening
    /// `appendUserEntry` to clear the latch.
    func testTerminalFrameReleasesTheLatch() throws {
        let engine = TurnEngine()
        engine.appendUserEntry(sessionID: session, text: "go")
        engine.apply(GatewayEvent(type: "message.start", sessionID: session, payload: .null, params: .null))
        engine.apply(GatewayEvent(
            type: "message.delta",
            sessionID: session,
            payload: .object(["text": .string("partial")]),
            params: .null
        ))
        engine.flush()
        engine.markInterrupted(sessionID: session)
        XCTAssertTrue(engine.state(for: session).interrupted)

        // The cancelled turn's own terminal frame, still inside the grace
        // window. Its text is still dropped — that part is unchanged (A3).
        engine.apply(GatewayEvent(
            type: "message.complete",
            sessionID: session,
            payload: .object([
                "text": .string("partial stale full completion"),
                "status": .string("interrupted"),
            ]),
            params: .null
        ))
        XCTAssertFalse(
            engine.state(for: session).interrupted,
            "the cancelled turn's terminal frame releases the latch"
        )
        XCTAssertFalse(
            engine.state(for: session).entries.contains { $0.text == "partial stale full completion" },
            "the cancelled turn's text is still not applied"
        )

        // A different turn, with no local send in between.
        engine.apply(GatewayEvent(type: "message.start", sessionID: session, payload: .null, params: .null))
        engine.apply(GatewayEvent(
            type: "message.delta",
            sessionID: session,
            payload: .object(["text": .string("a later turn")]),
            params: .null
        ))
        engine.flush()

        let state = engine.state(for: session)
        XCTAssertTrue(state.isBusy)
        XCTAssertEqual(
            state.entries.last { $0.kind == .assistant }?.text, "a later turn",
            "a turn after the released latch must render"
        )
    }

    /// `turnStartedLocally` over one turn's life: a local send claims it, a
    /// bare `message.start` (no local send — a mirrored turn) does not, and
    /// settling clears it either way.
    func testTurnStartedLocallyLifecycle() throws {
        let engine = TurnEngine()
        XCTAssertFalse(engine.state(for: session).turnStartedLocally, "an untouched session owns no turn")

        engine.appendUserEntry(sessionID: session, text: "go")
        XCTAssertTrue(engine.state(for: session).turnStartedLocally, "a local send claims the turn")

        engine.apply(GatewayEvent(
            type: "message.complete",
            sessionID: session,
            payload: .object(["text": .string("done"), "status": .string("complete")]),
            params: .null
        ))
        XCTAssertFalse(engine.state(for: session).turnStartedLocally, "settling releases the claim")

        // A turn that began with no local send at all: on a mirroring gateway
        // this is another client's, and the flag is how Change 7 knows.
        let foreign = "ff001122"
        engine.apply(GatewayEvent(type: "message.start", sessionID: foreign, payload: .null, params: .null))
        let state = engine.state(for: foreign)
        XCTAssertTrue(state.isBusy, "the turn is running")
        XCTAssertFalse(state.turnStartedLocally, "but it is not this client's")
    }


    // MARK: BUG-017 (D) — the reasoning duration

    private func reasoning(_ text: String, type: String = "reasoning.delta") -> GatewayEvent {
        GatewayEvent(
            type: type,
            sessionID: session,
            payload: .object(["text": .string(text)]),
            params: .null
        )
    }

    /// The header rendered `"Thought for \(RelativeTime.duration(elapsed))"`
    /// against a hardcoded `private var elapsed: Double { 0 }`, so after a
    /// ninety-second think it read **"Thought for 0 ms"**.
    ///
    /// The wire carries no reasoning duration on any of the three frames that
    /// deliver a trace, so the measurement is this client's own: first
    /// reasoning delta to last. `apply(at:)` places them at known instants, so
    /// this asserts an exact number rather than racing a clock.
    func testReasoningDurationSpansTheFirstDeltaToTheLast() throws {
        let engine = TurnEngine()
        let start = Date(timeIntervalSince1970: 1_700_000_000)

        engine.apply(reasoning("Let me think. "), at: start)
        engine.apply(reasoning("Still thinking. "), at: start.addingTimeInterval(42))
        engine.apply(reasoning("Done thinking."), at: start.addingTimeInterval(90))
        engine.flush()

        let entries = engine.state(for: session).entries
        let assistant = try XCTUnwrap(entries.first { $0.kind == .assistant })
        XCTAssertEqual(assistant.reasoning, "Let me think. Still thinking. Done thinking.")
        XCTAssertEqual(assistant.reasoningStartedAt, start)
        XCTAssertEqual(assistant.reasoningEndedAt, start.addingTimeInterval(90))
        XCTAssertEqual(
            try XCTUnwrap(assistant.reasoningDuration), 90, accuracy: 0.001,
            "a ninety-second think reports ninety seconds, not 0 ms"
        )
    }

    /// The stamps survive the flush boundary. A real think spans hundreds of
    /// 33 ms flushes, and the phase started at the first delta of the FIRST of
    /// them — not at the first delta of the last one.
    func testTheDurationSurvivesFlushingPartWayThroughAThink() throws {
        let engine = TurnEngine()
        let start = Date(timeIntervalSince1970: 1_700_000_000)

        for offset in [0.0, 10.0, 20.0, 30.0] {
            engine.apply(reasoning("tick "), at: start.addingTimeInterval(offset))
            engine.flush()
        }

        let entries = engine.state(for: session).entries
        let assistant = try XCTUnwrap(entries.first { $0.kind == .assistant })
        XCTAssertEqual(assistant.reasoning, "tick tick tick tick ")
        XCTAssertEqual(assistant.reasoningStartedAt, start, "the start is written once and never moves")
        XCTAssertEqual(try XCTUnwrap(assistant.reasoningDuration), 30, accuracy: 0.001)
    }

    /// **Nil is a real answer.** A trace that arrived whole has no interval to
    /// report, and a header that printed 0 for it would be exactly back where
    /// it started. Same for an entry projected from history, which never
    /// watched the think happen.
    func testAWholeTraceAndAHistoryEntryBothReportNoDuration() throws {
        let engine = TurnEngine()
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        engine.apply(reasoning("One blob, no interval.", type: "reasoning.available"), at: start)
        engine.flush()

        let entries = engine.state(for: session).entries
        let assistant = try XCTUnwrap(entries.first { $0.kind == .assistant })
        XCTAssertEqual(assistant.reasoning, "One blob, no interval.")
        XCTAssertNotNil(assistant.reasoningStartedAt, "the phase was still observed")
        XCTAssertNil(assistant.reasoningDuration, "no elapsed time is unknown, not zero")

        let history = ChatEntry(id: "rest-1", kind: .assistant, reasoning: "from REST", status: "complete")
        XCTAssertNil(history.reasoningDuration, "a transcript from REST never watched the think happen")
    }

    /// The arithmetic itself, pinned away from any clock.
    func testReasoningDurationArithmetic() throws {
        let start = Date(timeIntervalSince1970: 1_700_000_000)

        let measured = ChatEntry(
            id: "m", kind: .assistant, reasoning: "x",
            reasoningStartedAt: start,
            reasoningEndedAt: start.addingTimeInterval(1.5)
        )
        XCTAssertEqual(try XCTUnwrap(measured.reasoningDuration), 1.5, accuracy: 0.001)

        // A clock that went backwards is not a negative duration.
        let skewed = ChatEntry(
            id: "s", kind: .assistant, reasoning: "x",
            reasoningStartedAt: start,
            reasoningEndedAt: start.addingTimeInterval(-5)
        )
        XCTAssertNil(skewed.reasoningDuration)

        // Half a pair is no pair.
        let halfOpen = ChatEntry(id: "h", kind: .assistant, reasoning: "x", reasoningStartedAt: start)
        XCTAssertNil(halfOpen.reasoningDuration)
    }

    // MARK: BUG-017 (4.4) / BUG-018 (4.3) — the trace is bounded, and cannot shrink

    /// **`reasoning.available` may not shorten a trace this client accumulated.**
    ///
    /// The frame is documented as carrying the whole block, and the reducer
    /// treats it as a replacement. An emitter that sends a truncated summary
    /// instead — the 500-character variant seen on some backends — would replace
    /// a minute of streamed thinking with a paragraph, and the deltas that built
    /// it are gone: nothing re-sends them and nothing on the wire can put them
    /// back.
    func testAnAvailableFrameCannotShortenAnAccumulatedTrace() throws {
        let engine = TurnEngine()
        let long = String(repeating: "streamed thinking. ", count: 60)
        engine.apply(reasoning(long))
        engine.flush()

        engine.apply(reasoning("A short summary of the thinking.", type: "reasoning.available"))
        engine.flush()

        let assistant = try XCTUnwrap(engine.state(for: session).entries.first { $0.kind == .assistant })
        XCTAssertEqual(assistant.reasoning, long, """
            a 32-character "replacement" wiped a 1,140-character trace. A replacement that \
            loses text is not a replacement — the accumulated record is the better one
            """)
    }

    /// …and the legitimate case still works: a fuller block replaces a shorter
    /// one, which is what the frame is for.
    func testAnAvailableFrameStillReplacesWithSomethingFuller() throws {
        let engine = TurnEngine()
        engine.apply(reasoning("part"))
        engine.flush()

        let whole = "part, and the rest of it, and more besides."
        engine.apply(reasoning(whole, type: "reasoning.available"))
        engine.flush()

        let assistant = try XCTUnwrap(engine.state(for: session).entries.first { $0.kind == .assistant })
        XCTAssertEqual(assistant.reasoning, whole)
    }

    /// The bound, and the head-drop that enforces it.
    ///
    /// The newest thinking is what the preview shows and what a reader opening
    /// the disclosure mid-think is looking for, so the head goes and the tail
    /// stays. The elision marker is left behind because text that disappears
    /// with no trace is the same class of lie as a wrong duration.
    func testTheTraceIsBoundedAndDropsFromTheHead() throws {
        var entry = ChatEntry(id: "e", kind: .assistant)
        let chunk = String(repeating: "a", count: 8 * 1024)
        for _ in 0..<40 { entry.appendReasoning(chunk) }   // 320 KB offered

        XCTAssertLessThanOrEqual(entry.reasoning.utf8.count, ChatEntry.reasoningLimit,
                                 "an unbounded trace is an unbounded allocation on a phone")
        XCTAssertTrue(entry.reasoning.hasPrefix(ChatEntry.reasoningElision),
                      "text that vanished with no trace is its own kind of lie")

        // The tail is intact: the newest thing appended is still the last thing
        // there.
        entry.appendReasoning("THE NEWEST THOUGHT")
        XCTAssertTrue(entry.reasoning.hasSuffix("THE NEWEST THOUGHT"))

        // One-shot: dropping to exactly the limit would re-drop on every delta
        // from then on, which is the quadratic cost the limit exists to avoid.
        // After a drop there must be real headroom left.
        XCTAssertLessThan(entry.reasoning.utf8.count, ChatEntry.reasoningLimit - 16 * 1024,
                          "the drop must leave room to grow back into")
    }

    /// A trace that never reaches the ceiling is untouched — no marker, no loss.
    func testAnOrdinaryTraceIsNotTouched() {
        var entry = ChatEntry(id: "e", kind: .assistant)
        entry.appendReasoning("Let me think. ")
        entry.appendReasoning("Still thinking.")
        XCTAssertEqual(entry.reasoning, "Let me think. Still thinking.")
    }
}
