import Foundation
import HermesServeKit
import XCTest

@testable import HermesMobile

/// What App Review meets first is the demo, and its finished answers carry Read aloud, Retry and Edit. Each is driven here through the call its button makes, on a demo that has played to the end, and each must finish, leave the chat idle and reach for no network: the demo has no backend, so anything that dialed out would hang or fail in front of a reviewer.
@MainActor
final class DemoMessageActionsTests: XCTestCase {

    private static let testSpeed: Double = 25

    override func setUp() {
        super.setUp()
        NetworkTripwire.reset()
        URLProtocol.registerClass(NetworkTripwire.self)
    }

    override func tearDown() {
        URLProtocol.unregisterClass(NetworkTripwire.self)
        ReadAloud.shared.stop()
        super.tearDown()
    }

    // MARK: Read aloud

    func testReadAloudOnEachFinishedAnswerSpeaksAndStops() async throws {
        let (app, backend, chat) = try await playedDemo()
        let answers = finishedAnswers(chat)
        XCTAssertGreaterThanOrEqual(answers.count, 2, "both scripted answers should be finished")
        for answer in answers {
            XCTAssertFalse(ReadAloud.spokenText(from: answer.text).isEmpty, "the answer has nothing to read aloud")
            ReadAloud.shared.toggle(id: answer.id, text: answer.text)
            XCTAssertEqual(ReadAloud.shared.speakingID, answer.id, "Read aloud did not start")
            ReadAloud.shared.toggle(id: answer.id, text: answer.text)
            XCTAssertNil(ReadAloud.shared.speakingID, "a second tap must stop reading")
        }
        await assertStillOffline(app, backend)
        await app.exitDemo()
    }

    // MARK: Retry

    func testRetryOnEachFinishedAnswerReplaysItsTurnAndSettles() async throws {
        let (app, backend, chat) = try await playedDemo()
        for prompt in [DemoScript.turnOne.prompt, DemoScript.turnTwo.prompt] {
            let answer = try XCTUnwrap(
                finishedAnswers(chat).last { chat.precedingUserEntry(before: $0.id)?.text == prompt },
                "no finished answer follows \"\(prompt)\""
            )
            let turnsBefore = await backend.completedTurns
            let answersBefore = finishedAnswers(chat).count
            // The button's own call; the demo never asks for a hold first (see the next test).
            chat.resendPrecedingUserTurn(before: answer.id)
            let replayed = await waitUntil(timeout: 30) { await backend.completedTurns > turnsBefore }
            XCTAssertTrue(replayed, "Retry on the answer to \"\(prompt)\" never reached the demo backend")
            let settled = await waitUntil(timeout: 10) { !chat.live.isBusy && !chat.isSending }
            XCTAssertTrue(settled, "Retry on the answer to \"\(prompt)\" left the demo working")
            XCTAssertNil(chat.errorMessage, "Retry on the answer to \"\(prompt)\" put an error on screen")
            XCTAssertGreaterThan(finishedAnswers(chat).count, answersBefore, "Retry produced no new answer")
            XCTAssertTrue(chat.entries.allSatisfy { !$0.isStreaming }, "an entry was left streaming")
        }
        await assertStillOffline(app, backend)
        await app.exitDemo()
    }

    /// Retry on the second answer asked for a hold because "the turn being retried ran commands that changed files on your machine". The demo's write is scripted: nothing ran and nothing changed, so Retry must not say so.
    func testRetryInTheDemoNeverSaysTheTurnChangedFiles() async throws {
        let (app, backend, chat) = try await playedDemo()
        let report = try XCTUnwrap(
            finishedAnswers(chat).last { chat.precedingUserEntry(before: $0.id)?.text == DemoScript.turnTwo.prompt },
            "no finished answer follows \"\(DemoScript.turnTwo.prompt)\""
        )
        let entries = chat.entries
        let end = try XCTUnwrap(entries.firstIndex { $0.id == report.id })
        let start = try XCTUnwrap(entries[..<end].lastIndex { $0.kind == .user })
        XCTAssertTrue(
            entries[start...end].contains { $0.tool?.name == "write_file" },
            "precondition: the second turn carries the scripted write, or this proves nothing"
        )
        for answer in finishedAnswers(chat) {
            XCTAssertFalse(chat.turnMutatedState(before: answer.id), "Retry on \"\(answer.text.prefix(40))\" would ask for a hold over files the demo never touched")
        }
        await assertStillOffline(app, backend)
        await app.exitDemo()
    }

    // MARK: Edit

