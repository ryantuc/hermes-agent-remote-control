import Foundation
import HermesServeKit
import XCTest

@testable import HermesMobile

/// BUG-143 — four stores that belong to one backend survived a switch to another and showed the previous machine's data under the new machine's name: the settings document, the Bots roster, the connection log and the hub's expanded projects.
///
/// Each test switches with `connect: false`, so the new backend never answers anything; what is on screen afterwards is exactly what the switch left behind, which is the state a user sees for as long as the new machine keeps failing.
@MainActor
final class BackendSwitchStateTests: XCTestCase {

    /// The machine being switched to. Nothing listens here; the switch never connects to it.
    private func laptop() -> BackendProfile {
        BackendProfile(name: "laptop", baseURLString: "http://127.0.0.1:10", authMode: .sessionToken)
    }

    // MARK: 1 — the settings document

    func testSwitchingBackendsForgetsThePreviousBackendsSettings() async throws {
        let harness = await AppHarness.make()
        try await harness.openSocket()
        harness.app.settings.injectDocumentForTesting(.object(["model": .string("desk-model")]))
        XCTAssertEqual(harness.app.settings.stringValue("model"), "desk-model", "precondition: the desk machine's document is loaded")

        let other = laptop()
        harness.app.addProfile(other)
        await harness.app.activate(profileID: other.id, connect: false)

        XCTAssertNil(
            harness.app.settings.document,
            "Settings is showing the desk machine's configuration under the laptop's name, and keeps doing so for as long as the laptop's config load fails"
        )
        XCTAssertNil(harness.app.settings.stringValue("model"))
        XCTAssertNil(harness.app.settings.loadError, "an error from the previous backend's load is not the new backend's error")

        harness.app.deleteProfile(id: other.id)
        await harness.tearDown()
    }

    // MARK: 2 — the Bots roster

    func testSwitchingBackendsEmptiesTheBotsRosterUntilTheNewBackendAnswers() async throws {
        let harness = await AppHarness.make()
        try await harness.openSocket()
        await harness.backend.stub("profiles.list") { _ in
            .object([
                "profiles": .array([
                    SwitchWire.row(name: "default", isDefault: true, uiMeta: SwitchWire.groupsMeta, hint: "desk-pin"),
                    SwitchWire.row(name: "scout", hasAvatar: true),
                ]),
                "bot_mode_protocol": .bool(true),
            ])
        }
        await harness.backend.stub("session.list") { _ in .object(["sessions": .array([])]) }
        await harness.app.bots.refresh()
        XCTAssertEqual(harness.app.bots.bots.map(\.profile).sorted(), ["default", "scout"], "precondition: the desk machine's roster is loaded")
        XCTAssertTrue(harness.app.bots.hasDesktopGroups, "precondition")
        XCTAssertEqual(harness.app.bots.serverPinHint("default"), "desk-pin", "precondition")

        let other = laptop()
        harness.app.addProfile(other)
        await harness.app.activate(profileID: other.id, connect: false)

        XCTAssertTrue(
            harness.app.bots.bots.isEmpty,
            "the desk machine's bots — their names, faces and previews — are listed under the laptop's name until the laptop answers, and forever if it never does"
        )
        XCTAssertFalse(harness.app.bots.hasLoadedOnce, "the roster must show its pre-first-load state for a backend it has not loaded yet")
        XCTAssertNil(harness.app.bots.botModeProtocol, "the Bot Mode capability was the desk machine's answer")
        XCTAssertFalse(harness.app.bots.hasDesktopGroups, "the groups footnote was the desk machine's")
        XCTAssertNil(harness.app.bots.serverPinHint("default"), "Desktop's pin hint names a session in the desk machine's state.db")

        harness.app.deleteProfile(id: other.id)
        await harness.tearDown()
    }

    // MARK: 3 — the connection log

    func testSwitchingBackendsMarksTheConnectionLog() async throws {
        let harness = await AppHarness.make()
        try await harness.openSocket()

        let other = laptop()
        harness.app.addProfile(other)
        await harness.app.activate(profileID: other.id, connect: false)

        let messages = await harness.app.log.entries().map(\.message)
        let deskMark = messages.firstIndex { $0.contains("Scripted") }
        let laptopMark = messages.firstIndex { $0.contains("laptop") }
        XCTAssertNotNil(
            laptopMark,
            "Diagnostics interleaves both machines' trails with nothing to say where one ends — the log must mark the switch by the backend's name"
        )
        if let deskMark, let laptopMark {
            XCTAssertLessThan(deskMark, laptopMark, "the desk machine's mark must come first, and the laptop's after it")
        } else {
            XCTFail("the first backend's trail is not marked either, so nothing tells a reader which machine the opening entries came from")
        }

        harness.app.deleteProfile(id: other.id)
        await harness.tearDown()
    }

