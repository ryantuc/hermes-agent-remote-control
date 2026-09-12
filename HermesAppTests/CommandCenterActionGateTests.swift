import XCTest

@testable import HermesMobile

/// BUG-086 — Command Center's three maintenance actions did nothing, silently.
///
/// `restartGateway`, `runDiagnostics` and `runBackup` each opened `guard let
/// rest = app.rest else { return }` and wrote nothing on the way out, while
/// their siblings on the same screen — `loadSessions`, `loadUsage`,
/// `LogReaderSheet.load` — all name the state in their own guards. One screen,
/// two opposite house styles, and the three that stayed quiet are the ones
/// behind a hold-to-confirm gesture, where "nothing happened" is
/// indistinguishable from "the hold did not take".
///
/// The state this actually fires in is narrower than the report supposed:
/// `rest` and `client` are assigned when a profile is *activated* and nilled
/// only in `teardown()`, so a dropped socket never reaches the guard — a
/// configured-but-offline phone gets a real error back from the request. What
/// reaches it is a phone with **no profile at all**, which is roughly the state
/// an App Reviewer is in, on a screen `RootView` does not gate.
///
/// What is assertable without hosting the screen is the decision the three
/// guards now share. That the three call sites use it is a reading, and a hand
/// check on a device.
final class CommandCenterActionGateTests: XCTestCase {

    func testAnActionWithABackendIsNotBlocked() {
        XCTAssertNil(CommandCenterActionGate.blockedMessage(hasBackend: true))
    }

    func testAnActionWithNoBackendGetsWordsInsteadOfSilence() {
        XCTAssertEqual(
            CommandCenterActionGate.blockedMessage(hasBackend: false),
            "Not connected to a backend."
        )
    }

    /// Deliberately the sentence the loaders on the same screen already use.
    /// Two spellings of one state on one screen is how the reader learns that
    /// the words mean nothing.
    func testTheCopyMatchesTheSiblingLoadersOnTheSameScreen() {
        XCTAssertEqual(CommandCenterActionGate.noBackendMessage, "Not connected to a backend.")
    }

    /// BUG-109's third site, which lives on this screen: `compact` returns
    /// early for anything at or above a thousand, so only a large **negative**
    /// number ever reached `String(Int(value))` — narrower than the settings
    /// rows, the same trap. This call crashes on the unfixed tree.
    func testTheUsageCardsDoNotTrapOnAnAbsurdNegative() {
        XCTAssertFalse(SettingRowDescriptor.integerText(-1e30).isEmpty)
        XCTAssertEqual(SettingRowDescriptor.integerText(-42), "-42")
        XCTAssertEqual(SettingRowDescriptor.integerText(999), "999")
    }
}
