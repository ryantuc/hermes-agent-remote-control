import Foundation

/// A dynamic JSON value.
/// The gateway carries free-form payloads whose shapes vary by tool and version, so the transport decodes into `JSONValue` and typed wrappers project out the fields they understand; unknown fields survive round-trips.
public enum JSONValue: Sendable, Equatable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])
}

extension JSONValue: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let b = try? container.decode(Bool.self) {
            self = .bool(b)
        } else if let n = try? container.decode(Double.self) {
            self = .number(n)
        } else if let s = try? container.decode(String.self) {
            self = .string(s)
        } else if let a = try? container.decode([JSONValue].self) {
            self = .array(a)
        } else if let o = try? container.decode([String: JSONValue].self) {
            self = .object(o)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container, debugDescription: "Unsupported JSON value")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let b): try container.encode(b)
        case .number(let n): try container.encode(n)
        case .string(let s): try container.encode(s)
        case .array(let a): try container.encode(a)
        case .object(let o): try container.encode(o)
        }
    }
}

// MARK: - Ergonomic accessors

extension JSONValue {
    public subscript(key: String) -> JSONValue? {
        if case .object(let o) = self { return o[key] }
        return nil
    }

    public subscript(index: Int) -> JSONValue? {
        if case .array(let a) = self, a.indices.contains(index) { return a[index] }
        return nil
    }

    public var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }

    public var boolValue: Bool? {
        if case .bool(let b) = self { return b }
        return nil
    }

    public var doubleValue: Double? {
        if case .number(let n) = self { return n }
        return nil
    }

    /// Int value for a whole `.number`.
    /// BUG-112: `Int(exactly:)` rather than `Int(_:)`, which traps on a finite double outside Int64's range such as `1e30`; an unreadable wire number degrades to nil instead.
    public var intValue: Int? {
        if case .number(let n) = self, n.truncatingRemainder(dividingBy: 1) == 0 {
            return Int(exactly: n)
        }
        return nil
    }

    public var arrayValue: [JSONValue]? {
        if case .array(let a) = self { return a }
        return nil
    }

    public var objectValue: [String: JSONValue]? {
        if case .object(let o) = self { return o }
        return nil
    }

    public var isNull: Bool {
        if case .null = self { return true }
        return false
    }
}

// MARK: - Lenient coercion
//
// The gateway is deliberately loose about scalar types: bools arrive as SQLite 0/1 ints on some routes and real bools on others (rest-api-and-auth.md §6.1), event `text` is not guaranteed to be a string (reference-clients.md §3.2), and numbers arrive as int or float.
extension JSONValue {
    /// String value, coercing numbers and bools. `null` → nil.
    public var coercedString: String? {
        switch self {
        case .string(let s): return s
        case .number(let n):
            if n.truncatingRemainder(dividingBy: 1) == 0, abs(n) < 1e15 { return String(Int(n)) }
            return String(n)
        case .bool(let b): return b ? "true" : "false"
        case .null, .array, .object: return nil
        }
    }

    /// String value or `""` — the `coerceGatewayText` equivalent.
    public var text: String { coercedString ?? "" }

    /// Bool value, accepting `0`/`1` ints and `"true"`/`"false"` strings.
    public var coercedBool: Bool? {
        switch self {
        case .bool(let b): return b
        case .number(let n): return n != 0
        case .string(let s):
            switch s.lowercased() {
            case "true", "1", "yes": return true
            case "false", "0", "no": return false
            default: return nil
            }
        case .null, .array, .object: return nil
        }
    }

    /// Double value, accepting numeric strings.
    public var coercedDouble: Double? {
        switch self {
        case .number(let n): return n
        case .string(let s): return Double(s)
        case .bool(let b): return b ? 1 : 0
        case .null, .array, .object: return nil
        }
    }

    /// Epoch-seconds wire timestamp -> `Date`.
    /// Nil for `null`, for anything the numeric coercion cannot read, and for the non-positive values the backend uses as "never"; there is no `Codable` on this wire, so an unreadable key degrades rather than failing the surrounding decode.
    public var coercedEpochDate: Date? {
        guard let seconds = coercedDouble, seconds.isFinite, seconds > 0 else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }

    /// Int value, accepting numeric strings and truncating floats.
    /// BUG-112: the magnitude gate is load-bearing because `isFinite` excludes only NaN and the infinities while `Int(_:)` traps on any finite double outside Int64's range.
    /// Truncation toward zero is preserved by applying `Int(exactly:)` to the already truncated value, not to the raw double.
    public var coercedInt: Int? {
        guard let d = coercedDouble, d.isFinite else { return nil }
        return Int(exactly: d.rounded(.towardZero))
    }

    /// Compact single-line JSON for tool-argument previews and the diagnostics dump; pass the result through `Redaction` before anything security-sensitive.
    public var compactJSONString: String {
        (try? JSONRPCCodec.encodeLine(self)) ?? ""
    }

    /// Pretty-printed JSON for the diagnostics view.
    public var prettyJSONString: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(self),
              let s = String(data: data, encoding: .utf8)
        else { return compactJSONString }
        return s
    }
}

// MARK: - Literal conveniences (fixtures, tests, request params)

extension JSONValue: ExpressibleByNilLiteral, ExpressibleByBooleanLiteral,
    ExpressibleByIntegerLiteral, ExpressibleByFloatLiteral, ExpressibleByStringLiteral,
    ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral
{
    public init(nilLiteral: ()) { self = .null }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(integerLiteral value: Int) { self = .number(Double(value)) }
    public init(floatLiteral value: Double) { self = .number(value) }
    public init(stringLiteral value: String) { self = .string(value) }
    public init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
    public init(dictionaryLiteral elements: (String, JSONValue)...) {
        self = .object(Dictionary(uniqueKeysWithValues: elements))
    }
}
