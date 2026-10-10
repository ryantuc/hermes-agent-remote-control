import XCTest

@testable import HermesMobile

/// BUG-056: the composer caps its field from the measured height of its own chrome, read back through a preference, and the report's mechanism is that measurement flickering across a rounding boundary and re-capping the field on every pass. The hang did not reproduce on a later tree (the raised ladder passes `ComposerReachabilityUITests` against a real keyboard), so this damping is the report's direction A, taken as a guard rather than a fix observed red: a measurement is kept on the pixel grid, and noise inside one pixel is not a change.
final class ComposerChromeMeasureTests: XCTestCase {

    func testSubPixelNoiseLeavesTheMeasurementAlone() {
        XCTAssertEqual(ComposerChromeMeasure.settled(previous: 50, measured: 50.1, displayScale: 3), 50)
        XCTAssertEqual(ComposerChromeMeasure.settled(previous: 50, measured: 49.9, displayScale: 3), 50)
    }

    func testARealChangeIsTakenOnThePixelGrid() {
        XCTAssertEqual(ComposerChromeMeasure.settled(previous: 100, measured: 50, displayScale: 3), 50)
        XCTAssertEqual(ComposerChromeMeasure.settled(previous: 50, measured: 51, displayScale: 3), 51)
        XCTAssertEqual(ComposerChromeMeasure.settled(previous: 50, measured: 50.4, displayScale: 3), 50 + 1.0 / 3.0, accuracy: 0.0001)
    }

    func testAnUnplacedViewUsesTheCoarsestGrid() {
        XCTAssertEqual(ComposerChromeMeasure.settled(previous: 40, measured: 44.2, displayScale: 0), 44)
    }

    /// Settling twice changes nothing more, so the state write it guards cannot become a loop of its own.
    func testSettlingIsIdempotent() {
        let once = ComposerChromeMeasure.settled(previous: 0, measured: 87.77, displayScale: 3)
        XCTAssertEqual(ComposerChromeMeasure.settled(previous: once, measured: once, displayScale: 3), once)
    }
}
