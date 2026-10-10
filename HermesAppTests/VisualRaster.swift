import SwiftUI
import UIKit
import XCTest

@testable import HermesMobile

/// A rendered frame read back as pixels, for the visual-system tests.
///
/// The method is `Text4WordBearingTests`': host the shipped view in a `UIWindow` over the token canvas, rasterise it at @3x, and read colours out of the bitmap, so the assertion is about what a view drew and not about what a token's arithmetic says it should have drawn.
struct VisualRaster {
    let width: Int
    let height: Int
    let scale: Int
    /// Row-major RGBA bytes.
    private let bytes: [UInt8]

    init(width: Int, height: Int, scale: Int, bytes: [UInt8]) {
        self.width = width
        self.height = height
        self.scale = scale
        self.bytes = bytes
    }

    func pixel(x: Int, y: Int) -> RGBA {
        let index = (y * width + x) * 4
        return RGBA(
            r: Double(bytes[index]) / 255,
            g: Double(bytes[index + 1]) / 255,
            b: Double(bytes[index + 2]) / 255
        )
    }

    /// The most common colour in the frame: the ground a view stands on, or the fill of a control that fills the frame.
    var dominant: RGBA {
        var counts: [UInt32: Int] = [:]
        for y in 0..<height {
            for x in 0..<width {
                counts[key(x: x, y: y), default: 0] += 1
            }
        }
        let best = counts.max { $0.value < $1.value }?.key ?? 0
        return RGBA(hex: best)
    }

    /// The colour furthest in luminance from `ground`: for a run of solid glyphs, a fully covered interior pixel.
    func ink(over ground: RGBA) -> RGBA {
        var seen = Set<UInt32>()
        var best = ground
        var distance = 0.0
        for y in 0..<height {
            for x in 0..<width {
                let k = key(x: x, y: y)
                guard seen.insert(k).inserted else { continue }
                let candidate = RGBA(hex: k)
                let delta = abs(candidate.luminance - ground.luminance)
                if delta > distance {
                    distance = delta
                    best = candidate
                }
            }
        }
        return best
    }

    /// The leftmost column holding a pixel within `tolerance` (per channel, 0...1) of `color`, or nil when none does.
    func leftmostColumn(near color: RGBA, tolerance: Double = 0.02) -> Int? {
        for x in 0..<width {
            for y in 0..<height where pixel(x: x, y: y).isNear(color, tolerance: tolerance) {
                return x
            }
        }
        return nil
    }

    /// How many pixels in row `y` differ from `ground` by more than `tolerance` in any channel.
    func pixelsOff(ground: RGBA, row y: Int, tolerance: Double = 0.01) -> Int {
        (0..<width).filter { !pixel(x: $0, y: y).isNear(ground, tolerance: tolerance) }.count
    }

    private func key(x: Int, y: Int) -> UInt32 {
        let index = (y * width + x) * 4
        return UInt32(bytes[index]) << 16 | UInt32(bytes[index + 1]) << 8 | UInt32(bytes[index + 2])
    }
}

extension RGBA {
    func isNear(_ other: RGBA, tolerance: Double) -> Bool {
        abs(r - other.r) <= tolerance && abs(g - other.g) <= tolerance && abs(b - other.b) <= tolerance
    }

    /// The colour a `Color` token resolves to, so token tests can measure it.
    init(resolving color: Color) {
        let resolved = color.resolve(in: EnvironmentValues())
        self.init(
            r: Double(resolved.red),
            g: Double(resolved.green),
            b: Double(resolved.blue),
            a: Double(resolved.opacity)
        )
    }

    /// `self` laid over an opaque `ground`.
    func composited(over ground: RGBA) -> RGBA {
        RGBA(
            r: r * a + ground.r * (1 - a),
            g: g * a + ground.g * (1 - a),
            b: b * a + ground.b * (1 - a)
        )
    }

    /// The spread between the strongest and the weakest channel, in 0...255 levels: how far a colour is from grey.
    var chromaLevels: Double {
        (max(r, g, b) - min(r, g, b)) * 255
    }
}

/// Hosts and rasterises views; keeps its windows alive until `tearDown`.
@MainActor
final class VisualRasteriser {
    private var windows: [UIWindow] = []

    func render(
        _ view: AnyView,
        tokens: HermesTokens,
        polarity: ColorScheme,
        size: CGSize
    ) -> VisualRaster {
        var raster = rasterise(view, tokens: tokens, polarity: polarity, size: size, viaLayer: false)
        if raster.dominant == raster.ink(over: raster.dominant) {
            // `drawHierarchy` can report success and draw nothing when the window never reached the screen; the layer path does not need it.
            raster = rasterise(view, tokens: tokens, polarity: polarity, size: size, viaLayer: true)
        }
        return raster
    }

    func tearDown() {
        for window in windows { window.isHidden = true }
        windows.removeAll()
    }

    private func rasterise(
        _ view: AnyView,
        tokens: HermesTokens,
        polarity: ColorScheme,
        size: CGSize,
        viaLayer: Bool
    ) -> VisualRaster {
        let root = view
            .environment(\.hermes, tokens)
            .environment(\.colorScheme, polarity)
            .frame(width: size.width, height: size.height)
            .background(tokens.canvas)
        let host = UIHostingController(rootView: AnyView(root))
        // A window this small still inherits the device's safe area, and SwiftUI insets its content by it: a 48 pt row was drawn partly below the frame, so its bottom edge, and most of a button's ground, never reached the bitmap.
        host.safeAreaRegions = []
        host.overrideUserInterfaceStyle = polarity == .dark ? .dark : .light
        let window = UIWindow(frame: CGRect(origin: .zero, size: size))
        window.rootViewController = host
        window.makeKeyAndVisible()
        window.layoutIfNeeded()
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()
        windows.append(window)

        let scale = 3
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = CGFloat(scale)
        format.preferredRange = .standard
        let bounds = CGRect(origin: .zero, size: size)
        let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
            if viaLayer {
                host.view.layer.render(in: context.cgContext)
            } else if !host.view.drawHierarchy(in: bounds, afterScreenUpdates: true) {
                host.view.layer.render(in: context.cgContext)
            }
        }

        guard let cgImage = image.cgImage else {
            return VisualRaster(width: 0, height: 0, scale: scale, bytes: [])
        }
        let width = cgImage.width
        let height = cgImage.height
        var data = [UInt8](repeating: 0, count: width * height * 4)
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        data.withUnsafeMutableBytes { raw in
            let context = CGContext(
                data: raw.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4, space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
            context?.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        return VisualRaster(width: width, height: height, scale: scale, bytes: data)
    }
}
