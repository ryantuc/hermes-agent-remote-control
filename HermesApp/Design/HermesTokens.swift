import SwiftUI

// MARK: - Layer 1: seeds

/// The only runtime input to the colour system: four colours every surface, stroke, fill and text step is derived from.
///
/// `danger`, `warn` and `ok` are deliberately not here — they are pinned, because a skin-derived danger would be invisible in a monochrome skin.
public struct HermesSkin: Equatable, Sendable {
    public var fg: RGBA
    public var accent: RGBA
    public var bg: RGBA
    public var card: RGBA

    /// The deepening base. Never comes from a skin.
    static let ink = RGBA(hex: 0x07070B)

    /// Nous, reduced to seeds, read from the ported Desktop palette rather than restated here.
    public static let nousDark = HermesSkin(palette: .nousDark)
    public static let nousLight = HermesSkin(palette: .nousLight)

    public static func `default`(for polarity: ColorScheme) -> HermesSkin {
        polarity == .dark ? .nousDark : .nousLight
    }
}

/// Plain component storage so mixing happens in one predictable space rather than through `Color`, which cannot be inspected.
public struct RGBA: Equatable, Sendable {
    public var r: Double, g: Double, b: Double, a: Double

    public init(r: Double, g: Double, b: Double, a: Double = 1) {
        self.r = r; self.g = g; self.b = b; self.a = a
    }

    public init(hex: UInt32, alpha: Double = 1) {
        r = Double((hex >> 16) & 0xFF) / 255
        g = Double((hex >> 8) & 0xFF) / 255
        b = Double(hex & 0xFF) / 255
        a = alpha
    }

    /// `color-mix(in srgb, self percent, other)` in straight sRGB, so it resolves to the same literals as the desktop's CSS.
    public func mixed(_ percent: Double, with other: RGBA) -> RGBA {
        let t = min(max(percent, 0), 1)
        return RGBA(
            r: r * t + other.r * (1 - t),
            g: g * t + other.g * (1 - t),
            b: b * t + other.b * (1 - t),
            a: a * t + other.a * (1 - t)
        )
    }

    public func alpha(_ value: Double) -> RGBA {
        RGBA(r: r, g: g, b: b, a: value)
    }

    public var color: Color { Color(.sRGB, red: r, green: g, blue: b, opacity: a) }

    /// The round trip of `init(hex:)`, dropping alpha, so a skin can be handed to the widget extension, which cannot see the app's `Theme`.
    public var hex: UInt32 {
        func channel(_ value: Double) -> UInt32 {
            UInt32((min(max(value, 0), 1) * 255).rounded())
        }
        return channel(r) << 16 | channel(g) << 8 | channel(b)
    }

    /// WCAG relative luminance, used by the fallback ladder.
    public var luminance: Double {
        func channel(_ c: Double) -> Double {
            c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(r) + 0.7152 * channel(g) + 0.0722 * channel(b)
    }

    /// Contrast of `self` composited over `background`.
    public func contrast(over background: RGBA) -> Double {
        let composited = mixed(a, with: background.alpha(1))
        let l1 = max(composited.luminance, background.luminance)
        let l2 = min(composited.luminance, background.luminance)
        return (l1 + 0.05) / (l2 + 0.05)
    }
}

// MARK: - Layer 2: per-mode mix knobs

/// The only thing that differs between polarities: dark pulls the card seed toward ink, light keeps surfaces near full strength and tints from the accent.
struct MixKnobs {
    let canvas: Double, canvasDeep: Double
    let surface: Double, surface2: Double, surface3: Double, enclosure: Double
    let text: [Double]
    let stroke: [Double]
    let fill: [Double]
    /// What strokes and fills are tinted with.
    let tintIsAccent: Bool

    static let dark = MixKnobs(
        canvas: 0.40, canvasDeep: 0.33,
        surface: 0.45, surface2: 0.56, surface3: 0.74, enclosure: 0.50,
        text: [0.94, 0.72, 0.52, 0.36],
        stroke: [0.22, 0.14, 0.09, 0.05],
        fill: [0.04, 0.07, 0.12, 0.18, 0.26],
        tintIsAccent: false
    )

