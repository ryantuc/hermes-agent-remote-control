import Foundation
import Network
import XCTest
@testable import HermesServeKit
@testable import HermesMobile

@MainActor
final class ChatCheckpointLifecycleTests: XCTestCase {
    func testAcceptedMidTurnCorrectionKeepsSavingObservedActivity() async throws {
        for status in ["steered", "redirected"] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: root) }
            let store = LiveTranscriptStore(root: root)
            let h = await AppHarness.make()
            try await h.openSocket()
            let chat = h.chat(storedID: "stored")
            chat.transcriptStore = store
            await chat.open()
            chat.applyTranscript(TranscriptPage(sessionID: "stored", messages: []))
            let sid = try XCTUnwrap(chat.runtimeSessionID)
            let key = try XCTUnwrap(chat.checkpointKey)
            h.app.engine.setReplayEpoch("epoch")
            paint(h.app, sid: sid, type: "message.start", text: "", seq: 1)
            let savedBefore = await waitUntil { await store.load(key: key)?.turn.sequence == 1 }
            XCTAssertTrue(savedBefore, "normal publication must save before sending a correction")
            await h.backend.stub("prompt.submit") { _ in .object(["status": .string(status)]) }
            chat.draft = "Check the second source"
            chat.sendTapped()
            let acked = await waitUntil { !chat.isSending && chat.outbound.isEmpty }
            XCTAssertTrue(acked)
            XCTAssertEqual(chat.sendPhase, .queued, "existing acknowledgment presentation stays intact")
            paint(h.app, sid: sid, type: "reasoning.delta", text: "After correction", seq: 2)
            let advanced = await waitUntil(timeout: 2) {
                return await store.load(key: key)?.turn.sequence == 2
            }
            XCTAssertTrue(advanced, "an accepted \(status) update must not freeze the disk replay cursor")
            let savedAfter = await store.load(key: key)
            XCTAssertTrue(savedAfter?.turn.entries.contains { $0.reasoning.contains("After correction") } == true)
            await h.tearDown()
        }
    }

    func testFallbackDoesNotPromotePartialHistoryToTrustedCheckpoint() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LiveTranscriptStore(root: root)
        let h = await AppHarness.make()
        try await h.openSocket()
        h.app.engine.setReplayEpoch("epoch")
        await h.backend.stub("session.resume") { _ in .object([
            "session_id": .string("runtime"), "session_key": .string("stored"), "running": .bool(true),
            "info": .object([:]), "inflight": .object(["user": .string("Question"),
                "assistant": .string("Earlier cumulative text"), "streaming": .bool(true)])]) }
        let chat = h.chat(storedID: "stored")
        chat.transcriptStore = store
        await chat.open()
        let key = try XCTUnwrap(chat.checkpointKey)
        paint(h.app, sid: "runtime", type: "reasoning.delta", text: "Only the new reasoning", seq: 50)
        let promoted = await waitUntil(timeout: 0.2) { await store.load(key: key) != nil }
        XCTAssertFalse(promoted, "a recoverable suffix does not make missing earlier tools/thinking complete")
        await h.tearDown()
    }

    func testFailedIdleHistoryLoadStaysIncompleteWhenANewTurnStarts() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LiveTranscriptStore(root: root)
        let h = await AppHarness.make()
        try await h.openSocket()
        let chat = h.chat(storedID: "stored")
        chat.transcriptStore = store
        await chat.open() // Harness REST fails; the default resume is idle.
        let sid = try XCTUnwrap(chat.runtimeSessionID)
        let key = try XCTUnwrap(chat.checkpointKey)
        h.app.engine.setReplayEpoch("epoch")
        paint(h.app, sid: sid, type: "message.start", text: "", seq: 1)
        let promoted = await waitUntil(timeout: 0.2) { await store.load(key: key) != nil }
        XCTAssertFalse(promoted, "a new turn must not certify missing older durable history")
        await h.tearDown()
    }

    func testLegacyUnverifiedCoverageRecordIsNotLoaded() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LiveTranscriptStore(root: root)
        let engine = TurnEngine()
        engine.setReplayEpoch("epoch")
        engine.apply(GatewayEvent(type: "message.start", sessionID: "runtime", payload: .object([:]),
            params: .object(["seq": .number(1)])))
        let checkpoint = try XCTUnwrap(engine.checkpoint(sessionID: "runtime"))
        let record = LiveTranscriptStore.Record(savedAt: Date(), history: [], ordinals: [:], turn: checkpoint)
        await store.save(record, key: "backend\u{0}stored", at: Date())
        let files = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        let file = try XCTUnwrap(files.first)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        json.removeValue(forKey: "coverageVersion")
        try JSONSerialization.data(withJSONObject: json).write(to: file, options: .atomic)
        let loaded = await store.load(key: "backend\u{0}stored")
        XCTAssertNil(loaded, "records written before coverage attestation did not attest baseline coverage")
    }
    func testNormallySavedCorrectionCheckpointRestoresIntoAFreshApp() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LiveTranscriptStore(root: root)
        let first = await AppHarness.make()
        try await first.openSocket()
        let profile = try XCTUnwrap(first.app.activeProfile)
        let chat = first.chat(storedID: "stored")
        chat.transcriptStore = store
        await chat.open()
        chat.applyTranscript(TranscriptPage(sessionID: "stored", messages: [
            TranscriptMessage(json: .object(["id": .number(1), "role": .string("user"), "content": .string("Earlier question")])),
            TranscriptMessage(json: .object(["id": .number(2), "role": .string("assistant"), "content": .string("Earlier answer")]))]))
        let sid = try XCTUnwrap(chat.runtimeSessionID)
        let key = try XCTUnwrap(chat.checkpointKey)
        first.app.engine.setReplayEpoch("epoch")
        paint(first.app, sid: sid, type: "message.start", text: "", seq: 1)
        paint(first.app, sid: sid, type: "tool.start", payload: .object([
            "tool_id": .string("read-before-quit"), "name": .string("read_file"), "context": .string("notes.md")]), seq: 2)
        let toolDone: JSONValue = .object(["tool_id": .string("read-before-quit"),
            "name": .string("read_file"), "result": .string("Fixture notes"), "duration_s": .number(0.1)])
        paint(first.app, sid: sid, type: "tool.complete", payload: toolDone, seq: 3)
        await first.backend.stub("prompt.submit") { _ in .object(["status": .string("redirected")]) }
        chat.draft = "Accepted correction"
        chat.sendTapped()
        let settled = await waitUntil { !chat.isSending && chat.outbound.isEmpty }
        XCTAssertTrue(settled)
        paint(first.app, sid: sid, type: "reasoning.delta", text: "Reasoning after correction", seq: 4)
        let saved = await waitUntil(timeout: 2) {
            return await store.load(key: key)?.turn.sequence == 4
        }
        XCTAssertTrue(saved)
        let expected = chat.entries
        XCTAssertEqual(expected.compactMap(\.tool).map(\.id), ["read-before-quit"])
        // No store.save in this test: only the shipped publication and send paths wrote it.
        let second = await AppHarness.make()
        second.app.profiles = [profile]
        await second.app.activate(profileID: profile.id, connect: false)
        try await second.openSocket()
        second.app.engine.setReplayEpoch("epoch")
        await second.backend.stub("session.resume") { _ in .object([
            "session_id": .string(sid), "session_key": .string("stored"), "running": .bool(true),
            "info": .object([:]), "inflight": .object(["assistant": .string("Stale cumulative snapshot"), "streaming": .bool(true)])]) }
        await second.backend.stub("session.events.since") { _ in .object([
            "epoch": .string("epoch"), "truncated": .bool(false), "latest_seq": .number(4), "events": .array([
                .object(["type": .string("tool.complete"), "session_id": .string(sid), "seq": .number(3), "payload": toolDone]),
                .object(["type": .string("reasoning.delta"), "session_id": .string(sid), "seq": .number(4),
                    "payload": .object(["text": .string("Reasoning after correction")])])])]) }
        let restored = second.chat(storedID: "stored")
        restored.transcriptStore = store
        await restored.open()
        XCTAssertEqual(restored.entries.map(\.id), expected.map(\.id))
        XCTAssertEqual(restored.entries.map(\.text), expected.map(\.text))
        XCTAssertEqual(restored.entries.map(\.reasoning), expected.map(\.reasoning))
        XCTAssertEqual(restored.entries.compactMap(\.tool).map(\.id), ["read-before-quit"])
        XCTAssertFalse(try XCTUnwrap(restored.entries.compactMap(\.tool).first).isRunning)
        XCTAssertNil(restored.historyRecoveryNotice)
        let submits = await second.backend.callCount("prompt.submit")
        XCTAssertEqual(submits, 0)
        paint(second.app, sid: sid, type: "reasoning.delta", text: " Still connected", seq: 5)
        let advanced = await waitUntil(timeout: 2) {
            return await store.load(key: key)?.turn.sequence == 5
        }
        XCTAssertTrue(advanced, "a verified restore must continue saving despite final-history reconciliation")
        let http = try CheckpointTranscriptHTTPFixture(json: ["session_id": "stored", "messages": [
            ["id": 1, "role": "user", "content": "Earlier question"],
            ["id": 2, "role": "assistant", "content": "Earlier answer"],
            ["id": 3, "role": "user", "content": "Accepted correction"],
            ["id": 4, "role": "assistant", "content": "Durable final answer"]]])
        let endpoint = try await http.start()
        defer { http.stop() }
        // Route the existing real REST transport to the fixture for completion reconciliation.
        await second.app.auth?.updateConfiguration(BackendConfiguration(baseURL: endpoint, authMode: .none))
        paint(second.app, sid: sid, type: "message.complete", text: "Live final before reconciliation", seq: 6)
        let reconciled = await waitUntil(timeout: 3) {
            restored.history.last?.text == "Durable final answer"
        }
        XCTAssertTrue(reconciled, "completion must install the actual successful HTTP transcript")
        XCTAssertEqual(restored.entries.last?.text, "Durable final answer")
        XCTAssertNil(restored.historyRecoveryNotice)
        XCTAssertTrue(http.requestLines.contains { $0.hasPrefix("GET /api/sessions/stored/messages") })
        await second.tearDown()
        await first.tearDown()
    }
    func testDeferredSaveCannotCrossBackendSwitch() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LiveTranscriptStore(root: root)
        let h = await AppHarness.make()
        try await h.openSocket()
        let oldChat = h.chat(storedID: "stored")
        oldChat.transcriptStore = store
        await oldChat.open()
        oldChat.applyTranscript(TranscriptPage(sessionID: "stored", messages: []))
        let sid = try XCTUnwrap(oldChat.runtimeSessionID)
        let oldKey = try XCTUnwrap(oldChat.checkpointKey)
        h.app.engine.setReplayEpoch("epoch")
        paint(h.app, sid: sid, type: "message.start", text: "", seq: 1)
        let saved = await waitUntil { await store.load(key: oldKey)?.turn.sequence == 1 }
        XCTAssertTrue(saved)
        // Arm the trailing write, then discard this ChatModel through the real profile switch.
        paint(h.app, sid: sid, type: "reasoning.delta", text: "Old backend suffix", seq: 2)
        let other = BackendProfile(name: "Other", baseURLString: AppHarness.deadRESTHost, authMode: .sessionToken)
        h.app.profiles.append(other)
        await h.app.activate(profileID: other.id, connect: false)
        XCTAssertFalse(h.app.containsChat(oldChat))
        let foreignKey = try XCTUnwrap(oldChat.checkpointKey)
        XCTAssertNotEqual(oldKey, foreignKey)
        // Same runtime string on a different backend cannot authorize the retained object's write.
        h.app.engine.setReplayEpoch("other-epoch")
        paint(h.app, sid: sid, type: "message.start", text: "", seq: 8)
        oldChat.saveLiveCheckpoint(force: true)
        let leaked = await waitUntil(timeout: 0.8) { await store.load(key: foreignKey) != nil }
        XCTAssertFalse(leaked)
        let original = await store.load(key: oldKey)
        XCTAssertEqual(original?.turn.epoch, "epoch")
        await h.tearDown()
    }

    private func paint(_ app: AppModel, sid: String, type: String, text: String, seq: Int) {
        paint(app, sid: sid, type: type, payload: .object(["text": .string(text)]), seq: seq)
    }

    private func paint(_ app: AppModel, sid: String, type: String, payload: JSONValue, seq: Int) {
        app.engine.apply(GatewayEvent(type: type, sessionID: sid, payload: payload,
            params: .object(["type": .string(type), "session_id": .string(sid),
                             "seq": .number(Double(seq)), "payload": payload])))
        app.engine.flush()
        app.publish(sessionID: sid)
    }
}
/// Real loopback HTTP for the completion-reconciliation leg; no production transport is mocked.
private final class CheckpointTranscriptHTTPFixture: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "checkpoint-http-fixture")
    private let body: Data
    private var lines: [String] = []
    var requestLines: [String] { queue.sync { lines } }

    init(json: [String: Any]) throws {
        body = try JSONSerialization.data(withJSONObject: json)
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
    }

    func start() async throws -> URL {
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { connection.cancel(); return }
            connection.start(queue: self.queue)
            self.receive(connection, accumulated: Data())
        }
        return try await withCheckedThrowingContinuation { continuation in
            listener.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    self.listener.stateUpdateHandler = nil
                    guard let port = self.listener.port,
                          let url = URL(string: "http://127.0.0.1:\(port.rawValue)") else {
                        continuation.resume(throwing: URLError(.badURL)); return
                    }
                    continuation.resume(returning: url)
                case .failed(let error):
                    self.listener.stateUpdateHandler = nil
                    continuation.resume(throwing: error)
                default: break
                }
            }
            listener.start(queue: queue)
        }
    }

    private func receive(_ connection: NWConnection, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, complete, error in
            guard let self else { connection.cancel(); return }
            let combined = accumulated + (data ?? Data())
            guard combined.count <= 65_536, error == nil else { connection.cancel(); return }
            guard let header = String(data: combined, encoding: .utf8), header.contains("\r\n\r\n") else {
                if complete { connection.cancel() }
                else { self.receive(connection, accumulated: combined) }
                return
            }
            self.lines.append(header.components(separatedBy: "\r\n").first ?? "")
            let head = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: \(self.body.count)\r\nConnection: close\r\n\r\n"
            connection.send(content: Data(head.utf8) + self.body, completion: .contentProcessed { _ in connection.cancel() })
        }
    }

    func stop() { listener.cancel() }
}
