import XCTest

@testable import HermesServeKit

/// FEAT-016 — `error_surface`, the `{layer, code, retryable}` descriptor the
/// backend attaches to a failed turn.
///
/// The point of these is not that a field decodes. It is that **absence is a
/// first-class state on every one of them**: the backend's two builders are
/// wrapped in a bare `try/except` that yields `None`, so a failure with no
/// descriptor is not an edge case, it is the normal case on any error the
/// classifier does not recognise. Every assertion below that checks for nil is
/// checking that nothing in the client came to depend on the thing being there.
final class ErrorSurfaceTests: XCTestCase {
    private let session = "a1b2c3d4"

    private func complete(_ payload: [String: JSONValue]) -> MessageCompleteEvent {
        let event = GatewayEvent(
            type: "message.complete",
            sessionID: session,
            payload: .object(payload),
            params: .null
        )
        guard case .messageComplete(let completion) = HermesEvent.project(event) else {
            return MessageCompleteEvent(
                sessionID: "", text: "", rendered: "", status: "", error: "",
                partial: false, recoverable: false, warning: "", usage: .null,
                errorSurface: nil
            )
        }
        return completion
    }

    // MARK: - Decode

    func testMessageCompleteCarriesTheDescriptor() {
        let event = complete([
            "status": .string("error"),
            "error": .string("upstream returned 429"),
            "error_surface": .object([
                "layer": .string("provider"),
                "code": .string("rate_limited"),
                "retryable": .bool(true),
            ]),
        ])

        let surface = event.errorSurface
        XCTAssertEqual(surface?.layer, "provider")
        XCTAssertEqual(surface?.code, "rate_limited")
        XCTAssertEqual(surface?.retryable, true)
        XCTAssertEqual(surface?.isRetryable, true)
        XCTAssertEqual(surface?.isNotRetryable, false)
        XCTAssertNotNil(surface?.layerNote, "a known layer has wording")
    }

    /// The common case. A failed turn with no descriptor still decodes, still
    /// reports its error, and hands the render layer nil rather than a
    /// zero-valued struct that would read as "layer: '', not retryable".
    func testAFailedTurnWithoutADescriptorIsNil() {
        let event = complete([
            "status": .string("error"),
            "error": .string("something went wrong"),
        ])

        XCTAssertTrue(event.isError)
        XCTAssertEqual(event.error, "something went wrong")
        XCTAssertNil(event.errorSurface)
    }

    /// Every shape the wire can put there that is not a descriptor.
    func testNonDescriptorPayloadsDecodeToNil() {
        XCTAssertNil(complete(["error_surface": .null]).errorSurface)
        XCTAssertNil(complete(["error_surface": .object([:])]).errorSurface)
        XCTAssertNil(complete(["error_surface": .string("provider")]).errorSurface)
        XCTAssertNil(complete(["error_surface": .array([])]).errorSurface)
        XCTAssertNil(
            complete(["error_surface": .object(["layer": .string("   ")])]).errorSurface,
            "a descriptor whose only field is whitespace says nothing"
        )
    }

    /// `retryable` is tri-state and the middle state is the default. Silence is
    /// not a no — the client's existing retry affordance has to survive it.
    func testRetryableIsTriState() {
        let said = complete(["error_surface": .object(["retryable": .bool(false)])]).errorSurface
        XCTAssertEqual(said?.retryable, false)
        XCTAssertTrue(said?.isNotRetryable == true)
        XCTAssertFalse(said?.isRetryable == true)

        let silent = complete(["error_surface": .object(["code": .string("boom")])]).errorSurface
        XCTAssertNil(silent?.retryable)
        XCTAssertFalse(silent?.isRetryable == true)
        XCTAssertFalse(silent?.isNotRetryable == true)
    }

    /// The `layer` vocabulary is open-ended — the backend's own comment ends
    /// the list with an ellipsis. An unknown layer keeps the descriptor and
    /// simply has no wording; it must never be a reason to drop the card.
    func testAnUnknownLayerSurvivesWithoutWording() {
        let surface = complete([
            "error_surface": .object([
                "layer": .string("quantum_flux"),
                "code": .string("unheard_of"),
                "retryable": .bool(true),
            ]),
        ]).errorSurface

        XCTAssertEqual(surface?.layer, "quantum_flux")
        XCTAssertNil(surface?.layerNote)
        XCTAssertEqual(surface?.isRetryable, true)
    }

    /// The hand-written descriptor at the agent-init call site.
    func testTheRuntimeDescriptorFromAgentInit() {
        let surface = complete([
            "error_surface": .object([
                "layer": .string("runtime"),
                "code": .string("agent_init_failed"),
                "retryable": .bool(true),
            ]),
        ]).errorSurface

        XCTAssertEqual(surface?.layer, "runtime")
        XCTAssertNotNil(surface?.layerNote)
    }