    static let light = MixKnobs(
        canvas: 1.0, canvasDeep: 0.94,
        surface: 1.0, surface2: 0.90, surface3: 0.82, enclosure: 1.0,
        text: [0.94, 0.72, 0.62, 0.44],
        stroke: [0.22, 0.14, 0.12, 0.07],
        fill: [0.04, 0.07, 0.10, 0.16, 0.24],
        tintIsAccent: true
    )
}

// MARK: - Layer 3: derivation

public struct HermesTokens: Equatable, Sendable {
    // Surfaces
    public let canvas, canvasDeep, surface, surface2, surface3, enclosure: Color
    public let scrim, scrimBlocking: Color

    // Text — alpha over the foreground seed, so they compose over any surface
    public let text1, text2, text3, text4: Color

    /// The four text alphas after the ramp has been lifted to clear AA on every ground this skin paints words on; exposed because a `Color` cannot be inspected by the contrast tests.
    public let resolvedTextAlphas: [Double]

    // Stroke and fill
    public let stroke1, stroke2, stroke3, stroke4: Color
    public let fill1, fill2, fill3, fill4, fill5: Color

    // Action
    public let action, actionInk, accent, accentFill: Color

    // Semantics: pinned, never derived and never `.red` / `.orange` / `.green`, which shift under Increase Contrast and under skins.
    public let danger, dangerFill, warn, warnFill, ok, okFill: Color

    // Diff grounds, derived from the semantics so they survive any skin
    public let diffAddGround, diffAddInk, diffRemoveGround, diffRemoveInk: Color

    // MARK: Session grounds
    //
    // The four surfaces a conversation stands on, kept apart on purpose: from Desktop's semantic palette where the skin is one of its built-ins, from the derived surfaces otherwise.
    public let composerSurface, composerStroke, composerFocusStroke: Color
    public let userBubble, userBubbleStroke: Color
    public let botBubble, botBubbleStroke: Color
    public let toolCard, toolCardStroke: Color

    public init(skin rawSkin: HermesSkin, polarity: ColorScheme) {
        self.init(skin: rawSkin, palette: nil, polarity: polarity)
    }

