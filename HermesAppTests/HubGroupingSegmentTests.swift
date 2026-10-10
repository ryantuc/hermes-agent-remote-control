import XCTest

@testable import HermesMobile

/// BUG-146 (`NavigationHubView.swift`): the hub's Sessions / Projects segment was drawn only while `app.threads` was non-empty, but `hermes.hub.mode` is persisted, so an account with no threads and a stored "Projects" showed an empty Projects list with no control to switch back.
final class HubGroupingSegmentTests: XCTestCase {

    /// The reported case: nothing to list, Projects remembered. The segment is the only way back, so it stays.
    func testTheSegmentStaysWhileProjectsIsSelectedWithNoThreads() {
        XCTAssertTrue(HubGroupingSegment.isShown(hasThreads: false, groupingMode: "Projects"))
    }

    /// With no threads and the default grouping there is nothing to regroup, so the hub stays as quiet as it was.
    func testTheSegmentIsHiddenWithNoThreadsOnTheDefaultGrouping() {
        XCTAssertFalse(HubGroupingSegment.isShown(hasThreads: false, groupingMode: "Sessions"))
    }

    func testTheSegmentIsShownWheneverThereAreThreads() {
        XCTAssertTrue(HubGroupingSegment.isShown(hasThreads: true, groupingMode: "Sessions"))
        XCTAssertTrue(HubGroupingSegment.isShown(hasThreads: true, groupingMode: "Projects"))
    }
}
