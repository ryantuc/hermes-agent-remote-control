import XCTest

@testable import HermesServeKit

/// Wire-level decoding. Every fixture cites the extract line that fixes the
/// shape it encodes; if the backend ever drifts, these are the tests that fail
/// first.
final class CodecTests: XCTestCase {

    /// One WS text message may carry several newline-delimited frames because
    /// the server coalesces streamed token frames on a ~33 ms timer
    /// (PROTOCOL.md "Transport"; jsonrpc-methods-and-events.md §0.7).
    func testDecodesMultipleFramesFromOneCoalescedMessage() throws {
        let text = try Fixtures.coalescedText("event-message-delta-coalesced")
        let results = JSONRPCCodec.decodeMessage(text)

        XCTAssertEqual(results.count, 3)
        var accumulated = ""
        for result in results {
            let frame = try result.get()
            guard case .event(let event) = frame else {
                return XCTFail("expected an event frame, got \(frame)")
            }
            XCTAssertEqual(event.type, "message.delta")
            XCTAssertEqual(event.sessionID, "a1b2c3d4")
            accumulated += event.payload["text"]?.text ?? ""
        }
        XCTAssertEqual(accumulated, "I fixed the test.")
    }

    /// Blank lines between frames must not produce phantom decode failures.
    func testIgnoresBlankLinesBetweenFrames() throws {
        let text = try Fixtures.coalescedText("event-message-delta-coalesced")
        let padded = "\n" + text.replacingOccurrences(of: "\n", with: "\n\n") + "\n"
        XCTAssertEqual(JSONRPCCodec.decodeMessage(padded).count, 3)
    }

    /// `payload` is omitted entirely when it would be null — `message.start` is
    /// emitted exactly this way (jsonrpc-methods-and-events.md §0.3 Gotcha 2).
    func testEventWithNoPayloadDecodesToNull() throws {
        let events = try Fixtures.events("event-no-payload")
        let event = try XCTUnwrap(events.first)

        XCTAssertEqual(event.type, "message.start")
        XCTAssertEqual(event.sessionID, "a1b2c3d4")
        XCTAssertTrue(event.payload.isNull, "a missing payload key must decode as .null, never crash")

        // …and the typed projection must survive it.
        guard case .messageStart(let sessionID) = HermesEvent.project(event) else {
            return XCTFail("expected .messageStart")
        }
        XCTAssertEqual(sessionID, "a1b2c3d4")
    }

    /// Session-less broadcasts carry `session_id: ""`, and `gateway.ready` has
    /// no `session_id` key at all (§0.3 Gotcha 3; ws.py:306-318).
    func testGlobalBroadcastsDecodeWithEmptySessionID() throws {
        let events = try Fixtures.events("event-global-broadcast")
        XCTAssertEqual(events.count, 2)

        XCTAssertEqual(events[0].type, "sessions.changed")
        XCTAssertEqual(events[0].sessionID, "")
        if case .sessionsChanged = HermesEvent.project(events[0]) {} else {
            XCTFail("expected .sessionsChanged")
        }

        XCTAssertEqual(events[1].type, "gateway.ready")
        XCTAssertEqual(events[1].sessionID, "", "a missing session_id key must normalize to empty, not crash")
        guard case .gatewayReady(let ready) = HermesEvent.project(events[1]) else {
            return XCTFail("expected .gatewayReady")
        }
        XCTAssertTrue(ready.changeEvents, "change_events gates the poll-demotion decision")
        XCTAssertEqual(ready.skinName, "nous")
        // The fan-out fields are absent from this (pre-D3) fixture, and their
        // absent-defaults are what keep every backend in the field working:
        // false means "do not send `watch`", empty means "cannot tell whose
        // turn this is, fall back to the time rule".
        XCTAssertFalse(ready.sessionMirroring, "an absent session_mirroring must read as false")
        XCTAssertEqual(ready.origin, "", "an absent origin must read as empty")
    }

