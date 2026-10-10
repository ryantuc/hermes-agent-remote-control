# HARC

HARC (Hermes Agent Remote Control) is a native iOS client for [Hermes Agent](https://github.com/NousResearch/hermes-agent): it drives a copy of `hermes serve` that you run yourself, at an address you type in.

It is a remote control, not an agent. It has no model, no account and no server of its own, so everything it shows you happens on your backend.

I'm not affiliated with Nous (shoutout to the goats).

## Requirements

- An iPhone on iOS 17 or later.
- A machine running `hermes serve` that the phone can reach, over a LAN, Tailscale, a VPN, or a host you rent. HARC is developed against the hermes-agent 0.21 releases.
- A credential for it. Binding the gateway to anything but loopback turns Hermes Agent's own auth gate on.

[`docs/SETUP.md`](docs/SETUP.md) covers authentication, the serve command, the firewall, and running one backend for both clients. It also carries a prompt you can paste into Hermes on that machine so it writes the guide with your own values in it.

## Try it without a backend

Tap Try the demo on the first screen, or in Settings > Backend. The demo replays a scripted conversation inside the app. It opens no connection and saves nothing, and Exit on the DEMO bar at the top puts you back where you were.

## What it does

- Sessions: streaming replies, reasoning folded away, a live plan and tool strip, and tool output as cards with inline diffs. Pick up a session started on the desktop app or in a terminal, and hand it back.
- Approvals: when the agent asks permission, approve or deny it in the app with the command in front of you, or deny it from the Lock Screen card. Face ID is optional. An approval you tap runs that command on your machine, and which actions stop to ask is your backend's configuration. Which surfaces you get is a setting: see [support](docs/support.html).
- Bots mode: your backend's Hermes profiles as a list of chats, each one opening the same thread every time.
- Voice chat: speech recognition runs on the phone, and voice chat refuses to start where on-device recognition is unavailable. Your audio does not leave the phone; only the text goes to your backend.
- Media and files: images and video render in the transcript, reports render, and everything else opens in Quick Look. Attach photos and documents from the composer.
- Desktop parity: the ten desktop themes in light and dark, and Settings > Agent edits the backend's own configuration.

## Limitations

Notifications and Live Activities are off until you turn them on and iOS allows them, and the Dynamic Island needs a phone that has one. Nothing reaches you while the app is closed, because there is no push service. Voice chat is half-duplex. Bots mode has no push, badges, group rooms or administration. VoiceOver and large accessibility type sizes are not supported. [Support](docs/support.html) has the rest.

## Build from source

You need a Mac with Xcode and [XcodeGen](https://github.com/yonaskolb/XcodeGen). The Xcode project is generated from `project.yml` and is not tracked.

```bash
cd HermesServeKit && swift test
cd .. && brew install xcodegen && xcodegen generate
open HermesMobile.xcodeproj
```

`project.yml` names the maintainer's Apple team and bundle identifiers, so a device build needs yours instead. [`CONTRIBUTING.md`](CONTRIBUTING.md) lists the lines to change, and has the regeneration and test details.

## License and links

MIT, see [`LICENSE`](LICENSE). Material derived from Hermes Agent is listed in [`THIRD-PARTY-NOTICES.md`](THIRD-PARTY-NOTICES.md).

[`SECURITY.md`](SECURITY.md) has the reporting route and the security boundaries, [`docs/privacy.html`](docs/privacy.html) says what data goes where, and [`docs/PROTOCOL.md`](docs/PROTOCOL.md) is the wire protocol as this client implements it.
