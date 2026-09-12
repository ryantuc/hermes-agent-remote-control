import Foundation
import HermesServeKit
import XCTest

@testable import HermesMobile

/// BUG-005 — "the first tap on a project in Projects mode does nothing".
///
/// The report is a dance: tap a project, nothing appears, tap again to
/// collapse, tap a third time, and *now* the sessions are there. Every one of
/// these tests is a different way into the same hole — `ProjectGroupModel`
/// letting a section be expanded with no body to draw — plus the cost of the
/// dance itself, since each `projects.project_sessions` is a full tree rebuild
/// on the backend (~2.2 s measured, DECISIONS 19) and the impatient second tap
/// throws the first one away.
///
/// Every test opens the socket first: `HermesClient.request` throws
/// `.notConnected` on a closed one, which would fail these for the wrong
/// reason.
final class ProjectGroupModelTests: XCTestCase {

    /// The first tap paints something, in the same frame as the tap.
    @MainActor
    func testExpandedSectionAlwaysHasABody() async throws {
        let saved = seedExpansion(nil)
        defer { restoreExpansion(saved) }

        let harness = await AppHarness.make()
        try await harness.openSocket()

        let tree = treeResult([treeProject(id: "p1")])
        let full = projectResult(hydratedProject(id: "p1"))
        await harness.backend.stub("projects.tree") { _ in tree }
        await harness.backend.stub("projects.project_sessions") { _ in full }

        let model = ProjectGroupModel()
        await model.load(api: harness.app.projectsAPI, force: false)
        XCTAssertEqual(
            model.displayProjects.map(\.id),
            ["p1"],
            "the projects.tree fixture did not survive decoding — check the wire casing"
        )

        // The tap. Nothing is awaited between it and the assertion, so this is
        // literally the state the first tap leaves on screen.
        model.toggle("p1", api: harness.app.projectsAPI)
        let bodyAfterTap = model.sectionBody(for: "p1")
        XCTAssertEqual(bodyAfterTap, .loading, """
            BUG-005 (ProjectGroupModel.swift:55-60): the chevron rotated to "expanded" and \
            the body is nothing at all — not rows, not a spinner, not an error. The user \
            taps a project, sees no change, and concludes the app is broken; the workaround \
            they find is to tap twice more. An expanded section must always have a body.
            """)

        let rows = await waitUntil {
            if case .rows = model.sectionBody(for: "p1") { return true }
            return false
        }
        XCTAssertTrue(rows, "projects.project_sessions answered but the section never showed its sessions")

        await harness.tearDown()
    }

    /// A failed hydrate is visible and recoverable, not silence.
    @MainActor
    func testHydrationFailureSurfacesAndRetryRecovers() async throws {
        let saved = seedExpansion(nil)
        defer { restoreExpansion(saved) }

        let harness = await AppHarness.make()
        try await harness.openSocket()

        let tree = treeResult([treeProject(id: "p1")])
        let full = projectResult(hydratedProject(id: "p1"))
        await harness.backend.stub("projects.tree") { _ in tree }
        await harness.backend.stub("projects.project_sessions") { _ in full }
        // Fails once, then tells the truth — a backend part-way through a
        // rebuild, which is exactly when a user is tapping at it.
        await harness.backend.failNextRPC(
            "projects.project_sessions",
            code: -32000,
            message: "project tree rebuild failed"
        )

        let model = ProjectGroupModel()
        await model.load(api: harness.app.projectsAPI, force: false)
        model.toggle("p1", api: harness.app.projectsAPI)

        let surfaced = await waitUntil {
            if case .error = model.sectionBody(for: "p1") { return true }
            return false
        }
        XCTAssertTrue(surfaced, """
            BUG-005 (ProjectGroupModel.swift:101): projects.project_sessions failed and \
            `try?` threw the error on the floor, so the expanded section stayed blank \
            forever. The user is never told the call failed and is never offered a retry — \
            the project just looks empty, which is a lie about their sessions.
            """)

        // The retry the error state offers.
        model.ensureHydrated("p1", api: harness.app.projectsAPI)
        let recovered = await waitUntil {
            if case .rows = model.sectionBody(for: "p1") { return true }
            return false
        }
        XCTAssertTrue(recovered, "Try again did not replace the error with the project's sessions")

        let calls = await harness.backend.callCount("projects.project_sessions")
        XCTAssertEqual(calls, 2, "the retry should send exactly one more projects.project_sessions")

        await harness.tearDown()
    }

