import XCTest

@testable import HermesServeKit

/// A deep cut is a replacement that removes more than the target's own user turn: an Edit or Retry of an earlier message. A backend that enforces the depth gate refuses it with 4033 unless `confirm_deep_truncate` rides along, and says in the error's data how many user turns the cut would remove (`tui_gateway/methods_prompt.py:513-531` at v0.22.5, where the gate is still switched off at `:453`). The key is declared from 0.21.7 on (`tui_gateway/contracts/prompt_voice.py:46`); an older backend answers it with 4000, so it is never sent up front. It goes out once, on a resend after a 4033, and only when the person agreed to remove at least as many turns as the refusal counts.
final class PromptDeepCutTests: XCTestCase {
    private let session = "a1b2c3d4"
    private let streaming = JSONValue.object(["status": .string("streaming")])

    private func deepCutRefusal(archivedUserTurns: Int?) -> JSONValue {
        var data: [String: JSONValue] = ["archived_messages": .number(4)]
        if let archivedUserTurns { data["archived_user_turns"] = .number(Double(archivedUserTurns)) }
        return ScriptedGateway.rpcError(
            code: 4033,
            message: "truncation would archive later user turns; resubmit with confirm_deep_truncate=true if this is intended",
            data: .object(data))
    }

    /// (a) The refusal names two turns, the person agreed to two: exactly one resend, carrying the flag and otherwise the same submit.
    func testAnAgreedDeepCutIsResentOnceWithTheConfirmation() async throws {
        let (client, socket) = try await ScriptedGateway.connected(replies: [
            "prompt.submit": [deepCutRefusal(archivedUserTurns: 2), streaming],
        ])

        let ack = try await PromptAPI(client: client).submit(
            sessionID: session, text: "edited", submissionRef: "ref-1", replacingRowID: 41, agreedUserTurns: 2)

        XCTAssertTrue(ack.isStreaming)
        let sent = await ScriptedGateway.allSentParams("prompt.submit", on: socket)
        XCTAssertEqual(sent.count, 2, "exactly one resend")
        XCTAssertNil(sent.first?["confirm_deep_truncate"], "the first attempt must not carry a key an older backend refuses")
        let resend = try XCTUnwrap(sent.last)
        XCTAssertEqual(resend["confirm_deep_truncate"]?.boolValue, true)
        XCTAssertEqual(resend["session_id"]?.stringValue, session)
        XCTAssertEqual(resend["submission_ref"]?.stringValue, "ref-1", "the resend is the same submission")
        XCTAssertEqual(resend["truncate_before_row_id"]?.intValue, 41)
        XCTAssertEqual(resend["confirm_truncate"]?.boolValue, true)
        XCTAssertEqual(resend["confirm_empty_truncate"]?.boolValue, true)
        XCTAssertEqual(resend["text"]?.stringValue, "edited")

        await client.disconnect()
    }

    /// (b) A backend that never enforces the gate, which is every released one so far, never sees the key: not on success, and not after any other refusal.
    func testABackendThatNeverRefusesTheCutNeverSeesTheKey() async throws {
        let (client, socket) = try await ScriptedGateway.connected(replies: [
            "prompt.submit": [
                streaming,
                ScriptedGateway.rpcError(code: 4000, message: "invalid params"),
                ScriptedGateway.rpcError(code: 4018, message: "target row_id 41 is no longer in session history"),
            ],
        ])
        let api = PromptAPI(client: client)

        _ = try await api.submit(sessionID: session, text: "edited", replacingRowID: 41, agreedUserTurns: 2)
        for expected in [4000, 4018] {
            do {
                _ = try await api.submit(sessionID: session, text: "edited", replacingRowID: 41, agreedUserTurns: 2)
                XCTFail("a \(expected) must be thrown")
            } catch let HermesError.rpc(code, _, _) {
                XCTAssertEqual(code, expected)
            }
        }

        let sent = await ScriptedGateway.allSentParams("prompt.submit", on: socket)
        XCTAssertEqual(sent.count, 3, "no refusal but 4033 earns a resend")
        for params in sent {
            XCTAssertNil(params["confirm_deep_truncate"])
        }

        await client.disconnect()
    }

