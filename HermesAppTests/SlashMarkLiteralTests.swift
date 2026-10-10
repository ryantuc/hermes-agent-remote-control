import Foundation
import HermesServeKit
import XCTest

@testable import HermesMobile

/// FEAT-043, the model half of Send as text. The composer side (`ComposerSendAsText.send`) marked a typed `/tmp is full` literal by replaying the draft through `update` as a paste over the leading token, the one provenance rule that establishes a literal draft. `markLiteral()` says it directly. Specification tests for API this change adds, so they ride with it rather than a red commit.
@MainActor
final class SlashMarkLiteralTests: XCTestCase {
    private let scope = SlashCompletionScope(backendID: "one", profileID: "default", connectionID: "socket-1")

    private func type(_ model: SlashCompletionModel, _ text: String) {
        model.update(text: text, selection: NSRange(location: text.utf16.count, length: 0),
                     isComposing: false, isPaste: false, scope: scope, api: nil)
    }

    func testMarkingATypedCommandLiteralMakesItWords() {
        let model = SlashCompletionModel(debounce: .zero)
        type(model, "/tmp is full of logs again")
        XCTAssertTrue(model.commandIntent(for: "/tmp is full of logs again"), "precondition: a typed leading slash is a command")

        model.markLiteral()

        XCTAssertFalse(model.commandIntent(for: "/tmp is full of logs again"), "Send as text was chosen and Send would still run a command")
        XCTAssertTrue(model.items.isEmpty)
        XCTAssertNil(model.notice)
    }

    func testTheDraftStaysLiteralWhileItsLeadingSlashStays() {
        let model = SlashCompletionModel(debounce: .zero)
        type(model, "/tmp is full")
        model.markLiteral()
        type(model, "/tmp is full of logs")
        XCTAssertFalse(model.commandIntent(for: "/tmp is full of logs"), "editing the words after Send as text turned them back into a command")
    }

    func testRemovingTheLeadingSlashEndsTheLiteralMarking() {
        let model = SlashCompletionModel(debounce: .zero)
        type(model, "/tmp is full")
        model.markLiteral()
        type(model, "")
        type(model, "/help")
        XCTAssertTrue(model.commandIntent(for: "/help"), "a fresh typed command after clearing the draft must be a command again")
    }
}
