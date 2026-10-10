import HermesServeKit
import SwiftUI
import UIKit
import XCTest

@testable import HermesMobile

/// An empty composer in portrait stacked three rows (the field, a controls row, and a model row beneath it, `ComposerView.swift`), about a sixth of the screen with nothing typed, and it was filled on Home but left unfilled on Chat (`:147-149`), so the same control read as two components.
///
/// The control row now carries the model in the same row as the controls wherever the model name still has a readable width (Desktop's own progressive collapse, `apps/desktop/src/app/chat/composer/composer-utils.ts`: the controls compact before the row gives up), and falls back to the two-row stack only where it does not. Both hosts fill the well with `composerSurface`; on Chat at Desktop's 88 % (`styles.css`, `--composer-fill`), so the plate's frost still reads at the edge.
@MainActor
final class ComposerRestingLayoutTests: XCTestCase {

    /// iPhone 17 Pro, portrait.
    private static let width: CGFloat = 402
    private static let height: CGFloat = 874

    private func restingHeight(chat: ChatModel, app: AppModel) -> CGFloat {
        let width = Self.width
        let host = UIHostingController(rootView: AnyView(
            ComposerView(model: chat, viewportHeight: nil, chrome: .glass)
                .environment(app)
                .frame(width: width)
        ))
        host.safeAreaRegions = []
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: width, height: Self.height))
        window.rootViewController = host
        window.makeKeyAndVisible()
        window.layoutIfNeeded()
        host.view.layoutIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        window.layoutIfNeeded()
        let size = host.sizeThatFits(in: CGSize(width: width, height: .greatestFiniteMagnitude))
        window.isHidden = true
        return size.height
    }

    /// The whole composer less its outer padding and one line of field is what its controls cost.
    private func controlsHeight(_ composer: CGFloat) -> CGFloat {
        let oneLine = GrowingComposerField.height(
            forLines: 1, font: GrowingComposerField.bodyFont,
            insets: GrowingComposerField.textInsets,
            displayScale: UITraitCollection.current.displayScale
        )
        return composer - 2 * Space.s4 - oneLine
    }

    func testAnEmptyComposerInPortraitIsTheFieldAndOneControlRow() async throws {
        let harness = await AppHarness.make()
        let chat = harness.chat(storedID: "20261002_resting")
        let composer = restingHeight(chat: chat, app: harness.app)
        let controls = controlsHeight(composer)
        print("[composer] resting \(composer) pt, controls \(controls) pt")
        XCTAssertLessThan(controls, 2 * Hit.min, """
            an empty portrait composer spends \(controls) pt on controls under a one-line field: \
            two rows of controls where one fits
            """)
        await harness.tearDown()
    }

    func testBothHostsFillTheWellWithTheComposerSurface() {
        XCTAssertEqual(ComposerChrome.opaque.wellFillOpacity, 1)
        XCTAssertEqual(ComposerChrome.glass.wellFillOpacity, GlassMetrics.composerFillOpacity, """
            the Chat composer's well is \(ComposerChrome.glass.wellFillOpacity) filled where Home's is opaque, so \
            one control reads as two components
            """)
        XCTAssertGreaterThanOrEqual(GlassMetrics.composerFillOpacity, 0.8, "the fill carries the field's legibility over the frost")
        XCTAssertLessThan(GlassMetrics.composerFillOpacity, 1, "an opaque well would hide the plate it sits on")
    }
}
