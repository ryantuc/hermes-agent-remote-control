import SwiftUI

// MARK: - Provenance

/// Generated data, do not hand-edit: the ten built-in themes of the Hermes desktop app, extracted from `apps/desktop/src/themes/` at the revision in `sourceRevision` and checked in beside this file at `scripts/desktop-themes.json`.
///
/// The only sync mechanism is `DesktopThemePaletteTests`; when Desktop moves, re-extract, regenerate, and let the test say what changed.
///
/// Optional Desktop fields are stored already resolved through `applyTheme`'s fallbacks, and the five dark-only themes carry a precomputed `synthLightColors` result as their light palette.

// MARK: - A palette

/// One polarity of one theme: Desktop's 26 colour fields in the order `types.ts` declares them, kept so a field-by-field diff against a fresh extraction lines up.
///
/// Every field is opaque; the transparency the UI shows is applied downstream, and a field with `a != 1` would vanish through the token derivation.
public struct DesktopPalette: Equatable, Sendable {
    public let background: RGBA
    public let foreground: RGBA
    public let card: RGBA
    public let cardForeground: RGBA
    public let muted: RGBA
    public let mutedForeground: RGBA
    public let popover: RGBA
    public let popoverForeground: RGBA
    public let primary: RGBA
    public let primaryForeground: RGBA
    public let secondary: RGBA
    public let secondaryForeground: RGBA
    public let accent: RGBA
    public let accentForeground: RGBA
    public let border: RGBA
    public let input: RGBA
    public let ring: RGBA

    /// Desktop's brand-accent token, not `ring`, though all ten built-ins set them equal.
    public let midground: RGBA

    /// Absent from the five dark-only source blocks; filled here with `readableOn(midground)`, as `applyTheme` resolves it.
    public let midgroundForeground: RGBA

    /// Absent from the five dark-only source blocks and from `synthLightColors`; filled here with `midground`, as `applyTheme` resolves it.
    public let composerRing: RGBA
    public let destructive: RGBA
    public let destructiveForeground: RGBA
    public let sidebarBackground: RGBA
    public let sidebarBorder: RGBA
    public let userBubble: RGBA
    public let userBubbleBorder: RGBA

    public init(
        background: RGBA,
        foreground: RGBA,
        card: RGBA,
        cardForeground: RGBA,
        muted: RGBA,
        mutedForeground: RGBA,
        popover: RGBA,
        popoverForeground: RGBA,
        primary: RGBA,
        primaryForeground: RGBA,
        secondary: RGBA,
        secondaryForeground: RGBA,
        accent: RGBA,
        accentForeground: RGBA,
        border: RGBA,
        input: RGBA,
        ring: RGBA,
        midground: RGBA,
        midgroundForeground: RGBA,
        composerRing: RGBA,
        destructive: RGBA,
        destructiveForeground: RGBA,
        sidebarBackground: RGBA,
        sidebarBorder: RGBA,
        userBubble: RGBA,
        userBubbleBorder: RGBA
    ) {
        self.background = background
        self.foreground = foreground
        self.card = card
        self.cardForeground = cardForeground
        self.muted = muted
        self.mutedForeground = mutedForeground
        self.popover = popover
        self.popoverForeground = popoverForeground
        self.primary = primary
        self.primaryForeground = primaryForeground
        self.secondary = secondary
        self.secondaryForeground = secondaryForeground
        self.accent = accent
        self.accentForeground = accentForeground
        self.border = border
        self.input = input
        self.ring = ring
        self.midground = midground
        self.midgroundForeground = midgroundForeground
        self.composerRing = composerRing
        self.destructive = destructive
        self.destructiveForeground = destructiveForeground
        self.sidebarBackground = sidebarBackground
        self.sidebarBorder = sidebarBorder
        self.userBubble = userBubble
        self.userBubbleBorder = userBubbleBorder
    }

