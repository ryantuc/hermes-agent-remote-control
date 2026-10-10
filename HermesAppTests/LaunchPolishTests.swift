import UIKit
import XCTest

@testable import HermesMobile

/// The launch polish pass: what a first-time user and an App Reviewer read on the first run, the backend editor, Command Center with no backend, the Live Activities screen and the tool cards.
@MainActor
final class LaunchPolishTests: XCTestCase {

    // MARK: Tool cards

    private let families: [ToolCardView.Family] = [.terminal, .file, .edit, .search, .browser, .todo, .other]

    /// The todo tool's emoji drew as a missing-glyph box in the monospaced header font, on every todo card in the store frames.
    func testEveryToolFamilyDrawsASystemSymbolThatExists() {
        for family in families {
            XCTAssertNotNil(UIImage(systemName: family.symbol), "\(family) names \(family.symbol), which is not an SF Symbol on this OS")
        }
        XCTAssertEqual(ToolCardView.Family(toolName: "todo").symbol, "checklist")
        XCTAssertEqual(ToolCardView.Family(toolName: "todo_list").symbol, "checklist")
        XCTAssertEqual(Set(families.map(\.symbol)).count, families.count, "two families sharing a mark cannot be told apart")
    }

    /// A group whose header still reads "running" carried the danger stroke as soon as one finished member had failed.
    func testAToolGroupTurnsDangerOnlyOnceItHasSettled() {
        XCTAssertEqual(ToolGroupCard.tone(anyRunning: true, anyFailed: true), .neutral)
        XCTAssertEqual(ToolGroupCard.tone(anyRunning: false, anyFailed: true), .danger)
        XCTAssertEqual(ToolGroupCard.tone(anyRunning: true, anyFailed: false), .neutral)
        XCTAssertEqual(ToolGroupCard.tone(anyRunning: false, anyFailed: false), .neutral)
    }

    // MARK: Command Center

    /// With no backend, Command Center drew a red "Not connected to a backend." over "Nothing is running.", reachable from first run through the gear.
    func testCommandCenterWithNoBackendSaysNotConnectedOnEveryTab() {
        for tab in ["Sessions", "System", "Usage", "Maintenance"] {
            let message = CommandCenterAvailability.unavailableMessage(tab: tab, hasSessionAPI: false, hasREST: false, isDemo: false)
            XCTAssertNotNil(message, "\(tab) has nothing to load from and must say so")
            XCTAssertTrue(message?.hasPrefix("Connect a backend") == true, "\(tab): \(message ?? "")")
        }
        XCTAssertEqual(CommandCenterAvailability.title, "Not connected")
    }

    func testCommandCenterWithABackendDrawsEveryTab() {
        for tab in ["Sessions", "System", "Usage", "Maintenance"] {
            XCTAssertNil(CommandCenterAvailability.unavailableMessage(tab: tab, hasSessionAPI: true, hasREST: true, isDemo: false), tab)
        }
    }

    /// The demo has a gateway socket and no REST, so its Sessions tab works and the other three would only have shown the red no-backend line.
    func testTheDemoKeepsSessionsAndExplainsTheRest() {
        XCTAssertNil(CommandCenterAvailability.unavailableMessage(tab: "Sessions", hasSessionAPI: true, hasREST: false, isDemo: true))
        for tab in ["System", "Usage", "Maintenance"] {
            let message = CommandCenterAvailability.unavailableMessage(tab: tab, hasSessionAPI: true, hasREST: false, isDemo: true)
            XCTAssertTrue(message?.contains("demo") == true, "\(tab): \(message ?? "nil")")
        }
    }

    /// After a failed load, Try again showed "Nothing is running" for the whole request and then the same error again; the first open did the same before its first answer.
    func testALoadInFlightShowsProgressRatherThanNothingRunning() {
        typealias State = CommandCenterAvailability.SessionsEmptyState
        XCTAssertEqual(CommandCenterAvailability.sessionsEmptyState(hasSessionAPI: true, isLoading: true, error: "timed out"), State.loading)
        XCTAssertEqual(CommandCenterAvailability.sessionsEmptyState(hasSessionAPI: true, isLoading: true, error: nil), State.loading)
        XCTAssertEqual(CommandCenterAvailability.sessionsEmptyState(hasSessionAPI: true, isLoading: false, error: "timed out"), State.failed("timed out"))
        XCTAssertEqual(CommandCenterAvailability.sessionsEmptyState(hasSessionAPI: true, isLoading: false, error: nil), State.nothingRunning)
        XCTAssertEqual(
            CommandCenterAvailability.sessionsEmptyState(hasSessionAPI: false, isLoading: true, error: "Not connected to a backend."),
            State.notConnected("Connect a backend to see what is running."),
            "with no backend there is nothing to wait for"
        )
    }