    /// `palette` is Desktop's full semantic palette for a built-in skin and nil for a custom or backend-pushed one; only the session grounds read it.
    public init(skin rawSkin: HermesSkin, palette: DesktopPalette?, polarity: ColorScheme) {
        let knobs = polarity == .dark ? MixKnobs.dark : MixKnobs.light
        let skin = Self.repaired(rawSkin, polarity: polarity, knobs: knobs)
        let ink = HermesSkin.ink
        let fg = skin.fg
        let tint = knobs.tintIsAccent ? skin.accent : skin.fg

        let canvasRGBA = skin.bg.mixed(knobs.canvas, with: ink)

        // The session grounds are resolved before the text ramp because the ramp is checked against them, not against `canvas` alone.
        let surface2RGBA = skin.card.mixed(knobs.surface2, with: ink)
        let surface3RGBA = skin.card.mixed(knobs.surface3, with: ink)
        let enclosureRGBA = skin.card.mixed(knobs.enclosure, with: ink)
        let bubbleMix = polarity == .dark ? Self.userBubbleMixDark : Self.userBubbleMixLight
        let neutralCard = polarity == .dark ? Self.neutralCardDark : Self.neutralCardLight
        // The fallbacks are deliberately four different derived surfaces; in light `surface` and `enclosure` coincide, so the bot bubble and the tool card share a ground and are told apart by the enclosure border.
        let composerSurfaceRGBA = palette?.input ?? surface2RGBA
        let userBubbleRGBA = palette.map { $0.userBubble.mixed(bubbleMix, with: neutralCard) } ?? surface3RGBA
        // Not `surface`: in light it reduces to the raw card seed, which a backend skin puts within about 1.03:1 of the canvas.
        let botBubbleRGBA = palette?.card ?? surface2RGBA
        let toolCardRGBA = palette?.muted ?? enclosureRGBA

        canvas = canvasRGBA.color
        canvasDeep = skin.bg.mixed(knobs.canvasDeep, with: ink).color
        surface = skin.card.mixed(knobs.surface, with: ink).color
        surface2 = skin.card.mixed(knobs.surface2, with: ink).color
        surface3 = skin.card.mixed(knobs.surface3, with: ink).color
        enclosure = skin.card.mixed(knobs.enclosure, with: ink).color

        scrim = RGBA(hex: 0x03081A, alpha: polarity == .dark ? 0.62 : 0.34).color
        // The step up from `scrim` is the only cue that a prompt cannot be dismissed; do not equalise them.
        scrimBlocking = RGBA(hex: 0x03081A, alpha: polarity == .dark ? 0.74 : 0.46).color

        let textAlphas = Self.raisedTextRamp(
            knobs.text,
            fg: fg,
            over: [canvasRGBA, composerSurfaceRGBA, userBubbleRGBA, botBubbleRGBA, toolCardRGBA]
        )
        resolvedTextAlphas = textAlphas
        text1 = fg.alpha(textAlphas[0]).color
        text2 = fg.alpha(textAlphas[1]).color
        text3 = fg.alpha(textAlphas[2]).color
        // text-4 never carries text: chevrons, rules, the unfilled half of a rung indicator.
        text4 = fg.alpha(textAlphas[3]).color

        stroke1 = tint.alpha(knobs.stroke[0]).color
        stroke2 = tint.alpha(knobs.stroke[1]).color
        stroke3 = tint.alpha(knobs.stroke[2]).color
        stroke4 = tint.alpha(knobs.stroke[3]).color

        fill1 = tint.alpha(knobs.fill[0]).color
        fill2 = tint.alpha(knobs.fill[1]).color
        fill3 = tint.alpha(knobs.fill[2]).color
        fill4 = tint.alpha(knobs.fill[3]).color
        fill5 = tint.alpha(knobs.fill[4]).color

        // Rung 5: an accent that cannot carry ink stops being a fill.
        let inkOnAction = polarity == .dark ? skin.bg : RGBA(hex: 0xFCFCFC)
        let accentUsable = skin.accent.contrast(over: inkOnAction) >= 4.5
            || inkOnAction.contrast(over: skin.accent) >= 4.5
        action = (accentUsable ? skin.accent : fg).color
        actionInk = inkOnAction.color
        accent = polarity == .dark ? RGBA(hex: 0x8FB4FF).color : RGBA(hex: 0x0044D6).color
        accentFill = (polarity == .dark ? RGBA(hex: 0x8FB4FF) : RGBA(hex: 0x0044D6)).alpha(0.13).color

        let dangerRGBA = polarity == .dark ? RGBA(hex: 0xFF8A78) : RGBA(hex: 0xC72E4D)
        // #9A5B00 and not the more natural #B26A00, which lands at 4.1:1 and fails.
        let warnRGBA = polarity == .dark ? RGBA(hex: 0xF5B75E) : RGBA(hex: 0x9A5B00)
        let okRGBA = polarity == .dark ? RGBA(hex: 0x6FD69A) : RGBA(hex: 0x1F7A4D)
        danger = dangerRGBA.color
        dangerFill = dangerRGBA.alpha(0.16).color
        warn = warnRGBA.color
        warnFill = warnRGBA.alpha(0.14).color
        ok = okRGBA.color
        okFill = okRGBA.alpha(0.14).color

        diffAddGround = okRGBA.alpha(0.13).color
        diffAddInk = okRGBA.mixed(0.70, with: fg).color
        diffRemoveGround = dangerRGBA.alpha(0.13).color
        diffRemoveInk = dangerRGBA.mixed(0.70, with: fg).color

        // MARK: Session grounds

        if let palette {
            // The rest state is parity; the focus stroke is not — borrowing `composerRing` for the phone's composer is a deliberate divergence, not a port, because a desktop has hover and a persistent caret and a phone has neither.
            composerSurface = composerSurfaceRGBA.color
            composerStroke = palette.border.color
            composerFocusStroke = palette.composerRing.color

            // Desktop mixes the bubble seed over the neutral card at 0 % in light and 46 % in dark, so the authored hex is not the painted colour and the model is ported rather than its endpoint.
            userBubble = userBubbleRGBA.color
            userBubbleStroke = palette.userBubbleBorder.color

            botBubble = botBubbleRGBA.color
            botBubbleStroke = palette.border.color

            // The tool card keeps its enclosure but takes the muted ground, so a settled tool recedes.
            toolCard = toolCardRGBA.color
            toolCardStroke = palette.border.color
        } else {
            composerSurface = composerSurfaceRGBA.color
            composerStroke = tint.alpha(knobs.stroke[1]).color
            composerFocusStroke = (accentUsable ? skin.accent : fg).color
            userBubble = userBubbleRGBA.color
            userBubbleStroke = tint.alpha(knobs.stroke[2]).color
            botBubble = botBubbleRGBA.color
            botBubbleStroke = tint.alpha(knobs.stroke[3]).color
            toolCard = toolCardRGBA.color
            toolCardStroke = tint.alpha(knobs.stroke[2]).color
        }
    }