    /// The generated table's constructor; colours are written `0xRRGGBB` so this file greps against the extraction's own hex strings.
    init(
        background: UInt32,
        foreground: UInt32,
        card: UInt32,
        cardForeground: UInt32,
        muted: UInt32,
        mutedForeground: UInt32,
        popover: UInt32,
        popoverForeground: UInt32,
        primary: UInt32,
        primaryForeground: UInt32,
        secondary: UInt32,
        secondaryForeground: UInt32,
        accent: UInt32,
        accentForeground: UInt32,
        border: UInt32,
        input: UInt32,
        ring: UInt32,
        midground: UInt32,
        midgroundForeground: UInt32,
        composerRing: UInt32,
        destructive: UInt32,
        destructiveForeground: UInt32,
        sidebarBackground: UInt32,
        sidebarBorder: UInt32,
        userBubble: UInt32,
        userBubbleBorder: UInt32
    ) {
        self.init(
            background: RGBA(hex: background),
            foreground: RGBA(hex: foreground),
            card: RGBA(hex: card),
            cardForeground: RGBA(hex: cardForeground),
            muted: RGBA(hex: muted),
            mutedForeground: RGBA(hex: mutedForeground),
            popover: RGBA(hex: popover),
            popoverForeground: RGBA(hex: popoverForeground),
            primary: RGBA(hex: primary),
            primaryForeground: RGBA(hex: primaryForeground),
            secondary: RGBA(hex: secondary),
            secondaryForeground: RGBA(hex: secondaryForeground),
            accent: RGBA(hex: accent),
            accentForeground: RGBA(hex: accentForeground),
            border: RGBA(hex: border),
            input: RGBA(hex: input),
            ring: RGBA(hex: ring),
            midground: RGBA(hex: midground),
            midgroundForeground: RGBA(hex: midgroundForeground),
            composerRing: RGBA(hex: composerRing),
            destructive: RGBA(hex: destructive),
            destructiveForeground: RGBA(hex: destructiveForeground),
            sidebarBackground: RGBA(hex: sidebarBackground),
            sidebarBorder: RGBA(hex: sidebarBorder),
            userBubble: RGBA(hex: userBubble),
            userBubbleBorder: RGBA(hex: userBubbleBorder)
        )
    }
}

// MARK: - A theme

/// A Desktop built-in: a name, the two strings its picker shows, and both polarities.
///
/// `name` is the wire identity the backend sends; `label` and `blurb` are Desktop's own copy, carried so the phone's picker reads identically.
public struct DesktopTheme: Identifiable, Equatable, Sendable {
    public let name: String
    public let label: String
    public let blurb: String
    public let light: DesktopPalette
    public let dark: DesktopPalette

    /// True for the five themes Desktop ships dark-only, whose `light` is `synthesizedLight(darkPalette:)`'s output rather than something a designer chose.
    public let lightIsSynthesized: Bool

    public var id: String { name }

    public init(
        name: String,
        label: String,
        blurb: String,
        light: DesktopPalette,
        dark: DesktopPalette,
        lightIsSynthesized: Bool
    ) {
        self.name = name
        self.label = label
        self.blurb = blurb
        self.light = light
        self.dark = dark
        self.lightIsSynthesized = lightIsSynthesized
    }

    /// The revision the data below was extracted from; quote it in any bug report about a colour.
    public static let sourceRevision = "de25a6971d8ec8c5f3d0739433f9c6212fc884e0"

    /// In `BUILTIN_THEMES` registry order, which is what every Desktop picker renders, and deliberately not `presets.ts` declaration order.
    public static let all: [DesktopTheme] = [
        DesktopTheme(
            name: "nous",
            label: "Nous",
            blurb: "GitHub chrome, Nous blue accent",
            light: .nousLight,
            dark: .nousDark,
            lightIsSynthesized: false
        ),
        DesktopTheme(
            name: "github",
            label: "GitHub",
            blurb: "GitHub Light Default and Dark Default",
            light: .githubLight,
            dark: .githubDark,
            lightIsSynthesized: false
        ),
        DesktopTheme(
            name: "catppuccin",
            label: "Catppuccin",
            blurb: "Soothing pastels — Latte and Mocha",
            light: .catppuccinLight,
            dark: .catppuccinDark,
            lightIsSynthesized: false
        ),
        DesktopTheme(
            name: "everforest",
            label: "Everforest",
            blurb: "Warm, low-contrast forest greens",
            light: .everforestLight,
            dark: .everforestDark,
            lightIsSynthesized: false
        ),
        DesktopTheme(
            name: "solarized",
            label: "Solarized",
            blurb: "Fixed-contrast light and dark",
            light: .solarizedLight,
            dark: .solarizedDark,
            lightIsSynthesized: false
        ),
        DesktopTheme(
            name: "midnight",
            label: "Midnight",
            blurb: "Deep blue-violet with cool accents",
            light: .midnightLight,
            dark: .midnightDark,
            lightIsSynthesized: true
        ),
        DesktopTheme(
            name: "ember",
            label: "Ember",
            blurb: "Warm crimson and bronze — forge vibes",
            light: .emberLight,
            dark: .emberDark,
            lightIsSynthesized: true
        ),
        DesktopTheme(
            name: "mono",
            label: "Mono",
            blurb: "Clean grayscale — minimal and focused",
            light: .monoLight,
            dark: .monoDark,
            lightIsSynthesized: true
        ),
        DesktopTheme(
            name: "slate",
            label: "Slate",
            blurb: "Cool slate blue — focused developer theme",
            light: .slateLight,
            dark: .slateDark,
            lightIsSynthesized: true
        ),
        DesktopTheme(
            name: "cyberpunk",
            label: "Cyberpunk",
            blurb: "Neon green on black — matrix terminal",
            light: .cyberpunkLight,
            dark: .cyberpunkDark,
            lightIsSynthesized: true
        ),
    ]

