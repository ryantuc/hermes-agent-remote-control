import Foundation
import Observation
import XCTest

@testable import HermesMobile

/// `withObservationTracking`'s `onChange` is `@Sendable`, so it cannot mutate a
/// captured `var` — the compiler refuses it. A reference box is the ordinary
/// way through, and the callback is synchronous (it runs inside the tracked
/// property's `willSet`), so nothing here races.
///
/// At file scope rather than nested in the test class, because a type nested in
/// a `@MainActor` type inherits that isolation and a main-actor box cannot be
/// touched from a non-isolated `@Sendable` closure.
private final class Fired: @unchecked Sendable {
    var value = false
}

/// BUG-108, made real by BUG-100.
///
/// The transcript preferences were plain `UserDefaults` statics with no change
/// publisher of any kind. That was survivable only by accident of the
/// navigation graph: every release route
/// into Settings from a conversation rewrote the whole path, so the reader —
/// `ChatView` and the four views under it — was always torn down before the
/// writer appeared, and the rebuilt chat re-evaluated its reads. BUG-108 was
/// therefore closed with no production change, on one stated condition: if a
/// release route that keeps `ChatView` mounted while Transcript settings is
/// edited is ever introduced, the verdict flips.
///
/// BUG-100's fix is exactly that route. The composer's shortcuts now push
/// instead of replacing, so the conversation stays on the stack underneath
/// Settings and a person can walk ⋯ → Customise → Back → This phone → Chat →
/// Transcript with the transcript alive one screen below. So the condition
/// fired, and this is the observation it calls for.
///
/// The implementation is deliberately the narrow one. Owning an instance at
/// `HermesMobileApp`, injecting it through the environment and converting
/// seven call sites would be a wide diff into `ChatView`, `MessageBubbleView`,
/// `ToolCardView` and `ConversationDisclosure`. Putting the observable object
/// *behind* the existing statics gets the same invalidation with no call site
/// changed at all.
@MainActor
final class TranscriptPreferencesObservationTests: XCTestCase {

    /// `HermesAppTests` is hosted in the app, so these statics are shared
    /// across every suite on the simulator and accumulate. Set, never assume —
    /// and put them back, because `TranscriptSelectionTests` reads them too.
    private var restore: [Bool] = []

    override func setUp() {
        super.setUp()
        restore = [
            TranscriptPreferences.groupRepeatedCalls,
            TranscriptPreferences.showDiffs,
            TranscriptPreferences.showCopyAction,
            TranscriptPreferences.toolCardsExpandByDefault,
        ]
    }

    override func tearDown() {
        TranscriptPreferences.groupRepeatedCalls = restore[0]
        TranscriptPreferences.showDiffs = restore[1]
        TranscriptPreferences.showCopyAction = restore[2]
        TranscriptPreferences.toolCardsExpandByDefault = restore[3]
        super.tearDown()
    }

    /// The property SwiftUI has to notice. `withObservationTracking` is the
    /// same machinery a view body runs inside, so a read that registers here is
    /// a read that invalidates there.
    func testGroupingIsObservedThroughTheStaticEveryViewAlreadyCalls() {
        TranscriptPreferences.groupRepeatedCalls = true

        let fired = Fired()
        withObservationTracking {
            _ = TranscriptPreferences.groupRepeatedCalls
        } onChange: {
            fired.value = true
        }

        TranscriptPreferences.groupRepeatedCalls = false
        XCTAssertTrue(fired.value, "a mounted transcript must repaint when the preference changes")
    }

    func testDiffVisibilityIsObserved() {
        TranscriptPreferences.showDiffs = true
        let fired = Fired()
        withObservationTracking {
            _ = TranscriptPreferences.showDiffs
        } onChange: { fired.value = true }
        TranscriptPreferences.showDiffs = false
        XCTAssertTrue(fired.value)
    }

    func testMessageActionMembershipIsObserved() {
        TranscriptPreferences.showCopyAction = true
        let fired = Fired()
        withObservationTracking {
            _ = TranscriptPreferences.showCopyAction
        } onChange: { fired.value = true }
        TranscriptPreferences.showCopyAction = false
        XCTAssertTrue(fired.value)
    }

    /// Reading one preference must not make a view depend on all seven — a
    /// transcript that repaints because the Retry button was hidden is the
    /// wrong kind of fix.
    func testOnlyTheReadPropertyIsObserved() {
        TranscriptPreferences.groupRepeatedCalls = true
        TranscriptPreferences.showDiffs = true

        let fired = Fired()
        withObservationTracking {
            _ = TranscriptPreferences.groupRepeatedCalls
        } onChange: { fired.value = true }

        TranscriptPreferences.showDiffs = false
        XCTAssertFalse(fired.value, "an unrelated preference must not invalidate this reader")
    }

    // MARK: The durable half, unchanged

    /// The observable object is the repaint; `UserDefaults` is still the store.
    /// A value written through the static has to survive the process, which is
    /// what a fresh store instance reading the same defaults proves.
    func testAWriteStillPersists() {
        TranscriptPreferences.groupRepeatedCalls = false
        XCTAssertEqual(
            UserDefaults.standard.object(forKey: TranscriptPreferences.Key.groupCalls) as? Bool,
            false
        )
        XCTAssertFalse(TranscriptPreferencesStore().groupRepeatedCalls, "a relaunch reads this back")

        TranscriptPreferences.groupRepeatedCalls = true
        XCTAssertTrue(TranscriptPreferencesStore().groupRepeatedCalls)
    }

    /// The defaults a phone that has never opened this screen gets. Grouping,
    /// diffs and all four message actions on; tool cards collapsed, because a
    /// transcript of expanded tool cards is a log file.
    func testAnUntouchedInstallKeepsItsDefaults() {
        let suite = "bug-108-\(UUID().uuidString)"
        let empty = UserDefaults(suiteName: suite)!
        defer { empty.removePersistentDomain(forName: suite) }
        let store = TranscriptPreferencesStore(defaults: empty)

        XCTAssertTrue(store.groupRepeatedCalls)
        XCTAssertTrue(store.showDiffs)
        XCTAssertTrue(store.showBranchAction)
        XCTAssertTrue(store.showCopyAction)
        XCTAssertTrue(store.showReadAloudAction)
        XCTAssertTrue(store.showRetryAction)
        XCTAssertFalse(store.toolCardsExpandByDefault)
    }

    /// The trap the wide design would have hit, as far as a unit test can carry it.
    ///
    /// `ToolCardView` reads the expansion preference into `@State` at
    /// construction, so a card already on screen keeps whatever the reader
    /// opened or closed; making the preference observable must not turn that
    /// default into a live command. What is assertable here is the half that
    /// can go wrong in this file — the preference is still a plain stored
    /// value that round-trips, not a binding — and that a fresh store seeded
    /// after a write reads the written value, which is what "default" means.
    /// Whether an *already mounted* card holds its own state is `@State`'s
    /// contract and belongs to a hand check on a device.
    func testTheExpansionPreferenceIsADefaultAFreshCardWouldRead() {
        TranscriptPreferences.toolCardsExpandByDefault = true
        XCTAssertTrue(TranscriptPreferencesStore().toolCardsExpandByDefault)
        TranscriptPreferences.toolCardsExpandByDefault = false
        XCTAssertFalse(TranscriptPreferencesStore().toolCardsExpandByDefault)
    }
}
