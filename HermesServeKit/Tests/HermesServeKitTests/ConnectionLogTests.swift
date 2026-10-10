import Foundation
import XCTest

@testable import HermesServeKit

/// BUG-110 leg 2 — `ConnectionLog` had no test of any kind, and it is what Diagnostics shows and what a user pastes into a bug report: if it stopped redacting, bounding or ordering, nothing went red.
final class ConnectionLogTests: XCTestCase {

    // MARK: Recording

    func testEntriesKeepTheirOrderLevelAndCategory() async {
        let log = ConnectionLog()
        await log.debug("rpc", "one")
        await log.info("gateway", "two")
        await log.warning("http", "three")
        await log.error("auth", "four")

        let entries = await log.entries()
        XCTAssertEqual(entries.map(\.message), ["one", "two", "three", "four"])
        XCTAssertEqual(entries.map(\.level), [.debug, .info, .warning, .error])
        XCTAssertEqual(entries.map(\.category), ["rpc", "gateway", "http", "auth"])
        XCTAssertEqual(Set(entries.map(\.id)).count, 4, "every entry is its own row in Diagnostics' list")
    }

    func testRecordIsWhatTheConvenienceMethodsCall() async {
        let log = ConnectionLog()
        await log.record(.warning, "gateway", "said directly")
        let entry = await log.entries().first
        XCTAssertEqual(entry?.level, .warning)
        XCTAssertEqual(entry?.category, "gateway")
        XCTAssertEqual(entry?.message, "said directly")
    }

    // MARK: Bounds

    /// The buffer is a window, not a history: past capacity the oldest entries go, so a long session cannot grow it without bound.
    func testTheOldestEntriesGoPastCapacity() async {
        let log = ConnectionLog(capacity: 40)
        for index in 0..<50 { await log.info("rpc", "entry \(index)") }

        let entries = await log.entries()
        XCTAssertEqual(entries.count, 40)
        XCTAssertEqual(entries.first?.message, "entry 10", "the ten oldest must be the ones dropped")
        XCTAssertEqual(entries.last?.message, "entry 49")
    }

    /// A tiny capacity would turn the log into a single line; the floor keeps enough context to read a reconnect.
    func testCapacityHasAFloorOf32() async {
        let log = ConnectionLog(capacity: 1)
        for index in 0..<40 { await log.info("rpc", "entry \(index)") }
        let count = await log.entries().count
        XCTAssertEqual(count, 32)
    }

    func testTheDefaultCapacityIs400() async {
        let log = ConnectionLog()
        for index in 0..<410 { await log.debug("rpc", "entry \(index)") }
        let entries = await log.entries()
        XCTAssertEqual(entries.count, 400)
        XCTAssertEqual(entries.first?.message, "entry 10")
    }

    func testLongMessagesAreTruncated() async {
        let log = ConnectionLog()
        await log.info("gateway", String(repeating: "x", count: 700))
        let message = await log.entries().first?.message ?? ""
        XCTAssertEqual(message.count, 601, "600 characters plus the ellipsis")
        XCTAssertTrue(message.hasSuffix("…"))
    }

    // MARK: Redaction

    /// There is no unsanitized path into this buffer: a credential in a message is scrubbed before it is stored, so neither the list nor the export can show it.
    func testCredentialsAreRedactedOnTheWayIn() async {
        let log = ConnectionLog()
        await log.warning("http", "GET https://backend.example/api/ws?token=sekret-ticket-123456 failed")
        await log.debug("http", "Authorization: Bearer abcdefghijklmnopqrstuvwxyz0123")

        let messages = await log.entries().map(\.message)
        XCTAssertFalse(messages.contains { $0.contains("sekret-ticket-123456") }, "a query-string ticket reached the log: \(messages)")
        XCTAssertFalse(messages.contains { $0.contains("abcdefghijklmnopqrstuvwxyz0123") }, "a bearer token reached the log: \(messages)")
        XCTAssertTrue(messages.allSatisfy { $0.contains(Redaction.mask) }, "the scrub must leave a visible mask, not silently delete")

        let export = await log.export()
        XCTAssertFalse(export.contains("sekret-ticket-123456"))
        XCTAssertFalse(export.contains("abcdefghijklmnopqrstuvwxyz0123"))
    }