    /// Desktop's `--theme-mix-bubble`, set per mode and not per theme.
    static let userBubbleMixLight = 0.0
    static let userBubbleMixDark = 0.46

    /// Desktop's `--theme-neutral-card`, the ground the bubble seed is mixed over.
    static let neutralCardLight = RGBA(hex: 0xFCFCFC)
    static let neutralCardDark = RGBA(hex: 0x161618)

    // MARK: Fallback ladder

    /// Rungs 1, 2 and 4: a skin may change the colour of the app, never make it unreadable.
    private static func repaired(
        _ skin: HermesSkin,
        polarity: ColorScheme,
        knobs: MixKnobs
    ) -> HermesSkin {
        var repaired = skin
        let fallback = HermesSkin.default(for: polarity)

        // Rung 1: seeds are forced opaque, because `accentUsable` cannot catch a transparent accent — `contrast(over:)` composites against an opaque ground.
        if repaired.fg.a < 1 { repaired.fg = repaired.fg.alpha(1) }
        if repaired.accent.a < 1 { repaired.accent = repaired.accent.alpha(1) }

        // Rung 2: foreground but no background, so synthesise one from the accent at 8 % over ink, as the desktop's `skin.ts` does.
        if skin.bg.a == 0 {
            repaired.bg = skin.accent.alpha(0.08).mixed(0.08, with: HermesSkin.ink)
        }
        if skin.card.a == 0 { repaired.card = repaired.bg }

        // Rung 4: if text-2 still cannot pass 4.5:1 at full strength, discard the skin foreground and keep the skin accent.
        let canvas = repaired.bg.mixed(knobs.canvas, with: HermesSkin.ink)
        if repaired.fg.alpha(1).contrast(over: canvas) < 4.5 {
            repaired.fg = fallback.fg
        }
        return repaired
    }

    /// Rung 3: walk the word-bearing alphas up in 4 % steps until they pass AA on every ground they are painted on, capped so the ladder can never flatten.
    ///
    /// The cap is load-bearing: unbounded, this resolves some palettes to all-1.0 alphas, collapsing primary, secondary and tertiary text to one colour and still missing the floor. Some palettes therefore stay below AA on some grounds.
    private static func raisedTextRamp(_ ramp: [Double], fg: RGBA, over grounds: [RGBA]) -> [Double] {
        /// Indices 0-2; index 3 is the chrome rung and is deliberately excluded.
        let wordBearing = 0..<3
        /// Where `text-1` would start clamping and the rungs below would begin closing on it.
        let ceiling = max(0, 1.0 - ramp[0])
        func passes(_ alpha: Double) -> Bool {
            grounds.allSatisfy { fg.alpha(alpha).contrast(over: $0) >= 4.5 }
        }
        var lift = 0.0
        while lift + 0.04 <= ceiling + 1e-9, !passes(ramp[2] + lift) || !passes(ramp[1] + lift) {
            lift += 0.04
        }
        guard lift > 0 else { return ramp }
        return ramp.enumerated().map { index, value in
            wordBearing.contains(index) ? min(value + lift, 1.0) : value
        }
    }
}

// MARK: - Backend skin snapshot

/// Both polarities of one backend skin, resolved together.
///
/// BUG-046: a pair rather than two independently-applied halves, because a half-applied change leaves two skins live on one phone.
///
/// Declared beside `Theme` because this file compiles into the Live Activity extension, which must see every type `Theme`'s surface mentions.
public struct BackendSkinSnapshot: Equatable, Sendable {
    public let name: String
    public let dark: HermesSkin
    public let light: HermesSkin

