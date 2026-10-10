import XCTest
@testable import HermesServeKit

/// Requests only a Desktop window can answer (`preview.read`, `preview.act`, `terminal.read`, `window.read`, `tour`) used to wait for a tap on the phone, and the agent waited with them. A backend that advertises `declines_not_shown` counts a 4404 as this client abstaining and settles the request the moment every attached client has (`tui_gateway/server_requests.py:24-28`, `:221-250`; `tui_gateway/contracts/liveness.py:39-43`), so the phone declines them as they arrive. An older backend settles on the first error of any kind, which would beat a Desktop window that could answer, so there the phone stays silent.
final class WindowRequestDeclineTests: XCTestCase {
    private actor Transport: GatewayTransport {
        let onFrame: WebSocketTransport.FrameHandler
        let onState: WebSocketTransport.StateHandler
        let capabilities: JSONValue
        let earlyRequest: (method: String, id: String)?
        private(set) var state: ConnectionState = .idle
        private(set) var lastCloseCode = 0
        private(set) var sent: [JSONValue] = []
        private var replies: [String: JSONValue] = [:]
        private var capabilityID: JSONValue?

        init(onFrame: @escaping WebSocketTransport.FrameHandler, onState: @escaping WebSocketTransport.StateHandler,
             capabilities: JSONValue, earlyRequest: (method: String, id: String)?) {
            self.onFrame = onFrame; self.onState = onState
            self.capabilities = capabilities; self.earlyRequest = earlyRequest
        }
        func connect(url: URL) async throws {
            state = .open
            await onState(.open, 0)
            await onFrame(.event(GatewayEvent(type: "gateway.ready", sessionID: "", payload: .object([:]), params: .null)))
        }
        func disconnect() async { state = .closed; await onState(.closed, 0) }
        func send(line: String) async throws {
            let wire = try JSONDecoder().decode(JSONValue.self, from: Data(line.utf8))
            sent.append(wire)
            guard let method = wire["method"]?.stringValue, let id = wire["id"] else { return }
            if method == "client.capabilities" {
                if let earlyRequest {
                    // The question lands while the capability answer is still on its way.
                    capabilityID = id
                    await onFrame(.serverRequest(id: .string(earlyRequest.id), method: earlyRequest.method,
                                                 params: .object(["session_id": .string("session")])))
                    return
                }
                await onFrame(.response(JSONRPCResponse(id: id, result: capabilities, error: nil)))
            } else {
                await onFrame(.response(JSONRPCResponse(id: id, result: replies[method] ?? .object([:]), error: nil)))
            }
        }
        func answerCapabilities() async {
            guard let capabilityID else { return }
            await onFrame(.response(JSONRPCResponse(id: capabilityID, result: capabilities, error: nil)))
        }
        func receive(_ frame: JSONRPCFrame) async { await onFrame(frame) }
        func reply(_ method: String, _ value: JSONValue) { replies[method] = value }
        var responses: [JSONValue] { sent.filter { $0["method"] == nil } }
    }

