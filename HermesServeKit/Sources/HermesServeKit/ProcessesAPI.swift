import Foundation

/// One row of `process.list` (`ProcessEntry`, `tui_gateway/contracts/tools_commands.py:91-111`): a background process the agent started with `terminal(background=true)`, as `tools/process_registry.py::list_sessions` reports it plus the gateway's 4,000-char `output_tail` (`tui_gateway/server.py:3453-3468`).
public struct BackgroundProcess: Sendable, Equatable, Identifiable {
    /// The registry's process id, which the wire calls `session_id` and `process.kill` takes as `process_id`.
    public let id: String
    /// Capped at 200 chars by the registry.
    public let command: String
    public let cwd: String
    public let pid: Int?
    /// Host-local wall clock, `%Y-%m-%dT%H:%M:%S`, with no zone; display only.
    public let startedAt: String
    public let uptimeSeconds: Int?
    /// `running` | `exited` (`process_registry.py:2470`).
    public let status: String
    public let outputPreview: String
    public let outputTail: String
    public let exitCode: Int?
    /// Present only once the process has exited (`process_registry.py:2485-2488`).
    public let exitedAt: Date?
    public let completionReason: String
    public let detached: Bool
    public let sessionScoped: Bool

    public var isRunning: Bool { status != "exited" }

    public init(id: String, command: String, cwd: String = "", pid: Int? = nil, startedAt: String = "", uptimeSeconds: Int? = nil, status: String = "running", outputPreview: String = "", outputTail: String = "", exitCode: Int? = nil, exitedAt: Date? = nil, completionReason: String = "", detached: Bool = false, sessionScoped: Bool = false) {
        self.id = id
        self.command = command
        self.cwd = cwd
        self.pid = pid
        self.startedAt = startedAt
        self.uptimeSeconds = uptimeSeconds
        self.status = status
        self.outputPreview = outputPreview
        self.outputTail = outputTail
        self.exitCode = exitCode
        self.exitedAt = exitedAt
        self.completionReason = completionReason
        self.detached = detached
        self.sessionScoped = sessionScoped
    }

    /// Nil without an id, because a row that cannot be named cannot be stopped.
    public init?(json: JSONValue) {
        guard let id = json["session_id"]?.coercedString, !id.isEmpty else { return nil }
        self.id = id
        command = json["command"]?.text ?? ""
        cwd = json["cwd"]?.text ?? ""
        pid = json["pid"]?.coercedInt
        startedAt = json["started_at"]?.text ?? ""
        uptimeSeconds = json["uptime_seconds"]?.coercedInt
        status = json["status"]?.coercedString ?? "running"
        outputPreview = json["output_preview"]?.text ?? ""
        outputTail = json["output_tail"]?.text ?? ""
        exitCode = json["exit_code"]?.coercedInt
        exitedAt = json["exited_at"]?.coercedEpochDate
        completionReason = json["completion_reason"]?.text ?? ""
        detached = json["detached"]?.coercedBool ?? false
        sessionScoped = json["session_scoped"]?.coercedBool ?? false
    }

    /// How long it has run, from the registry's own clock; a finished process keeps the uptime it had when the list was read.
    public var uptime: TimeInterval? { uptimeSeconds.map(TimeInterval.init) }
}

/// `process.kill` result (`ProcessKillResult`, `tools_commands.py:135-145`): `status` is `killed` | `already_exited` | `not_found` | `error`, and `error` rides on the failure statuses.
public struct ProcessKillOutcome: Sendable, Equatable {
    public let status: String
    public let command: String
    public let exitCode: Int?
    public let completionReason: String
    public let output: String
    public let error: String

    public init(json: JSONValue) {
        status = json["status"]?.coercedString ?? ""
        command = json["command"]?.text ?? ""
        exitCode = json["exit_code"]?.coercedInt
        completionReason = json["completion_reason"]?.text ?? ""
        output = json["output"]?.text ?? ""
        error = json["error"]?.text ?? ""
    }

    public var wasKilled: Bool { status == "killed" }
    /// Either the process is gone now or it was already: nothing left to stop.
    public var isGone: Bool { status == "killed" || status == "already_exited" }

    /// One sentence for a person, never the status token.
    public var summary: String {
        switch status {
        case "killed": return "Stopped."
        case "already_exited": return "It had already finished."
        case "not_found": return "That process is no longer listed."
        default: return error.isEmpty ? "Could not stop it." : error
        }
    }
}

/// The agent's background processes for one live session: `process.list` and `process.kill` (`tui_gateway/methods_tools.py:281`, `:285`; contracts `tools_commands.py:86-149`). Both are scoped to the caller's session by `session_key`, so a process another session started is `not_found` here.
public struct ProcessesAPI: Sendable {
    private let client: HermesClient

    public init(client: HermesClient) {
        self.client = client
    }

    /// `process.list {session_id, profile?}`; rows without an id are dropped.
    public func list(sessionID: String, profile: String? = nil) async throws -> [BackgroundProcess] {
        var params: [String: JSONValue] = ["session_id": .string(sessionID)]
        if let profile, !profile.isEmpty { params["profile"] = .string(profile) }
        let result = try await client.request("process.list", params: .object(params))
        return (result["processes"]?.arrayValue ?? []).compactMap(BackgroundProcess.init(json:))
    }

    /// `process.kill {session_id, process_id, profile?}`.
    public func kill(sessionID: String, processID: String, profile: String? = nil) async throws -> ProcessKillOutcome {
        var params: [String: JSONValue] = [
            "session_id": .string(sessionID),
            "process_id": .string(processID),
        ]
        if let profile, !profile.isEmpty { params["profile"] = .string(profile) }
        let result = try await client.request("process.kill", params: .object(params))
        return ProcessKillOutcome(json: result)
    }
}
