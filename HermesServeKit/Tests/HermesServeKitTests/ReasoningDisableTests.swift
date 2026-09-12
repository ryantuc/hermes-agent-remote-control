import XCTest

@testable import HermesServeKit

/// FEAT-014 — `can_disable_reasoning` on the per-model capability map.
///
/// The whole value of this key is in its **absence**. Only `nous` and
/// `openrouter` rows ever carry it, and every other provider's silence means
/// "no restriction known", not "reasoning cannot be turned off". A decode that
/// folded absence into `false` would strip the off rung from most of the
/// catalogue; one that folded it into a stored `true` would be indistinguishable
/// from the backend granting permission it never granted. So the map holds only
/// what was actually said, and the accessor supplies the default.
final class ReasoningDisableTests: XCTestCase {

    private func provider(_ capabilities: [String: JSONValue]) -> ProviderRow {
        ProviderRow(json: .object([
            "slug": .string("nous"),
            "name": .string("Nous"),
            "models": .array([.string("hermes-4-405b"), .string("deepseek-v4-flash")]),
            "capabilities": .object(capabilities),
        ]))
    }

    func testAStatedFalseIsHonoured() {
        let row = provider([
            "hermes-4-405b": .object([
                "reasoning": .bool(true),
                "can_disable_reasoning": .bool(false),
            ]),
        ])

        XCTAssertTrue(row.supportsReasoning("hermes-4-405b"))
        XCTAssertFalse(row.canDisableReasoning("hermes-4-405b"))
    }

    func testAStatedTrueIsHonoured() {
        let row = provider([
            "hermes-4-405b": .object([
                "reasoning": .bool(true),
                "can_disable_reasoning": .bool(true),
            ]),
        ])
        XCTAssertTrue(row.canDisableReasoning("hermes-4-405b"))
    }

    /// The key is absent for every provider that is not `nous` or
    /// `openrouter`, and for uncatalogued models on those two.
    func testAnAbsentKeyMeansNoRestrictionKnown() {
        let row = provider([
            "hermes-4-405b": .object(["reasoning": .bool(true)]),
        ])

        XCTAssertTrue(row.canDisableReasoning("hermes-4-405b"), "silence is not a no")
        XCTAssertTrue(row.canDisableReasoning("a-model-nobody-catalogued"))
        XCTAssertNil(
            row.reasoningDisablable["hermes-4-405b"],
            "an unstated capability must not be stored as a stated one"
        )
    }

    /// A row with no capability map at all — every backend before the key
    /// existed, and every provider that does not publish per-model detail.
    func testAProviderWithNoCapabilityMapPermitsOff() {
        let row = ProviderRow(json: .object([
            "slug": .string("anthropic"),
            "models": .array([.string("claude-opus-5")]),
        ]))

        XCTAssertTrue(row.canDisableReasoning("claude-opus-5"))
        XCTAssertTrue(row.reasoningDisablable.isEmpty)
    }

    /// The two capabilities are independent: a model can accept the effort dial
    /// and still refuse to have reasoning turned off, which is exactly the case
    /// the key was added for.
    func testTheTwoCapabilitiesAreIndependent() {
        let row = provider([
            "hermes-4-405b": .object([
                "reasoning": .bool(true),
                "can_disable_reasoning": .bool(false),
            ]),
            "deepseek-v4-flash": .object([
                "reasoning": .bool(false),
                "can_disable_reasoning": .bool(true),
            ]),
        ])

        XCTAssertTrue(row.supportsReasoning("hermes-4-405b"))
        XCTAssertFalse(row.canDisableReasoning("hermes-4-405b"))
        XCTAssertFalse(row.supportsReasoning("deepseek-v4-flash"))
        XCTAssertTrue(row.canDisableReasoning("deepseek-v4-flash"))
    }

    /// The catalogue warms in the background, so the same model legitimately
    /// answers differently across two picker opens. Nothing may cache it: a
    /// second decode of a later payload has to win.
    func testALaterCatalogueOverridesAnEarlierOne() {
        let cold = provider(["hermes-4-405b": .object(["reasoning": .bool(true)])])
        XCTAssertTrue(cold.canDisableReasoning("hermes-4-405b"))

        let warm = provider([
            "hermes-4-405b": .object([
                "reasoning": .bool(true),
                "can_disable_reasoning": .bool(false),
            ]),
        ])
        XCTAssertFalse(warm.canDisableReasoning("hermes-4-405b"))
    }
}
