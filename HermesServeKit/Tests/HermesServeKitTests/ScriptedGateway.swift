import Foundation

@testable import HermesServeKit

/// A gateway that answers.
///
/// `HermesClientConnectTests.ScriptedTransport` exists to prove the connect
/// machine, so it never replies to anything. This one exists for the opposite
/// question — what an API wrapper puts ON the wire — so it records every
/// outbound line and answers each request with a canned result queued per
/// method. No sockets, no dependencies; the seam is the same
/// `transportFactory` the connect tests use.
actor ScriptedGatewayTransport: GatewayTransport {
    private let onFrame: WebSocketTransport.FrameHandler
    private let onState: WebSocketTransport.StateHandler
    /// method → results, consumed in order. A method with nothing left queued
    /// gets an empty object, which every decode in this kit must survive.
    private var replies: [String: [JSONValue]]

    private(set) var state: ConnectionState = .idle
    private(set) var lastCloseCode: Int = 0
    private(set) var sentLines: [String] = []

    init(
        replies: [String: [JSONValue]],
        onFrame: @escaping WebSocketTransport.FrameHandler,
        onState: @escaping WebSocketTransport.StateHandler
    ) {
        self.replies = replies
        self.onFrame = onFrame
        self.onState = onState
    }

    func connect(url: URL) async throws {
        state = .open
        await onState(.open, 0)
        await onFrame(.event(GatewayEvent(
            type: "gateway.ready",
            sessionID: "",
            payload: .object(["change_events": .bool(true)]),
            params: .null
        )))
    }

    func disconnect() async {
        state = .closed
        await onState(.closed, lastCloseCode)
    }

    func send(line: String) async throws {
        sentLines.append(line)
        guard let value = try? JSONDecoder().decode(JSONValue.self, from: Data(line.utf8)),
              let id = value["id"],
              let method = value["method"]?.stringValue
        else { return }
        var queue = replies[method] ?? []
        let result = queue.isEmpty ? JSONValue.object([:]) : queue.removeFirst()
        replies[method] = queue
        let frame: JSONRPCFrame
        if let error = Self.scriptedError(result) {
            frame = .response(JSONRPCResponse(id: id, result: nil, error: error))
        } else {
            frame = .response(JSONRPCResponse(id: id, result: result, error: nil))
        }
        // Handed off rather than awaited so the reply never re-enters the
        // client actor from inside its own writer task.
        Task { await self.onFrame(frame) }
    }

    /// The key `ScriptedGateway.rpcError` wraps a queued error reply in; no real result carries it.
    static let errorMarker = "__scripted_rpc_error__"

    private static func scriptedError(_ value: JSONValue) -> JSONRPCError? {
        guard let body = value[errorMarker] else { return nil }
        return JSONRPCError(code: body["code"]?.coercedInt ?? 0, message: body["message"]?.coercedString ?? "", data: body["data"])
    }

    /// The `params` object of the most recent request for `method`, or nil when
    /// nothing was ever sent for it.
    func sentParams(_ method: String) -> JSONValue? {
        for line in sentLines.reversed() {
            guard let value = try? JSONDecoder().decode(JSONValue.self, from: Data(line.utf8)),
                  value["method"]?.stringValue == method
            else { continue }
            return value["params"] ?? .null
        }
        return nil
    }

    func sentCount(_ method: String) -> Int {
        sentLines.filter { line in
            guard let value = try? JSONDecoder().decode(JSONValue.self, from: Data(line.utf8))
            else { return false }
            return value["method"]?.stringValue == method
        }.count
    }
}

/// The factory closure is synchronous, so the transport it builds has to come
/// back out through a lock rather than an actor.
private final class TransportBox: @unchecked Sendable {
    private let lock = NSLock()
    private var created: ScriptedGatewayTransport?

    func make(
        replies: [String: [JSONValue]],
        onFrame: @escaping WebSocketTransport.FrameHandler,
        onState: @escaping WebSocketTransport.StateHandler
    ) -> ScriptedGatewayTransport {
        lock.lock(); defer { lock.unlock() }
        let transport = ScriptedGatewayTransport(
            replies: replies, onFrame: onFrame, onState: onState
        )
        created = transport
        return transport
    }

    var transport: ScriptedGatewayTransport? {
        lock.lock(); defer { lock.unlock() }
        return created
    }
}

enum ScriptedGateway {
    /// A queued reply that answers as a JSON-RPC error frame instead of a result.
    /// `data` is the error's structured detail; nil sends none, as before.
    static func rpcError(code: Int, message: String, data: JSONValue? = nil) -> JSONValue {
        var body: [String: JSONValue] = [
            "code": .number(Double(code)),
            "message": .string(message),
        ]
        if let data { body["data"] = data }
        return .object([ScriptedGatewayTransport.errorMarker: .object(body)])
    }

    /// The `params` of every request sent for `method`, oldest first.
    static func allSentParams(_ method: String, on transport: ScriptedGatewayTransport) async -> [JSONValue] {
        let lines = await transport.sentLines
        return lines.compactMap { line in
            guard let value = try? JSONDecoder().decode(JSONValue.self, from: Data(line.utf8)),
                  value["method"]?.stringValue == method
            else { return nil }
            return value["params"] ?? .null
        }
    }

    /// An open `HermesClient` whose socket answers `replies`, plus the socket
    /// itself so a test can read back what was sent.
    static func connected(
        replies: [String: [JSONValue]] = [:]
    ) async throws -> (HermesClient, ScriptedGatewayTransport) {
        let box = TransportBox()
        let client = HermesClient(
            dialer: GatewayDialer(
                getStatus: {
                    ServerStatus(json: .object([
                        "version": .string("test"),
                        "auth_required": .bool(false),
                        "gateway_running": .bool(true),
                    ]))
                },
                webSocketURL: { _ in URL(string: "ws://scripted.test/ws")! }
            ),
            log: nil,
            transportFactory: { onFrame, onState in
                box.make(replies: replies, onFrame: onFrame, onState: onState)
            }
        )
        try await client.connect()
        guard let transport = box.transport else {
            throw JSONRPCError(code: -1, message: "scripted transport was never built")
        }
        return (client, transport)
    }
}
