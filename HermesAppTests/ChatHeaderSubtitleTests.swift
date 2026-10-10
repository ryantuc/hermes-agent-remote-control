import XCTest

@testable import HermesMobile

/// A new conversation's header read "New conversation" over a bare em dash, which looks like a rendering fault rather than a value that has not arrived. The header still lays the second line out in every state (the bar must not change height when the project answer lands, `ChatChromeTests`), but an unresolved project now draws nothing on it.
final class ChatHeaderSubtitleTests: XCTestCase {

    func testAnUnresolvedProjectDrawsNothingOnTheHeadersSecondLine() {
        XCTAssertNil(ChatProjectSubtitle.unknown.headerText, """
            the header draws "\(ChatProjectSubtitle.unknown.headerText ?? "")" under the title for a project \
            nobody has answered yet
            """)
    }

    func testEveryResolvedStateDrawsItsText() {
        XCTAssertEqual(ChatProjectSubtitle.noProject.headerText, "No project")
        XCTAssertEqual(ChatProjectSubtitle.folder("scratch").headerText, "scratch")
        XCTAssertEqual(ChatProjectSubtitle.project("hermesmobile").headerText, "hermesmobile")
    }
}
