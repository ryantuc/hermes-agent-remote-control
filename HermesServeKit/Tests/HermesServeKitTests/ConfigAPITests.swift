import XCTest

@testable import HermesServeKit

/// The config / model / usage results. Every one of these shapes is "defined
/// outside this layer" at the protocol level, so the contract this client
/// actually depends on is *defensive decoding*: a missing field is normal, and
/// none of it may crash or silently become a wrong number on screen.
final class ConfigAPITests: XCTestCase {

    /// `deferred: true` is the single producer of `ValueState.pending` — a
    /// mid-turn model switch the backend queued. Losing it would show the write
    /// as applied while the old model is still answering.
    func testConfigSetResultCarriesDeferredAndConfirmation() throws {
        let result = ConfigSetResult(json: try Fixtures.result("response-config-set-model"))

        XCTAssertEqual(result.key, "model")
        XCTAssertEqual(result.value, "hermes-4-405b")
        XCTAssertTrue(result.deferred, "a mid-turn write comes back queued, not applied")
        XCTAssertTrue(result.confirmRequired)
        XCTAssertEqual(result.confirmMessage, "Switch to an expensive model?")
        XCTAssertEqual(result.warning, "This model bills at 4x the current one.")
        XCTAssertEqual(result.scope, "session")
    }

    /// The common case is the bare `{key, value}` base with none of the
    /// per-key extras; nothing may be inferred from their absence.
    func testConfigSetResultDefaultsWhenOnlyTheBaseIsSent() {
        let result = ConfigSetResult(json: .object([
            "key": .string("thinking_mode"), "value": .string("collapsed"),
        ]))
        XCTAssertFalse(result.deferred, "no `deferred` key means applied, not pending")
        XCTAssertFalse(result.confirmRequired)
        XCTAssertTrue(result.warning.isEmpty)
        XCTAssertTrue(result.scope.isEmpty)
    }

    /// Context fields exist only when a compressor does. Absent must read as
    /// "no context state to show", never as 0% used.
    func testSessionUsageContextIsOptional() throws {
        let usage = SessionUsage(json: try Fixtures.result("response-session-usage"))

        XCTAssertEqual(usage.model, "hermes-4-405b")
        XCTAssertEqual(usage.total, 44380)
        XCTAssertEqual(usage.input, 41200)
        XCTAssertEqual(usage.output, 3180)
        XCTAssertTrue(usage.hasContext)
        XCTAssertEqual(usage.compressions, 1)
        XCTAssertEqual(try XCTUnwrap(usage.contextFraction), 0.322, accuracy: 0.0001)

        // The agentless-session shape (jsonrpc-methods §3.4).
        let agentless = SessionUsage(json: .object([
            "calls": .number(0), "input": .number(0), "output": .number(0), "total": .number(0),
        ]))
        XCTAssertFalse(agentless.hasContext, "no compressor ⇒ no ring, not a zeroed ring")
        XCTAssertNil(agentless.contextFraction)
    }

    /// Percent is authoritative when sent; used/max is the fallback; and a
    /// backend that overshoots 100% must not draw a ring past full.
    func testSessionUsageContextFractionFallsBackAndClamps() throws {
        let fromCounts = SessionUsage(json: .object([
            "context_used": .number(32000), "context_max": .number(128000),
        ]))
        XCTAssertEqual(try XCTUnwrap(fromCounts.contextFraction), 0.25, accuracy: 0.0001)
        XCTAssertTrue(fromCounts.hasContext)

        let over = SessionUsage(json: .object(["context_percent": .number(140)]))
        XCTAssertEqual(try XCTUnwrap(over.contextFraction), 1.0, accuracy: 0.0001)

        let negative = SessionUsage(json: .object(["context_percent": .number(-5)]))
        XCTAssertEqual(try XCTUnwrap(negative.contextFraction), 0.0, accuracy: 0.0001)

        // A zero max cannot be divided by, and must not surface as a fraction.
        let zeroMax = SessionUsage(json: .object([
            "context_used": .number(10), "context_max": .number(0),
        ]))
        XCTAssertNil(zeroMax.contextFraction)
    }

    /// Model entries arrive as objects keyed `slug` or `id`, and as bare
    /// strings. All three have to become a selectable row.
    func testModelCatalogueAcceptsPolymorphicEntries() throws {
        let catalogue = ModelCatalogue(json: try Fixtures.result("response-model-options"))
        XCTAssertEqual(catalogue.providers.count, 2)

        let nous = catalogue.providers[0]
        XCTAssertEqual(nous.name, "Nous Research")
        XCTAssertTrue(nous.isCurrent)
        XCTAssertTrue(nous.authenticated)
        XCTAssertEqual(nous.featuredModels, ["hermes-4-405b"])
        XCTAssertEqual(nous.models.map(\.slug), ["hermes-4-405b", "hermes-4-70b"])
        XCTAssertEqual(nous.models[1].name, "Hermes 4 70B", "an `id`-keyed entry is still a real model")
        XCTAssertTrue(nous.models[0].isCurrent)

        let openrouter = catalogue.providers[1]
        XCTAssertEqual(
            openrouter.name, "openrouter",
            "a provider with no display name falls back to its slug rather than rendering blank"
        )
        XCTAssertFalse(openrouter.authenticated)
        XCTAssertEqual(openrouter.warning, "No API key saved for this provider.")
        let bare = try XCTUnwrap(openrouter.models.first)
        XCTAssertEqual(bare.slug, "some-vendor/some-model")
        XCTAssertEqual(bare.name, bare.slug, "a bare string is both the id and the label")
    }

    /// A top-level array instead of `{providers: […]}` is the other shape this
    /// payload has taken; neither may decode to an empty picker.
    func testModelCatalogueAcceptsATopLevelArray() {
        let catalogue = ModelCatalogue(json: .array([
            .object(["slug": .string("nous"), "models": .array([.string("hermes-4-405b")])])
        ]))
        XCTAssertEqual(catalogue.providers.count, 1)
        XCTAssertEqual(catalogue.providers[0].models.first?.slug, "hermes-4-405b")

        // And an unrecognisable payload degrades to empty rather than throwing.
        XCTAssertTrue(ModelCatalogue(json: .object(["unexpected": .bool(true)])).providers.isEmpty)
    }
}
