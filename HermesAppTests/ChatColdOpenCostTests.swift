import Foundation
import XCTest

@testable import HermesMobile
@testable import HermesServeKit

/// BUG-121 — cold open cost, spinner window, and A2 isLoading/isBinding split.
@MainActor
final class ChatColdOpenCostTests: XCTestCase {

    private enum Wire {
        static func resumeResult(runtime: String, key: String) -> JSONValue {
            .object([
                "session_id": .string(runtime),
                "session_key": .string(key),
                "resumed": .string(key),
                "messages": .array([]),
                "running": .bool(false),
                "status": .string("idle"),
                "watching": .bool(false),
            ])
        }
    }

    /// A2: after loadTranscript returns (even nil on dead REST), isLoading is
    /// false while resume is gated; isBinding is true; isReleasable is false.
    func testIsLoadingEndsBeforeResumeWhileIsBindingGuardsEviction() async throws {
        let harness = await AppHarness.make()
        try await harness.openSocket()

        let storedID = "20260828_bug121_a2_split"
        await harness.backend.gate("session.resume")
        await harness.backend.stub("session.resume") { call in
            Wire.resumeResult(runtime: "rt-a2-split", key: call.sessionID)
        }

        let chat = harness.chat(storedID: storedID)
        let openTask = Task { await chat.open() }

        let parked = await waitUntil(timeout: 3) {
            await harness.backend.parkedCount >= 1
        }
        XCTAssertTrue(parked, "resume never parked")

        // Dead REST finishes load instantly; A2 clears isLoading before bind.
        XCTAssertFalse(
            chat.isLoading,
            "BUG-121 A2: isLoading must be false once transcript fetch settled, even mid-resume"
        )
        XCTAssertTrue(
            chat.isBinding,
            "BUG-121 A2: isBinding must be true while session.resume is in flight"
        )
        XCTAssertFalse(
            chat.isReleasable,
            "A8 must still refuse eviction while binding"
        )

        openTask.cancel()
        _ = await openTask.result
        await harness.backend.ungate("session.resume")
        await harness.backend.releaseParked()

        await harness.tearDown()
    }

    /// After a completed open, release forces a cold path on a fresh model.
    func testReleaseForcesAColdOpenOnTheNextVisit() async throws {
        let harness = await AppHarness.make()
        try await harness.openSocket()

        let storedID = "20260828_bug121_cold_again"
        let first = harness.chat(storedID: storedID)
        await first.open()
        let bound = await waitUntil { first.runtimeSessionID != nil }
        XCTAssertTrue(bound, "first open never bound")
        first.errorMessage = nil
        XCTAssertTrue(first.hasLoadedOnce)
        XCTAssertFalse(first.isLoading)
        XCTAssertFalse(first.isBinding)
        XCTAssertTrue(first.isReleasable, "idle completed open must be releasable")

        let released = harness.app.releaseChats(keeping: [])
        XCTAssertEqual(released, 1)

        let second = harness.chat(storedID: storedID)
        XCTAssertFalse(second === first, "release must mint a fresh ChatModel")
        XCTAssertFalse(second.hasLoadedOnce, "fresh model must not claim hasLoadedOnce")
        XCTAssertTrue(second.entries.isEmpty)

        // Gate resume so we can sample the in-flight flags. With A2 the
        // spinner window (isLoading && empty) is only the loadTranscript beat;
        // on dead REST that is microseconds, so we assert the bind window
        // instead: empty entries + isBinding, which is still a cold open the
        // user sees as pending gap / empty until resume returns.
        await harness.backend.gate("session.resume")
        let openTask = Task { await second.openIfNeeded() }
        let sawBindEmpty = await waitUntil(timeout: 3) {
            second.isBinding && second.entries.isEmpty && !second.isLoading
        }
        XCTAssertTrue(
            sawBindEmpty,
            """
            Cold open after release must enter isBinding with empty entries after \
            load settles (A2). Spinner is load-only; bind still blocks release.
            """
        )
        await harness.backend.ungate("session.resume")
        await harness.backend.releaseParked()
        _ = await openTask.result

        await harness.tearDown()
    }

    func testProjectingALargeTranscriptStaysUnder100Milliseconds() throws {
        var rows: [TranscriptMessage] = []
        for i in 0..<200 {
            if i % 2 == 0 {
                rows.append(TranscriptMessage(json: .object([
                    "id": .number(Double(i)),
                    "role": .string("user"),
                    "content": .string("user message \(i) with enough text to exercise redaction and plainText"),
                    "timestamp": .number(1_700_000_000 + Double(i)),
                ])))
            } else {
                rows.append(TranscriptMessage(json: .object([
                    "id": .number(Double(i)),
                    "role": .string("assistant"),
                    "content": .string(String(repeating: "assistant reply \(i). ", count: 20)),
                    "timestamp": .number(1_700_000_000 + Double(i)),
                    "tool_calls": .array([
                        .object([
                            "id": .string("call-\(i)"),
                            "name": .string("terminal"),
                            "arguments": .string("{\"cmd\":\"echo \(i)\"}"),
                        ]),
                    ]),
                ])))
                rows.append(TranscriptMessage(json: .object([
                    "id": .number(Double(i) + 0.5),
                    "role": .string("tool"),
                    "tool_call_id": .string("call-\(i)"),
                    "content": .string("ok \(i)"),
                    "timestamp": .number(1_700_000_000 + Double(i) + 0.1),
                ])))
            }
        }
        let page = TranscriptPage(
            sessionID: "proj-cost",
            messages: rows,
            limit: nil,
            offset: 0,
            returned: rows.count
        )

        let start = ContinuousClock.now
        let projected = ChatModel.projectTranscriptWithOrdinals(page)
        let ms = (ContinuousClock.now - start).intervalMilliseconds

        XCTAssertFalse(projected.entries.isEmpty, "projection must produce rows")
        XCTAssertLessThan(
            ms,
            100,
            "projectTranscriptWithOrdinals took \(ms) ms for \(rows.count) rows → \(projected.entries.count) entries"
        )
    }
}

private extension Duration {
    var intervalMilliseconds: Double {
        let comps = self.components
        return Double(comps.seconds) * 1000 + Double(comps.attoseconds) / 1e15
    }
}
