import Foundation
import HermesServeKit
import XCTest

@testable import HermesMobile

/// BUG-091 — the working-directory picker compared host paths with `==`.
///
/// `HostPath` (GitAPI.swift) records, from live probes, that a Windows gateway hands back the same directory in more than one spelling: `X:\…` from `projects.discover_repos` roots, `X:/…` from `projects.tree` paths that went through `git rev-parse --show-toplevel`. Its rule is that no path comparison in the app may be `==`. FolderPickerSheet broke it twice: the Projects section's dedupe against Repositories, so one directory drew two rows with contradictory glyphs, and the checkmark on the directory already in play, which went missing whenever the session's cwd was spelled differently from the row.
///
/// Both decisions are asserted as the pure functions the sheet calls, for the reason `ProjectPickerHomeRowTests` gives.
@MainActor
final class FolderPickerHostPathTests: XCTestCase {

    // MARK: Fixtures, in the wire's own shapes

    private func repo(_ root: String, label: String) -> ProjectsAPI.DiscoveredRepo {
        ProjectsAPI.DiscoveredRepo(json: .object([
            "root": .string(root),
            "label": .string(label),
            "sessions": .number(2),
            "last_active": .number(1_754_000_000),
        ]))
    }

    private func project(_ path: String, label: String, isNoProject: Bool = false) -> ProjectsAPI.Project {
        ProjectsAPI.Project(json: .object([
            "id": .string(label),
            "label": .string(label),
            "path": .string(path),
            "isNoProject": .bool(isNoProject),
            "sessionCount": .number(3),
            "lastActive": .number(1_754_000_000),
            "repos": .array([]),
        ]))
    }

    // MARK: The Projects section's dedupe

    func testARepositoryAndAProjectNamingOneWindowsDirectoryDrawOneRow() {
        let repos = [repo("D:\\code\\Projects\\harc", label: "harc")]
        let projects = [project("D:/code/Projects/harc", label: "harc")]

        let extra = FolderPickerSheet.extraProjects(projects, besides: repos)

        XCTAssertTrue(extra.isEmpty, """
            the same directory spelled X:\\… by discover_repos and X:/… by projects.tree drew a second row \
            under Projects: \(extra.map(\.path)) (BUG-091)
            """)
    }

    func testCaseAndATrailingSeparatorDoNotSplitAWindowsDirectory() {
        let repos = [repo("x:\\work\\api\\", label: "api")]
        let projects = [project("X:/Work/API", label: "API")]

        XCTAssertTrue(FolderPickerSheet.extraProjects(projects, besides: repos).isEmpty, "Windows folds case, and so must the dedupe")
    }

    func testAProjectInAnotherDirectoryIsStillListed() {
        let repos = [repo("X:\\work\\api", label: "api")]
        let projects = [project("X:/work/web", label: "web")]

        XCTAssertEqual(FolderPickerSheet.extraProjects(projects, besides: repos).map(\.label), ["web"])
    }

    func testPosixPathsStayCaseSensitive() {
        let repos = [repo("/srv/Api", label: "Api")]
        let projects = [project("/srv/api", label: "api")]

        XCTAssertEqual(FolderPickerSheet.extraProjects(projects, besides: repos).map(\.label), ["api"], "on a POSIX host these are two directories")
    }

    func testTheNoProjectBucketAndPathlessProjectsStayOut() {
        let projects = [
            project("", label: "No project", isNoProject: true),
            project("", label: "pathless"),
        ]

        XCTAssertTrue(FolderPickerSheet.extraProjects(projects, besides: []).isEmpty)
    }

    // MARK: The checkmark

    func testTheDirectoryInPlayIsCheckedWhateverItsSpelling() {
        XCTAssertTrue(
            FolderPickerSheet.isCurrent("D:/code/Projects/harc", currentPath: "D:\\code\\Projects\\harc"),
            "the session's cwd and the row name one directory, and the row had no checkmark (BUG-091)"
        )
    }

    func testAnotherDirectoryIsNotChecked() {
        XCTAssertFalse(FolderPickerSheet.isCurrent("D:/code/Projects/web", currentPath: "D:\\code\\Projects\\harc"))
    }

    func testNothingIsCheckedWhenNoDirectoryIsInPlay() {
        XCTAssertFalse(FolderPickerSheet.isCurrent("/srv/api", currentPath: ""))
    }
}
