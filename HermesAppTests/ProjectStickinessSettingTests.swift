import HermesServeKit
import XCTest

@testable import HermesMobile

/// FEAT-028 — the stickiness window becomes a duration the user picks.
///
/// FEAT-018 shipped the decay as a hidden constant and FEAT-028 exposes it. What this class pins is the part of the change that can be got wrong silently: the upgrade (a device that has never seen the control must behave exactly as it did before) and the two ends (`off` and `always` are real settings, not decorations on a picker that only ever means ten minutes).
///
/// `LastProjectDecayTests` is unmodified and still green. That is by design and it was FEAT-018's gift to this item: it asserts the window as a *bracket* — a minute-old pick seeds, an hour-old pick does not — precisely so the figure could move without editing a test. It passes here because the default did not move, and because the preference is read from the injected `UserDefaults` rather than through `@AppStorage`.
@MainActor
final class ProjectStickinessSettingTests: XCTestCase {

    private var defaults: UserDefaults!
    private var suiteName: String!
    private let profile = UUID()
    private let path = "/Users/you/Developer/myproject"

    override func setUp() {
        super.setUp()
        suiteName = "feat-028-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    private func store(_ path: String, secondsAgo: TimeInterval) {
        defaults.set(path, forKey: LastProjectStore.key(profileID: profile))
        defaults.set(Date().timeIntervalSince1970 - secondsAgo, forKey: LastProjectStore.timestampKey(profileID: profile))
    }

    private func choose(_ stickiness: ProjectStickiness) {
        defaults.set(stickiness.rawValue, forKey: ProjectStickiness.storageKey)
    }

    // MARK: The upgrade

    /// **Nobody's behaviour changes when this ships.** The control is new, so every phone that installs this build has no value stored for it, and what it does then is the whole of the compatibility promise.
    func testAPhoneThatHasNeverSeenTheControlGetsTheOldBehaviour() {
        XCTAssertEqual(ProjectStickiness.current(defaults: defaults), .tenMinutes,
                       "an unset preference must resolve to FEAT-018's shipped figure, or this feature silently changes what every existing phone does")
        XCTAssertEqual(ProjectStickiness.fallback, .tenMinutes)
    }

    /// Garbage in the slot is the same case as nothing in it. A raw value written by a future build, or by a hand editing defaults, must not turn the seeding off.
    func testAnUnreadableStoredValueFallsBackRatherThanDisablingTheFeature() {
        defaults.set("fortnight", forKey: ProjectStickiness.storageKey)
        XCTAssertEqual(ProjectStickiness.current(defaults: defaults), .tenMinutes)
    }

    /// **The preference is read from the store's own defaults, not from `.standard`.**
    ///
    /// This is the one that keeps `LastProjectDecayTests` honest. `@AppStorage` always means `UserDefaults.standard`, so a preference read that way would reach past the injected suite and let whatever is set on the simulator decide what a hermetic test measures — an hour-old pick would start seeding, in a test that never mentioned the setting, on the day somebody chose `Always` on that device.
    func testThePreferenceIsReadFromTheInjectedDefaults() {
        choose(.always)
        XCTAssertEqual(ProjectStickiness.current(defaults: defaults), .always,
                       "the injected suite must win")
        XCTAssertEqual(ProjectStickiness.current(defaults: UserDefaults(suiteName: "feat-028-empty-\(UUID().uuidString)")!), .tenMinutes,
                       "a different suite must not see this one's choice — if it does, the read is going through .standard")
    }

    // MARK: Off — FEAT-001 disabled

    func testOffMeansANewConversationNeverInheritsAProject() {
        choose(.off)
        store(path, secondsAgo: 5)
        XCTAssertNil(LastProjectStore.remembered(profileID: profile, defaults: defaults),
                     "a pick five seconds old still seeded with the setting off — Off has to mean off")
    }

