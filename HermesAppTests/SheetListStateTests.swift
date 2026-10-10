import Foundation
import XCTest

@testable import HermesMobile

/// BUG-092, the sheet half — what an empty list is allowed to say.
///
/// `HostListLoadTests` pins the fetch: a thrown call keeps its rows and carries its reason. These pin the claim drawn from it. The worktree sheet said "No repositories on the backend yet" whenever its list was empty, so a failed call made a statement about the user's machine; the same sheet said "That folder is not a git repository yet" after a failed worktree read and "No branches on that repository" after a failed branch read. Only an answered empty list may make those claims. The folder picker's failure line has to name which of its two lists failed.
@MainActor
final class SheetListStateTests: XCTestCase {

    // MARK: WorktreeSheet.listState

    func testAnEmptyListAfterAFailedCallIsAFailureNotAnEmptyBackend() {
        XCTAssertEqual(WorktreeSheet.listState(isLoading: false, isEmpty: true, failed: true), .failed, "the sheet would say there are no repositories when all it knows is that the call failed (BUG-092)")
    }

    func testOnlyAnAnsweredEmptyListClaimsThereIsNothing() {
        XCTAssertEqual(WorktreeSheet.listState(isLoading: false, isEmpty: true, failed: false), .empty)
    }

    func testRowsStayUpWhenARefreshFails() {
        XCTAssertEqual(WorktreeSheet.listState(isLoading: false, isEmpty: false, failed: true), .rows)
    }

    func testLoadingWinsOverEverything() {
        XCTAssertEqual(WorktreeSheet.listState(isLoading: true, isEmpty: true, failed: true), .loading)
        XCTAssertEqual(WorktreeSheet.listState(isLoading: true, isEmpty: false, failed: false), .loading)
    }

    // MARK: FolderPickerSheet.loadFailureText

    func testBothListsAnsweringSaysNothing() {
        XCTAssertNil(FolderPickerSheet.loadFailureText(repositories: nil, projects: nil))
    }

    func testTheFailureNamesTheListThatFailed() {
        let repositories = FolderPickerSheet.loadFailureText(repositories: "The backend is restarting.", projects: nil)
        XCTAssertEqual(repositories, "Couldn't list repositories: The backend is restarting.")

        let projects = FolderPickerSheet.loadFailureText(repositories: nil, projects: "Request timed out.")
        XCTAssertEqual(projects, "Couldn't list projects: Request timed out.")
    }

    func testOneReasonForBothListsIsSaidOnce() {
        XCTAssertEqual(
            FolderPickerSheet.loadFailureText(repositories: "Not signed in.", projects: "Not signed in."),
            "Couldn't list repositories or projects: Not signed in."
        )
    }

    func testTwoDifferentReasonsAreBothKept() {
        let text = FolderPickerSheet.loadFailureText(repositories: "A.", projects: "B.")
        XCTAssertTrue(text?.contains("A.") == true && text?.contains("B.") == true, String(describing: text))
    }
}
