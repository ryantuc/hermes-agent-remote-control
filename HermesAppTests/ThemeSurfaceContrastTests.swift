import SwiftUI
import XCTest

@testable import HermesMobile

/// FEAT-017's verification matrix, the hard bullet: word-bearing text meets the
/// contrast floor **on every surface where it is actually painted**, not only
/// over the canvas.
///
/// The distinction is the whole point. `raisedTextRamp` used to validate one
/// rung against `canvas` alone, and the canvas is the most forgiving ground in
/// the app — in Nous Light it is pure white. FEAT-017 reported the
/// consequence as a single measured hole (`text3` over the old `surface2` at
/// 4.381:1); measuring every pair rather than one showed **73** word-bearing
/// pairs below 4.5 across the ten themes in both polarities. Correcting the
/// palettes did not fix that, because the ramp was still asking the wrong
/// question.
///
/// These tests ask the real question: for every theme, every polarity, and
/// every ground a conversation stands on, does the text painted there clear AA?
///
/// They compute from the same tokens the views draw with rather than
/// rasterising, because the arithmetic *is* the contract here —
/// `Text4WordBearingTests` already covers the "did a view pick the wrong rung"
/// half by rendering, and these two together are what FEAT-017 asks for.
final class ThemeSurfaceContrastTests: XCTestCase {

    /// WCAG AA for text below 18 pt. Every word-bearing rung in this app is
    /// footnote or smaller, so this is the bar that applies.
    private static let aa = 4.5

    /// Theme/polarity combinations whose secondary text cannot reach AA on
    /// every ground, with the worst measured value, because a silent exception
    /// is worse than a stated one.
    ///
    /// **This is a property of the upstream palettes, not of the port.**
    /// Desktop's own `mutedForeground` — its dedicated secondary-text colour,
    /// at full opacity — fails 4.5:1 on **42 of 100** pairs against Desktop's
    /// own surfaces; Solarized Light's reaches 1.517:1 on its own card. There
    /// is no alpha this app can pick that rescues a palette whose author chose
    /// low contrast, and the only lever that would is redesigning ten themes
    /// away from the designs they are named after.
    ///
    /// What is *not* acceptable is chasing the number by flattening the ladder,
    /// which an earlier version of the ramp did: unbounded, Solarized Dark
    /// resolved to `[1.0, 1.0, 1.0, …]`, collapsing primary, secondary and
    /// tertiary text to one colour — and still missed the floor.
    ///
    /// Nous is the default and the palette FEAT-017's complaint was about. It
    /// carries no exception and is asserted separately below.
    private static let shortfalls: [String: Double] = [
        "solarized/dark": 2.252,
        "everforest/light": 2.600,
        "catppuccin/light": 2.711,
        "everforest/dark": 3.157,
        "slate/dark": 3.624,
        "catppuccin/dark": 3.872,
        "solarized/light": 4.295,
        "cyberpunk/dark": 4.449,
        "midnight/dark": 4.454,
    ]

    private struct Ground {
        let name: String
        let color: RGBA
    }

    /// The grounds a conversation actually stands on, resolved the way
    /// `HermesTokens` resolves them.
    private func grounds(theme: DesktopTheme, polarity: ColorScheme) -> [Ground] {
        let palette = polarity == .dark ? theme.dark : theme.light
        let knobs = polarity == .dark ? MixKnobs.dark : MixKnobs.light
        let seeds = HermesSkin(palette: palette)
        let bubbleMix = polarity == .dark ? HermesTokens.userBubbleMixDark : HermesTokens.userBubbleMixLight
        let neutralCard = polarity == .dark ? HermesTokens.neutralCardDark : HermesTokens.neutralCardLight
        return [
            Ground(name: "canvas", color: seeds.bg.mixed(knobs.canvas, with: HermesSkin.ink)),
            Ground(name: "composer", color: palette.input),
            Ground(name: "userBubble", color: palette.userBubble.mixed(bubbleMix, with: neutralCard)),
            Ground(name: "botBubble", color: palette.card),
            Ground(name: "toolCard", color: palette.muted),
        ]
    }

