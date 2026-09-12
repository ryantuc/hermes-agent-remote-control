import XCTest

@testable import HermesServeKit

/// Every payload below is a verbatim capture from a running hermes-agent 0.20.0
/// backend, not a hand-written approximation — the separator inconsistency
/// these tests pin only shows up on a real Windows-hosted gateway.
final class GitAPITests: XCTestCase {

    private func json(_ raw: String) -> JSONValue {
        try! JSONDecoder().decode(JSONValue.self, from: Data(raw.utf8))
    }

    // MARK: - HostPath

    /// The finding that forced `HostPath` to exist: one directory, two
    /// spellings, from two routes on the same gateway in the same second.
    func testWorktreeAndListingSpellingsAreTheSameDirectory() {
        let fromListing = #"D:\code\Mobile Clients\HermesMobile"#
        let fromWorktrees = "D:/code/Mobile Clients/HermesMobile"
        XCTAssertNotEqual(fromListing, fromWorktrees)
        XCTAssertTrue(HostPath.isSame(fromListing, fromWorktrees))
    }

    /// `POST /api/git/worktree/add` mixes both separators inside one string.
    func testMixedSeparatorAddResultMatchesItsWorktreeRow() {
        let fromAdd = #"C:/Users/you/scratch\.worktrees\band-7c-probe"#
        let fromList = "C:/Users/you/scratch/.worktrees/band-7c-probe"
        XCTAssertTrue(HostPath.isSame(fromAdd, fromList))
    }

