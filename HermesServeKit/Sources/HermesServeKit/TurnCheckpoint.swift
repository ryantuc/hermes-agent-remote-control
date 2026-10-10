import Foundation

/// Display state and its replay cursor are one atomic checkpoint. Never contains credentials,
/// pending approvals, or requests to submit again. Valid only within the original server epoch.
public struct TurnCheckpoint: Codable, Sendable {
    public let sessionID: String
    let epoch: String
    public let sequence: Int
    let entries: [ChatEntry]
    let persistedAssistantPrefix: String
    let assistantSegmentIDs: [String]
    let executionID: String?
    let observedExecutions: [String]
    let observedInputIDs: Set<String>
    let turnStartedAt: Date?
    let streamingEntryID: String?
    let entryCounter: Int
    let syntheticToolCounter: Int
    let references: [String: String]
    let bindings: [String: String]
}
