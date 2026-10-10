# Contributing

A personal project maintained in spare time, so issues and pull requests may sit for a while.

## Bug reports

Say what you did, what you expected and what happened, and include your iOS version and iPhone model, the build number from Settings > About, your Hermes Agent version, and how you run `serve`. For a connection problem, the log from Settings > Backend > Diagnostics helps: it is redacted, but read it before you paste it.

A security problem goes through [`SECURITY.md`](SECURITY.md), not a public issue. A bug in `hermes serve` itself belongs to [Hermes Agent](https://github.com/NousResearch/hermes-agent).

Accessibility is not a 1.0 goal. Reports are recorded but are not being worked.

## Layout

- `HermesServeKit/` is a Swift package with no dependencies: the WebSocket and JSON-RPC client for `hermes serve`, the turn state machine, authentication, the typed REST calls and the redactor. It builds and tests on its own.
- `HermesApp/` is the SwiftUI app: `Models/` holds the observable state (`AppModel`, `ChatModel`), `Views/` the screens, `Design/` the theme and shared components, `Support/` the platform glue, and `Demo/` the offline demo.
- `HermesActivity/` is the Live Activity's attributes and intents, compiled into both the app and the extension. `HermesLiveActivity/` is the widget extension that draws the Lock Screen card and the Dynamic Island.
- `HermesAppTests/`, `HermesUITests/` and `HermesServeKit/Tests/` are the three test targets.
- `docs/` holds the protocol notes, the setup guide and the GitHub Pages site; `scripts/` holds the two build phases.

## Building

A Mac with Xcode. The Xcode project is generated from `project.yml` and is not tracked.

```bash
cd HermesServeKit && swift test   # protocol layer, no simulator needed
cd .. && brew install xcodegen && xcodegen generate
open HermesMobile.xcodeproj
```

Run `xcodegen generate` after any checkout or merge that touches `project.yml`: build-phase behaviour lives in the generated project, so a stale one turns a build-stopping error back into a warning. Do not edit the `.xcodeproj` by hand; the next generate erases it silently.

## Signing with your own team

`project.yml` names the maintainer's team and bundle identifiers, so a fresh clone will not sign. Change them in `project.yml`, not in Xcode's Signing pane, which the next `xcodegen generate` overwrites:

- `DEVELOPMENT_TEAM`, four times: the app, the Live Activity extension and the two test targets. Your team id is on the Membership page of your Apple Developer account.
- `PRODUCT_BUNDLE_IDENTIFIER`, four times, and `bundleIdPrefix` under `options`. An identifier is owned by the team that registered it, so the maintainer's will not sign under yours. Keep the extension's identifier a child of the app's (`<yours>.liveactivity`), which iOS requires of an embedded extension.

Leave these changes out of a pull request.

The build number is stamped from `git rev-list --count HEAD` by `scripts/stamp-build-number.sh`, so build from a clone with its history, not from a downloaded archive.

## Tests

`HermesServeKit` runs under `swift test`. `HermesAppTests` is app-hosted; `HermesAppTests/README.md` has the invocation. `HermesUITests` is XCUITest, and some of it needs a freshly created simulator; those files say so at the top. A pull request should keep all three green.

Comments and changelog entries cite ids like `BUG-060` and `FEAT-021`. They are this project's own identifiers, and there is no tracker to follow them to.
