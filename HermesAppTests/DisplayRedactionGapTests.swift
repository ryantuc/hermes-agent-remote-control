import Foundation
import XCTest

@testable import HermesMobile

/// BUG-072A, from the display side.
///
/// `DisplayRedaction.toolOutput` / `.approvalCommand` / `.preview` are the
/// surfaces a secret was actually *rendered* on — the tool card, the args
/// preview, the full-screen reader — and each one is `Redaction.text` plus a
/// truncation and nothing else. The kit tests pin the patterns; these pin that
/// the screen inherits them, which is the claim that matters to someone holding
/// the phone.
final class DisplayRedactionGapTests: XCTestCase {

    func testToolOutputMasksAnEchoedProviderKey() {
        let output = DisplayRedaction.toolOutput(
            "$ printenv | grep -i api\nOPENAI_API_KEY=" + "sk-proj-" + "abcdefghijklmnopqrstuvwxyz0123456789")
        XCTAssertFalse(output.contains("abcdefghijklmnop"))
        XCTAssertTrue(output.contains("printenv"), "the command that produced it still reads")
    }

    /// The literal is assembled at run time rather than written whole, because a
    /// public repository's secret scanning matches the shape and not the meaning:
    /// this is GitHub's own documented sample value and there is nothing to leak,
    /// but a whole one in a tracked file raises an alert on every push.
    func testToolOutputMasksAGitHubToken() {
        let sample = "ghp_" + "16C7e42F292c6912E7710c838347Ae178B4a"
        let output = DisplayRedaction.toolOutput("remote: " + sample)
        XCTAssertFalse(output.contains(sample))
    }

    /// BUG-072B on the screen: the query key that `Redaction.url` masked and
    /// `Redaction.text` did not.
    func testToolOutputMasksTheDriftedQueryKeys() {
        for key in ["code", "key", "state"] {
            let output = DisplayRedaction.toolOutput("callback https://box.example/cb?\(key)=S3CRETVALUE0123456789")
            XCTAssertFalse(output.contains("S3CRETVALUE0123456789"), "?\(key)= still renders raw")
        }
    }

    func testAListPreviewMasksToo() {
        let preview = DisplayRedaction.preview("here is the key\n" + "sk-" + "abcdefghijklmnopqrstuvwxyz")
        XCTAssertFalse(preview.contains("sk-" + "abcdefghijklmnopqrstuvwxyz"))
    }

    func testOrdinaryToolOutputIsStillReadable() {
        let sample = "prompt_tokens: 1500, completion_tokens: 320\nstate: running\nexit code: 0"
        XCTAssertEqual(DisplayRedaction.toolOutput(sample), sample)
    }
}
