import Foundation
import HermesServeKit
import XCTest

@testable import HermesMobile

/// A rename, pin, archive or delete the backend refuses must leave the list as the backend has it and say why. The harness's REST host refuses every connection, so every write here fails, and so does the refresh that follows it.
final class SessionEditRefusalTests: XCTestCase {

    @MainActor
    func testARefusedDeleteBringsTheRowBackWhereItWasEvenWhenTheListCannotBeReread() async throws {
        let harness = await AppHarness.make()
        harness.app.seedDemoThreads()
        let before = harness.app.threads.map(\.id)
        let target = try XCTUnwrap(harness.app.threads.first { $0.id == "d3" })

        await harness.app.deleteThread(target)

        XCTAssertEqual(harness.app.threads.map(\.id), before, "the backend still has the conversation, so the list must too, in the same place")
        await harness.tearDown()
    }
}
