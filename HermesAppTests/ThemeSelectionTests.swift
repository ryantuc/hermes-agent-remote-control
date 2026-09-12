import SwiftUI
import XCTest

@testable import HermesMobile

/// BUG-046, first half: **two controls can both be true, and the UI shows the
/// one that lost.**
///
/// "Follow backend skin" and the local skin grid are separate pieces of state.
/// `Theme.skin(for:)` resolves in favour of the backend whenever Follow is on;
/// both settings views resolve their *display* in favour of the local name,
/// always. So tapping a card while Follow is on moves the selection ring and
/// changes nothing on screen, which is the reported defect, and it is a
/// state-authority defect rather than a palette one.
///
/// These tests pin the source of truth: what is painted and what is shown as
/// selected must be the same skin, and choosing a skin by hand must be the act
/// that takes the source back from the backend.
///
/// They talk to `Theme` directly rather than through a hosted view. The
/// question here is which value wins, and a rendered pixel would only tell us
/// that more slowly.
@MainActor
final class ThemeSelectionTests: XCTestCase {

    private var theme: Theme!

    override func setUp() {
        super.setUp()
        for key in ["hermes.theme.polarity", "hermes.theme.followBackendSkin", "hermes.theme.localSkin"] {
            UserDefaults.standard.removeObject(forKey: key)
        }
        theme = Theme()
    }

    override func tearDown() {
        theme = nil
        for key in ["hermes.theme.polarity", "hermes.theme.followBackendSkin", "hermes.theme.localSkin"] {
            UserDefaults.standard.removeObject(forKey: key)
        }
        super.tearDown()
    }

    /// A stand-in for what the backend pushes: two opaque seeds per polarity,
    /// distinguishable from any local preset so a test can tell which one won.
    private func applyBackend(name: String) {
        theme.applyBackendSkin(BackendSkinSnapshot(
            name: name,
            dark: HermesSkin(
                fg: RGBA(hex: 0xEAEAEA), accent: RGBA(hex: 0xEAEAEA),
                bg: RGBA(hex: 0x0E0E0E), card: RGBA(hex: 0x141414)
            ),
            light: HermesSkin(
                fg: RGBA(hex: 0x1F1F1F), accent: RGBA(hex: 0x3A3A3A),
                bg: RGBA(hex: 0xFAFAFA), card: RGBA(hex: 0xF0F0F0)
            )
        ))
    }

    // MARK: 1 — Follow on reports the backend's skin, not the remembered one

    /// With Follow on, the grid must highlight what is painted. The remembered
    /// local choice is still remembered — it is simply not what is on screen.
    ///
    /// `default` is the backend's own name for its skin and Desktop resolves it
    /// to Nous rather than to the classic terminal gold (`backend-sync.ts`
    /// skips registration for it, and `RETIRED_SKINS` maps it onto nous). The
    /// phone has to agree, or "Follow backend" means something different on the
    /// two clients sitting next to each other.
    func testFollowOnReportsTheBackendSkinAndNotTheRememberedLocalChoice() {
        theme.localSkinName = "ember"
        theme.followBackendSkin = true
        applyBackend(name: "default")

        XCTAssertEqual(
            theme.effectiveSkinName, "nous",
            """
            Follow is on and the backend named `default`, so the grid must \
            highlight Nous — the skin that is actually painted. It reported \
            "\(theme.effectiveSkinName)", the local choice, which is the losing \
            state being displayed as authoritative.
            """
        )
    }

    /// The bug as it is actually hit: Light appearance, Follow on,
    /// backend on its own `default`. The reported symptom was a brown/gold
    /// palette that no card could change.
    ///
    /// Asserts the *painted* colour, not just the name. `default`'s light
    /// overlay really is the classic terminal goldenrod (`#F5F5F5` ground,
    /// `#5C4718` ink, `#D89B04` accent, verified in `hermes_cli/skin_engine.py`
    /// at `de25a6971d`), so a test that only checked the name would still pass
    /// with brown on screen — which is precisely how this shipped.
    func testFollowingTheBackendDefaultInLightPaintsNousAndNeverTheTerminalGold() {
        theme.polarityPreference = .light
        theme.followBackendSkin = true
        theme.applyBackendSkin(BackendSkinSnapshot(
            name: "default",
            dark: HermesSkin(
                fg: RGBA(hex: 0xE8E6E3), accent: RGBA(hex: 0xD89B04),
                bg: RGBA(hex: 0x0B0B0F), card: RGBA(hex: 0x121212)
            ),
            light: HermesSkin(
                fg: RGBA(hex: 0x5C4718), accent: RGBA(hex: 0xD89B04),
                bg: RGBA(hex: 0xF5F5F5), card: RGBA(hex: 0xF1F1EF)
            )
        ))

        let painted = theme.skin(for: .light)
        XCTAssertEqual(
            painted.bg.hex, DesktopTheme.named("nous")?.light.background.hex,
            "Light + Follow + backend `default` is painting the CLI's own light overlay instead of resolving to Desktop's Nous — this is the brown"
        )
        XCTAssertNotEqual(painted.fg.hex, 0x5C4718, "the terminal's brown ink is on screen")
        XCTAssertNotEqual(painted.accent.hex, 0xD89B04, "the terminal's gold accent is on screen")
        XCTAssertEqual(painted.accent.hex, 0x0053FD, "Nous Light's action colour is Nous blue")

        // And the dark polarity of the same followed skin resolves the same way,
        // so the answer does not depend on which way the phone happens to be set.
        XCTAssertEqual(theme.skin(for: .dark).bg.hex, DesktopTheme.named("nous")?.dark.background.hex)
    }