    public static func named(_ name: String) -> DesktopTheme? {
        all.first { $0.name == name }
    }

    // MARK: - Name normalisation

    /// Desktop's `RETIRED_SKINS`; the backend still sends all three and all three land on `nous`.
    private static let retiredNames: Set<String> = ["nous-light", "default", "gold"]

    /// Desktop's `normalizeSkin`, with one deliberate divergence: where Desktop answers `nous` for every unresolvable name, the phone returns nil so a user's own skin keeps its name and colours instead of being repainted as the default.
    public static func normalizedName(_ backendName: String) -> String? {
        let key = backendName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if key.isEmpty { return nil }
        if retiredNames.contains(key) { return "nous" }
        return all.contains { $0.name == key } ? key : nil
    }

    // MARK: - The synthesized light palette

    /// Desktop's `synthLightColors`, ported: every value is a hard-coded neutral or a fixed-amount straight-sRGB lerp from one toward `ring`.
    ///
    /// A live function rather than only embedded output, because a backend skin can arrive dark-only too and because the test checks the embedded values against it.
    ///
    /// `ring` needs no fallback here: Desktop's `|| primary` catches an absent or empty field, and a `DesktopPalette` has neither.
    ///
    /// - Parameter darkPalette: the dark-only theme's single authored palette.
    public static func synthesizedLight(darkPalette: DesktopPalette) -> DesktopPalette {
        let accent = darkPalette.ring.hex
        let midground = darkPalette.midground.hex

        let soft = mix(0xFFFFFF, toward: accent, amount: 0.10)
        let softer = mix(0xFFFFFF, toward: accent, amount: 0.06)
        let border = mix(0xECECEF, toward: accent, amount: 0.14)
        // `secondaryForeground` and `accentForeground` are the same expression, which Desktop computes twice.
        let strongForeground = mix(0x2A2A2A, toward: accent, amount: 0.34)

        return DesktopPalette(
            background: 0xFFFFFF,
            foreground: 0x161616,
            card: 0xFFFFFF,
            cardForeground: 0x161616,
            muted: softer,
            mutedForeground: mix(0x6B6B70, toward: accent, amount: 0.16),
            popover: 0xFFFFFF,
            popoverForeground: 0x161616,
            primary: accent,
            primaryForeground: readableOn(accent),
            secondary: soft,
            secondaryForeground: strongForeground,
            accent: soft,
            accentForeground: strongForeground,
            border: border,
            input: mix(0xE2E2E6, toward: accent, amount: 0.18),
            ring: accent,
            midground: midground,
            midgroundForeground: readableOn(midground),
            // `synthLightColors` does not set `composerRing`, so `applyTheme` resolves it to `midground`.
            composerRing: midground,
            destructive: 0xB94A3A,
            destructiveForeground: 0xFFFFFF,
            sidebarBackground: mix(0xFAFAFA, toward: accent, amount: 0.05),
            sidebarBorder: border,
            userBubble: soft,
            userBubbleBorder: border
        )
    }

    /// `color.ts`'s `mix` composed with its `rgbToHex`, in packed-hex space.
    ///
    /// Not `RGBA.mixed`, and the difference is a real byte: Desktop interpolates in 0...255 and rounds before the colour reaches CSS, so a channel landing on a rounding boundary comes out one lower on the 0...1 path.
    ///
    /// - Parameters:
    ///   - base: the hard-coded neutral the lerp starts from.
    ///   - target: the accent it moves toward.
    ///   - amount: the weight of `target`, the opposite convention to `RGBA.mixed(_:with:)`.
    private static func mix(_ base: UInt32, toward target: UInt32, amount: Double) -> UInt32 {
        func channel(_ shift: UInt32) -> UInt32 {
            let b = Double((base >> shift) & 0xFF)
            let t = Double((target >> shift) & 0xFF)
            let mixed = b + (t - b) * amount
            return UInt32(min(255, max(0, mixed)).rounded())
        }
        return channel(16) << 16 | channel(8) << 8 | channel(0)
    }

