import Foundation
import HermesServeKit

/// A backend that is not there: a fake transport, not a fake UI.
///
/// It sits on the seam `HermesClient` already has for its own connect tests, answers the JSON-RPC methods the app calls when it opens, and replays a scripted event sequence with small pauses; everything above it is the shipping app.
///
/// It ships in release builds, because a `#if DEBUG` demo is a demo App Review cannot see — which is also why it is not wired to the DEBUG-only `-hermesScreenshotRoute` harness.
///
/// Nothing here can reach the network: no URLSession, no `RestAPI`, no `AuthenticationClient`, and the only socket is `DemoTransport`, which is a queue.
actor DemoBackend {

    /// The websocket URL the dialer reports; never opened, and on the reserved `.invalid` TLD that can never resolve.
    static let webSocketURL = URL(string: "ws://demo.invalid/api/ws")!
    /// The runtime session id every canned answer mints; the demo never has two sessions in flight.
    static let runtimeSessionID = "demo-runtime-1"
    static let storedSessionID = "demo-session-1"
    /// The version the demo claims, labelled rather than a plausible number so the Backend screen cannot read as a real server.
    static let serverVersion = "demo"

    /// Divides every pause in the script: always 1 in the app, raised by a test so the replay finishes in milliseconds.
    private let playbackSpeed: Double

    init(playbackSpeed: Double = 1) {
        self.playbackSpeed = max(1, playbackSpeed)
    }

    // MARK: Sockets

    private var transports: [DemoTransport] = []
    private var activeTransport: DemoTransport? { transports.last }

    /// How many sockets this backend has accepted; it moves only in `DemoTransport.connect`, so a non-zero value with a nil `AppModel.rest` proves the client dialed the demo and nothing else.
    private(set) var socketCount = 0

    func attach(_ transport: DemoTransport) {
        transports.append(transport)
        socketCount += 1
    }

    // MARK: Replay bookkeeping

    /// How many prompts the demo has been given; BUG-103: it selects nothing, because the script is keyed off the prompt that arrived.
    private(set) var submissionCount = 0
    /// How many scripted turns have finished replaying.
    private(set) var completedTurns = 0
    /// Every prompt whose replay has finished, so a waiter can ask about its own turn rather than a total anyone can move.
    private(set) var completedPrompts: Set<String> = []
    private var countWaiters: [(needed: Int, continuation: CheckedContinuation<Void, Never>)] = []
    private var promptWaiters: [(prompt: String, continuation: CheckedContinuation<Void, Never>)] = []

    /// The replay in flight, and the turns waiting behind it: a queue, because a real gateway serialises turns on one session and a replay cancelled mid-stream leaves a message with no `message.complete`.
    private var replayTask: Task<Void, Never>?
    private var pending: [QueuedTurn] = []

    /// One turn waiting to play, keyed by the submitted text rather than `Turn.prompt`, because the freeform turn's own prompt is empty by construction.
    private struct QueuedTurn {
        let key: String
        let turn: DemoScript.Turn
    }

    /// Suspend until at least `count` scripted turns have finished.
    func waitForTurns(_ count: Int) async {
        if completedTurns >= count { return }
        await withCheckedContinuation { continuation in
            countWaiters.append((count, continuation))
        }
    }

    /// Suspend until the turn provoked by `prompt` has finished replaying; returns immediately when nothing is in flight for it, so a shutdown cannot strand the driver.
    func waitForPrompt(_ prompt: String) async {
        if completedPrompts.contains(prompt) { return }
        await withCheckedContinuation { continuation in
            promptWaiters.append((prompt, continuation))
        }
    }

    private func markTurnComplete(prompt: String) {
        completedTurns += 1
        completedPrompts.insert(prompt)
        let readyCounts = countWaiters.filter { $0.needed <= completedTurns }
        countWaiters.removeAll { $0.needed <= completedTurns }
        for waiter in readyCounts { waiter.continuation.resume() }
        let readyPrompts = promptWaiters.filter { $0.prompt == prompt }
        promptWaiters.removeAll { $0.prompt == prompt }
        for waiter in readyPrompts { waiter.continuation.resume() }
    }

    /// Stop any replay in flight and release everyone waiting on it, so no task outlives the demo.
    func shutdown() {
        replayTask?.cancel()
        replayTask = nil
        pending.removeAll()
        let pendingCounts = countWaiters
        let pendingPrompts = promptWaiters
        countWaiters.removeAll()
        promptWaiters.removeAll()
        for waiter in pendingCounts { waiter.continuation.resume() }
        for waiter in pendingPrompts { waiter.continuation.resume() }
    }

    // MARK: Dial

    func status() -> ServerStatus {
        ServerStatus(json: .object([
            "version": .string(Self.serverVersion),
            "auth_required": .bool(false),
            "gateway_running": .bool(true),
            "gateway_state": .string("running"),
        ]))
    }

    /// The dialer to hand `HermesClient`; it touches neither `RestAPI` nor `AuthenticationClient`.
    nonisolated func dialer() -> GatewayDialer {
        GatewayDialer(
            getStatus: { await self.status() },
            webSocketURL: { _ in Self.webSocketURL }
        )
    }

    /// The transport factory to hand `HermesClient`.
    nonisolated func transportFactory() -> HermesClient.TransportFactory {
        { onFrame, onState in
            DemoTransport(backend: self, onFrame: onFrame, onState: onState)
        }
    }

    // MARK: Inbound JSON-RPC

    /// One decoded client-to-server frame; unrecognised methods get an empty object, which the kit already reads as "this gateway does not have that method".
    func receive(line: String, from transport: DemoTransport) async {
        guard let frame = try? JSONRPCCodec.decodeFrame(line),
              case .serverRequest(let id, let method, let params) = frame
        else { return }
        let callID = id.coercedString ?? ""
        let result = answer(method: method, params: params ?? .null)
        if let response = try? JSONRPCCodec.encodeResponse(id: .string(callID), result: result) {
            await transport.deliver(line: response)
        }
        // The reply goes out first and the turn replays on its own task, because the ack arrives in milliseconds and the turn takes seconds.
        if method == "prompt.submit" {
            submissionCount += 1
            // BUG-103: the prompt that arrived selects the turn, so an unscripted message gets the canned answer without consuming a scripted slot.
            let text = promptText(from: params ?? .null)
            startReplay(of: DemoScript.turn(forPrompt: text), key: text)
        }
        if method == "session.interrupt" {
            interrupt()
        }
    }

    /// The text of a `prompt.submit`, however the composer spelled it.
    private func promptText(from params: JSONValue) -> String {
        let candidate = params["prompt"] ?? params["text"] ?? params["message"]
        return (candidate?.coercedString ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// BUG-102: Stop stops the replay and it stays stopped.
    ///
    /// Cancelling alone is not enough — the message already streaming would never receive a terminal frame — so the queue is dropped and the turn is completed the way a real interrupt completes one.
    private func interrupt() {
        let running = currentPrompt
        let dropped = pending
        guard running != nil || !dropped.isEmpty else { return }
        // Invalidate before cancelling, so the replay's own completion cannot clear a handle that by then belongs to a later turn.
        replayGeneration += 1
        replayTask?.cancel()
        replayTask = nil
        currentPrompt = nil
        pending.removeAll()
        Task { [weak self] in
            await self?.finishInterruptedTurn(running: running, dropped: dropped)
        }
    }

    private func finishInterruptedTurn(running: String?, dropped: [QueuedTurn]) async {
        if running != nil {
            await emit("message.complete", payload: .object([
                "status": .string("interrupted"),
                "stopped": .bool(true),
            ]))
        }
        // Whatever was cancelled or queued counts as finished; a driver suspended on a turn that will never play cannot exit the demo.
        if let running { markTurnComplete(prompt: running) }
        for queued in dropped { markTurnComplete(prompt: queued.key) }
    }

    private func answer(method: String, params: JSONValue) -> JSONValue {
        switch method {
        case "session.create", "session.activate":
            return .object([
                "session_id": .string(Self.runtimeSessionID),
                "stored_session_id": .string(Self.storedSessionID),
                "messages": .array([]),
                "info": DemoScript.info(),
            ])
        case "session.resume":
            return .object([
                "session_id": .string(Self.runtimeSessionID),
                "resumed": .string(Self.storedSessionID),
                "session_key": .string(Self.storedSessionID),
                "messages": .array([]),
                "info": DemoScript.info(),
                "running": .bool(false),
                "status": .string("idle"),
                "watching": .bool(false),
            ])
        case "prompt.submit":
            return .object(["status": .string("streaming")])
        case "session.interrupt", "session.close", "session.title":
            return .object(["ok": .bool(true)])
        case "approval.respond":
            return .object(["resolved": .number(1)])
        case "config.get":
            return .object([
                "cwd": .string(DemoScript.workingDirectory),
                "model": .string(DemoScript.modelName),
            ])
        case "session.active_list":
            // An affirmative empty roster, which keeps the hub's live dot honest between turns.
            return .object(["sessions": .array([])])
        case "session.list":
            return .object(["sessions": .array([])])
        case "profiles.list":
            return .object(["profiles": .array([])])
        default:
            // A non-answer, which is what a gateway without the method looks like.
            return .object([:])
        }
    }

    // MARK: Replay

    /// The prompt whose beats are on the socket right now, so an interrupt can finish the turn it cancelled.
    private var currentPrompt: String?
    /// Bumped whenever a replay stops being the current one, so a finishing task can tell whether the handle it clears is still its own.
    private var replayGeneration = 0

    private func startReplay(of turn: DemoScript.Turn, key: String) {
        pending.append(QueuedTurn(key: key, turn: turn))
        drainReplays()
    }

    private func drainReplays() {
        guard replayTask == nil, !pending.isEmpty else { return }
        let queued = pending.removeFirst()
        currentPrompt = queued.key
        replayGeneration += 1
        let generation = replayGeneration
        replayTask = Task { [weak self] in
            await self?.replay(queued.turn, key: queued.key)
            await self?.replayFinished(generation: generation)
        }
    }

    private func replayFinished(generation: Int) {
        guard generation == replayGeneration else { return }
        replayTask = nil
        currentPrompt = nil
        drainReplays()
    }

    private func replay(_ turn: DemoScript.Turn, key: String) async {
        for beat in turn.beats {
            if Task.isCancelled { return }
            switch beat {
            case .pause(let seconds):
                let scaled = seconds / playbackSpeed
                try? await Task.sleep(nanoseconds: UInt64(scaled * 1_000_000_000))
            case .event(let type, let payload):
                await emit(type, payload: payload)
            }
        }
        guard !Task.isCancelled else { return }
        markTurnComplete(prompt: key)
    }

    /// How many gateway events this backend has pushed onto the socket: the only honest measure of whether a replay stopped, since the client swallows events for `TurnEngine.interruptGrace` after a Stop.
    private(set) var emittedFrameCount = 0

    /// Push one gateway event onto the live socket, in the frame shape `tui_gateway` uses.
    func emit(_ type: String, payload: JSONValue = .null) async {
        var params: [String: JSONValue] = [
            "type": .string(type),
            "session_id": .string(Self.runtimeSessionID),
        ]
        if !payload.isNull { params["payload"] = payload }
        let line = try? JSONRPCCodec.encodeLine(.object([
            "jsonrpc": .string("2.0"),
            "method": .string("event"),
            "params": .object(params),
        ]))
        guard let line, let transport = activeTransport else { return }
        emittedFrameCount += 1
        await transport.deliver(line: line)
    }

    /// Replay a turn without a `prompt.submit`, the seam a test drives instead of going through the composer.
    func replayTurnDirectly(_ turn: DemoScript.Turn) async {
        await replay(turn, key: turn.prompt)
    }

    /// Deliver one `prompt.submit` the way the composer does, decoded from a real JSON-RPC line, without going through a `ChatModel`.
    ///
    /// BUG-103's seam: it exercises the frame decode and the script selector without also exercising the busy-input mode.
    func submitDirectly(prompt: String) async {
        guard let transport = activeTransport else { return }
        let line = try? JSONRPCCodec.encodeLine(.object([
            "jsonrpc": .string("2.0"),
            "id": .string("demo-test-submit"),
            "method": .string("prompt.submit"),
            "params": .object([
                "session_id": .string(Self.runtimeSessionID),
                "text": .string(prompt),
            ]),
        ]))
        guard let line else { return }
        await receive(line: line, from: transport)
    }
}

/// The demo's stand-in for `WebSocketTransport`: same contract, no socket, frames handed straight to the client's own handlers.
actor DemoTransport: GatewayTransport {
    private let backend: DemoBackend
    private let onFrame: WebSocketTransport.FrameHandler
    private let onState: WebSocketTransport.StateHandler

    private(set) var state: ConnectionState = .idle
    private(set) var lastCloseCode: Int = 0

    init(
        backend: DemoBackend,
        onFrame: @escaping WebSocketTransport.FrameHandler,
        onState: @escaping WebSocketTransport.StateHandler
    ) {
        self.backend = backend
        self.onFrame = onFrame
        self.onState = onState
    }

    func connect(url: URL) async {
        state = .open
        await backend.attach(self)
        await onState(.open, 0)
        // The gateway speaks first; `session_mirroring` is off because there is no second client to mirror to.
        await onFrame(.event(GatewayEvent(
            type: "gateway.ready",
            sessionID: "",
            payload: .object(["change_events": .bool(true)]),
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
            throw JSONRPCError(code: -32000, message: "the demo is not running")
        }
        await backend.receive(line: line, from: self)
    }

    /// A server→client frame arriving on this socket.
    func deliver(line: String) async {
        guard state == .open else { return }
        for result in JSONRPCCodec.decodeMessage(line) {
            if case .success(let frame) = result { await onFrame(frame) }
        }
    }
}
