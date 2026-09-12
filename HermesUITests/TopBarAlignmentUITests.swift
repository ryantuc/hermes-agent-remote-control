import XCTest

/// BUG-121 residual — the top bar is misaligned while the cold-open spinner is up.
///
/// The report is that while the spinner is up the top bar is misaligned and the Back button is dead, and that Back later moves to where it belongs. So the claim is a move: Back and/or the title sit somewhere while `ProgressView("Loading conversation…")` is the transcript's only row, and somewhere else once the transcript paints.
///
/// That claim is a geometry claim, so this file measures geometry rather than photographing it. `-hermesScreenshotRoute transcript-loading` (added with this file) holds `ChatModel` in `isLoading` with an empty history and no backend, which is the exact predicate `ChatView` draws the spinner for; `transcript` and `transcript-long` are the existing painted fixtures. All three build their `ChatModel` the same way — `app.chat(for: ThreadRoute.new(UUID()))` — so `title` is `"New conversation"` in every one of them and no title-length difference can masquerade as a layout difference.
///
/// **The control matters as much as the comparison.** `testTheTwoPaintedRoutesAgreeAboutTheTopBar` reads two fixtures that differ in content by an order of magnitude and asserts the bar does not move between them. If that fails, this file's method is not stable enough to say anything about the loading route and the other test's result should be discarded rather than believed.
///
/// The principal item is `.accessibilityElement(children: .combine)`, so the two-line header arrives as **one** element whose frame is the union of the title and the subtitle — which is precisely the frame the doc comment at `ChatView.swift:414-421` makes a claim about ("puts the title's cap height near the top of Back and `⋯` rather than on the bar's centre line").
final class TopBarAlignmentUITests: XCTestCase {

    /// Everything the bar can move: its own frame, the leading control's, the trailing control's, and the principal item's.
    private struct BarReading {
        var route: String
        var bar: CGRect
        var leading: CGRect
        var trailing: CGRect
        var principal: CGRect
        var buttonCount: Int
        var principalLabel: String
        var tree: String

        var line: String {
            "D121BAR | route=\(route)"
            + " | bar=\(Self.f(bar))"
            + " | leading=\(Self.f(leading))"
            + " | trailing=\(Self.f(trailing))"
            + " | principal=\(Self.f(principal))"
            + " | buttons=\(buttonCount)"
            + " | principalLabel=\(principalLabel)"
        }

        static func f(_ r: CGRect) -> String {
            func n(_ v: CGFloat) -> String { String(format: "%.2f", Double(v)) }
            return "(\(n(r.minX)),\(n(r.minY)) \(n(r.width))x\(n(r.height)))"
        }
    }

    override func setUp() {
        continueAfterFailure = true
    }

    // MARK: Reading one route

    private func reading(for route: String, settled: (XCUIApplication) -> Bool) -> BarReading? {
        let app = XCUIApplication()
        app.launchArguments = ["-hermesScreenshotRoute", route]
        app.launch()

        let bar = app.navigationBars.firstMatch
        guard bar.waitForExistence(timeout: 60) else {
            XCTFail("no navigation bar on route \(route)")
            app.terminate()
            return nil
        }
        // The surface has to be the one this route names before anything is
        // read: a bar measured over the wrong content is not a control.
        var isSettled = false
        for _ in 0..<60 {
            if settled(app) { isSettled = true; break }
            quiesce(0.5)
        }
        if !isSettled {
            XCTFail("route \(route) never reached its expected content")
            print("D121BAR | route=\(route) | UNSETTLED TREE\n\(app.debugDescription)")
            app.terminate()
            return nil
        }
        // The first-paint ladder (BUG-016) settles after the content appears;
        // read the bar once it has stopped moving rather than in the frame the
        // content arrived in.
        quiesce(3.0)

        let buttons = bar.buttons.allElementsBoundByIndex
        let sorted = buttons.sorted { $0.frame.minX < $1.frame.minX }
        let principal = bar.staticTexts.allElementsBoundByIndex
            .max { $0.frame.height < $1.frame.height }

        let out = BarReading(
            route: route,
            bar: bar.frame,
            leading: sorted.first?.frame ?? .null,
            trailing: sorted.last?.frame ?? .null,
            principal: principal?.frame ?? .null,
            buttonCount: buttons.count,
            principalLabel: principal?.label ?? "-",
            tree: bar.debugDescription
        )
        print(out.line)
        print("D121BAR | route=\(route) | BAR TREE\n\(out.tree)")
        app.terminate()
        return out
    }

    /// A plain wait. `Thread.sleep` on the test thread is fine here — nothing
    /// in this file drives the app, it only reads it.
    private func quiesce(_ seconds: TimeInterval) {
        Thread.sleep(forTimeInterval: seconds)
    }

    private func loadingReading() -> BarReading? {
        reading(for: "transcript-loading") { app in
            app.descendants(matching: .any)
                .matching(NSPredicate(format: "label CONTAINS 'Loading conversation'"))
                .firstMatch.exists
        }
    }

    private func paintedReading() -> BarReading? {
        reading(for: "transcript") { app in
            app.staticTexts
                .matching(NSPredicate(format: "label CONTAINS 'Run the test suite'"))
                .firstMatch.exists
        }
    }

    private func longReading() -> BarReading? {
        reading(for: "transcript-long") { app in
            app.staticTexts
                .matching(NSPredicate(format: "label BEGINSWITH 'transcript row'"))
                .firstMatch.exists
        }
    }

