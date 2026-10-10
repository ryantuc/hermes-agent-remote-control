import XCTest

@testable import HermesServeKit

/// The config shapes behind the model rows in Settings: the flat `model` slug, provider + model pairs, the `fallback_providers` list, and the body `POST /api/model/set` takes.
final class ModelSettingsTests: XCTestCase {

    // MARK: Pairs

    func testAPairReadsOffTwoSiblingKeysAndTreatsAutoAsNoProvider() {
        let pinned = ModelPair(providerValue: .string("openrouter"), modelValue: .string("anthropic/claude-opus-4"))
        XCTAssertEqual(pinned.provider, "openrouter")
        XCTAssertEqual(pinned.model, "anthropic/claude-opus-4")
        XCTAssertEqual(pinned.displayText, "openrouter/anthropic/claude-opus-4")
        XCTAssertFalse(pinned.isEmpty)

        let inherited = ModelPair(providerValue: .string("auto"), modelValue: .string(""))
        XCTAssertEqual(inherited.provider, "", "an auxiliary slot spells inherit as `auto`")
        XCTAssertTrue(inherited.isEmpty)

        let absent = ModelPair(providerValue: nil, modelValue: .null)
        XCTAssertTrue(absent.isEmpty)
        XCTAssertEqual(absent.displayText, "")
    }

    func testATypedSlugSplitsAtTheFirstSlashOnly() {
        XCTAssertEqual(
            ModelPair.parsing("openrouter/anthropic/claude-opus-4"),
            ModelPair(provider: "openrouter", model: "anthropic/claude-opus-4")
        )
        XCTAssertEqual(ModelPair.parsing("  hermes-4-405b "), ModelPair(provider: "", model: "hermes-4-405b"))
        XCTAssertEqual(ModelPair.parsing("/odd"), ModelPair(provider: "", model: "/odd"), "a leading slash names no provider")
    }

    // MARK: The fallback list

    func testTheChainRoundTripsAndKeepsTheKeysItDoesNotEdit() {
        let stored: JSONValue = .array([
            .object([
                "provider": .string("copilot"), "model": .string("gpt-5-mini"),
                "base_url": .string("http://gateway.local:4000"), "key_env": .string("LOCAL_KEY"),
            ]),
            .object(["provider": .string("openai-codex"), "model": .string("gpt-5.4-mini")]),
        ])

        let entries = FallbackChain.entries(from: stored)
        XCTAssertEqual(entries.map(\.pair), [
            ModelPair(provider: "copilot", model: "gpt-5-mini"),
            ModelPair(provider: "openai-codex", model: "gpt-5.4-mini"),
        ])
        XCTAssertEqual(entries[0].extras, [
            "base_url": .string("http://gateway.local:4000"), "key_env": .string("LOCAL_KEY"),
        ], "the pair is not duplicated into the extras")

        XCTAssertEqual(FallbackChain.json(entries), stored, "an untouched chain writes back byte for byte")
    }

    func testReorderingRemovingAndAddingWriteTheWholeListInOrder() {
        var entries = FallbackChain.entries(from: .array([
            .object(["provider": .string("a"), "model": .string("one"), "api_mode": .string("chat_completions")]),
            .object(["provider": .string("b"), "model": .string("two")]),
            .object(["provider": .string("c"), "model": .string("three")]),
        ]))
        let last = entries.remove(at: 2)
        entries.insert(last, at: 0)
        entries.remove(at: 1)
        entries.append(FallbackEntry(provider: "d", model: "four"))

        XCTAssertEqual(FallbackChain.json(entries), .array([
            .object(["provider": .string("c"), "model": .string("three")]),
            .object(["provider": .string("b"), "model": .string("two")]),
            .object(["provider": .string("d"), "model": .string("four")]),
        ]))
    }

