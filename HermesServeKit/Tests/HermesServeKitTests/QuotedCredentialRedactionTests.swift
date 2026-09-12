import XCTest

@testable import HermesServeKit

/// Review regression: quoted credential values can contain spaces.
final class QuotedCredentialRedactionTests: XCTestCase {
    func testAQuotedPasswordMasksTheWholePassphrase() {
        let masked = Redaction.text(#"{"password": "hunter two", "model": "gpt-5"}"#)

        XCTAssertFalse(masked.contains("hunter"))
        XCTAssertFalse(masked.contains("two"), "the tail of a quoted passphrase must not survive")
        XCTAssertTrue(masked.contains("<redacted>"))
        XCTAssertTrue(masked.contains("\"model\": \"gpt-5\""), "the next JSON value stays readable")
    }

    func testASingleQuotedPasswordMasksTheWholePassphrase() {
        let masked = Redaction.text("password='correct horse battery staple'; mode=local")

        XCTAssertFalse(masked.contains("correct horse battery staple"))
        XCTAssertFalse(masked.contains("horse battery staple"), "the interior of a quoted passphrase must not survive")
        XCTAssertTrue(masked.contains("<redacted>"), "the credential value is replaced: \(masked)")
        XCTAssertTrue(masked.contains("mode=local"), "the assignment after the terminator stays readable: \(masked)")
    }

    func testAnUnquotedAssignmentStillStopsAtWhitespace() {
        let masked = Redaction.text("password=hunter next step stays readable")

        XCTAssertFalse(masked.contains("hunter"))
        XCTAssertTrue(masked.contains("next step stays readable"), "supporting spaces in quoted values must not over-mask prose")
    }
}
