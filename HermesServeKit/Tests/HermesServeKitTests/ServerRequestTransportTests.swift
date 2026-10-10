import XCTest
@testable import HermesServeKit

final class ServerRequestTransportTests: XCTestCase {
    private actor Transport: GatewayTransport {
        let onFrame: WebSocketTransport.FrameHandler
        let onState: WebSocketTransport.StateHandler
        private(set) var state: ConnectionState = .idle
        private(set) var lastCloseCode = 0
        private(set) var sent: [JSONValue] = []
        var replies: [String: JSONValue] = [:]
        let capabilityError: Bool
        let requestBeforeReady: Bool
        private var holdResponses = false
        private var responseWaiters: [CheckedContinuation<Void, Never>] = []
        var responseIsWaiting: Bool { !responseWaiters.isEmpty }
        init(onFrame: @escaping WebSocketTransport.FrameHandler, onState: @escaping WebSocketTransport.StateHandler, capabilityError: Bool = false, requestBeforeReady: Bool = false) {
            self.onFrame = onFrame; self.onState = onState; self.capabilityError = capabilityError
            self.requestBeforeReady = requestBeforeReady
        }
        func connect(url: URL) async throws {
            state = .open
            await onState(.open, 0)
            if requestBeforeReady {
                await onFrame(.serverRequest(id: .string("before-ready"), method: "secret", params: .object([
                    "session_id": .string("session"), "prompt": .string("Synthetic handshake request")])))
            }
            await onFrame(.event(GatewayEvent(type: "gateway.ready", sessionID: "", payload: .object([:]), params: .null)))
        }
        func disconnect() async { state = .closed; await onState(.closed, 0) }
        func send(line: String) async throws {
            let wire = try JSONDecoder().decode(JSONValue.self, from: Data(line.utf8))
            if holdResponses, wire["method"] == nil {
                await withCheckedContinuation { responseWaiters.append($0) }
            }
            sent.append(wire)
            guard let method = wire["method"]?.stringValue, let id = wire["id"] else { return }
            if method == "client.capabilities" {
                await onFrame(.response(JSONRPCResponse(id: id, result: capabilityError ? nil : .object(["server_requests": .array([.string("clarify"), .string("approval")])]), error: capabilityError ? JSONRPCError(code: -32601, message: "Unknown method") : nil)))
            } else {
                await onFrame(.response(JSONRPCResponse(id: id, result: replies[method] ?? .object([:]), error: nil)))
            }
        }
        func receive(_ frame: JSONRPCFrame) async { await onFrame(frame) }
        func reply(_ method: String, _ value: JSONValue) { replies[method] = value }
        func holdResponseWrites() { holdResponses = true }
        func releaseResponses() {
            holdResponses = false
            let waiting = responseWaiters
            responseWaiters.removeAll()
            for continuation in waiting { continuation.resume() }
        }
    }
    private final class Hub: @unchecked Sendable {
        let lock = NSLock()
        let capabilityError: Bool
        let requestBeforeReady: Bool
        init(capabilityError: Bool = false, requestBeforeReady: Bool = false) {
            self.capabilityError = capabilityError; self.requestBeforeReady = requestBeforeReady
        }
        private var stored: [Transport] = []
        func make(_ frame: @escaping WebSocketTransport.FrameHandler, _ state: @escaping WebSocketTransport.StateHandler) -> Transport {
            let transport = Transport(onFrame: frame, onState: state, capabilityError: capabilityError, requestBeforeReady: requestBeforeReady)
            lock.lock(); stored.append(transport); lock.unlock()
            return transport
        }
        var transports: [Transport] { lock.lock(); defer { lock.unlock() }; return stored }
    }
    private func client(capabilityError: Bool = false, requestBeforeReady: Bool = false) -> (HermesClient, Hub) {
        let hub = Hub(capabilityError: capabilityError, requestBeforeReady: requestBeforeReady)
        return (HermesClient(dialer: GatewayDialer(
            getStatus: { ServerStatus(json: .object(["version": .string("test"), "auth_required": .bool(false), "gateway_running": .bool(true)])) },
            webSocketURL: { _ in URL(string: "ws://example.invalid/ws")! }), handlesServerRequests: true,
            transportFactory: { hub.make($0, $1) }), hub)
    }
    private func emit(_ transport: Transport, id: JSONValue = .string("one"), method: String = "clarify", extra: [String: JSONValue] = [:]) async {
        await transport.receive(.serverRequest(id: id, method: method,
            params: .object(["session_id": .string("session"), "question": .string("Synthetic question")].merging(extra) { _, new in new })))
    }
    private func barrier(_ client: HermesClient) async throws { _ = try await client.request("ping") }

