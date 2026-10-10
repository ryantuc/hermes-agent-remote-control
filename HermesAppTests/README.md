# HermesAppTests — how to write one

The app layer's tests. `HermesServeKitTests` covers the kit; this target covers `AppModel`, `ChatModel` and the state that drives every screen. It runs the **shipped** `AppModel` — real pumps, real `TurnEngine`, real `ChatModel` — against a scripted backend instead of a socket. Nothing is stubbed except the wire.

## Running them

These need a simulator. `swift test` cannot run them — it only knows the kit package.

```
xcodegen generate
xcodebuild test -project HermesMobile.xcodeproj -scheme HermesMobile \
  -destination "platform=iOS Simulator,name=iPhone 17 Pro" \
  -derivedDataPath build/dd -jobs 3 \
  COMPILER_INDEX_STORE_ENABLE=NO CODE_SIGNING_ALLOWED=NO
```

Add `-only-testing:HermesAppTests` to skip the kit's tests.

`CODE_SIGNING_ALLOWED=NO` is what makes the suite portable, and it is also worth knowing about: an unsigned build carries neither `application-identifier` nor `keychain-access-groups`, so `securityd` refuses every `SecItem` call with `errSecMissingEntitlement` and `KeychainStore` falls back to a file in the app container. That is deliberate and durable (`KeychainPersistenceTests`, `KeychainContainerTests`), but it means a build installed this way is not exercising the real Keychain. Drop the flag when that is what you want to test.

## The shape of every test

```swift
@MainActor
func testSomething() async throws {
    let harness = await AppHarness.make()      // AppModel + scripted backend, socket closed
    try await harness.openSocket()             // opens and waits until AppModel has seen it

    let chat = harness.chat(storedID: "20260804_101500_abc123")
    await chat.open()                          // resume → the chat binds a runtime id

    // …script, act, assert…

    await harness.tearDown()
}
```

Three rules, and they are the whole pattern:

1. **Mark the test method `@MainActor`, not the class.** `AppModel` and `ChatModel` are `@MainActor`. Do not mark the class — a `@MainActor` class cannot override `XCTestCase`'s non-isolated `setUp`/`tearDown`. Build the harness inside the test and tear it down at the end.
2. **Register chats before `openSocket()` if the test is about what happens at open.** The `.open` transition sweeps every registered chat into `resumeOpenThreads`; it only sees chats that already exist. `openSocket()` waits for that sweep to drain before returning, so a chat you register *after* it is yours alone — that wait is load-bearing, and without it the sweep resumes your chat behind your back a few milliseconds into the test.
3. **Never sleep. Always `waitUntil`.** Every assertion about something asynchronous goes behind `waitUntil { … }`, and you assert on its `Bool` result. A fixed `Task.sleep` is a coin flip on a loaded machine.

## Scripting the backend

`harness.backend` is a `ScriptedBackend` actor. Everything on it is `await`ed.

### Answering RPCs

Sensible defaults are built in: `session.resume` and `session.create` mint a fresh runtime id (`rt-1`, `rt-2`, …), `prompt.submit` answers `{"status":"streaming"}`, `session.interrupt` / `session.close` answer `{"ok":true}`, and `approval.respond` answers `{"resolved":1}` — the real gateway's shape, an int count of what it resolved, where `0` means nothing was left to resolve. Anything unrecognised answers `{}` and is recorded in `unhandledMethods`.

Override one when the payload matters:

```swift
await harness.backend.stub("session.resume") { call in
    .object([
        "session_id": .string("rt-fixed"),
        "session_key": .string(call.sessionID),
        "messages": .array([]),
        "info": ScriptedBackend.info(model: "deepseek-v4-flash"),
        "running": .bool(true),
    ])
}
```

`call` is the decoded request: `call.method`, `call.sessionID`, `call.text`, `call.params`.

`stub` takes a `@Sendable` closure that runs off the main actor, so a JSON helper isolated to your `@MainActor` test class cannot be called from inside one — the compiler answers "call to main actor-isolated static method in a synchronous nonisolated context", once per stub. Keep the wire payloads in a file-private enum outside the class, the way `BotChatResolverTests` keeps `Wire` and `BotsModelTests` keeps `RosterWire`, and the closure can reach them.

### Failing an RPC

```swift
await harness.backend.failRPC("prompt.submit", code: 4001, message: "session not found")   // every time
await harness.backend.failNextRPC("prompt.submit", code: 4001, message: "session not found") // once, then normal
```

Codes that mean something to the app: **4001 / 4007** stale session id, **4009** no pending prompt, **4090** active-session limit.

### Pushing events

```swift
await harness.backend.emit("message.start", sessionID: runtimeID)
await harness.backend.emit("message.delta", sessionID: runtimeID, payload: .object(["text": .string("hello")]))
await harness.backend.emitAssistantText("hello", sessionID: runtimeID)   // start + one delta
await harness.backend.emitSessionInfo(sessionID: runtimeID, model: "deepseek-v4-flash")
```

Deltas are coalesced by `TurnEngine` and painted by `AppModel`'s flush loop, so assert on them through `waitUntil`, never immediately.

### Breaking the connection

```swift
await harness.backend.dropConnection()             // plain drop — the client reconnects
await harness.backend.dropConnection(code: 4401)   // credential rejection — it does not
await harness.backend.deliverThenFailWrite("prompt.submit")  // server gets it, client is told the write failed
```

`deliverThenFailWrite` is the *ambiguous write*: the frame reached the server and the client has an error. It is how you stage "did the turn land or not".

### Staging a race between two callers

`gate` withholds a method's **reply** while still recording its frame and leaving the socket writable — so a second caller's frame is not queued behind the first, and both are genuinely in flight.

```swift
await harness.backend.gate("session.resume")
try await harness.openSocket()                              // caller 1 parks in the resume
_ = await waitUntil { await harness.backend.callCount("session.resume") == 1 }

let second = Task { @MainActor in await harness.app.handleForeground() }   // caller 2

await harness.backend.ungate("session.resume")
await harness.backend.releaseParked()
await second.value
```

## Asserting

Read the app's own state — that is the point of testing here rather than in the kit:

```swift
chat.entries            // the rendered transcript: history + live + optimistic bubbles
chat.outbound           // optimistic bubbles not yet acknowledged; `.failure` is the dimmed state
chat.sendPhase          // .idle / .sending / .queued / .stalled
chat.runtimeSessionID   // what the chat is listening on
app.connectionState     // GatewayConnectionState
app.threads
```

And read what the backend saw:

```swift
await harness.backend.calls(to: "prompt.submit")    // [Call], in arrival order
await harness.backend.callCount("session.resume")
await harness.backend.issuedRuntimeIDs             // every runtime id handed out, oldest first
```

Write the failure message so it reads as a bug report — name the file and line of the defect and say what the user loses. `ChatModelSendTests` and `AppModelResumeTests` are the two worked examples.

## What is not scripted

**REST.** `AppModel` builds its own `RestAPI` from the profile, and the harness points that profile at `http://127.0.0.1:9`, which refuses instantly. So `refreshThreads` and `loadTranscript` always fail — fast, and exactly as they do against a backend that has gone away. If a test needs transcript content, put it in `session.resume`'s `messages`, not in REST. A test asserting on `app.threads` or on persisted history needs a REST seam that does not exist yet; add one the same way `AppModel.init(clientFactory:)` was added, and say so here.

**Views.** XCUITests live in `HermesUITests`. Tests here may host a view in a `UIHostingController` or an `ImageRenderer` to measure it, but assert on the model where the model carries the answer.
