# Hermes serve client contract (condensed)

This is the condensed contract HARC is written against: the subset of Hermes Agent's gateway protocol this client actually calls. The authoritative detail is the upstream source itself — [NousResearch/hermes-agent](https://github.com/NousResearch/hermes-agent), which serves 141 RPC methods and 62 event types over the same transport.

Derived from Hermes Agent (MIT, Copyright (c) 2025 Nous Research). See `THIRD-PARTY-NOTICES.md`.

Everything below was verified against hermes-agent **v0.19.1** source. Contract
version: `DESKTOP_BACKEND_CONTRACT = 5`, returned as `info.desktop_contract` in
`session.create`/`session.resume` results.

## Transport

- WebSocket at `/api/ws`. Newline-delimited JSON-RPC 2.0 both directions; one
  WS text message may contain **multiple** frames (server coalesces
  `message.delta`/`reasoning.delta`/`thinking.delta` on a 33 ms timer) —
  always split on `\n`.
- On accept the server pushes `{"method":"event","params":{"type":"gateway.ready","payload":{skin, change_events:true}}}`.
- Event frames: `params = {type, session_id, payload?}`. `session_id` is on
  every event (`""` for global broadcasts); `payload` is omitted when null.
- Responses can arrive out of order (41 methods run on a thread pool) —
  correlate strictly by `id`.
- Request timeout must be long: `prompt.submit`'s ACK is quick but the turn
  itself completes via events; Desktop uses a 30-minute request timeout.

## Auth

Mode is chosen by bind host: loopback ⇒ ungated; anything else ⇒ gated
(password/OAuth provider required). Probe `GET /api/status` (public) —
`auth_required`, `auth_flows`.

- **Loopback:** per-process `_SESSION_TOKEN` (injected into the dashboard's
  HTML only; obtain out-of-band for other clients). Send as
  `X-Hermes-Session-Token` or `Authorization: Bearer` on REST; `?token=` on
  the WS upgrade.
- **Gated:** login via `POST /auth/password-login` (sets cookies) or OAuth;
  native apps may use `Authorization: Bearer <access_token>` on every REST
  route, or RFC 8252 PKCE at `/auth/native/*` (loopback-IP-literal redirect
  only). WS upgrade needs `?ticket=` from `POST /api/auth/ws-ticket` —
  **single-use, 30 s TTL: mint a fresh ticket before every connect attempt.**
- Browsers: CORS allows only localhost origins, without credentials ⇒ the web
  app must be same-origin with the backend. Native clients: omit `Origin` on
  the WS upgrade (absent Origin is allowed).

## Sessions

- Two id spaces: ephemeral runtime `session_id` (8 hex, what events carry and
  most methods take) vs durable `stored_session_id`/`session_key` (what
  `session.list`/`session.resume`/`session.delete` take).
- `session.create {profile?, model?, ...} → {session_id, info{...}}`;
  `session.resume {session_key, lazy?} → {session_id, info, inflight?, queued?, auto_continue?}`.
  Resume follows the compression-continuation chain to the live tip.
- Thread list: REST `GET /api/sessions` (or `/api/profiles/sessions`);
  freshness via `sessions.changed` event (empty payload) demoting a slow poll
  backstop. No `updated_at` — use `last_active`.
- Transcript: `GET /api/sessions/{id}/messages` — the response's
  `session_id` may differ from the requested one (render against it).
  Message `content` is `str | OpenAI content-part list | null`; tool results
  are separate `role:"tool"` rows; `role:"user"` rows with non-empty
  `display_kind` are bookkeeping, not user turns.
- Disconnect: sessions with `close_on_disconnect:true` reap immediately;
  others get a ~20 s grace window — a quick reconnect + `session.resume`
  keeps them. In-flight turns are never reaped.
- Multi-session over one socket is supported; a session pins events to the
  transport that last touched it.

## Profiles

The roster surface. Read-only from this client: `profiles.configure` would write `ui_meta` whole-object behind a freshness fence, and a blind write clobbers whatever else is in that namespace.

- `profiles.list {include_sessions?, preferred_session_ids?} -> {profiles: [...], bot_mode_protocol}`. Every profile, always, default first — no filter, no pagination. `include_sessions` defaults true; `preferred_session_ids` is `{profile_name: session_id}` and anything that is not an object is silently discarded. `bot_mode_protocol` is presence-based (hardcoded true where it exists, never sent as false) and means the backend injects the Bot Mode teammate protocol itself.
- Row: `{name, path, is_default, model, provider, description, display_name, skill_count, last_session, worker_session, preferred_session?, ui_meta?, ui_meta_revisions, has_avatar}`. `model`/`provider` are genuinely nullable. `ui_meta` appears only when `profile.yaml` carries a non-empty dict; `ui_meta_revisions` is always there and is the feature-detect for gateway-owned CAS.
- `last_session` is `{id, title, preview, started_at, last_active, message_count}` — **hidden-filtered**, so it can never show a canonical `Bot Chat`. A bots roster orders by `preferred_session` or it orders by nothing.
- `preferred_session` is **tri-state and all three states are different**: key absent (no pin was supplied for that profile, or the gateway is too old), key present and `null` (the gateway looked and the row is gone / archived / `kanban`-or-`tool` sourced), key present with an object. Its shape is `{id, resolved_id, root_title, title, preview, started_at, last_active, message_count}`, where `id` is the caller's pin echoed back and `resolved_id` is the live compression tip. Its `last_active` reads `last_activity_at` directly and is **not** comparable with `last_session.last_active`.
- `profiles.get_asset {name, asset?} -> {found, mime?, size?, data?}`. `asset` defaults to `"avatar"`, the only supported value. `data` is a full `data:<mime>;base64,...` URL, not bare base64. A missing asset is `{found: false}` — a success, not an error — so probing every row is cheap. Errors are 4063 / 4064 / 5066.