    /// A project left expanded is hydrated when the hub reopens, not after a
    /// dance.
    @MainActor
    func testPersistedExpansionHydratesOnLoad() async throws {
        let saved = seedExpansion(["p1"])
        defer { restoreExpansion(saved) }

        let harness = await AppHarness.make()
        try await harness.openSocket()

        let tree = treeResult([treeProject(id: "p1")])
        let full = projectResult(hydratedProject(id: "p1"))
        await harness.backend.stub("projects.tree") { _ in tree }
        await harness.backend.stub("projects.project_sessions") { _ in full }

        // Built after the seed on purpose: the expansion set is read once, in
        // `init`, exactly as it is when the hub is opened.
        let model = ProjectGroupModel()
        XCTAssertTrue(model.isExpanded("p1"), "the persisted expansion did not survive init")

        await model.load(api: harness.app.projectsAPI, force: false)

        let hydrateFired = await waitUntil {
            await harness.backend.callCount("projects.project_sessions") == 1
        }
        XCTAssertTrue(hydrateFired, """
            BUG-005 (ProjectGroupModel.swift:74-87): a project the user left expanded is \
            drawn expanded on the next hub open, but nothing ever hydrates it — the hydrate \
            only runs from a tap. So the app reopens onto an expanded project with nothing \
            under it, and the only way out is to collapse it and expand it again.
            """)

        let rows = await waitUntil {
            if case .rows = model.sectionBody(for: "p1") { return true }
            return false
        }
        XCTAssertTrue(rows, "the appear-hydrate never delivered the persisted project's sessions")

        await harness.tearDown()
    }

    /// The impatient second tap must not throw away the seconds the backend
    /// has already spent.
    @MainActor
    func testInFlightHydrateIsNeverDuplicated() async throws {
        let saved = seedExpansion(nil)
        defer { restoreExpansion(saved) }

        let harness = await AppHarness.make()
        try await harness.openSocket()

        let tree = treeResult([treeProject(id: "p1")])
        let full = projectResult(hydratedProject(id: "p1"))
        await harness.backend.stub("projects.tree") { _ in tree }
        await harness.backend.stub("projects.project_sessions") { _ in full }

        let model = ProjectGroupModel()
        await model.load(api: harness.app.projectsAPI, force: false)

        // Hold the reply: the server-side tree rebuild, frozen mid-flight.
        await harness.backend.gate("projects.project_sessions")
        model.toggle("p1", api: harness.app.projectsAPI)
        let firstFired = await waitUntil {
            await harness.backend.callCount("projects.project_sessions") == 1
        }
        XCTAssertTrue(firstFired, "the first expand never sent projects.project_sessions")

        // The dance, performed on top of a call that has not come back yet.
        model.toggle("p1", api: harness.app.projectsAPI)
        XCTAssertNil(model.sectionBody(for: "p1"), "a collapsed section must have no body")
        model.toggle("p1", api: harness.app.projectsAPI)
        let bodyOnReExpand = model.sectionBody(for: "p1")
        XCTAssertEqual(bodyOnReExpand, .loading, "re-expanding mid-flight must say it is still loading")

        let midFlight = await harness.backend.callCount("projects.project_sessions")
        XCTAssertFalse(
            midFlight > 1,
            "the second expand sent a second projects.project_sessions while the first was still in flight"
        )

        await harness.backend.ungate("projects.project_sessions")
        await harness.backend.releaseParked()

        let rows = await waitUntil {
            if case .rows = model.sectionBody(for: "p1") { return true }
            return false
        }
        XCTAssertTrue(rows, """
            the hydrate that was in flight when the user collapsed the section was thrown \
            away, so the re-expanded section never got its rows
            """)

        let calls = await harness.backend.callCount("projects.project_sessions")
        XCTAssertEqual(calls, 1, """
            BUG-005 (ProjectGroupModel.swift:90-96): the collapse/re-expand dance sent a \
            second projects.project_sessions while the first was still in flight. Each one \
            is a full tree rebuild on the backend (~2.2 s measured), so the tap that came \
            from impatience costs the server twice over and makes the user wait longer, not \
            less.
            """)

        await harness.tearDown()
    }
}

