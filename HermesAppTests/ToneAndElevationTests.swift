import SwiftUI
import XCTest

@testable import HermesMobile

/// The two polarities were two different designs.
///
/// Strokes and fills. Light tinted every stroke and fill from the accent (`HermesTokens.swift:110`, `tintIsAccent: true`) while dark tinted them from the foreground (`:101`), so every neutral control in light (segmented rows, secondary buttons, New conversation, the skin cards, the composer's circles) was pale blue beside a grey model pill, and the same controls in dark were grey.
///
/// Raised surfaces. Dark derived every surface by pulling the card seed toward ink, and Desktop's Nous and GitHub dark card seeds (`#010409`) are darker than their background, so `surface2` resolved below the canvas: code blocks, tables and the model pill read as holes in dark where they read as raised cards in light.
///
/// Measured from the resolved tokens across every built-in theme, because these are token properties and every view inherits them.
@MainActor
final class ToneAndElevationTests: XCTestCase {

    private func tokens(_ palette: DesktopPalette, _ polarity: ColorScheme) -> HermesTokens {
        HermesTokens(skin: HermesSkin(palette: palette), palette: palette, polarity: polarity)
    }

    private func label(_ theme: DesktopTheme, _ polarity: ColorScheme) -> String {
        "\(theme.name)/\(polarity == .dark ? "dark" : "light")"
    }

    // MARK: Item 3 — one tint in both polarities

    /// In Nous light, the app's default, a neutral control's ground and every rule are grey: laid over the white canvas, no fill or stroke carries more than a few levels of chroma.
    func testNousLightStrokesAndFillsAreNeutral() {
        let t = tokens(.nousLight, .light)
        let canvas = RGBA(resolving: t.canvas)
        let named: [(String, Color)] = [
            ("fill1", t.fill1), ("fill2", t.fill2), ("fill3", t.fill3), ("fill4", t.fill4), ("fill5", t.fill5),
            ("stroke1", t.stroke1), ("stroke2", t.stroke2), ("stroke3", t.stroke3), ("stroke4", t.stroke4),
        ]
        for (name, color) in named {
            let painted = RGBA(resolving: color).composited(over: canvas)
            XCTAssertLessThanOrEqual(
                painted.chromaLevels, 4,
                "Nous light \(name) paints \(painted) over the canvas: \(String(format: "%.1f", painted.chromaLevels)) levels of chroma, an accent tint on a neutral control"
            )
        }
    }

    /// Both polarities tint from the same seed: in every built-in theme, light's `fill2` leans the way its foreground does, exactly as dark's does, rather than the way its accent does.
    func testBothPolaritiesTintFillsFromTheForeground() {
        for theme in DesktopTheme.all {
            for polarity in [ColorScheme.light, .dark] {
                let palette = polarity == .dark ? theme.dark : theme.light
                let t = tokens(palette, polarity)
                let fill = RGBA(resolving: t.fill2)
                let text = RGBA(resolving: t.text1)
                XCTAssertTrue(
                    fill.isNear(text.alpha(fill.a), tolerance: 0.002),
                    "\(label(theme, polarity)): fill2 \(fill) is not the foreground \(text.alpha(1)) the text is drawn in"
                )
            }
        }
    }

    // MARK: Item 4 — elevation reads the same way in both polarities

    /// In dark, each elevated surface is lighter than the canvas it stands on, and the steps keep their order: sheet and enclosure, then the wells, code blocks and pills (`surface2`), then `surface3`.
    func testDarkSurfacesRiseAboveTheCanvasInEveryBuiltInTheme() {
        for theme in DesktopTheme.all {
            let t = tokens(theme.dark, .dark)
            assertRises(t, label(theme, .dark))
        }
    }

    /// The same holds for skins Desktop has never heard of, which take the derived surfaces as their session grounds too.
    func testDarkSurfacesRiseAboveTheCanvasForCustomSkins() {
        let skins: [(String, HermesSkin)] = [
            ("backend default", HermesSkin(
                fg: RGBA(hex: 0xE8E6E3), accent: RGBA(hex: 0xD89B04),
                bg: RGBA(hex: 0x0B0B0F), card: RGBA(hex: 0x0B0B0F).mixed(0.96, with: RGBA(hex: 0xE8E6E3))
            )),
            ("backend mono", HermesSkin(
                fg: RGBA(hex: 0xEAEAEA), accent: RGBA(hex: 0xEAEAEA),
                bg: RGBA(hex: 0x0E0E0E), card: RGBA(hex: 0x141414)
            )),
            ("card below background", HermesSkin(
                fg: RGBA(hex: 0xE6EDF3), accent: RGBA(hex: 0x4A84FE),
                bg: RGBA(hex: 0x0D1117), card: RGBA(hex: 0x010409)
            )),
        ]
        for (name, skin) in skins {
            assertRises(HermesTokens(skin: skin, palette: nil, polarity: .dark), name)
        }
    }

    /// Light is untouched by the raised-surface rule: there a raised card is the darker one, and it already was.
    func testLightSurfacesStillSitBelowTheCanvas() {
        for theme in DesktopTheme.all {
            let t = tokens(theme.light, .light)
            let canvas = RGBA(resolving: t.canvas).luminance
            XCTAssertLessThan(RGBA(resolving: t.surface2).luminance, canvas, "\(label(theme, .light)): surface2 rose above the canvas")
        }
    }

    private func assertRises(_ t: HermesTokens, _ name: String, file: StaticString = #filePath, line: UInt = #line) {
        let canvas = RGBA(resolving: t.canvas)
        let surface = RGBA(resolving: t.surface)
        let enclosure = RGBA(resolving: t.enclosure)
        let surface2 = RGBA(resolving: t.surface2)
        let surface3 = RGBA(resolving: t.surface3)
        // A step the eye can find on a phone in a dim room, and not a mere rounding difference: 1.04:1 for the sheet ground, 1.08:1 for the wells, code blocks and pills.
        XCTAssertGreaterThanOrEqual(surface.contrast(over: canvas), 1.04, "\(name): surface \(surface) does not rise above canvas \(canvas)", file: file, line: line)
        XCTAssertGreaterThan(surface.luminance, canvas.luminance, "\(name): surface \(surface) sits below canvas \(canvas)", file: file, line: line)
        XCTAssertGreaterThanOrEqual(surface2.contrast(over: canvas), 1.08, "\(name): surface2 \(surface2) does not rise above canvas \(canvas)", file: file, line: line)
        XCTAssertGreaterThan(surface2.luminance, canvas.luminance, "\(name): surface2 \(surface2) sits below canvas \(canvas)", file: file, line: line)
        XCTAssertGreaterThanOrEqual(enclosure.luminance, surface.luminance, "\(name): enclosure \(enclosure) under surface \(surface)", file: file, line: line)
        XCTAssertGreaterThan(surface2.luminance, enclosure.luminance, "\(name): surface2 \(surface2) under enclosure \(enclosure)", file: file, line: line)
        XCTAssertGreaterThan(surface3.luminance, surface2.luminance, "\(name): surface3 \(surface3) under surface2 \(surface2)", file: file, line: line)
    }
}