    /// The same defect one layer up: the Settings root's summary row, which is
    /// the only place most of this state is visible without opening Appearance.
    func testTheSettingsSummaryReportsTheSkinThatIsPainted() {
        theme.localSkinName = "ember"
        theme.followBackendSkin = true
        applyBackend(name: "mono")

        XCTAssertEqual(
            theme.effectiveSkinLabel, "Mono",
            "the summary row named the remembered local skin while the backend's was on screen"
        )
    }

    // MARK: 2 — choosing a skin is what takes the source back

    /// One operation, two effects, and they cannot come apart: picking a card
    /// means "I want this one", which necessarily means "stop following".
    /// Leaving those as two independent writes is what produced a selected card
    /// that paints nothing.
    func testSelectingALocalSkinTurnsFollowOffAndRepaintsImmediately() {
        theme.followBackendSkin = true
        applyBackend(name: "mono")

        theme.selectLocalSkin("ember")

        XCTAssertFalse(
            theme.followBackendSkin,
            "choosing a skin by hand left Follow on, so the backend keeps overriding the choice"
        )
        XCTAssertEqual(theme.effectiveSkinName, "ember")

        let painted = theme.skin(for: .dark)
        XCTAssertNotEqual(
            painted.bg.hex, 0x0E0E0E,
            "the card was selected but the painted background is still the backend's"
        )
    }

    // MARK: 3 — Follow is a source switch, not a destructive one

    /// Turning Follow back on hands the source to the backend without
    /// forgetting the local choice, so turning it off again returns to the
    /// last local choice rather than to a default.
    func testTurningFollowBackOnShowsTheBackendSkinAndKeepsTheLocalChoice() {
        theme.selectLocalSkin("ember")
        applyBackend(name: "default")

        theme.followBackendSkin = true

        XCTAssertEqual(theme.effectiveSkinName, "nous", "Follow came back on but the grid still highlights the local skin")
        XCTAssertEqual(
            theme.localSkinName, "ember",
            "the remembered local choice was destroyed by following the backend; turning Follow off would land somewhere the user never chose"
        )

        theme.followBackendSkin = false
        XCTAssertEqual(theme.effectiveSkinName, "ember", "turning Follow off did not return to the remembered choice")
    }

    // MARK: 8 — a custom backend skin stays truthful

    /// The backend's built-in skins are `default`, `ares`, `mono`, `slate`,
    /// `daylight`, `warm-lightmode`, `poseidon`, `sisyphus` and `charizard`,
    /// and a user can install more. Only `mono` and `slate` share a name with
    /// a Desktop theme. So the ordinary case is a backend skin with **no** card
    /// in the grid, and the honest answer is to say its name rather than to
    /// light up an unrelated card.
    func testAnUnknownBackendSkinKeepsItsOwnNameInsteadOfHighlightingAPreset() {
        theme.followBackendSkin = true
        applyBackend(name: "charizard")

        XCTAssertEqual(
            theme.effectiveSkinName, "charizard",
            "an unknown backend skin was reported as some local preset, which claims a palette the phone is not painting"
        )
        XCTAssertEqual(
            theme.effectiveSkinLabel, "Charizard",
            "a custom backend skin should be labelled by its own name, not silently relabelled to a preset"
        )
    }

    /// The truthful-custom-skin gate has three parts and the row that renders it
    /// depends on all three: Follow on, a non-empty effective name, and no local
    /// card by that name. Pinned here because the row itself lives in a view
    /// that no test hosts.
    func testTheBackendRowAppearsOnlyForASkinWithNoCardOfItsOwn() {
        theme.followBackendSkin = true
        applyBackend(name: "charizard")
        XCTAssertNil(SkinPreset.named(theme.effectiveSkinName), "a custom backend skin must not resolve to a local card")

        // A backend skin Desktop *does* know keeps its card and gets no row.
        applyBackend(name: "mono")
        XCTAssertNotNil(SkinPreset.named(theme.effectiveSkinName), "`mono` is a Desktop theme and should highlight its own card")

        // `default` normalises onto Nous, which has a card, so no row either.
        applyBackend(name: "default")
        XCTAssertEqual(theme.effectiveSkinName, "nous")
        XCTAssertNotNil(SkinPreset.named(theme.effectiveSkinName))

        // Follow off: no row regardless of what the backend last said.
        theme.selectLocalSkin("ember")
        XCTAssertFalse(theme.followBackendSkin)
        XCTAssertNotNil(SkinPreset.named(theme.effectiveSkinName))
    }

    /// Polarity is client-local and stays that way. It is the one part of this
    /// screen that already works, and the fix must not
    /// entangle it with the skin source while rearranging everything around it.
    func testPolarityRemainsClientLocalAcrossASkinSourceChange() {
        theme.polarityPreference = .light
        theme.followBackendSkin = true
        applyBackend(name: "mono")
        XCTAssertEqual(theme.resolvedScheme(system: .dark), .light)

        theme.selectLocalSkin("ember")
        XCTAssertEqual(
            theme.resolvedScheme(system: .dark), .light,
            "choosing a skin changed the polarity, which is client-local and belongs to the user"
        )
    }
}
