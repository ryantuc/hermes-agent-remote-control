import Foundation

/// Dotted-path navigation over the nested document `GET /api/config` returns and the partial-document builder `PUT /api/config`'s deep-merge wants; the schema speaks flat dotted paths while the document is nested, and this is the only place that translation lives.
public enum ConfigDocument {
    /// The value at `path`, or nil when any component is missing, which is the key the backend does not report.
    public static func value(at path: String, in document: JSONValue) -> JSONValue? {
        var current = document
        for component in path.split(separator: ".") {
            guard case .object(let object) = current,
                  let next = object[String(component)]
            else { return nil }
            current = next
        }
        return current
    }

    /// The minimal nested document that sets exactly `path`, which is what a deep-merging `PUT /api/config` should receive.
    public static func partial(path: String, value: JSONValue) -> JSONValue {
        var result = value
        for component in path.split(separator: ".").reversed() {
            result = .object([String(component): result])
        }
        return result
    }

    /// A copy of `document` with `path` set to `value`, creating intermediate objects as needed and replacing non-object intermediates exactly as the backend's deep-merge would resolve it.
    public static func setting(_ document: JSONValue, path: String, to value: JSONValue) -> JSONValue {
        let components = path.split(separator: ".").map(String.init)
        return set(document, components: components[...], to: value)
    }

    private static func set(
        _ node: JSONValue,
        components: ArraySlice<String>,
        to value: JSONValue
    ) -> JSONValue {
        guard let head = components.first else { return value }
        var object: [String: JSONValue]
        if case .object(let existing) = node {
            object = existing
        } else {
            object = [:]
        }
        let child = object[head] ?? .null
        object[head] = set(child, components: components.dropFirst(), to: value)
        return .object(object)
    }
}