    /// Off hides the value; it does not erase it. The same rule expiry follows, and for a stronger reason here: turning the setting back on has to bring the last pick back with it, or Off is a destructive operation disguised as a preference.
    func testOffDoesNotErasetheRememberedProject() {
        choose(.off)
        store(path, secondsAgo: 5)
        _ = LastProjectStore.remembered(profileID: profile, defaults: defaults)

        choose(.tenMinutes)
        XCTAssertEqual(LastProjectStore.remembered(profileID: profile, defaults: defaults), path,
                       "turning the setting back on did not restore the pick — Off deleted something instead of ignoring it")
    }

    // MARK: Always — FEAT-018 disabled

    func testAlwaysSeedsAPickFromLastWeek() {
        choose(.always)
        store(path, secondsAgo: 7 * 24 * 60 * 60)
        XCTAssertEqual(LastProjectStore.remembered(profileID: profile, defaults: defaults), path,
                       "a week-old pick expired with the setting on Always")
    }

    /// **`always` turns off everything FEAT-018 introduced, including its treatment of unstamped values.**
    ///
    /// Under every other setting a path with no stamp beside it expires, because FEAT-018's reasoning is that an unknown age cannot honestly be called recent. Under `always` nothing is asking about age, so there is nothing for the missing stamp to fail — and this is what makes the setting genuinely pre-decay behaviour rather than "no expiry, except for the very values the decay was built to retire."
    func testAlwaysSeedsAValueStoredBeforeTheWindowExisted() {
        choose(.always)
        defaults.set(path, forKey: LastProjectStore.key(profileID: profile))
        XCTAssertEqual(LastProjectStore.remembered(profileID: profile, defaults: defaults), path,
                       "an unstamped FEAT-001-era value did not seed under Always, so Always is not the pre-decay behaviour it claims to be")
    }

    // MARK: The middle rungs

    func testOneHourSeedsAtHalfAnHourAndNotAtTwo() {
        choose(.oneHour)
        store(path, secondsAgo: 30 * 60)
        XCTAssertEqual(LastProjectStore.remembered(profileID: profile, defaults: defaults), path,
                       "a half-hour-old pick expired on the one-hour setting")

        store(path, secondsAgo: 2 * 60 * 60)
        XCTAssertNil(LastProjectStore.remembered(profileID: profile, defaults: defaults),
                     "a two-hour-old pick seeded on the one-hour setting")
    }

    /// The rungs have to be ordered and distinct, or the picker is offering the same thing twice.
    func testTheRungsAreDistinctAndInIncreasingOrder() {
        let bounded = ProjectStickiness.allCases.compactMap { rung -> TimeInterval? in
            if case .within(let window) = rung.horizon { return window }
            return nil
        }
        XCTAssertEqual(bounded, bounded.sorted(), "the durations must climb in the order they are offered")
        XCTAssertEqual(Set(bounded).count, bounded.count, "two rungs mean the same duration")
        XCTAssertEqual(ProjectStickiness.allCases.first, .off, "Off leads the control")
        XCTAssertEqual(ProjectStickiness.allCases.last, .always, "Always closes it")
    }

    /// A future stamp is a clock that moved. It fails closed on a bounded window — FEAT-018's rule, restated because the branch it lives in moved.
    func testAStampInTheFutureStillFailsClosedOnABoundedWindow() {
        choose(.oneHour)
        store(path, secondsAgo: -60 * 60)
        XCTAssertNil(LastProjectStore.remembered(profileID: profile, defaults: defaults))
    }

    /// Every rung needs a label, and four of them share a segmented control on a phone's width.
    func testEveryRungHasAShortLabel() {
        for rung in ProjectStickiness.allCases {
            XCTAssertFalse(rung.label.isEmpty, "\(rung.rawValue) has no label")
            XCTAssertLessThanOrEqual(rung.label.count, 8,
                                     "\(rung.label) is too long for one of four segments on a phone")
        }
        XCTAssertEqual(Set(ProjectStickiness.allCases.map(\.label)).count, ProjectStickiness.allCases.count,
                       "two rungs read the same on the control")
    }

    // MARK: The forwarding constant

    /// FEAT-018's name still resolves to FEAT-018's number, so the three docstrings that cite it are not lying.
    func testTheOldConstantStillNamesTheDefaultWindow() {
        XCTAssertEqual(LastProjectStore.stickyWindow, 10 * 60, accuracy: 0.001)
    }
}
