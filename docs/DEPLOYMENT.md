# Deploying HARC against a Hermes Agent backend

HARC talks to the FastAPI server inside Hermes Agent, started as either `hermes dashboard` (serves the browser SPA plus the APIs) or `hermes serve` (headless — APIs only; every non-API path returns JSON 404).

Facts that shape every deployment (verified against hermes-agent v0.19.1 source; the condensed client contract is in `docs/PROTOCOL.md`):

- **Auth mode is chosen by bind host alone.** Loopback binds (`127.0.0.1`/`localhost`/`::1`) run ungated with an ephemeral per-process session token. *Any* other bind — LAN, Tailscale, `0.0.0.0` — engages the auth gate, which requires at least one configured auth provider (password or OAuth) or the server refuses to start.
- **WebSocket auth**: gated mode requires a single-use 30-second ticket from `POST /api/auth/ws-ticket`, passed as `?ticket=` on the `/api/ws` upgrade. Loopback mode accepts `?token=<session token>`.
- **The native app is unaffected by CORS.** Hermes' CORS policy allows only `localhost`/`127.0.0.1` origins and never sends `allow_credentials`, which constrains browser clients; HARC authenticates with cookies or `Authorization: Bearer` and is not subject to it.

---

## Building and running the app

On a Mac:

```
brew install xcodegen
cd HermesMobile
xcodegen generate
open HermesMobile.xcodeproj
```

`project.yml` is the source of truth — the `.xcodeproj` is generated and is not tracked, so edits made in Xcode's project editor are lost on the next `xcodegen generate`.

Set your own signing team (see `CONTRIBUTING.md`), then run on a device. In the app's connection settings enter the backend URL:

- **Tailnet (recommended):** `http://<tailscale-ip>:9119` works out of the box (the ATS local-networking exemption is enabled); prefer `https://<machine>.<tailnet>.ts.net` behind `tailscale cert`/Caddy.
- **Gated backends:** log in with the password provider; the app stores the session cookie and mints WS tickets automatically. A pasted bearer token (`Authorization: Bearer`) also works for OAuth-provider deployments.
- **Loopback backends** are not reachable from a phone by definition; bind Hermes to the tailnet address.

Never expose `hermes serve`/`hermes dashboard` directly to the public internet. A tailnet (or WireGuard/VPN) plus TLS is the intended shape.