    // MARK: - The resume snapshot

    /// The third carrier: a reconnect whose `message.complete` was lost to the
    /// disconnect recovers the same descriptor from `session.resume`.
    func testTheInflightSnapshotCarriesTheDescriptor() throws {
        let snapshot = try XCTUnwrap(InflightSnapshot(json: .object([
            "user": .string("do the thing"),
            "assistant": .string(""),
            "status": .string("error"),
            "error": .string("the provider hung up"),
            "error_surface": .object([
                "layer": .string("streaming"),
                "code": .string("stream_truncated"),
                "retryable": .bool(true),
            ]),
        ])))

        XCTAssertTrue(snapshot.isFailure)
        XCTAssertEqual(snapshot.errorSurface?.layer, "streaming")
        XCTAssertEqual(snapshot.errorSurface?.isRetryable, true)
    }

    func testTheInflightSnapshotWithoutADescriptorIsNil() throws {
        let snapshot = try XCTUnwrap(InflightSnapshot(json: .object([
            "user": .string("do the thing"),
            "status": .string("error"),
            "error": .string("the provider hung up"),
        ])))

        XCTAssertTrue(snapshot.isFailure)
        XCTAssertNil(snapshot.errorSurface)
    }

    // MARK: - Reaching the transcript

    /// The descriptor has to survive the turn engine, because the render layer
    /// only ever sees a `ChatEntry`.
    func testTheSettledEntryCarriesTheDescriptor() throws {
        let engine = TurnEngine()
        engine.appendUserEntry(sessionID: session, text: "fix the failing test")
        engine.apply(GatewayEvent(
            type: "message.complete",
            sessionID: session,
            payload: .object([
                "status": .string("error"),
                "error": .string("upstream returned 401"),
                "error_surface": .object([
                    "layer": .string("auth"),
                    "code": .string("provider_unauthorized"),
                    "retryable": .bool(false),
                ]),
            ]),
            params: .null
        ))
        engine.flush()

        let entry = try XCTUnwrap(
            engine.state(for: session).entries.last { $0.kind == .assistant }
        )
        XCTAssertTrue(entry.isError)
        XCTAssertEqual(entry.errorSurface?.layer, "auth")
        XCTAssertEqual(entry.errorSurface?.isNotRetryable, true)
    }

    /// A turn that ended well carries no descriptor, even if the backend sent
    /// one: a leftover surface on a successful bubble would name a layer that
    /// did not fail.
    func testASuccessfulTurnCarriesNoDescriptor() throws {
        let engine = TurnEngine()
        engine.appendUserEntry(sessionID: session, text: "fix the failing test")
        engine.apply(GatewayEvent(
            type: "message.complete",
            sessionID: session,
            payload: .object([
                "status": .string("complete"),
                "text": .string("done"),
                "error_surface": .object(["layer": .string("provider")]),
            ]),
            params: .null
        ))
        engine.flush()

        let entry = try XCTUnwrap(
            engine.state(for: session).entries.last { $0.kind == .assistant }
        )
        XCTAssertFalse(entry.isError)
        XCTAssertNil(entry.errorSurface)
    }

    // MARK: - 4009 has two meanings (BUG-114)

    /// `session.resume` can now be refused with 4009 while a disconnect
    /// interrupt settles. The session is ALIVE — an earlier backend simply
    /// succeeded on the same call — so the client has to retry rather than
    /// surface a failed reconnect.
    func testResumeSettlingIsRecognisedAsTransient() {
        let settling = HermesError.rpc(code: 4009, message: "session disconnect interrupt settling")
        XCTAssertTrue(settling.isResumeSettling)
        XCTAssertFalse(settling.isMissingPendingPrompt, "not the expired-prompt 4009")
        XCTAssertFalse(
            settling.isSessionNotFound,
            "must NOT read as session-gone: that drives start-over, and this session is live"
        )
    }

    /// The other 4009. Swallowed as benign, and it must not be dragged into the
    /// resume retry ladder.
    func testMissingPendingPromptStaysDistinctFromResumeSettling() {
        let expired = HermesError.rpc(code: 4009, message: "no pending clarify request")
        XCTAssertTrue(expired.isMissingPendingPrompt)
        XCTAssertFalse(expired.isResumeSettling)
    }

