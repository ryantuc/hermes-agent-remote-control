import Foundation
import HermesServeKit
import SwiftUI
import UIKit
import XCTest

@testable import HermesMobile

/// FEAT-020 — the demo an App Store reviewer can exercise with no backend.
///
/// The demo's whole claim is that it is the *real* app fed by a fake transport:
/// the shipping `HermesClient`, the shipping `TurnEngine`, the shipping
/// `ChatModel` and the shipping transcript, with a `DemoTransport` where the
/// socket would be. So these tests assert on what the real objects end up
/// holding — a transcript, tool cards, a plan, a finished turn — rather than on
/// the script that produced them. A test that only checked the script would
/// pass just as happily against a mock view, which is the outcome the feature
/// exists to avoid.
///
/// Every replay here runs at a raised `playbackSpeed`. That divides the pauses
/// and nothing else: the same frames, in the same order, with the gaps taken
/// out. The seam is the same one `HermesClient.handshakeBudget` is, and for the
/// same reason.
@MainActor
final class DemoModeTests: XCTestCase {

    /// Fast enough to finish inside a test, slow enough that the engine's flush
    /// loop still runs between beats.
    private static let testSpeed: Double = 25

    /// `AppModel.init` loads whatever the host app left in `UserDefaults`, so
    /// every test here starts by clearing the profile list — the same
    /// precaution `AppHarness` and `HomeFirstRunTests` take.
    private func freshModel() -> AppModel {
        let app = AppModel()
        app.profiles = []
        return app
    }

    // MARK: RED-1 — the script reaches the real transcript

    func testTheDemoScriptReplaysThroughTheRealTranscript() async throws {
        let app = freshModel()
        defer { app.profiles = [] }

        await app.enterDemo(playbackSpeed: Self.testSpeed)
        let backend = try XCTUnwrap(
            app.demo,
            "entering the demo must install a demo backend — without one there is no transport to replay through"
        )

        let played = await waitUntil(timeout: 25) {
            await backend.completedTurns >= DemoScript.autoplayTurnCount
        }
        XCTAssertTrue(
            played,
            "the two scripted turns never finished replaying; the demo is supposed to play itself with no taps at all"
        )
        // The last turn's own settle lands on the next engine flush.
        let settled = await waitUntil(timeout: 5) {
            !app.chat(for: app.demoThreadRoute).live.isBusy
        }
        XCTAssertTrue(settled, "the second turn never settled — a demo that ends mid-stream shows a spinner, not a product")

        let chat = app.chat(for: app.demoThreadRoute)
        let entries = chat.entries

        // Both prompts arrive through the real send path rather than being written into the transcript.
        let userTexts = entries.filter { $0.kind == .user }.map(\.text)
        XCTAssertEqual(
            userTexts,
            [DemoScript.turnOne.prompt, DemoScript.turnTwo.prompt],
            "the demo's two questions must be in the transcript as real user turns, in order"
        )

        // A finished answer. `status` is what the bubble reads to stop drawing a
        // typing indicator, so an unfinished last turn is visible.
        let assistant = entries.filter { $0.kind == .assistant }
        XCTAssertGreaterThanOrEqual(
            assistant.count, 2,
            "one answer per question, at least; got \(assistant.count)"
        )
        let last = try XCTUnwrap(assistant.last)
        XCTAssertEqual(
            last.status, "complete",
            "the demo's last turn must be finished — a transcript frozen mid-stream is the one thing a reviewer must not see"
        )
        XCTAssertTrue(
            last.text.contains("Hermes Agent — what it is"),
            "the second turn ends in the written report it promised; got: \(last.text.prefix(120))"
        )

        // A thinking trace, on at least one turn.
        XCTAssertTrue(
            assistant.contains { !$0.reasoning.isEmpty },
            "the demo is supposed to show the agent thinking — no entry carried a reasoning trace"
        )

        // The tool cards. Named, because "some tool ran" is not what the
        // reviewer is being shown: reading a note, searching a corpus and
        // writing a file are three different cards.
        let toolNames = Set(entries.compactMap { $0.tool?.name })
        for expected in ["read_file", "search", "write_file"] {
            XCTAssertTrue(
                toolNames.contains(expected),
                "the transcript is missing the \(expected) card; tool cards are most of what this client is for. Saw: \(toolNames.sorted())"
            )
        }
        XCTAssertTrue(
            toolNames.contains(TodoList.toolName),
            "the plan arrives as a todo tool call; without it the activity strip has nothing to count"
        )

        // A diff, so the edit card is exercised too.
        XCTAssertTrue(
            entries.contains { !($0.tool?.inlineDiff ?? "").isEmpty },
            "the write step carries an inline diff and the diff card is one of the surfaces the screenshots need"
        )

        // The plan itself, finished. This is what the activity strip's fraction
        // is computed from (`AppModel.liveStepFraction`).
        let todos = chat.live.activity.todos
        XCTAssertEqual(
            todos.items.count, DemoScript.planSteps.count,
            "the demo's plan is \(DemoScript.planSteps.count) steps and the strip counts them; got \(todos.items.count)"
        )
        XCTAssertTrue(
            todos.isFinished,
            "the plan must end complete — a strip stuck at 3/4 after the answer landed reads as a stalled agent"
        )
        XCTAssertEqual(
            StripProgress.todos(todos), "\(DemoScript.planSteps.count)/\(DemoScript.planSteps.count)",
            "the strip's own progress string is the thing on screen; it must read as finished"
        )

        await app.exitDemo()
    }

