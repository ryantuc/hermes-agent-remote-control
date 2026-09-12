import XCTest

@testable import HermesServeKit

/// FEAT-015 — the WS ticket moves from the query string into
/// `Sec-WebSocket-Protocol`, with the old path kept as an automatic fallback.
///
/// This is the one change in its batch that can stop the phone connecting at
/// all, so both halves are pinned here: the **exact** protocol set offered (the
/// server rejects an ambiguous one outright, which is worse than not trying),
/// and the fallback — one retry down the `?ticket=` path, with a freshly minted
/// ticket, when the first attempt does not reach `gateway.ready`.
///
/// Server side, read at `hermes-agent` `de25a6971d` (0.20.5, the revision this
/// client's backend is actually running), `hermes_cli/web_server.py:15964-16081`:
/// `_gateway_ws_ticket_from_subprotocol` answers `"none"` with no ticket
/// protocol present, `"invalid"` when the public protocol is missing or more
/// than one ticket protocol was offered, and `_ws_auth_reason` turns `"invalid"`
/// into `ticket_invalid` → close 4401.
final class GatewayTicketSubprotocolTests: XCTestCase {

    // MARK: - The offer

    /// The public protocol must be present and there must be exactly one
    /// ticket protocol. Offering the ticket protocol alone is `ticket_invalid`.
    func testTheOfferIsThePublicProtocolAndExactlyOneTicket() {
        let offered = GatewayWSProtocol.offer(ticket: "t-123")

        XCTAssertEqual(offered, ["hermes-gateway-v1", "hermes-gateway-ticket.t-123"])
        XCTAssertTrue(offered.contains(GatewayWSProtocol.publicProtocol))
        XCTAssertEqual(
            offered.filter { $0.hasPrefix(GatewayWSProtocol.ticketPrefix) }.count, 1,
            "two ticket protocols is ticket_invalid, not a better attempt"
        )
    }

    func testAnEmptyTicketOffersNothing() {
        XCTAssertTrue(
            GatewayWSProtocol.offer(ticket: "").isEmpty,
            "the public protocol alone would authenticate nothing and risks a bare-protocol handshake"
        )
    }

    func testADialKnowsWhetherItCarriesTheTicketInAProtocol() {
        let url = URL(string: "wss://backend.example/api/ws")!

        let subprotocol = GatewayDial(url: url, protocols: GatewayWSProtocol.offer(ticket: "t-123"))
        XCTAssertTrue(subprotocol.carriesTicketProtocol)

        let query = GatewayDial(url: URL(string: "wss://backend.example/api/ws?ticket=t-123")!)
        XCTAssertFalse(query.carriesTicketProtocol)
        XCTAssertTrue(query.protocols.isEmpty)
    }

    // MARK: - The fallback

    /// The failure a client actually hits against a backend
    /// that predates the subprotocol: the upgrade is refused, the socket closes
    /// 4401, `gateway.ready` never arrives — and the client must not stop
    /// there. It re-dials the old way and connects.
    func testARejectedSubprotocolHandshakeFallsBackToTheQueryTicket() async throws {
        let box = DialRecorder()
        let client = HermesClient(
            dialer: box.dialer(),
            log: nil,
            transportFactory: { onFrame, onState in
                box.make(onFrame: onFrame, onState: onState)
            }
        )

        try await client.connect()

        // Unwrapped, not subscripted: a regression that stops retrying leaves
        // one attempt here, and a bare `attempts[1]` would trap and take the
        // whole kit process down instead of reporting which test broke.
        let attempts = box.attempts
        XCTAssertEqual(attempts.count, 2, "exactly one retry, not a loop")
        let first = try XCTUnwrap(attempts.first)
        let second = try XCTUnwrap(attempts.dropFirst().first, "no fallback attempt was made")

        XCTAssertEqual(first.protocols, ["hermes-gateway-v1", "hermes-gateway-ticket.ticket-1"])
        XCTAssertNil(
            URLComponents(url: first.url, resolvingAgainstBaseURL: false)?
                .queryItems?.first { $0.name == "ticket" },
            "the whole point: attempt one puts no credential in the URL"
        )

        XCTAssertTrue(second.protocols.isEmpty, "the fallback offers no subprotocol")
        XCTAssertEqual(
            URLComponents(url: second.url, resolvingAgainstBaseURL: false)?
                .queryItems?.first { $0.name == "ticket" }?.value,
            "ticket-2",
            "the fallback mints a fresh ticket — the first is single-use whether or not it was consumed"
        )

        let state = await client.state
        XCTAssertTrue(state.isOpen, "the fallback is what connected")
    }

    /// Having fallen back once, the client stops paying for the doubled dial:
    /// a second connect on the same client goes straight down the old path.
    func testTheClientStopsPreferringTheSubprotocolOnceItHasFallenBack() async throws {
        let box = DialRecorder()
        let client = HermesClient(
            dialer: box.dialer(),
            log: nil,
            transportFactory: { onFrame, onState in
                box.make(onFrame: onFrame, onState: onState)
            }
        )

        try await client.connect()
        await client.disconnect()
        box.reset()
        try await client.connect()

        XCTAssertEqual(box.attempts.count, 1, "no second doubled dial")
        XCTAssertTrue(try XCTUnwrap(box.attempts.first).protocols.isEmpty)
    }

