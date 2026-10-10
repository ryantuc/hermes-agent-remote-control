import SwiftUI
import XCTest

@testable import HermesMobile

/// The "Scroll to the end ▾" cue sat over readable command text. The veil under it was painted in `enclosure`, but the command block's ground is `toolCard` (`EnclosureModifier`), so on a backend palette the veil was a different colour from the block it covers, and it only reached solid at the very bottom edge, below the cue. It is now the block's own ground, solid from just above the cue down.
@MainActor
final class ApprovalGateVeilTests: XCTestCase {

    private func tokens(_ polarity: ColorScheme) -> HermesTokens {
        let palette: DesktopPalette = polarity == .dark ? .nousDark : .nousLight
        return HermesTokens(skin: HermesSkin(palette: palette), palette: palette, polarity: polarity)
    }

    func testTheVeilIsPaintedInTheCommandBlocksOwnGround() {
        for polarity: ColorScheme in [.light, .dark] {
            let t = tokens(polarity)
            XCTAssertNotEqual(t.toolCard, t.enclosure, "precondition (\(polarity)): with a palette the two grounds differ, which is what makes this test mean anything")
            let stops = ApprovalSheetView.gateVeilStops(t)
            XCTAssertEqual(stops.first?.color, t.toolCard.opacity(0), "\(polarity): the veil fades in from a colour that is not the block's ground")
            XCTAssertEqual(stops.last?.color, t.toolCard, "\(polarity): the veil is not the command block's ground, so it reads as a band over the text")
        }
    }

    func testTheVeilIsSolidUnderTheCue() throws {
        let stops = ApprovalSheetView.gateVeilStops(tokens(.dark))
        let solid = try XCTUnwrap(stops.last)
        XCTAssertLessThanOrEqual(solid.location, 0.6, "the veil reaches solid only at its bottom edge, so command text shows through the cue")
    }
}
