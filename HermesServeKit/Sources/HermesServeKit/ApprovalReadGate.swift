import Foundation

/// The approval sheet's read gate: a command too long for its window keeps every allow choice dead until the user scrolls to the end, and deny is never gated.
public enum ApprovalReadGate {
    /// How close to the bottom counts as read, in points.
    public static let bottomSlack: Double = 24

    /// `nil` means not enough information yet and the caller must not latch either way, because the two heights arrive from separate layout passes and an unset one reads as "it all fits".
    public static func isRead(
        containerHeight: Double,
        contentHeight: Double,
        offset: Double
    ) -> Bool? {
        guard containerHeight > 0, contentHeight > 0 else { return nil }
        if contentHeight <= containerHeight + 1 { return true }
        return offset + containerHeight >= contentHeight - bottomSlack
    }
}
