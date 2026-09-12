import XCTest

@testable import HermesServeKit

/// BUG-065 — *when* the keepalive is armed, which is the constraint the whole
/// feature has to obey.
///
/// A ping must never gate the handshake. `WebSocketTransport.connect` carries
/// the note: CFNetwork will not service the pong while the server's opening
/// `gateway.ready` sits unread in the receive queue, so a ping-gated open
/// self-deadlocks against a server-speaks-first protocol and the socket is torn
/// down ~15 s later having received nothing. That is why the original
/// ping-gated open was removed, and re-introducing a probe anywhere in the
/// connect path would re-introduce the deadlock with it.
///
/// So: not in `connect`, not in `openSocket`, not in `waitForReady`. On
/// `gateway.ready`, and nowhere else.
final class KeepaliveArmingTests: XCTestCase {

    /// Delivers `.open` from `connect` and holds `gateway.ready` until the test
    /// releases it, so the handshake window is observable.
    private actor Transport: GatewayTransport {
        private let onFrame: WebSocketTransport.FrameHandler
        private let onState: WebSocketTransport.StateHandler

        private(set) var state: ConnectionState = .idle
        private(set) var lastCloseCode: Int = 0
        private(set) var keepaliveStarts = 0
        private(set) var keepaliveStops = 0
        private(set) var readyDelivered = false
        /// The count at the moment `gateway.ready` was handed over — anything
        /// above zero here is a probe armed during the handshake.
        private(set) var startsBeforeReady = -1

        init(
            onFrame: @escaping WebSocketTransport.FrameHandler,
            onState: @escaping WebSocketTransport.StateHandler
        ) {
            self.onFrame = onFrame
            self.onState = onState
        }

        func connect(url: URL) async throws {
            state = .open
            await onState(.open, 0)
        }

        func deliverReady() async {
            startsBeforeReady = keepaliveStarts
            readyDelivered = true
            await onFrame(.event(GatewayEvent(
                type: "gateway.ready",
                sessionID: "",
                payload: .object(["change_events": .bool(true)]),
                params: .null
            )))
        }

        func disconnect() async {
            state = .closed
            await onState(.closed, 0)
        }

        func send(line: String) async throws {}

        func startKeepalive() async { keepaliveStarts += 1 }
        func stopKeepalive() async { keepaliveStops += 1 }
    }

    private final class Hub: @unchecked Sendable {
        private let lock = NSLock()
        private var created: [Transport] = []

        func make(
            onFrame: @escaping WebSocketTransport.FrameHandler,
            onState: @escaping WebSocketTransport.StateHandler
        ) -> Transport {
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
                webSocketURL: { _ in URL(string: "ws://mock.test/ws")! }
            ),
            log: nil,
            transportFactory: { onFrame, onState in hub.make(onFrame: onFrame, onState: onState) }
        )
        return (client, hub)
    }

    private func waitUntil(timeout: TimeInterval = 5, _ predicate: () async -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await predicate() { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return await predicate()
    }

    func testTheKeepaliveIsArmedOnGatewayReadyAndNotBefore() async throws {
        let (client, hub) = makeClient()

        let dialing = Task { try? await client.connect() }
        let dialed = await waitUntil { hub.transports.isEmpty == false }
        XCTAssertTrue(dialed, "precondition: no transport was created")

        let transport = hub.transports[0]
        let waiting = await waitUntil {
            let state = await transport.state
            return state == .open
        }
        XCTAssertTrue(waiting, "precondition: the socket never reached .open")

        // The handshake window: the socket is open and reading, the client is
        // parked in waitForReady, and nothing may have pinged yet.
        let duringHandshake = await transport.keepaliveStarts
        XCTAssertEqual(
            duringHandshake, 0,
            "a ping issued before gateway.ready deadlocks against it — the deadlock the "
                + "ping-gated open was removed for"
        )

        await transport.deliverReady()
        _ = await dialing.value

        let startsBeforeReady = await transport.startsBeforeReady
        XCTAssertEqual(startsBeforeReady, 0, "the probe was armed inside the handshake")

        let armed = await waitUntil { await transport.keepaliveStarts == 1 }
        XCTAssertTrue(armed, "nothing arms the liveness probe once the connection is live")

        let state = await client.state
        XCTAssertTrue(state.isOpen)

        await client.disconnect()
    }

    /// Every connection gets one, including the ones a reconnect makes. A
    /// keepalive armed only on the first dial leaves every later socket
    /// unmonitored, which is precisely the socket a flaky link produces most
    /// of.
    func testEachNewSocketArmsItsOwnKeepalive() async throws {
        let (client, hub) = makeClient()

        let firstDial = Task { try? await client.connect() }
        _ = await waitUntil { hub.transports.isEmpty == false }
        await hub.transports[0].deliverReady()
        _ = await firstDial.value
        _ = await waitUntil { await hub.transports[0].keepaliveStarts == 1 }

        await client.disconnect()

        let secondDial = Task { try? await client.connect() }
        let redialed = await waitUntil { hub.transports.count == 2 }
        XCTAssertTrue(redialed, "precondition: the second connect never dialed")
        await hub.transports[1].deliverReady()
        _ = await secondDial.value

        let armed = await waitUntil { await hub.transports[1].keepaliveStarts == 1 }
        XCTAssertTrue(armed, "the second socket runs unmonitored")

        await client.disconnect()
    }
}
