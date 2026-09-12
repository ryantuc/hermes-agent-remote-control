# HARC

A native iOS client for [Hermes Agent](https://github.com/NousResearch/hermes-agent): it drives a copy of `hermes serve` that you run yourself, at an address you type in.

I'm not affiliated with Nous (shoutout to the goats).

## Requirements

- An iPhone on iOS 17 or later.
- A machine running `hermes serve` that the phone can reach, over a LAN, Tailscale, a VPN, or a host you rent.
- A credential for it. Binding the gateway to anything but loopback turns Hermes Agent's own auth gate on.

[`docs/SETUP.md`](docs/SETUP.md) covers authentication, the serve command, the firewall, and running one backend for both clients. It also carries a prompt you can paste into Hermes on that machine so it writes the guide with your own values in it.

## What it does

- **Sessions.** Streaming replies, reasoning folded away, a live plan and tool strip, tool output as cards with inline diffs. Pick up a session started on the desktop app or in a terminal, and hand it back.
- **Approvals.** When the agent asks permission, approve or deny it in the app with the command in front of you, or deny it from the Lock Screen card. Face ID optional. An approval you tap runs that command on your machine, and which actions stop to ask is your backend's configuration. Which surfaces you get is a setting: see [support](docs/support.html).
- **Bots mode.** Your backend's Hermes profiles as a list of chats, each one opening the same thread every time.
- **Voice chat.** Runs on required on-device speech recognition. Your audio does not leave the phone; only the text goes to your backend.
- **Media and files.** Images and video render in the transcript, reports render, everything else opens in Quick Look. Attach photos and documents from the composer.
- **Desktop parity.** The ten desktop themes in light and dark, and Settings > Agent edits the backend's own configuration.

## Limitations

Notifications and Live Activities are off until you turn them on and iOS allows them, and the Dynamic Island needs a phone that has one. Nothing reaches you while the app is closed, because there is no push service. Voice chat is half-duplex. Bots mode has no push, badges, group rooms or administration. VoiceOver and large accessibility type sizes are not supported. [Support](docs/support.html) has the rest.

## Build

HARC is not on the App Store yet. Building it needs a Mac with Xcode.

```bash
cd HermesServeKit && swift test
cd .. && brew install xcodegen && xcodegen generate
open HermesMobile.xcodeproj
```

[`CONTRIBUTING.md`](CONTRIBUTING.md) has the signing, regeneration and test details.

## License and links

MIT, see [`LICENSE`](LICENSE). Material derived from Hermes Agent is listed in [`THIRD-PARTY-NOTICES.md`](THIRD-PARTY-NOTICES.md).

[`SECURITY.md`](SECURITY.md) has the reporting route and the security boundaries, [`docs/privacy.html`](docs/privacy.html) says what data goes where, and [`docs/PROTOCOL.md`](docs/PROTOCOL.md) is the wire protocol as this client implements it.