// MARK: - UserDefaults

/// Seed the persisted expansion set (nil clears it) and hand back what was
/// there, for a `defer` to put back. There is no `tearDown` in this target's
/// pattern — the tests are `@MainActor` methods on a plain `XCTestCase` — so
/// restoring in a `defer` is what survives a thrown assertion.
@MainActor
private func seedExpansion(_ ids: [String]?) -> [String]? {
    let saved = UserDefaults.standard.stringArray(forKey: ProjectGroupModel.expansionKey)
    restoreExpansion(ids)
    return saved
}

@MainActor
private func restoreExpansion(_ ids: [String]?) {
    if let ids {
        UserDefaults.standard.set(ids, forKey: ProjectGroupModel.expansionKey)
    } else {
        UserDefaults.standard.removeObject(forKey: ProjectGroupModel.expansionKey)
    }
}

// MARK: - Wire fixtures

/// `projects.tree`'s envelope.
private func treeResult(_ projects: [JSONValue]) -> JSONValue {
    .object(["projects": .array(projects)])
}

/// `projects.project_sessions`' envelope.
private func projectResult(_ project: JSONValue) -> JSONValue {
    .object(["project": project])
}

/// A project node as `projects.tree` sends it: a preview, `repos` empty.
///
/// The project and lane nodes are **camelCase** on the wire (`sessionCount`,
/// `lastActive`, `isNoProject`, `isMain`) while the session rows inside them
/// are snake_case — the tree is synthesised by the gateway, the session rows
/// come straight out of the sessions table. Getting this wrong decodes
/// `sessionCount` as 0, which `displayProjects` filters out, and the test
/// times out on code that works.
private func treeProject(
    id: String,
    label: String = "Project One",
    lastActive: Double = 1_754_000_000
) -> JSONValue {
    .object([
        "id": .string(id),
        "label": .string(label),
        "path": .string("/scripted/\(id)"),
        "isNoProject": .bool(false),
        "sessionCount": .number(2),
        "lastActive": .number(lastActive),
        "repos": .array([]),
    ])
}

/// The same project as `projects.project_sessions` sends it: one repo, one
/// lane, two session rows. The lane array's wire key is `groups`.
private func hydratedProject(
    id: String,
    label: String = "Project One",
    lastActive: Double = 1_754_000_000
) -> JSONValue {
    .object([
        "id": .string(id),
        "label": .string(label),
        "path": .string("/scripted/\(id)"),
        "isNoProject": .bool(false),
        "sessionCount": .number(2),
        "lastActive": .number(lastActive),
        "repos": .array([
            .object([
                "id": .string("\(id)-repo"),
                "label": .string("repo"),
                "path": .string("/scripted/\(id)"),
                "sessionCount": .number(2),
                "groups": .array([
                    .object([
                        "id": .string("\(id)-main"),
                        "label": .string("main"),
                        "path": .string("/scripted/\(id)"),
                        "isMain": .bool(true),
                        "sessions": .array([
                            session(id: "\(id)-s1", title: "First session", lastActive: lastActive),
                            session(id: "\(id)-s2", title: "Second session", lastActive: lastActive - 60),
                        ]),
                    ]),
                ]),
            ]),
        ]),
    ])
}

/// A session row — snake_case, unlike the nodes that carry it.
private func session(id: String, title: String, lastActive: Double) -> JSONValue {
    .object([
        "id": .string(id),
        "title": .string(title),
        "source": .string("ios"),
        "last_active": .number(lastActive),
        "message_count": .number(4),
    ])
}
