import SwiftUI
import XCTest

@testable import HermesMobile

/// Empty and error states that read as unfinished.
///
/// Eight backend-backed screens drew the same block when their load failed: a heading, a grey line and a half-width "Try again", pinned to the top-left corner with the rest of the screen empty (`SettingsDetailView.swift`, `MessagingStatusView.swift`, `ArtifactsView.swift`); on Capabilities the block was centred in a frame that did not reach the screen's edges, so dark mode showed black above and below it (`CapabilitiesView.swift`). The retry was offered even with no backend configured, where it could never succeed. `StatePanel` is that block as one shared component; these tests pin what it draws.
@MainActor
final class StatePanelTests: XCTestCase {
    private let rasteriser = VisualRasteriser()

    override func tearDown() {
        rasteriser.tearDown()
        super.tearDown()
    }

    private func tokens(_ polarity: ColorScheme) -> HermesTokens {
        let palette: DesktopPalette = polarity == .dark ? .nousDark : .nousLight
        return HermesTokens(skin: HermesSkin(palette: palette), palette: palette, polarity: polarity)
    }

    private func panel(action: (() -> Void)? = {}) -> StatePanel {
        StatePanel(
            symbol: "exclamationmark.triangle",
            title: "Couldn't load settings",
            message: "The request timed out.",
            actionTitle: "Try again",
            action: action
        )
    }

    private let size = CGSize(width: 360, height: 640)

    /// How the screens hold it: the screen's content area, which aligns what it is given to its top-leading corner. A panel that takes the space it is offered centres itself in it; a block that hugs its own content lands in that corner.
    private func onScreen(_ panel: StatePanel) -> AnyView {
        AnyView(panel.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading))
    }

    /// The bounding box of every pixel that is not `ground`, in pixels.
    private func inkBounds(_ raster: VisualRaster, ground: RGBA) -> (minX: Int, minY: Int, maxX: Int, maxY: Int)? {
        var minX = Int.max, minY = Int.max, maxX = -1, maxY = -1
        for y in 0..<raster.height {
            for x in 0..<raster.width where !raster.pixel(x: x, y: y).isNear(ground, tolerance: 0.02) {
                minX = min(minX, x); maxX = max(maxX, x)
                minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        return maxX < 0 ? nil : (minX, minY, maxX, maxY)
    }

    /// The panel's content sits in the middle of whatever space the screen gives it, not in its top-left corner.
    func testThePanelCentresItsContentInTheSpaceItIsGiven() {
        for polarity in [ColorScheme.light, .dark] {
            let t = tokens(polarity)
            let raster = rasteriser.render(onScreen(panel()), tokens: t, polarity: polarity, size: size)
            guard let box = inkBounds(raster, ground: RGBA(resolving: t.canvas)) else {
                return XCTFail("the panel drew nothing")
            }
            let name = polarity == .dark ? "dark" : "light"
            let centreX = Double(box.minX + box.maxX) / 2 / Double(raster.width)
            let centreY = Double(box.minY + box.maxY) / 2 / Double(raster.height)
            XCTAssertEqual(centreX, 0.5, accuracy: 0.04, "Nous \(name): the panel's content is centred at \(Int(centreX * 100)) % across, not in the middle")
            XCTAssertEqual(centreY, 0.5, accuracy: 0.06, "Nous \(name): the panel's content is centred at \(Int(centreY * 100)) % down — the block is pinned to the top of an otherwise empty screen")
        }
    }

    /// The panel stands on the screen's canvas from edge to edge, so a screen whose own frame stops short cannot show another ground around it (Capabilities' black bands in dark).
    func testThePanelPaintsTheCanvasOverEveryPointItIsGiven() {
        for polarity in [ColorScheme.light, .dark] {
            let t = tokens(polarity)
            let magenta = Color(red: 1, green: 0, blue: 1)
            let view = AnyView(
                ZStack(alignment: .topLeading) {
                    magenta
                    onScreen(panel())
                }
            )
            let raster = rasteriser.render(view, tokens: t, polarity: polarity, size: size)
            let probe = RGBA(resolving: magenta)
            var showing = 0
            for y in stride(from: 0, to: raster.height, by: 3) {
                for x in stride(from: 0, to: raster.width, by: 3) where raster.pixel(x: x, y: y).isNear(probe, tolerance: 0.05) {
                    showing += 1
                }
            }
            XCTAssertEqual(showing, 0, "Nous \(polarity == .dark ? "dark" : "light"): \(showing) sampled points show the ground behind the panel rather than the canvas")
        }
    }

    /// A retry is offered only when there is a backend it could reach.
    func testThereIsNoTryAgainWithoutABackend() {
        XCTAssertFalse(LoadFailureRecovery.offersRetry(hasBackend: false), "Try again with no backend configured is an action that cannot succeed")
    }

    /// The control: with a backend, the retry stays.
    func testThereIsATryAgainWithABackend() {
        XCTAssertTrue(LoadFailureRecovery.offersRetry(hasBackend: true))
    }

    /// The control: the panel still draws its button when it is given an action, so the centring above is not won by dropping it.
    func testThePanelStillDrawsTheActionItIsGiven() {
        let t = tokens(.light)
        let with = rasteriser.render(onScreen(panel()), tokens: t, polarity: .light, size: size)
        let without = rasteriser.render(onScreen(panel(action: nil)), tokens: t, polarity: .light, size: size)
        let canvas = RGBA(resolving: t.canvas)
        guard let a = inkBounds(with, ground: canvas), let b = inkBounds(without, ground: canvas) else {
            return XCTFail("the panel drew nothing")
        }
        XCTAssertGreaterThan(a.maxY - a.minY, b.maxY - b.minY, "a panel given an action drew nothing more than one without")
    }
}