    /// `color.ts`'s `readableOn`: white or near-black, whichever measures better against `background`, rather than a luminance threshold.
    private static func readableOn(_ background: UInt32) -> UInt32 {
        let bg = RGBA(hex: background)
        let onWhite = bg.contrast(over: RGBA(hex: 0xFFFFFF))
        let onInk = bg.contrast(over: RGBA(hex: 0x161616))
        return onWhite >= onInk ? 0xFFFFFF : 0x161616
    }
}

// MARK: - The palettes

/// The 520 values: twenty palettes, in `themeOrder`, each in `colorFieldOrder`. Regenerate rather than patch.
extension DesktopPalette {
    /// Nous light.
    static let nousLight = DesktopPalette(
        background: 0xFFFFFF,
        foreground: 0x1F2328,
        card: 0xF6F8FA,
        cardForeground: 0x1F2328,
        muted: 0xF6F6F6,
        mutedForeground: 0x656D76,
        popover: 0xFFFFFF,
        popoverForeground: 0x1F2328,
        primary: 0x0053FD,
        primaryForeground: 0xFFFFFF,
        secondary: 0xDEEAFF,
        secondaryForeground: 0x1F2328,
        accent: 0xE3EDFF,
        accentForeground: 0x1F2328,
        border: 0xD0D7DE,
        input: 0xFFFFFF,
        ring: 0x0053FD,
        midground: 0x0053FD,
        midgroundForeground: 0xFFFFFF,
        composerRing: 0x0053FD,
        destructive: 0xCF222E,
        destructiveForeground: 0xFFFFFF,
        sidebarBackground: 0xF6F8FA,
        sidebarBorder: 0xD0D7DE,
        userBubble: 0xDAE7FD,
        userBubbleBorder: 0xD0D7DE
    )

    /// Nous dark.
    static let nousDark = DesktopPalette(
        background: 0x0D1117,
        foreground: 0xE6EDF3,
        card: 0x010409,
        cardForeground: 0xE6EDF3,
        muted: 0x1A1E24,
        mutedForeground: 0x7D8590,
        popover: 0x161B22,
        popoverForeground: 0xE6EDF3,
        primary: 0x4A84FE,
        primaryForeground: 0x161616,
        secondary: 0x1D2E4F,
        secondaryForeground: 0xE6EDF3,
        accent: 0x17243A,
        accentForeground: 0xE6EDF3,
        border: 0x30363D,
        input: 0x0D1117,
        ring: 0x4A84FE,
        midground: 0x4A84FE,
        midgroundForeground: 0x161616,
        composerRing: 0x4A84FE,
        destructive: 0xF85149,
        destructiveForeground: 0xFFFFFF,
        sidebarBackground: 0x010409,
        sidebarBorder: 0x30363D,
        userBubble: 0x07162C,
        userBubbleBorder: 0x30363D
    )

    /// GitHub light.
    static let githubLight = DesktopPalette(
        background: 0xFFFFFF,
        foreground: 0x1F2328,
        card: 0xF6F8FA,
        cardForeground: 0x1F2328,
        muted: 0xF6F6F6,
        mutedForeground: 0x656D76,
        popover: 0xFFFFFF,
        popoverForeground: 0x1F2328,
        primary: 0x196D31,
        primaryForeground: 0xFFFFFF,
        secondary: 0xDFEBE2,
        secondaryForeground: 0x1F2328,
        accent: 0xE3EDE6,
        accentForeground: 0x1F2328,
        border: 0xD0D7DE,
        input: 0xFFFFFF,
        ring: 0x196D31,
        midground: 0x196D31,
        midgroundForeground: 0xFFFFFF,
        composerRing: 0x196D31,
        destructive: 0xCF222E,
        destructiveForeground: 0xFFFFFF,
        sidebarBackground: 0xF6F8FA,
        sidebarBorder: 0xD0D7DE,
        userBubble: 0xDBE7E2,
        userBubbleBorder: 0xD0D7DE
    )

    /// GitHub dark.
    static let githubDark = DesktopPalette(
        background: 0x0D1117,
        foreground: 0xE6EDF3,
        card: 0x010409,
        cardForeground: 0xE6EDF3,
        muted: 0x1A1E24,
        mutedForeground: 0x7D8590,
        popover: 0x161B22,
        popoverForeground: 0xE6EDF3,
        primary: 0x4F9E5E,
        primaryForeground: 0xFFFFFF,
        secondary: 0x1F382B,
        secondaryForeground: 0xE6EDF3,
        accent: 0x192A24,
        accentForeground: 0xE6EDF3,
        border: 0x30363D,
        input: 0x0D1117,
        ring: 0x4F9E5E,
        midground: 0x4F9E5E,
        midgroundForeground: 0xFFFFFF,
        composerRing: 0x4F9E5E,
        destructive: 0xF85149,
        destructiveForeground: 0xFFFFFF,
        sidebarBackground: 0x010409,
        sidebarBorder: 0x30363D,
        userBubble: 0x0F2018,
        userBubbleBorder: 0x30363D
    )

