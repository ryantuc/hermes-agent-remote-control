import Foundation
import XCTest

@testable import HermesMobile

/// **The sync mechanism for `DesktopThemePalette.swift`.**
///
/// That file is generated data: 520 colour values copied out of `hermes-agent` at
/// revision `de25a6971d8ec8c5f3d0739433f9c6212fc884e0`. Generated data goes stale
/// silently, and the thing it goes stale against — Desktop's `presets.ts` — lives
/// in another repository, in another language, on another release cadence. Nothing
/// in a build will ever notice.
///
/// So the point of this class is not "does the port work". It is to write down, in
/// a form that fails, every claim the port makes about Desktop: which themes exist
/// and in what order, what five of Nous's colours actually are, that light is
/// lighter than dark, that the two polarities are genuinely different palettes,
/// and that the synthesized-light algorithm reproduces the values embedded beside
/// it. `SkinPresets` carried the claim "same names, same hex seeds" in a doc
/// comment while handing one palette to both polarities of five of its six themes.
/// A comment cannot enforce a set or a value. These can.
///
/// When one of these fails, the question is always which side moved. Re-extract
/// from the revision in `DesktopTheme.sourceRevision`, regenerate, and the diff
/// answers it.
final class DesktopThemePaletteTests: XCTestCase {

    /// Every colour field, paired with its name, so the two tests that have to walk
    /// a whole palette can name the field that failed instead of reporting an
    /// opaque struct inequality. In `colorFieldOrder`.
    ///
    /// Both callers assert this is 26 entries long before using it: a key path
    /// dropped from this table would quietly stop testing a field, which is the
    /// same failure the whole class exists to prevent.
    private static let fields: [(name: String, path: KeyPath<DesktopPalette, RGBA>)] = [
        ("background", \.background),
        ("foreground", \.foreground),
        ("card", \.card),
        ("cardForeground", \.cardForeground),
        ("muted", \.muted),
        ("mutedForeground", \.mutedForeground),
        ("popover", \.popover),
        ("popoverForeground", \.popoverForeground),
        ("primary", \.primary),
        ("primaryForeground", \.primaryForeground),
        ("secondary", \.secondary),
        ("secondaryForeground", \.secondaryForeground),
        ("accent", \.accent),
        ("accentForeground", \.accentForeground),
        ("border", \.border),
        ("input", \.input),
        ("ring", \.ring),
        ("midground", \.midground),
        ("midgroundForeground", \.midgroundForeground),
        ("composerRing", \.composerRing),
        ("destructive", \.destructive),
        ("destructiveForeground", \.destructiveForeground),
        ("sidebarBackground", \.sidebarBackground),
        ("sidebarBorder", \.sidebarBorder),
        ("userBubble", \.userBubble),
        ("userBubbleBorder", \.userBubbleBorder),
    ]

    private func hex(_ value: UInt32) -> String { String(format: "#%06x", value) }

    // MARK: 1 — the roster

    /// **The drift alarm.** Ten themes, in Desktop's registry order.
    ///
    /// Asserted against a literal rather than against a count or a `Set`, because
    /// all three ways this can drift matter and only a literal catches all three:
    /// Desktop adding a theme, Desktop retiring one, and Desktop reordering the
    /// registry — which is what every one of its pickers renders, so a reorder is
    /// visible to users even though no colour changed.
    ///
    /// Note this is *not* `presets.ts` declaration order. That order opens with
    /// `github` and ends `cyberpunk, slate`; `BUILTIN_THEMES` is what the UI walks.
    /// If a future extraction takes the declaration order by mistake, this fails,
    /// which is the point.
    func testTheThemeRosterIsDesktopsTenBuiltInsInRegistryOrder() {
        XCTAssertEqual(DesktopTheme.all.map(\.name), [
            "nous",
            "github",
            "catppuccin",
            "everforest",
            "solarized",
            "midnight",
            "ember",
            "mono",
            "slate",
            "cyberpunk",
        ], """
            the built-in theme roster no longer matches Desktop's. Either Desktop \
            added, retired or reordered a theme and this file needs regenerating \
            from a newer revision, or the generator dropped one. Re-extract from \
            \(DesktopTheme.sourceRevision) and diff
            """)
    }

