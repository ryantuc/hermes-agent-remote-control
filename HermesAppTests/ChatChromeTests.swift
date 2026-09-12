import HermesServeKit
import XCTest

@testable import HermesMobile

/// **FEAT-024 — the conversation screen's glass chrome.**
///
/// Three of the four visible changes are rules rather than pixels, and rules
/// are assertable. The fourth — whether the frost actually looks like glass —
/// is a photograph, and is verified on the simulator instead.
///
/// Asserted on the derivations rather than by hosting `ChatView`, deliberately:
/// hosting it needs an `AppModel`, a socket and a simulator to prove things
/// that are a dozen lines of arithmetic, and a Box-hosted view test can pass
/// vacuously.
final class ChatChromeTests: XCTestCase {

    // MARK: 1 — what the ⋯ overflow offers

    func testANormalThreadIsOfferedAllThreeActionsInReportOrder() {
        XCTAssertEqual(
            ChatChrome.overflowActions(isBotThread: false, isDraft: false),
            [.details, .rename, .project],
            """
            the ⋯ overflow for an ordinary conversation is not info → pencil → folder. \
            FEAT-024 §2 fixes both the set and the order
            """
        )
    }

    /// The one rule in this feature that is a data-integrity rule and not a
    /// look: a bot conversation's title is the registry key the Bot Chat
    /// resolver resolves by.
    func testABotThreadIsNeverOfferedRename() {
        let actions = ChatChrome.overflowActions(isBotThread: true, isDraft: false)
        XCTAssertFalse(actions.contains(.rename), """
            a bot thread was offered Rename. A bot conversation's title IS the registry key the \
            Bot Chat resolver looks it up by — renaming it from the header strands the \
            conversation exactly the way a casual hub rename would
            """)
        XCTAssertEqual(actions, [.details, .project], """
            omitting Rename must not disturb the other two, or their order
            """)
    }

    /// A draft has no stored session, so `AppModel.renameThread` has nothing to
    /// address. An action whose only possible outcome is silence is worse than
    /// no action.
    func testADraftIsNotOfferedRename() {
        XCTAssertEqual(
            ChatChrome.overflowActions(isBotThread: false, isDraft: true),
            [.details, .project]
        )
    }

    func testABotDraftIsAlsoNotOfferedRename() {
        XCTAssertEqual(
            ChatChrome.overflowActions(isBotThread: true, isDraft: true),
            [.details, .project]
        )
    }

    /// Icon-only means the label is the only text a screen reader has, so an
    /// empty one is not a cosmetic miss.
    func testEveryActionCarriesAnIconAndASpokenLabel() {
        for action in ChatOverflowAction.allCases {
            XCTAssertFalse(action.systemImage.isEmpty, "\(action) has no SF Symbol")
            XCTAssertFalse(action.accessibilityLabel.isEmpty, "\(action) has no accessibility label")
        }
        XCTAssertEqual(ChatOverflowAction.details.systemImage, "info.circle")
        XCTAssertEqual(ChatOverflowAction.rename.systemImage, "pencil")
        XCTAssertEqual(ChatOverflowAction.project.systemImage, "folder")
    }

    // MARK: 2 — which glass

    /// The deployment target is iOS 17.0 and `glassEffect` is iOS 26 only, so
    /// the fallback is what most of the field gets. It has to be a real blur,
    /// not a solid fill, or the feature reads as "nothing changed" there.
    func testBelowIOS26TheChromeFallsBackToUltraThinMaterial() {
        for major in [17, 18, 19, 25] {
            XCTAssertEqual(
                ChatChromeMaterial.resolve(osMajorVersion: major),
                .ultraThinMaterial,
                "iOS \(major) resolved to Liquid Glass, which does not exist there"
            )
        }
    }

    func testIOS26AndAboveUseLiquidGlass() {
        for major in [26, 27, 30] {
            XCTAssertEqual(
                ChatChromeMaterial.resolve(osMajorVersion: major),
                .liquidGlass,
                "iOS \(major) fell back to a material when the system paints glass itself"
            )
        }
    }

    func testTheGlassThresholdIsTwentySix() {
        XCTAssertEqual(ChatChromeMaterial.liquidGlassMinimumMajorVersion, 26)
    }

    // MARK: 3 — the project subtitle

    func testACwdInsideAProjectShowsThatProjectsName() {
        XCTAssertEqual(
            ChatProjectSubtitle.derive(
                cwd: "/Users/you/Developer/myproject",
                projectName: "hermesmobile",
                didResolve: true,
                isConnected: true
            ),
            .project("hermesmobile")
        )
    }

