import Foundation
import HermesServeKit
import XCTest

@testable import HermesMobile

/// BUG-045 — the project picker had no way back out of a project.
///
/// The sheet listed named projects alphabetically and nothing else, so a pick was a one-way door: once a project was on the draft there was no row that took it off. The "No project" bucket does arrive on the wire, but it has no path by construction and the sheet dropped it as "not a destination" — correctly, as a *navigation* target. What it was missing is a destination of its own: the backend's own default working directory, which is where a session lands when no cwd rides its create, and therefore what "no project" actually means to this client.
///
/// The row list is asserted as a pure function rather than by hosting the sheet, for the reason `HomeModeControlTests` gives: a hosted view test passes on a row that draws the right words and goes nowhere, and going somewhere is the whole of this item.
@MainActor
final class ProjectPickerHomeRowTests: XCTestCase {

    // MARK: Fixtures — `projects.tree` rows as the wire sends them

    private func project(
        id: String,
        label: String,
        path: String,
        isNoProject: Bool = false,
        repos: [String] = []
    ) -> ProjectsAPI.Project {
        ProjectsAPI.Project(json: .object([
            "id": .string(id),
            "label": .string(label),
            "path": .string(path),
            "isNoProject": .bool(isNoProject),
            "sessionCount": .number(3),
            "lastActive": .number(1_754_000_000),
            "repos": .array(repos.map { .object(["path": .string($0), "root": .string($0)]) }),
        ]))
    }

    /// One backend's tree: three named projects out of alphabetical order, plus
    /// the pathless "No project" bucket the backend always sends.
    private var tree: [ProjectsAPI.Project] {
        [
            project(id: "zed", label: "Zed", path: "/srv/zed"),
            project(id: "none", label: "No project", path: "", isNoProject: true),
            project(id: "alpha", label: "alpha", path: "/srv/alpha"),
            project(id: "mid", label: "Mid", path: "/srv/mid"),
        ]
    }

    private let defaultCwd = "/Users/you/work"

    // MARK: 1 — the row exists, and it is first

    func testTheFirstRowIsTheNoProjectRow() {
        let rows = ProjectPickerSheet.rows(projects: tree, defaultCwd: defaultCwd)
        guard let first = rows.first else { return XCTFail("the picker built no rows at all") }
        XCTAssertTrue(first.isHome, """
            the first row is "\(first.label)". There is no way to clear a project from this sheet \
            unless the clearing row is the one pinned above the list (BUG-045)
            """)
        XCTAssertEqual(first.label, "No project")
    }

    /// Pinned means pinned: it does not sort into the alphabetical run, where a
    /// backend with a project called "Aardvark" would bury it.
    func testTheNoProjectRowIsNotSortedIntoTheList() {
        let withAnEarlierName = tree + [project(id: "aa", label: "Aardvark", path: "/srv/aa")]
        let rows = ProjectPickerSheet.rows(projects: withAnEarlierName, defaultCwd: defaultCwd)
        XCTAssertEqual(rows.first?.isHome, true, """
            "Aardvark" sorts above "No project" alphabetically, and the row list came back as \
            \(rows.map(\.label)) — the row is being sorted rather than pinned
            """)
        XCTAssertEqual(rows.dropFirst().map(\.label), ["Aardvark", "alpha", "Mid", "Zed"], """
            the named projects below the pin are no longer case-insensitively alphabetical
            """)
    }

    // MARK: 2 — picking it goes somewhere

    /// The row has to carry a real path or the sheet's shared `apply` hook has
    /// nothing to send: `session.create(cwd:)` takes a path or nothing at all,
    /// and the picker only ever calls the path form.
    func testTheNoProjectRowLandsOnTheBackendsDefaultWorkingDirectory() {
        let rows = ProjectPickerSheet.rows(projects: tree, defaultCwd: defaultCwd)
        XCTAssertEqual(rows.first?.path, defaultCwd, """
            the "No project" row's path is "\(rows.first?.path ?? "")". A row that applies an \
            empty path blanks the draft's working directory instead of returning it to the \
            backend's default, which is the state this row is supposed to restore
            """)
    }

    /// Before the socket answers `config.get project`, `AppModel.defaultCwd` is
    /// empty and there is nowhere for the row to go. A row that applied "" would
    /// be worse than no row.
    func testThereIsNoHomeRowUntilTheBackendHasNamedItsDefault() {
        let rows = ProjectPickerSheet.rows(projects: tree, defaultCwd: "")
        XCTAssertFalse(rows.contains(where: \.isHome), """
            a "No project" row was offered with no default working directory known — picking it \
            would apply an empty path
            """)
        XCTAssertEqual(rows.map(\.label), ["alpha", "Mid", "Zed"], """
            the named projects must still list normally when the default is unknown
            """)
    }

    // MARK: 3 — the wire's own bucket is still not a destination

    /// The pinned row is this client's, not the backend's: the wire's bucket has
    /// no path, and its repo list (when it has one) is a set of unrelated
    /// checkouts, not a place. It must never become a navigable row.
    func testTheWiresNoProjectBucketIsNeverListedAsAProject() {
        let bucketWithRepos = [
            project(id: "none", label: "No project", path: "", isNoProject: true, repos: ["/srv/loose"]),
            project(id: "alpha", label: "alpha", path: "/srv/alpha"),
        ]
        let rows = ProjectPickerSheet.rows(projects: bucketWithRepos, defaultCwd: defaultCwd)
        XCTAssertFalse(rows.contains { $0.path == "/srv/loose" }, """
            the "No project" bucket's first repository became a row: \(rows.map(\.path)). A loose \
            checkout that happens to be first in that bucket is not where "no project" lives
            """)
        XCTAssertEqual(rows.filter(\.isHome).count, 1, """
            the pin appeared \(rows.filter(\.isHome).count) times — the wire's bucket is being \
            listed alongside this client's own row
            """)
    }

    func testAProjectWithNoPathFallsBackToItsFirstRepository() {
        let rows = ProjectPickerSheet.rows(
            projects: [project(id: "p", label: "Pathless", path: "", repos: ["/srv/repo"])],
            defaultCwd: ""
        )
        XCTAssertEqual(rows.map(\.path), ["/srv/repo"], """
            the pre-existing fallback for a named project with no path of its own was lost
            """)
    }
}
