import XCTest

@testable import HermesServeKit

/// The card's answers. Current contract: `ConnectionRespondParams` = `owner` + `op_id` + `result` (+ inherited `profile`), `tui_gateway/contracts/connectors_operation.py:186-238`; `owner` is `{type: "session", session_id}` (`contracts/common.py:240-249`). An older backend declares `session_id` instead of `owner`, so `owner` answers 4000 there before any handler runs (`tui_gateway/rpc_dispatch.py:27-31` → `contracts/registry.py:100-115` on an older backend).
final class ConnectorsAPITests: XCTestCase {
    private let session = "a1b2c3d4"

    private static func undeclared(_ key: String, method: String = "connection.respond") -> String {
        "invalid params for \(method): \(key): Extra inputs are not permitted — the client and the "
            + "Hermes backend are out of sync (different versions); run `hermes update` and restart both"
    }

    func testSkipSendsOnlyTheDeclaredShape() async throws {
        let (client, socket) = try await ScriptedGateway.connected(replies: [
            "connection.respond": [.object(["status": .string("ok"), "settled": .bool(false)])],
        ])

        let answer = try await ConnectorsAPI(client: client).skip(sessionID: session, opID: "op-1", targets: ["github"])

        XCTAssertFalse(answer.settled)
        let sent = await socket.sentParams("connection.respond")
        let params = try XCTUnwrap(sent, "the skip never reached the backend")
        XCTAssertEqual(Set(params.objectValue?.keys.map { $0 } ?? []), ["owner", "op_id", "result"],
                       "connection.respond may carry only its declared params")
        XCTAssertEqual(params["owner"]?["type"]?.stringValue, "session")
        XCTAssertEqual(params["owner"]?["session_id"]?.stringValue, session)
        XCTAssertEqual(params["op_id"]?.stringValue, "op-1")
        let rows = try XCTUnwrap(params["result"]?["targets"]?.arrayValue)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?["name"]?.stringValue, "github")
        XCTAssertEqual(rows.first?["status"]?.stringValue, "skipped", "`ConnectionAnswerStatus` is approved | skipped")
        XCTAssertNil(params["result"]?["settled_by"])

        await client.disconnect()
    }

    func testContinueEndsTheOperation() async throws {
        let (client, socket) = try await ScriptedGateway.connected(replies: [
            "connection.respond": [.object(["status": .string("ok"), "settled": .bool(true)])],
        ])

        let answer = try await ConnectorsAPI(client: client).continueOperation(sessionID: session, opID: "op-1")

        XCTAssertTrue(answer.settled)
        let sent = await socket.sentParams("connection.respond")
        let params = try XCTUnwrap(sent)
        XCTAssertEqual(params["result"]?["settled_by"]?.stringValue, "continue")
        XCTAssertEqual(params["result"]?["targets"]?.arrayValue?.count ?? 0, 0)

        await client.disconnect()
    }

    /// An older backend rejects `owner` at dispatch, so nothing moved; the same answer goes once more in that backend's own shape.
    func testAnOlderBackendIsAnsweredWithSessionID() async throws {
        let (client, socket) = try await ScriptedGateway.connected(replies: [
            "connection.respond": [
                ScriptedGateway.rpcError(code: 4000, message: Self.undeclared("owner")),
                .object(["status": .string("ok"), "settled": .bool(true)]),
            ],
        ])

        let answer = try await ConnectorsAPI(client: client).continueOperation(sessionID: session, opID: "op-1")

        XCTAssertTrue(answer.settled)
        let sends = await socket.sentCount("connection.respond")
        XCTAssertEqual(sends, 2, "exactly one retry")
        let sent = await socket.sentParams("connection.respond")
        let retry = try XCTUnwrap(sent)
        XCTAssertNil(retry["owner"])
        XCTAssertEqual(retry["session_id"]?.stringValue, session)
        XCTAssertEqual(retry["op_id"]?.stringValue, "op-1")
        XCTAssertEqual(retry["result"]?["settled_by"]?.stringValue, "continue")

        await client.disconnect()
    }

    func testAnyOtherRejectionReachesTheCaller() async throws {
        let (client, socket) = try await ScriptedGateway.connected(replies: [
            "connection.respond": [
                ScriptedGateway.rpcError(code: 4004, message: "No open operation with that op_id."),
                .object(["status": .string("ok"), "settled": .bool(true)]),
            ],
        ])

        do {
            _ = try await ConnectorsAPI(client: client).skip(sessionID: session, opID: "op-1", targets: ["github"])
            XCTFail("a refusal was swallowed")
        } catch let HermesError.rpc(code, _, _) {
            XCTAssertEqual(code, 4004)
        }
        let sends = await socket.sentCount("connection.respond")
        XCTAssertEqual(sends, 1)

        await client.disconnect()
    }

    /// `connectors.operation.wake` (`connectors_operation.py:195-200`) only shortens the wait; an older backend has no such method and answers -32601.
    func testWakeSendsTheOwnerAndIsBestEffort() async throws {
        let (client, socket) = try await ScriptedGateway.connected(replies: [
            "connectors.operation.wake": [
                .object(["status": .string("ok")]),
                ScriptedGateway.rpcError(code: -32601, message: "unknown method: connectors.operation.wake"),
            ],
        ])
        let api = ConnectorsAPI(client: client)

        let woke = await api.wake(sessionID: session, opID: "op-1")
        XCTAssertTrue(woke)
        let sent = await socket.sentParams("connectors.operation.wake")
        let params = try XCTUnwrap(sent)
        XCTAssertEqual(Set(params.objectValue?.keys.map { $0 } ?? []), ["owner", "op_id"])
        XCTAssertEqual(params["owner"]?["session_id"]?.stringValue, session)

        let oldBackend = await api.wake(sessionID: session, opID: "op-1")
        XCTAssertFalse(oldBackend, "an absent method is a no-op, never an error on the card")

        await client.disconnect()
    }
}
