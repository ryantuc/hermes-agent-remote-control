import Foundation
import HermesServeKit
import XCTest

@testable import HermesMobile

/// "/model" is the model drawer, as on Desktop: bare, it opens the drawer; with a name, it picks the model the backend offers by that name, or opens the drawer when it cannot tell which. Nothing is sent and no conversation is created. Before this, the client refused it as "not available in HARC", and from Home that refusal opened an empty new chat.
@MainActor
final class ModelCommandTests: XCTestCase {

    // MARK: Parsing

    func testTheRequestIsReadFromTheDraft() {
        XCTAssertEqual(ModelCommand.request(in: "/model"), .picker)
        XCTAssertEqual(ModelCommand.request(in: "/model   "), .picker)
        XCTAssertEqual(ModelCommand.request(in: "/model deepseek/deepseek-v4"), .select("deepseek/deepseek-v4"))
        XCTAssertEqual(ModelCommand.request(in: "/MODEL  Claude X "), .select("Claude X"))
        XCTAssertEqual(ModelCommand.request(in: "/model\nGPT-5"), .select("GPT-5"))
        XCTAssertNil(ModelCommand.request(in: "/models"))
        XCTAssertNil(ModelCommand.request(in: "/modelx gpt"))
        XCTAssertNil(ModelCommand.request(in: "switch /model"))
        XCTAssertNil(ModelCommand.request(in: "/usage"))
    }

    // MARK: Matching

    private static let catalogue = ModelCatalogue(json: .object(["providers": .array([
        .object([
            "slug": .string("nous"), "name": .string("Nous Portal"),
            "is_current": .bool(true), "authenticated": .bool(true),
            "models": .array([
                .object(["slug": .string("gpt-5"), "name": .string("GPT-5")]),
                .object(["slug": .string("claude-x"), "name": .string("Claude X")]),
            ]),
        ]),
        .object([
            "slug": .string("openrouter"), "name": .string("OpenRouter"),
            "authenticated": .bool(true),
            "models": .array([
                .object(["slug": .string("gpt-5"), "name": .string("GPT-5")]),
                .object(["slug": .string("deepseek/deepseek-v4"), "name": .string("DeepSeek V4")]),
                .object(["slug": .string("deepseek/deepseek-v4-flash"), "name": .string("DeepSeek V4 Flash")]),
            ]),
        ]),
        .object([
            "slug": .string("locked"), "name": .string("Locked"),
            "authenticated": .bool(false),
            "models": .array([.object(["slug": .string("secret-model"), "name": .string("Secret")])]),
        ]),
    ])]))

    func testAnExactSlugPicksThatModelAndItsProvider() {
        XCTAssertEqual(ModelCommand.match("deepseek/deepseek-v4", in: Self.catalogue),
                       ModelCommand.Choice(slug: "deepseek/deepseek-v4", providerSlug: "openrouter"))
        XCTAssertEqual(ModelCommand.match("DEEPSEEK/DEEPSEEK-V4-FLASH", in: Self.catalogue)?.slug, "deepseek/deepseek-v4-flash")
    }

    func testAModelOnTwoProvidersIsTheCurrentProvidersOne() {
        XCTAssertEqual(ModelCommand.match("gpt-5", in: Self.catalogue),
                       ModelCommand.Choice(slug: "gpt-5", providerSlug: "nous"))
    }

    func testAnExactNameOrTheOnlyContainingNamePicksTheModel() {
        XCTAssertEqual(ModelCommand.match("claude x", in: Self.catalogue)?.slug, "claude-x")
        XCTAssertEqual(ModelCommand.match("flash", in: Self.catalogue)?.slug, "deepseek/deepseek-v4-flash")
        XCTAssertEqual(ModelCommand.match("claude", in: Self.catalogue)?.slug, "claude-x")
    }