A bot's thread is identified by its title, not by a stored pointer — there is no `canonical_session` field anywhere on this wire:

- `session.list {title, profile?, include_hidden?, limit?}` is an **exact-title registry lookup**, not a listing: a partial UNIQUE index on `sessions(title)` means at most one row per profile db can carry a title, and the branch answers with a one-element list `{id, resolved_id, title, preview, started_at, message_count, source}`. Hidden rows resolve here; archived rows and `kanban`/`tool` sources come back as an empty success. `started_at` is the root's, `message_count` the tip's, and `preview` is always empty (the tip is a `get_session()` row). An older gateway ignores `title` and returns its ordinary windowed listing instead — **filter client-side on the exact title or you will adopt an unrelated conversation.**
- Compression **transfers** a title from the root onto the continuation and NULLs the ancestor. So a pinned root id keeps resuming, but after the first rotation only the tip is discoverable by title, and `preferred_session.root_title` goes empty while `title` still reads the name. Treat "root title matches, or root title is empty and tip title matches" as the same conversation.
- `session.create {title, hidden?, profile?, cols?, ...}`. `hidden: true` is deferred intent — no DB row is written at create; the row materialises on the first `prompt.submit` and the flag is applied then. A created-but-never-prompted session does not exist.
- `session.resume {session_id}` accepts an exact **title** in `session_id`: when the id lookup misses, the gateway retries it as a title lookup and binds what it finds. Undocumented outside the source, and the fallback rung a client uses when it has no pin.

## A chat turn

```
prompt.submit {session_id, text}          → ACK {queued|steered|redirected...}
  ← message.start                          (seals nothing; begin a bubble)
  ← reasoning.delta / thinking.delta ...   (optional reasoning stream)
  ← message.delta {text} ...               (accumulate per SESSION — no message id)
  ← tool.start / tool.complete ...         (tool cards; correlate positionally)
  ← approval.request {...}                 (see below — must be answered)
  ← message.interim / message.complete     (seal the streaming bubble)
```

- `message.complete` with `status:"error"` is the failure signal — there is
  no separate error event for a failed turn.
- Interrupt = `session.interrupt {session_id}` (there is no
  `prompt.interrupt`).
- `prompt.submit` on a busy session is never rejected — it queues/steers per
  `display.busy_input_mode`.
- Render flushes should be timer-based (≈33 ms floor, adaptive), never
  requestAnimationFrame (hidden tabs stall rAF and the stream "hangs").

## Blocking prompts (client must answer)

- **Approvals** (`terminal`, `execute_code` tools): `approval.request`
  event, **session-keyed FIFO, no request_id**. Answer with
  `approval.respond {session_id, choice: "once"|"session"|"always"|"deny"}`
  (an `all` bool exists for batch). Unanswered ⇒ agent hangs 300 s then the
  tool fails. Pending approvals are NOT recoverable across reconnect —
  surface them prominently.
- **Clarify / sudo / secret / terminal-read**: different mechanism — each
  request event carries `request_id`; answer via the matching respond method
  with per-flow keys (`answer` / `password` / `value`). Timeouts: clarify
  configurable (default 3600 s), sudo 120 s, secret 300 s, terminal-read
  30 s; each emits `<prefix>.expire` on timeout and tolerates late answers.

## Attachments

Never inline in `prompt.submit`:

- Images/PDFs: `image.attach_bytes` (raw base64) queues onto the session's
  `attached_images`; consumed at next turn start.
- Other files: `file.attach` (data-URL) returns `ref_text` (`@file:...`)
  which the client splices into the prompt text itself.
- REST alternatives: `POST /api/chat/image-upload` (JSON data-URL, 25 MiB,
  images only, returns a gateway-local path), `POST /api/files/upload-stream`
  (multipart, 100 MiB). Downloads: `GET /api/files/download` (accepts
  `?token=`), `/api/files/read`, `/api/media`.

## Reconnect

No client reconnect exists in the shared transport — implement: backoff
1→15 s (escalate UI after ~6 tries), wake on online/visibility/power events,
re-mint the WS ticket every attempt, then `session.resume` each open thread
and project its `inflight {user, assistant, streaming, corrections?, error?}`
snapshot (the only carrier of a terminal frame lost while disconnected).
`auto_continue` in the resume payload means the backend auto-resubmitted a
turn that died with the process.

## Reusable code

`apps/shared/src/json-rpc-gateway.ts` (422 lines, MIT, zero deps beyond DOM
WebSocket) is the entire protocol client — vendored into `hermes-web` and
used as the specification for the Swift port.
