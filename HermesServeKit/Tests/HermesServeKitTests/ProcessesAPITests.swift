import XCTest

@testable import HermesServeKit

/// `process.list` and `process.kill` against `tui_gateway/contracts/tools_commands.py:86-149`; the row shapes are `tools/process_registry.py::list_sessions` (`:2462-2488`) plus the gateway's `output_tail` (`tui_gateway/server.py:3466`).
final class ProcessesAPITests: XCTestCase {
    private let session = "rt-a1b2c3"

    static let runningRow: JSONValue = .object([
        "session_id": .string("proc_7f3a"),
        "command": .string("npm run dev"),
        "cwd": .string("/Users/you/app"),
        "pid": .number(48213),
        "owner_task_id": .string("task-1"),
        "started_at": .string("2026-10-09T16:40:12"),
        "uptime_seconds": .number(95),
        "status": .string("running"),
        "output_preview": .string("ready on http://localhost:5173"),
        "output_tail": .string("VITE ready\n  Local: http://localhost:5173/"),
    ])

    /// Exited rows carry three keys a running row never has (`process_registry.py:2485-2488`).
    static let exitedRow: JSONValue = .object([
        "session_id": .string("proc_0c91"),
        "command": .string("pytest -q"),
        "cwd": .string("/Users/you/app"),
        "pid": .number(48001),
        "owner_task_id": .string("task-1"),
        "started_at": .string("2026-10-09T16:38:02"),
        "uptime_seconds": .number(41),
        "status": .string("exited"),
        "output_preview": .string("12 passed in 38.90s"),
        "exit_code": .number(0),
        "exited_at": .number(1_759_999_999.2),
        "completion_reason": .string("exited"),
        "output_tail": .string("............\n12 passed in 38.90s"),
    ])

    func testListSendsOnlyTheSessionIDAndDecodesBothShapes() async throws {
        let (client, socket) = try await ScriptedGateway.connected(replies: [
            "process.list": [.object(["processes": .array([Self.runningRow, Self.exitedRow, .object(["command": .string("no id")])])])],
        ])

        let rows = try await ProcessesAPI(client: client).list(sessionID: session)

        let sent = await socket.sentParams("process.list")
        let params = try XCTUnwrap(sent)
        XCTAssertEqual(Set(params.objectValue?.keys.map { $0 } ?? []), ["session_id"], "`ProcessListParams` is session_id plus optional profile")
        XCTAssertEqual(params["session_id"]?.stringValue, session)

        XCTAssertEqual(rows.count, 2, "a row with no id cannot be stopped and is dropped")
        let running = rows[0]
        XCTAssertEqual(running.id, "proc_7f3a")
        XCTAssertEqual(running.command, "npm run dev")
        XCTAssertTrue(running.isRunning)
        XCTAssertEqual(running.pid, 48213)
        XCTAssertEqual(running.uptimeSeconds, 95)
        XCTAssertNil(running.exitedAt)
        XCTAssertNil(running.exitCode)
        XCTAssertEqual(running.outputTail, "VITE ready\n  Local: http://localhost:5173/")

        let exited = rows[1]
        XCTAssertFalse(exited.isRunning)
        XCTAssertEqual(exited.exitCode, 0)
        XCTAssertEqual(exited.exitedAt?.timeIntervalSince1970 ?? 0, 1_759_999_999.2, accuracy: 0.001)
        XCTAssertEqual(exited.completionReason, "exited")

        await client.disconnect()
    }

    func testKillSendsTheProcessIDUnderItsDeclaredName() async throws {
        let (client, socket) = try await ScriptedGateway.connected(replies: [
            "process.kill": [.object([
                "status": .string("killed"),
                "session_id": .string("proc_7f3a"),
                "command": .string("npm run dev"),
                "completion_reason": .string("killed"),
                "termination_source": .string("user"),
                "output": .string("VITE ready"),
            ])],
        ])

        let outcome = try await ProcessesAPI(client: client).kill(sessionID: session, processID: "proc_7f3a")

        let sent = await socket.sentParams("process.kill")
        let params = try XCTUnwrap(sent)
        XCTAssertEqual(Set(params.objectValue?.keys.map { $0 } ?? []), ["session_id", "process_id"], "`ProcessKillParams` is session_id, process_id, optional profile")
        XCTAssertEqual(params["process_id"]?.stringValue, "proc_7f3a")
        XCTAssertTrue(outcome.wasKilled)
        XCTAssertTrue(outcome.isGone)
        XCTAssertEqual(outcome.summary, "Stopped.")

        await client.disconnect()
    }

    func testTheFailureStatusesReadAsSentences() {
        XCTAssertEqual(ProcessKillOutcome(json: .object(["status": .string("already_exited"), "exit_code": .number(1)])).summary, "It had already finished.")
        XCTAssertTrue(ProcessKillOutcome(json: .object(["status": .string("already_exited")])).isGone)
        XCTAssertEqual(ProcessKillOutcome(json: .object(["status": .string("not_found"), "error": .string("No process with ID x")])).summary, "That process is no longer listed.")
        XCTAssertEqual(ProcessKillOutcome(json: .object(["status": .string("error"), "error": .string("Permission denied")])).summary, "Permission denied")
        XCTAssertFalse(ProcessKillOutcome(json: .object(["status": .string("error")])).isGone)
    }

    func testAProfileRidesOnBothCallsOnlyWhenGiven() async throws {
        let (client, socket) = try await ScriptedGateway.connected(replies: [
            "process.list": [.object(["processes": .array([])])],
            "process.kill": [.object(["status": .string("not_found")])],
        ])
        let api = ProcessesAPI(client: client)

        _ = try await api.list(sessionID: session, profile: "work")
        let listed = await socket.sentParams("process.list")
        XCTAssertEqual(listed?["profile"]?.stringValue, "work")
        _ = try await api.kill(sessionID: session, processID: "p", profile: nil)
        let killed = await socket.sentParams("process.kill")
        XCTAssertNil(killed?["profile"])

        await client.disconnect()
    }
}