    func testEditOnTheFinishedAnswerSendsTheEditedMessageAndSettles() async throws {
        let (app, backend, chat) = try await playedDemo()
        let answer = try XCTUnwrap(finishedAnswers(chat).last)
        let user = try XCTUnwrap(chat.precedingUserEntry(before: answer.id))
        XCTAssertTrue(chat.canEdit(entryID: user.id), "the Edit icon is drawn only when this is true, and the demo's answer shows it")

        XCTAssertTrue(chat.beginEditing(entryID: user.id), "Edit refused to load the message")
        XCTAssertEqual(chat.draft, user.text, "Edit must put the earlier message in the composer")
        let edited = "Make the report shorter."
        chat.draft = edited
        chat.sendTapped()

        let answered = await waitUntil(timeout: 30) { await backend.completedPrompts.contains(edited) }
        XCTAssertTrue(answered, "the edited message never reached the demo backend")
        let settled = await waitUntil(timeout: 10) { !chat.live.isBusy && !chat.isSending }
        XCTAssertTrue(settled, "the edited send left the demo working")
        XCTAssertNil(chat.editingEntryID, "edit mode outlived its send")
        XCTAssertNil(chat.errorMessage, "the edited send put an error on screen")
        XCTAssertTrue(chat.entries.contains { $0.kind == .user && $0.text == edited }, "the edited message is not in the transcript")
        XCTAssertTrue(
            chat.entries.contains { $0.kind == .assistant && $0.text == DemoScript.freeformReply },
            "an unscripted message gets the demo's canned reply"
        )
        await assertStillOffline(app, backend)
        await app.exitDemo()
    }

    func testCancellingAnEditLeavesTheDemoAsItWas() async throws {
        let (app, backend, chat) = try await playedDemo()
        let answer = try XCTUnwrap(finishedAnswers(chat).last)
        let user = try XCTUnwrap(chat.precedingUserEntry(before: answer.id))
        let entriesBefore = chat.entries.map(\.id)
        XCTAssertTrue(chat.beginEditing(entryID: user.id))
        chat.cancelEditing()
        XCTAssertNil(chat.editingEntryID)
        XCTAssertEqual(chat.draft, "")
        XCTAssertEqual(chat.entries.map(\.id), entriesBefore, "cancelling an edit changed the transcript")
        await assertStillOffline(app, backend)
        await app.exitDemo()
    }

    // MARK: Helpers

    private func playedDemo() async throws -> (AppModel, DemoBackend, ChatModel) {
        let app = AppModel()
        app.profiles = []
        await app.enterDemo(playbackSpeed: Self.testSpeed)
        let backend = try XCTUnwrap(app.demo, "entering the demo installed no demo backend")
        let played = await waitUntil(timeout: 30) { await backend.completedTurns >= DemoScript.autoplayTurnCount }
        XCTAssertTrue(played, "the scripted turns never finished")
        let chat = app.chat(for: app.demoThreadRoute)
        let settled = await waitUntil(timeout: 10) { !chat.live.isBusy && !chat.isSending }
        XCTAssertTrue(settled, "the demo never settled")
        return (app, backend, chat)
    }

    /// The answers whose action row is drawn: complete, not streaming (`ChatView.messageActions(for:)`).
    private func finishedAnswers(_ chat: ChatModel) -> [ChatEntry] {
        chat.entries.filter { $0.kind == .assistant && $0.status == "complete" && !$0.isStreaming }
    }

    private func assertStillOffline(_ app: AppModel, _ backend: DemoBackend, file: StaticString = #filePath, line: UInt = #line) async {
        XCTAssertNil(app.rest, "the demo built a REST client", file: file, line: line)
        XCTAssertNil(app.auth, "the demo built an authentication client", file: file, line: line)
        let sockets = await backend.socketCount
        XCTAssertEqual(sockets, 1, "the demo dialed \(sockets) sockets; a second one means something reconnected", file: file, line: line)
        XCTAssertEqual(NetworkTripwire.requests, [], "the demo made a URLSession request", file: file, line: line)
    }
}

/// Records, and refuses, every request made through `URLSession.shared` while registered.
private final class NetworkTripwire: URLProtocol {
    private static let lock = NSLock()
    private static var seen: [URL] = []

    static var requests: [URL] { lock.withLock { seen } }

    static func reset() { lock.withLock { seen = [] } }

    override class func canInit(with request: URLRequest) -> Bool {
        if let url = request.url { lock.withLock { seen.append(url) } }
        return true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
    }

    override func stopLoading() {}
}
