import SwiftUI
import XCTest

@testable import HermesMobile

/// Disabled controls were unreadable in both appearances.
///
/// `PrimaryButtonStyle` disabled as `actionInk` at 45 % on `action` at 18 % (`Primitives.swift:17-21`): white on pale blue in light, navy on navy in dark, which is the gated "Allow once" in `approval-*` and the invisible "Save" in `backend-editor-dark`. The secondary and danger styles faded their label the same way, and the Settings root faded a whole row to 45 % on top of its `text3` value (`SettingsView.swift:296`).
///
/// A disabled control still carries words: it says what it would do once it can. So the label is measured the way `Text4WordBearingTests` measures words, rendered and read back, against the ground it is actually drawn on, and held to the same AA bar. Solid `█` glyphs make the reading the token's colour rather than an anti-aliased edge.
@MainActor
final class DisabledControlLegibilityTests: XCTestCase {
    private static let aa = 4.5
    private static let solid = String(repeating: "\u{2588}", count: 5)
    private let rasteriser = VisualRasteriser()

    override func tearDown() {
        rasteriser.tearDown()
        super.tearDown()
    }

    private func tokens(_ polarity: ColorScheme) -> HermesTokens {
        let palette: DesktopPalette = polarity == .dark ? .nousDark : .nousLight
        return HermesTokens(skin: HermesSkin(palette: palette), palette: palette, polarity: polarity)
    }

    private func name(_ polarity: ColorScheme) -> String { polarity == .dark ? "dark" : "light" }

    /// Renders one disabled button filling a 260 x 48 frame, so the most common colour is the button's own ground.
    private func disabledButton<S: ButtonStyle>(_ style: S, polarity: ColorScheme) -> (ink: RGBA, ground: RGBA) {
        let view = AnyView(
            Button(Self.solid) {}
                .buttonStyle(style)
                .disabled(true)
        )
        let raster = rasteriser.render(view, tokens: tokens(polarity), polarity: polarity, size: CGSize(width: 260, height: 48))
        let ground = raster.dominant
        return (raster.ink(over: ground), ground)
    }

    private func assertLegible<S: ButtonStyle>(_ style: S, _ what: String, file: StaticString = #filePath, line: UInt = #line) {
        for polarity in [ColorScheme.light, .dark] {
            let reading = disabledButton(style, polarity: polarity)
            XCTAssertNotEqual(reading.ink, reading.ground, "\(what) \(name(polarity)): no label was drawn, the measurement is blind", file: file, line: line)
            let contrast = reading.ink.contrast(over: reading.ground)
            XCTAssertGreaterThanOrEqual(
                contrast, Self.aa,
                "disabled \(what) in Nous \(name(polarity)) draws its label at \(String(format: "%.2f", contrast)):1 on its own ground (ink \(reading.ink), ground \(reading.ground))",
                file: file, line: line
            )
        }
    }

    func testADisabledPrimaryButtonsLabelIsLegible() {
        assertLegible(PrimaryButtonStyle(), "primary button")
    }

    func testADisabledSecondaryButtonsLabelIsLegible() {
        assertLegible(SecondaryButtonStyle(), "secondary button")
    }

    func testADisabledDangerButtonsLabelIsLegible() {
        assertLegible(DangerButtonStyle(), "danger button")
    }

    /// A disabled primary is not a faded call to action: it stops wearing the accent, so the colour that says "this is the thing to press" appears only when it can be pressed.
    func testADisabledPrimaryButtonDropsTheAccent() {
        for polarity in [ColorScheme.light, .dark] {
            let ground = disabledButton(PrimaryButtonStyle(), polarity: polarity).ground
            let canvas = RGBA(resolving: tokens(polarity).canvas)
            XCTAssertLessThanOrEqual(
                ground.chromaLevels, canvas.chromaLevels + 4,
                "disabled primary in Nous \(name(polarity)) still carries the accent: ground \(ground), \(String(format: "%.1f", ground.chromaLevels)) levels of chroma against the canvas's \(String(format: "%.1f", canvas.chromaLevels))"
            )
        }
    }

    /// The Settings root's Agent rows with no backend: each one names a screen the reader is being taught exists, so its name stays readable.
    func testADisabledSettingsRowKeepsItsLabelReadable() {
        for polarity in [ColorScheme.light, .dark] {
            let view = AnyView(SettingsValueRowLabel(label: Self.solid, value: "", isEnabled: false))
            let raster = rasteriser.render(view, tokens: tokens(polarity), polarity: polarity, size: CGSize(width: 300, height: 48))
            let ground = raster.dominant
            let ink = raster.ink(over: ground)
            XCTAssertNotEqual(ink, ground, "settings row \(name(polarity)): no label was drawn")
            let contrast = ink.contrast(over: ground)
            XCTAssertGreaterThanOrEqual(
                contrast, Self.aa,
                "a disabled Settings row in Nous \(name(polarity)) draws its label at \(String(format: "%.2f", contrast)):1 (ink \(ink), ground \(ground))"
            )
        }
    }

    /// The control says it is disabled by its rung, not by vanishing: an enabled row's label stays the stronger of the two.
    func testADisabledSettingsRowIsStillVisiblyDisabled() {
        for polarity in [ColorScheme.light, .dark] {
            let size = CGSize(width: 300, height: 48)
            let on = rasteriser.render(AnyView(SettingsValueRowLabel(label: Self.solid, value: "", isEnabled: true)), tokens: tokens(polarity), polarity: polarity, size: size)
            let off = rasteriser.render(AnyView(SettingsValueRowLabel(label: Self.solid, value: "", isEnabled: false)), tokens: tokens(polarity), polarity: polarity, size: size)
            let onContrast = on.ink(over: on.dominant).contrast(over: on.dominant)
            let offContrast = off.ink(over: off.dominant).contrast(over: off.dominant)
            XCTAssertGreaterThan(onContrast, offContrast + 1, "Nous \(name(polarity)): enabled \(onContrast):1 and disabled \(offContrast):1 rows read the same")
        }
    }
}
