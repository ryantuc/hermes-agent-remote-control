import XCTest

@testable import HermesMobile

/// The chat header's subtitle has BUG-093's race. `ChatProjectSubtitleModel.resolve` wrote `subtitle` unconditionally after `try? await forCwd(cwd)` (`ChatChrome.swift`), under a `.task(id: subtitleResolveKey)` (`ChatView.swift:159`) that SwiftUI cancels when the cwd changes. `client.request` does not stop for cancellation, so the old cwd's answer still arrives, and if it arrives last it names the wrong project under the title. Same fix as BUG-093's chips: a generation ticket, and no write from a resolve that has been overtaken or cancelled.
@MainActor
final class ChatSubtitleResolveRaceTests: XCTestCase {

    /// Holds a resolve inside its request until the test lets it go.
    @MainActor
    private final class Gate {
        private var continuation: CheckedContinuation<Void, Never>?
        private(set) var isWaiting = false

        func wait() async {
            isWaiting = true
            await withCheckedContinuation { continuation = $0 }
        }

        func open() {
            continuation?.resume()
            continuation = nil
        }
    }

    func testAnOvertakenResolveThatLandsLastDoesNotOverwriteTheHeader() async {
        let model = ChatProjectSubtitleModel()
        let gate = Gate()
        let slow: ChatProjectSubtitleModel.ForCwd = { _ in
            await gate.wait()
            return (project: "old-project", branch: "main")
        }
        let fast: ChatProjectSubtitleModel.ForCwd = { _ in (project: "new-project", branch: "main") }

        let first = Task { await model.resolve(cwd: "/repo/old", isConnected: true, forCwd: slow) }
        let parked = await waitUntil { gate.isWaiting }
        XCTAssertTrue(parked, "precondition: the first resolve never reached its request, so this proves nothing")

        await model.resolve(cwd: "/repo/new", isConnected: true, forCwd: fast)
        XCTAssertEqual(model.subtitle, .project("new-project"))

        // What SwiftUI does when the task's id changes; the request inside does not stop for it.
        first.cancel()
        gate.open()
        await first.value
        XCTAssertEqual(model.subtitle, .project("new-project"), """
            the old cwd's late answer overwrote the header: it reads \(model.subtitle) for a chat in /repo/new
            """)
    }

    /// A disconnect takes a ticket too, so an answer from before it cannot land after it.
    func testAnAnswerThatLandsAfterADisconnectIsDropped() async {
        let model = ChatProjectSubtitleModel()
        let gate = Gate()
        let slow: ChatProjectSubtitleModel.ForCwd = { _ in
            await gate.wait()
            return (project: "hermesmobile", branch: "main")
        }
        let first = Task { await model.resolve(cwd: "/repo/hermes", isConnected: true, forCwd: slow) }
        let parked = await waitUntil { gate.isWaiting }
        XCTAssertTrue(parked)

        await model.resolve(cwd: "/repo/hermes", isConnected: false, forCwd: nil)
        XCTAssertEqual(model.subtitle, .unknown)
        gate.open()
        await first.value
        XCTAssertEqual(model.subtitle, .unknown, "an answer from before the disconnect landed after it")
    }

    func testTheLatestResolveStillWrites() async {
        let model = ChatProjectSubtitleModel()
        await model.resolve(cwd: "/repo/a", isConnected: true, forCwd: { _ in (project: "a", branch: "") })
        await model.resolve(cwd: "/repo/b", isConnected: true, forCwd: { _ in (project: "b", branch: "") })
        XCTAssertEqual(model.subtitle, .project("b"))
    }
}