    /// Catppuccin light.
    static let catppuccinLight = DesktopPalette(
        background: 0xEFF1F5,
        foreground: 0x4C4F69,
        card: 0xE6E9EF,
        cardForeground: 0x4C4F69,
        muted: 0xE8EBEF,
        mutedForeground: 0x4C4F69,
        popover: 0xE6E9EF,
        popoverForeground: 0x4C4F69,
        primary: 0x6D2EBF,
        primaryForeground: 0xFFFFFF,
        secondary: 0xDDD6ED,
        secondaryForeground: 0x4C4F69,
        accent: 0xDFDAEF,
        accentForeground: 0x4C4F69,
        border: 0xACB0BE,
        input: 0xCCD0DA,
        ring: 0x6D2EBF,
        midground: 0x6D2EBF,
        midgroundForeground: 0xFFFFFF,
        composerRing: 0x6D2EBF,
        destructive: 0xD20F39,
        destructiveForeground: 0xFFFFFF,
        sidebarBackground: 0xE6E9EF,
        sidebarBorder: 0xACB0BE,
        userBubble: 0xD7D3E9,
        userBubbleBorder: 0xACB0BE
    )

    /// Catppuccin dark.
    static let catppuccinDark = DesktopPalette(
        background: 0x1E1E2E,
        foreground: 0xCDD6F4,
        card: 0x181825,
        cardForeground: 0xCDD6F4,
        muted: 0x29293A,
        mutedForeground: 0xCDD6F4,
        popover: 0x181825,
        popoverForeground: 0xCDD6F4,
        primary: 0xCBA6F7,
        primaryForeground: 0xFFFFFF,
        secondary: 0x4E4466,
        secondaryForeground: 0xCDD6F4,
        accent: 0x3D3652,
        accentForeground: 0xCDD6F4,
        border: 0x585B70,
        input: 0x313244,
        ring: 0xCBA6F7,
        midground: 0xCBA6F7,
        midgroundForeground: 0xFFFFFF,
        composerRing: 0xCBA6F7,
        destructive: 0xF38BA8,
        destructiveForeground: 0xFFFFFF,
        sidebarBackground: 0x181825,
        sidebarBorder: 0x585B70,
        userBubble: 0x38324B,
        userBubbleBorder: 0x585B70
    )

    /// Everforest light.
    static let everforestLight = DesktopPalette(
        background: 0xFDF6E3,
        foreground: 0x5C6A72,
        card: 0xFDF6E3,
        cardForeground: 0x5C6A72,
        muted: 0xF7F0DE,
        mutedForeground: 0x939F91,
        popover: 0xFDF6E3,
        popoverForeground: 0x5C6A72,
        primary: 0x586B35,
        primaryForeground: 0xFFFFFF,
        secondary: 0xE6E3CB,
        secondaryForeground: 0x5C6A72,
        accent: 0xE9E5CE,
        accentForeground: 0x5C6A72,
        border: 0xFDF6E3,
        input: 0xFDF6E3,
        ring: 0x586B35,
        midground: 0x586B35,
        midgroundForeground: 0xFFFFFF,
        composerRing: 0x586B35,
        destructive: 0xF1706F,
        destructiveForeground: 0xFFFFFF,
        sidebarBackground: 0xFDF6E3,
        sidebarBorder: 0xFDF6E3,
        userBubble: 0xE9E5CE,
        userBubbleBorder: 0xFDF6E3
    )

    /// Everforest dark.
    static let everforestDark = DesktopPalette(
        background: 0x2D353B,
        foreground: 0xD3C6AA,
        card: 0x2D353B,
        cardForeground: 0xD3C6AA,
        muted: 0x373E42,
        mutedForeground: 0x859289,
        popover: 0x2D353B,
        popoverForeground: 0xD3C6AA,
        primary: 0xA7C080,
        primaryForeground: 0xFFFFFF,
        secondary: 0x4F5C4E,
        secondaryForeground: 0xD3C6AA,
        accent: 0x434E47,
        accentForeground: 0xD3C6AA,
        border: 0x2D353B,
        input: 0x2D353B,
        ring: 0xA7C080,
        midground: 0xA7C080,
        midgroundForeground: 0xFFFFFF,
        composerRing: 0xA7C080,
        destructive: 0xDA6362,
        destructiveForeground: 0xFFFFFF,
        sidebarBackground: 0x2D353B,
        sidebarBorder: 0x2D353B,
        userBubble: 0x434E47,
        userBubbleBorder: 0x2D353B
    )

