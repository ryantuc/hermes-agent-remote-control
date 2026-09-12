import SwiftUI

/// The desktop's ten built-in themes, as the four seeds this app's token derivation runs on.
///
/// Every colour comes from `DesktopThemePalette.swift`; those values are the desktop's `presets.ts` seeds, not its painted result, and callers needing the full semantic palette read `DesktopTheme` directly.
public struct SkinPreset: Identifiable, Sendable, Equatable {
    public let name: String
    public let label: String
    public let blurb: String
    public let dark: HermesSkin
    public let light: HermesSkin

    public var id: String { name }

    /// In Desktop's registry order, which is the order its picker renders.
    public static let all: [SkinPreset] = DesktopTheme.all.map(SkinPreset.init(theme:))

    public static func named(_ name: String) -> SkinPreset? {
        all.first { $0.name == name }
    }

    /// The reduction to four seeds; it takes `primary`, not `accent`, because Desktop's `accent` is a pale surface tint and would leave the UI with no action colour.
    init(theme: DesktopTheme) {
        name = theme.name
        label = theme.label
        blurb = theme.blurb
        dark = HermesSkin(palette: theme.dark)
        light = HermesSkin(palette: theme.light)
    }
}

public extension HermesSkin {
    /// Reduce one of Desktop's semantic palettes to the four seeds.
    init(palette: DesktopPalette) {
        self.init(
            fg: palette.foreground,
            accent: palette.primary,
            bg: palette.background,
            card: palette.card
        )
    }
}
