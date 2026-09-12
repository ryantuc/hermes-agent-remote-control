import XCTest

@testable import HermesServeKit

/// The consent read gate. The first test is the regression that mattered: the
/// gate shipped latched open because an unmeasured content height read as
/// "it all fits", and nothing caught it until the sheet was looked at.
final class ApprovalReadGateTests: XCTestCase {
    private let window: Double = 190

    /// The container measures first, the content is still unmeasured. The gate
    /// must refuse to answer — answering `true` here is what let an
    /// overflowing command show a live "Allow once".
    func testUnmeasuredContentIsNotReadable() {
        XCTAssertNil(ApprovalReadGate.isRead(containerHeight: window, contentHeight: 0, offset: 0))
    }

    /// Symmetric: content measured, container not.
    func testUnmeasuredContainerIsNotReadable() {
        XCTAssertNil(ApprovalReadGate.isRead(containerHeight: 0, contentHeight: 400, offset: 0))
    }

    /// A command that fits needs no scrolling to have been read.
    func testCommandThatFitsIsReadImmediately() {
        XCTAssertEqual(ApprovalReadGate.isRead(containerHeight: window, contentHeight: 120, offset: 0), true)
    }

    /// Exactly filling the window still counts — the 1 pt tolerance absorbs
    /// sub-pixel layout rounding.
    func testCommandExactlyFillingTheWindowIsRead() {
        XCTAssertEqual(ApprovalReadGate.isRead(containerHeight: window, contentHeight: window, offset: 0), true)
    }

    /// The case the gate exists for: long command, not yet scrolled.
    func testOverflowingCommandAtTheTopIsNotRead() {
        XCTAssertEqual(ApprovalReadGate.isRead(containerHeight: window, contentHeight: 600, offset: 0), false)
    }

    /// Part-way down is still not the end.
    func testOverflowingCommandPartWayIsNotRead() {
        XCTAssertEqual(ApprovalReadGate.isRead(containerHeight: window, contentHeight: 600, offset: 200), false)
    }

    /// Within the bottom slack: read.
    func testScrolledToWithinSlackOfTheEndIsRead() {
        // 600 - 190 = 410 is the true bottom; 410 - 24 = 386 is the threshold.
        XCTAssertEqual(ApprovalReadGate.isRead(containerHeight: window, contentHeight: 600, offset: 386), true)
        XCTAssertEqual(ApprovalReadGate.isRead(containerHeight: window, contentHeight: 600, offset: 385), false)
    }

    /// Scrolled fully to the bottom.
    func testScrolledToTheEndIsRead() {
        XCTAssertEqual(ApprovalReadGate.isRead(containerHeight: window, contentHeight: 600, offset: 410), true)
    }

    /// Landscape narrows the column, so the same command wraps taller. The
    /// gate must key off measured geometry, not the command, and engage in the
    /// two-column layout exactly as it does in one column.
    func testNarrowerColumnMakesTheSameCommandGate() {
        // Regular-width landscape: wide column, the command fits.
        XCTAssertEqual(ApprovalReadGate.isRead(containerHeight: window, contentHeight: 150, offset: 0), true)
        // Compact-width landscape: same command, more wrapping, must gate.
        XCTAssertEqual(ApprovalReadGate.isRead(containerHeight: window, contentHeight: 260, offset: 0), false)
    }
}
