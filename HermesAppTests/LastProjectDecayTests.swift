import Foundation
import XCTest

@testable import HermesMobile

/// FEAT-018 — the last-used project decays instead of governing forever.
///
/// FEAT-001 made a new conversation start in the project the last one used. The value is "I am starting three conversations about this repo right now"; the cost was that a project picked once silently governed the conversation started days later about something else. A time window turns the sticky global back into a session-scoped convenience.
///
/// **The keys are written by hand here rather than through the store's own API**, so that every one of these tests compiles and runs against the unfixed tree and reports a real failure rather than a build error. They are the literal `UserDefaults` keys the store owns; if a key is renamed, this file fails and that is correct — the stored name is the thing the phone already has on disk.
///
/// The window itself is deliberately never named here. These pin that it is minutes rather than seconds and minutes rather than days, which is the requirement; the exact figure lives in one constant in the store and is free to move without editing a test.
final class LastProjectDecayTests: XCTestCase {

    private var defaults: UserDefaults!
    private let suiteName = "feat-018-last-project-decay-tests"
    private let profile = UUID()
    private let path = "/Users/you/work/hermes"

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

    // MARK: The store's keys, spelled out

    private func pathKey(_ id: UUID?) -> String {
        "hermes.project.last." + (id?.uuidString ?? "none")
    }

    private func stampKey(_ id: UUID?) -> String {
        "hermes.project.lastAt." + (id?.uuidString ?? "none")
    }

    /// A project remembered `age` seconds ago, written straight into the store's
    /// keys so the test controls the clock rather than waiting on it.
    private func store(_ path: String, secondsAgo age: TimeInterval, profileID: UUID?) {
        defaults.set(path, forKey: pathKey(profileID))
        defaults.set(Date().timeIntervalSince1970 - age, forKey: stampKey(profileID))
    }

    // MARK: 1 — a pick is stamped

    func testAPickRecordsWhenItWasMade() {
        LastProjectStore.remember(path, profileID: profile, defaults: defaults)

        guard let stamp = defaults.object(forKey: stampKey(profile)) as? Double else {
            return XCTFail("""
                nothing was written to \(stampKey(profile)). Without a timestamp beside the path \
                there is nothing for a window to be measured against, and the seed is permanent \
                again (FEAT-018)
                """)
        }
        XCTAssertEqual(stamp, Date().timeIntervalSince1970, accuracy: 5, """
            the pick was stamped \(Date().timeIntervalSince1970 - stamp) s away from now
            """)
    }

    // MARK: 2 — the window

    func testAProjectPickedAMomentAgoIsStillSeeded() {
        store(path, secondsAgo: 5, profileID: profile)
        XCTAssertEqual(
            LastProjectStore.remembered(profileID: profile, defaults: defaults),
            path,
            "the whole point of FEAT-001 is the next draft in the same working session"
        )
    }

    func testAProjectPickedYesterdayIsNotSeededAgain() {
        store(path, secondsAgo: 24 * 60 * 60, profileID: profile)
        XCTAssertNil(
            LastProjectStore.remembered(profileID: profile, defaults: defaults),
            """
            a project picked a day ago still seeds a fresh draft. That is the behaviour the \
            window exists to time-box: a conversation started days later about something \
            unrelated opens inside yesterday's repo (FEAT-018)
            """
        )
    }

    /// The window is minutes, not seconds and not days. Asserted as a bracket
    /// rather than as the constant's value, so tuning the figure does not
    /// require editing a test — only leaving the class of behaviour intact does.
    func testTheWindowIsMinutesWideNotSecondsAndNotHours() {
        store(path, secondsAgo: 60, profileID: profile)
        XCTAssertEqual(
            LastProjectStore.remembered(profileID: profile, defaults: defaults),
            path,
            "a minute-old pick expired — the window has collapsed to something shorter than a pause for thought"
        )

        store(path, secondsAgo: 60 * 60, profileID: profile)
        XCTAssertNil(
            LastProjectStore.remembered(profileID: profile, defaults: defaults),
            "an hour-old pick still seeds — the window is not the working-session length that was asked for"
        )
    }

    /// Expiry hides the value; it does not delete it. `remembered` is read from
    /// `HomeView.seededCwd`, a computed property evaluated inside a view body,
    /// and a body that writes to `UserDefaults` is a side effect on every
    /// redraw. The row is left alone and simply stops answering.
    func testAnExpiredPickIsHiddenRatherThanErased() {
        store(path, secondsAgo: 24 * 60 * 60, profileID: profile)
        _ = LastProjectStore.remembered(profileID: profile, defaults: defaults)
        XCTAssertEqual(
            defaults.string(forKey: pathKey(profile)),
            path,
            "reading an expired value erased it — a read must not write"
        )
    }

    // MARK: 3 — the upgrade, and the edges

    /// A device upgrading from FEAT-001 carries a stored value with no stamp beside it, and there is no honest age for it, so it expires: the first fresh draft after the upgrade opens on the backend's default and the next pick starts the window properly.
    func testAValueStoredBeforeTheWindowExistedIsNotSeeded() {
        defaults.set(path, forKey: pathKey(profile))
        XCTAssertNil(
            LastProjectStore.remembered(profileID: profile, defaults: defaults),
            """
            a path with no timestamp beside it was seeded anyway, which is every value already on \
            a phone that ran FEAT-001 — the decay would not begin until the next pick
            """
        )
    }

    /// A stamp in the future is a clock that moved, not a pick that has not
    /// happened yet. It fails closed: no seed, rather than one that cannot expire.
    func testAStampInTheFutureDoesNotSeed() {
        store(path, secondsAgo: -(24 * 60 * 60), profileID: profile)
        XCTAssertNil(
            LastProjectStore.remembered(profileID: profile, defaults: defaults),
            "a pick stamped in the future would outlive any window"
        )
    }

    /// Forgetting a profile has to take the stamp with it, or a later path
    /// written under that profile inherits a window it never opened.
    func testForgettingAProfileClearsItsStampToo() {
        LastProjectStore.remember(path, profileID: profile, defaults: defaults)
        LastProjectStore.forget(profileID: profile, defaults: defaults)
        defaults.set(path, forKey: pathKey(profile))

        XCTAssertNil(
            LastProjectStore.remembered(profileID: profile, defaults: defaults),
            """
            a stamp survived `forget` and is still inside its window, so a path written under \
            this profile afterwards is seeded on the strength of a pick that was thrown away
            """
        )
    }

    /// Per-profile isolation is FEAT-001's rule and the window must not blur it:
    /// two backends are two machines, and one machine's clock does not open the
    /// other's window.
    func testOneProfilesWindowDoesNotOpenAnothers() {
        store(path, secondsAgo: 5, profileID: profile)
        let other = UUID()
        defaults.set("/srv/matters/station-casinos", forKey: pathKey(other))

        XCTAssertNil(
            LastProjectStore.remembered(profileID: other, defaults: defaults),
            "the second profile has no stamp of its own and was seeded off the first one's"
        )
    }
}
