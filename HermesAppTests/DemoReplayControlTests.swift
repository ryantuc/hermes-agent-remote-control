import Foundation
import HermesServeKit
import XCTest

@testable import HermesMobile

/// BUG-102 and BUG-103 — the demo under a reviewer's finger.
///
/// The demo is the one thing App Review will actually drive, and the two ways a
/// person who *touches* it rather than watching it can make it look broken were
/// both in `DemoBackend`.
///
/// **BUG-102.** `session.interrupt` was answered `{"ok": true}` and otherwise
/// ignored: nothing cancelled the replay. The client's own optimistic latch is
/// time-boxed at five seconds and the scripted turns run past seven, so the
/// observable behaviour was worse than the report — Stop cleared the spinner
/// and unlocked the composer, and then the answer started writing itself again
/// with its middle missing.
///
/// **BUG-103.** The script was selected by a process-wide submission counter,
/// so one message typed during the autoplay consumed the slot the second
/// scripted turn was going to occupy and the flagship plan / tool-card / report
/// beats never played. The same submit also cancelled the replay in flight
/// before it could mark its turn complete, stranding a half-written answer with
/// no terminal frame.
@MainActor
final class DemoReplayControlTests: XCTestCase {

    private static let testSpeed: Double = 25

    private func freshModel() -> AppModel {
        UserDefaults.standard.removeObject(forKey: "hermes.activeBackendProfile.v1")
        let app = AppModel()
        app.profiles = []
        return app
    }

    // MARK: BUG-102 — Stop stops it, and it stays stopped

    /// The measure is **frames off the socket**, not entries in the transcript.
    ///
    /// The client swallows a cancelled turn's in-flight events for five seconds
    /// (`TurnEngine.interruptGrace`), so a transcript that stops growing proves
    /// nothing — it is precisely how BUG-102 hid until the grace expired and
    /// the answer started writing itself again. `emittedFrameCount` is the
    /// backend's own count and no latch touches it.
    ///
    /// Autoplay is off and the speed is low. With the driver running, the
    /// second scripted question arrives a tenth of a second after the first
    /// answer ends and its thirteen frames are indistinguishable from a replay
    /// that ignored the Stop; and at speed 25 the whole turn is over before a
    /// Stop can land in the middle of it, which would pass vacuously.
    func testStopEndsTheScriptedReplayForGood() async throws {
        let app = freshModel()
        defer { app.profiles = [] }

        await app.enterDemo(playbackSpeed: 4, autoplay: false)
        let backend = try XCTUnwrap(app.demo)
        let chat = app.chat(for: app.demoThreadRoute)
        await chat.openIfNeeded()

        chat.draft = DemoScript.turnOne.prompt
        chat.sendTapped()

        // Mid-stream: the answer has started and the turn has not finished.
        let streaming = await waitUntil(timeout: 20) {
            // Each read is its own `await`: `&&` takes its right operand as an
            // autoclosure and an `await` cannot appear inside one.
            let finishedTurns = await backend.completedTurns
            let hasAssistantEntry = !chat.entries.filter { $0.kind == .assistant }.isEmpty
            return finishedTurns == 0 && hasAssistantEntry
        }
        XCTAssertTrue(streaming, "the scripted turn never started streaming")

        await chat.interrupt()

        // The interrupted turn is finished rather than abandoned: a message
        // that never receives a terminal frame sits in the transcript as a
        // permanent half-answer.
        let finished = await waitUntil(timeout: 5) {
            let finishedTurns = await backend.completedTurns
            return finishedTurns >= 1
        }
        XCTAssertTrue(finished, "the cancelled turn was never completed — nothing would ever settle it")

        let framesAtStop = await backend.emittedFrameCount
        let scriptedEvents = DemoScript.turnOne.beats.filter {
            if case .event = $0 { return true }
            return false
        }.count
        XCTAssertLessThan(
            framesAtStop, scriptedEvents,
            "the Stop landed after the turn had already played all \(scriptedEvents) of its frames, so this test proved nothing about Stop"
        )

        try? await Task.sleep(nanoseconds: 1_500_000_000)
        let framesLater = await backend.emittedFrameCount
        XCTAssertEqual(
            framesLater, framesAtStop,
            "\(framesLater - framesAtStop) more frames arrived after Stop — `session.interrupt` was answered ok and cancelled nothing, and once the client's five-second grace expired they started painting again"
        )

        await app.exitDemo()
    }