    /// Error envelope: `{"id", "error": {"code", "message"}}` (§0.2).
    func testDecodesResponseErrorFrame() throws {
        let line = try JSONRPCCodec.encodeLine(try Fixtures.frames("response-error")[0])
        guard case .response(let response) = try JSONRPCCodec.decodeFrame(line) else {
            return XCTFail("expected a response frame")
        }
        XCTAssertEqual(response.id.coercedString, "i7")
        XCTAssertNil(response.result)
        let error = try XCTUnwrap(response.error)
        XCTAssertEqual(error.code, 4001)
        XCTAssertEqual(error.message, "session not found")

        // The classification the reconnect path depends on.
        let mapped = HermesError.rpc(code: error.code, message: error.message)
        XCTAssertTrue(mapped.isSessionNotFound)
        XCTAssertFalse(mapped.isAuthenticationFailure)
    }

    /// A frame with both an id and a non-"event" method is a server→client
    /// request, not a response. Misclassifying it would silently drop a frame.
    func testDecodesServerRequestFrame() throws {
        let line = try JSONRPCCodec.encodeLine(try Fixtures.frames("server-request")[0])
        guard case .serverRequest(let id, let method, let params) = try JSONRPCCodec.decodeFrame(line) else {
            return XCTFail("expected a server request frame")
        }
        XCTAssertEqual(id.coercedInt, 42)
        XCTAssertEqual(method, "client.ping")
        XCTAssertEqual(params?["nonce"]?.stringValue, "abc123")

        // The client answers it rather than leaving the peer hanging.
        let response = try JSONRPCCodec.encodeResponse(
            id: id,
            result: .object(["ok": .bool(false)])
        )
        XCTAssertTrue(response.contains("\"id\":42"))
    }

    /// Both id spaces come back from `session.create`, and `desktop_contract`
    /// is the only protocol version a client can check (§1.1, §6.1).
    func testDecodesSessionCreateResult() throws {
        let result = try Fixtures.result("response-session-create")
        XCTAssertEqual(result["session_id"]?.coercedString, "a1b2c3d4")
        XCTAssertEqual(result["stored_session_id"]?.coercedString, "20260731_170500_ab12ef")

        let info = SessionInfo(json: result["info"] ?? .null)
        XCTAssertEqual(info.desktopContract, 5)
        XCTAssertTrue(info.lazy, "session.create returns the lazy info variant before the deferred build")
        XCTAssertEqual(info.model, "hermes-4-405b")
    }

    /// Requests are single-line JSON with a string id and no trailing newline;
    /// the WebSocket frame is the delimiter.
    func testEncodesRequestFrame() throws {
        let line = try JSONRPCCodec.encodeRequest(
            id: "i1",
            method: "prompt.submit",
            params: .object(["session_id": .string("a1b2c3d4"), "text": .string("hello")])
        )
        XCTAssertFalse(line.contains("\n"))
        let decoded = try JSONDecoder().decode(JSONValue.self, from: Data(line.utf8))
        XCTAssertEqual(decoded["jsonrpc"]?.stringValue, "2.0")
        XCTAssertEqual(decoded["id"]?.stringValue, "i1")
        XCTAssertEqual(decoded["method"]?.stringValue, "prompt.submit")
        XCTAssertEqual(decoded["params"]?["text"]?.stringValue, "hello")
    }

    /// The bool-vs-int quirk: list rows coerce to real bools, the single-session
    /// route leaves SQLite 0/1 ints (rest-api-and-auth.md §6.1 / §6.3).
    func testSessionSummaryAcceptsBoolAndIntFlags() throws {
        let asBools = SessionSummary(json: .object([
            "id": .string("s1"), "archived": .bool(true), "pinned": .bool(false),
            "last_active": .number(1_753_900_000),
        ]))
        let asInts = SessionSummary(json: .object([
            "id": .string("s1"), "archived": .number(1), "pinned": .number(0),
            "last_active": .number(1_753_900_000),
        ]))
        XCTAssertEqual(asBools.archived, asInts.archived)
        XCTAssertEqual(asBools.pinned, asInts.pinned)
        XCTAssertTrue(asInts.archived)
        XCTAssertFalse(asInts.pinned)
    }

