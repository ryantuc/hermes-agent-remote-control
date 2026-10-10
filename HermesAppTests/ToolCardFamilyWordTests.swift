import XCTest

@testable import HermesMobile

/// BUG-146 (`ToolCardView.swift` `Family.init(toolName:)`): the browser bucket matched the bare substring `web`, so any tool whose name merely contains those three letters, `webhook_send` or `cobweb_scan`, drew the browser glyph.
///
/// `web` is a word in the names it is meant for (`web_extract`, `web-fetch`, an MCP `fetchWebPage`), so it is matched as a word: the name split on punctuation and on lower-to-upper case changes. The other needles in that list are untouched, and the search bucket still wins over the browser one, as before.
@MainActor
final class ToolCardFamilyWordTests: XCTestCase {

    private let browser = ToolCardView.Family.browser.glyph
    private let other = ToolCardView.Family.other.glyph
    private let search = ToolCardView.Family.search.glyph

    /// The defect as filed, and its siblings: names that contain `web` without meaning the web.
    func testANameThatOnlyContainsWebIsNotABrowserTool() {
        for name in ["webhook_send", "send_webhook", "WebhookSend", "cobweb_scan", "webinar_list"] {
            XCTAssertEqual(ToolCardView.Family(toolName: name).glyph, other, "\(name) is not a browser tool")
        }
    }

    /// The names the bucket exists for keep their glyph, however the word is delimited.
    func testWebAsAWordStillDrawsTheBrowserGlyph() {
        for name in ["web", "web_extract", "WEB_EXTRACT", "web-fetch", "mcp__fetch__web_fetch", "fetchWebPage", "fetch.web"] {
            XCTAssertEqual(ToolCardView.Family(toolName: name).glyph, browser, "\(name) names the web")
        }
    }

    /// The rest of the bucket and the ordering around it are unchanged.
    func testTheOtherBrowserNeedlesAndTheBucketOrderAreUnchanged() {
        XCTAssertEqual(ToolCardView.Family(toolName: "browser_navigate").glyph, browser)
        XCTAssertEqual(ToolCardView.Family(toolName: "browser_cdp").glyph, browser)
        XCTAssertEqual(ToolCardView.Family(toolName: "take_screenshot").glyph, browser)
        // `search` is tested before `browser`, so the backend's own web search keeps the search glyph.
        XCTAssertEqual(ToolCardView.Family(toolName: "web_search").glyph, search)
        XCTAssertEqual(ToolCardView.Family(toolName: "hermes_web_search").glyph, search)
    }
}