    /// Solarized light.
    static let solarizedLight = DesktopPalette(
        background: 0xFDF6E3,
        foreground: 0x1F1F1F,
        card: 0xD3CBB7,
        cardForeground: 0x1F1F1F,
        muted: 0xF4EDDB,
        mutedForeground: 0x9CA8A6,
        popover: 0xEEE8D5,
        popoverForeground: 0x1F1F1F,
        primary: 0x675E34,
        primaryForeground: 0xFFFFFF,
        secondary: 0xE8E1CB,
        secondaryForeground: 0x1F1F1F,
        accent: 0xEBE4CE,
        accentForeground: 0x1F1F1F,
        border: 0xDDD6C1,
        input: 0xDDD6C1,
        ring: 0x675E34,
        midground: 0x675E34,
        midgroundForeground: 0xFFFFFF,
        composerRing: 0x675E34,
        destructive: 0xE25563,
        destructiveForeground: 0xFFFFFF,
        sidebarBackground: 0xEEE8D5,
        sidebarBorder: 0xDDD6C1,
        userBubble: 0xC6BEA7,
        userBubbleBorder: 0xDDD6C1
    )

    /// Solarized dark.
    static let solarizedDark = DesktopPalette(
        background: 0x002B36,
        foreground: 0x839496,
        card: 0x002B36,
        cardForeground: 0x839496,
        muted: 0x08313C,
        mutedForeground: 0x586E75,
        popover: 0x001F26,
        popoverForeground: 0x839496,
        primary: 0x6EA1C4,
        primaryForeground: 0xFFFFFF,
        secondary: 0x1F4C5E,
        secondaryForeground: 0x839496,
        accent: 0x144050,
        accentForeground: 0x839496,
        border: 0x234751,
        input: 0x073642,
        ring: 0x6EA1C4,
        midground: 0x6EA1C4,
        midgroundForeground: 0xFFFFFF,
        composerRing: 0x6EA1C4,
        destructive: 0xE35957,
        destructiveForeground: 0xFFFFFF,
        sidebarBackground: 0x001F26,
        sidebarBorder: 0x234751,
        userBubble: 0x144050,
        userBubbleBorder: 0x234751
    )

    /// Midnight light — synthesized from its `ring` by `synthLightColors`, not authored.
    static let midnightLight = DesktopPalette(
        background: 0xFFFFFF,
        foreground: 0x161616,
        card: 0xFFFFFF,
        cardForeground: 0x161616,
        muted: 0xF8F7FE,
        mutedForeground: 0x706E83,
        popover: 0xFFFFFF,
        popoverForeground: 0x161616,
        primary: 0x8B80E8,
        primaryForeground: 0x161616,
        secondary: 0xF3F2FD,
        secondaryForeground: 0x4B476B,
        accent: 0xF3F2FD,
        accentForeground: 0x4B476B,
        border: 0xDEDDEE,
        input: 0xD2D0E6,
        ring: 0x8B80E8,
        midground: 0x8B80E8,
        midgroundForeground: 0x161616,
        composerRing: 0x8B80E8,
        destructive: 0xB94A3A,
        destructiveForeground: 0xFFFFFF,
        sidebarBackground: 0xF4F4F9,
        sidebarBorder: 0xDEDDEE,
        userBubble: 0xF3F2FD,
        userBubbleBorder: 0xDEDDEE
    )

    /// Midnight dark.
    static let midnightDark = DesktopPalette(
        background: 0x08081C,
        foreground: 0xDDD6FF,
        card: 0x0D0D28,
        cardForeground: 0xDDD6FF,
        muted: 0x13133A,
        mutedForeground: 0x7C7AB0,
        popover: 0x0F0F2E,
        popoverForeground: 0xDDD6FF,
        primary: 0xDDD6FF,
        primaryForeground: 0x08081C,
        secondary: 0x1A1A4A,
        secondaryForeground: 0xC4BFF0,
        accent: 0x1A1A44,
        accentForeground: 0xD0C8FF,
        border: 0x1E1E52,
        input: 0x1E1E52,
        ring: 0x8B80E8,
        midground: 0x8B80E8,
        midgroundForeground: 0x161616,
        composerRing: 0x8B80E8,
        destructive: 0xB03060,
        destructiveForeground: 0xFEF2F2,
        sidebarBackground: 0x06061A,
        sidebarBorder: 0x12123A,
        userBubble: 0x14143A,
        userBubbleBorder: 0x242466
    )