    /// `projects.for_cwd` naming no project is the "outside every project"
    /// answer. The words are `WorkspaceChips`' own so Home and Chat cannot
    /// disagree about the same directory.
    func testACwdOutsideEveryProjectShowsItsFolderLeaf() {
        XCTAssertEqual(
            ChatProjectSubtitle.derive(
                cwd: "/Users/you/Desktop/scratch",
                projectName: "",
                didResolve: true,
                isConnected: true
            ),
            .folder("scratch")
        )
    }

    /// Before the answer arrives there is no honest claim to make. An em dash,
    /// which is what the chip already renders, and never a blank — the header
    /// must not change height when the answer lands.
    func testAnUnresolvedCwdShowsAnEmDashRatherThanClaimingNoProject() {
        let subtitle = ChatProjectSubtitle.derive(
            cwd: "/Users/you/Desktop/scratch",
            projectName: "",
            didResolve: false,
            isConnected: true
        )
        XCTAssertEqual(subtitle, .unknown)
        XCTAssertEqual(subtitle.text, "—")
    }

    func testNoWorkingDirectoryOnAnOpenSocketIsNoProject() {
        let subtitle = ChatProjectSubtitle.derive(
            cwd: "", projectName: "", didResolve: true, isConnected: true
        )
        XCTAssertEqual(subtitle, .noProject)
        XCTAssertEqual(subtitle.text, "No project")
    }

    func testNoWorkingDirectoryWithNoSocketIsUnknownNotNoProject() {
        XCTAssertEqual(
            ChatProjectSubtitle.derive(
                cwd: "", projectName: "", didResolve: false, isConnected: false
            ),
            .unknown,
            """
            a closed socket reported "No project". Before the backend has had the chance to \
            speak, that is a claim we have not earned — and it makes the header flicker \
            through the wrong answer on the way to the right one
            """
        )
    }

    func testEverySubtitleStateRendersSomething() {
        let states: [ChatProjectSubtitle] = [
            .unknown, .noProject, .folder("scratch"), .project("hermesmobile"),
        ]
        for subtitle in states {
            XCTAssertFalse(subtitle.text.isEmpty, "\(subtitle) rendered as a blank line")
        }
    }

    // MARK: 4 — the resolver, end to end, with no socket

    @MainActor
    func testTheResolverTurnsAForCwdAnswerIntoAProjectName() async {
        let model = ChatProjectSubtitleModel()
        let answer: ChatProjectSubtitleModel.ForCwd = { _ in (project: "hermesmobile", branch: "main") }
        await model.resolve(cwd: "/repo/hermes", isConnected: true, forCwd: answer)
        XCTAssertEqual(model.subtitle, .project("hermesmobile"))
    }

    @MainActor
    func testTheResolverTurnsANamelessAnswerIntoTheFolderLeaf() async {
        let model = ChatProjectSubtitleModel()
        let answer: ChatProjectSubtitleModel.ForCwd = { _ in (project: nil, branch: "main") }
        await model.resolve(cwd: "/Users/you/Desktop/scratch", isConnected: true, forCwd: answer)
        XCTAssertEqual(model.subtitle, .folder("scratch"))
    }

    /// A failed RPC is not "no project". It is "we do not know".
    @MainActor
    func testAFailedResolveStaysUnknown() async {
        struct Boom: Error {}
        let model = ChatProjectSubtitleModel()
        let failing: ChatProjectSubtitleModel.ForCwd = { _ in throw Boom() }
        await model.resolve(cwd: "/repo/hermes", isConnected: true, forCwd: failing)
        XCTAssertEqual(model.subtitle, .unknown)
    }

    @MainActor
    func testAClosedSocketNeverDialsAndStaysUnknown() async {
        let model = ChatProjectSubtitleModel()
        let probe = DialProbe()
        let answer: ChatProjectSubtitleModel.ForCwd = { _ in
            probe.dialled = true
            return (project: "hermesmobile", branch: "main")
        }
        await model.resolve(cwd: "/repo/hermes", isConnected: false, forCwd: answer)
        XCTAssertFalse(probe.dialled, "the subtitle dialled projects.for_cwd on a closed socket")
        XCTAssertEqual(model.subtitle, .unknown)
    }

    /// A box, so the closure below mutates a reference rather than a captured
    /// local — the closure outlives the statement that made it.
    private final class DialProbe {
        var dialled = false
    }
}
