# Contributing

A personal project maintained in spare time, so issues and pull requests may sit for a while.

## Bug reports

Say what you did, what you expected and what happened, and include your iOS version and iPhone model, the build number from Settings > About, your Hermes Agent version, and how you run `serve`. For a connection problem, the log from Settings > Backend > Diagnostics helps: it is redacted, but read it before you paste it.

Accessibility is not a 1.0 goal. Reports are recorded but are not being worked.

## Building

A Mac with Xcode. The Xcode project is generated from `project.yml` and is not tracked.

```bash
cd HermesServeKit && swift test   # protocol layer, no simulator needed
cd .. && brew install xcodegen && xcodegen generate
open HermesMobile.xcodeproj
```

Run `xcodegen generate` after any checkout or merge that touches `project.yml`: build-phase behaviour lives in the generated project, so a stale one turns a build-stopping error back into a warning. Do not edit the `.xcodeproj` by hand; the next generate erases it silently.

`project.yml` carries a `DEVELOPMENT_TEAM` that is not yours, so a fresh clone will fail to sign. Replace the four values with your own team id, and leave that change out of a pull request.

## Tests

`HermesServeKit` runs under `swift test`. `HermesAppTests` is app-hosted; `HermesAppTests/README.md` has the invocation. `HermesUITests` is XCUITest, and some of it needs a freshly created simulator; those files say so at the top. A pull request should keep all three green.

Comments and changelog entries cite ids like `BUG-060` and `FEAT-021`. They are this project's own identifiers, and there is no tracker to follow them to.