    func testWindowsComparisonFoldsCase() {
        XCTAssertTrue(HostPath.isSame(#"C:\Users\You"#, #"c:\users\you"#))
    }

    /// POSIX hosts are case-sensitive and must stay that way.
    func testPosixComparisonDoesNotFoldCase() {
        XCTAssertFalse(HostPath.isSame("/Users/you/Desktop", "/users/you/desktop"))
        XCTAssertTrue(HostPath.isSame("/Users/you/Desktop/", "/Users/you/Desktop"))
    }

    func testParentWalksUpAndStopsAtTheRoot() {
        XCTAssertEqual(HostPath.parent(of: #"C:\Users\you\code"#), #"C:\Users\you"#)
        XCTAssertEqual(HostPath.parent(of: #"C:\Users"#), #"C:\"#)
        XCTAssertNil(HostPath.parent(of: #"C:\"#))
        XCTAssertEqual(HostPath.parent(of: "/Users/you"), "/Users")
        XCTAssertEqual(HostPath.parent(of: "/Users"), "/")
        XCTAssertNil(HostPath.parent(of: "/"))
    }

    func testLastComponent() {
        XCTAssertEqual(HostPath.lastComponent(of: #"D:\code\Mobile Clients\HermesMobile"#), "HermesMobile")
        XCTAssertEqual(HostPath.lastComponent(of: "/Users/you/Developer/myproject"), "myproject")
        XCTAssertEqual(HostPath.lastComponent(of: "/"), "/")
    }

    func testJoiningUsesTheHostSeparator() {
        XCTAssertEqual(HostPath.joining(#"C:\Users\you"#, ".git"), #"C:\Users\you\.git"#)
        XCTAssertEqual(HostPath.joining(#"C:\"#, "Users"), #"C:\Users"#)
        XCTAssertEqual(HostPath.joining("/Users/you", ".git"), "/Users/you/.git")
        XCTAssertEqual(HostPath.joining("/", "Users"), "/Users")
    }

    func testWindowsBreadcrumb() {
        let crumbs = HostPath.breadcrumb(#"D:\code\Mobile Clients"#)
        XCTAssertEqual(crumbs.map(\.name), ["D:", "code", "Mobile Clients"])
        XCTAssertEqual(crumbs.map(\.path), [
            #"D:\"#,
            #"D:\code"#,
            #"D:\code\Mobile Clients"#,
        ])
    }

    func testPosixBreadcrumb() {
        let crumbs = HostPath.breadcrumb("/Users/you/Desktop")
        XCTAssertEqual(crumbs.map(\.name), ["/", "Users", "you", "Desktop"])
        XCTAssertEqual(crumbs.map(\.path), ["/", "/Users", "/Users/you", "/Users/you/Desktop"])
    }

    /// Every crumb must be somewhere the browser can actually navigate to.
    func testBreadcrumbCrumbsRoundTripThroughParent() {
        let crumbs = HostPath.breadcrumb(#"C:\Users\you\code"#)
        for (child, parent) in zip(crumbs.dropFirst(), crumbs) {
            XCTAssertEqual(HostPath.parent(of: child.path).map(HostPath.normalized),
                           HostPath.normalized(parent.path))
        }
    }

    // MARK: - GitRef

    func testGitRefSanitisesAsTheDesktopDoes() {
        XCTAssertEqual(GitRef.sanitize("fix the read gate"), "fix-the-read-gate")
        XCTAssertEqual(GitRef.sanitize("ios/band 7c"), "ios/band-7c")
        XCTAssertEqual(GitRef.sanitize("feat: ~thing~"), "feat-thing")
        XCTAssertEqual(GitRef.sanitize("a--b"), "a-b")
        XCTAssertEqual(GitRef.sanitize("a//b"), "a/b")
        XCTAssertEqual(GitRef.sanitize("a..b"), "a.b")
        XCTAssertEqual(GitRef.sanitize("--/leading"), "leading")
        XCTAssertEqual(GitRef.sanitize("  "), "")
    }

    /// The one deliberate divergence from the backend's `_sanitize_branch`:
    /// a trailing separator survives, or `ios/` could never be typed.
    func testGitRefKeepsTrailingSeparatorSoTheFieldStaysTypable() {
        XCTAssertEqual(GitRef.sanitize("ios/"), "ios/")
        XCTAssertEqual(GitRef.sanitize("ios/b"), "ios/b")
    }

    // MARK: - Worktrees

    func testWorktreeListDecodesTheLiveShape() {
        let raw = """
        {"worktrees":[\
        {"path":"C:/Users/you/scratch","branch":"master","isMain":true,"detached":false,"locked":false},\
        {"path":"C:/Users/you/scratch/.worktrees/band-7c-probe","branch":"ios/band-7c","isMain":false,\
        "detached":false,"locked":false}]}
        """
        let trees = (json(raw)["worktrees"]?.arrayValue ?? []).map(GitWorktree.init(json:))
        XCTAssertEqual(trees.count, 2)
        XCTAssertEqual(trees[0].label, "master")
        XCTAssertEqual(trees[0].laneNote, "home")
        XCTAssertEqual(trees[1].label, "ios/band-7c")
        XCTAssertEqual(trees[1].laneNote, "worktree")
    }

    /// A detached lane has `branch: null`; it still has to be nameable.
    func testDetachedWorktreeFallsBackToItsDirectoryName() {
        let tree = GitWorktree(json: json(#"{"path":"C:/repo/.worktrees/spike","branch":null,"isMain":false,"detached":true,"locked":false}"#))
        XCTAssertTrue(tree.detached)
        XCTAssertEqual(tree.branch, "")
        XCTAssertEqual(tree.label, "spike")
    }

    // MARK: - Branch action labels

    func testBranchActionLabels() {
        let checkedOut = GitBranch(name: "ios/band-7c", checkedOut: true, isDefault: false, worktreePath: "C:/repo/.worktrees/x")
        XCTAssertEqual(checkedOut.action, .openExisting)
        XCTAssertEqual(checkedOut.action.label, "Open existing")

        let trunk = GitBranch(name: "main", checkedOut: false, isDefault: true, worktreePath: nil)
        XCTAssertEqual(trunk.action, .switchHome)
        XCTAssertEqual(trunk.action.label, "Switch home")

        let other = GitBranch(name: "spike", checkedOut: false, isDefault: false, worktreePath: nil)
        XCTAssertEqual(other.action, .createWorktree)
        XCTAssertEqual(other.action.label, "Create worktree")
    }

    /// `checkedOut` wins over `isDefault` — the desktop tests `checkedOut`
    /// first, and a checked-out trunk must open, not re-switch to itself.
    func testCheckedOutDefaultBranchOpensRatherThanSwitches() {
        let branch = GitBranch(name: "master", checkedOut: true, isDefault: true, worktreePath: "C:/repo")
        XCTAssertEqual(branch.action, .openExisting)
    }

    func testBranchListDecodesTheLiveShape() {
        let raw = """
        {"branches":[\
        {"name":"ios/band-7c","checkedOut":true,"isDefault":false,"worktreePath":"C:/Users/you/scratch/.worktrees/band-7c-probe"},\
        {"name":"master","checkedOut":true,"isDefault":true,"worktreePath":"C:/Users/you/scratch"}]}
        """
        let branches = (json(raw)["branches"]?.arrayValue ?? []).map(GitBranch.init(json:))
        XCTAssertEqual(branches.map(\.name), ["ios/band-7c", "master"])
        XCTAssertEqual(branches[0].worktreePath, "C:/Users/you/scratch/.worktrees/band-7c-probe")
        XCTAssertTrue(branches.allSatisfy { $0.action == .openExisting })
    }

    func testMissingWorktreePathDecodesToNil() {
        let branch = GitBranch(json: json(#"{"name":"spike","checkedOut":false,"isDefault":false,"worktreePath":null}"#))
        XCTAssertNil(branch.worktreePath)
    }

    // MARK: - Base branches

    func testPreferredBaseBranchPrefersTheFlaggedDefault() {
        let branches = [
            GitBaseBranch(name: "ios/band-7c", isRemote: false, isDefault: false),
            GitBaseBranch(name: "master", isRemote: false, isDefault: true),
        ]
        XCTAssertEqual(GitBaseBranch.preferred(in: branches)?.name, "master")
    }

    /// The live case: a repo with no `origin/HEAD` symbolic ref flags nothing,
    /// and the picker must still open on a concrete value.
    func testPreferredBaseBranchFallsBackToTheFirstRowWhenNothingIsFlagged() {
        let branches = [
            GitBaseBranch(name: "main", isRemote: false, isDefault: false),
            GitBaseBranch(name: "origin/main", isRemote: true, isDefault: false),
        ]
        XCTAssertEqual(GitBaseBranch.preferred(in: branches)?.name, "main")
    }

    func testPreferredBaseBranchOfNothingIsNothing() {
        XCTAssertNil(GitBaseBranch.preferred(in: []))
    }

    // MARK: - Directory listing

    /// The route answers an unreadable directory with 200 + `error`, so an
    /// empty `entries` array is not evidence of an empty directory.
    func testUnreadableDirectoryCarriesItsErrorRatherThanLookingEmpty() {
        for (code, expected) in [
            ("ENOENT", "That folder no longer exists on the host."),
            ("ENOTDIR", "That path is a file, not a folder."),
            ("EACCES", "The gateway is not allowed to read that folder."),
        ] {
            let listing = DirectoryListing(entries: [], error: code)
            XCTAssertEqual(listing.errorMessage, expected)
        }
        XCTAssertEqual(DirectoryListing(entries: [], error: "Bad unit").errorMessage, "Bad unit")
        XCTAssertNil(DirectoryListing(entries: [], error: nil).errorMessage)
    }

    func testDirectoryListingKeepsOnlyDirectoriesForTheBrowser() {
        let raw = """
        {"entries":[\
        {"name":".agents","path":"C:\\\\Users\\\\you\\\\.agents","isDirectory":true},\
        {"name":"setup info.txt","path":"C:\\\\Users\\\\you\\\\setup info.txt","isDirectory":false}]}
        """
        let value = json(raw)
        let listing = DirectoryListing(
            entries: (value["entries"]?.arrayValue ?? []).map(DirectoryEntry.init(json:)),
            error: nil
        )
        XCTAssertEqual(listing.entries.count, 2)
        XCTAssertEqual(listing.directories.map(\.name), [".agents"])
    }

    // MARK: - HEAD parsing

    func testHeadBranchParsing() {
        XCTAssertEqual(GitAPI.branchName(fromHEAD: "ref: refs/heads/main\n"), "main")
        XCTAssertEqual(GitAPI.branchName(fromHEAD: "ref: refs/heads/ios/band-7c\n"), "ios/band-7c")
        XCTAssertEqual(GitAPI.branchName(fromHEAD: "4d66fd1a9c0b3e5f7d2a1b8c9e0f1a2b3c4d5e6f\n"), "4d66fd1")
        XCTAssertNil(GitAPI.branchName(fromHEAD: ""))
        XCTAssertNil(GitAPI.branchName(fromHEAD: "   \n"))
        XCTAssertNil(GitAPI.branchName(fromHEAD: "gitdir: ../../.git/worktrees/spike"))
    }
}
