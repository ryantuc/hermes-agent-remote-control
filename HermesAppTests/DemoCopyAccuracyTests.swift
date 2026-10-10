import Foundation
import HermesServeKit
import XCTest

@testable import HermesMobile

/// The demo's words are the first a reviewer reads, so they may claim only what the app does: an approval appears where the backend's approval policy asks for one, nothing promises that requests stay on the user's machine, and the demo itself shows no approval.
final class DemoCopyAccuracyTests: XCTestCase {

    private static let turns: [(name: String, turn: DemoScript.Turn)] = [
        ("turn one", DemoScript.turnOne),
        ("turn two", DemoScript.turnTwo),
        ("the canned reply", DemoScript.freeformTurn),
    ]

    func testEveryTurnStreamsTheSameWordsItCompletesWith() {
        for (name, turn) in Self.turns {
            var streamed = ""
            var completed: String?
            for case .event(let type, let payload) in turn.beats {
                if type == "message.delta", case .string(let chunk)? = payload["text"] { streamed += chunk }
                if type == "message.complete", case .string(let text)? = payload["text"] { completed = text }
            }
            XCTAssertEqual(streamed, completed, "\(name) streams different words from the ones it settles on, so the answer jumps when it completes")
        }
    }

    func testNoDemoTextPromisesAnApprovalForEverythingOrThatNothingLeavesTheMachine() {
        let retired = ["anything dangerous", "every dangerous", "never leave", "never leaves"]
        for (name, turn) in Self.turns {
            for text in Self.strings(in: turn) {
                for phrase in retired {
                    XCTAssertFalse(text.lowercased().contains(phrase), "\(name) still says \"\(phrase)\": \(text.prefix(120))")
                }
            }
        }
    }

    func testTheCannedReplyDoesNotClaimTheDemoShowsApprovals() {
        XCTAssertFalse(DemoScript.freeformReply.lowercased().contains("approval"), "the demo never shows an approval, so its canned reply cannot list approval prompts among what it shows")
    }

    private static func strings(in turn: DemoScript.Turn) -> [String] {
        var out: [String] = []
        func collect(_ value: JSONValue) {
            switch value {
            case .string(let text): out.append(text)
            case .array(let items): items.forEach(collect)
            case .object(let fields): fields.values.forEach(collect)
            default: break
            }
        }
        for case .event(_, let payload) in turn.beats { collect(payload) }
        return out
    }
}