    // MARK: Bots

    /// The demo answers the profiles call with an empty list, and the Bots root then filled the screen with an empty state about "this backend".
    func testTheDemosEmptyRosterTalksAboutTheDemoNotABackend() {
        let demo = BotRosterEmptyCopy(isDemo: true)
        for text in [demo.title, demo.message, demo.line] {
            XCTAssertFalse(text.contains("This backend"), text)
            XCTAssertFalse(text.contains("profiles yet"), text)
        }
        XCTAssertTrue(demo.message.contains("connect your own Hermes Agent"))
        XCTAssertEqual(BotRosterEmptyCopy(isDemo: false).title, "No bots yet")
    }

    // MARK: Backend editor

    /// The editor's help read as developer documentation: an environment variable, a header name, protocol frames.
    func testTheBackendEditorHelpHasNoDeveloperWords() {
        let banned = ["HERMES_", "Authorization", "Bearer", "loopback", "gateway.ready", "WebSocket", "--host", "cookie", "provider-minted", "replayed", "config.yaml"]
        for line in BackendEditorCopy.all {
            for word in banned {
                XCTAssertFalse(line.localizedCaseInsensitiveContains(word), "\"\(word)\" in: \(line)")
            }
        }
        XCTAssertFalse(BackendAuthMethod.allCases.map(\.title).contains { $0.localizedCaseInsensitiveContains("bearer") })
    }

    func testTheAddressPlaceholderIsAnExampleAddress() throws {
        let url = try XCTUnwrap(URL(string: BackendEditorCopy.addressPlaceholder))
        XCTAssertEqual(url.scheme, "http")
        XCTAssertEqual(url.port, 9119, "the port hermes serve listens on by default")
    }

    // MARK: First run and the demo

    /// First run never said that Hermes Agent must already be running somewhere the phone can reach, or how to get it.
    func testFirstRunSaysWhatTheAppNeedsAndWhereToGetIt() throws {
        let line = HomeChrome.firstRunRequirement
        XCTAssertTrue(line.contains("Hermes Agent"))
        XCTAssertTrue(line.contains("address"))
        let url = try XCTUnwrap(HomeChrome.getHermesAgentURL)
        XCTAssertEqual(url.scheme, "https")
        XCTAssertEqual(url.host, "github.com")
        XCTAssertEqual(HomeChrome.getHermesAgentTitle, "Get Hermes Agent")
    }

    func testTheHubNamesTheDemoWithoutAVersionOrAConnection() {
        XCTAssertFalse(HubBackendCopy.demoSubtitle.contains("Connected"))
        XCTAssertFalse(HubBackendCopy.demoSubtitle.contains("vdemo"))
    }

    // MARK: Notifications

    /// iOS Settings lists the app as HARC (`CFBundleDisplayName`), so a pointer to "iOS Settings → Hermes" sent people to a row that does not exist.
    func testTheLiveActivitiesRepairLineNamesTheAppAsIOSListsIt() {
        XCTAssertTrue(NotificationSettingsCopy.systemOff.contains("iOS Settings → HARC → Live Activities"))
        XCTAssertFalse(NotificationSettingsCopy.systemOff.contains("→ Hermes"))
        XCTAssertFalse(NotificationSettingsCopy.notifications.contains("Hermes is running"), "the app that must be running is HARC")
    }

    func testTheLockScreenRosterCountDoesNotReadLikeAQuota() {
        XCTAssertEqual(NotificationSettingsCopy.rosterValue(active: 0, cap: 2), "None")
        XCTAssertEqual(NotificationSettingsCopy.rosterValue(active: 1, cap: 2), "1 of 2")
    }

    // MARK: Settings rhythm

    /// Sibling settings screens started their first content at three different heights.
    func testSettingsScreensShareOneTopInset() {
        XCTAssertEqual(Space.settingsTop, Space.s6)
    }
}
