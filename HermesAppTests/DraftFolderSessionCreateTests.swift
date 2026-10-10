import Foundation
import HermesServeKit
import XCTest

@testable import HermesMobile

/// A new chat started in a folder picked on the phone, under a
/// named Hermes profile, must run in that folder. On current upstream a named profile's
/// configured folder beats `session.create`'s `cwd` unless `cwd_explicit` is true
/// (`tui_gateway/session_workdir.py:43-45`), while an older backend
/// rejects the flag with 4000. Both backends must start the chat in the picked folder.
@MainActor
final class DraftFolderSessionCreateTests: XCTestCase {

    private static let folder = "/Users/you/projects/alpha"

    /// A Home draft under the named profile `writer` with a folder already on it — the state
    /// `ChatModel.applyCwd` (a pick) and `HomeView.seedDraftProject` (the remembered pick) leave.
    private func namedProfileDraft(_ harness: AppHarness) throws -> ChatModel {
        let index = try XCTUnwrap(harness.app.profiles.firstIndex { $0.id == harness.profileID })
        harness.app.profiles[index].hermesProfile = "writer"
        let chat = ChatModel(app: harness.app, summary: nil)
        chat.draftCwd = Self.folder
        return chat
    }

    func testAPickedFolderRidesTheCreateAsExplicit() async throws {
        let harness = await AppHarness.make()
        try await harness.openSocket()
        let chat = try namedProfileDraft(harness)

        chat.draft = "list the files here"
        chat.sendTapped()
        let submitted = await waitUntil { await harness.backend.callCount("prompt.submit") == 1 }
        XCTAssertTrue(submitted, "the send never reached prompt.submit: \(chat.errorMessage ?? "no error")")

        let creates = await harness.backend.calls(to: "session.create")
        XCTAssertEqual(creates.count, 1)
        let params = creates.first?.params
        XCTAssertEqual(params?["profile"]?.coercedString, "writer")
        XCTAssertEqual(params?["cwd"]?.coercedString, Self.folder)
        XCTAssertEqual(
            params?["cwd_explicit"]?.coercedBool, true,
            "without the flag a current backend runs the chat in writer's configured folder instead"
        )

        await harness.tearDown()
    }

    func testABackendThatRejectsTheFlagStillStartsTheChatInThePickedFolder() async throws {
        let harness = await AppHarness.make()
        try await harness.openSocket()
        let chat = try namedProfileDraft(harness)
        // An older backend's exact answer (`contracts/registry.py:100-115`, `rpc_dispatch.py:27-31`).
        await harness.backend.failNextRPC(
            "session.create",
            code: 4000,
            message: "invalid params for session.create: cwd_explicit: Extra inputs are not permitted — the client "
                + "and the Hermes backend are out of sync (different versions); run `hermes update` and restart both"
        )

        chat.draft = "list the files here"
        chat.sendTapped()
        let submitted = await waitUntil { await harness.backend.callCount("prompt.submit") == 1 }
        XCTAssertTrue(submitted, "the send never reached prompt.submit: \(chat.errorMessage ?? "no error")")
        XCTAssertNotNil(chat.runtimeSessionID, "the draft never bound a session")

        let creates = await harness.backend.calls(to: "session.create")
        XCTAssertEqual(creates.count, 2, "one rejected create, one retry without the flag")
        XCTAssertEqual(creates.last?.params["cwd"]?.coercedString, Self.folder, "the retry keeps the folder")
        XCTAssertNil(creates.last?.params["cwd_explicit"])

        await harness.tearDown()
    }
}