    public init(name: String, dark: HermesSkin, light: HermesSkin) {
        self.name = name
        self.dark = dark
        self.light = light
    }
}

// MARK: - Runtime theme

/// Owns the live skin and hands out resolved tokens.
///
/// Polarity is client-local and never taken from the skin: the payload carries `light_colors` and `dark_colors` so each client can choose.
@MainActor
@Observable
public final class Theme {
    public enum Polarity: String, CaseIterable, Sendable {
        case system, light, dark
    }

    // `@Observable` rewrites tracked stored properties into computed ones, so none of them can carry a `didSet`; persistence lives in the public setter instead.
    private var storedPolarityPreference: Polarity = .system
    public var polarityPreference: Polarity {
        get { storedPolarityPreference }
        set {
            storedPolarityPreference = newValue
            UserDefaults.standard.set(newValue.rawValue, forKey: Self.polarityKey)
        }
    }

    /// Skin selection is client-local: the phone never writes `skin`, because `skin.changed` broadcasts to every client and must not repaint the desktop.
    private var storedFollowBackendSkin: Bool = true
    public var followBackendSkin: Bool {
        get { storedFollowBackendSkin }
        set {
            storedFollowBackendSkin = newValue
            UserDefaults.standard.set(newValue, forKey: Self.followKey)
        }
    }

    /// The locally selected built-in skin name.
    private var storedLocalSkinName: String = "nous"
    public var localSkinName: String {
        get { storedLocalSkinName }
        set {
            storedLocalSkinName = newValue
            UserDefaults.standard.set(newValue, forKey: Self.localSkinKey)
        }
    }

    /// Seeds pushed by the backend on `gateway.ready` and `skin.changed`, nil until one arrives.
    public private(set) var backendDark: HermesSkin?
    public private(set) var backendLight: HermesSkin?
    public private(set) var backendSkinName: String = ""

    private static let polarityKey = "hermes.theme.polarity"
    private static let followKey = "hermes.theme.followBackendSkin"
    private static let localSkinKey = "hermes.theme.localSkin"

    public init() {
        // Assign the backing stores directly: the computed setters would persist while reading persisted values back in.
        if let raw = UserDefaults.standard.string(forKey: Self.polarityKey),
           let stored = Polarity(rawValue: raw) {
            storedPolarityPreference = stored
        }
        if UserDefaults.standard.object(forKey: Self.followKey) != nil {
            storedFollowBackendSkin = UserDefaults.standard.bool(forKey: Self.followKey)
        }
        if let skin = UserDefaults.standard.string(forKey: Self.localSkinKey), !skin.isEmpty {
            storedLocalSkinName = skin
        }
        #if DEBUG
        applyScreenshotOverrides()
        #endif
    }

    #if DEBUG
    /// Appearance fixtures for the screenshot harness.
    ///
    /// Applied in `init` rather than from a view's `.task`, because the first frame already reads this state and a frame-late write is a capturable repaint; the backing stores are written directly so a fixture run does not persist into the simulator.
    private func applyScreenshotOverrides() {
        let arguments = ProcessInfo.processInfo.arguments
        func value(_ flag: String) -> String? {
            guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
            return arguments[index + 1]
        }

        if let name = value("-hermesScreenshotSkin"), !name.isEmpty {
            storedLocalSkinName = name
        }
        if let raw = value("-hermesScreenshotPolarity"), let polarity = Polarity(rawValue: raw) {
            storedPolarityPreference = polarity
        }
        if let raw = value("-hermesScreenshotFollowBackend") {
            storedFollowBackendSkin = (raw == "true")
        }
        // A backend skin without a socket, in the two payload shapes the field actually sends.
        if let name = value("-hermesScreenshotBackendSkin"), !name.isEmpty {
            storedFollowBackendSkin = true
            switch name {
            case "default":
                backendSkinName = "default"
                backendDark = HermesSkin(
                    fg: RGBA(hex: 0xE8E6E3), accent: RGBA(hex: 0xD89B04),
                    bg: RGBA(hex: 0x0B0B0F), card: RGBA(hex: 0x0B0B0F).mixed(0.96, with: RGBA(hex: 0xE8E6E3))
                )
                backendLight = HermesSkin(
                    fg: RGBA(hex: 0x5C4718), accent: RGBA(hex: 0xD89B04),
                    bg: RGBA(hex: 0xF5F5F5), card: RGBA(hex: 0xF5F5F5).mixed(0.975, with: RGBA(hex: 0x5C4718))
                )
            case "mono":
                backendSkinName = "mono"
                let seeds = HermesSkin(
                    fg: RGBA(hex: 0xEAEAEA), accent: RGBA(hex: 0xEAEAEA),
                    bg: RGBA(hex: 0x0E0E0E), card: RGBA(hex: 0x141414)
                )
                backendDark = seeds
                backendLight = seeds
            default:
                // A custom skin with no Desktop counterpart, which exercises the converter.
                backendSkinName = name
                backendDark = HermesSkin(
                    fg: RGBA(hex: 0xFFD8B0), accent: RGBA(hex: 0xFF7A18),
                    bg: RGBA(hex: 0x160800), card: RGBA(hex: 0x1E0E04)
                )
                backendLight = HermesSkin(
                    fg: RGBA(hex: 0x3B1F00), accent: RGBA(hex: 0xC85A00),
                    bg: RGBA(hex: 0xFFF6EC), card: RGBA(hex: 0xFFEFE0)
                )
            }
        }
    }
    #endif

