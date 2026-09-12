import SwiftUI
import XCTest

@testable import HermesMobile

/// FEAT-033 — four one-line chrome decisions taken after a check on a device.
///
/// Three of them are rules and are asserted here. The fourth, (c), is the project picker's pinned row and lives with the rest of that derivation in `ProjectPickerHomeRowLabelTests`.
///
/// Nothing here hosts a view. Every one of these decisions is a value the view reads, and a Box-hosted view test can pass vacuously — see `ChatChromeTests` for the longer version of the same argument.
final class WalkTweakChromeTests: XCTestCase {

    // MARK: (a) — the frost, and the rung that was not there

    /// Below 26 the step is real and this is it. Asserted through
    /// `String(describing:)` because `Material` is not `Equatable`; the two
    /// values are produced the same way, so the comparison is stable whatever
    /// the description text turns out to be.
    func testBothRungsNowNameTheThinnestMaterialThereIs() {
        XCTAssertEqual(
            String(describing: ChatChromeMaterial.ultraThinMaterial.frost),
            String(describing: Material.ultraThinMaterial),
            """
            the sub-26 fallback is not `.ultraThinMaterial`. That is the one rung FEAT-033 (a) had \
            to spend — below 26 the app's frost was `.thinMaterial`, which was reported as \
            too milky
            """
        )
        XCTAssertEqual(
            String(describing: ChatChromeMaterial.liquidGlass.frost),
            String(describing: ChatChromeMaterial.ultraThinMaterial.frost),
            "the two cases resolve to different Materials again"
        )
    }

    /// The floor, and the reason it is asserted rather than assumed.
    ///
    /// On iOS 26 `.ultraThinMaterial` was already what the chrome used, so
    /// "one notch less milky" had nowhere to go. The opacity dial was built,
    /// compared against a control from the same build, and measured at 4/255
    /// in light and exactly zero in dark; it was removed rather than shipped. What
    /// remains true is that there is no thinner `Material`, and the next person
    /// asked to thin this frost needs to know that before they try.
    func testTheChromeIsAtTheThinnestMaterialSwiftUIHas() {
        let ladder = [
            Material.ultraThickMaterial, .thickMaterial, .regularMaterial,
            .thinMaterial, .ultraThinMaterial,
        ]
        XCTAssertEqual(
            String(describing: ChatChromeMaterial.current.frost),
            String(describing: ladder.last!),
            """
            the chat chrome is no longer painted in the thinnest Material SwiftUI defines. If this \
            is deliberate it is a taste change and wants its own report; if it is not, someone has \
            reintroduced a rung the frost had already spent
            """
        )
    }

    // MARK: (b) — a draft shows the pencil disabled

    func testAnOrdinaryThreadDrawsAllThreeActionsEnabledInReportOrder() {
        let entries = ChatChrome.overflowEntries(isBotThread: false, isDraft: false)
        XCTAssertEqual(entries.map(\.action), [.details, .rename, .project])
        XCTAssertEqual(entries.map(\.isEnabled), [true, true, true])
    }

    /// The decision is to show it disabled: drawn, in its own place in the
    /// order, and not tappable.
    func testADraftDrawsRenameDisabledRatherThanOmittingIt() {
        let entries = ChatChrome.overflowEntries(isBotThread: false, isDraft: true)
        XCTAssertEqual(entries.map(\.action), [.details, .rename, .project], """
            a draft's overflow is \(entries.map(\.action)). FEAT-033 (b) asks for the pencil to be shown \
            and disabled — a control that appears the second time you open the same header reads as a bug
            """)
        XCTAssertEqual(entries.map(\.isEnabled), [true, false, true], """
            the draft's pencil is enabled. `AppModel.renameThread` needs a stored session id and a draft \
            has none, so tapping it can only ever be silence
            """)
    }

    /// A bot thread's omission is a different rule and it has to survive this
    /// change: its title **is** the registry key the Bot Chat resolver looks it
    /// up by, so Rename there is wrong forever rather than unavailable for now.
    func testABotThreadStillHasNoRenameAtAllEnabledOrOtherwise() {
        for isDraft in [false, true] {
            let entries = ChatChrome.overflowEntries(isBotThread: true, isDraft: isDraft)
            XCTAssertFalse(entries.contains { $0.action == .rename }, """
                a bot thread (isDraft: \(isDraft)) was drawn a Rename control. A greyed one is no better \
                than a live one here — the reason it is missing is not "not yet"
                """)
            XCTAssertEqual(entries.map(\.action), [.details, .project])
            XCTAssertEqual(entries.map(\.isEnabled), [true, true])
        }
    }

