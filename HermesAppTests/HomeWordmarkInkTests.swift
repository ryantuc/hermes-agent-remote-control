import SwiftUI
import XCTest

@testable import HermesMobile

/// The wordmark on an empty Home was `text1` at 15 % opacity, a ghost in light and barely there in dark, so the empty screen read as one that had not loaded rather than as a calm one.
///
/// It was never Desktop's either. BUG-063's acceptance for this mark was parity ("in substantially the same way the desktop does"), and Desktop draws it `text-midground dark:text-foreground/90` (`apps/desktop/src/components/chat/wordmark.tsx`): a mid rung in light, nearly the foreground in dark.
@MainActor
final class HomeWordmarkInkTests: XCTestCase {

    private func tokens(_ polarity: ColorScheme) -> HermesTokens {
        let palette: DesktopPalette = polarity == .dark ? .nousDark : .nousLight
        return HermesTokens(skin: HermesSkin(palette: palette), palette: palette, polarity: polarity)
    }

    private func contrast(_ polarity: ColorScheme) -> Double {
        let t = tokens(polarity)
        let canvas = RGBA(resolving: t.canvas)
        return RGBA(resolving: HomeChrome.wordmarkInk(t, scheme: polarity)).composited(over: canvas).contrast(over: canvas)
    }

    /// Large display lettering reads at 3:1; the 15 % ghost measured about 1.2:1.
    func testTheWordmarkReadsInLight() {
        XCTAssertGreaterThanOrEqual(contrast(.light), 3, "Nous light: the wordmark is \(String(format: "%.2f", contrast(.light))):1 on the canvas — a ghost, not Desktop's midground")
    }

    func testTheWordmarkReadsInDark() {
        XCTAssertGreaterThanOrEqual(contrast(.dark), 3, "Nous dark: the wordmark is \(String(format: "%.2f", contrast(.dark))):1 on the canvas — Desktop draws it at 90 % of the foreground")
    }

    /// The control: the mark stays quieter than the words people read, in light, where Desktop's midground sits below the foreground.
    func testTheWordmarkStaysBelowTheForegroundInLight() {
        let t = tokens(.light)
        let canvas = RGBA(resolving: t.canvas)
        let foreground = RGBA(resolving: t.text1).composited(over: canvas).contrast(over: canvas)
        XCTAssertLessThan(contrast(.light), foreground, "the mark is decoration and must not out-shout the text under it")
    }
}
