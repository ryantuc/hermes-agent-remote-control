import Foundation

/// How long the turn on screen has actually been running: the backend's `turn_started_at` on `session.info` wins over this client's local stamp whenever it has spoken (FEAT-010).
enum TurnElapsed {
    static func origin(backendStart: Date?, localStart: Date) -> Date {
        backendStart ?? localStart
    }

    /// Seconds to display, never negative: the two clocks are unsynchronised, so a backend start a second or two ahead of this phone is ordinary.
    static func seconds(backendStart: Date?, localStart: Date, now: Date = Date()) -> TimeInterval {
        max(0, now.timeIntervalSince(origin(backendStart: backendStart, localStart: localStart)))
    }
}
