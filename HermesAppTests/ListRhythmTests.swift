import SwiftUI
import XCTest

@testable import HermesMobile

/// List rhythm.
///
/// `FlatRow` drew a full-bleed hairline under every row by default (`Primitives.swift:194`, `:217-221`), against the design system's own rule beside `hairline()` in `HermesType.swift` ("one per group boundary, never a border around a panel or between every settings row"), so every list read as a ruled form. And in the hub only pinned and live rows carry a dot, which sat in the row's flow and pushed those rows' titles 12 pt to the right of every other row (`HistoryGroupList.swift:104-111`).
@MainActor
final class ListRhythmTests: XCTestCase {
    private let rasteriser = VisualRasteriser()

    override func tearDown() {
        rasteriser.tearDown()
        super.tearDown()
    }

    private func tokens(_ polarity: ColorScheme) -> HermesTokens {
        let palette: DesktopPalette = polarity == .dark ? .nousDark : .nousLight
        return HermesTokens(skin: HermesSkin(palette: palette), palette: palette, polarity: polarity)
    }

    /// A plain row draws no rule of its own: its bottom edge is canvas from side to side.
    func testAFlatRowDrawsNoRuleByDefault() {
        for polarity in [ColorScheme.light, .dark] {
            let t = tokens(polarity)
            let view = AnyView(
                FlatRow {
                    Color.clear.frame(width: 10, height: 10)
                } trailing: {
                    EmptyView()
                }
            )
            let raster = rasteriser.render(view, tokens: t, polarity: polarity, size: CGSize(width: 300, height: Hit.commit))
            let canvas = RGBA(resolving: t.canvas)
            let bottom = raster.height - 1
            let off = raster.pixelsOff(ground: canvas, row: bottom) + raster.pixelsOff(ground: canvas, row: bottom - 1)
            XCTAssertEqual(off, 0, "Nous \(polarity == .dark ? "dark" : "light"): a default FlatRow drew \(off) non-canvas pixels along its bottom edge — a rule under every row")
        }
    }

    /// A row that opts in still gets its rule, so a group boundary can be drawn where one is meant.
    func testAFlatRowStillDrawsTheRuleItIsAskedFor() {
        let t = tokens(.light)
        let view = AnyView(
            FlatRow(showsHairline: true) {
                Color.clear.frame(width: 10, height: 10)
            } trailing: {
                EmptyView()
            }
        )
        let raster = rasteriser.render(view, tokens: t, polarity: .light, size: CGSize(width: 300, height: Hit.commit))
        let canvas = RGBA(resolving: t.canvas)
        let bottom = raster.height - 1
        let off = raster.pixelsOff(ground: canvas, row: bottom) + raster.pixelsOff(ground: canvas, row: bottom - 1)
        XCTAssertGreaterThan(off, raster.width / 2, "an explicit showsHairline: true row drew no rule")
    }

    /// Every hub row's title starts on the same line, dot or no dot.
    func testHubRowTitlesAlignWhetherOrNotTheRowCarriesADot() {
        for polarity in [ColorScheme.light, .dark] {
            let t = tokens(polarity)
            let size = CGSize(width: 300, height: Hit.commit + 8)
            let solid = String(repeating: "\u{2588}", count: 5)
            let plain = rasteriser.render(AnyView(HistoryRowLabel(title: solid, meta: "", dot: .none)), tokens: t, polarity: polarity, size: size)
            let pinned = rasteriser.render(AnyView(HistoryRowLabel(title: solid, meta: "", dot: .pinned)), tokens: t, polarity: polarity, size: size)
            // The title is `text1`, the strongest ink in the row; the pinned dot is `text3`, so the title's own colour finds the title and not the dot.
            let titleInk = plain.ink(over: plain.dominant)
            guard let plainX = plain.leftmostColumn(near: titleInk),
                  let pinnedX = pinned.leftmostColumn(near: titleInk) else {
                return XCTFail("Nous \(polarity == .dark ? "dark" : "light"): no title was drawn")
            }
            XCTAssertEqual(
                Double(pinnedX), Double(plainX), accuracy: 1,
                "Nous \(polarity == .dark ? "dark" : "light"): a pinned row's title starts at \(Double(pinnedX) / 3) pt and a plain row's at \(Double(plainX) / 3) pt"
            )
        }
    }

    /// The dot is still drawn: it moved, it did not go.
    func testAPinnedHubRowStillShowsItsDot() {
        let t = tokens(.light)
        let size = CGSize(width: 300, height: Hit.commit + 8)
        let raster = rasteriser.render(AnyView(HistoryRowLabel(title: "", meta: "", dot: .pinned)), tokens: t, polarity: .light, size: size)
        let ground = raster.dominant
        XCTAssertNotEqual(raster.ink(over: ground), ground, "a pinned row with no title drew no dot")
    }
}
