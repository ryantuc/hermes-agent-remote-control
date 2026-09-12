import HermesServeKit
import XCTest

@testable import HermesMobile

/// FEAT-014 — which rungs of the reasoning ladder a model is offered.
///
/// The failure this closes is a quiet one. `off` on a reasoning-mandatory route
/// used to be an HTTP 400; since `agent/reasoning_effort.clamp_effort` landed it
/// is taken as "the weakest level you support", so the request succeeds, the
/// model reasons anyway, and the dial reads `off`. A control that reports a
/// state the system is not in is worse than one that is not there.
final class EffortLadderTests: XCTestCase {

    func testTheFullLadderIsOfferedWhenReasoningCanBeDisabled() {
        let offered = EffortLadder.offered(canDisableReasoning: true)
        XCTAssertEqual(offered, ReasoningEffort.allCases)
        XCTAssertTrue(offered.contains(.off))
    }

    func testOffIsNotOfferedOnAReasoningMandatoryModel() {
        let offered = EffortLadder.offered(canDisableReasoning: false)

        XCTAssertFalse(offered.contains(.off))
        XCTAssertEqual(
            offered, [.minimal, .low, .medium, .high, .xhigh, .max, .ultra],
            "only the rung that cannot be honoured goes; the rest of the dial stands"
        )
    }

    /// A missing rung with no explanation is the same silence in a different
    /// place, so the sheet says why.
    func testTheReasonIsStated() {
        XCTAssertFalse(EffortLadder.mandatoryNote.isEmpty)
        XCTAssertTrue(EffortLadder.mandatoryNote.lowercased().contains("always reasons"))
    }

    /// The default that governs almost every model in the catalogue: the key is
    /// published for `nous` and `openrouter` alone, and absence means "no
    /// restriction known".
    func testAnUncataloguedModelKeepsTheWholeLadder() {
        let row = ProviderRow(json: .object([
            "slug": .string("anthropic"),
            "models": .array([.string("claude-opus-5")]),
        ]))

        XCTAssertTrue(row.canDisableReasoning("claude-opus-5"))
        XCTAssertEqual(
            EffortLadder.offered(canDisableReasoning: row.canDisableReasoning("claude-opus-5")),
            ReasoningEffort.allCases
        )
    }

    /// End to end from the payload the picker actually decodes.
    func testARestrictedModelFromAPayloadLosesOnlyItsOffRung() {
        let row = ProviderRow(json: .object([
            "slug": .string("nous"),
            "models": .array([.string("hermes-4-405b")]),
            "capabilities": .object([
                "hermes-4-405b": .object([
                    "reasoning": .bool(true),
                    "can_disable_reasoning": .bool(false),
                ]),
            ]),
        ]))

        let offered = EffortLadder.offered(
            canDisableReasoning: row.canDisableReasoning("hermes-4-405b")
        )
        XCTAssertFalse(offered.contains(.off))
        XCTAssertEqual(offered.count, ReasoningEffort.allCases.count - 1)
        XCTAssertTrue(row.supportsReasoning("hermes-4-405b"), "the dial itself stays")
    }
}
