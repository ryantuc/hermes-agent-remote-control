import Foundation
import XCTest

@testable import HermesMobile

/// BUG-092 — the folder and worktree sheets turned a failed list call into an empty list.
///
/// Both sheets loaded with `(try? await …) ?? []`. A thrown RPC error (a backend restarting under the sheet, an expired session, a gateway error) became "nothing there": the worktree sheet then said "No repositories on the backend yet", a claim about the user's machine the client did not know to be true, and the folder picker's sections vanished without a word. `HostListLoad` is the one fetch both sheets now go through.
final class HostListLoadTests: XCTestCase {

    private struct GatewayRestarting: LocalizedError {
        var errorDescription: String? { "The backend is restarting." }
    }

    func testAFailedFetchSaysWhyInsteadOfReportingNothing() async {
        let load = await HostListLoad<String>.run(keeping: []) { throw GatewayRestarting() }

        XCTAssertNotNil(load.failure, "a thrown list call came back as an empty list with no failure, which the sheet draws as \"nothing on the backend\" (BUG-092)")
        XCTAssertTrue(load.failure?.contains("The backend is restarting.") == true, "the failure should carry the reason: \(String(describing: load.failure))")
    }

    func testAFailedRefreshKeepsTheRowsAlreadyShown() async {
        let load = await HostListLoad.run(keeping: ["X:\\work\\api", "X:\\work\\web"]) { throw GatewayRestarting() }

        XCTAssertEqual(load.rows, ["X:\\work\\api", "X:\\work\\web"], "a failed refresh emptied a list the backend had already answered")
    }

    func testASuccessfulFetchReplacesTheRowsAndCarriesNoFailure() async {
        let load = await HostListLoad.run(keeping: ["stale"]) { ["fresh"] }

        XCTAssertEqual(load.rows, ["fresh"])
        XCTAssertNil(load.failure)
    }

    func testAnEmptyAnswerIsAnEmptyListAndNotAFailure() async {
        let load = await HostListLoad.run(keeping: ["stale"]) { [String]() }

        XCTAssertEqual(load.rows, [], "the backend said there are none, which is the one case the empty claim is true")
        XCTAssertNil(load.failure)
    }

    func testCancellationIsNeitherAFailureNorAnEmptyList() async {
        // A sheet dismissed mid-load cancels its task; that is not something to report, and not an answer either.
        let load = await HostListLoad.run(keeping: ["kept"]) { throw CancellationError() }

        XCTAssertNil(load.failure)
        XCTAssertEqual(load.rows, ["kept"])
    }
}
