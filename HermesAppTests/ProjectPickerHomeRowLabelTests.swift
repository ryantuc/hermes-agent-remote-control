import Foundation
import HermesServeKit
import XCTest

@testable import HermesMobile

/// **FEAT-033 (c) — the pinned row names the directory it goes to.**
///
/// BUG-045 left one question open once its row existed: keep the words "No project", or name the backend's default working directory instead. The answer is the directory.
///
/// The reason it is a real improvement and not a preference: every other row in this sheet is a place, and the pin was the only one labelled with a *state*. Above an alphabetical list of project names, a row reading "No project" reads as a category header — the thing you scroll past — rather than the row you tap. Naming the directory makes it the same kind of thing as its neighbours, and the full path already drawn beneath it says which one.
///
/// **What did not change, and is asserted here because it is the whole of BUG-045.** The row is still pinned above the list, it still carries `AppModel.defaultCwd` as its path, it is still the only row that clears a project, and it still takes the checkmark by `HostPath.isSame` against that path. `ProjectPickerHomeRowTests` asserts all of that against `Row.label`, which is unchanged and still the vocabulary word — the app says "No project" in the chip and in the chat header's second line, and one sheet renaming the *state* would have made three surfaces disagree. `displayLabel` is what the row draws; `label` is what it is.
@MainActor
final class ProjectPickerHomeRowLabelTests: XCTestCase {

    private func project(id: String, label: String, path: String) -> ProjectsAPI.Project {
        ProjectsAPI.Project(json: .object([
            "id": .string(id),
            "label": .string(label),
            "path": .string(path),
            "isNoProject": .bool(false),
            "sessionCount": .number(1),
            "lastActive": .number(1_754_000_000),
            "repos": .array([]),
        ]))
    }

    private var tree: [ProjectsAPI.Project] {
        [project(id: "zed", label: "Zed", path: "/srv/zed")]
    }

    private func homeRow(defaultCwd: String) -> ProjectPickerSheet.Row? {
        ProjectPickerSheet.rows(projects: tree, defaultCwd: defaultCwd).first(where: \.isHome)
    }

    // MARK: 1 — it draws the directory

    func testThePinnedRowDrawsTheDefaultDirectorysName() {
        guard let row = homeRow(defaultCwd: "/Users/you/work") else {
            return XCTFail("the picker built no pinned row to inspect")
        }
        XCTAssertEqual(row.displayLabel, "work", """
            the pinned row draws "\(row.displayLabel)". The row names the backend's \
            default directory rather than the words "No project"
            """)
    }

    func testAWindowsStyleDefaultDirectoryAlsoResolvesToItsLeaf() {
        guard let row = homeRow(defaultCwd: "C:\\Users\\you\\hermes") else {
            return XCTFail("the picker built no pinned row to inspect")
        }
        XCTAssertEqual(row.displayLabel, "hermes", """
            a backend on Windows drew "\(row.displayLabel)". The pill already names host directories \
            through `HostPath.lastComponent`, and this row has to agree with it on the same path
            """)
    }

    /// A backend whose default working directory is the filesystem root has no
    /// directory name to draw. Falling through to the words is right; drawing a
    /// blank row is not.
    func testARootDefaultDirectoryFallsBackToTheWords() {
        guard let row = homeRow(defaultCwd: "/") else {
            return XCTFail("the picker built no pinned row to inspect")
        }
        XCTAssertFalse(row.displayLabel.isEmpty, "the pinned row drew nothing at all")
        XCTAssertEqual(row.displayLabel, "No project")
    }

    // MARK: 2 — an ordinary project row is untouched

    func testANamedProjectStillDrawsItsOwnLabel() {
        let rows = ProjectPickerSheet.rows(projects: tree, defaultCwd: "/Users/you/work")
        for row in rows where !row.isHome {
            XCTAssertEqual(row.displayLabel, row.label, """
                a named project's drawn label diverged from its own: "\(row.displayLabel)" vs "\(row.label)". \
                Only the pin was asked to change
                """)
        }
    }

    // MARK: 3 — BUG-045's semantics survive the rename

    /// The row is still the way out of a project. Renaming what it draws must
    /// not move where it goes, where it sits, or what it is.
    func testTheRowStillIsWhatItWasUnderneathTheNewWords() {
        let defaultCwd = "/Users/you/work"
        let rows = ProjectPickerSheet.rows(projects: tree, defaultCwd: defaultCwd)
        guard let first = rows.first else { return XCTFail("the picker built no rows at all") }
        XCTAssertTrue(first.isHome, "the pin is no longer pinned first")
        XCTAssertEqual(first.path, defaultCwd, """
            the pinned row's path is "\(first.path)". It has to be the backend's own default working \
            directory or picking it does not clear the project (BUG-045)
            """)
        XCTAssertEqual(first.label, "No project", """
            the row's semantic label changed. The chip and the chat header's second line both say \
            "No project" for this state; only what this one row *draws* was in scope
            """)
        XCTAssertEqual(first.id, ProjectPickerSheet.homeRowID)
    }

    /// The checkmark is `HostPath.isSame(row.path, currentPath)` and reads the
    /// path, never the label — so it still ticks when the draft is sitting on
    /// the default directory, and still does not when it is in a project.
    func testTheCheckmarkStillFollowsThePathAndNotTheWords() {
        let defaultCwd = "/Users/you/work"
        guard let row = homeRow(defaultCwd: defaultCwd) else {
            return XCTFail("the picker built no pinned row to inspect")
        }
        XCTAssertTrue(HostPath.isSame(row.path, defaultCwd), """
            the pinned row stopped matching the working directory it applies, so a draft that is \
            already out of every project would show nothing ticked
            """)
        XCTAssertFalse(HostPath.isSame(row.path, "/srv/zed"))
    }
}