    /// Keyed on "not the no-pending shape" rather than on the exact wording, so
    /// an upstream reword of the settling message cannot silently turn a
    /// transient refusal back into a hard failure.
    func testAnyOther4009CountsAsSettlingRatherThanFailing() {
        let reworded = HermesError.rpc(code: 4009, message: "resume refused: interrupt in flight")
        XCTAssertTrue(reworded.isResumeSettling)

        // And the predicate stays pinned to 4009 — neighbouring codes are not it.
        XCTAssertFalse(HermesError.rpc(code: 4007, message: "session no longer live; retry resume").isResumeSettling)
        XCTAssertFalse(HermesError.rpc(code: 4001, message: "session not found").isResumeSettling)
        XCTAssertFalse(HermesError.notConnected.isResumeSettling)
    }

    // MARK: - 4090 carries a label, and absence is a real answer (BUG-141)

    /// Decode a real error frame the way the socket does, so the assertion
    /// covers the whole path the label travels: codec → `JSONRPCError.data` →
    /// `HermesError.from` → the accessor. Every earlier attempt at this bug
    /// died at the third arrow, where `data` used to be dropped on the floor.
    private func refusal(code: Int, reason: JSONValue?) throws -> HermesError {
        var errorObject: [String: JSONValue] = [
            "code": .number(Double(code)),
            "message": .string("Session 9f2c already has a live owner (desktop, pid 41288)."),
        ]
        if let reason { errorObject["data"] = .object(["reason": reason]) }
        let line = try JSONRPCCodec.encodeLine(.object([
            "jsonrpc": .string("2.0"),
            "id": .string("w1"),
            "error": .object(errorObject),
        ]))
        guard case .response(let response) = try JSONRPCCodec.decodeFrame(line),
              let rpc = response.error
        else {
            throw XCTSkip("the codec stopped producing an error frame")
        }
        return HermesError.from(rpc)
    }

    /// The measured case. A probe drove two real gateway
    /// processes against one stored conversation and the second one's
    /// `prompt.submit` came back with exactly this reason.
    func testSessionNotOwnedIsRecognised() throws {
        XCTAssertEqual(
            try refusal(code: 4090, reason: .string("SESSION_NOT_OWNED")).activeSessionRefusal,
            .sessionNotOwned
        )
    }

    func testTheOtherTwoLabelsAreRecognised() throws {
        XCTAssertEqual(
            try refusal(code: 4090, reason: .string("MAX_CONCURRENT_SESSIONS")).activeSessionRefusal,
            .maxConcurrentSessions
        )
        XCTAssertEqual(
            try refusal(code: 4090, reason: .string("SESSION_COORDINATION_UNAVAILABLE")).activeSessionRefusal,
            .coordinationUnavailable
        )
    }

    /// **The version-tolerance pin.** Every backend before 0.21.0 refuses with
    /// a bare 4090 and no `data` at all, and so does 0.21.0's own fourth,
    /// unlabelled refusal (`server.py:634-636`). Both must read as nil, which
    /// is what routes them to today's untouched behaviour.
    func testAReasonlessRefusalHasNoLabelAndStaysAnActiveSessionLimit() throws {
        let bare = try refusal(code: 4090, reason: nil)
        XCTAssertNil(bare.activeSessionRefusal, "no data means the old backend, not a guess")
        XCTAssertTrue(bare.isActiveSessionLimit, "the pre-existing 4090 predicate is unchanged")
    }

    /// An unknown future label maps to nil — today's behaviour — rather than to
    /// whichever of the three it looks most like.
    func testAnUnknownReasonDoesNotGuess() throws {
        XCTAssertNil(try refusal(code: 4090, reason: .string("SOMETHING_NEW")).activeSessionRefusal)
    }

    /// Keyed on the reason **and** the code together. 4090 is not a dedicated
    /// fence code upstream (`methods_bot_relay.py:94`, `methods_tools.py:2092`
    /// return it for unrelated refusals), and neither is a valid-looking reason
    /// on some other code the fence.
    func testTheLabelIsOnlyReadOn4090() throws {
        XCTAssertNil(try refusal(code: 4009, reason: .string("SESSION_NOT_OWNED")).activeSessionRefusal)
    }

    /// A `data` that is not an object, or an object whose `reason` is not a
    /// string, is not a refusal either — the accessor never crashes its way
    /// into a guess.
    func testAMalformedDataPayloadReadsAsNoLabel() throws {
        XCTAssertNil(try refusal(code: 4090, reason: .number(7)).activeSessionRefusal)
        XCTAssertNil(
            HermesError.rpc(code: 4090, message: "refused", data: .string("SESSION_NOT_OWNED"))
                .activeSessionRefusal
        )
        XCTAssertNil(HermesError.notConnected.activeSessionRefusal)
    }
}