    /// A backend that accepts the subprotocol connects on the first attempt and
    /// no ticket ever reaches a URL.
    func testAnAcceptedSubprotocolConnectsWithoutTouchingTheQueryString() async throws {
        let box = DialRecorder(rejectSubprotocol: false)
        let client = HermesClient(
            dialer: box.dialer(),
            log: nil,
            transportFactory: { onFrame, onState in
                box.make(onFrame: onFrame, onState: onState)
            }
        )

        try await client.connect()

        XCTAssertEqual(box.attempts.count, 1)
        let only = try XCTUnwrap(box.attempts.first)
        XCTAssertEqual(only.protocols.first, "hermes-gateway-v1")
        XCTAssertFalse(only.url.absoluteString.contains("ticket="))
        let state = await client.state
        XCTAssertTrue(state.isOpen)
    }

    /// A loopback backend has no ticket to move — its credential is `?token=`,
    /// which the server reads only from the query. Nothing is offered, and
    /// there is nothing to fall back from.
    func testALoopbackDialOffersNoProtocolsAndDoesNotRetry() async throws {
        let box = DialRecorder(authRequired: false)
        let client = HermesClient(
            dialer: box.dialer(),
            log: nil,
            transportFactory: { onFrame, onState in
                box.make(onFrame: onFrame, onState: onState)
            }
        )

        try await client.connect()

        XCTAssertEqual(box.attempts.count, 1)
        let only = try XCTUnwrap(box.attempts.first)
        XCTAssertTrue(only.protocols.isEmpty)
        XCTAssertTrue(only.url.absoluteString.contains("token=local"))
    }
}

// MARK: - Harness

/// A dialer plus a transport that records what each attempt offered, and can
/// refuse a subprotocol handshake the way the gateway does: accept the socket,
/// then close 4401 without ever sending `gateway.ready`.
private final class DialRecorder: @unchecked Sendable {
    struct Attempt {
        let url: URL
        let protocols: [String]
    }

    private let lock = NSLock()
    private var recorded: [Attempt] = []
    private var mintCount = 0
    private let rejectSubprotocol: Bool
    private let authRequired: Bool

    init(rejectSubprotocol: Bool = true, authRequired: Bool = true) {
        self.rejectSubprotocol = rejectSubprotocol
        self.authRequired = authRequired
    }

    var attempts: [Attempt] {
        lock.lock(); defer { lock.unlock() }
        return recorded
    }

    func reset() {
        lock.lock(); defer { lock.unlock() }
        recorded = []
    }

    func record(_ attempt: Attempt) {
        lock.lock(); defer { lock.unlock() }
        recorded.append(attempt)
    }

    func shouldRefuse(_ protocols: [String]) -> Bool {
        rejectSubprotocol && protocols.contains { $0.hasPrefix(GatewayWSProtocol.ticketPrefix) }
    }

    private func nextTicket() -> String {
        lock.lock(); defer { lock.unlock() }
        mintCount += 1
        return "ticket-\(mintCount)"
    }

    func dialer() -> GatewayDialer {
        let authRequired = self.authRequired
        return GatewayDialer(
            getStatus: {
                ServerStatus(json: .object([
                    "version": .string("0.20.5"),
                    "auth_required": .bool(authRequired),
                    "gateway_running": .bool(true),
                ]))
            },
            webSocketURL: { _ in URL(string: "wss://backend.example/api/ws?ticket=legacy")! },
            webSocketDial: { [weak self] gated, preferSubprotocol in
                guard let self else { throw HermesError.notConnected }
                guard gated else {
                    return GatewayDial(url: URL(string: "ws://127.0.0.1:8790/api/ws?token=local")!)
                }
                let ticket = self.nextTicket()
                if preferSubprotocol {
                    return GatewayDial(
                        url: URL(string: "wss://backend.example/api/ws")!,
                        protocols: GatewayWSProtocol.offer(ticket: ticket)
                    )
                }
                return GatewayDial(url: URL(string: "wss://backend.example/api/ws?ticket=\(ticket)")!)
            }
        )
    }

    func make(
        onFrame: @escaping WebSocketTransport.FrameHandler,
        onState: @escaping WebSocketTransport.StateHandler
    ) -> RecordingTransport {
        RecordingTransport(recorder: self, onFrame: onFrame, onState: onState)
    }
}

private actor RecordingTransport: GatewayTransport {
    private let recorder: DialRecorder
    private let onFrame: WebSocketTransport.FrameHandler
    private let onState: WebSocketTransport.StateHandler

    private(set) var state: ConnectionState = .idle
    private(set) var lastCloseCode: Int = 0

    init(
        recorder: DialRecorder,
        onFrame: @escaping WebSocketTransport.FrameHandler,
        onState: @escaping WebSocketTransport.StateHandler
    ) {
        self.recorder = recorder
        self.onFrame = onFrame
        self.onState = onState
    }

    func connect(url: URL) async throws {
        try await connect(url: url, protocols: [])
    }

    func connect(url: URL, protocols: [String]) async throws {
        recorder.record(DialRecorder.Attempt(url: url, protocols: protocols))
        state = .open
        await onState(.open, 0)

        if recorder.shouldRefuse(protocols) {
            // What the gateway does with `ticket_invalid`, and what a backend
            // that has never heard of the subprotocol does with no credential:
            // refuse the upgrade, close 4401, never speak first.
            state = .closed
            lastCloseCode = 4401
            await onState(.closed, 4401)
            return
        }

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

    func send(line: String) async throws {}
}
