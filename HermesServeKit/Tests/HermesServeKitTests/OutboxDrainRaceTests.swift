import XCTest

@testable import HermesServeKit

/// BUG-146 — `drainOutbox` cleared `writerTask` only after its last `await`. A send that fails
/// tears the socket down inside the drain (`failSocket`, which awaits the transport's
/// `disconnect()`); a frame enqueued during that await saw a writer still set, started none, and
/// sat in the outbox with no drain coming. The same teardown then set `transport = nil` after its
/// await, wiping out whatever socket a reconnect had installed meanwhile, so the client claimed
/// `.open` over no transport at all.
final class OutboxDrainRaceTests: XCTestCase {
    private actor Transport: GatewayTransport {
        private let onFrame: WebSocketTransport.FrameHandler
        private let onState: WebSocketTransport.StateHandler

        private(set) var state: ConnectionState = .idle
        private(set) var lastCloseCode = 0
        private(set) var sentMethods: [String] = []
        private(set) var disconnectEntered = false
        private var failSends = false
        private var holdDisconnect = false
        private var disconnectWaiter: CheckedContinuation<Void, Never>?

        init(onFrame: @escaping WebSocketTransport.FrameHandler, onState: @escaping WebSocketTransport.StateHandler) {
            self.onFrame = onFrame
            self.onState = onState
        }

        func connect(url: URL) async throws {
            state = .open
            await onState(.open, 0)
            await onFrame(.event(GatewayEvent(type: "gateway.ready", sessionID: "", payload: .object([:]), params: .null)))
        }

        func disconnect() async {
            disconnectEntered = true
            if holdDisconnect {
                await withCheckedContinuation { disconnectWaiter = $0 }
            }
            state = .closed
            await onState(.closed, 0)
        }

        func send(line: String) async throws {
            if failSends { throw HermesError.connectionClosed("synthetic dead socket") }
            let wire = try JSONDecoder().decode(JSONValue.self, from: Data(line.utf8))
            guard let method = wire["method"]?.stringValue, let id = wire["id"] else { return }
            sentMethods.append(method)
            let reply = JSONRPCFrame.response(JSONRPCResponse(id: id, result: .object(["method": .string(method)]), error: nil))
            // Handed off so the reply never re-enters the client from inside its own writer.
            Task { await self.onFrame(reply) }
        }

        /// The dead-socket condition, with the teardown held open so the test can act inside it.
        func breakAndHoldTeardown() {
            failSends = true
            holdDisconnect = true
        }

        func releaseTeardown() {
            holdDisconnect = false
            disconnectWaiter?.resume()
            disconnectWaiter = nil
        }
    }

    private final class Hub: @unchecked Sendable {
        private let lock = NSLock()
        private var created: [Transport] = []

        func make(_ onFrame: @escaping WebSocketTransport.FrameHandler, _ onState: @escaping WebSocketTransport.StateHandler) -> Transport {
            let transport = Transport(onFrame: onFrame, onState: onState)
            lock.lock(); created.append(transport); lock.unlock()
            return transport
        }

        var transports: [Transport] {
            lock.lock(); defer { lock.unlock() }
            return created
        }
    }

    private func makeClient() -> (HermesClient, Hub) {
        let hub = Hub()
        let client = HermesClient(
            dialer: GatewayDialer(
                getStatus: {
                    ServerStatus(json: .object([
                        "version": .string("test"),
                        "auth_required": .bool(false),
                        "gateway_running": .bool(true),
                    ]))
                },
                webSocketURL: { _ in URL(string: "ws://example.invalid/ws")! }
            ),
            log: nil,
            transportFactory: { hub.make($0, $1) }
        )
        return (client, hub)
    }

    private func waitUntil(timeout: TimeInterval = 5, _ predicate: () async -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await predicate() { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return await predicate()
    }

    func testARequestMadeWhileTheDeadSocketIsTornDownReachesTheReplacement() async throws {
        let (client, hub) = makeClient()
        try await client.connect()
        let first = hub.transports[0]
        await first.breakAndHoldTeardown()

        // The send that discovers the dead socket; its teardown parks inside `disconnect()`.
        let doomed = Task { try await client.request("probe.first", timeout: 5) }
        let parked = await waitUntil { await first.disconnectEntered }
        XCTAssertTrue(parked, "the failed send must reach the socket teardown")

        // A reconnect completes while that teardown is still awaiting the old socket.
        try await client.connect()
        XCTAssertEqual(hub.transports.count, 2)
        let second = hub.transports[1]
        let reconnected = await client.state
        XCTAssertEqual(reconnected, .open)

        // A request on the new socket, made while the old drain is still parked.
        let request = Task { try await client.request("probe.second", timeout: 2) }
        try await Task.sleep(nanoseconds: 200_000_000)
        await first.releaseTeardown()

        do {
            let result = try await request.value
            XCTAssertEqual(result["method"], .string("probe.second"))
        } catch {
            XCTFail("the request on the replacement socket never went out: \(error)")
        }
        let sent = await second.sentMethods
        XCTAssertTrue(sent.contains("probe.second"), "sent on the replacement: \(sent)")

        // The client is still usable afterwards, on the replacement.
        do {
            let again = try await client.request("probe.third", timeout: 2)
            XCTAssertEqual(again["method"], .string("probe.third"))
        } catch {
            XCTFail("the old socket's teardown took the replacement down with it: \(error)")
        }

        let doomedOutcome = await doomed.result
        if case .success = doomedOutcome { XCTFail("the request on the dead socket cannot have succeeded") }
        await client.disconnect()
    }

    /// The ordinary path the fix must not disturb: one failed send tears the socket down, fails what
    /// was pending, and leaves nothing behind in the outbox for the next socket.
    func testAFailedSendStillFailsItsRequestAndLeavesNothingQueued() async throws {
        let (client, hub) = makeClient()
        try await client.connect()
        let first = hub.transports[0]
        await first.breakAndHoldTeardown()
        await first.releaseTeardown()

        do {
            _ = try await client.request("probe.dead", timeout: 2)
            XCTFail("a send on a dead socket must fail")
        } catch let error as HermesError {
            XCTAssertEqual(error, .connectionClosed("synthetic dead socket"))
        }

        try await client.connect()
        XCTAssertEqual(hub.transports.count, 2)
        let result = try await client.request("probe.fresh", timeout: 2)
        XCTAssertEqual(result["method"], .string("probe.fresh"))
        let sent = await hub.transports[1].sentMethods
        XCTAssertEqual(sent, ["probe.fresh"], "nothing from the dead socket was replayed onto the new one")
        await client.disconnect()
    }
}
