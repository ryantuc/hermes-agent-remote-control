#if DEBUG
import XCTest

@testable import HermesMobile

/// BUG-146 (`ColdOpenTrace.swift` `TraceState.startProbe`): `probing` was set once and never cleared, so once a traced screenshot route started the 10 ms main-queue probe it posted a hop every 10 ms for the life of the process, and every hop after the report was appended to `stalls` with no bound. A traced run now ends at its report: the probe stops and nothing more is recorded, and the next `startStallProbe` / `begin` pair starts a fresh run, which is how every call site in `RootView` uses it.
///
/// Debug-only, like the instrument. The probe runs on its own queue and records on the main queue, so these tests spin the main run loop rather than sleep it.
@MainActor
final class ColdOpenTraceProbeTests: XCTestCase {

    private func spinMainRunLoop(for seconds: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    /// The defect: after the report the probe is still running and the sample count keeps climbing.
    func testTheReportEndsTheRunAndStopsTheProbe() {
        let state = TraceState()
        state.startProbe()
        state.begin("probe-test")
        spinMainRunLoop(for: 0.2)
        XCTAssertGreaterThan(state.stallSampleCount, 0, "precondition: the probe recorded hops during the run")

        state.report("probe-test")
        // One hop can already be queued on the main queue when the report lands.
        spinMainRunLoop(for: 0.05)
        let afterReport = state.stallSampleCount
        XCTAssertFalse(state.probeIsRunning, "the probe must stop when its run is reported")

        spinMainRunLoop(for: 0.2)
        XCTAssertEqual(state.stallSampleCount, afterReport, "nothing may be recorded after the run has been reported")
    }

    /// Stopping must not break the next run: every traced route calls `startStallProbe` then `begin`.
    func testAProbeStartedAgainAfterAReportRecordsANewRun() {
        let state = TraceState()
        state.startProbe()
        state.begin("first")
        spinMainRunLoop(for: 0.1)
        state.report("first")
        spinMainRunLoop(for: 0.05)

        state.startProbe()
        state.begin("second")
        XCTAssertEqual(state.stallSampleCount, 0, "begin clears the previous run's samples")
        spinMainRunLoop(for: 0.2)
        XCTAssertTrue(state.probeIsRunning)
        XCTAssertGreaterThan(state.stallSampleCount, 0, "the second run is measured")
        state.report("second")
    }
}
#endif
