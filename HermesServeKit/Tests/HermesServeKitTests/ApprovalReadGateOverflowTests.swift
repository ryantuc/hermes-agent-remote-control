import HermesServeKit
import XCTest

/// The approval sheet decided whether a command overflows its window with a second copy of the rule `ApprovalReadGate.isRead` uses (content taller than the window by more than one point), so the gate warning and the read latch could disagree at that boundary and only one copy was tested. Both now read `ApprovalReadGate.overflows`.
final class ApprovalReadGateOverflowTests: XCTestCase {
    func testOverflowIsMoreThanOnePointTallerThanTheWindow() {
        XCTAssertEqual(ApprovalReadGate.overflows(containerHeight: 190, contentHeight: 191), false, "one point over is rounding, not overflow")
        XCTAssertEqual(ApprovalReadGate.overflows(containerHeight: 190, contentHeight: 191.5), true)
        XCTAssertEqual(ApprovalReadGate.overflows(containerHeight: 190, contentHeight: 120), false)
    }

    func testOverflowIsUnknownUntilBothHeightsAreMeasured() {
        XCTAssertNil(ApprovalReadGate.overflows(containerHeight: 0, contentHeight: 400))
        XCTAssertNil(ApprovalReadGate.overflows(containerHeight: 190, contentHeight: 0))
    }

    /// The two answers agree everywhere: a command that does not overflow counts as read wherever it is scrolled, and one that does is unread at the top.
    func testTheReadGateAgreesWithOverflowAtTheBoundary() {
        for content in stride(from: 150.0, through: 260.0, by: 0.25) {
            let overflows = ApprovalReadGate.overflows(containerHeight: 190, contentHeight: content)
            let readAtTop = ApprovalReadGate.isRead(containerHeight: 190, contentHeight: content, offset: 0)
            if overflows == false {
                XCTAssertEqual(readAtTop, true, "content \(content): fits, but the read gate says unread")
            }
            if content > 190 + 1 + ApprovalReadGate.bottomSlack {
                XCTAssertEqual(readAtTop, false, "content \(content): overflows past the slack, but the read gate says read at the top")
            }
        }
    }
}