    func testClosedSocketCannotRepublishALateRequestBeforeReconnect() async throws {
        let (client, hub) = client()
        try await client.connect()
        let retiredTransport = hub.transports[0]
        await client.disconnect()
        await emit(retiredTransport, id: .string("late-after-close"), method: "approval")
        let open = await client.openServerRequests(sessionID: "session")
        XCTAssertTrue(open.isEmpty)
        let frames = await retiredTransport.sent
        XCTAssertTrue(frames.allSatisfy { $0["method"] != nil }, "Closing must never answer a late request")
    }

    func testRequestBeforeGatewayReadyStillArrivesDuringHandshake() async throws {
        let (client, _) = client(requestBeforeReady: true)
        try await client.connect()
        let open = await client.openServerRequests(sessionID: "session")
        XCTAssertEqual(open.map(\.identity.id), [.string("before-ready")])
        await client.disconnect()
    }

    func testLegacyApprovalSendsOptionalQueueIDOnlyWhenProvided() async throws {
        let (client, hub) = client(capabilityError: true)
        try await client.connect()
        let api = ApprovalAPI(client: client)
        _ = try await api.respond(sessionID: "session", choice: .once, legacyRequestID: "old-entry")
        _ = try await api.respond(sessionID: "session", choice: .deny)
        let frames = await hub.transports[0].sent.filter { $0["method"]?.stringValue == "approval.respond" }
        XCTAssertEqual(frames.count, 2)
        XCTAssertEqual(frames[0]["params"], .object(["session_id": .string("session"), "choice": .string("once"), "request_id": .string("old-entry")]))
        XCTAssertEqual(frames[1]["params"], .object(["session_id": .string("session"), "choice": .string("deny")]))
        await client.disconnect()
    }

    func testOldBackendCapabilityRejectionKeepsLegacyResponsesWorking() async throws {
        let (client, hub) = client(capabilityError: true)
        try await client.connect()
        _ = try await ApprovalAPI(client: client).respondSudo(requestID: "legacy-sudo", password: "synthetic")
        let methods = await client.serverRequestMethods
        XCTAssertTrue(methods.isEmpty)
        let sent = await hub.transports[0].sent
        XCTAssertTrue(sent.contains { $0["method"]?.stringValue == "sudo.respond" })
        let state = await client.state
        XCTAssertEqual(state, .open)
        await client.disconnect()
    }

