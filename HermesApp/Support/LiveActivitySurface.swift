import ActivityKit
import Foundation
import HermesServeKit

/// The one door between `LiveActivityController` and ActivityKit: the controller
/// never names ActivityKit, so its lifecycle is testable against a fake.
@MainActor
protocol LiveActivitySurface {
    /// The system switch, which the user sets independently of our master toggle.
    var isAuthorized: Bool { get }

    /// Start a card. Throws exactly what `Activity.request` throws.
    func request(
        attributes: HermesActivityAttributes,
        snapshot: LiveActivitySnapshot,
        staleDate: Date?
    ) throws -> LiveActivityHandle

    /// Every activity the system holds for this app, including ones this process
    /// never started — a card outlives the process that made it.
    func existing() -> [LiveActivityHandle]
}

/// One live card, class-constrained so the controller and a test read the same
/// handle rather than two copies that drift apart.
@MainActor
protocol LiveActivityHandle: AnyObject {
    /// ActivityKit's own identifier. Logged, never matched on.
    var id: String { get }
    /// The runtime session id this card was requested for.
    var sessionKey: String { get }

    /// Push new content. A nil `staleDate` means the card carries none.
    func update(_ snapshot: LiveActivitySnapshot, staleDate: Date?)

    /// End the card: a nil `removeAt` removes it immediately, a date is `.after`.
    /// Never `.default` — that leaves an ended card up for up to four hours.
    func end(_ snapshot: LiveActivitySnapshot?, removeAt: Date?)

    /// Report state changes: the system moves a card out from under us and this
    /// is the only notice of that.
    func observeState(_ onChange: @escaping @MainActor (LiveActivityHandleState) -> Void)
}

/// `ActivityState` without the platform type. `.dismissed` is the user's own
/// swipe and earns a suppression for the turn; `.ended` does not.
enum LiveActivityHandleState: String, Sendable, Equatable {
    case active
    case stale
    case dismissed
    case ended
    case unknown
}

// MARK: - The production surface

/// Straight pass-through to ActivityKit; any decision belongs in the controller.
@MainActor
struct ActivityKitSurface: LiveActivitySurface {
    var isAuthorized: Bool { ActivityAuthorizationInfo().areActivitiesEnabled }

    func request(
        attributes: HermesActivityAttributes,
        snapshot: LiveActivitySnapshot,
        staleDate: Date?
    ) throws -> LiveActivityHandle {
        let activity = try Activity.request(
            attributes: attributes,
            content: ActivityContent(state: snapshot, staleDate: staleDate),
            // No push token: everything shown here already arrives on the event stream (§5.3).
            pushType: nil
        )
        return ActivityKitHandle(activity: activity)
    }

    func existing() -> [LiveActivityHandle] {
        Activity<HermesActivityAttributes>.activities.map { ActivityKitHandle(activity: $0) }
    }
}

/// The real card: one per `Activity`, owning the task that watches its state.
@MainActor
private final class ActivityKitHandle: LiveActivityHandle {
    private let activity: Activity<HermesActivityAttributes>
    private var observation: Task<Void, Never>?

    init(activity: Activity<HermesActivityAttributes>) {
        self.activity = activity
    }

    var id: String { activity.id }
    var sessionKey: String { activity.attributes.sessionKey }

    func update(_ snapshot: LiveActivitySnapshot, staleDate: Date?) {
        Task { [activity] in
            await activity.update(ActivityContent(state: snapshot, staleDate: staleDate))
        }
    }

    func end(_ snapshot: LiveActivitySnapshot?, removeAt: Date?) {
        let policy: ActivityUIDismissalPolicy
        if let removeAt {
            policy = .after(removeAt)
        } else {
            policy = .immediate
        }
        Task { [activity] in
            await activity.end(
                snapshot.map { ActivityContent(state: $0, staleDate: nil) },
                dismissalPolicy: policy
            )
        }
    }

    func observeState(_ onChange: @escaping @MainActor (LiveActivityHandleState) -> Void) {
        observation?.cancel()
        observation = Task { [activity] in
            for await state in activity.activityStateUpdates {
                let mapped = LiveActivityHandleState(state)
                await MainActor.run { onChange(mapped) }
            }
        }
    }
}

extension LiveActivityHandleState {
    fileprivate init(_ state: ActivityState) {
        switch state {
        case .active: self = .active
        case .stale: self = .stale
        case .dismissed: self = .dismissed
        case .ended: self = .ended
        // A card accepted but not yet shown; naming it stops the warning.
        case .pending: self = .unknown
        @unknown default: self = .unknown
        }
    }
}