    // MARK: Clear and export

    func testClearEmptiesTheBuffer() async {
        let log = ConnectionLog()
        await log.info("gateway", "connected")
        await log.clear()
        let entries = await log.entries()
        XCTAssertTrue(entries.isEmpty)
        let export = await log.export()
        XCTAssertEqual(export, "")
    }

    /// One line per entry, oldest first, each with a timestamp, the level in capitals, the category and the message.
    func testExportIsOneLinePerEntry() async {
        let log = ConnectionLog()
        await log.info("gateway", "connected")
        await log.warning("rpc", "send failed: timed out")

        let lines = await log.export().components(separatedBy: "\n")
        XCTAssertEqual(lines.count, 2)
        XCTAssertTrue(lines[0].hasSuffix("[INFO] gateway: connected"), lines[0])
        XCTAssertTrue(lines[1].hasSuffix("[WARNING] rpc: send failed: timed out"), lines[1])
        let stamp = lines[0].components(separatedBy: " ").first ?? ""
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        XCTAssertNotNil(
            formatter.date(from: stamp),
            "the line must open with an ISO-8601 timestamp a reader can sort on; got \(stamp)"
        )
    }

    // MARK: Backend attribution (BUG-143)

    /// One log per app, many backends per launch: a switch is marked once, and every entry after it says which machine it came from.
    func testEnteringABackendMarksTheTrailAndLabelsWhatFollows() async {
        let log = ConnectionLog()
        await log.info("gateway", "before any backend")
        await log.enterBackend(key: "https://desk.example|", label: "desk")
        await log.info("gateway", "connected")
        await log.enterBackend(key: "https://desk.example|", label: "desk")
        await log.enterBackend(key: "https://laptop.example|", label: "laptop")
        await log.info("gateway", "connected")

        let entries = await log.entries()
        XCTAssertEqual(entries.map(\.message), [
            "before any backend",
            "— now on desk —",
            "connected",
            "— now on laptop —",
            "connected",
        ], "re-entering the backend already in use is not a switch and must not mark the trail")
        XCTAssertEqual(entries.map(\.backend), [nil, "desk", "desk", "laptop", "laptop"])
        XCTAssertEqual(entries[1].category, "backend")
    }

    /// The same machine under a new name relabels what follows without a divider, because nothing was switched.
    func testARenameRelabelsWithoutMarkingTheTrail() async {
        let log = ConnectionLog()
        await log.enterBackend(key: "k", label: "workstation")
        await log.enterBackend(key: "k", label: "the mac mini")
        await log.info("gateway", "connected")

        let entries = await log.entries()
        XCTAssertEqual(entries.map(\.message), ["— now on workstation —", "connected"])
        XCTAssertEqual(entries.last?.backend, "the mac mini")
    }

    func testTheExportNamesTheBackendOnEveryLine() async {
        let log = ConnectionLog()
        await log.info("gateway", "unattributed")
        await log.enterBackend(key: "k", label: "laptop")
        await log.warning("rpc", "send failed")

        let lines = await log.export().components(separatedBy: "\n")
        XCTAssertTrue(lines[0].hasSuffix("[INFO] gateway: unattributed"), lines[0])
        XCTAssertTrue(lines[1].hasSuffix("[INFO] (laptop) backend: — now on laptop —"), lines[1])
        XCTAssertTrue(lines[2].hasSuffix("[WARNING] (laptop) rpc: send failed"), lines[2])
    }

    /// A label is a display name or an address, and an address can carry a credential; it is scrubbed like a message.
    func testTheBackendLabelIsRedacted() async {
        let log = ConnectionLog()
        await log.enterBackend(key: "k", label: "https://backend.example/?token=sekret-ticket-123456")
        await log.info("gateway", "connected")

        let entries = await log.entries()
        XCTAssertFalse(entries.contains { ($0.backend ?? "").contains("sekret-ticket-123456") || $0.message.contains("sekret-ticket-123456") })
        XCTAssertTrue(entries.last?.backend?.contains(Redaction.mask) ?? false)
    }
}
