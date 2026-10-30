import XCTest

@testable import HermesMobile
@testable import HermesServeKit

/// BUG-146 (`ToolCardView.swift` `Family.init(toolName:)`): the browser bucket matched the bare substring `web`, so any tool whose name merely contains those three letters, `webhook_send` or `cobweb_scan`, drew the browser glyph.
///
/// `web` is a word in the names it is meant for (`web_extract`, `web-fetch`, an MCP `fetchWebPage`), so it is matched as a word: the name split on punctuation and on lower-to-upper case changes. The other needles in that list are untouched, and the search bucket still wins over the browser one, as before.
@MainActor
final class ToolCardFamilyWordTests: XCTestCase {

    private let browser = ToolCardView.Family.browser.glyph
    private let other = ToolCardView.Family.other.glyph
    private let search = ToolCardView.Family.search.glyph
    private let terminal = ToolCardView.Family.terminal.glyph

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

    /// Newer backends drive the browser through one tool, `browser_exec`, whose name also carries the terminal bucket's `exec`. A browser tool draws the globe whatever else its name says; the terminal names keep the terminal.
    func testABrowserToolWhoseNameCarriesATerminalWordIsStillABrowserTool() {
        for name in ["browser_exec", "BROWSER_EXEC", "browser_run_code", "mcp__playwright__browser_run_code", "browser_command"] {
            XCTAssertEqual(ToolCardView.Family(toolName: name).glyph, browser, "\(name) drives the browser")
        }
        for name in ["terminal", "exec", "execute_code", "bash", "shell_command", "run_tests"] {
            XCTAssertEqual(ToolCardView.Family(toolName: name).glyph, terminal, "\(name) is a terminal tool")
        }
    }

    /// `browser_exec` runs the model's Python on the machine, so a turn that ran it still asks for a hold before Retry repeats it, as it did while it drew the terminal; a browser tool that only navigates still does not.
    func testRetryAfterABrowserToolThatRunsCodeStillAsksFirst() async throws {
        let harness = await AppHarness.make()
        try await harness.openSocket()
        let chat = harness.chat(storedID: "20261030_browser_exec")
        await chat.open()
        let bound = await waitUntil { chat.runtimeSessionID != nil }
        XCTAssertTrue(bound)
        let sid = try XCTUnwrap(chat.runtimeSessionID)

        for (index, tool) in ["browser_exec", "browser_navigate"].enumerated() {
            chat.draft = "use the browser \(index)"
            chat.sendTapped()
            _ = await waitUntil { await harness.backend.callCount("prompt.submit") == index + 1 }
            _ = await waitUntil { !chat.isSending }
            await harness.backend.emit("message.start", sessionID: sid)
            await harness.backend.emit("tool.start", sessionID: sid, payload: .object([
                "tool_id": .string("tool-\(index)"), "name": .string(tool), "context": .string("example.com"),
            ]))
            await harness.backend.emit("tool.complete", sessionID: sid, payload: .object([
                "tool_id": .string("tool-\(index)"), "name": .string(tool), "result": .string("ok"), "duration_s": .number(0.1),
            ]))
            await harness.backend.emit("message.delta", sessionID: sid, payload: .object(["text": .string("Done \(index).")]))
            await harness.backend.emit("message.complete", sessionID: sid, payload: .object([
                "text": .string("Done \(index)."), "status": .string("complete"),
            ]))
            let settled = await waitUntil {
                !chat.live.isBusy && chat.entries.contains { $0.kind == .assistant && $0.status == "complete" && $0.text == "Done \(index)." }
            }
            XCTAssertTrue(settled, "precondition: turn \(index) never settled: \(chat.entries.map(\.id))")
        }
        let execReply = try XCTUnwrap(chat.entries.first { $0.kind == .assistant && $0.text == "Done 0." })
        let navigateReply = try XCTUnwrap(chat.entries.first { $0.kind == .assistant && $0.text == "Done 1." })

        XCTAssertTrue(chat.turnMutatedState(before: execReply.id), "a turn that ran browser_exec must still ask before Retry repeats it")
        XCTAssertFalse(chat.turnMutatedState(before: navigateReply.id), "a turn that only navigated never asked, and still must not")

        await harness.tearDown()
    }
}
