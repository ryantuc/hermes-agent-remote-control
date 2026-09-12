import HermesServeKit
import SwiftUI

/// Turns the backend's `resolve_skin()` dict into the two polarity seeds the design system needs, pure and free-standing so it is exercisable without a socket (BUG-046).
///
/// Per `hermes_cli/skin_engine.py`, an empty paired block means the skin has no hand-tuned variant for that polarity, so an empty block is absent rather than present-and-useless, and a non-empty one is an overlay over `colors` rather than a replacement.
enum BackendSkinProjection {

    /// Nil when the payload carries no usable colours at all; a caller that gets nil must leave the previous snapshot alone rather than half-clearing it.
    static func snapshot(name: String, raw: JSONValue) -> BackendSkinSnapshot? {
        guard case .object = raw else { return nil }
        let base = object(raw["colors"])
        guard let dark = seeds(base: base, overlay: object(raw["dark_colors"]), darkCardMix: 0.96),
              let light = seeds(base: base, overlay: object(raw["light_colors"]), darkCardMix: 0.975)
        else { return nil }
        return BackendSkinSnapshot(name: name, dark: dark, light: light)
    }

    /// An empty object and an absent key are the same thing here: both mean no hand-tuned variant.
    private static func object(_ value: JSONValue?) -> [String: JSONValue] {
        guard let value, case .object(let dictionary) = value, !dictionary.isEmpty else { return [:] }
        return dictionary
    }

    /// The seed pick order is ported verbatim from `hermes-web/src/lib/skin.ts`, because the web client and the phone have to agree about what a skin looks like.
    private static func seeds(
        base: [String: JSONValue],
        overlay: [String: JSONValue],
        darkCardMix: Double
    ) -> HermesSkin? {
        let colors = base.merging(overlay) { _, fromOverlay in fromOverlay }
        func pick(_ keys: [String]) -> RGBA? {
            for key in keys {
                if let hex = colors[key]?.coercedString, let rgba = RGBA(css: hex) { return rgba }
            }
            return nil
        }
        guard let bg = pick(["background", "status_bar_bg"]),
              let fg = pick(["ui_text", "banner_text", "status_bar_text"]) else { return nil }
        let accent = pick(["ui_accent", "banner_accent", "banner_title"]) ?? fg
        // card ← mix(bg, fg, 0.04) dark / 0.025 light — mostly bg, a trace of fg.
        let card = bg.mixed(darkCardMix, with: fg)
        return HermesSkin(fg: fg, accent: accent, bg: bg, card: card)
    }
}

// MARK: - Skin colour parsing

/// This file is the only place a skin colour string is parsed.
fileprivate extension RGBA {
    /// Parse a skin colour string: skins ship hex (`#RGB`, `#RRGGBB`, `#RRGGBBAA`), and anything else returns nil so the seed falls back.
    init?(css: String) {
        var s = css.trimmingCharacters(in: .whitespaces)
        guard s.hasPrefix("#") else { return nil }
        s.removeFirst()
        if s.count == 3 { s = s.map { "\($0)\($0)" }.joined() }
        guard s.count == 6 || s.count == 8, let value = UInt32(s, radix: 16) else { return nil }
        if s.count == 8 {
            self.init(
                r: Double((value >> 24) & 0xFF) / 255,
                g: Double((value >> 16) & 0xFF) / 255,
                b: Double((value >> 8) & 0xFF) / 255,
                a: Double(value & 0xFF) / 255
            )
        } else {
            self.init(hex: value)
        }
    }
}
