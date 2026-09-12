import Foundation
import XCTest

@testable import HermesServeKit

/// Anchor class so `Bundle(for:)` can find the test bundle when the fixtures
/// were copied as resources (the XcodeGen unit-test target path). The primary
/// lookup is the source tree, which works identically under `swift test` and
/// under Xcode without needing `Bundle.module` (which only exists for SwiftPM
/// targets and would not compile in a hand-rolled Xcode target).
private final class FixtureAnchor {}

enum Fixtures {
    enum FixtureError: Error, CustomStringConvertible {
        case notFound(String)
        case malformed(String)

        var description: String {
            switch self {
            case .notFound(let name): return "fixture not found: \(name)"
            case .malformed(let name): return "fixture malformed: \(name)"
            }
        }
    }

    private static var sourceDirectory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures", isDirectory: true)
    }

    static func url(_ name: String) throws -> URL {
        let fileName = name.hasSuffix(".json") ? name : name + ".json"
        let sourceURL = sourceDirectory.appendingPathComponent(fileName)
        if FileManager.default.fileExists(atPath: sourceURL.path) { return sourceURL }

        let bundle = Bundle(for: FixtureAnchor.self)
        let stem = (fileName as NSString).deletingPathExtension
        if let bundled = bundle.url(forResource: stem, withExtension: "json", subdirectory: "Fixtures")
            ?? bundle.url(forResource: stem, withExtension: "json") {
            return bundled
        }
        throw FixtureError.notFound(fileName)
    }

    static func json(_ name: String) throws -> JSONValue {
        let data = try Data(contentsOf: try url(name))
        return try JSONDecoder().decode(JSONValue.self, from: data)
    }

    /// Every fixture wraps its frames in `{comment, frames: [...]}` so the file
    /// stays valid JSON while still documenting its provenance.
    static func frames(_ name: String) throws -> [JSONValue] {
        guard let frames = try json(name)["frames"]?.arrayValue else {
            throw FixtureError.malformed(name)
        }
        return frames
    }

    /// Reconstruct one WebSocket text message from a fixture's frames by
    /// joining them with newlines — exactly what the server does when it
    /// coalesces streamed token frames.
    static func coalescedText(_ name: String) throws -> String {
        try frames(name)
            .map { try JSONRPCCodec.encodeLine($0) }
            .joined(separator: "\n")
    }

    /// Decode a fixture straight into gateway events, skipping frames that are
    /// not events.
    static func events(_ name: String) throws -> [GatewayEvent] {
        try frames(name).compactMap { frame in
            let line = try JSONRPCCodec.encodeLine(frame)
            if case .event(let event) = try JSONRPCCodec.decodeFrame(line) { return event }
            return nil
        }
    }

    /// The single JSON-RPC result carried by a response fixture.
    static func result(_ name: String) throws -> JSONValue {
        try result(name, frame: 0)
    }

    /// One frame of a fixture that carries several responses — the shape used
    /// when a call's two outcomes belong in the same file (a hit and a miss).
    static func result(_ name: String, frame index: Int) throws -> JSONValue {
        let all = try frames(name)
        guard all.indices.contains(index) else { throw FixtureError.malformed(name) }
        let line = try JSONRPCCodec.encodeLine(all[index])
        guard case .response(let response) = try JSONRPCCodec.decodeFrame(line),
              let result = response.result
        else { throw FixtureError.malformed(name) }
        return result
    }
}