    // MARK: 2 — the anchors

    /// Five spot values of Nous Light, transcribed by hand from the extraction.
    ///
    /// The whole table was machine-generated from one JSON file, so a systematic
    /// error in the generator — a swapped polarity, an off-by-one field shift, a
    /// channel-order bug — would be applied uniformly to all 520 values and would
    /// look perfectly self-consistent. These five are the independent check on
    /// that: they were read off Desktop's source by eye, not by the generator, and
    /// they cover both ends of the field order (`background`, `userBubble`) and the
    /// accent that everything else is derived from.
    func testNousLightAnchorColours() {
        let nous = DesktopTheme.named("nous")
        XCTAssertNotNil(nous, "the default skin is missing from the table")
        guard let light = nous?.light else { return }

        XCTAssertEqual(hex(light.background.hex), "#ffffff", "nous light background")
        XCTAssertEqual(hex(light.foreground.hex), "#1f2328", "nous light foreground")
        XCTAssertEqual(hex(light.card.hex), "#f6f8fa", "nous light card")
        XCTAssertEqual(hex(light.primary.hex), "#0053fd", "nous light primary")
        XCTAssertEqual(hex(light.userBubble.hex), "#dae7fd", "nous light userBubble")
    }

    // MARK: 3 — the anchors, other polarity

    /// The same five fields of Nous Dark.
    ///
    /// Paired with the light anchors deliberately. If the generator ever emitted
    /// one polarity into both slots — the exact bug `SkinPresets` shipped — these
    /// two tests disagree loudly, and they name the field, which the whole-palette
    /// comparison in test 5 cannot.
    func testNousDarkAnchorColours() {
        guard let dark = DesktopTheme.named("nous")?.dark else {
            return XCTFail("the default skin is missing from the table")
        }

        XCTAssertEqual(hex(dark.background.hex), "#0d1117", "nous dark background")
        XCTAssertEqual(hex(dark.foreground.hex), "#e6edf3", "nous dark foreground")
        XCTAssertEqual(hex(dark.card.hex), "#010409", "nous dark card")
        XCTAssertEqual(hex(dark.primary.hex), "#4a84fe", "nous dark primary")
        XCTAssertEqual(hex(dark.userBubble.hex), "#07162c", "nous dark userBubble")
    }

    // MARK: 4 — polarity is the right way round

    /// Every light background is lighter than its own dark background.
    ///
    /// This is the test that catches an inverted mix. `RGBA.mixed(_:with:)` takes
    /// the percentage as the weight of the **receiver**, which is the opposite of
    /// `color-mix()` and the opposite of Desktop's `mix(a, b, amount)` where
    /// `amount` weights `b`. Write `RGBA(hex: 0xFFFFFF).mixed(0.10, with: accent)`
    /// intending "10% accent over white" and you get 90% accent instead: the
    /// synthesized light palettes come out near-black, every one of them, and
    /// nothing else in the file looks wrong. Luminance is the cheap total order
    /// that notices.
    ///
    /// Gamma-corrected WCAG luminance, not Desktop's naive `luminance()` — the
    /// naive one exists in `color.ts` only to bucket a palette as light or dark for
    /// the rendered-mode override, and it is not the right measure of "lighter".
    func testEveryLightBackgroundIsLighterThanItsDarkBackground() {
        XCTAssertEqual(DesktopTheme.all.count, 10)

        for theme in DesktopTheme.all {
            XCTAssertGreaterThan(
                theme.light.background.luminance,
                theme.dark.background.luminance,
                """
                \(theme.name): the light background is not lighter than the dark one \
                (light \(hex(theme.light.background.hex)) at \(theme.light.background.luminance), \
                dark \(hex(theme.dark.background.hex)) at \(theme.dark.background.luminance)). \
                Either the two palettes are swapped, or a synthesized light palette was \
                mixed with the weights inverted — `mixed(_:with:)` weights the receiver
                """
            )
        }
    }