    // MARK: BUG-103 — an interjection does not derail the script

    func testAnInterjectionGetsTheCannedReplyAndTheScriptKeepsItsTurns() async throws {
        let app = freshModel()
        defer { app.profiles = [] }

        await app.enterDemo(playbackSpeed: Self.testSpeed)
        defer { Task { await app.exitDemo() } }
        let backend = try XCTUnwrap(app.demo)

        // The reviewer's own message, arriving between the driver's two
        // scripted prompts. It must be answered by the freeform turn.
        await backend.submitDirectly(prompt: "are you actually running right now?")
        let answered = await waitUntil(timeout: 20) {
            let done = await backend.completedPrompts
            return done.contains("are you actually running right now?")
        }
        XCTAssertTrue(answered, "the interjection never got an answer")

        // Both scripted turns still play, and both still get *their* answers.
        let played = await waitUntil(timeout: 30) {
            let done = await backend.completedPrompts
            return done.contains(DemoScript.turnOne.prompt) && done.contains(DemoScript.turnTwo.prompt)
        }
        XCTAssertTrue(
            played,
            "one message from a reviewer used to shift every later turn down a slot, so the second scripted turn — the plan, the tool cards, the written report — was answered with the generic demo reply instead"
        )

        let chat = app.chat(for: app.demoThreadRoute)
        let settled = await waitUntil(timeout: 10) { !chat.live.isBusy }
        XCTAssertTrue(settled, "the transcript never settled after the interjection")
        let assistant = chat.entries.filter { $0.kind == .assistant }
        XCTAssertTrue(
            assistant.allSatisfy { !$0.isStreaming },
            "an assistant entry left streaming is the stranded half-answer BUG-103's cancellation produced"
        )
        XCTAssertTrue(
            assistant.contains { $0.text.contains("Hermes Agent — what it is") },
            "the second scripted turn's report is the thing the demo exists to show; it was missing whenever anyone typed"
        )
    }

    /// The selector itself, without a socket: the same prompt always gets the
    /// same turn, whatever order things arrive in.
    func testTheScriptIsSelectedByPromptAndNotByOrder() {
        XCTAssertEqual(DemoScript.turn(forPrompt: DemoScript.turnOne.prompt).prompt, DemoScript.turnOne.prompt)
        XCTAssertEqual(DemoScript.turn(forPrompt: DemoScript.turnTwo.prompt).prompt, DemoScript.turnTwo.prompt)
        XCTAssertEqual(
            DemoScript.turn(forPrompt: "  \(DemoScript.turnTwo.prompt)  ").prompt,
            DemoScript.turnTwo.prompt,
            "the composer trims; the selector must too"
        )
        XCTAssertEqual(
            DemoScript.turn(forPrompt: DemoScript.turnOne.prompt.lowercased()).prompt,
            DemoScript.turnOne.prompt,
            "iOS autocapitalisation means a hand-typed version of the same question is not byte-identical"
        )
        XCTAssertEqual(
            DemoScript.turn(forPrompt: "something nobody scripted").beats.count,
            DemoScript.freeformTurn.beats.count,
            "anything else gets the canned 'this is a demo' answer"
        )
        XCTAssertNotEqual(
            DemoScript.turn(forPrompt: "something nobody scripted").beats.count,
            DemoScript.turnTwo.beats.count,
            "and it is not the showcase turn — that one belongs to its own question"
        )
        XCTAssertEqual(DemoScript.autoplayTurnCount, DemoScript.autoplayTurns.count)
        XCTAssertEqual(DemoScript.autoplayTurn(0).prompt, DemoScript.turnOne.prompt)
        XCTAssertEqual(DemoScript.autoplayTurn(1).prompt, DemoScript.turnTwo.prompt)
    }
}