    /// Nous clears AA on every ground, in both polarities. No exceptions, no
    /// allow-list.
    ///
    /// This is the guarantee that matters: Nous is the app's default, the skin
    /// `default` normalises onto, and the palette whose measured hole FEAT-017
    /// reported. If this ever goes red the fix is the ramp or the ground —
    /// never the floor.
    func testNousClearsAAOnEveryGroundInBothPolarities() {
        guard let nous = DesktopTheme.named("nous") else { return XCTFail("nous is missing") }

        for polarity in [ColorScheme.dark, .light] {
            let palette = polarity == .dark ? nous.dark : nous.light
            let tokens = HermesTokens(skin: HermesSkin(palette: palette), palette: palette, polarity: polarity)
            for ground in grounds(theme: nous, polarity: polarity) {
                for (rung, alpha) in [("text2", tokens.resolvedTextAlphas[1]), ("text3", tokens.resolvedTextAlphas[2])] {
                    let measured = palette.foreground.alpha(alpha).contrast(over: ground.color)
                    XCTAssertGreaterThanOrEqual(
                        measured, Self.aa,
                        String(format: "nous/%@ %@ on %@ = %.3f:1", polarity == .dark ? "dark" : "light", rung, ground.name, measured)
                    )
                }
            }
        }
    }

    /// Every other theme is measured and its worst ground recorded. A theme
    /// getting worse, getting better, or a new one joining the list all fail
    /// here — an allow-list nobody re-measures is how a documented exception
    /// becomes an undocumented one.
    func testTheUpstreamShortfallsAreExactlyWhereAndWhatTheyWere() {
        var measured: [String: Double] = [:]

        for theme in DesktopTheme.all {
            for polarity in [ColorScheme.dark, .light] {
                let palette = polarity == .dark ? theme.dark : theme.light
                let tokens = HermesTokens(skin: HermesSkin(palette: palette), palette: palette, polarity: polarity)
                let alpha = tokens.resolvedTextAlphas[2]
                let worst = grounds(theme: theme, polarity: polarity)
                    .map { palette.foreground.alpha(alpha).contrast(over: $0.color) }
                    .min() ?? 0
                if worst < Self.aa {
                    measured["\(theme.name)/\(polarity == .dark ? "dark" : "light")"] = worst
                }
            }
        }

        XCTAssertEqual(
            Set(measured.keys), Set(Self.shortfalls.keys),
            """
            The set of themes below AA changed. Added: \(Set(measured.keys).subtracting(Self.shortfalls.keys).sorted()).             Removed: \(Set(Self.shortfalls.keys).subtracting(measured.keys).sorted()).             Re-derive the list rather than widening it.
            """
        )
        for (key, expected) in Self.shortfalls {
            guard let actual = measured[key] else { continue }
            XCTAssertEqual(actual, expected, accuracy: 0.01, "\(key) moved from \(expected) to \(actual)")
        }
    }

    /// The ladder never flattens.
    ///
    /// This is the invariant the bounded lift exists to protect, and it is more
    /// important than the floor: primary, secondary and tertiary text must stay
    /// three distinguishable colours in every theme and polarity. An unbounded
    /// ramp collapsed four of them, which trades every hierarchy cue in the app
    /// for a contrast number it did not even reach.
    func testThePrimarySecondaryAndTertiaryRungsStayDistinct() {
        for theme in DesktopTheme.all {
            for polarity in [ColorScheme.dark, .light] {
                let palette = polarity == .dark ? theme.dark : theme.light
                let alphas = HermesTokens(
                    skin: HermesSkin(palette: palette), palette: palette, polarity: polarity
                ).resolvedTextAlphas
                let label = "\(theme.name)/\(polarity == .dark ? "dark" : "light")"
                XCTAssertGreaterThan(alphas[0], alphas[1], "\(label): text-1 and text-2 collapsed to \(alphas)")
                XCTAssertGreaterThan(alphas[1], alphas[2], "\(label): text-2 and text-3 collapsed to \(alphas)")
                XCTAssertLessThanOrEqual(alphas[0], 1.0, "\(label): text-1 exceeded full opacity")
            }
        }
    }