    // MARK: The assertions

    private func assertSamePlace(
        _ a: BarReading,
        _ b: BarReading,
        tolerance: CGFloat = 0.5,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        func compare(_ name: String, _ l: CGRect, _ r: CGRect) {
            let deltas: [(String, CGFloat)] = [
                ("minX", l.minX - r.minX), ("minY", l.minY - r.minY),
                ("width", l.width - r.width), ("height", l.height - r.height),
            ]
            for (axis, delta) in deltas where abs(delta) > tolerance {
                XCTFail(
                    "\(name).\(axis) moved by \(String(format: "%.2f", Double(delta))) pt between "
                    + "\(a.route) \(BarReading.f(l)) and \(b.route) \(BarReading.f(r))",
                    file: file, line: line
                )
            }
        }
        compare("bar", a.bar, b.bar)
        compare("leading", a.leading, b.leading)
        compare("trailing", a.trailing, b.trailing)
        compare("principal", a.principal, b.principal)
        XCTAssertEqual(a.buttonCount, b.buttonCount, "the bar carries a different set of controls", file: file, line: line)
    }

    /// The control. Two painted fixtures whose transcripts differ by an order of magnitude must produce the same bar; if they do not, nothing else here is evidence.
    func testTheTwoPaintedRoutesAgreeAboutTheTopBar() {
        guard let short = paintedReading(), let long = longReading() else { return }
        assertSamePlace(short, long)
    }

    /// BUG-121's residual, stated as a measurement: the bar the spinner is under is the bar the transcript is under.
    func testTheTopBarSitsInTheSamePlaceWhileLoadingAsWhenPainted() {
        guard let loading = loadingReading(), let painted = paintedReading() else { return }
        assertSamePlace(loading, painted)
    }

    // MARK: The trajectory

    /// One sample of the whole bar, taken in one round trip.
    ///
    /// `snapshot()` returns the bar's entire subtree — every child's type, label and frame — for the cost of a single query, where reading four elements' `frame` costs four. That matters: a push animation lasts about a third of a second, and a sampler that manages three hertz is not sampling it. This form runs at ten to twenty.
    private static func pose(of bar: XCUIElement) -> String? {
        guard let snap = try? bar.snapshot() else { return nil }
        func walk(_ node: XCUIElementSnapshot, depth: Int) -> [String] {
            let name = node.label.isEmpty ? node.identifier : node.label
            let head = "\(depth):\(node.elementType.rawValue):\(name.prefix(24)):\(BarReading.f(node.frame))"
            return [head] + node.children.flatMap { walk($0, depth: depth + 1) }
        }
        return walk(snap, depth: 0).joined(separator: " ")
    }

    /// A recording, not an oracle, and the distinction is deliberate.
    ///
    /// The two tests above read the bar once it has settled, which answers "is the loading layout a different layout" and nothing else. The report is about a bar watched for three or four seconds, so the other candidate is a transitional pose — the destination bar laid out before its two-line principal item has been measured, or before `.toolbarRole(.editor)` has moved the title off the centre line, held on screen because the main thread is busy — and a settled reading cannot see either.
    ///
    /// It asserts nothing about the poses on purpose: XCUI samples through a snapshot, so a pose caught mid-animation is indistinguishable from a pose that is wrong, and an assertion over that would be a test that goes red for reasons unrelated to the code — which is BUG-132's disease, not a cure for it. Read the `D121TRAJ` lines. One distinct pose from first sight to settled means there was no transitional pose for a busy main thread to freeze; more than one means there was, and the frames say what moved.
    ///
    /// The painted route is recorded beside the loading one for the same reason the control test exists: every push has whatever poses a push has, and only a difference between the two is about the spinner.
    func testRecordTheTopBarsPosesOnTheWayIntoEachRoute() {
        for route in ["transcript-loading", "transcript"] {
            let app = XCUIApplication()
            app.launchArguments = ["-hermesScreenshotRoute", route]
            let launchedAt = Date()
            app.launch()

            let bar = app.navigationBars.firstMatch
            var seen: [String] = []
            var samples = 0
            let deadline = Date().addingTimeInterval(12)
            while Date() < deadline {
                samples += 1
                guard let pose = Self.pose(of: bar) else { continue }
                if seen.last != pose, !seen.contains(pose) {
                    let ms = Int(Date().timeIntervalSince(launchedAt) * 1000)
                    print("D121TRAJ | route=\(route) | +\(ms)ms | sample=\(samples) | pose=\(pose)")
                }
                if seen.last != pose { seen.append(pose) }
            }
            // Asked once, at the end, because asking it inside the loop would
            // halve the sampling rate — and the rate is the whole point.
            let content = route == "transcript-loading" ? "Loading conversation" : "Run the test suite"
            let drewItsContent = app.descendants(matching: .any)
                .matching(NSPredicate(format: "label CONTAINS %@", content))
                .firstMatch.exists
            print("D121TRAJ | route=\(route) | distinctPoses=\(Set(seen).count)"
                  + " | transitions=\(max(seen.count - 1, 0)) | samples=\(samples)"
                  + " | drewItsContent=\(drewItsContent)")
            XCTAssertTrue(bar.exists, "the navigation bar never appeared on \(route)")
            XCTAssertTrue(drewItsContent, "\(route) never drew the content this recording is about")
            app.terminate()
        }
    }
}