    // MARK: 4 — the hub's expanded projects

    /// A project id is a path, and two machines can share one: the expansion set is per machine, like `LastProjectStore`'s remembered project.
    func testHubProjectExpansionIsRememberedPerBackend() async throws {
        let legacy = UserDefaults.standard.stringArray(forKey: ProjectGroupModel.expansionKey)
        UserDefaults.standard.removeObject(forKey: ProjectGroupModel.expansionKey)
        defer { restoreLegacyExpansion(legacy) }
        let path = "/Users/you/src/hermes"

        let harness = await AppHarness.make()
        let desk = ProjectGroupModel()
        desk.toggle(path, api: nil)
        XCTAssertTrue(desk.isExpanded(path), "precondition")

        let other = laptop()
        harness.app.addProfile(other)
        await harness.app.activate(profileID: other.id, connect: false)

        XCTAssertFalse(
            ProjectGroupModel().isExpanded(path),
            "the laptop's hub opened with the desk machine's groups expanded — the set is persisted under one key for every backend"
        )

        // A hub that outlives the switch must not keep the old machine's set either; `.task` reloads it on the next appearance.
        await desk.load(api: nil, force: false)
        XCTAssertFalse(desk.isExpanded(path), "a hub model built on the desk machine kept its expansion set after the switch")

        await harness.app.activate(profileID: harness.profileID, connect: false)
        XCTAssertTrue(ProjectGroupModel().isExpanded(path), "the desk machine's own expansion must still be remembered when the user switches back")

        harness.app.deleteProfile(id: other.id)
        await harness.tearDown()
    }

    /// The pre-fix set was written under one shared key; the first backend to read it adopts it, and no other backend inherits it after that.
    func testTheSharedExpansionSetIsAdoptedOnceAndNotInherited() async throws {
        let legacy = UserDefaults.standard.stringArray(forKey: ProjectGroupModel.expansionKey)
        UserDefaults.standard.set(["p-old"], forKey: ProjectGroupModel.expansionKey)
        defer { restoreLegacyExpansion(legacy) }

        let harness = await AppHarness.make()
        XCTAssertTrue(ProjectGroupModel().isExpanded("p-old"), "an upgrade must not collapse what the user had open")

        let other = laptop()
        harness.app.addProfile(other)
        await harness.app.activate(profileID: other.id, connect: false)
        XCTAssertFalse(ProjectGroupModel().isExpanded("p-old"), "the shared set was handed to a second backend as well")

        harness.app.deleteProfile(id: other.id)
        await harness.tearDown()
    }

    private func restoreLegacyExpansion(_ ids: [String]?) {
        if let ids {
            UserDefaults.standard.set(ids, forKey: ProjectGroupModel.expansionKey)
        } else {
            UserDefaults.standard.removeObject(forKey: ProjectGroupModel.expansionKey)
        }
    }
}

/// `profiles.list` rows for these tests; free-standing because `ScriptedBackend.stub` runs its closure off the main actor.
private enum SwitchWire {
    static let groupsMeta: JSONValue = .object([
        "hermes-bots-groups": .object(["rooms": .object(["standup": .object(["members": .array([])])])]),
    ])

    static func row(
        name: String,
        isDefault: Bool = false,
        uiMeta: JSONValue? = nil,
        hint: String? = nil,
        hasAvatar: Bool = false
    ) -> JSONValue {
        var meta: [String: JSONValue] = uiMeta?.objectValue ?? [:]
        if let hint { meta["hermes-bots"] = .object(["chat": .string(hint)]) }
        var row: [String: JSONValue] = [
            "name": .string(name),
            "path": .string("/home/\(name)"),
            "is_default": .bool(isDefault),
            "description": .string(""),
            "display_name": .string(""),
            "skill_count": .number(0),
            "has_avatar": .bool(hasAvatar),
            "ui_meta_revisions": .object([:]),
            "canonical_session": .null,
        ]
        if !meta.isEmpty { row["ui_meta"] = .object(meta) }
        return .object(row)
    }
}
