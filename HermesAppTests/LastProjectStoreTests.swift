import Foundation
import XCTest

@testable import HermesMobile

/// FEAT-001 — a fresh Home draft reset to the backend's default project every time, because the pick is a per-draft override and nothing persisted it.
///
/// These pin the store: the round trip, the per-profile isolation that keeps switching backends from leaking projects, and the fallback when a profile has never picked anything.
final class LastProjectStoreTests: XCTestCase {

    private var defaults: UserDefaults!
    private let suiteName = "feat-001-last-project-store-tests"

    override func setUp() {
        super.setUp()
        UserDefaults.standard.removePersistentDomain(forName: suiteName)
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    func testAPickIsRememberedForThatProfile() {
        let profile = UUID()

        LastProjectStore.remember("/Users/you/work/hermes", profileID: profile, defaults: defaults)

        XCTAssertEqual(
            LastProjectStore.remembered(profileID: profile, defaults: defaults),
            "/Users/you/work/hermes",
            "nothing persisted the Home project pick, so every new draft went back to the backend default"
        )
    }

    func testOneProfilesProjectDoesNotLeakIntoAnother() {
        let second = UUID()
        let laptop = UUID()

        LastProjectStore.remember("/Users/you/work/hermes", profileID: second, defaults: defaults)
        LastProjectStore.remember("/srv/matters/station-casinos", profileID: laptop, defaults: defaults)

        XCTAssertEqual(
            LastProjectStore.remembered(profileID: second, defaults: defaults),
            "/Users/you/work/hermes",
            "two backends are two machines with two sets of paths"
        )
        XCTAssertEqual(
            LastProjectStore.remembered(profileID: laptop, defaults: defaults),
            "/srv/matters/station-casinos"
        )
    }

    func testAProfileThatHasNeverPickedRemembersNothing() {
        let picked = UUID()
        let fresh = UUID()
        LastProjectStore.remember("/Users/you/work/hermes", profileID: picked, defaults: defaults)

        XCTAssertNil(
            LastProjectStore.remembered(profileID: fresh, defaults: defaults),
            "nil is what sends the caller to app.defaultCwd — the fallback the report requires"
        )
    }

    func testTheProfileLessKeyIsItsOwnSlotAndAnEmptyPickIsNotAPath() {
        LastProjectStore.remember("/Users/you/work/hermes", profileID: nil, defaults: defaults)
        XCTAssertEqual(LastProjectStore.remembered(profileID: nil, defaults: defaults), "/Users/you/work/hermes")
        XCTAssertNil(
            LastProjectStore.remembered(profileID: UUID(), defaults: defaults),
            "the no-profile slot must not answer for a real profile"
        )

        LastProjectStore.remember("   ", profileID: nil, defaults: defaults)
        XCTAssertEqual(
            LastProjectStore.remembered(profileID: nil, defaults: defaults),
            "/Users/you/work/hermes",
            "blank is not a path — a whitespace pick must not blank the chip"
        )
    }
}
