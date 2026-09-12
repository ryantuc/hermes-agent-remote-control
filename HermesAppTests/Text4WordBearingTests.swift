import SwiftUI
import UIKit
import XCTest

@testable import HermesMobile

/// `text-4` is the chrome rung. The token says so in the source that derives
/// it: "text-4 never carries text. Chevrons, rules, the unfilled half of a rung
/// indicator. If a word lands here it belongs in text-3."
/// (`HermesApp/Design/HermesTokens.swift:187-189`.)
///
/// BUG-034: words landed there anyway — the day separator, the section
/// header's `3/6` fraction, timestamps, slugs, footnotes — at 2.898:1 over the
/// dark Nous canvas and 2.826:1 over the light one. Both fail WCAG AA (4.5:1)
/// and both fail AA-large (3.0:1); the footnote and caption faces are 11–12 pt,
/// so 4.5 is the bar that applies.
///
/// These tests measure the **rendered** colour rather than restate the ramp: a
/// view is hosted in a `UIWindow`, rasterised, and the fully-covered glyph
/// pixel is composited against the sampled ground with the app's own
/// `RGBA.contrast(over:)` (`HermesTokens.swift:96-102`). A test that only
/// recomputed the ramp would be green with the bug still on screen, because the
/// bug is which rung a *view* picked, not what the rung's arithmetic is.
///
/// The measured label is a run of `█` (U+2588 FULL BLOCK) rather than "Today".
/// Colour does not depend on the string, and a solid glyph guarantees interior
/// pixels at full coverage, so the reading is the token's colour and never a
/// partly anti-aliased edge of it.
///
/// The four `…StaysBelowAA` / `…MeetsAA` companions pin the token arithmetic in
/// both polarities. They are green today and must stay green: they are what
/// stops a later session from "fixing" this bug by raising the chrome rung's
/// alpha, which would repaint every chevron, rule and dot in the app.
@MainActor
final class Text4WordBearingTests: XCTestCase {

    /// WCAG AA for text below 18 pt / 14 pt bold. Every word-bearing surface in
    /// this app is footnote (12 pt) or caption (11 pt) — `HermesType.swift:56-58`.
    private static let aa = 4.5

    /// U+2588 FULL BLOCK. See the type comment: the string is the instrument,
    /// the colour is the subject.
    private static let solid = String(repeating: "\u{2588}", count: 5)

    private var windows: [UIWindow] = []

    override func tearDown() {
        for window in windows { window.isHidden = true }
        windows.removeAll()
        super.tearDown()
    }

    // MARK: - Rendered-contrast measurements (red before the BUG-034 bump)

    /// The transcript's day separator — the report's flagship site.
    func testDaySeparatorContrastMeetsAAInNousDark() {
        assertMeetsAA(AnyView(DaySeparator(label: Self.solid)),
                      skin: .nousDark, polarity: .dark, what: "DaySeparator")
    }

    /// Same word, other polarity. The filed report called light "passing at
    /// ~6.7:1"; that figure is light **text-2**. Light text-4 is 2.826:1.
    func testDaySeparatorContrastMeetsAAInNousLight() {
        assertMeetsAA(AnyView(DaySeparator(label: Self.solid)),
                      skin: .nousLight, polarity: .light, what: "DaySeparator")
    }

    // MARK: - Token arithmetic (green today, must stay green)

    /// The chrome rung stays chrome. If this ever passes AA, someone raised
    /// `MixKnobs.dark.text[3]` instead of moving the words to text-3.
    func testNousDarkText4StaysBelowAA() {
        let (ramp, canvas) = rampAndCanvas(skin: .nousDark, knobs: .dark)
        let contrast = HermesSkin.nousDark.fg.alpha(ramp[3]).contrast(over: canvas)
        XCTAssertLessThan(contrast, 3.0,
                          "dark text-4 is the chrome rung; measured \(contrast)")
    }

    func testNousLightText4StaysBelowAA() {
        let (ramp, canvas) = rampAndCanvas(skin: .nousLight, knobs: .light)
        let contrast = HermesSkin.nousLight.fg.alpha(ramp[3]).contrast(over: canvas)
        XCTAssertLessThan(contrast, 3.0,
                          "light text-4 is the chrome rung; measured \(contrast)")
    }

    /// Why the bump works rather than a new ramp step: text-3 already clears AA
    /// in both polarities.
    func testNousDarkText3MeetsAA() {
        let (ramp, canvas) = rampAndCanvas(skin: .nousDark, knobs: .dark)
        let contrast = HermesSkin.nousDark.fg.alpha(ramp[2]).contrast(over: canvas)
        XCTAssertGreaterThanOrEqual(contrast, Self.aa,
                                    "dark text-3 must carry words; measured \(contrast)")
    }

    func testNousLightText3MeetsAA() {
        let (ramp, canvas) = rampAndCanvas(skin: .nousLight, knobs: .light)
        let contrast = HermesSkin.nousLight.fg.alpha(ramp[2]).contrast(over: canvas)
        XCTAssertGreaterThanOrEqual(contrast, Self.aa,
                                    "light text-3 must carry words; measured \(contrast)")
    }

    // MARK: - Token arithmetic helpers

