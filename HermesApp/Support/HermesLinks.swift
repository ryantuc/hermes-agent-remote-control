import Foundation

/// The externally hosted pages the app links out to; `github` is this client's repo, not the agent's, and a nil link draws no row rather than a dead one.
/// All three are live: the repository publishes `docs/` through GitHub Pages, so the address follows the account and repository name. App Review requires a reachable privacy policy (5.1.1(i)) and an easy way to contact the developer (1.5).
enum HermesLinks {
    static let privacyPolicy: URL? = URL(string: "https://ryantuc.github.io/hermes-agent-remote-control/privacy.html")

    static let support: URL? = URL(string: "https://ryantuc.github.io/hermes-agent-remote-control/support.html")

    static let github: URL? = URL(string: "https://github.com/ryantuc/hermes-agent-remote-control")
}
