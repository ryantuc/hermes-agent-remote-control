import SwiftUI
import XCTest

@testable import HermesMobile

/// BUG-115 — the project pill truncated to three characters because the branch button held a fixed slot.
///
/// The reported defect: centring the project pill left the branch button where it was, and the project name in the picker truncated to three characters and an ellipsis. The pill has to expand in both directions until it would collide with something else.
///
/// The mechanism is BUG-063 (2)'s hidden twin. It is a full copy of the branch chip placed on the far side of the pill so that what lands at the bar's centre is the pill and not the pill-plus-chip pair, and it is the right idea — but it is a slot in an `HStack`, and an `HStack` slot does not know it is worth less than its neighbour. On a phone-width bar the twin and the real chip take 44 pt each (up to 102 pt each off trunk) before the pill is offered anything.
///
/// `WorkspaceChipsRow` ranks the three instead of dividing between them, and the ranking is pure arithmetic, so it is asserted here at every width and label length rather than photographed. The numbers below are the real ones: `Space.s3` between slots, a 44 pt bare branch glyph, and a `ComposerPill` whose own chrome — 12 pt padding either side, a 7 pt dot, a chevron and two 6 pt gaps — is about 51 pt before a single character of the name.
final class WorkspaceChipsRowTests: XCTestCase {

    private let spacing = Space.s3
    /// A bare branch chip: an icon button at the minimum target.
    private let branch = Hit.min
    /// Roughly what a 40-character project name asks for at `HermesFont.code`,
    /// well past the cap.
    private let fortyCharacterPill: CGFloat = 360
    /// Roughly what a three-character name asks for: the pill's chrome plus
    /// three glyphs.
    private let threeCharacterPill: CGFloat = 75

    private func resolve(
        budget: CGFloat,
        pill: CGFloat,
        shim: CGFloat? = nil,
        branchWidth: CGFloat? = nil
    ) -> WorkspaceChipsRow.Widths {
        let chip = branchWidth ?? branch
        return WorkspaceChipsRow.resolve(
            budget: budget,
            shimIdeal: shim ?? chip,
            pillWanted: pill,
            branchIdeal: chip,
            spacing: spacing
        )
    }

    // MARK: 1 — the regression itself

    /// The measured shape of the bug. `HomeView`'s bar leaves this row roughly
    /// 157 pt on a 393 pt phone; two 44 pt branch slots and two 6 pt gaps take
    /// 100 of it, and the pill was left with what was under the pill's own
    /// chrome — three characters and an ellipsis.
    func testAThreeCharacterPillIsWhatTheOldFixedSlotsProduced() {
        let barWidth: CGFloat = 157
        let starved = barWidth - (branch * 2) - (spacing * 2)
        XCTAssertLessThan(starved, threeCharacterPill, """
            the arithmetic this test is built on no longer holds: two fixed branch slots leave \
            \(starved) pt, which is now enough for a short name. If the bar's budget changed, the \
            numbers below need re-deriving before this file means anything
            """)
    }

    /// The fix, at the same width: the shim goes to nothing and the pill takes
    /// everything the branch chip does not need.
    func testALongNameTakesTheShimsWidthRatherThanTruncatingBesideIt() {
        let widths = resolve(budget: 157, pill: fortyCharacterPill)
        XCTAssertEqual(widths.shim, 0, """
            the centring shim held \(widths.shim) pt while the name beside it had nowhere to go. \
            Centring is what BUG-063 bought; reading the name is what the bar is for, and the shim \
            is invisible
            """)
        XCTAssertEqual(widths.branch, branch, "the branch chip was compressed; it is a 44 pt control")
        XCTAssertEqual(widths.pill, 157 - branch - spacing)
        XCTAssertGreaterThan(widths.pill, threeCharacterPill, """
            the pill came out at \(widths.pill) pt, which is still inside the three-characters-and-an-\
            ellipsis band the report is about
            """)
    }

    /// The whole safety argument for this layout: it re-divides the row's old
    /// footprint and never asks the bar for more than it already had.
    func testTheRowNeverSpendsMoreThanItsBudget() {
        for budget in stride(from: CGFloat(60), through: 420, by: 7) {
            for pill in [threeCharacterPill, 140, fortyCharacterPill] {
                let widths = resolve(budget: budget, pill: pill)
                XCTAssertLessThanOrEqual(widths.total, budget, """
                    at budget \(budget) with a \(pill) pt pill the row claimed \(widths.total) pt. A row \
                    that overruns its budget pushes `HomeView`'s mode control off the trailing edge — \
                    which is the "would conflict with another element" the report draws the line at
                    """)
            }
        }
    }

    // MARK: 2 — a short name still reads, and still centres

