import HermesServeKit
import XCTest

@testable import HermesMobile

/// The fallback editor writes the whole chain on every gesture, so two gestures in quick succession are two whole-list writes in flight. A refusal of the earlier one that answers after the later one succeeded must not put back the chain from before both, and a refusal must leave the store showing what the backend has rather than the local copy from before the write.
@MainActor
final class FallbackChainWriteOrderTests: XCTestCase {
    private let nous = FallbackEntry(provider: "nous", model: "hermes-4-405b")
    private let openrouter = FallbackEntry(provider: "openrouter", model: "google/gemini-3-flash-preview")
    private let anthropic = FallbackEntry(provider: "anthropic", model: "claude-haiku-4.5")

    /// A drag (slow, then refused) followed at once by a removal (quick, accepted): the removal is what the backend kept, so it is what the editor must be re-seeded from.
    func testARefusalAnsweringAfterALaterSuccessDoesNotRevertIt() async throws {
        let harness = await AppHarness.make()
        let store = harness.app.settings!
        let backend = FakeConfigBackend(chain: [nous, openrouter, anthropic])
        backend.held = [0]
        backend.refused = [0]
        store.injectDocumentForTesting(backend.stored)
        store.configBackendForTesting = { try await backend.handle($0, $1) }

        let reordered = [openrouter, nous, anthropic]
        let removed = [openrouter, nous]
        let first = Task { await store.setFallbackChain(reordered) }
        try await backend.waitForPuts(1)
        let second = Task { await store.setFallbackChain(removed) }
        try await Task.sleep(nanoseconds: 300_000_000)
        backend.releaseHeld()
        await first.value
        await second.value

        XCTAssertEqual(backend.chain, removed.map(\.pair), "the backend kept the later write")
        XCTAssertEqual(store.fallbackChain().map(\.pair), removed.map(\.pair), "the refused earlier write put back the chain from before both edits, and the next gesture would write it")
        XCTAssertNil(store.writeFailures[FallbackChain.key], "the list on screen is the one the backend holds")
        await harness.tearDown()
    }

    /// A write the backend applied before the connection failed: the local copy from before the write is no longer the truth, so the store reads the chain back instead of restoring it, and still says the write failed.
    func testARefusalShowsTheBackendsChainNotTheCopyFromBeforeTheWrite() async throws {
        let harness = await AppHarness.make()
        let store = harness.app.settings!
        let backend = FakeConfigBackend(chain: [nous, openrouter, anthropic])
        backend.appliedThenRefused = [0]
        store.injectDocumentForTesting(backend.stored)
        store.configBackendForTesting = { try await backend.handle($0, $1) }

        let removed = [nous, anthropic]
        await store.setFallbackChain(removed)

        XCTAssertNotNil(store.writeFailures[FallbackChain.key], "the failure is still shown")
        XCTAssertEqual(store.fallbackChain().map(\.pair), removed.map(\.pair), "the store restored its own pre-image instead of reading what the backend has")
        await harness.tearDown()
    }
}

/// `GET` and `PUT /api/config` against an in-memory document; PUTs are numbered from zero in arrival order.
@MainActor
private final class FakeConfigBackend {
    private(set) var stored: JSONValue
    private(set) var putCount = 0
    var held: Set<Int> = []
    var refused: Set<Int> = []
    var appliedThenRefused: Set<Int> = []
    private var waiting: [CheckedContinuation<Void, Never>] = []

    init(chain: [FallbackEntry]) {
        stored = .object([FallbackChain.key: FallbackChain.json(chain)])
    }

    var chain: [ModelPair] {
        FallbackChain.entries(from: ConfigDocument.value(at: FallbackChain.key, in: stored)).map(\.pair)
    }

    func handle(_ method: String, _ body: JSONValue?) async throws -> JSONValue {
        if method == "GET" { return stored }
        let index = putCount
        putCount += 1
        if held.contains(index) {
            await withCheckedContinuation { waiting.append($0) }
        }
        if refused.contains(index) { throw URLError(.timedOut) }
        if let body, let chain = ConfigDocument.value(at: FallbackChain.key, in: body) {
            stored = ConfigDocument.setting(stored, path: FallbackChain.key, to: chain)
        }
        if appliedThenRefused.contains(index) { throw URLError(.networkConnectionLost) }
        return .null
    }

    func releaseHeld() {
        let resumed = waiting
        waiting = []
        resumed.forEach { $0.resume() }
    }

    func waitForPuts(_ count: Int) async throws {
        var polls = 0
        while putCount < count, polls < 500 {
            try await Task.sleep(nanoseconds: 10_000_000)
            polls += 1
        }
        if putCount < count { throw NeverArrived() }
    }

    struct NeverArrived: Error {}
}