    func testAnAmbiguousOrUnknownNameOrADisconnectedProviderPicksNothing() {
        XCTAssertNil(ModelCommand.match("deepseek", in: Self.catalogue), "two DeepSeek models: the drawer decides, not the client")
        XCTAssertNil(ModelCommand.match("nothing-like-it", in: Self.catalogue))
        XCTAssertNil(ModelCommand.match("secret-model", in: Self.catalogue), "a provider that is not connected cannot serve the model")
        XCTAssertNil(ModelCommand.match("   ", in: Self.catalogue))
    }

    // MARK: Routing and running

    private func type(_ text: String, into chat: ChatModel, pasted: Bool = false) {
        chat.draft = text
        chat.slashCompletion.update(
            text: text, selection: NSRange(location: text.utf16.count, length: 0),
            isComposing: false, isPaste: pasted, isExternal: false,
            scope: chat.slashCompletionScope, api: chat.slashCommandAPI
        )
    }

    private func stubCatalogue(_ harness: AppHarness) async {
        await harness.backend.stub("model.options") { _ in .object(["providers": .array([
            .object([
                "slug": .string("openrouter"), "name": .string("OpenRouter"),
                "is_current": .bool(true), "authenticated": .bool(true),
                "models": .array([
                    .object(["slug": .string("deepseek/deepseek-v4"), "name": .string("DeepSeek V4")]),
                    .object(["slug": .string("anthropic/claude-x"), "name": .string("Claude X")]),
                ]),
            ]),
        ])]) }
    }

    /// Home's draft: no stored session and no runtime session.
    private func homeDraft() async throws -> (AppHarness, ChatModel) {
        let harness = await AppHarness.make()
        try await harness.openSocket()
        await stubCatalogue(harness)
        let chat = ChatModel(app: harness.app, summary: nil)
        XCTAssertTrue(chat.isDraft)
        return (harness, chat)
    }

    private func run(_ chat: ChatModel, app: AppModel) async -> (ModelCommand.Outcome?, Bool) {
        guard let request = ModelCommand.pending(in: chat) else { return (nil, false) }
        let typed = chat.draft
        let outcome = await ModelCommand.perform(request, on: chat, app: app)
        var opened = false
        ModelCommand.apply(outcome, typed: typed, to: chat) { opened = true }
        return (outcome, opened)
    }

    private func assertNothingWasSentOrCreated(_ harness: AppHarness, _ chat: ChatModel, file: StaticString = #filePath, line: UInt = #line) async {
        for method in ["session.create", "prompt.submit", "slash.exec", "command.dispatch"] {
            let count = await harness.backend.callCount(method)
            XCTAssertEqual(count, 0, "/model reached \(method)", file: file, line: line)
        }
        XCTAssertFalse(chat.hasStartedSubmission, "Home would have left for a new conversation", file: file, line: line)
        XCTAssertTrue(chat.isDraft, file: file, line: line)
    }

    func testBareModelFromHomeOpensTheDrawerAndSendsNothing() async throws {
        let (harness, chat) = try await homeDraft()
        type("/model", into: chat)
        XCTAssertEqual(ModelCommand.pending(in: chat), .picker)

        let (outcome, opened) = await run(chat, app: harness.app)

        XCTAssertEqual(outcome, .openPicker)
        XCTAssertTrue(opened, "the drawer did not open")
        XCTAssertEqual(chat.draft, "", "the command stayed in the composer after it ran")
        XCTAssertNil(chat.errorMessage)
        await assertNothingWasSentOrCreated(harness, chat)
        await harness.tearDown()
    }

    func testModelWithAnOfferedSlugFromHomePicksItWithoutOpeningAnything() async throws {
        let (harness, chat) = try await homeDraft()
        type("/model deepseek/deepseek-v4", into: chat)

        let (outcome, opened) = await run(chat, app: harness.app)

        XCTAssertEqual(outcome, .selected(slug: "deepseek/deepseek-v4"))
        XCTAssertFalse(opened)
        XCTAssertEqual(chat.draftModelSlug, "deepseek/deepseek-v4", "the choice must ride session.create, as the drawer's does")
        XCTAssertEqual(chat.draftProviderSlug, "openrouter")
        XCTAssertEqual(chat.draft, "")
        await assertNothingWasSentOrCreated(harness, chat)
        let writes = await harness.backend.callCount("config.set")
        XCTAssertEqual(writes, 0, "a draft has no session, and a session-less config.set changes the backend's global default")
        await harness.tearDown()
    }