    /// The other half of the report: *both* lengths must read fully when width
    /// allows. A three-character name always has the width.
    func testAThreeCharacterNameIsNeverTruncated() {
        let widths = resolve(budget: 157, pill: threeCharacterPill)
        XCTAssertEqual(widths.pill, threeCharacterPill, """
            a three-character project name was given \(widths.pill) pt against the \(threeCharacterPill) \
            it asked for. Nothing on this bar is short enough to justify truncating that
            """)
    }

    /// BUG-063's centring is not abandoned — it is ranked last. With a short
    /// name there is change left over and the shim spends it.
    func testAShortNameLeavesTheShimSomethingToCentreWith() {
        let widths = resolve(budget: 157, pill: threeCharacterPill)
        XCTAssertGreaterThan(widths.shim, 0, """
            the shim was given nothing even though the name fit with room to spare. BUG-063 (2) is \
            still a live requirement: the pill is meant to sit at the bar's centre whether or not a \
            branch chip is beside it
            """)
        XCTAssertLessThanOrEqual(widths.shim, branch, "the shim grew past the chip it is a twin of")
    }

    /// Given room for everything, everything gets its full width — the shim
    /// included, which is the fully centred state.
    func testAWideBarCentresThePillExactlyAsBeforeTheFix() {
        let widths = resolve(budget: 400, pill: threeCharacterPill)
        XCTAssertEqual(widths.shim, branch, "a bar with room to spare stopped centring the pill")
        XCTAssertEqual(widths.pill, threeCharacterPill)
        XCTAssertEqual(widths.branch, branch)
        XCTAssertEqual(widths.total, branch + spacing + threeCharacterPill + spacing + branch)
    }

    // MARK: 3 — the branch chip is a control

    func testTheBranchChipIsNeverCompressedForThePill() {
        for pill in [threeCharacterPill, 200, fortyCharacterPill] {
            let widths = resolve(budget: 157, pill: pill)
            XCTAssertEqual(widths.branch, branch, """
                a \(pill) pt pill squeezed the branch chip to \(widths.branch) pt. It is a 44 pt target \
                with a job — saying you are off trunk — and starving it is the bug this report is \
                about, pointed the other way
                """)
        }
    }

    /// Off trunk the chip is a labelled pill of up to 102 pt, and it still
    /// comes first. The pill takes what is left, which is less — that is the
    /// trade the labelled state is deliberately buying.
    func testALabelledBranchChipStillTakesItsWidthFirst() {
        let labelled: CGFloat = 102
        let widths = resolve(budget: 157, pill: fortyCharacterPill, branchWidth: labelled)
        XCTAssertEqual(widths.branch, labelled)
        XCTAssertEqual(widths.pill, 157 - labelled - spacing)
        XCTAssertEqual(widths.shim, 0)
    }

    // MARK: 4 — no repository at all

    /// `BranchDisplay.removed` renders `EmptyView` on both sides. A slot at
    /// zero must be charged no gap, or the pill pays 12 pt for two chips that
    /// are not there.
    func testWithNoRepositoryThePillGetsTheWholeRowAndNoDanglingGaps() {
        let widths = WorkspaceChipsRow.resolve(
            budget: 157,
            shimIdeal: 0,
            pillWanted: fortyCharacterPill,
            branchIdeal: 0,
            spacing: spacing
        )
        XCTAssertEqual(widths.branch, 0)
        XCTAssertEqual(widths.shim, 0)
        XCTAssertEqual(widths.pill, 157)
        XCTAssertEqual(widths.total, 157, """
            the row claimed \(widths.total) pt for one chip on a \(157) pt budget — a slot with no width \
            is still being charged a gap
            """)
    }

    // MARK: 5 — degenerate widths do not produce negative ones

    func testAnImpossiblyNarrowBarProducesNoNegativeWidths() {
        for budget in [CGFloat(0), 1, 20, 44, 50] {
            let widths = resolve(budget: budget, pill: fortyCharacterPill)
            XCTAssertGreaterThanOrEqual(widths.shim, 0, "shim went negative at budget \(budget)")
            XCTAssertGreaterThanOrEqual(widths.pill, 0, "pill went negative at budget \(budget)")
            XCTAssertGreaterThanOrEqual(widths.branch, 0, "branch went negative at budget \(budget)")
            XCTAssertLessThanOrEqual(widths.total, budget, "the row overran a \(budget) pt budget")
        }
    }

    // MARK: 6 — the caps

    func testThePillCapIsUnchangedFromTheOneItReplaced() {
        XCTAssertEqual(WorkspaceChipsRow.pillCapDefault, 225, """
            the pill's ceiling moved. BUG-115 relocated it from a `.frame(maxWidth:)` on the chip into \
            the layout; it was not asked to change value
            """)
        XCTAssertEqual(WorkspaceChipsRow.branchCapDefault, 102, "the labelled branch chip's ceiling moved")
    }
}
