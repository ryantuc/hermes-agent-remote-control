import Foundation

/// Wire frames for the tui_gateway dialect: JSON-RPC 2.0, one newline-delimited JSON object per line in both directions, over WebSocket at `/api/ws`.
/// Three shapes exist: request (id + method), response (id + `result` or `error`), and event (method `"event"`, no id).
/// Server→client requests for approvals carry an id and a non-`"event"` method, and are surfaced as `.serverRequest`.
public enum JSONRPCFrame: Sendable {
    case response(JSONRPCResponse)
    case event(GatewayEvent)
    case serverRequest(id: JSONValue, method: String, params: JSONValue?)
    case unknown(JSONValue)
}

public struct JSONRPCResponse: Sendable {
    public let id: JSONValue
    public let result: JSONValue?
    public let error: JSONRPCError?
}

public struct JSONRPCError: Error, Sendable {
    public let code: Int
    public let message: String
    public let data: JSONValue?

    public init(code: Int, message: String, data: JSONValue? = nil) {
        self.code = code
        self.message = message
        self.data = data
    }
}

/// A gateway event; `params` carries `{"type", "session_id", "payload"}`.
/// `session_id` is present on every event (empty for global broadcasts) and `payload` is omitted entirely when it would be null.
public struct GatewayEvent: Sendable {
    public let type: String
    /// Session the event belongs to; empty for session-less broadcasts.
    public let sessionID: String
    /// `.null` when the server omitted the payload field.
    public let payload: JSONValue
    /// The full params object, for events that carry extra fields.
    public let params: JSONValue

    public init(type: String, sessionID: String, payload: JSONValue, params: JSONValue) {
        self.type = type
        self.sessionID = sessionID
        self.payload = payload
        self.params = params
    }
}

public enum JSONRPCCodec {
    /// Encode one client→server request as a single JSON line with no trailing newline, since WebSocket text messages are already delimited.
    public static func encodeRequest(id: String, method: String, params: JSONValue?) throws -> String {
        var obj: [String: JSONValue] = [
            "jsonrpc": .string("2.0"),
            "id": .string(id),
            "method": .string(method),
        ]
        if let params { obj["params"] = params }
        return try encodeLine(.object(obj))
    }

    /// Encode a client→server response, used to answer server-initiated requests such as approval prompts.
    public static func encodeResponse(id: JSONValue, result: JSONValue) throws -> String {
        let obj: JSONValue = .object([
            "jsonrpc": .string("2.0"),
            "id": id,
            "result": result,
        ])
        return try encodeLine(obj)
    }

    public static func encodeLine(_ value: JSONValue) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        let data = try encoder.encode(value)
        guard let s = String(data: data, encoding: .utf8) else {
            throw JSONRPCError(code: -32603, message: "encoding produced non-UTF8 data")
        }
        return s
    }

    /// Decode one inbound line into a frame; one WebSocket text message may hold several newline-separated frames because the server coalesces streamed token frames, so callers split with `decodeMessage` first.
    public static func decodeFrame(_ line: String) throws -> JSONRPCFrame {
        guard let data = line.data(using: .utf8) else {
            throw JSONRPCError(code: -32700, message: "non-UTF8 frame")
        }
        let value = try JSONDecoder().decode(JSONValue.self, from: data)
        guard case .object(let obj) = value else {
            throw JSONRPCError(code: -32700, message: "frame is not an object")
        }

        let id = obj["id"]
        let method = obj["method"]?.stringValue

        if let method {
            if method == "event", let params = obj["params"] {
                let type = params["type"]?.stringValue ?? "unknown"
                return .event(
                    GatewayEvent(
                        type: type,
                        sessionID: params["session_id"]?.stringValue ?? "",
                        payload: params["payload"] ?? .null,
                        params: params
                    ))
            }
            // Server-initiated request (carries an id and a method).
            if let id, !id.isNull {
                return .serverRequest(id: id, method: method, params: obj["params"])
            }
            // Notification with an unrecognized method.
            return .unknown(value)
        }

        if let id {
            var rpcError: JSONRPCError?
            if let err = obj["error"], case .object(let eo) = err {
                rpcError = JSONRPCError(
                    code: eo["code"]?.intValue ?? -32603,
                    message: eo["message"]?.stringValue ?? "unknown error",
                    data: eo["data"]
                )
            }
            return .response(JSONRPCResponse(id: id, result: obj["result"], error: rpcError))
        }

        return .unknown(value)
    }

    /// Split one WebSocket text message into frames; newline-delimited, blank lines ignored.
    public static func decodeMessage(_ text: String) -> [Result<JSONRPCFrame, Error>] {
        text.split(separator: "\n", omittingEmptySubsequences: true).map { line in
            Result { try decodeFrame(String(line)) }
        }
    }
}
