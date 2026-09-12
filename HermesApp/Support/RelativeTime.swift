import Foundation

/// Thread-list timestamps: the backend has no `updated_at`, so recency is `last_active` (`MAX(messages.timestamp)`), one epoch-seconds field.
enum RelativeTime {
    private static let relative: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        formatter.dateTimeStyle = .numeric
        return formatter
    }()

    private static let sameDay: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter
    }()

    private static let older: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    /// "just now" / "5m ago" / "3d ago" — for a dense list row.
    static func short(_ date: Date, now: Date = Date()) -> String {
        let interval = now.timeIntervalSince(date)
        if date.timeIntervalSince1970 <= 0 { return "" }
        if interval < 45 { return "just now" }
        if interval < 0 { return relative.localizedString(for: date, relativeTo: now) }
        return relative.localizedString(for: date, relativeTo: now)
    }

    static func short(epochSeconds: Double, now: Date = Date()) -> String {
        guard epochSeconds > 0 else { return "" }
        return short(Date(timeIntervalSince1970: epochSeconds), now: now)
    }

    /// Absolute timestamp for a detail header or a diagnostics row.
    static func absolute(_ date: Date, now: Date = Date()) -> String {
        Calendar.current.isDate(date, inSameDayAs: now)
            ? sameDay.string(from: date)
            : older.string(from: date)
    }

    /// Countdown for a blocking prompt: an unanswered approval hangs the agent for 300 s and then fails the tool closed.
    static func countdown(remaining: TimeInterval) -> String {
        let clamped = max(0, remaining)
        let minutes = Int(clamped) / 60
        let seconds = Int(clamped) % 60
        if minutes > 0 { return String(format: "%d:%02d", minutes, seconds) }
        return "\(seconds)s"
    }

    static func duration(_ seconds: Double) -> String {
        if seconds < 1 { return String(format: "%.0f ms", seconds * 1000) }
        if seconds < 60 { return String(format: "%.1f s", seconds) }
        let minutes = Int(seconds) / 60
        let remainder = Int(seconds) % 60
        return "\(minutes)m \(remainder)s"
    }
}