    func testDelayedResponseCannotSucceedOrCrossOntoReplacementSocket() async throws {
        let (client, hub) = client()
        try await client.connect()
        let oldTransport = hub.transports[0]
        await emit(oldTransport)
        let requests = await client.openServerRequests(sessionID: "session")
        let request = try XCTUnwrap(requests.first)
        await oldTransport.holdResponseWrites()
        let response = Task { try await client.respond(to: request.identity, result: .object(["answer": .string("synthetic")])) }
        for _ in 0..<100 {
            if await oldTransport.responseIsWaiting { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let waiting = await oldTransport.responseIsWaiting
        XCTAssertTrue(waiting)
        await client.disconnect()
        try await client.connect()
        let replacement = hub.transports[1]
        await emit(replacement)
        await oldTransport.releaseResponses()
        do { try await response.value; XCTFail("A response whose generation retired cannot report success") }
        catch { }
        try await barrier(client)
        let frames = await replacement.sent
        XCTAssertTrue(frames.allSatisfy { $0["method"] != nil })
        let open = await client.openServerRequests(sessionID: "session")
        XCTAssertEqual(open.count, 1)
        await client.disconnect()
    }

    func testCurrentSingleBatchCancelAndMaskedValuesHaveExactResultSchemas() async throws {
        let (client, hub) = client()
        try await client.connect()
        let transport = hub.transports[0]
        let api = ApprovalAPI(client: client)
        for method in ["clarify", "sudo", "secret", "vault.unlock_prompt", "vault.code", "preview.read", "future.method"] {
            await emit(transport, id: .string(method), method: method)
            let open = await client.openServerRequests(sessionID: "session")
            let current = try XCTUnwrap(open.first)
            if method == "clarify" {
                _ = try await api.respondClarify(requestID: current.id.uuidString, answer: "synthetic", serverRequest: current.identity)
            } else if method == "sudo" {
                _ = try await api.respondSudo(requestID: current.id.uuidString, password: "synthetic", serverRequest: current.identity)
            } else {
                _ = try await api.respondSecret(requestID: current.id.uuidString, value: method == "preview.read" || method == "future.method" ? "" : "synthetic", serverRequest: current.identity)
            }
        }
        await emit(transport, id: .string("cancel-batch"), method: "clarify")
        let open = await client.openServerRequests(sessionID: "session")
        let batch = try XCTUnwrap(open.first)
        _ = try await api.respondClarify(requestID: batch.id.uuidString, answer: "", serverRequest: batch.identity, isBatch: true)
        let replies = await transport.sent.filter { $0["method"] == nil }
        XCTAssertEqual(replies.count, 8)
        XCTAssertEqual(replies.first?["result"], .object(["answer": .string("synthetic")]))
        for reply in replies.dropFirst().prefix(4) { XCTAssertEqual(reply["result"], .object(["value": .string("synthetic")])) }
        XCTAssertEqual(replies[5]["result"], .object(["value": .string("")]))
        XCTAssertEqual(replies[6]["error"]?["code"], .number(-32601))
        XCTAssertEqual(replies.last?["result"], .object([:]))
        await client.disconnect()
    }

    func testCapabilityOncePerConnectionAndObserverNeverAnswersAnyMethod() async throws {
        let (client, hub) = client()
        try await client.connect()
        let transport = hub.transports[0]
        for method in ["approval", "clarify", "sudo", "secret", "vault.unlock_prompt", "vault.code", "vault.save_login", "terminal.read", "preview.read", "preview.act", "window.read", "tour", "future.method"] {
            await emit(transport, id: .string(method), method: method)
        }
        try await barrier(client)
        let sent = await transport.sent
        XCTAssertEqual(sent.filter { $0["method"]?.stringValue == "client.capabilities" }.count, 1)
        XCTAssertTrue(sent.allSatisfy { $0["method"] != nil }, "No request may be answered just by observing it")
        let open = await client.openServerRequests(sessionID: "session")
        XCTAssertEqual(open.count, 13)
        await client.disconnect()
    }

    func testNewApprovalUsesExactTypedResponseAndLegacyStillUsesFIFO() async throws {
        let (client, hub) = client()
        try await client.connect()
        let transport = hub.transports[0]
        await emit(transport, id: .number(17), method: "approval")
        let currentRequests = await client.openServerRequests(sessionID: "session")
        let request = try XCTUnwrap(currentRequests.first)
        let api = ApprovalAPI(client: client)
        _ = try await api.respond(sessionID: "session", choice: .once, serverRequest: request.identity)
        _ = try await api.respond(sessionID: "legacy", choice: .deny)
        let sent = await transport.sent
        let response = try XCTUnwrap(sent.first { $0["method"] == nil })
        XCTAssertEqual(response["id"], .number(17))
        XCTAssertEqual(response["result"], .object(["choice": .string("once")]))
        let legacy = try XCTUnwrap(sent.first { $0["method"]?.stringValue == "approval.respond" })
        XCTAssertEqual(legacy["params"]?["session_id"], .string("legacy"))
        await client.disconnect()
    }

    func testReconnectRejectsOldDecisionAndIgnoresOldSocketCancel() async throws {
        let (client, hub) = client()
        try await client.connect()
        let oldTransport = hub.transports[0]
        await emit(oldTransport)
        let oldRequests = await client.openServerRequests(sessionID: "session")
        let old = try XCTUnwrap(oldRequests.first)
        await client.disconnect()
        try await client.connect()
        let newTransport = hub.transports[1]
        await emit(newTransport)
        do { try await client.respond(to: old.identity, result: .object(["answer": .string("stale")]))
            XCTFail("An old UI must not send onto a replacement socket")
        } catch { }
        await oldTransport.receive(.event(GatewayEvent(type: "request.cancel", sessionID: "session", payload: .object(["id": .string("one"), "method": .string("clarify"), "reason": .string("timeout")]), params: .null)))
        let open = await client.openServerRequests(sessionID: "session")
        XCTAssertEqual(open.count, 1)
        XCTAssertNotEqual(open.first?.identity.generation, old.identity.generation)
        try await barrier(client)
        let sent = await newTransport.sent
        XCTAssertTrue(sent.allSatisfy { $0["method"] != nil })
        await client.disconnect()
    }

    func testOpenBatchAcknowledgmentCarriesItsRevisionBeforeUIConsumesTheProjection() async throws {
        let (client, hub) = client()
        try await client.connect()
        let transport = hub.transports[0]
        await emit(transport, extra: ["answers": .object(["a": .string("A")])])
        let initialRequests = await client.openServerRequests(sessionID: "session")
        let initial = try XCTUnwrap(initialRequests.first)
        await transport.reply("clarify.lock", .object(["status": .string("ok"), "remaining": .array([.string("b")])]))
        let receipt = try await ApprovalAPI(client: client).respondClarify(
            requestID: initial.id.uuidString, answer: "B", questionID: "a", serverRequest: initial.identity)
        let acceptedRevision = try XCTUnwrap(receipt.sourceRevision)
        let acknowledgedRequests = await client.openServerRequests(sessionID: "session")
        let acknowledged = try XCTUnwrap(acknowledgedRequests.first)
        XCTAssertEqual(acknowledged.clarify?.sourceRevision, acceptedRevision)
        XCTAssertGreaterThan(acceptedRevision, initial.revision)
        XCTAssertEqual(acknowledged.clarify?.lockedAnswers, ["a": "B"])

        await transport.reply("session.events.since", .object(["session_id": .string("session"), "open_requests": .array([
            .object(["id": .string("one"), "method": .string("clarify"), "params": initial.params])])]))
        _ = try await client.request("session.events.since", params: .object(["session_id": .string("session")]))
        let revertedRequests = await client.openServerRequests(sessionID: "session")
        let reverted = try XCTUnwrap(revertedRequests.first)
        XCTAssertEqual(reverted.clarify?.lockedAnswers, ["a": "A"])
        XCTAssertGreaterThan(try XCTUnwrap(reverted.clarify?.sourceRevision), acceptedRevision)
        XCTAssertNotEqual(reverted.clarify, initial.clarify)
        await client.disconnect()
    }

    func testSnapshotsFromAllThreeOfficialMethodsAndBatchLockUseCurrentContract() async throws {
        let (client, hub) = client()
        try await client.connect()
        let transport = hub.transports[0]
        let snapshot: JSONValue = .object(["session_id": .string("session"), "open_requests": .array([
            .object(["id": .string("batch"), "method": .string("clarify"), "params": .object([
                "session_id": .string("session"), "questions": .array([.object(["qid": .string("a"), "question": .string("First")]), .object(["qid": .string("b"), "question": .string("Second")])]), "answers": .object(["a": .string("first")])])])])])
        for method in ["session.resume", "session.activate", "session.events.since"] {
            await transport.reply(method, snapshot)
            _ = try await client.request(method, params: .object(["session_id": .string("session")]))
        }
        let currentRequests = await client.openServerRequests(sessionID: "session")
        let request = try XCTUnwrap(currentRequests.first)
        XCTAssertEqual(request.clarify?.lockedAnswers, ["a": "first"])
        await transport.reply("clarify.lock", .object(["status": .string("ok"), "remaining": .array([])]))
        let result = try await ApprovalAPI(client: client).respondClarify(requestID: "not-the-wire-id", answer: "second", questionID: "b", serverRequest: request.identity)
        XCTAssertEqual(result.remaining, [])
        let sent = await transport.sent
        let lock = try XCTUnwrap(sent.first { $0["method"]?.stringValue == "clarify.lock" })
        XCTAssertEqual(lock["params"], .object(["request_id": .string("batch"), "question_id": .string("b"), "answer": .string("second")]))
        let open = await client.openServerRequests(sessionID: "session")
        XCTAssertTrue(open.isEmpty)
        await client.disconnect()
    }
}