    func testAnIncompleteEntryIsNeverWritten() {
        let entries = [
            FallbackEntry(provider: "nous", model: "hermes-4-405b"),
            FallbackEntry(provider: "", model: "orphan"),
            FallbackEntry(provider: "openrouter", model: ""),
        ]
        XCTAssertEqual(FallbackChain.json(entries), .array([
            .object(["provider": .string("nous"), "model": .string("hermes-4-405b")]),
        ]))
        XCTAssertEqual(entries.filter(\.isComplete).count, 1)
    }

    func testOddStoredShapesReadWithoutCrashing() {
        XCTAssertEqual(
            FallbackChain.entries(from: .array([.string("openrouter/anthropic/claude-opus-4")])).map(\.pair),
            [ModelPair(provider: "openrouter", model: "anthropic/claude-opus-4")],
            "a legacy string entry reads the way Desktop reads it"
        )
        XCTAssertEqual(
            FallbackChain.entries(from: .object(["provider": .string("a"), "model": .string("b")])).count,
            1,
            "a lone object is a one-entry chain, as the backend treats it"
        )
        XCTAssertTrue(FallbackChain.entries(from: .string("nonsense")).isEmpty)
        XCTAssertTrue(FallbackChain.entries(from: nil).isEmpty)
        XCTAssertTrue(FallbackChain.entries(from: .array([.number(3)])).isEmpty)
    }

    func testTheChainPartialIsTheTopLevelKeyAlone() {
        let partial = ConfigDocument.partial(
            path: FallbackChain.key,
            value: FallbackChain.json([FallbackEntry(provider: "nous", model: "hermes-4-70b")])
        )
        XCTAssertEqual(partial, .object([
            "fallback_providers": .array([.object(["provider": .string("nous"), "model": .string("hermes-4-70b")])]),
        ]))
    }

    // MARK: A pair of sibling keys

    func testAProviderAndModelPairGoOutInOneNestedPartial() {
        let partial = ConfigDocument.partial(paths: [
            (path: "delegation.provider", value: .string("openrouter")),
            (path: "delegation.model", value: .string("google/gemini-3-flash-preview")),
        ])
        XCTAssertEqual(partial, .object([
            "delegation": .object([
                "provider": .string("openrouter"),
                "model": .string("google/gemini-3-flash-preview"),
            ]),
        ]))
    }

    // MARK: The assignment route

    func testTheMainAssignmentBodyMatchesDesktopsPicker() {
        XCTAssertEqual(
            ModelAssignmentAPI.body(
                slot: .main,
                pair: ModelPair(provider: "anthropic", model: "claude-sonnet-4.6"),
                confirmExpensive: false
            ),
            .object([
                "scope": .string("main"),
                "provider": .string("anthropic"),
                "model": .string("claude-sonnet-4.6"),
            ])
        )
        XCTAssertEqual(
            ModelAssignmentAPI.body(
                slot: .auxiliary(task: "vision"),
                pair: ModelPair(provider: "auto", model: ""),
                confirmExpensive: true
            ),
            .object([
                "scope": .string("auxiliary"),
                "task": .string("vision"),
                "provider": .string("auto"),
                "model": .string(""),
                "confirm_expensive_model": .bool(true),
            ])
        )
    }

    func testTheAssignmentResultReadsBothAnswers() {
        let applied = ModelAssignmentResult(json: .object([
            "ok": .bool(true), "scope": .string("main"),
            "provider": .string("anthropic"), "model": .string("claude-sonnet-4.6"),
            "base_url": .string(""), "stale_aux": .array([]),
        ]))
        XCTAssertTrue(applied.ok)
        XCTAssertFalse(applied.confirmRequired)
        XCTAssertEqual(applied.model, "claude-sonnet-4.6")

        let asks = ModelAssignmentResult(json: .object([
            "ok": .bool(false), "confirm_required": .bool(true),
            "confirm_message": .string("This model is expensive."),
        ]))
        XCTAssertFalse(asks.ok)
        XCTAssertTrue(asks.confirmRequired)
        XCTAssertEqual(asks.confirmMessage, "This model is expensive.")

        XCTAssertFalse(ModelAssignmentResult(json: .null).ok, "an empty body is not a success")
    }
}