    /// `content` is `str | content-part list | null` (rest §6.2), and a `user`
    /// row with a non-empty `display_kind` is bookkeeping, not a user turn.
    func testTranscriptMessageHandlesPolymorphicContent() {
        let plain = TranscriptMessage(json: .object([
            "id": .number(1), "role": .string("user"), "content": .string("hi"),
        ]))
        XCTAssertEqual(plain.content.plainText, "hi")
        XCTAssertFalse(plain.isBookkeeping)

        let multimodal = TranscriptMessage(json: .object([
            "id": .number(2), "role": .string("user"),
            "content": .array([
                .object(["type": .string("text"), "text": .string("what is this?")]),
                .object([
                    "type": .string("image_url"),
                    "image_url": .object(["url": .string("data:image/png;base64,AAAA")]),
                ]),
            ]),
        ]))
        XCTAssertEqual(multimodal.content.plainText, "what is this?")
        XCTAssertEqual(multimodal.content.imageReferences.count, 1)

        let toolCallOnly = TranscriptMessage(json: .object([
            "id": .number(3), "role": .string("assistant"), "content": .null,
            "tool_calls": .array([
                .object([
                    "id": .string("call_1"), "type": .string("function"),
                    "function": .object([
                        "name": .string("terminal"),
                        "arguments": .string("{\"command\":\"ls\"}"),
                    ]),
                ])
            ]),
        ]))
        XCTAssertEqual(toolCallOnly.content, .empty)
        XCTAssertEqual(toolCallOnly.toolCalls.first?.name, "terminal")

        let bookkeeping = TranscriptMessage(json: .object([
            "id": .number(4), "role": .string("user"), "content": .string("[model switched]"),
            "display_kind": .string("model_switch"),
        ]))
        XCTAssertTrue(bookkeeping.isBookkeeping)
    }

    /// Nothing that reaches a log or an export may carry a credential.
    func testRedactionStripsCredentials() throws {
        let url = try XCTUnwrap(URL(string: "wss://box.example/api/ws?ticket=abcdef0123456789&cols=96"))
        let redacted = Redaction.url(url)
        XCTAssertFalse(redacted.contains("abcdef0123456789"))
        XCTAssertTrue(redacted.contains("cols=96"))

        let text = Redaction.text("Authorization: Bearer " + "sk-live-" + "0123456789abcdef")
        XCTAssertFalse(text.contains("sk-live-" + "0123456789abcdef"))

        let headers = Redaction.headers([
            "Authorization": "Bearer x", "X-Hermes-Session-Token": "t", "Accept": "application/json",
        ])
        XCTAssertEqual(headers["Accept"], "application/json")
        XCTAssertEqual(headers["Authorization"], Redaction.mask)
        XCTAssertEqual(headers["X-Hermes-Session-Token"], Redaction.mask)
    }

    /// Base-URL normalization mirrors `normalizeRemoteBaseUrl`
    /// (reference-clients.md §2.6) and drives every derived URL.
    func testBackendConfigurationBuildsURLs() throws {
        let base = try BackendConfiguration.normalizeBaseURL("https://hermes.example.com/gw/")
        let config = BackendConfiguration(baseURL: base, authMode: .bearer)
        XCTAssertEqual(config.basePath, "/gw")
        XCTAssertEqual(
            config.restURL("/api/sessions").absoluteString,
            "https://hermes.example.com/gw/api/sessions"
        )
        let ws = try config.webSocketURL(authParam: (name: "ticket", value: "abc"))
        XCTAssertEqual(ws.absoluteString, "wss://hermes.example.com/gw/api/ws?ticket=abc")

        // A bare loopback host:port defaults to http, not https.
        let local = try BackendConfiguration.normalizeBaseURL("127.0.0.1:9119")
        XCTAssertEqual(local.scheme, "http")
        let localWS = try BackendConfiguration(baseURL: local)
            .webSocketURL(authParam: (name: "token", value: "t"))
        XCTAssertEqual(localWS.absoluteString, "ws://127.0.0.1:9119/api/ws?token=t")

        XCTAssertThrowsError(try BackendConfiguration.normalizeBaseURL("ftp://box"))
    }
}
