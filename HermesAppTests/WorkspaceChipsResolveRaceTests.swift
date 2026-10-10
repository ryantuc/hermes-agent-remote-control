import Foundation
import HermesServeKit
import XCTest

@testable import HermesMobile

/// BUG-093 — the top bar's project and branch chips could settle on the previous directory's answer.
///
/// The chips resolve in a `.task(id:)` keyed on the cwd and the socket. A new key cancels the old task, but nothing under it honours cancellation (`client.request` is not cancellation-aware, `ProjectGroupModel` says so), so the old `projects.for_cwd` runs to completion and its answer was written unconditionally. When the old directory's answer arrived after the new one, the chips named the old project and branch, and nothing re-fired to correct them until the cwd or the socket changed again.
///
/// The model takes both calls as closures, so each test holds one answer back and releases it after a later resolve has landed, which is the race on a real backend made deterministic.
@MainActor
final class WorkspaceChipsResolveRaceTests: XCTestCase {

    /// An answer the test releases by hand.
    @MainActor
    private final class HeldAnswer {
        private var continuation: CheckedContinuation<Void, Never>?
        private(set) var isWaiting = false

        func wait() async {
            await withCheckedContinuation { continuation in
                self.continuation = continuation
                isWaiting = true
            }
        }

        func release() {
            continuation?.resume()
            continuation = nil
        }
    }

    /// Lets the held task run until it is parked inside its request; the precondition every race test needs, checked rather than assumed.
    private func runUntilWaiting(_ held: HeldAnswer, file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<1_000 where !held.isWaiting {
            await Task.yield()
        }
        XCTAssertTrue(held.isWaiting, "precondition: the first resolve never reached its request, so this run proved nothing", file: file, line: line)
    }

    private func branch(_ name: String, isDefault: Bool) -> GitBranch {
        GitBranch(json: .object([
            "name": .string(name),
            "checkedOut": .bool(true),
            "isDefault": .bool(isDefault),
        ]))
    }

    // MARK: The race

    func testAStaleProjectAnswerThatLandsLastDoesNotReplaceTheFreshOne() async {
        let model = WorkspaceChipsModel()
        let held = HeldAnswer()

        let stale = Task {
            await model.resolve(cwd: "/srv/alpha", isOpen: true, forCwd: { _ in
                await held.wait()
                return (project: "alpha", branch: "")
            }, branches: nil)
        }
        await runUntilWaiting(held)

        await model.resolve(cwd: "/srv/beta", isOpen: true, forCwd: { _ in
            (project: "beta", branch: "")
        }, branches: nil)
        XCTAssertEqual(model.resolution.projectName, "beta")

        held.release()
        await stale.value

        XCTAssertEqual(model.resolution.projectName, "beta", """
            the previous directory's projects.for_cwd answered last and the chip now names "\(model.resolution.projectName)" \
            while the draft is in /srv/beta (BUG-093)
            """)
    }

    func testAStaleBranchLookupThatLandsLastDoesNotReplaceTheFreshOne() async {
        let model = WorkspaceChipsModel()
        let held = HeldAnswer()

        // The second await is the slow one here: `GET /api/git/branches` for the old directory.
        let stale = Task {
            await model.resolve(cwd: "/srv/alpha", isOpen: true, forCwd: { _ in
                (project: "alpha", branch: "feat/old")
            }, branches: { _ in
                await held.wait()
                return [self.branch("main", isDefault: true), self.branch("feat/old", isDefault: false)]
            })
        }
        await runUntilWaiting(held)

        await model.resolve(cwd: "/srv/beta", isOpen: true, forCwd: { _ in
            (project: "beta", branch: "main")
        }, branches: { _ in
            [self.branch("main", isDefault: true)]
        })

        held.release()
        await stale.value

        XCTAssertEqual(model.resolution.projectName, "beta")
        XCTAssertEqual(model.resolution.branch, "main", "the old directory's branch chip came back after the new one had landed (BUG-093)")
    }

    func testAResolveOvertakenByADisconnectDoesNotLandAfterIt() async {
        let model = WorkspaceChipsModel()
        let held = HeldAnswer()

        let stale = Task {
            await model.resolve(cwd: "/srv/alpha", isOpen: true, forCwd: { _ in
                await held.wait()
                return (project: "alpha", branch: "main")
            }, branches: nil)
        }
        await runUntilWaiting(held)

        // The socket dropped: the key changed to "…|false" and the chips were cleared.
        await model.resolve(cwd: "/srv/alpha", isOpen: false, forCwd: nil, branches: nil)

        held.release()
        await stale.value

        XCTAssertEqual(model.resolution, WorkspaceChips.Resolution(), "an answer from before the disconnect painted the chips as resolved while offline")
    }

    func testACancelledResolveDoesNotLand() async {
        let model = WorkspaceChipsModel()
        let held = HeldAnswer()

        let cancelled = Task {
            await model.resolve(cwd: "/srv/alpha", isOpen: true, forCwd: { _ in
                await held.wait()
                return (project: "alpha", branch: "")
            }, branches: nil)
        }
        await runUntilWaiting(held)

        // What `.task(id:)` does when the chips leave the screen.
        cancelled.cancel()
        held.release()
        await cancelled.value

        XCTAssertEqual(model.resolution, WorkspaceChips.Resolution(), "a resolve whose task was cancelled still wrote its answer")
    }

    // MARK: Controls

    func testASingleResolveLands() async {
        let model = WorkspaceChipsModel()

        await model.resolve(cwd: "/srv/alpha", isOpen: true, forCwd: { _ in
            (project: "alpha", branch: "feat/x")
        }, branches: { _ in
            [self.branch("main", isDefault: true)]
        })

        XCTAssertEqual(model.resolution, WorkspaceChips.Resolution(
            projectName: "alpha", branch: "feat/x", defaultBranch: "main", didResolve: true
        ))
    }

    func testTheLaterOfTwoInOrderResolvesWins() async {
        let model = WorkspaceChipsModel()

        await model.resolve(cwd: "/srv/alpha", isOpen: true, forCwd: { _ in (project: "alpha", branch: "") }, branches: nil)
        await model.resolve(cwd: "/srv/beta", isOpen: true, forCwd: { _ in (project: "beta", branch: "") }, branches: nil)

        XCTAssertEqual(model.resolution.projectName, "beta")
    }
}
