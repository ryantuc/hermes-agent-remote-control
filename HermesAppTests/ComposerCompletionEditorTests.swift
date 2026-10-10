import SwiftUI
import UIKit
import XCTest

@testable import HermesMobile

@MainActor
final class ComposerCompletionEditorTests: XCTestCase {
    private final class Buffer {
        var text: String
        var snapshots: [ComposerEditorSnapshot] = []
        init(_ text: String) { self.text = text }
    }

    private func editor(_ text: String, cursor: Int) -> (
        Buffer, GrowingComposerField.ComposerTextView, GrowingComposerField.Coordinator
    ) {
        let buffer = Buffer(text)
        let field = GrowingComposerField(
            text: Binding(get: { buffer.text }, set: { buffer.text = $0 }),
            placeholder: "Compose", textColor: .gray, isFocused: .constant(false),
            onEditorChange: { buffer.snapshots.append($0) }
        )
        let coordinator = field.makeCoordinator()
        let textView = GrowingComposerField.ComposerTextView()
        textView.text = text
        textView.selectedRange = NSRange(location: cursor, length: 0)
        textView.delegate = coordinator
        return (buffer, textView, coordinator)
    }

    func testCompletionReplacesOnlyIntendedTokenAndReportsCursorWithoutSending() {
        let draft = "/mo keep 🐈 arguments\n> untouched quote"
        let (buffer, view, coordinator) = editor(draft, cursor: 3)
        let request = ComposerEditorReplacement(
            expectedText: draft, expectedSelection: view.selectedRange,
            range: NSRange(location: 1, length: 2), text: "model"
        )
        XCTAssertTrue(coordinator.apply(request, to: view))
        XCTAssertEqual(buffer.text, "/model keep 🐈 arguments\n> untouched quote")
        XCTAssertEqual(view.selectedRange, NSRange(location: 6, length: 0))
        XCTAssertEqual(buffer.snapshots.last?.origin, .completion)
        XCTAssertEqual(buffer.snapshots.last?.selection, view.selectedRange)
        XCTAssertEqual(buffer.snapshots.last?.editedRange, request.range)
    }

    func testLateCompletionCannotReplaceEditedTextOrMovedCursor() {
        let draft = "/mo arguments"
        let (buffer, view, coordinator) = editor(draft, cursor: 3)
        let request = ComposerEditorReplacement(
            expectedText: draft, expectedSelection: view.selectedRange,
            range: NSRange(location: 1, length: 2), text: "model"
        )
        view.selectedRange = NSRange(location: 5, length: 0)
        XCTAssertFalse(coordinator.apply(request, to: view))
        XCTAssertEqual(view.text, draft)
        view.text = "/more arguments"
        view.selectedRange = request.expectedSelection
        XCTAssertFalse(coordinator.apply(request, to: view))
        XCTAssertEqual(view.text, "/more arguments")
        XCTAssertEqual(buffer.text, draft)
    }

    func testInvalidUTF16RangeCannotSplitEmoji() {
        let draft = "/model 🐈"
        let (_, view, coordinator) = editor(draft, cursor: (draft as NSString).length)
        for range in [NSRange(location: 8, length: 1), NSRange(location: 7, length: 1),
                      NSRange(location: 8, length: 0), NSRange(location: NSNotFound, length: 1)] {
            let request = ComposerEditorReplacement(
                expectedText: draft, expectedSelection: view.selectedRange, range: range, text: "bad"
            )
            XCTAssertFalse(coordinator.apply(request, to: view))
            XCTAssertEqual(view.text, draft)
        }
        let valid = ComposerEditorReplacement(
            expectedText: draft, expectedSelection: view.selectedRange,
            range: NSRange(location: 7, length: 2), text: "🐕"
        )
        XCTAssertTrue(coordinator.apply(valid, to: view))
        XCTAssertEqual(view.text, "/model 🐕")
    }

    func testMarkedTextCannotBeReplacedAndDoesNotClaimCompletionKeys() {
        let (_, view, coordinator) = editor("/model ", cursor: 7)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 600))
        let host = UIViewController()
        window.rootViewController = host
        host.view.addSubview(view)
        view.frame = host.view.bounds
        window.makeKeyAndVisible()
        view.becomeFirstResponder()
        view.setMarkedText("未", selectedRange: NSRange(location: 1, length: 0))
        XCTAssertNotNil(view.markedTextRange)
        let markedDraft = view.text ?? ""
        let request = ComposerEditorReplacement(
            expectedText: markedDraft, expectedSelection: view.selectedRange,
            range: NSRange(location: 7, length: 1), text: "replacement"
        )
        view.hasCompletions = true
        XCTAssertFalse(coordinator.apply(request, to: view))
        XCTAssertEqual(view.text, markedDraft)
        XCTAssertFalse(view.keyCommands?.contains { $0.wantsPriorityOverSystemBehavior && $0.input == "\t" } ?? false)
        view.unmarkText()
        window.isHidden = true
    }

    func testCompletionKeysExcludeReturnAndOnlyOverrideWhenListIsOpen() {
        let (_, view, _) = editor("/", cursor: 1)
        XCTAssertFalse(view.keyCommands?.contains { $0.wantsPriorityOverSystemBehavior && $0.input == "\t" } ?? false)
        view.hasCompletions = true
        let completionKeys = (view.keyCommands ?? []).filter(\.wantsPriorityOverSystemBehavior).compactMap(\.input)
        XCTAssertTrue(completionKeys.contains(UIKeyCommand.inputUpArrow))
        XCTAssertTrue(completionKeys.contains(UIKeyCommand.inputDownArrow))
        XCTAssertTrue(completionKeys.contains(UIKeyCommand.inputEscape))
        XCTAssertTrue(completionKeys.contains("\t"))
        XCTAssertFalse(completionKeys.contains("\r"))
        XCTAssertFalse(completionKeys.contains("\n"))
    }

    func testBulkInsertionReportsPasteProvenance() {
        let (buffer, view, coordinator) = editor("", cursor: 0)
        XCTAssertTrue(coordinator.textView(view, shouldChangeTextIn: view.selectedRange, replacementText: "/help pasted prose"))
        view.text = "/help pasted prose"
        coordinator.textViewDidChange(view)
        XCTAssertEqual(buffer.snapshots.last?.origin, .paste)
        XCTAssertEqual(buffer.snapshots.last?.editedRange, NSRange(location: 0, length: 0))
        coordinator.textViewDidChangeSelection(view)
        XCTAssertEqual(buffer.snapshots.last?.origin, .selection)
        XCTAssertNil(buffer.snapshots.last?.editedRange)
    }
}