    private final class Box: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: Transport?
        var transport: Transport? {
            get { lock.lock(); defer { lock.unlock() }; return stored }
            set { lock.lock(); stored = newValue; lock.unlock() }
        }
    }

    private static let counting: JSONValue = .object([
        "server_requests": .array(["clarify", "approval", "preview.read", "preview.act", "terminal.read", "window.read", "tour"].map(JSONValue.string)),
        "declines_not_shown": .bool(true),
    ])
    private static let older: JSONValue = .object([
        "server_requests": .array(["clarify", "approval", "preview.read"].map(JSONValue.string)),
    ])
    private static let windowOwned = ["preview.read", "preview.act", "terminal.read", "window.read", "tour"]

    private func connect(capabilities: JSONValue, earlyRequest: (method: String, id: String)? = nil) async throws -> (HermesClient, Transport) {
        let box = Box()
        let client = HermesClient(dialer: GatewayDialer(
            getStatus: { ServerStatus(json: .object(["version": .string("test"), "auth_required": .bool(false), "gateway_running": .bool(true)])) },
            webSocketURL: { _ in URL(string: "ws://example.invalid/ws")! }), handlesServerRequests: true,
            transportFactory: { onFrame, onState in
                let transport = Transport(onFrame: onFrame, onState: onState, capabilities: capabilities, earlyRequest: earlyRequest)
                box.transport = transport
                return transport
            })
        try await client.connect()
        return (client, try XCTUnwrap(box.transport))
    }

    private func emit(_ transport: Transport, id: String, method: String) async {
        await transport.receive(.serverRequest(id: .string(id), method: method, params: .object(["session_id": .string("session")])))
    }

    private func barrier(_ client: HermesClient) async throws { _ = try await client.request("ping") }

    func testEveryWindowOwnedRequestIsDeclinedWith4404AndNothingElseIs() async throws {
        let (client, transport) = try await connect(capabilities: Self.counting)
        try await barrier(client)
        for method in Self.windowOwned + ["clarify", "vault.save_login", "future.method"] {
            await emit(transport, id: "q-\(method)", method: method)
        }
        try await barrier(client)

        let declines = await transport.responses
        XCTAssertEqual(Set(declines.compactMap { $0["id"]?.stringValue }), Set(Self.windowOwned.map { "q-\($0)" }))
        for decline in declines {
            XCTAssertEqual(decline["error"]?["code"], .number(4404), "only the not-shown code is counted as abstaining")
            XCTAssertNil(decline["result"])
        }
        let open = await client.openServerRequests(sessionID: "session").map(\.identity.method)
        XCTAssertEqual(Set(open), ["clarify", "vault.save_login", "future.method"],
                       "a declined request never reaches the phone's notice; everything else still waits for the user")
        await client.disconnect()
    }

    func testAnOlderBackendIsNeverAnsweredAutomatically() async throws {
        let (client, transport) = try await connect(capabilities: Self.older)
        try await barrier(client)
        for method in Self.windowOwned { await emit(transport, id: "q-\(method)", method: method) }
        try await barrier(client)
        let responses = await transport.responses
        XCTAssertTrue(responses.isEmpty, "an older backend settles on any error, so a decline here would beat a Desktop window that could answer")
        let open = await client.openServerRequests(sessionID: "session")
        XCTAssertEqual(open.count, Self.windowOwned.count)
        await client.disconnect()
    }

    func testARequestThatArrivedBeforeTheCapabilityAnswerIsDeclinedWhenItLands() async throws {
        let (client, transport) = try await connect(capabilities: Self.counting, earlyRequest: (method: "tour", id: "early"))
        try await barrier(client)
        let waiting = await client.openServerRequests(sessionID: "session").map(\.identity.method)
        XCTAssertEqual(waiting, ["tour"], "nothing is known about the backend yet, so the request is held")
        await transport.answerCapabilities()
        try await barrier(client)
        let responses = await transport.responses
        XCTAssertEqual(responses.map { $0["id"]?.stringValue }, ["early"])
        XCTAssertEqual(responses.first?["error"]?["code"], .number(4404))
        let open = await client.openServerRequests(sessionID: "session")
        XCTAssertTrue(open.isEmpty)
        await client.disconnect()
    }

    func testAReplayedWindowRequestIsDeclinedOnceNotOnEveryReplay() async throws {
        let (client, transport) = try await connect(capabilities: Self.counting)
        try await barrier(client)
        // The backend keeps the request open for a Desktop owner, so every snapshot repeats it.
        await transport.reply("session.events.since", .object(["session_id": .string("session"), "open_requests": .array([
            .object(["id": .string("srq-preview"), "method": .string("preview.read"),
                     "params": .object(["session_id": .string("session")])]),
        ])]))
        _ = try await client.request("session.events.since", params: .object(["session_id": .string("session")]))
        _ = try await client.request("session.events.since", params: .object(["session_id": .string("session")]))
        try await barrier(client)
        let responses = await transport.responses
        XCTAssertEqual(responses.map { $0["id"]?.stringValue }, ["srq-preview"])
        XCTAssertEqual(responses.first?["error"]?["code"], .number(4404))
        let open = await client.openServerRequests(sessionID: "session")
        XCTAssertTrue(open.isEmpty)
        await client.disconnect()
    }
}
