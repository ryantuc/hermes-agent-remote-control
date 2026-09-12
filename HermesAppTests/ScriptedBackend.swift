import Foundation
import HermesServeKit

@testable import HermesMobile

/// A scripted gateway for app-layer tests.
///
/// This is the same seam the kit's own `HermesClientConnectTests` uses — a
/// `ScriptedTransport` handed to `HermesClient` through its `transportFactory`,
/// dialed through a scripted `GatewayDialer` — extended one level up: where the
/// kit's version only needed to open, close and count frames, this one decodes
/// the JSON-RPC the app actually sends, answers it, and can push events back.
///
/// Everything here is deterministic. There are no sleeps: a test either drives
/// the backend directly (`emit`, `dropConnection`, `releaseParked`) or polls
/// with `waitUntil`. Nothing depends on how fast the machine is.
///
/// See README.md in this directory for how to write a test against it.
actor ScriptedBackend {

    // MARK: What the backend did and saw

    /// One decoded client→server request, in arrival order.
    struct Call: Sendable, Equatable {
        let id: String
        let method: String
        let params: JSONValue

        /// `params.session_id`, the field almost every method carries.
        var sessionID: String { params["session_id"]?.coercedString ?? "" }
        var text: String { params["text"]?.coercedString ?? "" }
    }

    private(set) var receivedCalls: [Call] = []
    /// Runtime session ids this backend has handed out, oldest first. One
    /// `session.create` or `session.resume` mints exactly one.
    private(set) var issuedRuntimeIDs: [String] = []
    /// Methods answered from the fallback (`{}`) rather than a real stub —
    /// a test may assert this is empty to prove it stubbed everything it used.
    private(set) var unhandledMethods: [String] = []

    func calls(to method: String) -> [Call] { receivedCalls.filter { $0.method == method } }
    func callCount(_ method: String) -> Int { calls(to: method).count }

    // MARK: Scripting knobs

    private var stubs: [String: @Sendable (Call) -> JSONValue] = [:]
    private var failures: [String: JSONRPCError] = [:]
    private var oneShotFailures: [String: JSONRPCError] = [:]
    private var gatedMethods: Set<String> = []
    private var writeFailureMethods: Set<String> = []
    private var parked: [(transport: ScriptedTransport, call: Call)] = []
    private var runtimeCounter = 0
    private var transports: [ScriptedTransport] = []
    /// Whether `gateway.ready` advertises the D3 fan-out contract
    /// (`session_mirroring` + this connection's `origin`). Off by default, so
    /// every existing test keeps handshaking against the backend the field
    /// actually runs.
    private(set) var advertisesSessionMirroring = false

    /// Hand out a patched `gateway.ready`. Set this **before** the socket
    /// opens — the handshake happens once.
    func setSessionMirroring(_ enabled: Bool) { advertisesSessionMirroring = enabled }

    /// The `skin` block `gateway.ready` carries, or nil for a handshake that
    /// names no skin at all.
    ///
    /// Until this existed the ready frame's skin was unreachable from a test:
    /// the payload was built inside `ScriptedTransport.connect` with one knob,
    /// so every scripted backend handshook as a backend with no skin opinion.
    /// That is the *one* shape BUG-046 cannot reproduce, which is why the bug
    /// survived a suite this large. Set it **before** the socket opens — the
    /// handshake happens once.
    private(set) var readySkin: JSONValue?
    func setReadySkin(_ skin: JSONValue?) { readySkin = skin }

    /// The payload shape the field actually sends: `colors` always present,
    /// and paired blocks that are **empty objects** rather than absent keys
    /// when the skin has no hand-tuned variant for that polarity. Eight of the
    /// backend's nine built-ins ship exactly this, and `default` ships it for
    /// `dark_colors`. An absent key and an empty object are not the same
    /// payload, and mobile only ever handled the absent one.
    static func skinPayload(
        name: String,
        colors: [String: String],
        lightColors: [String: String]? = nil,
        darkColors: [String: String]? = nil
    ) -> JSONValue {
        func block(_ values: [String: String]?) -> JSONValue {
            .object((values ?? [:]).mapValues { JSONValue.string($0) })
        }
        return .object([
            "name": .string(name),
            "colors": block(colors),
            "light_colors": block(lightColors),
            "dark_colors": block(darkColors),
        ])
    }

    /// The backend's real `default` skin, trimmed to the keys mobile reads.
    /// `light_colors` is the classic terminal goldenrod treatment and
    /// `dark_colors` is empty — verified against `hermes_cli/skin_engine.py`
    /// at `de25a6971d`, where `default` is the only built-in carrying any
    /// paired block at all.
    static func defaultSkinPayload() -> JSONValue {
        skinPayload(
            name: "default",
            colors: ["background": "#0B0B0F", "ui_text": "#E8E6E3", "ui_accent": "#D89B04"],
            lightColors: ["background": "#F5F5F5", "ui_text": "#5C4718", "ui_accent": "#D89B04"],
            darkColors: nil
        )
    }

    /// A backend built-in with **both** paired blocks empty — `mono`, `slate`,
    /// `ares`, and five others. This is the payload that makes the current
    /// decoder abandon the whole apply.
    static func monoSkinPayload() -> JSONValue {
        skinPayload(
            name: "mono",
            colors: ["background": "#0E0E0E", "ui_text": "#EAEAEA", "ui_accent": "#EAEAEA"]
        )
    }

    /// The transport id this backend claims for a client connection, echoed
    /// back on `gateway.ready` as `origin`.
    static let transportOrigin = "scripted-transport-1"

    /// Answer `method` with whatever the closure returns.
    func stub(_ method: String, _ handler: @escaping @Sendable (Call) -> JSONValue) {
        stubs[method] = handler
    }

    /// Answer every `method` with a JSON-RPC error (4001/4007 are "session not
    /// found"; see `HermesError.isSessionNotFound`).
    func failRPC(_ method: String, code: Int, message: String) {
        failures[method] = JSONRPCError(code: code, message: message)
    }

    /// Fail `method` exactly once, then answer normally — the shape of a stale
    /// runtime id that a resume repairs.
    /// `data` is the server's structured detail. It defaults to nil, which is
    /// what every backend predating 0.21.0 sends, so existing callers are
    /// unchanged; BUG-141's tests pass `{"reason": …}` through it.
    func failNextRPC(_ method: String, code: Int, message: String, data: JSONValue? = nil) {
        oneShotFailures[method] = JSONRPCError(code: code, message: message, data: data)
    }

    /// Accept `method`'s frame but withhold its **reply** until
    /// `releaseParked()`. The frame is still recorded on arrival and the socket
    /// stays writable, so a second caller's frame is not queued behind it —
    /// which is what makes a two-callers-at-once race stageable.
    func gate(_ method: String) { gatedMethods.insert(method) }

    func ungate(_ method: String) { gatedMethods.remove(method) }

    var parkedCount: Int { parked.count }

    func releaseParked() async {
        let pending = parked
        parked.removeAll()
        for item in pending {
            await answer(item.call, on: item.transport)
        }
    }

    /// Deliver the next frame for `method` to the server and *then* report the
    /// write as failed — the ambiguous write. `URLSessionWebSocketTask.send`
    /// reports failure for a frame that may already have crossed the wire, and
    /// a socket dying between the write and the ack is exactly this shape: the
    /// server has the request, the client has an error, and no one can tell
    /// which side of the wire the frame got to.
    func deliverThenFailWrite(_ method: String) { writeFailureMethods.insert(method) }

    // MARK: Dial

    func status() -> ServerStatus {
        ServerStatus(json: .object([
            "version": .string("0.20.0"),
            "auth_required": .bool(false),
            "gateway_running": .bool(true),
            "gateway_state": .string("running"),
        ]))
    }

    nonisolated func webSocketURL() -> URL { URL(string: "ws://scripted.test/api/ws?token=t")! }

    /// The dialer to hand `HermesClient`. Never touches the real
    /// `AuthenticationClient` or `RestAPI`.
    nonisolated func dialer() -> GatewayDialer {
        GatewayDialer(
            getStatus: { await self.status() },
            webSocketURL: { _ in self.webSocketURL() }
        )
    }

    // MARK: Transport wiring

    func attach(_ transport: ScriptedTransport) {
        transports.append(transport)
    }

    /// The socket the client is using now, or nil if it has none.
    private var activeTransport: ScriptedTransport? { transports.last }

    var socketCount: Int { transports.count }

    // MARK: Inbound frames

    /// What the transport should do with a line it was asked to send.
    enum WriteVerdict: Sendable {
        case accepted
        /// The server got it; tell the client the write failed anyway.
        case failWrite
    }

    func receive(line: String, from transport: ScriptedTransport) async -> WriteVerdict {
        guard let frame = try? JSONRPCCodec.decodeFrame(line) else { return .accepted }
        switch frame {
        case .serverRequest(let id, let method, let params):
            let call = Call(
                id: id.coercedString ?? "",
                method: method,
                params: params ?? .null
            )
            receivedCalls.append(call)
            if writeFailureMethods.contains(method) {
                writeFailureMethods.remove(method)
                return .failWrite
            }
            if gatedMethods.contains(method) {
                parked.append((transport, call))
                return .accepted
            }
            await answer(call, on: transport)
            return .accepted
        case .response, .event, .unknown:
            // The client answering a server→client request. Nothing here
            // issues one; record nothing.
            return .accepted
        }
    }

    private func answer(_ call: Call, on transport: ScriptedTransport) async {
        if let error = oneShotFailures.removeValue(forKey: call.method) ?? failures[call.method] {
            // The `data` member is emitted only when the script set one, so a
            // scripted failure without it is byte-identical to the frame this
            // helper has always written (BUG-141: absence is the old backend).
            var errorObject: [String: JSONValue] = [
                "code": .number(Double(error.code)),
                "message": .string(error.message),
            ]
            if let data = error.data { errorObject["data"] = data }
            let line = try? JSONRPCCodec.encodeLine(.object([
                "jsonrpc": .string("2.0"),
                "id": .string(call.id),
                "error": .object(errorObject),
            ]))
            if let line { await transport.deliver(line: line) }
            return
        }
        let result = stubs[call.method].map { $0(call) } ?? defaultResult(for: call)
        guard let line = try? JSONRPCCodec.encodeResponse(id: .string(call.id), result: result) else { return }
        await transport.deliver(line: line)
    }

    private func defaultResult(for call: Call) -> JSONValue {
        switch call.method {
        case "session.resume":
            let requested = call.sessionID
            return .object([
                "session_id": .string(mintRuntimeID()),
                "resumed": .string(requested),
                "session_key": .string(requested),
                "messages": .array([]),
                "info": Self.info(),
                "running": .bool(false),
                "status": .string("idle"),
                // Per-resume confirmation of the watcher attach. False here
                // because the default backend does not mirror sessions.
                "watching": .bool(false),
            ])
        case "session.create":
            return .object([
                "session_id": .string(mintRuntimeID()),
                "stored_session_id": .string("stored-\(runtimeCounter)"),
                "messages": .array([]),
                "info": Self.info(),
            ])
        case "session.activate":
            return .object([
                "session_id": .string(mintRuntimeID()),
                "messages": .array([]),
                "info": Self.info(),
            ])
        case "prompt.submit":
            return .object(["status": .string("streaming")])
        case "session.interrupt", "session.close":
            return .object(["ok": .bool(true)])
        case "approval.respond":
            // The real gateway answers `{resolved: <int count>}` — 1 when the
            // head was resolved, 0 when nothing was pending. The old
            // `{ok: true}` default carried no count at all, and a default that
            // does not match the wire is a default every test silently inherits
            // the wrong behaviour from.
            return .object(["resolved": .number(1)])
        case "config.get":
            return .object(["cwd": .string("/scripted"), "model": .string("scripted-model")])
        // **`session.active_list` has no default here, deliberately.** A
        // scripted backend must not volunteer "nothing is running" for a
        // question the test never scripted — this one emits frames of running
        // sessions all day, and an affirmative empty roster contradicts them.
        // It falls through to the unknown-method `{}` below, which is a
        // NON-answer: `SessionAPI.activeListIfAnswered` returns nil for it and
        // the settle sweep stays inert. A test that wants the sweep to act
        // stubs `{"sessions": [...]}` — including the empty array, which is an
        // affirmative "nothing is running".
        default:
            unhandledMethods.append(call.method)
            return .object([:])
        }
    }

    private func mintRuntimeID() -> String {
        runtimeCounter += 1
        let id = "rt-\(runtimeCounter)"
        issuedRuntimeIDs.append(id)
        return id
    }

    /// `_session_info` as the app reads it. `desktop_contract` is at the
    /// current minimum so no contract warning fires.
    static func info(model: String = "scripted-model", title: String = "") -> JSONValue {
        .object([
            "model": .string(model),
            "provider": .string("scripted"),
            "cwd": .string("/scripted"),
            "title": .string(title),
            "desktop_contract": .number(5),
            "running": .bool(false),
        ])
    }

    // MARK: Outbound events

    /// Push one gateway event onto the live socket.
    func emit(_ type: String, sessionID: String, payload: JSONValue = .null) async {
        var params: [String: JSONValue] = [
            "type": .string(type),
            "session_id": .string(sessionID),
        ]
        if !payload.isNull { params["payload"] = payload }
        let line = try? JSONRPCCodec.encodeLine(.object([
            "jsonrpc": .string("2.0"),
            "method": .string("event"),
            "params": .object(params),
        ]))
        guard let line, let transport = activeTransport else { return }
        await transport.deliver(line: line)
    }

    /// Push one gateway event stamped with a fan-out `origin` — the D3 wire
    /// shape, where `origin` rides on the event's **params**, beside `type`
    /// and `session_id`, never inside the payload (D3-SPEC item 9). Callers
    /// pass the origin of whichever client's turn the frame belongs to; the
    /// un-stamped `emit` above stays the shape of every backend without the
    /// patch. `origin` is deliberately not defaulted: a default would make
    /// every existing `emit` call ambiguous.
    func emit(_ type: String, sessionID: String, payload: JSONValue = .null, origin: String) async {
        var params: [String: JSONValue] = [
            "type": .string(type),
            "session_id": .string(sessionID),
            "origin": .string(origin),
        ]
        if !payload.isNull { params["payload"] = payload }
        let line = try? JSONRPCCodec.encodeLine(.object([
            "jsonrpc": .string("2.0"),
            "method": .string("event"),
            "params": .object(params),
        ]))
        guard let line, let transport = activeTransport else { return }
        await transport.deliver(line: line)
    }

    /// `message.start` → one `message.delta`. **It does not emit
    /// `message.complete`**, so the turn it produces stays open and never
    /// settles.
    ///
    /// That is fine for the tests using it today — they assert on text
    /// arriving, not on a turn ending — but the doc used to promise a complete
    /// it never sent, which is a live trap for the next author: a settle,
    /// eviction or interrupt-latch test written on this helper would assert
    /// against a turn that never finished, and could pass for the wrong reason.
    /// This campaign has already produced one test that went green against the
    /// defect it was written to catch; this is the same failure mode waiting to
    /// happen.
    ///
    /// If you need a finished turn, emit `message.complete` yourself after
    /// calling this. Deliberately not folded in — existing tests depend on the
    /// turn staying open.
    func emitAssistantText(_ text: String, sessionID: String) async {
        await emit("message.start", sessionID: sessionID)
        await emit("message.delta", sessionID: sessionID, payload: .object(["text": .string(text)]))
    }

    func emitSessionInfo(sessionID: String, model: String = "scripted-model") async {
        await emit("session.info", sessionID: sessionID, payload: Self.info(model: model))
    }

    /// Drop the socket. `code` 0 is a plain drop (the client reconnects);
    /// 4401/4403 is a credential rejection (it does not).
    func dropConnection(code: Int = 0) async {
        guard let transport = activeTransport else { return }
        await transport.serverClose(code: code)
    }
}

