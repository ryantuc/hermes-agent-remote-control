import XCTest

@testable import HermesServeKit

/// Review residuals for BUG-072 — the measured leaks the first gap pass missed.
final class RedactionResidualTests: XCTestCase {
    private static let canary = "S3CRETVALUE0123456789"

    func testURLEncodedQueryAssignmentsAreMasked() {
        let masked = Redaction.text("see https://box.example/cb?api_key%3D\(Self.canary)&cols=96")
        XCTAssertFalse(masked.contains(Self.canary), "URL-encoded ?api_key%3D leaked: \(masked)")
        XCTAssertTrue(masked.contains("api_key%3D"))
        XCTAssertTrue(masked.contains("cols=96"))
    }

    func testWrappedTokenTailsAreMasked() {
        let head = "sk-" + "abcdefghijklmnopqrst"
        let tail = "uvwxyz0123456789"
        let raw = "here is \(head)\n\(tail) and more"
        let masked = Redaction.text(raw)
        XCTAssertFalse(masked.contains(head))
        XCTAssertFalse(masked.contains(tail), "a soft-wrapped token tail must not print: \(masked)")
        XCTAssertTrue(masked.contains("and more"))
    }

    func testAWSTemporaryAndSlackAppTokensAreMasked() {
        let asia = Redaction.text("AWS_SESSION_TOKEN_ID=ASIAIOSFODNN7EXAMPLE")
        XCTAssertFalse(asia.contains("ASIAIOSFODNN7EXAMPLE"), "ASIA leaked: \(asia)")

        let xoxe = Redaction.text("SLACK_REFRESH=xoxe-1-123456789012-1234567890123-AbCdEfGhIjKlMnOpQrStUv")
        XCTAssertFalse(xoxe.contains("AbCdEfGhIjKlMnOpQrStUv"), "xoxe leaked: \(xoxe)")

        let xapp = Redaction.text("SLACK_APP=xapp-1-A0123456789-1234567890123-AbCdEfGhIjKlMnOpQrStUvWx")
        XCTAssertFalse(xapp.contains("AbCdEfGhIjKlMnOpQrStUvWx"), "xapp leaked: \(xapp)")
    }

    func testCaseMangledPrefixesAreMasked() {
        // Assembled at run time: a public repository's secret scanning matches
        // the shape, and this is GitHub's own documented sample value.
        let body = "16C7e42F292c6912E7710c838347Ae178B4a"
        let ghp = Redaction.text("remote: " + "GHP_" + body)
        XCTAssertFalse(ghp.contains(body), "GHP_ leaked: \(ghp)")

        let xox = Redaction.text("token=XOXB-123456789012-1234567890123-AbCdEfGhIjKlMnOpQrStUvWx")
        XCTAssertFalse(xox.contains("AbCdEfGhIjKlMnOpQrStUvWx"), "XOXB leaked: \(xox)")

        let akiaReal = Redaction.text("key=AKIAIOSFODNN7EXAMPLE")
        XCTAssertFalse(akiaReal.contains("AKIAIOSFODNN7EXAMPLE"), "AKIA leaked: \(akiaReal)")
        // `(?i)` makes the body class case-insensitive too, so a lower-case
        // AKIA-shaped run is also masked. That is acceptable; the important
        // false-positive guard is the word-boundary case below.
    }

    func testOrdinaryProseStillSurvivesTheBroaderPrefixes() {
        let samples = [
            "prompt_tokens: 1500, completion_tokens: 320",
            "state: running",
            "let sky = 1",
            "risk-assessment-methodology-v2",
            "MYAKIAIOSFODNN7EXAMPLE stays ordinary prose",
        ]
        for sample in samples {
            XCTAssertEqual(Redaction.text(sample), sample, "over-masked: \(sample)")
        }
    }
}