    // MARK: 5 — two palettes, not one

    /// No theme hands the same palette to both polarities.
    ///
    /// This is the regression `SkinPresets` actually shipped: `single(...)` built
    /// one `HermesSkin` and passed it as both `dark:` and `light:` for five of six
    /// themes, so those themes rendered dark chrome in light mode and the doc
    /// comment above them said that was intentional parity with Desktop. It was
    /// not — Desktop synthesizes a light variant for exactly those themes. Any
    /// future shortcut of the same shape fails here.
    func testNoThemeReusesOnePaletteForBothPolarities() {
        for theme in DesktopTheme.all {
            XCTAssertNotEqual(theme.light, theme.dark, """
                \(theme.name) has an identical light and dark palette. Desktop never \
                does this: the five authored-pair themes carry two hand-tuned palettes \
                and the five dark-only themes get a synthesized light one
                """)
        }
    }

    // MARK: 6 — the algorithm reproduces the data

    /// `synthesizedLight(darkPalette:)` rebuilds the embedded light palette of all
    /// five dark-only themes, byte for byte, on all 26 fields.
    ///
    /// The port keeps the same value twice on purpose — precomputed in the table so
    /// the data file is self-contained and readable, and as a live function because
    /// a backend skin can arrive dark-only too. Two copies of a value is two things
    /// that can disagree, so this is the test that makes the duplication safe.
    ///
    /// **Exact hex equality, not a tolerance.** It is achievable because the port
    /// does the arithmetic where Desktop does it: in 0...255 `Double` space, in the
    /// same expression order, rounding to a byte at the end, rather than
    /// interpolating in `RGBA`'s 0...1 space and never quantising. The two are not
    /// interchangeable — cyberpunk's `sidebarBackground` red channel is exactly
    /// 237.5, and the 0...1 route lands a hair below it and rounds down to `#ed`
    /// where Desktop rounds up to `#ee`. One byte on one field of one theme, which
    /// is precisely the kind of thing a 1/255 tolerance would have hidden.
    func testSynthesizedLightReproducesTheEmbeddedLightPalettes() {
        XCTAssertEqual(Self.fields.count, 26, "the field table lost an entry and is no longer testing every field")

        let darkOnly = DesktopTheme.all.filter(\.lightIsSynthesized)
        XCTAssertEqual(darkOnly.count, 5, """
            expected five dark-only themes; with none the loop below passes vacuously
            """)

        for theme in darkOnly {
            let recomputed = DesktopTheme.synthesizedLight(darkPalette: theme.dark)
            for (name, path) in Self.fields {
                let expected = theme.light[keyPath: path].hex
                let actual = recomputed[keyPath: path].hex
                XCTAssertEqual(hex(actual), hex(expected), """
                    \(theme.name).\(name): the ported `synthLightColors` disagrees with the \
                    value generated from Desktop. Either the algorithm drifted or the table did
                    """)
            }
        }
    }

    // MARK: 7 — which themes are which

