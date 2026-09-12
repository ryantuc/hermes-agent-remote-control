import XCTest

@testable import HermesMobile

/// What the Home live dot does when it is tapped.
///
/// **This class used to specify the opposite, and that is the item.** FEAT-011 made the dot a control at all — before it, a pulsing dot rendered as an interactive element and did nothing — and sent it to Settings → Notifications with a two-hop push, `[.settings, .settingsScreen(.notifications)]`. These two tests required exactly that pair, and the second required it be *appended* to whatever was already on the stack: "a push, not a reset — the dot is a detour, not a new root".
///
/// A detour that inserts Settings is precisely why Back from Notifications landed on the full Settings page rather than on Home (BUG-054), and FEAT-026 gives the dot a different destination altogether: the list of sessions actually running. So the assertions that pinned the old route were the specification of the defect, and they move with it. The dot now presents `LiveSessionPickerSheet` over Home and puts nothing on the navigation stack at all.
///
/// The assertion is still on the **effect of the tap**, not on the existence of a button: a Box-hosted view test would pass on a dot that went nowhere, which is the bug FEAT-011 was filed for in the first place.
@MainActor
final class HomeLiveIndicatorRouteTests: XCTestCase {

    func testTappingTheLiveDotPresentsTheRunningSessionPicker() {
        var pickerOpen = false
        var path: [AppRoute] = []

        HomeLiveIndicator.open(pickerOpen: &pickerOpen, path: &path)

        XCTAssertTrue(
            pickerOpen,
            "the dot's destination is the list of what is running, not a settings page about Lock Screen cards"
        )
    }

    /// BUG-054, stated as the property that makes it impossible: a tap that pushes nothing has nothing for Back to pop, so Back from the conversation the picker opens is Home.
    func testTheDotPutsNothingOnTheNavigationStack() {
        var pickerOpen = false
        var path: [AppRoute] = []

        HomeLiveIndicator.open(pickerOpen: &pickerOpen, path: &path)

        XCTAssertEqual(
            path,
            [],
            "the dot is a Home control and the user never asked for another page — the picker is presented over Home, not pushed onto it"
        )
    }

    /// And it does not disturb a stack it was tapped from either. The dot is rendered on Home, so this is a guard rather than a live case: whatever is on the stack when the picker is presented is still on it afterwards.
    func testTheDotLeavesAnExistingStackExactlyAsItFoundIt() {
        var pickerOpen = false
        var path: [AppRoute] = [.commandCenter]

        HomeLiveIndicator.open(pickerOpen: &pickerOpen, path: &path)

        XCTAssertEqual(path, [.commandCenter])
        XCTAssertTrue(pickerOpen)
    }
}