/// Stand-in for `WebSocketTransport`, mirroring its contract exactly as the
/// kit's own scripted transport does: `connect` returns once the receive loop
/// would be running, `gateway.ready` arrives as a frame, closes arrive through
/// the state callback.
actor ScriptedTransport: GatewayTransport {
    private let backend: ScriptedBackend
    private let onFrame: WebSocketTransport.FrameHandler
    private let onState: WebSocketTransport.StateHandler

    private(set) var state: ConnectionState = .idle
    private(set) var lastCloseCode: Int = 0
    private(set) var sentLines: [String] = []

    init(
        backend: ScriptedBackend,
        onFrame: @escaping WebSocketTransport.FrameHandler,
        onState: @escaping WebSocketTransport.StateHandler
    ) {
        self.backend = backend
        self.onFrame = onFrame
        self.onState = onState
    }

    func connect(url: URL) async throws {
        state = .open
        await backend.attach(self)
        await onState(.open, 0)
        var payload: [String: JSONValue] = ["change_events": .bool(true)]
        // The D3 handshake, off unless a test asked for it.
        if await backend.advertisesSessionMirroring {
            payload["session_mirroring"] = .bool(true)
            payload["origin"] = .string(ScriptedBackend.transportOrigin)
        }
        if let skin = await backend.readySkin {
            payload["skin"] = skin
        }
        await onFrame(.event(GatewayEvent(
            type: "gateway.ready",
            sessionID: "",
            payload: .object(payload),
            params: .null
        )))
    }

    func disconnect() async {
        guard state != .closed else { return }
        state = .closed
        await onState(.closed, lastCloseCode)
    }

    func send(line: String) async throws {
        guard state == .open else {
            throw JSONRPCError(code: -32000, message: "gateway not connected")
        }
        sentLines.append(line)
        let verdict = await backend.receive(line: line, from: self)
        if case .failWrite = verdict {
            // The bytes went out; the write reported failure. `HermesError.from`
            // maps an NSURLError to `.connectFailed`, which is what a real
            // `URLSessionWebSocketTask.send` failure produces.
            throw URLError(.networkConnectionLost)
        }
    }

    /// A server→client frame arriving on this socket.
    func deliver(line: String) async {
        guard state == .open else { return }
        for result in JSONRPCCodec.decodeMessage(line) {
            if case .success(let frame) = result { await onFrame(frame) }
        }
    }

    /// The server side closing the socket.
    func serverClose(code: Int) async {
        lastCloseCode = code
        state = .closed
        await onState(.closed, code)
    }
}

/// Hands one scripted transport per dial and records them all. Lock-based
/// because `HermesClient.TransportFactory` is a synchronous closure — the same
/// reason the kit's `TransportHub` is.
final class TransportHub: @unchecked Sendable {
    private let lock = NSLock()
    private let backend: ScriptedBackend
    private var created: [ScriptedTransport] = []

    init(backend: ScriptedBackend) { self.backend = backend }

    func make(
        onFrame: @escaping WebSocketTransport.FrameHandler,
        onState: @escaping WebSocketTransport.StateHandler
    ) -> ScriptedTransport {
        lock.lock(); defer { lock.unlock() }
        let transport = ScriptedTransport(backend: backend, onFrame: onFrame, onState: onState)
        created.append(transport)
        return transport
    }

    var transports: [ScriptedTransport] {
        lock.lock(); defer { lock.unlock() }
        return created
    }
}
