import XCTest

@testable import HermesServeKit

/// The dotted-path ↔ nested-document translation the settings tree rides on.
final class ConfigDocumentTests: XCTestCase {
    private let document: JSONValue = .object([
        "model": .string("deepseek/deepseek-v4-flash-0731"),
        "model_context_length": .number(0),
        "memory": .object([
            "memory_enabled": .bool(true),
            "memory_char_limit": .number(4000),
        ]),
        "compression": .object([
            "enabled": .bool(false),
        ]),
    ])

    func testValueAtPath() {
        XCTAssertEqual(
            ConfigDocument.value(at: "memory.memory_enabled", in: document),
            .bool(true)
        )
        XCTAssertEqual(
            ConfigDocument.value(at: "model", in: document),
            .string("deepseek/deepseek-v4-flash-0731")
        )
        XCTAssertNil(
            ConfigDocument.value(at: "terminal.cwd", in: document),
            "a missing key is nil — the ValueView removal contract, never an error"
        )
        XCTAssertNil(ConfigDocument.value(at: "model.default", in: document),
                     "descending through a scalar is a miss, not a crash")
    }

    func testPartialBuildsTheMinimalNestedWrite() {
        XCTAssertEqual(
            ConfigDocument.partial(path: "memory.memory_enabled", value: .bool(false)),
            .object(["memory": .object(["memory_enabled": .bool(false)])])
        )
        XCTAssertEqual(
            ConfigDocument.partial(path: "timezone", value: .string("America/Chicago")),
            .object(["timezone": .string("America/Chicago")])
        )
    }

    func testSettingMutatesACopyAndPreservesSiblings() {
        let updated = ConfigDocument.setting(document, path: "memory.memory_enabled", to: .bool(false))
        XCTAssertEqual(ConfigDocument.value(at: "memory.memory_enabled", in: updated), .bool(false))
        XCTAssertEqual(
            ConfigDocument.value(at: "memory.memory_char_limit", in: updated),
            .number(4000),
            "siblings survive the write"
        )
        XCTAssertEqual(
            ConfigDocument.value(at: "memory.memory_enabled", in: document),
            .bool(true),
            "the source document is untouched"
        )

        let grown = ConfigDocument.setting(document, path: "stt.provider", to: .string("local"))
        XCTAssertEqual(
            ConfigDocument.value(at: "stt.provider", in: grown),
            .string("local"),
            "intermediate objects are created on demand"
        )
    }
}