    /// The ramp the tokens actually resolve to, plus the canvas they sit on.
    /// `raisedTextRamp` lifts the whole ramp only when text-2 fails 4.5:1; under
    /// both Nous polarities text-2 passes (7.936 / 6.952), so the lift is zero
    /// and the knob values are the live alphas. The text-2 assertion here is
    /// what makes that claim, rather than assuming it.
    private func rampAndCanvas(skin: HermesSkin, knobs: MixKnobs,
                               file: StaticString = #filePath, line: UInt = #line)
        -> (ramp: [Double], canvas: RGBA) {
        let canvas = skin.bg.mixed(knobs.canvas, with: HermesSkin.ink)
        let text2 = skin.fg.alpha(knobs.text[1]).contrast(over: canvas)
        XCTAssertGreaterThanOrEqual(text2, Self.aa,
                                    "text-2 passing is what makes the lift zero; measured \(text2)",
                                    file: file, line: line)
        return (knobs.text, canvas)
    }

    // MARK: - Rendering helpers

    private func assertMeetsAA(_ view: AnyView, skin: HermesSkin, polarity: ColorScheme,
                               what: String,
                               file: StaticString = #filePath, line: UInt = #line) {
        let tokens = HermesTokens(skin: skin, polarity: polarity)
        let knobs: MixKnobs = polarity == .dark ? .dark : .light
        let expectedGround = skin.bg.mixed(knobs.canvas, with: HermesSkin.ink)

        let reading = measure(view, tokens: tokens, polarity: polarity)

        XCTAssertNotEqual(reading.ink, reading.ground,
                          "\(what) rendered no ink — the measurement is blind, not passing",
                          file: file, line: line)
        for (channel, pair) in [("r", (reading.ground.r, expectedGround.r)),
                                ("g", (reading.ground.g, expectedGround.g)),
                                ("b", (reading.ground.b, expectedGround.b))] {
            XCTAssertEqual(pair.0, pair.1, accuracy: 0.03,
                           "\(what) was not rendered over the token canvas (\(channel))",
                           file: file, line: line)
        }
        XCTAssertGreaterThanOrEqual(
            reading.contrast, Self.aa,
            "\(what) carries words at \(reading.contrast):1 over the \(polarity == .dark ? "dark" : "light") Nous canvas — WCAG AA needs \(Self.aa). ink \(reading.ink), ground \(reading.ground)",
            file: file, line: line)
    }

    /// Rasterise the hosted view and return the fully-covered glyph colour, the
    /// ground it sits on, and the contrast between them.
    private func measure(_ view: AnyView, tokens: HermesTokens, polarity: ColorScheme)
        -> (ink: RGBA, ground: RGBA, contrast: Double) {
        let size = CGSize(width: 260, height: 60)
        var reading = read(image: rasterise(view, tokens: tokens, polarity: polarity,
                                            size: size, viaLayer: false))
        if reading.ink == reading.ground {
            // `drawHierarchy` can report success and draw nothing when the
            // window never reached the screen. The layer path does not need it.
            reading = read(image: rasterise(view, tokens: tokens, polarity: polarity,
                                            size: size, viaLayer: true))
        }
        return (reading.ink, reading.ground, reading.ink.contrast(over: reading.ground))
    }

    private func rasterise(_ view: AnyView, tokens: HermesTokens, polarity: ColorScheme,
                           size: CGSize, viaLayer: Bool) -> UIImage {
        let root = view
            .environment(\.hermes, tokens)
            .environment(\.colorScheme, polarity)
            .frame(width: size.width, height: size.height)
            .background(tokens.canvas)
        let host = UIHostingController(rootView: AnyView(root))
        host.overrideUserInterfaceStyle = polarity == .dark ? .dark : .light
        let window = UIWindow(frame: CGRect(origin: .zero, size: size))
        window.rootViewController = host
        window.makeKeyAndVisible()
        window.layoutIfNeeded()
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()
        windows.append(window)

        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 3
        format.preferredRange = .standard
        let bounds = CGRect(origin: .zero, size: size)
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            if viaLayer {
                host.view.layer.render(in: context.cgContext)
            } else if !host.view.drawHierarchy(in: bounds, afterScreenUpdates: true) {
                host.view.layer.render(in: context.cgContext)
            }
        }
    }

    /// The ground is the most common colour in the frame; the ink is the colour
    /// furthest from it in luminance, which for a solid glyph is a fully
    /// covered interior pixel.
    private func read(image: UIImage) -> (ink: RGBA, ground: RGBA) {
        guard let cgImage = image.cgImage else { return (RGBA(hex: 0), RGBA(hex: 0)) }
        let width = cgImage.width
        let height = cgImage.height
        var data = [UInt8](repeating: 0, count: width * height * 4)
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        data.withUnsafeMutableBytes { raw in
            let context = CGContext(data: raw.baseAddress, width: width, height: height,
                                    bitsPerComponent: 8, bytesPerRow: width * 4, space: space,
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            context?.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        }

        var counts: [UInt32: Int] = [:]
        for pixel in stride(from: 0, to: width * height * 4, by: 4) {
            let key = UInt32(data[pixel]) << 16 | UInt32(data[pixel + 1]) << 8 | UInt32(data[pixel + 2])
            counts[key, default: 0] += 1
        }
        guard let groundKey = counts.max(by: { $0.value < $1.value })?.key else {
            return (RGBA(hex: 0), RGBA(hex: 0))
        }
        let ground = RGBA(hex: groundKey)
        let groundLuminance = ground.luminance
        var ink = ground
        var distance = 0.0
        for key in counts.keys {
            let candidate = RGBA(hex: key)
            let delta = abs(candidate.luminance - groundLuminance)
            if delta > distance {
                distance = delta
                ink = candidate
            }
        }
        return (ink, ground)
    }
}
