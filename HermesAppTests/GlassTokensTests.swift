import SwiftUI
import UIKit
import XCTest

@testable import HermesMobile

/// The glass system's rules (`HermesApp/Design/Glass.swift`), asserted as the values the views read. Nothing here hosts a view: whether the frost looks right is a screenshot, and whether it disturbs the transcript is `TranscriptBlankingUITests`.
final class GlassTokensTests: XCTestCase {

    // MARK: Which glass a floating control gets

    /// The deployment target is iOS 17.0 and `glassEffect` is iOS 26 only, so most of the field gets the fallback. It must never ask for an API the OS does not have.
    func testBelowIOS26AFloatingControlIsAMaterialDisc() {
        for major in [17, 18, 19, 25] {
            XCTAssertEqual(
                GlassRendering.resolve(osMajorVersion: major),
                .material,
                "iOS \(major) resolved to Liquid Glass, which does not exist there"
            )
        }
    }

    func testIOS26AndAboveUseLiquidGlass() {
        for major in [26, 27, 30] {
            XCTAssertEqual(GlassRendering.resolve(osMajorVersion: major), .liquidGlass)
        }
    }

    /// The fixture that lets the fallback be captured on an iOS 26 runtime.
    func testTheForcedFallbackWinsOnEveryOS() {
        for major in [17, 26, 30] {
            XCTAssertEqual(GlassRendering.resolve(osMajorVersion: major, forcesFallback: true), .material)
        }
    }

    /// One threshold for the whole app: the chrome's resolver and the floating controls' resolver must never disagree about which OS has Liquid Glass.
    func testTheGlassThresholdIsTheSameEverywhere() {
        XCTAssertEqual(GlassRendering.liquidGlassMinimumMajorVersion, 26)
        XCTAssertEqual(GlassRendering.liquidGlassMinimumMajorVersion, ChatChromeMaterial.liquidGlassMinimumMajorVersion)
    }

    // MARK: The top edge

    /// On iOS 26 the transcript's own soft scroll-edge effect is the top glass and the app must not paint over it; below 26 nothing would frost the conversation under the clear bar unless the app does.
    func testTheAppFrostsUnderTheTopBarOnlyWhereTheSystemDoesNot() {
        XCTAssertFalse(ChatChrome.drawsOwnTopPlane(.liquidGlass), "a plane over iOS 26's scroll-edge effect is the grey slab again")
        XCTAssertTrue(ChatChrome.drawsOwnTopPlane(.material), "below iOS 26 the bar is clear and nothing else frosts what passes under it")
    }

    // MARK: The chrome planes

    /// The tint is what carries legibility once the transcript passes behind the chrome; the frost is texture. Thinned below the floor, the composer's placeholder and the dock's rows start competing with the blurred words behind them; at 1 the plane is a slab again.
    func testTheChromeTintCarriesLegibilityAndStillLetsTheConversationThrough() {
        XCTAssertGreaterThanOrEqual(GlassMetrics.chromeTintOpacity, GlassMetrics.chromeTintFloor)
        XCTAssertLessThan(GlassMetrics.chromeTintOpacity, 0.9, "the plane is opaque in all but name, which is BUG-061 again")
        for scheme in [ColorScheme.light, .dark] {
            let tokens = HermesTokens(skin: scheme == .dark ? .nousDark : .nousLight, polarity: scheme)
            let glass = GlassTokens(tokens, scheme: scheme)
            XCTAssertEqual(
                Double(UIColor(glass.chromeTint).cgColor.alpha),
                GlassMetrics.chromeTintOpacity,
                accuracy: 0.01,
                "the \(scheme) tint is not the canvas at the chrome opacity"
            )
        }
    }

    /// A glass edge is a rim and a lift, in both polarities; a plane with neither is a tone step, which is the reported hard line.
    func testBothPolaritiesDrawARimAndALift() {
        for scheme in [ColorScheme.light, .dark] {
            let tokens = HermesTokens(skin: scheme == .dark ? .nousDark : .nousLight, polarity: scheme)
            let glass = GlassTokens(tokens, scheme: scheme)
            XCTAssertGreaterThan(UIColor(glass.rim).cgColor.alpha, 0, "no rim in \(scheme)")
            XCTAssertGreaterThan(UIColor(glass.shadow).cgColor.alpha, 0, "no lift in \(scheme)")
        }
    }

    /// The dock rounds the corners that face the conversation, and so does the plane under the top bar, mirrored, so the two read as one family.
    func testEachPlaneRoundsOnlyTheEdgeThatFacesContent() {
        let radius = ChatChrome.plateCornerRadius
        let dock = GlassPlaneBackground.corners(anchoredTo: .bottom, cornerRadius: radius)
        XCTAssertEqual(dock.top, radius)
        XCTAssertEqual(dock.bottom, 0, "the dock's bottom runs into the home indicator well and must stay square")
        let bar = GlassPlaneBackground.corners(anchoredTo: .top, cornerRadius: radius)
        XCTAssertEqual(bar.top, 0, "the bar's plane runs under the status bar and must stay square")
        XCTAssertEqual(bar.bottom, radius)
    }
}