    func testModelWithNoMatchOpensTheDrawer() async throws {
        let (harness, chat) = try await homeDraft()
        type("/model nothing like it", into: chat)

        let (outcome, opened) = await run(chat, app: harness.app)

        XCTAssertEqual(outcome, .openPicker)
        XCTAssertTrue(opened)
        XCTAssertNil(chat.draftModelSlug)
        await assertNothingWasSentOrCreated(harness, chat)
        await harness.tearDown()
    }

    func testAPastedModelIsWordsAndNotTheCommand() async throws {
        let (harness, chat) = try await homeDraft()
        type("/model is the best one", into: chat, pasted: true)
        XCTAssertNil(ModelCommand.pending(in: chat))
        await harness.tearDown()
    }

    private func liveChat() async throws -> (AppHarness, ChatModel) {
        let harness = await AppHarness.make()
        try await harness.openSocket()
        await stubCatalogue(harness)
        let chat = harness.chat(storedID: "20261009_model_command")
        await chat.open()
        let bound = await waitUntil { chat.runtimeSessionID != nil }
        XCTAssertTrue(bound)
        return (harness, chat)
    }

    func testModelWithAnOfferedNameInAConversationWritesItToThatSession() async throws {
        let (harness, chat) = try await liveChat()
        await harness.backend.stub("config.set") { call in
            .object(["key": .string("model"), "value": call.params["value"] ?? .null])
        }
        type("/model Claude X", into: chat)

        let (outcome, opened) = await run(chat, app: harness.app)

        XCTAssertEqual(outcome, .selected(slug: "anthropic/claude-x"))
        XCTAssertFalse(opened)
        let writes = await harness.backend.calls(to: "config.set")
        XCTAssertEqual(writes.count, 1)
        XCTAssertEqual(writes.first?.params["key"]?.stringValue, "model")
        XCTAssertEqual(writes.first?.params["value"]?.stringValue, "anthropic/claude-x")
        XCTAssertEqual(writes.first?.params["session_id"]?.stringValue, chat.runtimeSessionID, "without the session the write lands on the global default")
        let sent = await harness.backend.callCount("prompt.submit")
        XCTAssertEqual(sent, 0)
        XCTAssertEqual(chat.draft, "")
        await harness.tearDown()
    }

    func testAnExpensiveModelOpensTheDrawerWhichAsksFirst() async throws {
        let (harness, chat) = try await liveChat()
        await harness.backend.stub("config.set") { _ in
            .object(["confirm_required": .bool(true), "confirm_message": .string("This model is expensive.")])
        }
        type("/model deepseek/deepseek-v4", into: chat)

        let (outcome, opened) = await run(chat, app: harness.app)

        XCTAssertEqual(outcome, .openPicker)
        XCTAssertTrue(opened)
        await harness.tearDown()
    }

    func testAFailedWriteKeepsTheDraftWithTheReason() async throws {
        let (harness, chat) = try await liveChat()
        await harness.backend.failRPC("config.set", code: 5000, message: "model switch failed")
        type("/model deepseek/deepseek-v4", into: chat)

        let (outcome, opened) = await run(chat, app: harness.app)

        guard case .failed = outcome else { return XCTFail("expected a failure, got \(String(describing: outcome))") }
        XCTAssertFalse(opened)
        XCTAssertEqual(chat.draft, "/model deepseek/deepseek-v4")
        XCTAssertNotNil(chat.errorMessage)
        await harness.tearDown()
    }
}
