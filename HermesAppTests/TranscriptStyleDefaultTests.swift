import SwiftUI
import XCTest

@testable import HermesMobile

/// **`.session` is the default, and the thread picks the grammar.**
///
/// Two properties, and the first one is what keeps this feature from being a
/// rewrite of the transcript. Every view that reads `\.transcriptStyle` —
/// `MessageBubbleView`, `AssistantTurn` — keeps today's behaviour for every
/// caller that does not set the key, which is why `MarkdownTableTests`,
/// `TranscriptScrollTests`, `ChatTranscriptDuplicationTests`,
/// `ImageChipLoadGateTests`, `ComposerCapTests`, `KeyboardDismissTests` and
/// `ScrollToLatestHitTargetTests` were not touched by the work that added it.
///
/// The second is that presentation follows the thread,
/// not the app mode. A bot thread renders as a conversation whether it was
/// reached from the roster, a deep link, a Live Activity card, or a Sessions
/// stack — so the resolver reads the thread's own profile and nothing about
/// where the push came from.
///
/// Asserted on the resolver rather than by hosting `ChatView`, deliberately:
/// hosting it would need an `AppModel`, a socket and a simulator to prove a
/// rule that is four lines of arithmetic.
final class TranscriptStyleDefaultTests: XCTestCase {

    // MARK: 1 — the environment default

    func testTheEnvironmentDefaultIsSessionGrammar() {
        XCTAssertEqual(EnvironmentValues().transcriptStyle, .session, """
            the default value of \\.transcriptStyle is not `.session`. Every transcript view in \
            the app reads this key, and the default is the only thing keeping the seven \
            Sessions-rendering test classes — and every screen that ships today — unchanged
            """)
    }

    // MARK: 2 — the thread decides

    func testAThreadWithNoBotProfileResolvesToSession() {
        XCTAssertEqual(TranscriptStyle.resolve(explicit: nil, botProfile: nil), .session)
    }

    func testAThreadWithABotProfileResolvesToConversation() {
        XCTAssertEqual(TranscriptStyle.resolve(explicit: nil, botProfile: "ada"), .conversation, """
            a bot thread resolved to Sessions grammar. The bot's forever-chat is the one surface \
            this feature exists to render
            """)
    }

    /// `SessionSummary.profile` is a coercing accessor and hands back `""` for
    /// an absent field rather than nil (`RestAPI.swift`). An empty profile is
    /// an absent one, not a bot whose name is the empty string.
    func testAnEmptyProfileStringIsNotABot() {
        XCTAssertEqual(TranscriptStyle.resolve(explicit: nil, botProfile: ""), .session, """
            an empty profile string resolved to conversation grammar. Every string off this wire \
            is coerced with a `""` fallback, so this would turn ordinary sessions into bot \
            threads the moment one field failed to decode
            """)
    }

    // MARK: 3 — an explicit pin wins

    /// The screenshot harness and the layout tests both depend on this: a
    /// pinned style overrides the thread, and nothing in the shipping app
    /// passes one.
    func testAnExplicitStyleOverridesTheThread() {
        XCTAssertEqual(TranscriptStyle.resolve(explicit: .conversation, botProfile: nil), .conversation)
        XCTAssertEqual(TranscriptStyle.resolve(explicit: .session, botProfile: "ada"), .session)
    }

    // MARK: 4 — an ordinary session

    /// `ChatView` builds a `BotThreadIdentity` from the chat's own bot fields,
    /// which are nil for every ordinary session. That is the claim above about
    /// the untouched Sessions test classes, restated where it can fail.
    func testAnEmptyBotIdentityResolvesToSession() {
        let identity = BotThreadIdentity()
        XCTAssertNil(identity.profile)
        XCTAssertNil(identity.displayName)
        XCTAssertEqual(TranscriptStyle.resolve(explicit: nil, botProfile: identity.profile), .session)
    }
}