    /// Ember light — synthesized from its `ring` by `synthLightColors`, not authored.
    static let emberLight = DesktopPalette(
        background: 0xFFFFFF,
        foreground: 0x161616,
        card: 0xFFFFFF,
        cardForeground: 0x161616,
        muted: 0xFDF7F1,
        mutedForeground: 0x7D6C62,
        popover: 0xFFFFFF,
        popoverForeground: 0x161616,
        primary: 0xD97316,
        primaryForeground: 0x161616,
        secondary: 0xFBF1E8,
        secondaryForeground: 0x664323,
        accent: 0xFBF1E8,
        accentForeground: 0x664323,
        border: 0xE9DBD1,
        input: 0xE0CEC1,
        ring: 0xD97316,
        midground: 0xD97316,
        midgroundForeground: 0x161616,
        composerRing: 0xD97316,
        destructive: 0xB94A3A,
        destructiveForeground: 0xFFFFFF,
        sidebarBackground: 0xF8F3EF,
        sidebarBorder: 0xE9DBD1,
        userBubble: 0xFBF1E8,
        userBubbleBorder: 0xE9DBD1
    )

    /// Ember dark.
    static let emberDark = DesktopPalette(
        background: 0x160800,
        foreground: 0xFFD8B0,
        card: 0x1E0E04,
        cardForeground: 0xFFD8B0,
        muted: 0x2A1408,
        mutedForeground: 0xAA7A56,
        popover: 0x221008,
        popoverForeground: 0xFFD8B0,
        primary: 0xFFD8B0,
        primaryForeground: 0x160800,
        secondary: 0x341800,
        secondaryForeground: 0xF0C090,
        accent: 0x301600,
        accentForeground: 0xE8C080,
        border: 0x3A1C08,
        input: 0x3A1C08,
        ring: 0xD97316,
        midground: 0xD97316,
        midgroundForeground: 0x161616,
        composerRing: 0xD97316,
        destructive: 0xC43010,
        destructiveForeground: 0xFEF2F2,
        sidebarBackground: 0x100600,
        sidebarBorder: 0x2A1004,
        userBubble: 0x2A1000,
        userBubbleBorder: 0x4A2010
    )

    /// Mono light — synthesized from its `ring` by `synthLightColors`, not authored.
    static let monoLight = DesktopPalette(
        background: 0xFFFFFF,
        foreground: 0x161616,
        card: 0xFFFFFF,
        cardForeground: 0x161616,
        muted: 0xF9F9F9,
        mutedForeground: 0x737377,
        popover: 0xFFFFFF,
        popoverForeground: 0x161616,
        primary: 0x9A9A9A,
        primaryForeground: 0x161616,
        secondary: 0xF5F5F5,
        secondaryForeground: 0x505050,
        accent: 0xF5F5F5,
        accentForeground: 0x505050,
        border: 0xE1E1E3,
        input: 0xD5D5D8,
        ring: 0x9A9A9A,
        midground: 0x9A9A9A,
        midgroundForeground: 0x161616,
        composerRing: 0x9A9A9A,
        destructive: 0xB94A3A,
        destructiveForeground: 0xFFFFFF,
        sidebarBackground: 0xF5F5F5,
        sidebarBorder: 0xE1E1E3,
        userBubble: 0xF5F5F5,
        userBubbleBorder: 0xE1E1E3
    )

    /// Mono dark.
    static let monoDark = DesktopPalette(
        background: 0x0E0E0E,
        foreground: 0xEAEAEA,
        card: 0x141414,
        cardForeground: 0xEAEAEA,
        muted: 0x1E1E1E,
        mutedForeground: 0x808080,
        popover: 0x181818,
        popoverForeground: 0xEAEAEA,
        primary: 0xEAEAEA,
        primaryForeground: 0x0E0E0E,
        secondary: 0x262626,
        secondaryForeground: 0xC8C8C8,
        accent: 0x222222,
        accentForeground: 0xD8D8D8,
        border: 0x2A2A2A,
        input: 0x2A2A2A,
        ring: 0x9A9A9A,
        midground: 0x9A9A9A,
        midgroundForeground: 0x161616,
        composerRing: 0x9A9A9A,
        destructive: 0xA84040,
        destructiveForeground: 0xFEF2F2,
        sidebarBackground: 0x0A0A0A,
        sidebarBorder: 0x202020,
        userBubble: 0x1A1A1A,
        userBubbleBorder: 0x363636
    )

