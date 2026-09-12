# Setup

HARC connects to `hermes serve` on a machine you run. The gateway ships inside the agent, so there is nothing extra to install.

```
hermes serve --host 0.0.0.0 --port 9119
```

## Authentication

The bind host decides how you authenticate, and this catches people out. Bound to loopback, the gateway runs ungated. Bound to anything else, including a tailnet address or `0.0.0.0`, it turns the auth gate on (`should_require_dashboard_auth`, `hermes_cli/web_server.py`), advertises that on `GET /api/status` as `auth_required`, and refuses unauthenticated calls. So the moment you make the backend reachable from your phone, you need a real credential.

HARC offers four methods in the backend form, and detects which one to use when you let it.

| Method | When |
| --- | --- |
| Password | Gated backend, `POST /auth/password-login`, cookie session |
| Bearer token | Gated backend, `Authorization: Bearer` on every REST route |
| Session token | Loopback backend, `X-Hermes-Session-Token` |
| None | Loopback backend with no token set |

Type an address and the app probes it while you type, tells you what it found, and says whether the backend wants a sign-in. Credentials go into the iOS Keychain marked device-only, so they do not sync to iCloud and do not restore onto another phone.

The connection itself is whatever you set up. On a private network it is ordinary HTTP; TLS exists only if you have put it in front of your own server.

## Ask your own agent to write the guide

Hermes is running on the machine you are about to configure, so it can read its own installation and write you a guide with real values in it instead of placeholders. Paste this into a Hermes session on that machine:

```
I want to reach this Hermes installation from the HARC iOS app on my phone. Work out the specifics for THIS machine and write me an exact setup guide, not a generic one. Read your own installation to answer, and tell me what you found before you tell me what to do.

Cover, in this order:

1. What is here now. Your OS and version, HERMES_HOME, the hermes version, whether a `hermes serve` is already running and on what host and port, and whether anything else (a desktop app, a gateway, a cron runner) is already sharing this HERMES_HOME. Say how you determined each one.

2. The address my phone should use. List every candidate: LAN address, Tailscale or other VPN address if this machine is on one, and a public hostname if it genuinely has one. Recommend one and say why. If a tailnet is available, prefer it and say what it costs me to set up if it is not installed yet.

3. Authentication. Binding to anything other than loopback turns the gateway's auth gate on, so tell me which of these I will be using: password, bearer token, session token, or none. Give me the exact commands to set the credential, generate a strong secret where one is needed, and show it to me once. Do not put a secret in a file that is committed anywhere or in a shell history if you can avoid it, and say which files you touched.

4. The serve command. The exact line, for this machine, with the host and port filled in.

5. Making it survive a reboot. Use the right mechanism for this OS: a Scheduled Task on Windows, a launchd agent on macOS, a systemd user unit on Linux. Give me the actual command or the actual unit file, tell me where it will write its logs, and tell me how to check it is running and how to stop it.

6. The firewall. Whatever this OS needs so the port is reachable over the interface I picked, and nothing wider than that.

7. Pointing the desktop app at the same backend, if this machine has the Hermes desktop app. I want one backend with both clients on it, not the desktop spawning a second one, so tell me how to check which backend the desktop is currently talking to and how to point it at this one.

8. Verifying it from the phone. What I type into HARC's backend form, in order; what a healthy `GET /api/status` looks like from another machine; and the two or three things that most commonly go wrong here with the symptom I would see in the app for each.

Ask me anything you need instead of guessing. Where you had to assume something, mark it.
```

Everything the prompt asks for is in the agent's own documentation if you would rather do it by hand. The prompt exists because the machine-specific half is the part that wastes an evening.

## Run one backend

If a desktop app spawns its own `hermes serve` while one is already running on the same `HERMES_HOME`, the two can dispatch the same conversation and fork the transcript. Point the desktop at the backend you already have; step 7 of the prompt above works out how, for your machine.

From hermes-agent 0.21.1, a client that resumes a session attaches to the live event stream instead of taking it away from the client already on it. On older versions, a phone reconnecting can stop the stream the desktop was showing.

## If it does not connect

Three things account for most of it: the gateway is still bound to `127.0.0.1` and cannot be reached from the phone at all; the gateway is reachable but the auth gate is refusing the credential the app is sending; or the port is not open on the interface you picked, which on Windows is the usual cause because a fresh `hermes serve` gets no firewall rule of its own.

More in [Support](https://ryantuc.github.io/hermes-agent-remote-control/support.html).