    /// (c) A second 4033 is thrown, not answered with a third submit.
    func testASecondRefusalIsThrownNotLooped() async throws {
        let (client, socket) = try await ScriptedGateway.connected(replies: [
            "prompt.submit": [deepCutRefusal(archivedUserTurns: 2), deepCutRefusal(archivedUserTurns: 2), streaming],
        ])

        do {
            _ = try await PromptAPI(client: client).submit(
                sessionID: session, text: "edited", replacingRowID: 41, agreedUserTurns: 2)
            XCTFail("the second refusal must be thrown")
        } catch let HermesError.rpc(code, _, _) {
            XCTAssertEqual(code, 4033)
        }

        let sent = await ScriptedGateway.allSentParams("prompt.submit", on: socket)
        XCTAssertEqual(sent.count, 2, "one resend, then the refusal is the answer")
        XCTAssertEqual(sent.last?["confirm_deep_truncate"]?.boolValue, true)

        await client.disconnect()
    }

    /// Stop or Cancel cancels the send's task while the first submit still waits for its answer, which the request does not abandon. A refusal that arrives after that must not become a new, confirmed cut the person already cancelled.
    func testACancelledSubmitIsNeverResent() async throws {
        let (client, socket) = try await ScriptedGateway.connected(replies: [
            "prompt.submit": [deepCutRefusal(archivedUserTurns: 2), streaming],
        ])
        let api = PromptAPI(client: client)
        let session = self.session

        let cancelled = Task { () async throws -> PromptAck in
            withUnsafeCurrentTask { $0?.cancel() }
            return try await api.submit(sessionID: session, text: "edited", replacingRowID: 41, agreedUserTurns: 2)
        }
        do {
            _ = try await cancelled.value
            XCTFail("a cancelled submit must not be resent into a success")
        } catch let HermesError.rpc(code, _, _) {
            XCTAssertEqual(code, 4033)
        }

        let count = await socket.sentCount("prompt.submit")
        XCTAssertEqual(count, 1, "nothing may be sent after the cancel")

        await client.disconnect()
    }

    /// The person agreed to the turns they could see. A refusal that counts more means the cut would remove turns they never saw, so it is thrown without a resend.
    func testARefusalCountingMoreTurnsThanAgreedIsThrownWithoutAResend() async throws {
        let (client, socket) = try await ScriptedGateway.connected(replies: [
            "prompt.submit": [deepCutRefusal(archivedUserTurns: 3), streaming],
        ])

        do {
            _ = try await PromptAPI(client: client).submit(
                sessionID: session, text: "edited", replacingRowID: 41, agreedUserTurns: 2)
            XCTFail("a cut deeper than agreed must be thrown")
        } catch let HermesError.rpc(code, _, _) {
            XCTAssertEqual(code, 4033)
        }

        let count = await socket.sentCount("prompt.submit")
        XCTAssertEqual(count, 1)

        await client.disconnect()
    }

    /// Nothing agreed (a Retry), or a refusal that does not say how deep the cut goes: thrown without a resend.
    func testWithoutAnAgreementOrACountTheRefusalIsThrown() async throws {
        let (client, socket) = try await ScriptedGateway.connected(replies: [
            "prompt.submit": [deepCutRefusal(archivedUserTurns: 2), deepCutRefusal(archivedUserTurns: nil), streaming],
        ])
        let api = PromptAPI(client: client)

        for agreed in [nil, 5] as [Int?] {
            do {
                _ = try await api.submit(sessionID: session, text: "again", replacingRowID: 41, agreedUserTurns: agreed)
                XCTFail("the refusal must be thrown")
            } catch let HermesError.rpc(code, _, _) {
                XCTAssertEqual(code, 4033)
            }
        }

        let sent = await ScriptedGateway.allSentParams("prompt.submit", on: socket)
        XCTAssertEqual(sent.count, 2, "neither refusal earns a resend")
        for params in sent {
            XCTAssertNil(params["confirm_deep_truncate"])
        }

        await client.disconnect()
    }
}