    // MARK: RED-2 — the marker is on while the demo runs, and gone after

    /// The marker is a top safe-area inset on the shell's root, so its presence
    /// is measurable: the same content is taller with the bar than without it.
    /// Measuring rather than looking for a view keeps this from passing
    /// vacuously against a modifier that inserts nothing.
    private func hostedHeight(isActive: Bool) -> CGFloat {
        let width: CGFloat = 320
        let probe = Color.clear
            .frame(width: width, height: 200)
            .demoModeMarker(isActive: isActive, onExit: {})
        let host = UIHostingController(rootView: AnyView(probe))
        host.safeAreaRegions = []
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: width, height: 1400))
        window.rootViewController = host
        window.makeKeyAndVisible()
        window.layoutIfNeeded()
        host.view.layoutIfNeeded()
        let size = host.sizeThatFits(in: CGSize(width: width, height: .greatestFiniteMagnitude))
        window.isHidden = true
        return size.height
    }

    func testTheDemoMarkerIsOnScreenWhileTheDemoRunsAndGoneAfterExit() async throws {
        let bare = hostedHeight(isActive: false)
        let marked = hostedHeight(isActive: true)
        XCTAssertGreaterThan(
            marked, bare + 20,
            "the demo marker must actually displace the app — it measured \(marked) pt against \(bare) pt bare, which is a marker nobody would see"
        )

        // FEAT-030 / BUG-118: the separator is a middle dot so the title and
        // the unshrinkable Exit button still fit on one line at the largest
        // accessibility sizes. The assertion still requires both meanings.
        XCTAssertTrue(
            DemoModeBanner.title.contains("DEMO") && DemoModeBanner.title.contains("not connected"),
            "the marker has to say both things: that this is a demo and that nothing is connected"
        )
        XCTAssertFalse(DemoModeBanner.exitLabel.isEmpty, "the marker carries the way out")

        let app = freshModel()
        defer { app.profiles = [] }

        XCTAssertFalse(app.isDemoActive, "precondition: a fresh model is not in the demo")

        await app.enterDemo(playbackSpeed: Self.testSpeed)
        XCTAssertTrue(
            app.isDemoActive,
            "the marker is driven off this one predicate; if it does not turn on, nothing on screen says the content is canned"
        )
        XCTAssertFalse(
            app.needsBackend,
            "while the demo is running the first-run explainer must not sit over it — the screen is full"
        )

        await app.exitDemo()
        XCTAssertFalse(
            app.isDemoActive,
            "leaving the demo must clear the marker; a marker that outlives the demo is worse than none"
        )
        // FEAT-030: exit lands on Home (first-run when nothing is parked). The
        // old Settings → Backend hop was the interim first-run path this feature
        // retired.
        XCTAssertEqual(
            app.requestedRoute, [],
            "leaving the demo returns to Home; with no parked backend that is first-run Home"
        )
        XCTAssertTrue(
            app.needsBackend,
            "after the demo the device still has no backend, and the first-run state must come back"
        )
        XCTAssertNil(app.client, "the demo's client must go with the demo")
    }

    // MARK: RED-3 — nothing in demo mode can reach the network

    func testDemoModeConstructsNoNetworkTransport() async throws {
        let app = freshModel()
        defer { app.profiles = [] }

        await app.enterDemo(playbackSpeed: Self.testSpeed)

        XCTAssertNil(
            app.rest,
            "a `RestAPI` in demo mode is a URLSession pointed at something; the demo must work on a device with no network at all"
        )
        XCTAssertNil(
            app.auth,
            "an `AuthenticationClient` in demo mode would have a credential to send and somewhere to send it"
        )
        XCTAssertTrue(
            app.profiles.isEmpty,
            "the demo must not write a backend profile — one that survived a relaunch would be indistinguishable from a real backend the user configured"
        )
        XCTAssertNil(
            app.activeProfile,
            "there is no profile, so there is no active one; the demo is not a backend"
        )

        let backend = try XCTUnwrap(app.demo)
        let sockets = await backend.socketCount
        XCTAssertEqual(
            sockets, 1,
            "the client dialed \(sockets) demo sockets; exactly one means the transport factory produced a `DemoTransport` and no `WebSocketTransport` was built for this connection"
        )

        let open = await waitUntil(timeout: 5) { app.connectionState.isOpen }
        XCTAssertTrue(
            open,
            "the demo has to reach the connected state on its own — every send control in the app is gated on it"
        )

        await app.exitDemo()
        XCTAssertNil(app.demo, "the demo backend goes with the demo")
    }
}
