import XCTest

@testable import HermesMobile

/// BUG-097 — *Default effort* offered no way back to "reasoning off".
///
/// The backend accepts `none` for `agent.reasoning_effort`
/// (`parse_reasoning_effort` aliases `false` and `disabled` onto it, and the
/// agent's own `EFFORT_LADDER` carries it), but `/api/config/schema` types the
/// key as a plain string and serves options only for
/// `delegation.reasoning_effort`. The row's `.options` list is therefore
/// static, and `none` was not in it. A user who turned reasoning off from the
/// CLI or the desktop saw the raw word through the fallback label path and had
/// no way to select it again — so any change made on the phone replaced that
/// state permanently.
final class ReasoningEffortOptionsTests: XCTestCase {

    private var defaultEffort: SettingRowDescriptor {
        SettingsCatalog.modelReasoning.sections
            .flatMap(\.rows)
            .first { $0.key == "agent.reasoning_effort" }!
    }

    private var options: [SettingOption] {
        guard case .options(let list) = defaultEffort.kind, let list else {
            XCTFail("the row must carry a static list — the schema serves none for this key")
            return []
        }
        return list
    }

    func testNoneIsSelectable() {
        XCTAssertTrue(
            options.contains { $0.value == "none" },
            "the one backend state the phone could read but never write"
        )
    }

    /// The label matters as much as the value: the fallback path rendered the
    /// raw `none`, and a picker that offers the same raw word teaches nothing.
    func testNoneIsNamedLikeAChoiceAndNotLikeAnAbsence() {
        XCTAssertEqual(options.first { $0.value == "none" }?.label, "None")
    }

    /// Bottom of the ladder, so it reads first — a rung, not a special case
    /// bolted on the end.
    func testNoneLeadsTheLadder() {
        XCTAssertEqual(options.first?.value, "none")
        XCTAssertEqual(options.map(\.value), ["none"] + SettingsCatalog.effortScale)
    }

    /// The composer's own dial and the subagent row are separate surfaces with
    /// separate mechanisms (FEAT-014 / FEAT-016, and the schema respectively);
    /// the shared scale must not have grown a member behind their backs.
    func testTheSharedScaleIsUnchanged() {
        XCTAssertEqual(
            SettingsCatalog.effortScale,
            ["minimal", "low", "medium", "high", "xhigh", "max", "ultra"]
        )
    }

    /// Subagent effort still takes its options from the live schema, which
    /// serves `""` for "inherit" and is not this list.
    func testSubagentEffortStillDefersToTheSchema() {
        let subagent = SettingsCatalog.modelReasoning.sections
            .flatMap(\.rows)
            .first { $0.key == "delegation.reasoning_effort" }
        guard case .options(let list)? = subagent?.kind else {
            return XCTFail("subagent effort is an options row")
        }
        XCTAssertNil(list, "nil is how a row asks for the schema's options")
    }
}
