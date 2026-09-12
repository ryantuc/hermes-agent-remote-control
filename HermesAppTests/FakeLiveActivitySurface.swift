import ActivityKit
import Foundation
import HermesServeKit

@testable import HermesMobile

/// A `LiveActivitySurface` that records instead of calling ActivityKit.
///
/// This is the whole reason BUG-003 stage 0 exists. `Activity.request` refuses
/// outside a real entitled app process, and the Lock Screen card cannot be
/// inspected in a view hierarchy, driven by `simctl`, or photographed off a
/// tethered phone — so before the seam there was no way at all to ask the
/// question the bug is about: *when a turn ends, what does the card say, and
/// does it ever go away.* Everything the controller pushes lands here, in
/// order, where a test can read it.
@MainActor
final class FakeLiveActivitySurface: LiveActivitySurface {
    /// The system switch. True by default — a test that wants the refusal path
    /// sets it false, and the controller's cap collapses to zero.
    var isAuthorized = true

    /// Cards the *system* is holding that this process never started: an
    /// activity outlives the app that requested it. Seeding this is how the
    /// cold-launch orphan race is staged.
    var preexisting: [FakeLiveActivityHandle] = []

    /// Set to make the next `request` throw, standing in for the platform's own
    /// `targetMaximumExceeded`.
    var requestError: Error?

    /// BUG-116 — the app-state gate the real ActivityKit enforces and this fake
    /// did not.
    ///
    /// **Opt-in, and default OFF on purpose.** Every test written before this
    /// one staged its cards through a fake that handed back a handle
    /// unconditionally, and a fake that suddenly refused would rewrite the
    /// meaning of assertions those tests were never asked about. So the gate is
    /// a switch a new test turns on, and the old behaviour is what the switch
    /// being off means.
    ///
    /// It exists because the suite was green over a seam the platform enforces
    /// at runtime: `Activity.request` throws
    /// `ActivityAuthorizationError.visibility` — Apple's definition being *"The
    /// app tried to start the Live Activity while it was in the background"* —
    /// and there was no way to write a test that could see it. That is how
    /// BUG-116 shipped: a card the "Questions" mode can only ever ask for from
    /// the background, and a unit test insisting it appears.
    var enforcesForegroundRequirement = false

    /// Whether this fake's "app" is on screen. Only consulted when the gate
    /// above is on.
    var isForeground = true

    /// Every card this surface handed out, in request order. Kept rather than
    /// keyed by session, because "how many times did a card get torn down and
    /// re-requested for one session" is exactly the end/start thrash BUG-003 is
    /// about, and a dictionary would hide it.
    private(set) var requested: [FakeLiveActivityHandle] = []

    func request(
        attributes: HermesActivityAttributes,
        snapshot: LiveActivitySnapshot,
        staleDate: Date?
    ) throws -> LiveActivityHandle {
        if let requestError { throw requestError }
        // The real refusal, by its real name — not a stand-in. The controller
        // catches `ActivityAuthorizationError` separately from everything else,
        // so a generic error would exercise the wrong branch.
        if enforcesForegroundRequirement, !isForeground {
            throw ActivityAuthorizationError.visibility
        }
        let handle = FakeLiveActivityHandle(
            id: "fake-activity-\(requested.count + 1)",
            sessionKey: attributes.sessionKey
        )
        // The content a card is requested WITH is content it is showing, so it
        // counts as a push. Without this the first thing on the glass would be
        // invisible to every assertion.
        handle.update(snapshot, staleDate: staleDate)
        requested.append(handle)
        return handle
    }

    func existing() -> [LiveActivityHandle] {
        preexisting.map { $0 as LiveActivityHandle }
    }

    /// The most recent card requested for a session.
    ///
    /// This returns the **same object** the controller is holding — which is
    /// what `LiveActivityHandle: AnyObject` buys. With value semantics this
    /// would be a copy that stopped agreeing with the controller's the moment
    /// either one recorded anything, and every assertion below would be reading
    /// a stale duplicate rather than the card.
    func handle(for sessionKey: String) -> FakeLiveActivityHandle? {
        requested.last { $0.sessionKey == sessionKey }
    }

    /// How many separate cards this session has been given. More than one means
    /// a card was ended and a fresh one requested — the elapsed timer resets
    /// and the Dynamic Island slot is lost.
    func requestCount(for sessionKey: String) -> Int {
        requested.filter { $0.sessionKey == sessionKey }.count
    }

    /// Cards that have not been ended — the fake's answer to "what is on the
    /// glass right now".
    var liveHandles: [FakeLiveActivityHandle] { requested.filter { !$0.isEnded } }
}

/// One recorded card.
@MainActor
final class FakeLiveActivityHandle: LiveActivityHandle {
    let id: String
    let sessionKey: String

    /// Every snapshot pushed, oldest first, starting with the one the card was
    /// requested with.
    private(set) var pushed: [LiveActivitySnapshot] = []
    /// The stale date that rode with each push, same order.
    private(set) var staleDates: [Date?] = []

    private(set) var isEnded = false
    /// The content `end` carried, if any. `nil` means the card was ended
    /// showing whatever was already on it.
    private(set) var finalSnapshot: LiveActivitySnapshot?
    /// The dismissal date `end` carried. `nil` is `.immediate`.
    private(set) var removeAt: Date?

    private var onState: (@MainActor (LiveActivityHandleState) -> Void)?

    init(id: String, sessionKey: String) {
        self.id = id
        self.sessionKey = sessionKey
    }

    /// The last content the card was given, whichever call gave it. A handle is
    /// never used after `end`, so the final snapshot — when there is one — is
    /// always the latest thing on the glass.
    var lastContent: LiveActivitySnapshot? { finalSnapshot ?? pushed.last }

    func update(_ snapshot: LiveActivitySnapshot, staleDate: Date?) {
        pushed.append(snapshot)
        staleDates.append(staleDate)
    }

    func end(_ snapshot: LiveActivitySnapshot?, removeAt: Date?) {
        isEnded = true
        finalSnapshot = snapshot
        self.removeAt = removeAt
    }

    func observeState(_ onChange: @escaping @MainActor (LiveActivityHandleState) -> Void) {
        onState = onChange
    }

    /// Drive the controller's state observation — the user swiping the card
    /// away, or the system ending it out from under us.
    func send(_ state: LiveActivityHandleState) {
        onState?(state)
    }

    /// A one-line description for a failure message. Assertions print this
    /// rather than the whole snapshot: what matters is whether the card is
    /// telling the truth about the turn.
    var describeContent: String {
        guard let content = lastContent else { return "nothing was ever pushed" }
        return "isBusy=\(content.isBusy) hasEnded=\(content.hasEnded) status=\"\(content.statusText)\" tool=\"\(content.toolName)\" ended=\(isEnded)"
    }
}