    /// The skin that is actually painted, named: the backend's skin normalised the way Desktop normalises it while Follow is on, the local choice otherwise.
    ///
    /// BUG-046: the single answer both settings surfaces ask, so neither can highlight a card that paints nothing.
    public var effectiveSkinName: String {
        guard followBackendSkin, !backendSkinName.isEmpty else { return localSkinName }
        return Self.normalizedBackendName(backendSkinName)
    }

    /// The label for `effectiveSkinName`; a backend skin with no local card keeps its own name rather than claiming a preset's palette.
    public var effectiveSkinLabel: String {
        let name = effectiveSkinName
        if let preset = SkinPreset.named(name) { return preset.label }
        guard let first = name.first else { return "Nous" }
        return first.uppercased() + name.dropFirst()
    }

    /// Desktop's `RETIRED_SKINS` mapping: `default` is the backend saying "no opinion", so it folds onto nous rather than painting the CLI's goldenrod.
    static func normalizedBackendName(_ name: String) -> String {
        // Trimmed as well as lowercased, as Desktop trims at `ingestBackendSkin`; a name arriving as " default" would otherwise miss both lookups.
        let lowered = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return ["default", "nous-light", "gold"].contains(lowered) ? "nous" : lowered
    }

    /// Choosing a skin from the Appearance grid is one operation: recording the choice and taking the source back from the backend are the same act.
    public func selectLocalSkin(_ name: String) {
        localSkinName = name
        followBackendSkin = false
    }

    public func resolvedScheme(system: ColorScheme) -> ColorScheme {
        switch polarityPreference {
        case .system: return system
        case .light: return .light
        case .dark: return .dark
        }
    }

    /// Desktop's own theme for the effective skin, or nil when Desktop has no theme of that name.
    ///
    /// Desktop's name policy, ported: the backend picks a name and Desktop owns the colours, so a backend skin called `mono` paints Desktop's Mono rather than the CLI's terminal palette.
    public var effectiveDesktopTheme: DesktopTheme? {
        DesktopTheme.named(effectiveSkinName)
    }

    /// The full semantic palette for the effective skin, or nil for a custom backend skin, which selects the derived session grounds.
    public func palette(for polarity: ColorScheme) -> DesktopPalette? {
        guard let theme = effectiveDesktopTheme else { return nil }
        return polarity == .dark ? theme.dark : theme.light
    }

    public func skin(for polarity: ColorScheme) -> HermesSkin {
        if let palette = palette(for: polarity) { return HermesSkin(palette: palette) }
        // With Follow off there is no pushed skin to consider, however odd the stored local name is.
        guard followBackendSkin else { return .default(for: polarity) }
        let pushed = polarity == .dark ? backendDark : backendLight
        return pushed ?? .default(for: polarity)
    }

    public func tokens(for polarity: ColorScheme) -> HermesTokens {
        HermesTokens(skin: skin(for: polarity), palette: palette(for: polarity), polarity: polarity)
    }