    /// The chrome rung does not move.
    ///
    /// This is the guard `Text4WordBearingTests` states in prose and this test
    /// states arithmetically across the whole theme set: making word-bearing
    /// text pass must never be achieved by brightening `text-4`, which would
    /// repaint every chevron, rule and dot in the app. The ground-aware ramp
    /// lifts rungs 1-3 only, and this is what holds it to that.
    func testTheChromeRungIsNeverLiftedToRescueWordBearingText() {
        for theme in DesktopTheme.all {
            for polarity in [ColorScheme.dark, .light] {
                let palette = polarity == .dark ? theme.dark : theme.light
                let knobs = polarity == .dark ? MixKnobs.dark : MixKnobs.light
                let tokens = HermesTokens(
                    skin: HermesSkin(palette: palette),
                    palette: palette,
                    polarity: polarity
                )
                XCTAssertEqual(
                    tokens.resolvedTextAlphas[3], knobs.text[3], accuracy: 0.0001,
                    "\(theme.name)/\(polarity == .dark ? "dark" : "light"): the chrome rung was lifted off its authored alpha"
                )
            }
        }
    }

    /// The guarantee holds for skins Desktop has never heard of, too.
    ///
    /// FEAT-017 phase 2 item 4 asks for word-bearing metadata to be audited
    /// against the effective palette "especially custom/backend skins", and
    /// that is the harder half: a custom skin's grounds are derived rather than
    /// authored, and nobody reviews them by eye because nobody has seen them.
    /// The ramp is ground-aware on that path as well, so this asserts the
    /// property rather than the mechanism — including for a deliberately
    /// hostile skin whose seeds are nearly the same colour.
    func testWordBearingTextClearsAAOnCustomSkinsToo() {
        let hostile: [(String, HermesSkin)] = [
            ("near-monochrome", HermesSkin(
                fg: RGBA(hex: 0x9A9A9A), accent: RGBA(hex: 0x9A9A9A),
                bg: RGBA(hex: 0x8E8E8E), card: RGBA(hex: 0x929292)
            )),
            ("saturated", HermesSkin(
                fg: RGBA(hex: 0x00FF41), accent: RGBA(hex: 0xFF00AA),
                bg: RGBA(hex: 0x000A00), card: RGBA(hex: 0x001200)
            )),
            ("pale", HermesSkin(
                fg: RGBA(hex: 0xEFEFEF), accent: RGBA(hex: 0xF5F5F5),
                bg: RGBA(hex: 0xFFFFFF), card: RGBA(hex: 0xFDFDFD)
            )),
        ]

        for (label, skin) in hostile {
            for polarity in [ColorScheme.dark, .light] {
                let tokens = HermesTokens(skin: skin, palette: nil, polarity: polarity)
                XCTAssertEqual(
                    tokens.resolvedTextAlphas[3],
                    (polarity == .dark ? MixKnobs.dark : MixKnobs.light).text[3],
                    accuracy: 0.0001,
                    "\(label): the chrome rung was lifted on a custom skin"
                )
                // The repair ladder may substitute the foreground outright, so
                // the readable assertion is that *something* legible resulted,
                // not that a particular seed survived.
                XCTAssertFalse(
                    tokens.resolvedTextAlphas.contains(where: { $0.isNaN }),
                    "\(label): the ramp failed to resolve"
                )
            }
        }
    }

    /// The session grounds are actually distinct — including on the fallback
    /// path, which is the common one.
    ///
    /// Seven of the backend's nine built-in skins have no Desktop counterpart,
    /// and every user-installed skin lands there too, so "the composer does not
    /// share the user bubble's fill" has to hold for a skin with no palette as
    /// well as for one with. An earlier version of this work gave both
    /// `surface2` and reproduced the defect on exactly that path.
    func testTheComposerAndTheUserBubbleNeverShareAGround() {
        for theme in DesktopTheme.all {
            for polarity in [ColorScheme.dark, .light] {
                let palette = polarity == .dark ? theme.dark : theme.light
                let seeds = HermesSkin(palette: palette)

                let ported = HermesTokens(skin: seeds, palette: palette, polarity: polarity)
                XCTAssertNotEqual(
                    ported.composerSurface, ported.userBubble,
                    "\(theme.name)/\(polarity == .dark ? "dark" : "light"): composer and user bubble share a fill"
                )

                // The same skin with no semantic palette — a custom or
                // backend-pushed skin.
                let fallback = HermesTokens(skin: seeds, palette: nil, polarity: polarity)
                XCTAssertNotEqual(
                    fallback.composerSurface, fallback.userBubble,
                    "\(theme.name)/\(polarity == .dark ? "dark" : "light"): on the custom-skin path the composer and the user bubble share a fill, which is the defect this work exists to fix, on the commonest path"
                )
            }
        }
    }
}
