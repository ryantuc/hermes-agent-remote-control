import Foundation
import XCTest

@testable import HermesServeKit

/// BUG-072 — the gaps in the one client-side scrubber.
///
/// `Redaction.text` is not just a log filter. `DisplayRedaction.toolOutput`,
/// `.approvalCommand` and `.preview` are all `Redaction.text` and nothing else,
/// so this function is the entire secret defence on the tool card, the args
/// preview, the full-screen reader and the diagnostics export. Three things
/// were wrong with it: it knew no token prefixes, its query-key alternation had
/// drifted from `sensitiveQueryKeys`, and the login line it scrubbed carried an
/// account name no pattern could ever match.
final class RedactionGapTests: XCTestCase {

    private static let canary = "S3CRETVALUE0123456789"

    // MARK: - B: the two scrubbers cannot drift apart again

    /// The regression proper. `code`, `key` and `state` were in
    /// `sensitiveQueryKeys` and absent from the free-text alternation, so the
    /// same URL was masked by `url(_:)` and raw by `text(_:)`. This asserts the
    /// invariant rather than the three instances: every key the URL scrubber
    /// treats as a credential, the text scrubber treats as one too.
    func testEverySensitiveQueryKeyIsMaskedInFreeTextAsWellAsInURLs() throws {
        for key in Redaction.sensitiveQueryKeys.sorted() {
            let raw = "see https://box.example/callback?\(key)=\(Self.canary)&cols=96 for details"

            let inText = Redaction.text(raw)
            XCTAssertFalse(
                inText.contains(Self.canary),
                "Redaction.text leaked the value of ?\(key)= : \(inText)"
            )
            XCTAssertTrue(inText.contains(key), "the key name should survive so the reader knows what was present")

            let url = try XCTUnwrap(URL(string: "https://box.example/callback?\(key)=\(Self.canary)&cols=96"))
            XCTAssertFalse(Redaction.url(url).contains(Self.canary))
        }
    }

    /// The three that were actually missing, named, so a future edit that
    /// re-hardcodes the alternation fails on the specific loss as well as on
    /// the invariant above.
    func testTheThreeDriftedQueryKeysAreMasked() {
        for key in ["code", "key", "state"] {
            let masked = Redaction.text("https://x/y?\(key)=\(Self.canary)")
            XCTAssertFalse(masked.contains(Self.canary), "?\(key)= still leaks: \(masked)")
        }
    }

    func testTheSecondQueryParameterIsMaskedToo() {
        let masked = Redaction.text("https://x/y?cols=96&key=\(Self.canary)")
        XCTAssertFalse(masked.contains(Self.canary))
        XCTAssertTrue(masked.contains("cols=96"))
    }

    // MARK: - A: token shapes an agent's own output echoes

    func testMasksOpenAIStyleKeys() {
        let masked = Redaction.text("OPENAI_API_KEY=" + "sk-proj-" + "abcdefghijklmnopqrstuvwxyz0123456789")
        XCTAssertFalse(masked.contains("sk-proj-" + "abcdefghijklmnopqrstuvwxyz0123456789"))
        XCTAssertFalse(masked.contains("abcdefghijklmnop"))
    }

    func testMasksABareOpenAIKeyInProse() {
        let masked = Redaction.text("the key is " + "sk-" + "abcdefghijklmnopqrstuvwxyz" + " and it works")
        XCTAssertFalse(masked.contains("sk-" + "abcdefghijklmnopqrstuvwxyz"))
        XCTAssertTrue(masked.contains("the key is"))
        XCTAssertTrue(masked.contains("and it works"))
    }

    /// The literals are assembled at run time rather than written whole, because a
    /// public repository's secret scanning matches the shape and not the meaning:
    /// these are GitHub's own documented sample values and there is nothing to
    /// leak, but a whole one in a tracked file raises an alert on every push.
    func testMasksGitHubTokens() {
        let body = "16C7e42F292c6912E7710c838347Ae178B4a"
        let masked = Redaction.text("remote: " + "ghp_" + body)
        XCTAssertFalse(masked.contains("ghp_" + body))

        let oauth = Redaction.text("gho_" + body)
        XCTAssertFalse(oauth.contains(body))
    }

    func testMasksSlackTokens() {
        for prefix in ["xoxb", "xoxp"] {
            let masked = Redaction.text("SLACK=\(prefix)-123456789012-1234567890123-AbCdEfGhIjKlMnOpQrStUvWx")
            XCTAssertFalse(masked.contains("AbCdEfGhIjKlMnOpQrStUvWx"), "\(prefix) still leaks: \(masked)")
        }
    }

    func testMasksAWSAccessKeyIDs() {
        let masked = Redaction.text("AWS_ACCESS_KEY_ID=AKIAIOSFODNN7EXAMPLE")
        XCTAssertFalse(masked.contains("AKIAIOSFODNN7EXAMPLE"))
    }

    /// The JSON shape a `curl` echo or a config dump prints.
    func testMasksAnApiKeyAssignmentWithNoRecognisablePrefix() {
        let masked = Redaction.text("{\"api_key\": \"\(Self.canary)\", \"model\": \"gpt-5\"}")
        XCTAssertFalse(masked.contains(Self.canary))
        XCTAssertTrue(masked.contains("api_key"), "the key name survives")
        XCTAssertTrue(masked.contains("gpt-5"), "an unrelated value beside it survives")
    }

    func testMasksAnEnvStyleApiKeyAssignment() {
        let masked = Redaction.text("ANTHROPIC_API_KEY=\(Self.canary)")
        XCTAssertFalse(masked.contains(Self.canary))
    }

    /// `Authorization:` without the literal word Bearer — the case the one
    /// existing pattern could not see. Its value has an internal space, so a
    /// scrubber that stops at whitespace masks the scheme and prints the
    /// credential.
    func testMasksANonBearerAuthorizationHeader() {
        let masked = Redaction.text("Authorization: Basic dXNlcjpwYXNzd29yZA==")
        XCTAssertFalse(masked.contains("dXNlcjpwYXNzd29yZA=="))
    }

    func testMasksAPasswordAssignment() {
        let masked = Redaction.text("password=\(Self.canary)")
        XCTAssertFalse(masked.contains(Self.canary))
    }

    // MARK: - What must NOT be masked

    /// The false-positive budget. An over-eager scrubber makes tool cards
    /// unreadable, which is why `token`, `key`, `code` and `state` are query
    /// keys but not assignment keys: `tokens: 1500` and `state: running` are
    /// ordinary agent output and masking them would buy nothing.
    func testOrdinaryToolOutputIsLeftAlone() {
        let samples = [
            "prompt_tokens: 1500, completion_tokens: 320",
            "state: running",
            "exit code: 0",
            "key: value",
            "the task-management-system is fine",
            "risk-assessment-methodology-v2",
            "let sky = 1",
        ]
        for sample in samples {
            XCTAssertEqual(Redaction.text(sample), sample, "over-masked: \(sample)")
        }
    }

    // MARK: - The shapes that already worked keep working

    func testTheExistingPatternsStillHold() {
        XCTAssertFalse(Redaction.text("Authorization: Bearer abcdef0123456789").contains("abcdef0123456789"))
        XCTAssertFalse(Redaction.text("x-hermes-session-token: \(Self.canary)").contains(Self.canary))

        let dataURL = "data:image/png;base64," + String(repeating: "A", count: 64)
        let masked = Redaction.text("here it is \(dataURL) done")
        XCTAssertFalse(masked.contains(String(repeating: "A", count: 64)))
        XCTAssertTrue(masked.contains("done"))
    }
}
