import HermesServeKit
import XCTest

@testable import HermesMobile

/// BUG-096's third path — the one the report did not find and the one a real
/// user is likeliest to hit.
///
/// `SettingsStore.set` opened `guard let rest = app.rest, let previous =
/// document else { return }` and returned before touching `writeFailures`. So
/// on a phone with no backend **both** editor sheets dismissed cleanly having
/// written nothing and recorded nothing — and the text editor's careful
/// `writeFailures[key] == nil` dismissal passed its check *precisely because*
/// the failure was never recorded. A refusal that leaves no trace is
/// indistinguishable from a success.
///
/// The two states are different and get different sentences: no backend at all
/// is something the reader can act on, and a document that has not arrived is
/// something they can only wait for.
@MainActor
final class SettingsWriteRefusalTests: XCTestCase {

    /// No `activate` has run, so `rest` is nil — the fresh-install state, and
    /// the state a phone is in inside the demo.
    func testAWriteWithNoBackendRecordsWhyItDidNotHappen() async {
        let app = AppModel()
        await app.settings.set("agent.max_turns", to: .number(40))

        XCTAssertEqual(
            app.settings.writeFailures["agent.max_turns"],
            SettingsStore.disconnectedWriteMessage,
            "a silent return is indistinguishable from a successful write"
        )
        XCTAssertNil(app.settings.document, "and nothing was invented locally either")
    }

    /// The sentence is the one the Settings root already shows over the same
    /// rows. One explanation met twice, not two explanations of one thing.
    func testTheRefusalUsesTheSentenceTheRootAlreadyShows() {
        XCTAssertEqual(SettingsStore.disconnectedWriteMessage, SettingsTree.agentDisconnectedFooter)
        XCTAssertEqual(SettingsStore.disconnectedWriteMessage, "Connect a backend to change these.")
    }

    /// A backend is selected but its document never loaded — the harness's REST
    /// points at a closed port, so `reload()` can only fail. A partial PUT is a
    /// deep merge against a document; without one there is nothing honest to
    /// send, and that is a different sentence.
    func testAWriteWithNoDocumentRecordsItsOwnReason() async {
        let harness = await AppHarness.make()
        XCTAssertNotNil(harness.app.rest, "the harness activates a profile")
        XCTAssertNil(harness.app.settings.document)

        await harness.app.settings.set("model", to: .string("x/y"))
        XCTAssertEqual(
            harness.app.settings.writeFailures["model"],
            SettingsStore.unloadedWriteMessage
        )
        await harness.tearDown()
    }
}