    /// Called by AppModel from `gateway.ready` and `skin.changed`; the skin supplies seeds only, and typography in a skin is ignored.
    ///
    /// One assignment, both polarities, no merge: a backend skin change is a snapshot replacing a snapshot.
    public func applyBackendSkin(_ snapshot: BackendSkinSnapshot) {
        backendSkinName = snapshot.name
        backendDark = snapshot.dark
        backendLight = snapshot.light
    }
}

// MARK: - Environment

private struct HermesTokensKey: EnvironmentKey {
    static let defaultValue = HermesTokens(skin: .nousDark, polarity: .dark)
}

public extension EnvironmentValues {
    var hermes: HermesTokens {
        get { self[HermesTokensKey.self] }
        set { self[HermesTokensKey.self] = newValue }
    }
}

/// Resolves the theme once per polarity change and injects the tokens, rather than deriving them inside every view body.
public struct HermesThemeContainer<Content: View>: View {
    @Environment(\.colorScheme) private var systemScheme
    private let theme: Theme
    private let content: Content

    public init(theme: Theme, @ViewBuilder content: () -> Content) {
        self.theme = theme
        self.content = content()
    }

    public var body: some View {
        let scheme = theme.resolvedScheme(system: systemScheme)
        let tokens = theme.tokens(for: scheme)
        content
            .environment(\.hermes, tokens)
            .preferredColorScheme(theme.polarityPreference == .system ? nil : scheme)
            .tint(tokens.action)
            .background(tokens.canvas.ignoresSafeArea())
    }
}

// MARK: - Metrics

/// Spacing, radii and motion. Named rungs, never literals at the call site.
public enum Space {
    /// Optical nudges only — never layout.
    public static let s1: CGFloat = 2
    /// Inside a control: icon to its label.
    public static let s2: CGFloat = 4
    /// Between chips in a row.
    public static let s3: CGFloat = 6
    /// Between sibling controls; between stacked buttons.
    public static let s4: CGFloat = 8
    /// Row padding; padding inside an enclosure.
    public static let s5: CGFloat = 12
    /// **The screen gutter.** Every full-width surface uses this and only this.
    public static let s6: CGFloat = 16
    /// Between messages in the transcript.
    public static let s7: CGFloat = 18
    /// Between a settings group and the next group header.
    public static let s8: CGFloat = 22
    /// Between major sections inside a sheet.
    public static let s9: CGFloat = 32
    /// Bottom pad on a scroller ending at the home indicator.
    public static let s10: CGFloat = 42
}

public enum Radius {
    /// Capability chips, inline code, small badges.
    public static let chip: CGFloat = 6
    /// Buttons, input wells, settings rows, icon-button press states.
    public static let control: CGFloat = 10
    /// **Enclosure.** Tool cards, command blocks, user message fill, secret fields.
    public static let enclosure: CGFloat = 14
    /// Top corners of any bottom-anchored layer.
    public static let sheet: CGFloat = 20
    public static let pill: CGFloat = 999
}

/// Border weights: two rungs, and the second has to be visible across the room without becoming a frame.
public enum Stroke {
    /// Every resting border in the app — wells, cards, rows, the composer at rest.
    public static let hairline: CGFloat = 1
    /// The composer while it holds the keyboard: a phone divergence from Desktop, which has hover and a persistent caret and needs no ring.
    public static let focusRing: CGFloat = 2
}

public enum Hit {
    /// Never smaller. No exceptions.
    public static let min: CGFloat = 44
    /// A committing action.
    public static let commit: CGFloat = 48
}

public enum Motion {
    /// Selection, pressed feedback. Paints in the current frame. Never animated.
    public static let none: Animation? = nil
    /// Chip and toggle state, hold-to-confirm fill.
    public static let quick = Animation.easeOut(duration: 0.12)
    /// Sheet present/dismiss, layer push.
    public static let layer = Animation.easeOut(duration: 0.18)
    /// Full-screen layer, keyboard-driven resize.
    public static let full = Animation.easeInOut(duration: 0.24)
    /// Live indicators, skeleton pulse.
    public static let loop = Animation.easeInOut(duration: 1.6).repeatForever(autoreverses: true)

    /// Reduced motion is honoured per token, not as a global override, because the approval countdown is a width animation that must keep updating.
    public static func layer(reduced: Bool) -> Animation {
        reduced ? .easeOut(duration: 0.09) : layer
    }

    public static func full(reduced: Bool) -> Animation {
        reduced ? .easeOut(duration: 0.09) : full
    }

    public static func loop(reduced: Bool) -> Animation? {
        reduced ? nil : loop
    }
}
