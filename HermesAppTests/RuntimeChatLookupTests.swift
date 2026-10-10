import Foundation
import HermesServeKit
import XCTest

@testable import HermesMobile

/// BUG-074 leg B — the flush loop publishes every touched session about every 33 ms, and each publish found its chat by scanning every open chat; a streaming turn paid that scan on every tick, multiplied by the number of chats open.
///
/// The index that replaces the scan is a cache in front of a dictionary nobody can observe directly, so the second half of this file pins that it never answers wrongly: not after a rebind, and not for a chat that has been released.
@MainActor
final class RuntimeChatLookupTests: XCTestCase {

    func testPublishingAStreamingSessionDoesNotScanEveryOpenChat() async throws {
        let harness = await AppHarness.make()
        // Registered before the socket opens, so the post-open sweep binds every one of them.
        for index in 0..<12 {
            harness.chat(storedID: "20261002_1000\(String(format: "%02d", index))_crowd")
        }
        try await harness.openSocket()
        let target = harness.chat(storedID: "20261002_110000_streaming")
        await target.open()
        let runtimeID = try XCTUnwrap(target.runtimeSessionID, "precondition: the chat never bound")

        let before = harness.app.runtimeChatLookupScans
        for _ in 0..<50 { harness.app.publish(sessionID: runtimeID) }
        let scans = harness.app.runtimeChatLookupScans - before

        XCTAssertLessThanOrEqual(
            scans,
            1,
            "fifty flush ticks for one streaming session scanned the open chats \(scans) times — the lookup is linear on the hot path, once per tick per touched session"
        )
        XCTAssertTrue(harness.app.chat(runtimeSessionID: runtimeID) === target, "the lookup must still find the streaming chat")

        await harness.tearDown()
    }

    /// A chat that re-resumes gets a new runtime id; the old id must stop answering and the new one must start.
    func testALookupFollowsAChatThatRebinds() async throws {
        let harness = await AppHarness.make()
        try await harness.openSocket()
        let chat = harness.chat(storedID: "20261002_111500_rebind")
        await chat.open()
        let first = try XCTUnwrap(chat.runtimeSessionID)
        harness.app.publish(sessionID: first)
        XCTAssertTrue(harness.app.chat(runtimeSessionID: first) === chat, "precondition")

        // A rebuild for a new credential keeps the chat and re-resumes it on the new socket, which mints a new runtime id (ProfileSaveTests RED-4).
        let profile = try XCTUnwrap(harness.app.activeProfile)
        harness.app.update(profile, credentialsChanged: true)
        let rebound = await waitUntil(timeout: 10) {
            chat.runtimeSessionID != nil && chat.runtimeSessionID != first
        }
        XCTAssertTrue(rebound, "precondition: the preserved chat was never re-resumed on the new socket")
        let second = try XCTUnwrap(chat.runtimeSessionID)

        XCTAssertNil(harness.app.chat(runtimeSessionID: first), "a runtime id the chat has given up still answers with that chat")
        XCTAssertTrue(harness.app.chat(runtimeSessionID: second) === chat, "the chat's new runtime id does not find it")

        await harness.tearDown()
    }

    /// A released chat must not be reachable through a lookup that had found it before.
    func testAReleasedChatIsNotFoundByItsRuntimeID() async throws {
        let harness = await AppHarness.make()
        try await harness.openSocket()
        let chat = harness.chat(storedID: "20261002_112000_release")
        await chat.open()
        let runtimeID = try XCTUnwrap(chat.runtimeSessionID)
        harness.app.publish(sessionID: runtimeID)
        XCTAssertTrue(harness.app.chat(runtimeSessionID: runtimeID) === chat, "precondition")
        XCTAssertTrue(chat.isReleasable, "precondition: nothing pins this chat in memory")

        harness.app.releaseChats(keeping: [])

        XCTAssertFalse(harness.app.containsChat(chat), "precondition: the chat was released")
        XCTAssertNil(
            harness.app.chat(runtimeSessionID: runtimeID),
            "the event pump can still reach a chat the app released, and would publish turn state into a model no screen holds"
        )

        await harness.tearDown()
    }
}
