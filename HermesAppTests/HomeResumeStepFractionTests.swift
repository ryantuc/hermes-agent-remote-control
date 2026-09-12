import Foundation
import HermesServeKit
import XCTest

@testable import HermesMobile

/// FEAT-012 — the Home resume row is specified to read `working · step N of M` and the code never routed the count there, so a session's progress was invisible until you opened it.
///
/// The join under test is the interesting part: Home's rows are keyed by the durable `session_key`, the engine's roster by the gateway's in-memory id, and `session.active_list` is the only row where both appear. These drive the real wire path — an `active_list` reply and a `tool.complete` frame — rather than poking the engine, so the id join is actually exercised.
@MainActor
final class HomeResumeStepFractionTests: XCTestCase {

    /// Three settled of seven, on a session this phone has never opened.
    private nonisolated static func todoPayload() -> JSONValue {
        var items: [JSONValue] = []
        let statuses = ["completed", "completed", "cancelled", "in_progress", "pending", "pending", "pending"]
        for (index, status) in statuses.enumerated() {
            items.append(.object([
                "id": .string("t\(index)"),
                "content": .string("step \(index)"),
                "status": .string(status),
            ]))
        }
        return .object([
            "id": .string("call-todo"),
            "name": .string("todo"),
            "todos": .array(items),
        ])
    }

    private nonisolated static func activeList(status: String = "working") -> JSONValue {
        .object(["sessions": .array([
            .object([
                "id": .string("rt-live"),
                "session_key": .string("stored-live"),
                "title": .string("Running somewhere else"),
                "status": .string(status),
                "last_active": .number(Date().timeIntervalSince1970),
            ]),
        ])])
    }

    func testTheResumeRowExposesTheStepFractionForALiveSession() async throws {
        let harness = await AppHarness.make()
        try await harness.openSocket()

        await harness.backend.stub("session.active_list") { _ in Self.activeList() }
        await harness.app.refreshThreads(force: true)
        XCTAssertEqual(
            harness.app.liveStatus(forStoredID: "stored-live")?.id,
            "rt-live",
            "precondition: the durable→runtime join has landed"
        )

        await harness.backend.emit("tool.complete", sessionID: "rt-live", payload: Self.todoPayload())
        let landed = await waitUntil { harness.app.engine.state(for: "rt-live").activity.todos.total == 7 }
        XCTAssertTrue(landed, "precondition: the engine took the plan")

        XCTAssertEqual(
            harness.app.liveStepFraction(for: "stored-live"),
            "3/7",
            "the count already exists in the engine — the resume row never routed it"
        )

        await harness.tearDown()
    }

    func testALiveSessionWithNoPlanYetShowsNoFraction() async throws {
        let harness = await AppHarness.make()
        try await harness.openSocket()

        await harness.backend.stub("session.active_list") { _ in Self.activeList() }
        await harness.app.refreshThreads(force: true)
        XCTAssertTrue(harness.app.isLiveWorking("stored-live"), "precondition: the row is live")

        XCTAssertNil(
            harness.app.liveStepFraction(for: "stored-live"),
            "a plan that has not been fetched is a blank, not 0/0 — Home is the surface people trust at a glance"
        )

        await harness.tearDown()
    }

    func testAnIdleSessionShowsNoFraction() async throws {
        let harness = await AppHarness.make()
        try await harness.openSocket()

        await harness.backend.stub("session.active_list") { _ in .object(["sessions": .array([])]) }
        await harness.app.refreshThreads(force: true)

        XCTAssertNil(
            harness.app.liveStepFraction(for: "stored-idle"),
            "no active_list row means no runtime id and no engine state to read"
        )

        await harness.tearDown()
    }
}