    /// Slate light — synthesized from its `ring` by `synthLightColors`, not authored.
    static let slateLight = DesktopPalette(
        background: 0xFFFFFF,
        foreground: 0x161616,
        card: 0xFFFFFF,
        cardForeground: 0x161616,
        muted: 0xF5FAFF,
        mutedForeground: 0x687487,
        popover: 0xFFFFFF,
        popoverForeground: 0x161616,
        primary: 0x58A6FF,
        primaryForeground: 0x161616,
        secondary: 0xEEF6FF,
        secondaryForeground: 0x3A5472,
        accent: 0xEEF6FF,
        accentForeground: 0x3A5472,
        border: 0xD7E2F1,
        input: 0xC9D7EB,
        ring: 0x58A6FF,
        midground: 0x58A6FF,
        midgroundForeground: 0x161616,
        composerRing: 0x58A6FF,
        destructive: 0xB94A3A,
        destructiveForeground: 0xFFFFFF,
        sidebarBackground: 0xF2F6FA,
        sidebarBorder: 0xD7E2F1,
        userBubble: 0xEEF6FF,
        userBubbleBorder: 0xD7E2F1
    )

    /// Slate dark.
    static let slateDark = DesktopPalette(
        background: 0x0D1117,
        foreground: 0xC9D1D9,
        card: 0x161B22,
        cardForeground: 0xC9D1D9,
        muted: 0x21262D,
        mutedForeground: 0x8B949E,
        popover: 0x1C2128,
        popoverForeground: 0xC9D1D9,
        primary: 0xC9D1D9,
        primaryForeground: 0x0D1117,
        secondary: 0x2A3038,
        secondaryForeground: 0xADB5BF,
        accent: 0x1E2530,
        accentForeground: 0xC0C8D0,
        border: 0x30363D,
        input: 0x30363D,
        ring: 0x58A6FF,
        midground: 0x58A6FF,
        midgroundForeground: 0x161616,
        composerRing: 0x58A6FF,
        destructive: 0xCF4848,
        destructiveForeground: 0xFEF2F2,
        sidebarBackground: 0x090D13,
        sidebarBorder: 0x1C2228,
        userBubble: 0x1E2A38,
        userBubbleBorder: 0x2E4060
    )

    /// Cyberpunk light — synthesized from its `ring` by `synthLightColors`, not authored.
    static let cyberpunkLight = DesktopPalette(
        background: 0xFFFFFF,
        foreground: 0x161616,
        card: 0xFFFFFF,
        cardForeground: 0x161616,
        muted: 0xF0FFF4,
        mutedForeground: 0x5A8368,
        popover: 0xFFFFFF,
        popoverForeground: 0x161616,
        primary: 0x00FF41,
        primaryForeground: 0x161616,
        secondary: 0xE6FFEC,
        secondaryForeground: 0x1C7232,
        accent: 0xE6FFEC,
        accentForeground: 0x1C7232,
        border: 0xCBEFD7,
        input: 0xB9E7C8,
        ring: 0x00FF41,
        midground: 0x00FF41,
        midgroundForeground: 0x161616,
        composerRing: 0x00FF41,
        destructive: 0xB94A3A,
        destructiveForeground: 0xFFFFFF,
        sidebarBackground: 0xEEFAF1,
        sidebarBorder: 0xCBEFD7,
        userBubble: 0xE6FFEC,
        userBubbleBorder: 0xCBEFD7
    )

    /// Cyberpunk dark.
    static let cyberpunkDark = DesktopPalette(
        background: 0x000A00,
        foreground: 0x00FF41,
        card: 0x001200,
        cardForeground: 0x00FF41,
        muted: 0x001A00,
        mutedForeground: 0x1A8A30,
        popover: 0x001000,
        popoverForeground: 0x00FF41,
        primary: 0x00FF41,
        primaryForeground: 0x000A00,
        secondary: 0x002800,
        secondaryForeground: 0x00CC34,
        accent: 0x002000,
        accentForeground: 0x00E038,
        border: 0x003000,
        input: 0x003000,
        ring: 0x00FF41,
        midground: 0x00FF41,
        midgroundForeground: 0x161616,
        composerRing: 0x00FF41,
        destructive: 0xFF003C,
        destructiveForeground: 0x000A00,
        sidebarBackground: 0x000600,
        sidebarBorder: 0x001800,
        userBubble: 0x001400,
        userBubbleBorder: 0x004800
    )
}
