# Security

## Reporting a vulnerability

Use GitHub's private vulnerability reporting on this repository (Security > Report a vulnerability), or email <hermesagent.rc@gmail.com>. Please do not open a public issue for a security problem.

## Boundaries

- HARC talks to one backend, at an address the user typed in, running software the user installed. There is no service operated by this project, no relay, no telemetry, no analytics and no third-party SDK. The other network destination is the host serving media the agent produced at an internet address, which the phone fetches with a bare `URLSession` that carries no credential of any kind.
- The transport is whatever the user set up. On a private network it is an ordinary HTTP connection; TLS exists only if the user has put it in front of their own server.
- Passwords, session tokens and bearer tokens live in the iOS Keychain, written `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`. They do not sync to iCloud, do not restore onto a different device, and are never written into `BackendProfile`, the `UserDefaults`-persisted half, or into a log.
- A running conversation keeps a disposable recovery cache on the phone, in the app's Caches directory under iOS file protection: at most eight checkpoints and 32 MiB, no file over 8 MiB, and nothing older than a day. Signing out of a backend or deleting it removes its checkpoints. A checkpoint is restored only when the backend's own event replay validates it, and no prompt or approval is stored in it or resent from it.
- Log lines and exported configuration pass through a redactor that masks provider keys, tokens, passwords and authorization headers by shape and by key name. It is defence in depth rather than a guarantee, which is why the transcript has its own display redaction.
- The approval sheet shows the exact command, deny is the default action, Face ID can be required, and no approval is remembered across a turn. Which actions stop for approval at all is the backend's configuration, not the app's.
- Binding `hermes serve` to anything but loopback turns Hermes Agent's own auth gate on. HARC does not and cannot weaken that.
- The launch-argument seeding harness, including `-hermesSeedPassword`, is enclosed in `#if DEBUG` and does not compile into a Release build.

## Out of scope

- Anything reached through a backend the user chose to point the app at. HARC is a remote control; if you tell it to connect to a hostile server, it will.
- The security of `hermes serve` itself. Report those to [Hermes Agent](https://github.com/NousResearch/hermes-agent).
- A physically unlocked phone with the app already open.