    /// The popover is icon-only, so the spoken label is the only text there is.
    /// A disabled control has to say why, because `.disabled` announces
    /// "dimmed" — a state, not a reason.
    func testADisabledEntrySaysWhyAndAnEnabledOneDoesNot() {
        let draft = ChatChrome.overflowEntries(isBotThread: false, isDraft: true)
        guard let pencil = draft.first(where: { $0.action == .rename }) else {
            return XCTFail("the draft's overflow carried no Rename entry to inspect")
        }
        XCTAssertNotEqual(pencil.accessibilityLabel, ChatOverflowAction.rename.accessibilityLabel)
        XCTAssertTrue(
            pencil.accessibilityLabel.hasPrefix(ChatOverflowAction.rename.accessibilityLabel),
            "the disabled label stopped naming the control it is attached to: \(pencil.accessibilityLabel)"
        )
        for entry in ChatChrome.overflowEntries(isBotThread: false, isDraft: false) {
            XCTAssertEqual(entry.accessibilityLabel, entry.action.accessibilityLabel, """
                an enabled \(entry.action) is explaining itself as though it were disabled
                """)
        }
    }

    /// `overflowActions` is still the enabled set and is still what the rule
    /// tests assert. `overflowEntries` adds to it; it must never subtract.
    func testEveryEnabledEntryIsExactlyTheOldActionSet() {
        for isBotThread in [false, true] {
            for isDraft in [false, true] {
                let enabled = ChatChrome.overflowEntries(isBotThread: isBotThread, isDraft: isDraft)
                    .filter(\.isEnabled)
                    .map(\.action)
                XCTAssertEqual(
                    enabled,
                    ChatChrome.overflowActions(isBotThread: isBotThread, isDraft: isDraft),
                    """
                    bot: \(isBotThread), draft: \(isDraft) — the drawn-and-enabled set drifted from the \
                    derivation it is built on
                    """
                )
            }
        }
    }

    // MARK: (d) — the ring, and the plate under the composer

    /// The ring was reported as a little thin. One rung, and the rung has to be visible.
    func testTheFocusRingIsThickerThanTheRestingBorder() {
        XCTAssertGreaterThan(Stroke.focusRing, Stroke.hairline, """
            the composer's focus ring is no heavier than its resting border, which is the state \
            that was reported as too thin
            """)
        XCTAssertEqual(Stroke.hairline, 1, "the resting border moved; only the focused one was asked to")
        XCTAssertLessThanOrEqual(Stroke.focusRing, 3, """
            \(Stroke.focusRing) pt is a frame, not a ring. The control's job is to say the field is live, \
            not to box it in
            """)
    }

    /// *"The composer is round [and] still sits on a square background."* The
    /// plate and the well have to be cut to the same radius, and the check is
    /// against the token rather than a number so the two cannot drift apart.
    func testTheChromePlateIsCutToTheComposersOwnRadius() {
        XCTAssertEqual(ChatChrome.plateCornerRadius, Radius.sheet, """
            the frosted plate under the bottom chrome no longer follows `Radius.sheet`, which is the \
            radius the composer's own well is drawn with and the token whose definition reads "top \
            corners of any bottom-anchored layer"
            """)
        XCTAssertGreaterThan(ChatChrome.plateCornerRadius, 0, """
            the plate is square again. A rounded one-pixel outline on a hard-edged slab is exactly what \
            was reported
            """)
    }

    // MARK: BUG-120 — the black bar, and the hard line under the top bar

    /// The plate has to reach the home indicator, and it must not re-enter the
    /// keyboard's inset negotiation. `.container` is that split. Asserted as
    /// the value the views read, because hosting `ChatView` to watch the well
    /// is a photograph, not a unit test.
    func testTheChromeEscapesOnlyTheHomeIndicatorContainer() {
        XCTAssertEqual(
            ChatChrome.homeIndicatorEscape,
            SafeAreaRegions.container,
            "the chrome is not escaping the home-indicator container"
        )
        XCTAssertNotEqual(
            ChatChrome.homeIndicatorEscape,
            SafeAreaRegions.all,
            "`.all` includes the keyboard, which is the FEAT-024 trap"
        )
        XCTAssertNotEqual(
            ChatChrome.homeIndicatorEscape,
            SafeAreaRegions.keyboard,
            "the chrome must not ignore the keyboard safe area"
        )
    }

    /// A one-pixel fade is a line; a band the size of the header is a second
    /// bar. `Space.s6` is the token in between. This is the top-bar fade, not
    /// a mask on the composer plate.
    func testTheFrostEdgeFadeIsABandNotALineAndNotAPanel() {
        XCTAssertEqual(ChatChrome.frostEdgeFade, Space.s6)
        XCTAssertGreaterThan(ChatChrome.frostEdgeFade, 8, "the fade collapsed to a line")
        XCTAssertLessThan(ChatChrome.frostEdgeFade, 40, "the fade is dissolving the top bar")
    }
}