    /// Five authored pairs, five dark-only.
    ///
    /// `lightIsSynthesized` is the flag a picker reads to decide whether it can
    /// honestly offer a theme in light mode, so getting it backwards is a UI bug
    /// rather than a colour bug and none of the colour tests would see it. Pinning
    /// both halves by name also means a Desktop theme changing category — an
    /// authored light palette added to `mono`, say — surfaces here rather than
    /// silently reclassifying.
    func testTheAuthoredPairsAndTheDarkOnlyThemesAreLabelledCorrectly() {
        let authored = DesktopTheme.all.filter { !$0.lightIsSynthesized }.map(\.name)
        let synthesized = DesktopTheme.all.filter(\.lightIsSynthesized).map(\.name)

        XCTAssertEqual(authored, ["nous", "github", "catppuccin", "everforest", "solarized"], """
            these are the themes Desktop ships with two hand-authored palettes
            """)
        XCTAssertEqual(synthesized, ["midnight", "ember", "mono", "slate", "cyberpunk"], """
            these are the themes Desktop ships dark-only, whose light palette it \
            synthesizes at runtime from the theme's own `ring`
            """)
    }

    // MARK: 8 — backend names

    /// `normalizedName` maps the wire's skin names onto the table.
    ///
    /// Three groups, and the third is the one worth stating. `default` is what a
    /// profile with no skin opinion reports and it is by far the commonest value on
    /// the wire; `nous-light` and `gold` are skins Desktop retired but the backend
    /// still stores. All three are `nous`.
    ///
    /// The nil group is real backend skin names — `charizard`, `poseidon`,
    /// `sisyphus`, `ares`, `daylight`, `warm-lightmode` all ship in
    /// `$HERMES_HOME/skins/` and none has a Desktop counterpart. nil is not a
    /// failure signal here, it is the instruction to run the backend's own four
    /// seeds through the generic converter and keep the backend's name in the
    /// picker. Answering `nous` for them — which is what Desktop's own
    /// `normalizeSkin` does, because by then it has already registered a converted
    /// theme under that name — would repaint a user's custom skin as the default.
    func testNormalizedNameResolvesRetiredNamesAndRejectsUnknownOnes() {
        for retired in ["default", "nous-light", "gold", "DEFAULT"] {
            XCTAssertEqual(DesktopTheme.normalizedName(retired), "nous", """
                \(retired) is a retired skin name and must land on the default skin
                """)
        }

        XCTAssertEqual(DesktopTheme.normalizedName("mono"), "mono")
        XCTAssertEqual(DesktopTheme.normalizedName("slate"), "slate")

        for unknown in ["charizard", "poseidon", "sisyphus", "ares", "daylight", "warm-lightmode"] {
            XCTAssertNil(DesktopTheme.normalizedName(unknown), """
                \(unknown) is a backend skin with no Desktop counterpart. Answering with a \
                built-in name here would paint it in somebody else's colours
                """)
        }

        XCTAssertNil(DesktopTheme.normalizedName(""), """
            an empty skin name is an absent one. Every string off this wire is coerced \
            with a `""` fallback, so a field that failed to decode must not resolve to a theme
            """)
    }

    // MARK: 9 — nothing is transparent

    /// All 520 values are fully opaque.
    ///
    /// Desktop's palettes are 6-digit `#rrggbb` throughout — its theme system has
    /// no alpha at all, and the transparency the UI shows is mixed in downstream by
    /// `styles.css`. On this side, a field arriving with `a != 1` does not look
    /// wrong in the table and does not fail any other test here; it fails in the
    /// app, silently, by disappearing through the token derivation, which composites
    /// with alpha and would blend a border away to nothing. Cheaper to assert.
    func testEveryFieldOfEveryPaletteIsOpaque() {
        XCTAssertEqual(Self.fields.count, 26, "the field table lost an entry and is no longer testing every field")

        var checked = 0
        for theme in DesktopTheme.all {
            for (polarity, palette) in [("light", theme.light), ("dark", theme.dark)] {
                for (name, path) in Self.fields {
                    checked += 1
                    XCTAssertEqual(palette[keyPath: path].a, 1, """
                        \(theme.name).\(polarity).\(name) is not opaque. Desktop's palettes \
                        carry no alpha; this field would fade out through the token derivation
                        """)
                }
            }
        }
        XCTAssertEqual(checked, 520, "expected ten themes x two polarities x 26 fields")
    }
}
