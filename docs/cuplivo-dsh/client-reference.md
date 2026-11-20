# Cuplivo ⇄ DeepSeek Harness — client reference and Cuplivo client design

Status: research note for `feat/cuplivo-dsh` (workstream P2). Companion
documents: `architecture.md` (the contract — wins on any disagreement),
`protocol.md` (server-side API ground truth), `client-api.md` (the frozen
public surface of `lib/core/dsh/`, written from this note),
`cuplivo-integration.md` (host seams), `ui-spec.md` (surfaces from the
reference images), `e2e-infra.md` (acceptance harness). Where this note and
`client-api.md` differ on a class or method name, `client-api.md` is the one
implementers code against.

This note answers three questions:

1. **What exists to copy from?** The reference is the **dsh-go** repository
   (AGPL-3.0, a read-only research copy outside this repository): a pure-Dart
   DSH client plus a full Flutter client that renders the official DSH surfaces
   natively. Both were read in place, never modified, never copied into this
   repository.
2. **What does the wire actually look like?** Every endpoint this feature needs,
   with argument and response shapes verified against the installed DSH
   **0.2.2-rc.1** (the installed `@deepseek-ai/dsh` package) and against
   the reference client's parser for that version.
3. **What should Cuplivo build?** A fresh pure-Dart client under
   `lib/core/dsh/` with the module layout already agreed in `architecture.md`,
   the state ownership and lifecycle rules that keep it lean, and a phased
   implementation checklist.

Nothing here is code to paste: the deliverable is knowledge (endpoint shapes,
engineering rules, pitfalls) plus interface contracts for fresh code. See §8 for
the licensing position and the acknowledgement the PR owes.

> Conventions in this note: `http://<authority>` stands for the `dsh web` root
> the user pastes (`http://127.0.0.1:3080` or a LAN/TLS address); `<token>` is
> the launch token printed by `dsh web`; payloads are JSON unless stated.
> "0.2.2" means the installed 0.2.2-rc.1. "0.2.1" means the 0.2.1-rc.2 the
> reference was first written against.

---

## 0. TL;DR — what this study concludes

**Recommended shape.** Five protocol layers (endpoint parsing → transport →
unary RPC → mux → wire models) plus two domain layers (catalog reads; one open
session), all Flutter-free, producing a transcript projection that the Flutter
feature renders with Cuplivo's own widgets. This is exactly the layout in
`architecture.md` §3; this note fills in the interfaces and the behavior inside
each file. One `DshClient` per connected remote, one `DshChatController` per
open session, no persistence of DSH data.

**Engineering rules worth copying from the reference** (all verified in
`packages/dsh_client`, §4):

- Connection is a **generation**: every successful WebSocket carries one
  `$events` ready handshake; a lost socket voids every stream on it and nothing
  is replayed. Callers reopen their streams, take a fresh `session/follow`
  snapshot, and reconcile. A watch must therefore be built as "snapshot +
  contiguous seq tail", never as "resume from where I was".
- Unary calls and mux streams are **separate failure domains**: HTTP 200 with
  `{ok:false}` is a business answer; HTTP 401/403/404/415 is the carrier
  refusing; a socket error is neither. The UI classes differ (retry vs
  re-login vs hide-capability).
- The transcript is folded from **append-origin durable events only**
  (`surfaceOp === 'append'`; replacement events are model-context rewrites, §7.3)
  plus a live assistant draft that is replaced by the durable
  `assistant/message` when it lands.
- Pending approvals/questions are **host requests**, not log events: they ride
  `$events` waterfalls, are redelivered to each new generation with the same
  `eventId`, and are answered through `$events/result` bound to that
  generation's `clientId`.
- Big surfaces follow the same recipe: catalog read + live stream/cache, and
  every cache is refreshed by a host event (`settings/document-updated`,
  `plugin-manager/changed`, `llm/adapters-updated`, `commands/change`, …), not
  by polling.

**Things that should change the Lead's current plan** (details in the cited
sections — this list is the report, not a side note):

1. **DSH 0.2.2 is `session/selectModel` → `{selected}` only**; `defaultSave` is
   gone and the next-session default moved to `session/initializeDefaultModel`
   (§7.2). The reference's "selection + default save" result type exists only
   for older hosts; Cuplivo should target the new shape and treat the old one as
   a fallback.
2. **Permission control has no per-session write endpoint.** The session's
   current preset is read from `session/control` projections
   (`permissionPreset`) and changed by sending a normal prompt line
   (`/permission` command through `commands/execute`) — not by a dedicated
   "set permission" RPC. The "default new-session permission" really is a
   settings write (`settings/mutate ns=permission`, key `defaultPreset`) (§3.6).
3. **Activation before prompting is required but undocumented in the request
   shape**: `session/prompt` needs a live agent for a session that exists on
   disk; the reference opens a throwaway `session/follow {activate:true,
   maxMessages:1}` and waits for its snapshot. Cuplivo must do the same or the
   first prompt on a cold session can fail (§3.2.3).
4. **The reference images' right-rail “浏览器” card has no server API in
   0.2.2-rc.1** (no `browser/*` remote namespace; the official browser sidebar
   is a desktop-only surface). Capability parity therefore says: do not render
   a browser card that cannot be served. Recommended: hide it, or make it a
   Cuplivo-native "open URL in the in-app browser" utility clearly outside the
   DSH capability set (§3.14, §6.8).
5. **Plugin panels/entries cannot be enumerated through the API.** There is no
   remote endpoint for plugin-contributed UI slots; `pluginInventory/list` +
   the boot graph tell you *which packages have a browser half*, not their
   labels or slot occupancy. Hence: Flutter entry rows may be derived from
   inventory/bundles, but the panel body is always the official page in a
   WebView, and deep-landing inside it is best-effort DOM driving (§5.7, §6.9).
6. **WebView auth is cookie injection, not URL tokens.** The launch token works
   once and rotates per `dsh web` process; the signed cookie outlives restarts.
   First open may navigate `/?token=` (mints the cookie in the WebView jar);
   every later open must inject the stored cookie (§3.1.4).
7. **DSH itself is MIT** (`@deepseek-ai/dsh` 0.2.2-rc.1 ships an MIT `LICENSE`),
   while `dsh-go` is AGPL-3.0 and Cuplivo is AGPL-3.0. The PR's acknowledgement
   should say exactly that; "both projects are AGPL" is inaccurate (§8).
8. **`llm/discoverModels` lost its `…WithHeaders` variant** and takes
   `{settingsNs, request}` where `request` is the draft
   (`provider?`, `baseURL?`, `api?`, `apiKey?`). Custom-provider editing must
   write `llm-pi-ai` profiles through `settings/mutate` path ops and preserve
   every field it does not edit (§3.8, §7.4).

---

## 1. The reference implementations

All paths below are relative to the dsh-go repository root (a read-only research
copy outside this repository). It is the closest prior art in existence: a client that already proves
which parts of the DSH API a native app can render, which parts it cannot, and
what engineering it takes to keep a live WebSocket projection correct on a
phone network.

### 1.1 `packages/dsh_client` — pure-Dart protocol client (23,040 lines in `lib/src`)

No Flutter imports. Layered exactly like a network stack, which is why the
Cuplivo design should keep the same seams:

```text
DshConnection      one host's physical connection: URL, Host header, cookie, HTTP, WS upgrade
  └─ DshCarrier    transport abstraction; default DshHttpCarrier (POST /api/<endpoint> + WS)
       ├─ DshRpc   unary Typert call: {type:client-request, rpcId, method, payload}
       └─ DshMux   /api/remote.mux logical streams + $events generations + reconnect
            └─ DshClient  domain API: 27 `*_api.dart` extensions on one class
                 └─ ChatTranscript   optional reducer: events → chat items
```

File map (line counts are useful as a weight budget; Cuplivo's lean client
should be a fraction of this):

| file | lines | responsibility |
|---|---|---|
| `connection.dart` | 858 | `DshCookie`, `DshLaunchUrl`, login (`GET /?token=`), `postJson`, `postBytes`, `getBounded`, `connectWebSocket`, Host header, timeout/cancel, cookie parse |
| `carrier.dart` | 288 | `DshCarrier` + `DshHttpCarrier` + `_WebSocketMuxLink` (frame words, ping cadence, large-frame decoding) |
| `rpc.dart` / `rpc_envelope.dart` | 70 / 31 | call wrapper, endpoint validation, `server-response` envelope, HTTP status → message |
| `mux.dart` | 594 | generations, ready handshake, streams, uplink, pending host requests, backoff, reconnect |
| `models.dart` | 2088 | every wire model: parts, messages, session summaries, model catalog, workspaces, approvals, questions, event hierarchy, follow frames, host events |
| `errors.dart` | 105 | sealed exception hierarchy (remote vs carrier vs protocol vs closed) |
| `session_api.dart` | 1358 | list/create/follow/page/history/prompt/cancel/queue/fork/search/rename/archive, models, permission preset, commands, skills, uploads, attachments, activation |
| `transcript.dart` | 1326 | `ChatItem` hierarchy + reducer + assistant draft blocks + pending reconciliation |
| `plugins_api.dart` | 1187 | bundles/plugins/install/inspect/registries + localized meta |
| `engine_settings_api.dart` | 676 | schemastery JSON view, settings describe/mutate, plugin inventory |
| `providers_api.dart` | 651 | `llm-pi-ai` provider profiles, model specs/overrides, discovery, configurable providers |
| `features_api.dart` | 686 | schedule, jobs, skills, agent presets, settings section, generic stream helper |
| `workspaces_api.dart` / `workspace_api.dart` | 194 / 300 | workspace CRUD/follow/pin/archive, directory picker |
| `client_inventory_api.dart` | 548 | boot graph `__DSH_BOOT__` parse, bridge inventory, client package merge |
| `session_activation.dart` | 138 | cold-session activation gate (release check + throwaway follow) |
| `files_api.dart` | 237 | file read/bytes, office→PDF, media type sniffing |
| `messages_api.dart` | 301 | fork at message, message feedback |
| `agents_api.dart` | 500 | subagent addressing/routing (out of Cuplivo scope) |
| `background_session_read.dart` | 568 | isolates: off-main-thread list reads for startup latency |
| `binary_response.dart` | 123 | multipart `server-response` with byte attachments |
| `runtime_capabilities.dart` | 273 | release/endpoint capability probe cache |
| `dsh_go_api.dart` | 1768 | the app's own bridge plugin `/dsh-go/v1/*` (out of scope for Cuplivo) |
| `dsbot_api.dart`, `companion_*`, `phone_*`, `goals_api`, `cordis_api`, … | — | dsh-go product extras; deliberately out of Cuplivo scope |

Public surface (the shape a native client needs; Cuplivo implements a subset):

```text
DshClient.connect(launchUrl:, hostHeader:) -> DshClient
listSessions() createSession({workspaceId?, cwd?, sessionId?, agentPreset?})
history(sessionId, throughSeq:, beforeSeq?, maxMessages?, turnWindow?)
watch(sessionId)  -> Stream<DshEvent>  (snapshot first; survives reconnect)
prompt(sessionId, text|parts, mode: queue|steer, requestId:)   cancel(sessionId)
respondApproval(request, decision)  answerQuestion(request, answers)
listModels()  setModel(sessionId, provider, model, reasoningEffort?)  permissionPresets()
watchWorkspaces()  watchSessionControl()  watchJobs(sessionId)
describeSettings()  mutateSettings(ns, ops, expectedRevision)  permission default
listBundles() listPlugins() setBundleEnabled() installBundle() pluginInventory()
describeCredentials(refs) setProviderKey() clearProviderKey()
listCommands(agentId) executeCommand(agentId, line) listSkills(sessionId)
scheduleCatalog() jobList() forkAt() searchSessions() renameSession() archiveSession()
uploadFile() attachment()  webBoot graph  supportsEndpoint()
```

### 1.2 `packages/dsh_remote` — encrypted tunnel carrier (out of Cuplivo scope, but instructive)

7,896 lines / 20 files: account + device pairing, `RemoteServerApi`, relay
control WebSocket, Noise IK `SecureChannel`, WebRTC transport with chunking,
`RemoteRpcClient`, and `RemoteTunnelCarrier implements DshCarrier` handed to the
same `DshClient`. Also `RemoteSessionTransfer` (encrypted session backup) and
`RemoteDshWeb` (open the official Web UI through the tunnel).

Why it matters here: it proves the `DshCarrier` seam is the right abstraction —
**one client, several transports**. Cuplivo only needs the HTTP/WebSocket carrier
today, but `lib/core/dsh/dsh_transport.dart` should keep the same tiny interface
(`call`, `openLink`, `close`, `allowsEndpoint`, optional capabilities) so a
future SSH/relay carrier does not require touching the session layer. It also
shows the tunnel-side allowlist (`harnessRemoteAllowlist`) that a carrier can use
to advertise which endpoints exist — not needed for direct HTTP, where the Host
serves everything it mounts.

### 1.3 `app/` — the native Flutter client (the prior art the Lead asked about)

- 123 state files, handwritten Riverpod `Notifier`/`AsyncNotifier` (no codegen).
  Cuplivo must **not** adopt Riverpod; the patterns translate to `ChangeNotifier`
  (§6.3).
- `app/lib/state/chat_state.dart` (2,263 lines) owns one open session:
  `autoDispose.family(sessionId)`, folds mux events into `ChatState`, holds
  approvals/questions/pending prompts, sends/stops, and exposes one immutable
  snapshot to the UI.
- `app/lib/state/features_state.dart` derives permission/model/skills/commands
  catalogs with host-event invalidation; `engine_settings_state.dart` (1,226
  lines) renders settings from schemastery; `providers_state.dart` /
  `provider_backend.dart` drive provider CRUD.
- `app/lib/ui/chat/` is the rendering stack: `chat_rows.dart` derives immutable
  row objects from transcript items, `chat_rows_cache.dart` keeps built rows
  across streaming frames, `tool_view.dart` renders tool cards,
  `composer.dart`/`model_sheet.dart` the composer selectors.
- `app/lib/ui/web/` + `app/assets/web/*.js` host the official Web page and drive
  it by accessible name because DSH Web has no URL routes (§5.7).
- `app/docs/architecture.md` §2.3 states the state contract that Cuplivo should
  imitate in Provider form: one owner per state, UI calls notifier methods,
  chat list watches full state only inside the list builder.

### 1.4 Tests and harness (what a fresh client should also test)

`packages/dsh_client/test` has 60+ files; the ones that matter as models for
Cuplivo's `test/core/dsh/`:

| reference test | what Cuplivo should mirror |
|---|---|
| `transcript_test.dart` | event fold → rows; draft replaced by durable message; interruptions |
| `watch_activation_test.dart`, `activation_rc1_test.dart`, `activation_bounded_http_test.dart` | activation gate and its version/HTTP bounds |
| `watch_history_fill_test.dart` | gap between snapshot end and live seq → paged backfill |
| `mux_pending_order_test.dart`, `mux_generation_history_test.dart` | pending-request reconciliation across generations |
| `websocket_compression_live_test.dart` (live-tagged) | deflate does not break frame decoding |
| `http_body_timeout_test.dart`, `http_late_open_test.dart`, `connection_abort_test.dart` | total-deadline discipline (body timeout, late connect, cancel) |
| `model_selection_result_test.dart` | old `defaultSave` vs new selection-only response |
| `engine_settings_api_test.dart`, `providers_api_test.dart` | schema views, path ops, revision conflicts, unknown-field preservation |
| `live_test.dart` (gated by `DSH_LIVE_URL`) | shape check against a real server |

Fixtures are recorded JSON payloads (`test/fixtures/`), and every "live" test is
skipped unless an environment variable points at a real server — exactly the
hygiene Cuplivo's CI needs (unit tests never need a server; the E2E scenario
proves the real integration, per the roadmap).

### 1.5 Reference docs worth reading (not copied)

- `docs/architecture.md` — layers, state ownership, protocol data flow.
- `docs/official-parity.md` — a per-package map of official web UI features to
  native pages; states explicitly which features stayed in the WebView and why.
  This is the best single answer to "is surface X implementable natively?".
- `docs/plugins/web-panels.md` and `docs/design/plugin-seams.md` — how the app
  hosts plugin UI in WebViews and what a native plugin bridge would have to do.
  Cuplivo deliberately does **not** ship such a bridge (product goal: plugin UI
  only in a WebView), but these documents define the boundary.
- `docs/design/settings-ia.md` — how the official settings were split into
  native pages, which is the same problem as Cuplivo's settings split.

---

## 2. Wire quick reference (client-relevant essentials)

`protocol.md` owns the exhaustive protocol description; this section is the
minimum a client author must internalize before writing code.

### 2.1 Root, authority and authentication

`dsh web` prints its authenticated root when the app is ready:

```text
dsh web: http://127.0.0.1:3080/?token=<launch-token>
```

- The **authority** is `host[:port]` as dialed (`127.0.0.1:3080`,
  `dsh.lan.example` and so on). The Host binds the session cookie to exactly
  that string.
- The launch token is accepted only by `GET /?token=<token>`; a wrong token, a
  token from another `dsh` process or the right token on another path answers
  401. 0.2.2 adds `GET /connect?token=<token>&interactions=answer|none`, which
  mints a **v2 API-operator** cookie instead — Cuplivo deliberately does **not**
  use it (`architecture.md` invariant 2): v2 allows one mux peer, cannot
  authenticate the WebView, and is outlived by v1.
- The answer is a redirect (`303`) plus `Set-Cookie:
  dsh-auth-<base64url(sha256(authority))>=v1.<payload>.<sig>; Max-Age=2592000;
  Path=/; HttpOnly; SameSite=Strict` (`Secure` under TLS). The cookie payload
  binds `authority` + issue/expiry instants and is signed with a secret
  persisted in `$DSH_HOME/.credentials.yaml`, so **the cookie survives DSH
  restarts while the launch token rotates with each process**.
- The cookie is a bearer credential: store it in `flutter_secure_storage`, never
  in preferences, logs or crash reports, and send it only to the address its
  authority names (`architecture.md` invariant 2).
- A v1 login is a **browser peer**, which defaults to `interactions:answer`, so
  approvals and questions do reach the phone through this cookie (the reference
  client is built exactly this way and its live tests answer approvals over it).
  The `/connect` operator peer is unnecessary for Cuplivo and cannot serve the
  WebView; one v1 credential covers `/api`, the mux and the WebView.
- Every `/api` request and the mux WebSocket must pass the **Host fence**:
  loopback authority, or one the Host was started with `--trusted-host`; the
  `Host` header must name that authority; `Origin`, when present, must be
  same-origin; `Sec-Fetch-Site: cross-site` is refused; `X-Forwarded-Host` /
  `X-Forwarded-Proto` must not appear. `dart:io` sends neither `Origin` nor
  `Sec-Fetch-*`, so a native client passes naturally — but the server needs
  `--trusted-host <authority>` when it is addressed by a LAN/TLS name.
- Server-side prerequisites for direct connection (E2E harness duty, not
  Cuplivo's): `dsh --profile web --host <one concrete local address> --port
  <port> [--trusted-host <authority> …] [--public-url <root>]`. Wildcard binds
  are rejected; `--public-url` only advertises, it grants no trust.

### 2.2 Unary RPC

```text
POST /api/<namespace>/<method>
content-type: application/json
cookie: dsh-auth-…=v1…

{"type":"client-request","rpcId":"<uuid>","method":"<namespace>/<method>",
 "payload":{"args":{…}}}

200 {"type":"server-response","rpcId":"<uuid>",
     "result":{"ok":true,"value":…}}          // "value" absent for void
200 {"type":"server-response","rpcId":"<uuid>",
     "result":{"ok":false,"error":{"code","message","details":{…}}}}
```

Rules that cost debugging time when missed:

- Argument names are the **wire names**, not TypeScript-friendly ones. Some are
  odd on purpose: `session/list` takes `{"_request":{}}`; every other session
  endpoint nests its request under `"request"`; `commands/execute` is flat
  (`agentId`, `line`, `submittedAttachments`).
- Business/gateway failures are **HTTP 200 with `result.ok: false`**. Only
  carrier refusals use 4xx: 401 (no/expired/mismatched cookie), 403 (Host/Origin
  fence), 404 (endpoint not mounted), 405 (wrong method), 413 (body too large),
  415 (content type). A client that maps 4xx to "network error" will report a
  stale token as an outage.
- `rpcId` is echoed; a success envelope with a different `rpcId` is a protocol
  error (a gateway validation failure may echo `invalid-request` instead, which
  must be accepted as an error answer).
- Bulk bodies are bounded by the Host: `/api` JSON bodies default to 300 MiB
  (`maxRequestBodyBytes`), the streamed upload route has no comparable bound.
- A result carrying bytes (e.g. `workspaceFiles/readBytes`, `officeToPdf/render`)
  answers `multipart/form-data`: a `metadata` field with the normal envelope
  (byte slots as `null`) plus one part per attachment (`bytes-N`), described by
  an `attachments` table in the metadata. Decode before parsing the envelope.

### 2.3 `remote.mux` — one WebSocket, many logical streams

`GET /api/remote.mux` upgrades to a WebSocket. One JSON object per text frame:

```text
client → host   {"type":"open","streamId":"<uuid>","endpoint":"<ns>/<method>",
                 "payload":{"args":{…}}}
                {"type":"item","streamId":"<uuid>","value":…}     // uplink
                {"type":"end","streamId":"<uuid>"}                // half-close
                {"type":"cancel","streamId":"<uuid>"}

host → client   {"type":"item","streamId":"<uuid>","value":…}
                {"type":"end","streamId":"<uuid>"}
                {"type":"error","streamId":"<uuid>",
                 "error":{"code","message","details"}}
```

- A stream endpoint is opened by name; the response type is whatever that
  endpoint yields per item (a `session/follow` frame, a `session/control` frame,
  a job list, …).
- `cancel` exists to end streams the client no longer needs (`session/follow`
  when leaving the chat, `job/follow`, `terminal/attach`, `userQuestions/attachWait`).
  Cancelling is mandatory cleanup, not an optimization: the Host keeps work
  alive per stream.
- The connection is a **generation**. The first logical stream a healthy
  connection opens is `$events`; its first item must be
  `{"type":"ready","clientId":"…","host":{"home":"…"}}`. Until `ready` arrives
  (Host deadline 15 s), the generation does not exist and no other stream may be
  assumed to work. Losing the socket loses every stream on it; nothing is
  replayed.
- Host → client heartbeat: a WebSocket ping every **2 s**, terminated after
  **2** missed pongs (≈4 s of silence). A client-side ping cadence of 15 s adds
  dead-link detection (`dart:io` answers Host pings automatically; set
  `pingInterval` and rely on it).
- Compression: the mux accepts `permessage-deflate` by default (`'deflate'`,
  level 1). `dart:io`'s `WebSocket.connect` negotiates and decodes it
  transparently. HTTP responses are **not** gzip by default
  (`webserver.compression: 'none'`), but a deployment may enable gzip; use
  `HttpClient.autoUncompress = true` and send `accept-encoding: gzip`.
  There is no brotli.
- Per-stream uplink is bounded: default `streamInboxBytes = 262144` (256 KiB) of
  buffered client frames; overflow fails the stream with
  `gateway/uplink-overflow`. Terminal keystrokes are tiny; a file/blob uplink
  must chunk under this bound or use the HTTP upload route.
- Frames larger than ~1 MiB are worth decoding off the UI isolate (the
  reference decodes them via `Isolate.run`); a `session/follow` snapshot can be
  several MiB on long sessions.

### 2.4 `$events` and host requests

`$events` is the Host-wide event stream. Each generation starts with `ready`,
then delivers three frame types:

```text
{"type":"emit","event":"<host-event>","args":[…]}          // fire and forget
{"type":"waterfall","event":"approval/request","eventId":"…","agentId":"<sessionId>",
 "request":{…}}                                            // expects an answer
{"type":"waterfall","event":"user-questions/request","eventId":"…","agentId":"…",
 "request":{…}}
{"type":"cancel","eventId":"…"}                            // withdraw an unanswered request
```

- A waterfall request is answered with the *unary* endpoint `$events/result`:

  ```json
  {"clientId":"<current generation ready.clientId>","eventId":"…",
   "outcome":{"kind":"result","value":{…}}}
  ```

  `{"kind":"next"}` declines (lets another client answer, or the Host's next
  answerer), `{"kind":"rejected","error":{"name","message","code"}}` rejects.
  The Host answers ok even when the request was already settled — handle that
  as success, not as an error.
- Requests pending when a generation is replaced are **redelivered to the new
  generation with the same `eventId`** (clientId changes, eventId does not).
  A client must key approval/question UI by `eventId`, not by client or
  generation, and drop entries on `cancel`.
- Host requests reach every peer whose `interactions` is `answer`; a v1 login
  (the browser peer Cuplivo uses, §2.1) defaults to `answer`, so no `/connect`
  operator cookie is needed. If the user has the official WebUI open in a
  browser on the same Host, both peers receive every request and the first
  answer wins — design for that, do not assume exclusivity.
- Known emit events are not a stable public API surface, but the ones a client
  caches on are listed in Appendix C. Unknown events must be ignored, never
  fatal.

### 2.5 Error taxonomy (`client-api.md` §3 is the contract)

The reference client's names differ from Cuplivo's frozen hierarchy; the
**column on the right is what the implementation uses** (`client-api.md` §3):

| Cuplivo class (`dsh_errors.dart`) | cause | user action |
|---|---|---|
| `DshRemoteException(code, message, details)` | Host answered `ok:false`, or a stream `error` frame (reference: same name) | depends on code; usually show text and keep the connection |
| `DshAuthException(statusCode?)` | carrier refused: 401/403 (or 409 on the mux upgrade); reference: `DshHttpException` | re-pair (paste a fresh WebUI URL); never retry silently |
| `DshUnsupportedException(endpoint)` | HTTP 404 / `gateway/method-not-found` | hide the capability (feature detection, §7.3) |
| `DshTransportException(cause, retryable)` | socket/DNS/TLS/timeout; reference: also `DshCarrierLostException` | retry; streams reopen through the mux |
| `DshProtocolException` | malformed envelope/frame/multipart | bug or version mismatch; log, fail the operation, do not loop |
| `DshEndpointException(field)` | bad pasted URL/token form | show next to the input field; no network call |
| `DshClosedException` | caller closed it | dispose silently |

Reference-to-Cuplivo mapping for reading `dsh-go` code: `DshHttpException` →
`DshAuthException` (401/403) or `DshUnsupportedException` (404);
`DshCarrierLostException` → `DshTransportException(retryable: true)` carrying
the mux's loss; everything else is the same idea under a different name.

Gateway codes worth mapping to UX (`gateway/…` prefix means the Remote
dispatcher, not a domain): `bad-request`, `arguments-invalid`, `internal`,
`method-not-found`/`not-found` (capability absent), `cancelled`,
`service-unavailable`, `peer-disposed`, `uplink-overflow`. Domain codes the chat
actually shows: `session/not-found`, `session/agent-busy`, `session/writer-held`,
`session/model-unavailable`, `session/provider-credentials-unavailable`,
`session/attachment-invalid`, `credential/rejected`, `settings/conflict`,
`permission/invalid-preset`, `plugin-manager/*`, `workspace/*`,
`directory-picker/*`, `terminal/*`. Appendix B has the fuller list.

### 2.6 HTTP extras used by the client

| route | purpose |
|---|---|
| `GET /` | the index page; also the only host of the boot graph `__DSH_BOOT__` used for version/capability detection |
| `GET /api/file?load=…` | authenticated file byte fetch for Markdown images/links; must be fetched with the cookie (a bare `Image.network` will 401) |
| `POST /api/session/uploadFileBinary?sessionId=&name=&mediaType=` | streamed raw-byte upload (`content-type: application/octet-stream`), answers bare `{ok,value:{receiptId,file|image}}` (not an RPC envelope) |
| `GET /api/session.export…` | session-log export download (the official `/export` command's target); optional for Cuplivo |
| `GET /connect?token=&interactions=` | 0.2.2 API-operator login (302 + v2 cookie) — exists, **not used** by Cuplivo |

Timeouts that the reference settled on after real-network failures (use these as
defaults, make them constants in one file):

| operation | timeout |
|---|---|
| TCP/TLS connect | 10 s |
| unary RPC | 120 s (request default), pass a shorter one for catalog reads (10–30 s) |
| WebSocket `ready` frame after upgrade | 15 s (Host's own default is 15 s) |
| `GET /` boot-graph read (activation/version probe) | 1–2 s bounded, max 4 MiB |
| activation throwaway follow first item | 2 s |
| model discovery (`llm/discoverModels`) | 30 s |
| file upload stream | up to 10 min, no total-body default |
| mux reconnect backoff caps | 500 ms, 1 s, 2 s, 4 s, 8 s, 10 s (then repeat), 50–100 % jitter |
| stop/cancel: give the Host 10 s, then offer "left running" | 10 s |

---

## 3. Feature-by-feature wire reference

Every table below was checked against the installed 0.2.2-rc.1 typings
(`*/lib/typert.remote-client.d.ts` and `*/lib/types/*.d.ts`). "Client use" says
what Cuplivo must do with it, "MVP" marks whether the brief's acceptance flow
needs it.

### 3.1 Connecting, the cookie, and the WebView's login

**URL parsing.** The user pastes the line `dsh web` printed, or just the URL,
with or without scheme (`例如127.0.0.1:3080/?token=…` in `ui-spec.md` R2). Accept:

- the whole `dsh web: http://host:port/?token=…` line or a bare URL;
- missing scheme ⇒ `http://`;
- require a `token` query parameter (otherwise the form says "缺少 token");
- keep the path as the mount path when the Host is served under one
  (`https://example.test/ui/?token=…` ⇒ base `https://example.test/ui`);
- drop `token` and every other query from the stored base URL. The **authority**
  (`host[:port]`, no scheme, no path) is what the cookie is bound to and what
  the UI shows as the connection address.

**Login** (one shot at pairing time, v1 — `architecture.md` invariant 2):

```text
GET /?token=<token>  (followRedirects: false, explicit Host header)
  → 303 Location: ./
    Set-Cookie: dsh-auth-<base64url(sha256(authority))>=v1.…
```

Do not follow the redirect (it points at a relative page load; following it is
harmless but pointless, and an API proxy that redirects would mask errors).
Parse the `Set-Cookie` whose name starts with `dsh-auth-`; if none arrived, fail
as a protocol error. Keep the whole `name=value` pair plus `authority` and
`expiresAt` (derived from `Max-Age`, ~30 days).

The 0.2.2 `/connect` route (`302` + `v2` operator cookie) is deliberately not
used: one v1 cookie authenticates `/api`, the mux and the WebView alike, and a
v1 peer already receives approvals (§2.4).

Then **prove the connection** in this order:

1. `GET /` with the cookie: 200 → authenticated; 401/403 → re-pair. This also
   yields the boot graph (§3.9) in the same round trip.
2. Open the mux and wait for `$events` `ready` (≤15 s). That is the real
   readiness: the WebSocket route mounts only after application readiness.

There is no health endpoint. Do not retry a rejected token in a loop; a token is
either current for this `dsh web` process or stale forever.

**When the cookie stops working** (401 on any request, or
`DshCarrierRefusedException` from a tunnel): the remote enters
`failed(credential)` and the UI asks for a fresh WebUI URL. Never keep a token
after the connect attempt; never display it.

**WebView authentication** (plugin pages, right-rail plugin panels). DSH Web has
no URL router and no per-plugin URL, so the WebView must load the Host's own page
at the real authority and be authenticated by its cookie jar:

- **inject the stored v1 cookie before the first load**: name = the stored
  `dsh-auth-…`, value, domain = authority host, path = `/`, expiry from the
  stored instant, `isSecure` = scheme is https, `isHttpOnly = true`,
  `sameSite = SameSite.strict` — `flutter_inappwebview`'s
  `CookieManager.setCookie` (Cuplivo already depends on it) exposes all of these;
  `webview_flutter` has a per-platform cookie manager too;
- if a platform refuses to set an `HttpOnly` cookie from the native side, set the
  same name/value **without** `HttpOnly`: the attribute only governs JavaScript
  visibility and the Host accepts any correctly signed cookie;
- then load the base page (`http://<authority>/`) and read no data out of it;
- the launch-token URL (`GET /?token=…`) is *not* a WebView auth path for
  Cuplivo: the token is memory-only by invariant and is discarded after pairing.
  If the cookie is missing, the user re-pairs;
- The WebView needs no `Host` header rewrite for a direct connection. A future
  tunnel carrier would need a loopback forward whose `Host` names the real
  authority — the reference does exactly that for SSH
  (`Uri(scheme:'http', host:'127.0.0.1', port: forwardPort)`, `hostHeader:
  endpoint.authority`); out of scope now.

**Server prerequisite to document in the E2E harness**: a non-loopback direct
connection needs `--trusted-host <authority>`; otherwise every `/api` request is
403 even though the page loads. The WebView shows the same refusal.

### 3.2 Sessions: list, create, follow, page, prompt, cancel

All session endpoints take their request object under `"request"` except
`session/list` (`"_request"`, may be omitted) and `session/modelCatalog`.

| endpoint | kind | args | result / value | MVP |
|---|---|---|---|---|
| `session/list` | unary | `{"_request":{}}` (`cursor` accepted, currently returns everything) | `{items:[SessionSummary]}` ordered by `updatedAt` desc | ✓ |
| `session/create` | unary | `{request:{workspaceId? xor cwd?, sessionId?, agentPreset?}}` | `{sessionId, agentPreset?}` — may reuse a stored blank session, so **the returned id is authoritative** | ✓ |
| `session/follow` | mux stream | `{request:{address:{kind:'session',sessionId}, assistantStream?, maxMessages?, turnWindow?, activate?}}` | `snapshot` then event/assistant-stream frames | ✓ |
| `session/page` | unary | `{request:{address, throughSeq?, beforeSeq?, maxMessages?, turnWindow?}}` | `{records, hasMore}` — one contiguous backwards page | ✓ (older history) |
| `session/events` | unary | same as page (0.2.2 addition) | same | — (page is enough) |
| `session/prompt` | unary | `{request:{requestId, sessionId, mode:'queue'\|'steer', content:[…], clientTimeZone?}}` | `{accepted:true}` | ✓ |
| `session/cancel` | unary | `{request:{sessionId}}` | `{accepted:true}` | ✓ |
| `session/updateQueue` | unary | `{request:{sessionId, itemId, action:{kind:'edit'\|'remove'\|'steer', content?}}}` | `{accepted:true}` | optional |
| `session/rename` | unary | `{request:{sessionId, title}}` | `{title, seq}` | ✓ (title edit) |
| `session/fork` | unary | `{request:{sessionId, atSeq?, allowMigration?}}` | `{sessionId}` | optional |
| `session/search` | unary | `{request:{query}}` | `{items:[{sessionId, snippet}], hasMore}` (max 20) | optional |
| `session/attachment` | unary | `{request:{sessionId, attachment:<full ImageAttachmentRef>}}` | `{attachment, data:<base64>}` | ✓ (images in history) |
| `session/projections` | unary | `{request:{sessionId}}` | `{asOfSeq, values}` or `null` | optional |
| `session/state` | unary | `{request:{sessionId}}` | `{cursor, active, running, queue, pendingInput}` | optional |
| `session/wait` | unary | `{request:{sessionId, timeoutMs?, afterSeq?, maxMessages?}}` | stopping-state snapshot + output | optional |
| `session/observeState`, `…Projections`, `…Event` | mux stream | same as their unary forms | frames | optional |
| `session/initializeDefaultModel` | unary | `{}` | `void` | optional |
| `session/canOpenWorkspacePath`, `session/openWorkspacePath`, `session/workspacePathApplications` | unary | host-desktop interactions | — | ✗ (no desktop on a phone) |

`SessionSummary` (0.2.2):

```json
{"sessionId":"…","updatedAt":1760000000000,"running":false,"blank":true,
 "agentAvailable":false,"cwd":"/home/me/ws","parentSessionId":null,
 "origin":null,"formatStatus":"current",
 "projections":{"kind":"sequenced","asOfSeq":123,
                "values":{"title":"…","sessionListMetadata":{"blank":false,…}}}}
```

- `updatedAt` is **epoch milliseconds**; `blank` means "no turn yet" (the new
  conversation empty state); `agentAvailable` says whether a live agent exists
  (false does not mean the session is unusable — it activates on interaction).
- `projections` is an optimization for list rows. `kind:'cached'` values may be
  stale/partial, `kind:'sequenced'` are complete at `asOfSeq`. Render a title
  from it when present, otherwise fall back to "新会话".

**Creating a session** (R5's `新会话` and the empty state): call
`session/create` without `sessionId` and with either `workspaceId` (a workspace
section's new-session) or nothing (the host default workspace). The returned id
is the session to open. Do not mint an id client-side; the Host owns identity.

**Prompting a cold session — activation.** The session exists on disk but has
no live agent until something interacts with it. The reference's recipe
(`session_activation.dart`), which Cuplivo must copy:

1. Only for an *interactive* intent (send, or opening a chat the user will act
   in), never for passive reads.
2. Check the release once per generation: read `GET /`, parse the boot graph
   (`__DSH_BOOT__`) for `release.version`; accept when the version supports
   `activate` (0.2.2-alpha.2 / 0.2.2-rc.1 in the reference; every 0.2.2 release
   qualifies). Cache the verdict per generation; an unknown/older Host disables
   activation and the client proceeds without it.
3. Open a throwaway stream
   `session/follow {request:{address:{kind:'session',sessionId}, activate:true,
   maxMessages:1}}`, wait for its first `snapshot` (2 s bound), cancel the
   stream. Never use this stream for rendering.
4. Then send the prompt. Failure of activation discovery must not fail the
   chat; the prompt will surface the Host's own error in that case.

Rationale: without a live agent, `session/prompt` can answer `session/agent-busy`
or queue work that never starts. The reference hit this in real use; the
`activate` field is the supported way to promote a background session.

**The transcript stream (`session/follow`)** — the single most important
endpoint. One mux stream yields:

- first frame (always): `{"type":"snapshot","header":{…},"cursor":<seq>,
  "records":[{"type":"event","event":<SessionWireEvent>} …],"hasMore":bool,
  "projections":{…},"assistantStream":{"revision":n,"activeAttempt":{…}}?}`
- then `{"type":"event","event":{…}}` for each durable event, and
  `{"type":"assistant-stream","frame":{…}}` when `assistantStream:true`.
- Snapshot defaults the reference uses (and the official web client): initial
  window `maxMessages: 500`, `turnWindow: {minMessages:50, minTurns:2}`,
  `assistantStream: true`. `hasMore` means the snapshot starts mid-log; older
  history is fetched with `session/page` (§4.3).

Apply order is part of the contract: **the snapshot first** (it establishes
cursor and projections), then events strictly by `seq`. A second snapshot on the
same stream is a protocol error, not an update.

**Sending a prompt**:

```json
{"request":{
  "requestId":"<uuid v4 minted by the client>",
  "sessionId":"…",
  "mode":"queue",
  "content":[{"type":"text","text":"…"},
             {"type":"image","mediaType":"image/png","data":"<base64>","name":"a.png"},
             {"type":"file","receiptId":"<from the upload route>"}],
  "clientTimeZone":"Asia/Shanghai"}}
→ {"accepted": true}
```

- `requestId` is the reconciliation key: it reappears on the durable
  `user/message` as `data.source.rpcId`, so an optimistic bubble replaces itself
  instead of duplicating (§5.2). Mint one per send and keep it until the echo
  arrives (or the send is abandoned).
- `mode:'queue'` is the normal send while a turn runs; `'steer'` injects into
  the running turn (long-press on the send button in the reference).
- `content` needs at least one text part with non-whitespace or an attachment.
  Images go inline as base64 (`image` part) up to the Host's image limits from
  the `imageLimits` projection; files must be staged first and passed by
  `receiptId`.
- A prompt can fail with `session/agent-busy` (another writer holds the turn? no
  — busy means the agent is not accepting this mode), `session/writer-held`,
  `session/model-unavailable`, `session/provider-credentials-unavailable`,
  `session/attachment-invalid`, `agent-preset/conflict`. Show the mapped text
  (§2.5) and keep the composer draft.

**Stopping**: `session/cancel` only *requests* cancellation; the turn ends with
a `turn/end` event whose `reason` says cancelled/error/complete. Give it 10 s
and then show "仍在运行" (the reference's timeout). The durable
`assistant/message` keeps the delivered prefix with `interrupted: true` when the
turn was cut; render the prefix, not a retraction.

### 3.3 The transcript: durable event vocabulary a chat renders

`SessionWireEvent` envelope:

```json
{"type":"assistant/message","seq":42,"time":1760000000000,"data":{…},
 "surfaceOp":"append"}                       // surface events only
```

- `surfaceOp` exists for the five *surface-eligible* types (`system/message`,
  `developer/message`, `user/message`, `assistant/message`, `tool/result`):
  `'append'` or `{op:'replace',startSeq,endSeq}`. **Human transcripts render
  append-origin events only**; replacement copies exist for the model's
  context and would otherwise duplicate or erase what the user saw. Absent
  `surfaceOp` (older Hosts) ⇒ treat as append.
- `ignorable: true` marks unknown/future events whose loss does not break the
  transcript. Keep advancing `seq`, but skip rendering. Never drop `seq`
  continuity — a gap triggers a history refetch (§4.3).
- `seq` is dense within a session; ordering is by `seq`, never by `time`.

Events a chat view consumes (data shape after `data`):

| event | data | rendering |
|---|---|---|
| `turn/start` | `{turn}` | start of a turn (for grouping/folding); optional notice |
| `turn/end` | `{turn, reason:{kind, …}}` | stop/error/complete notice; `reason.kind` decides the card |
| `step/start` / `step/end` | `{turn, step}` | optional (progress/thinking indicator) |
| `user/message` | full `Message` at `data` root (`parts`, `source{k:RpcId?}`, `id`, `role`) | user bubble; synthetic (non-`user`-source) messages hidden by default |
| `assistant/message` | `{turn, step, message:<Message>, usage?, interrupted?}` | assistant text + reasoning; the durable replacement for the streamed draft |
| `assistant/attempt` | `{turn, step, attemptId, …}` | optional; marks a retried/abandoned attempt |
| `tool/call` | `{turn, step, callId, name, arguments:"<json>"}` | tool card start (status running) |
| `tool/result` | `{turn, step, message:<Message>, error?:{name,code,reason}}` | tool card result (success/failure); `message.parts` holds text/images |
| `session/title` | `{title, source:{kind}}` | app bar title (or projection `title`) |
| `model/selection` | `{provider, model, reasoningEffort?}` | model chip state |
| `permission/preset` | `{preset}` | permission control state |
| `sandbox/mode` / `approval/policy` | `{mode}` / `{policy}` | permission detail only |
| `approval/asked` / `approval/decided` | `{id, toolName, callId?, reason?}` / `{id, outcome}` | approval history; live requests arrive as `$events` waterfalls (§3.4) |
| `agent/inbox/spliced` | `{target:'next-turn'\|'next-step', start, removedCount, inserted:[Message], outcome?}` | queued/steering prompts in the composer dock |
| `todo/write` | `{todos:[{content, status, …}]}` | todo strip above the composer (official feature; optional MVP) |
| `llm/retry` | `{turn, step, retry, maxRetries, delayMs, failure}` | transient "重试中" notice |
| `command/run` / `command/done` | `{commandId, name, args?}` / `{commandId, result}` | slash-command result row (and `/permission` feedback) |
| `compaction/*`, `goal/change`, `plan/mode`, `deliverables/presented`, `feedback/*`, `subagent/*`, `job/*`, `hook/*` | varies | not needed by the brief's acceptance flow; ignore (unknown) |

`Message.parts` entries are `{type:'text',text}`, `{type:'reasoning',text}`,
`{type:'tool-call',…}`, `{type:'image',attachment:{attachmentId,mediaType,bytes,
width,height,name?}}`, `{type:'file',attachment:{…}}`; see the reference's
`models.dart` for the tolerant parser (parts may be a string in older hosts).
Images are **references**, not URLs: fetch bytes with `session/attachment` or
`/api/file` (§2.6) using the cookie.

### 3.4 Approvals and questions (the cards that block a turn)

Requests arrive on `$events` as waterfalls and are **not** in the session log
(only their `approval/asked`/`approval/decided` audit events are).

`approval/request` payload:

```json
{"toolName":"bash","callId":"…","reason":"…",
 "displayReason":{"en":"…","zh":"…"}}
```

Answer through `$events/result` (current generation's `clientId`):

```json
{"kind":"result","value":{"kind":"allowed-once"}}   // approve once
{"kind":"result","value":{"kind":"rejected"}}       // reject
{"kind":"next"}                                     // let another client answer
```

Outcome values in the audit vocabulary: `allowed-once`, `rejected`, `cancelled`,
`unavailable`. There is no "always allow" in this release; a product that wants
a blanket grant must switch the session permission preset (§3.5).

`user-questions/request` payload: `{questions:[{id, question, detail?, header?,
options?:[{label, description?}], multiSelect?, intent?}], wait?:{callId, timed?}}`.

- Answer with `{kind:'result', value:{answers:[{id, selected:[<labels>],
  custom?}]}}`.
- `intent.kind === 'plan-review'` means `detail` is the plan markdown and
  `intent.approve` names the approving option; `intent.kind === 'approval'`
  (new in 0.2.2) is a fixed approve/reject/always card with localized
  `display` text and an optional `subject` icon/name. Render these as the cards
  the official UI renders — a generic option list is also valid (the intent
  changes presentation only; the answer encoding is identical).
- `wait.timed` = the tool call is blocked on a foreground wait; a claimed timed
  wait uses `userQuestions/attachWait {agentId, callId}` (stream, cancel to
  release) and can be answered late via `userQuestions/answer {agentId, callId,
  answer}` when the projection says `state:'continued'`.
- Reject with `{kind:'rejected', error:{name:'UserQuestionError',
  message:'declined', code?}}` if the user dismisses it; for a timed wait the
  reference uses `ASK_TIMED_OUT`.

Client discipline: key pending requests by `eventId`; dedupe redeliveries across
generations; drop on `cancel`; after a new generation wait 3 s for redeliveries
before retracting cards that are no longer pending (§4.5).

### 3.5 Models and reasoning effort

| endpoint | kind | args | value |
|---|---|---|---|
| `session/modelCatalog` | unary | `{}` | `ModelCatalog` |
| `session/selectModel` | unary | `{request:{sessionId, provider, model, reasoningEffort?}}` | `{selected:{provider, model, reasoningEffort?}}` (0.2.2) |
| `session/initializeDefaultModel` | unary | `{}` | `void` (0.2.2; was `selectModel.defaultSave`) |

```json
{"default":{"provider":"deepseek","model":"deepseek-chat"},
 "routableProviders":["deepseek","anthropic"],
 "groups":[{"id":"deepseek","name":"DeepSeek",
            "models":[{"id":"deepseek-reasoner","name":"DeepSeek Reasoner",
                       "description":"…",
                       "reasoning":{"efforts":[{"id":"low","name":"低"},
                                               {"id":"medium","name":"中"},
                                               {"id":"high","name":"高"}],
                                    "defaultEffort":"medium"},
                       "badge":{"text":{"en":"…"},"tone":"info"}}]}],
 "failures":[{"id":"openrouter","name":"OpenRouter","message":"…"}]}
```

- The list is **the remote's truth**: no static model table, no Cuplivo-side
  model metadata, no fallback ids. `groups` are rendered as-is (provider name +
  models); `failures` are rendered as disabled provider rows with the message —
  parity says the user must see that a provider failed rather than silently
  losing it.
- Reasoning efforts come from `model.reasoning.efforts` (`id` is the wire value,
  `name` is display text); `defaultEffort` is the starting point. A model with no
  `reasoning` offers no effort control. If a stored effort is not in the list,
  fall back to `defaultEffort` → `medium` → first non-`off` effort → omit
  (the reference's `startingEffort`); never send an effort the catalog does not
  advertise.
- The session's current selection comes from the `modelSelection` projection
  (`{lastUsed, next}`), not from the catalog's `default`; the catalog default is
  only for a session that never selected one. After `selectModel`, update the
  chip from `selected` and from the projection frame that follows.
- `session/selectModel` may fail with `session/model-unavailable` (provider or
  model gone) or `session/provider-credentials-unavailable`; on failure keep the
  old chip and show the reason — the Host did not switch.
- `defaultSave` is gone in 0.2.2: older clients' "set as default for new
  sessions" must call `session/initializeDefaultModel` if such a feature is
  wanted. Cuplivo does not need it (each session's selection is explicit).

### 3.6 Permissions (three levels, exactly as the brief wants)

| endpoint | kind | args | value |
|---|---|---|---|
| `permissionPresets/catalog` | unary | `{}` | `{options:[PresetOption], defaultOptions:[PresetOption], defaultPreset}` |
| `commands/execute` | unary | `{agentId:<sessionId>, line:"/permission <value>", submittedAttachments:[]}` | `{commandId, result:{kind:'success'\|'error', text?}}` |
| `settings/describe` + `settings/mutate` | unary | see §3.7 | default new-session preset |

`PresetOption` is `{value, name, description?}`; the installed profile ships
exactly the brief's three levels (§ base composition):

```json
{"options":[{"value":"read-only","name":"…","description":"…"},
            {"value":"workspace-write","name":"…"},
            {"value":"danger-full-access","name":"…"}],
 "defaultOptions":[…],"defaultPreset":"workspace-write"}
```

- The **session's current value** is the `permissions` projection:
  `{currentValue: "read-only"|"workspace-write"|"danger-full-access"|"auto"|"custom"}`.
  `auto` and `custom` are valid current values that may not be in `options`;
  render the label from `options` when present, else a neutral label for the raw
  value. Key absence means no permission service is composed — hide the control
  (capability parity), do not invent a default.
- **Changing the session's permission is a command, not an RPC.** Send
  `/permission <value>` with `commands/execute`; the answer `{kind:'success'}`
  means accepted, `{kind:'error', text}` is shown verbatim. The session log then
  carries `permission/preset` and a `session/control` projection frame updates
  the control. This is exactly what the official UI does (`live.command()`),
  and it is the only supported path in 0.2.2.
- `danger-full-access` (and `auto`) require an explicit confirmation in the
  official UI (a risk dialog with an acknowledgement checkbox). Cuplivo's
  confirmation copy can be its own, but it must not switch the control silently;
  keep the same friction.
- **The default for new sessions** is a settings write:
  `settings/mutate` with `ns:"permission"`,
  `ops:[{op:"set", path:["defaultPreset"], value:"workspace-write"}]`, and the
  `expectedRevision` from the `permission` namespace view. It is a `volatile`
  setting (applies live, not persisted to a config file by the Host). This is
  one of the two settings surfaces the brief wants native (R8).
- `/permission` is also listed by `commands/list`, so the composer's slash menu
  shows it like any other command; the dedicated control in the composer is the
  shortcut the brief asks for.

### 3.7 Engine settings (the two native settings and the settings machinery)

| endpoint | kind | args | value |
|---|---|---|---|
| `settings/describe` | unary | `{}` | `{writable, hasDocument, namespaces:[SettingsNamespaceView]}` |
| `settings/mutate` | unary | `{ns, ops:[{op:'set',path:[…],value} \| {op:'unset',path}], expectedRevision?}` | updated namespace view |
| `settings/update` | unary | `{ns, patch, expectedRevision?}` | updated view (merges one object level; prefer `mutate`) |
| `settings/replace` | unary | `{ns, section, expectedRevision?}` | replaces the whole section (avoid: destroys unknown fields) |
| `credential(s)/describe` | unary | `{refs:[…]}` (0.2.2: `credential(s)/describe`; reference used `credentials/describe`) | `{ref:{configured, source?, writable}}` |
| `credentials/set` / `credentials/unset` | unary | `{ref, value}` / `{ref}` | `void` |

`SettingsNamespaceView`:

```json
{"ns":"session-log-deepseek","revision":7,"writable":true,"applies":"live",
 "schema":{…schemastery JSON…},
 "value":{…resolved: defaults → base → user…},
 "base":{…composition base…},"user":{…raw user section, absent if none…},
 "secrets":[{"path":["apiKey"],"set":true}],
 "autoGenerate":true,"hasDocument":false}
```

- `schema` is a **schemastery** JSON tree (`{type:'object',dict:{…},
  meta:{…}}`), not JSON Schema. A native settings editor needs a small renderer
  for `object`/`union`(enum)/`const`/`string`/`number`/`boolean`/`array`/`dict`,
  plus `meta.description`, `meta.role === 'secret'` (never echo the value),
  `meta.role === 'credential-ref'` (render a credential picker), and
  `meta.default`. The reference's `engine_settings_api.dart` is a complete
  implementation of that viewer (not to be copied, but the semantics are the
  spec).
- `revision` is the CAS token: **always** send the revision you read; on
  `settings/conflict` re-read the namespace and re-apply the user's intent, or
  ask. Never retry a mutation with a stale revision.
- `writable:false` (or namespace-level `writable:false` in the reference's older
  shape) disables every write control — read-only deployment.
- `secrets[].path` lists schema-declared secret slots with only `set: boolean`;
  secrets never ride the wire. A settings UI shows "已设置/未设置" plus a
  "清除" action (`{op:'unset'}`), not a masked value it cannot obtain.
- Unknown fields must survive: write only the paths the user edited
  (`settings/mutate` path ops), never `replace` with a value built from
  `value` (which is redacted/resolved and would bake defaults in). The
  reference's provider editing exists specifically to enforce this.

**The two native settings the brief names** (R8):

| setting | namespace | key | default | write |
|---|---|---|---|---|
| 选择新会话的默认权限限制 | `permission` | `defaultPreset` | `"auto"` (catalog's effective default) | `settings/mutate ns=permission path=[defaultPreset]` |
| 在使用官方模型API时上传Session Log | `session-log-deepseek` | `enabled` (volatile bool), `maxBytes` (bytes, default 8 MiB) | `true` | `settings/mutate ns=session-log-deepseek path=[enabled]` |

Everything else in `settings/describe` is intentionally **hidden** in Cuplivo:
the official rendering settings (language, appearance, fonts, working-step
display, code view, shortcuts…) are governed by Cuplivo's own settings, and the
brief says so (R8). Do not render a generic settings list; render exactly these
two, plus plugin settings entry points (§3.9).

`settings/document-updated {ns, revision}` on `$events` invalidates the cached
describe; `credentials/reference-updated {ref}` invalidates credential state.

### 3.8 Providers: the built-in/custom provider catalog and CRUD

The model provider list is not a single endpoint; it is a merge of three sources,
exactly as the official settings page does it:

| endpoint | kind | args | value |
|---|---|---|---|
| `llm/listProviders` | unary | `{}` | `[{id, name}]` — routes with a registered, live adapter |
| `llm/listConfigurableProviders` | unary | `{}` | `[{provider, displayName, settingsNs, settingsPath, declared?, defaultBaseURL?, baseURLEnv?, nativeAuth?, error?}]` |
| `settings/describe` | unary | `{}` | all namespaces, including each provider adapter's (`llm-deepseek`, `llm-pi-ai`, …) |
| `settings/mutate` | unary | path ops | writes one profile / one field |
| `credentials/describe` / `credentials/set` | unary | refs | API-key state and write |
| `llm/discoverModels` | unary | `{settingsNs, request:{provider?, baseURL?, api?, apiKey?}}` | `[{id, name?, contextWindow?, maxTokens?, inputModalities?}]` |

Merge recipe (copy it; it matches the official R9–R11 pages):

1. Configurable providers from `llm/listConfigurableProviders`, joined with
   registered ones from `llm/listProviders` (a registered route with no
   configurable entry still appears, marked active).
2. Order: `deepseek-account` first, `deepseek-official` second, then the rest
   alphabetically. (R10 expects the alphabetical list and `自定义提供商` as the
   first *action* row; the account row is optional for Cuplivo, see below.)
3. A provider's configuration comes from `settings/describe` namespace
   `settingsNs` at `settingsPath` (for `llm-pi-ai`, the section root is a
   `providers` dict keyed by route). Fields as in §7.4: `api`, `baseURL`,
   `apiKeyEnv`, `models[]`, `headers`, `modelOverrides`, `defaultInput`,
   `defaultContextWindow`, `defaultMaxTokens`, and many adapter knobs Cuplivo
   should display only where the brief requires them.
4. Credential state: the profile's `apiKeyEnv` names a credential ref; when it
   is absent the official page derives `<ROUTE>_API_KEY`
   (`deriveKeyRef` = uppercase, non-alphanumerics → `_`, + `_API_KEY`) and, for
   routes with `nativeAuth`, also checks those env refs. Read the state with
   `credentials/describe`, write with `credentials/set` (never store the key in
   settings JSON).
5. "Custom provider" (`自定义提供商`) creates a route pi-ai ships nothing about:
   it **must** carry `api` (wire protocol), `baseURL`, and at least one model,
   and `apiKeyEnv` for its key. The protocol choices are read from the
   `llm-pi-ai` schema's `providers.<probe>.api` union — do not hard-code them.
   The installed adapter accepts `openai-completions`, `openai-responses`,
   `anthropic-messages` (verify from the schema at runtime; the value is part of
   the remote's truth, like models).
6. Model discovery for the draft being edited: `llm/discoverModels` with
   `{settingsNs, request:{baseURL, api, apiKey?}}` (no provider ⇒ a new route; a
   known route answers from adapter knowledge without network). Results are
   candidates to adopt into `models[]`, not stored automatically.

Provider CRUD writes:

- **create/replace a profile**: `settings/mutate ns=<settingsNs>`,
  `[{op:'set', path:[...settingsPath, 'providers', route], value:<profile>}]`
  (the value must include every field the user set; a new route must include
  `api`, `baseURL`, `models`).
- **edit fields**: one `set`/`unset` per edited path only — this is how unknown
  fields (`compat`, retry policy, unedited headers, future knobs) survive.
- **delete**: `unset` the profile path; the official page only offers delete for
  user-layer routes (`userRoutes − baseRoutes`), so a base-provided route shows
  as "reset to default", not delete.
- API key: `credentials/set` the ref; the profile stores only the ref name.
- Model rows: each carries `id`, optional `name`, `contextWindow`, `maxTokens`,
  `input` (`['text','image']`), and the pi-ai extras `reasoningEfforts`
  (`{level: value|null}`, `false` = non-reasoning). Reasoning levels offered by a
  *custom* provider are the adapter levels `off|minimal|low|medium|high|xhigh|max`
  filtered by the map; writing a level the adapter does not know breaks the
  whole adapter at the next start, so the reference drops unknown levels and
  writes `reasoningEfforts:false` when nothing usable remains. Cuplivo must not
  round-trip unknown levels.

`llm/adapters-updated` / `llm/models-updated` / `credentials/reference-updated`
on `$events` invalidate the provider and model caches. **The model list is only
for DSH chats** — never register a remote provider/model with Cuplivo's local
model catalog (brief: "模型不可用于本地对话").

Account login (DeepSeek OAuth via `account/startSignIn`, balance, bonuses) exists
in 0.2.2 but is an interactive browser/device flow with callback origins and
polling state; it is **out of MVP scope**. The models page should show the
`deepseek-account` row as it exists with an "登录需在官方网页完成" hint (or hide
it if the brief's reference has no login flow — it does not).

### 3.9 Workspaces and the session list grouping

| endpoint | kind | args | value |
|---|---|---|---|
| `workspace/follow` | mux stream | `{}` | `baseline` frame then increments (§ below) |
| `workspace/create` | unary | `{request:{path}}` | `{workspace, created}` |
| `workspace/rename` | unary | `{request:{workspaceId, title}}` | `{workspace}` |
| `workspace/delete` | unary | `{request:{workspaceId}}` | `{workspaceIds}` |
| `workspace/insertBefore` | unary | `{request:{workspaceId, beforeWorkspaceId?}}` | `{workspaceIds}` |
| `workspace/insertSessionBefore` | unary | `{request:{workspaceId, sessionId, beforeSessionId?}}` | `{workspace}` |
| `workspace/archiveSession` | unary | `{request:{sessionId, stopActivity?}}` | `{archivedSessionIds}` |
| `workspace/unarchiveSession` | unary | `{request:{sessionId}}` | `{archivedSessionIds}` |
| `workspace/pinSession` / `unpinSession` | unary | `{request:{sessionId}}` | `{pinnedSessionIds}` |
| `workspace/initializeDefault` | unary | `{}` | `{workspace}` or absent (0.2.2) |
| `directoryPicker/list` | unary | `{path?}` | `{path, home, crumbs, entries:[{name,path,hidden}], truncated}` |
| `directoryPicker/createDirectory` | unary | `{path, name}` | created path |
| `directoryPicker/pick` | unary | `{}` | host-native dialog; **not for a remote phone** |

`workspace/follow` frames (canonical):

```text
{"type":"baseline","value":{"items":[WorkspaceView],"archivedSessionIds":[…],
                            "pinnedSessionIds":[…]}}
{"type":"replace","value":<baseline>}                       // supersedes earlier state in this generation
{"type":"upsert","workspace":<WorkspaceView>}
{"type":"remove","workspaceId":"…"}
{"type":"order","workspaceIds":[…]}
{"type":"archived","archivedSessionIds":[…]}
{"type":"pinned","pinnedSessionIds":[…]}
```

`WorkspaceView{workspaceId, path, title, sessionIds, createdAt:ISO-8601,
updatedAt:ISO-8601}`. The sidebar's workspace sections come from this stream;
the session rows inside a workspace are the `session/list` items whose
`sessionId` is in `workspace.sessionIds`, in that manual order. Sessions that
belong to no workspace (or sit in the default one) need a `默认工作区` group —
the reference derives it from sessions whose `cwd`/workspace is the host
default, and the Host's `workspace/initializeDefault` can create the real one
(0.2.2). Archived ids are filtered out of the normal list and offered in an
"已归档" view; pinned ids sort first within their workspace.

- `workspace/create` takes an absolute path on the Host. The remote user must be
  able to browse that filesystem with `directoryPicker/list` (the app-internal
  browser; `pick` would open a dialog on the Host machine's desktop, useless
  remotely). R5's workspace adding flow should use `list`, not `pick`.
- `workspace/archiveSession` refuses with `workspace/session-active` when work is
  running; pass `stopActivity:true` only after a confirmation that names what
  stops (the error's `details.activity`).
- Renaming/deleting/ordering applies immediately; no optimistic reordering —
  apply the returned order.

### 3.10 Plugins, the boot graph, and what can be a native surface

| endpoint | kind | value |
|---|---|---|
| `pluginManager/listBundles` | unary | `[BundleInfo]` — installed/optional/on-demand bundles with `rows` |
| `pluginManager/listPlugins` | unary | `[PluginInfo]` — loader entries (`entryId`, `moduleName`, `meta`, `enabled`, `fiberPhase`, `patchId`/`readOnlyReason`) |
| `pluginManager/setBundleEnabled` | unary | `{name, enabled}` → `ChangeResult` |
| `pluginManager/setPluginEnabled` | unary | `{id, enabled}` → `ChangeResult` |
| `pluginManager/installBundle` / `removeBundle` / `inspect` / `waitForInstall` / `cancelInstall` | unary | installation lifecycle (`ChangeResult` with `application:'restart-required'` etc.) |
| `pluginManager/registries` | unary | install sources |
| `pluginInventory/list` | unary | `{managementAvailable?, entries:[PluginInventoryEntry], agentPresets?:[…]}` |
| `pluginManager/listVersions` / `readBundleDetail` / `updateBundle` / `listVersionExemptions` / `setVersionExemption` | unary | 0.2.2 additions (market/detail/update flows) |
| `pluginMarket/*`, `pluginRecommendations/*` | unary | 0.2.2 plugin marketplace (out of MVP) |
| `settings/describe` | unary | every plugin's settings namespace, schema and revision |

`BundleInfo` (abridged): `name, official, availability
('installation'|'profile'|'missing'), installTarget?, version?, meta?
{title,description: LocalizedText}, description?, enabled, installed, source?,
optional, removable, readOnlyReason?, error?, rows:[{rowId,moduleName,meta?,
entryId?}], overrides:[rowId]`. A row's `rowId` is also the plugin's settings
namespace and the loader entry id — the join key between "a bundle" and "its
configuration form".

**What is native vs WebView** (product rule: official UI native, plugin UI in
the WebView):

| surface | source | native? |
|---|---|---|
| plugin list, enable/disable, install/remove | `pluginManager/*` + `pluginInventory/list` | yes — Cuplivo list with toggles; apply `ChangeResult.application` ("需要重启 DSH 生效" when `restart-required`) |
| plugin configuration form | `settings/describe` namespace of the row + generated form | yes, when the namespace exists (schema-driven form, same viewer as engine settings) |
| plugin's own custom settings page / panel / sidebar entry / right-rail panel / composer extension | no API — the plugin's browser half renders it into the official page | **WebView only**, with a Flutter entry row when it can be listed |
| plugin market | `pluginMarket/*` + registries | optional, likely WebView/none in MVP |

There is **no remote endpoint that enumerates plugin-contributed UI slots**. The
reference solves this two ways and neither is available to Cuplivo without
installing a bridge plugin into DSH (which the product forbids):

1. Boot graph (`GET /`, `__DSH_BOOT__`) + `pluginManager/listBundles` tells you
   *which packages have a client half* (`entries[].id`, `external`, `batches`) —
   not their labels or slot positions.
2. dsh-go installs its own `dsh-go-bridge` Cordis plugin that publishes an
   occupancy table (`/dsh-go/v1/inventory`) and a native plugin protocol. Not our
   design.

So Cuplivo's honest capability set is:

- **R5's three sidebar entries** (插件 / 自动化任务 / 更多): render the rows in
  Flutter; 插件 opens the native plugin manager list described above; 自动化任务
  opens a native schedule list (`schedule/list`, §3.11) if built, else a WebView
  on the official automation panel; 更多 can be a small Flutter menu of official
  entries.
- **Plugin settings tabs** (R2's fourth tab `内容`): Flutter tab strip; each tab
  body is a WebView on the official settings page. Which tabs exist can only be
  discovered by the *official page itself*; two acceptable implementations:
  (a) one Flutter tab `插件` whose body is the official 插件 settings page
  (simple, robust, MVP); (b) one Flutter tab per plugin, discovered from
  `pluginManager/listBundles` + inventory names, landing the WebView on that
  plugin's page by label (§5.7). (b) needs DOM driving and is best-effort.
- **Right-rail plugin panels** (R7 decorations): the rail's official tool cards
  are Flutter; plugin contributions appear only if enumerated (same problem).
  MVP: rail shows the official native cards plus one `插件面板` entry that opens
  the official page in a WebView; do not fabricate per-plugin entries.

`plugin-manager/changed` and `plugin-manager/install-state|install-log|
update-state` events invalidate the list; `settings/document-updated` invalidates
plugin forms.

**Boot graph** (`GET /` HTML embeds
`<script>globalThis["__DSH_BOOT__"] = {…}</script>`, `<` escaped):

```json
{"release":{"version":"0.2.2-rc.1","commit":"…"},"rev":"…",
 "entries":[{"id":"@deepseek-ai/dsh-client-ui-chat","url":"…","rev":"…",
             "inject":[…],"external":[…],"immediately":true}],
 "packages":["@deepseek-ai/dsh-client-ui-chat", …],
 "batches":[…]}
```

It is the cheapest **version and client-package detector** (1–2 s bounded read,
no RPC, works before the mux is up). Parse as text; never execute the page.
`release.version` drives the activation gate and any version-specific branch;
`entries`/`packages` tell whether an official client half exists (for the
WebView entries) — nothing more. 0.2.2 adds `batches` (prefetch grouping) and
`packages` remains the flat list.

### 3.11 Commands, skills, and the composer's `+` menu

| endpoint | kind | args | value |
|---|---|---|---|
| `commands/list` | unary | `{agentId:<sessionId>}` | `[{definitionId?, name, description, input?:{hint, attachments?}}]` |
| `commands/execute` | unary | `{agentId, line, submittedAttachments:[]}` | `{commandId, result:{kind:'success'\|'error', text?}}` (or absent when the line did not match a command) |
| `skills/list` | unary | `{request:{sessionId}}` | `{skills:[{name, description, whenToUse?, path?, modelInvocable}]}` |
| `fileReferences/list` | unary | `{agentId, query}` | `[{…candidate}]` (for `@` mentions) |
| `sessionReferenceResolver/candidates` | unary | `{sessionId, query}` | conversation/subagent references (0.2.2) |

- The composer's `+` menu (R6) is built from these: **commands** (name +
  description, executed with `commands/execute` when picked and its `input`
  requires no free text; when `input` is present, insert `/<name> ` into the
  composer and let the user type), **skills** (insert `/<name> ` the same way the
  official UI does), and DSH attachments (file/photo staging, §3.12).
- A command execution produces durable `command/run`/`command/done` events, so
  the chat shows its outcome in place. `commands/change` invalidates the list.
- Effective commands/skills depend on the session's agent preset and cwd, which
  is why both take a session id. There is no "global commands" list worth
  caching across sessions.
- References (`@`): optional for MVP. If built, `fileReferences/list` is scoped
  to the agent; a picked file goes into the prompt as a `file` part only after
  being uploaded and staged (a path alone is not a prompt attachment).

### 3.12 Attachments, uploads, and the file route

| endpoint / route | kind | args | value |
|---|---|---|---|
| `fileUploads/upload` | unary | `{agentId:<sessionId>, request:{data:<base64>, name?}}` | `{receiptId, file:{attachmentId, name?, bytes}}` |
| `POST /api/session/uploadFileBinary?sessionId=&name=&mediaType=` | HTTP | raw bytes, `application/octet-stream` | bare `{ok:true,value:{receiptId,file}}` (or `{…,image}` when `mediaType` is set) |
| `session/attachment` | unary | full `ImageAttachmentRef` | `{attachment, data:<base64>}` |
| `GET /api/file?load=…` | HTTP | cookie | bytes with content-type (images, previews) |

- **Upload first, then prompt with the receipt.** The streamed route is the
  preferred one (no base64 in a JSON body); it answers a *bare* result object,
  not a `server-response` envelope, and errors as `{ok:false,error}`. If the
  route is absent (404), fall back to `fileUploads/upload` for small files only
  (base64 in one JSON frame; the reference caps it at 30 MiB).
- The response file can be a **file** receipt or, when `mediaType` was passed, an
  **image** receipt (`{receiptId, image}`). A prompt `file` part carries the
  receipt id; a staged image part enters the message as that image.
- Image parts in history are references: fetch with `session/attachment`
  (returns base64) or `/api/file` for Markdown targets. Always include the
  cookie; cache bytes in memory for the session's lifetime only (no disk cache —
  "remote means live").
- Cuplivo must not copy the bytes anywhere durable: the projection holds them
  for rendering, and they disappear with the session.

### 3.13 Supporting surfaces that R7/R5 can reach natively

These are not in the brief's screenshot flow but are named by the right rail or
sidebar entries, so the client should know their wire shape now.

**Workspace files** (right rail 工作区文件; R7 says official panels are native):

| endpoint | kind | args | value |
|---|---|---|---|
| `workspaceFiles/list` | unary | `{workspaceFileScopeId:<sessionId>, path}` | `{path, entries:[{name,path,kind,size?}], …}` |
| `workspaceFiles/read` | unary | `{workspaceFileScopeId, path, range:{…}}` | text page (offset/limit/lines) |
| `workspaceFiles/readBytes` | unary (multipart) | `{workspaceFileScopeId, path, options:{…}}` | bytes |
| `workspaceFiles/stat` | unary | `{workspaceFileScopeId, path}` | stat |
| `workspaceFiles/changes` | mux stream | `{workspaceFileScopeId, path}` | watch frames |

The scope id is the session id (the file root is the session's workspace). The
reference's `files_api.dart` shows the consumer side, including office→PDF
preview (`officeToPdf/render`) — out of scope for MVP; text/image preview is
enough for the rail.

**Terminal** (right rail 新建终端; full xterm surface is a large project[^1]):

| endpoint | kind | args | value |
|---|---|---|---|
| `terminal/shells` | unary | `{agentId:<sessionId>}` | `[{path,args,name}]` |
| `terminal/environment` | unary | `{agentId}` | `{cwd, maxInputBytes, maxBufferedBytes, maxCols, maxRows, scrollback}` |
| `terminal/list` | unary | `{sessionId}` | `[WebTerminalInfo]` |
| `terminal/create` | unary | `{agentId, request:{id, cols, rows, shellPath?}}` | `WebTerminalInfo` |
| `terminal/attach` | mux stream (uplink) | `{agentId, id}` | `snapshot` frame with the full screen + `inputWindow?`, then ordered `output`, `state`, `ack` frames |
| `terminal/retain` | mux stream | `{sessionId, id}` | keeps the process without taking the screen |
| `terminal/rename` / `terminal/close` | unary | `{agentId, id, title}` / `{agentId, id}` | void |

`terminal/attach` is the one endpoint with **client→host uplink**: send
`{type:'write',sequence,data}` and `{type:'resize',sequence,cols,rows}` as mux
`item` frames; sequences must be consecutive from 1; `ack` frames carry the
sequence and an optional refusal (`read-only`, `not-running`); the stream's
`inputWindow` (when present) bounds buffered input; an overflow fails the stream
with `gateway/uplink-overflow` (§2.3). A faithful terminal needs a VT renderer
(the reference has a dedicated terminal widget) — recommend a **read-only
terminal panel MVP** (attach without sending input) or deferring the card
entirely; do not ship a half-working shell.

**Automation (schedule)** (R5 自动化任务; optional):

| endpoint | mode | args |
|---|---|---|
| `schedule/catalog` | unary | `{}` → `[ScheduleCatalogEntry]` |
| `schedule/list` | unary | `{request:{active?, limit?, offset?}}` |
| `schedule/view` | unary | `{request:{id}}` |
| `schedule/history` | unary | `{request:{id, limit?, before?}}` (delivery runs) |
| `schedule/edit` | unary | `{request:{id, patch…}}` (title/prompt/schedule) |
| `schedule/run` | unary | `{request:{id}}` |
| `schedule/deleteInactive` | unary | `{}` |
| `schedule/deliveryLimits` | unary | `{}` |

0.2.2 replaced `schedule/delete`+`schedule/update` with `schedule/edit` and
`schedule/deleteInactive`, and split list harvesting into
`list`/`view`/`history`. `schedule/changed` invalidates. A read-only list (title,
next run, active, open session) is cheap and makes R5's entry real; creating
tasks still goes through the model, as the official UI does.

**Background jobs** (`job/list`, `job/follow`, `job/kill` scoped to a session)
feed the "N 个后台任务" chip the official UI shows; optional.

**Session log export / upload** — the second native setting (§3.7) is only about
the Host's own upload plugin (`session-log-deepseek`); there is nothing for
Cuplivo to upload. `/export` is a slash command that makes the Host produce a
download (`GET /api/session.export…`); Cuplivo can invoke the command and offer
the downloaded file, but this is optional and must not persist it.

**Message feedback** (`sessionFeedback/record`, `messageFeedback/…`) and goals
(`goals/*`) exist; out of scope per the brief (no goal bar, no 👍/👎).

### 3.14 What does not exist (do not invent controls for it)

| surface | reality in 0.2.2-rc.1 | Cuplivo action |
|---|---|---|
| browser sidebar / `浏览器` tool card | no `browser/*` remote namespace; the official browser panel is a desktop-only surface | hide the card, or render a Cuplivo in-app browser utility that is clearly not a DSH capability |
| plugin slot inventory (labels, rightbar occupancy) | no endpoint | derive entries from bundles/inventory only; WebView body; best-effort landing |
| "always allow" for one approval | not in the protocol (only `allowed-once`/`rejected`/`next`) | do not render an always-allow button; use the permission preset instead |
| open-in-desktop / native file dialogs (`session/openWorkspacePath`, `directoryPicker/pick`) | host-side interactive actions | hide on a remote phone |
| local session cache | product invariant forbids it | no offline transcript, no optimistic history |
| provider/model management for Cuplivo's own chats | product rule: DSH models are remote-only | keep the two model systems separate |

[^1]: A faithful terminal is a multi-week component (VT parser, scrollback,
  IME, selection). The right rail's value in the brief comes from the panel
  chrome and the official tool cards, not from a shell emulator; recommend
  landing the rail without a terminal card first, then adding a read-only
  attached terminal if the acceptance images demand the card.

---

## 4. Transport engineering: the parts that take weeks to rediscover

This section is the reference client's accumulated operational knowledge
(`connection.dart`, `carrier.dart`, `mux.dart`, `session_api.dart` and their
tests). Copy the *rules*, not the code.

### 4.1 Connection lifecycle: one mux, many generations

```text
idle ──start──► connecting ──ok: $events ready──► connected ──loss──► reconnecting ──…
  ▲                  │                                  │
  └──close───────────┴──401/403/fence──► unauthorized ──reconnect() after login──► connecting
```

- The **`DshMux` is created once per remote**, not per screen. It owns one
  WebSocket, the `$events` handshake, the generation counter, pending host
  requests, and reconnect backoff. Everything else subscribes.
- A **generation** exists only after the `$events` stream delivered `ready`
  (15 s deadline). `clientId` is bound to that generation and is required on
  `$events/result`; using an old one answers `gateway/client-unknown`.
- Reconnect backoff: caps `[500ms, 1s, 2s, 4s, 8s, 10s]`, each wait multiplied
  by 50–100 % jitter, reset to the first cap after a successful `ready`. This
  schedule is the official web client's; it is gentle on a laptop and a phone
  waking from sleep.
- **401/403 (or a carrier refusal) is terminal until the user acts.** Enter
  `unauthorized`, do not schedule retries (a stale token cannot heal), surface
  "连接已失效，请重新粘贴 WebUI 地址". After a new login call `reconnect()`,
  which drops any socket and starts immediately.
- **Nothing is replayed across sockets.** Emitted host notifications between
  generations are lost. Every logical stream must be reopened; a `session/follow`
  reopened after a loss starts with a snapshot again. Design the UI to treat a
  generation change as "rebuild from snapshots", not "resume".
- Make the **connection state a first-class value** (`connecting`, `connected`,
  `reconnecting`, `unauthorized`, `closed`, plus `lastError`) exposed as a
  `ValueListenable`/stream; the reference's `ConnectionState` drives the app's
  banner and disables the composer during `reconnecting`.
- Two independent timers must never fight: the mux's own reconnect owns the
  socket; screens never create sockets. A screen that "reconnects" is a bug.

### 4.2 Logical stream discipline

- Open streams through the mux by endpoint name; each open must be registered
  **before** any frame can arrive (the reference's `open` registers a
  subscription synchronously, then sends the frame; a late registration drops
  the first snapshot). In Dart this means: create the `StreamController`/subscription
  in the same synchronous block as `mux.open`.
- A stream's `items` completes on `end` and errors with a forwarded
  `DshRemoteException` on `error`; socket death fails **all** streams with
  `DshCarrierLostException`. A caller that treats `end` and error the same will
  loop on a Host-refused stream — distinguish them.
- Always `cancel()` streams the UI no longer shows (leaving the chat, closing a
  terminal, dismissing job detail): the Host keeps per-stream work alive.
- Reopen recipes:

| stream | reopened on generation change | starts with |
|---|---|---|
| `$events` | owned by the mux per generation | `ready` |
| `session/follow` | yes, if the screen still shows the session | fresh `snapshot` |
| `session/control` | yes | `baseline` |
| `workspace/follow` | yes | `baseline` |
| `terminal/attach` | yes (the screen re-attaches; the process survives) | `snapshot` |
| `job/follow`, `toolResults/watch`, `workspaceFiles/changes`, `userQuestions/attachWait` | yes | their own baseline/partial |

- **A refused open is data**: the `error` frame's code (`gateway/not-found`,
  `gateway/method-not-allowed`, a feature code) is how a client discovers a Host
  that does not have the feature. Cache the negative result per generation;
  don't retry a refused endpoint in a loop.

### 4.3 Sequencing, snapshots and history fill

A `session/follow` snapshot window is bounded: `maxMessages` (default 500 in the
client and the official page) and `turnWindow {minMessages:50, minTurns:2}` so
the cut falls on a turn boundary where possible. Snapshot frames carry
`records:[{type:'event',event}]` **in ascending `seq`** and `cursor` = the newest
covered seq. Live events continue from `cursor+1`.

Rules (all four are implemented in the reference's `_SessionWatch` and each one
was a real bug before it was a rule):

1. **Monotonic**: drop any durable event with `seq <= cursor`.
2. **Contiguous**: if `seq > cursor+1`, there is a hole. Repair with
   `session/page` before rendering the hole:
   `page(throughSeq: <gap end>, beforeSeq: <gap end>, maxMessages: 500)` walks
   backwards; keep pages until the first page's first seq is `<= cursor` or
   `hasMore` is false; reverse-concatenate; verify the filled range is exactly
   `cursor+1 … holeStart-1`. If the fill is empty or still has a hole → treat as
   a resync (new snapshot), never render out of order.
3. **Resync is a snapshot restart**: retire the current follow, cancel it, reopen
   (with backoff for back-to-back resyncs), apply the new snapshot. After
   **six** resyncs without a clean frame, fail the watch loudly (a persistent
   protocol mismatch must reach the user, not spin forever).
4. **Snapshot repair after reconnection**: when the new snapshot's
   `cursor > lastRenderedSeq`, its records may not reach back far enough
   (`firstRecordSeq > lastRenderedSeq+1`): fill the gap with `session/page`
   exactly as above before merging, so merging by seq never leaves holes.

`session/page` semantics (0.2.2): returns one contiguous page of durable events
ending at `throughSeq` (inclusive) and starting before `beforeSeq` (exclusive)
when given; `hasMore` means older events exist. The "load older history"
gesture is `page(throughSeq: <firstSeqOnScreen - 1>, maxMessages: 500)` (or
`beforeSeq` for an explicit pagination cursor); render prepended rows in `seq`
order and scroll-anchor. `TurnWindow`-based cuts are a Host concern; the client
only passes `maxMessages`/`turnWindow` if it wants a different window than the
official 500/50/2.

### 4.4 Reconstructing the live assistant draft

With `assistantStream:true`, the stream carries the model's in-flight output as
cursorless frames, separate from the durable log:

```text
{"type":"start","attemptId":"…","revision":1,"startedAfterSeq":41,"turn":2,"step":1}
{"type":"chunk","attemptId":"…","revision":2,"index":0,"time":…,
 "chunk":{"type":"block-start","index":0,"blockType":"text"}}
{"type":"chunk","attemptId":"…","revision":3,"index":1,"chunk":{"type":"text-delta","index":0,"text":"Hel"}}
…
{"type":"end","attemptId":"…","revision":n,"index":m,
 "outcome":{"kind":"committed","eventType":"assistant/message","seq":42}}
{"type":"end",…, "outcome":{"kind":"abandoned"}}          // retry/interruption
```

- `revision` is **exactly previous + 1 within a follow**. A skip means the follow
  is broken → resync (rule 3). Do not patch over it.
- `index` is dense per attempt (0,1,2,…) and orders chunks; `chunk.index` is the
  *content block* index (text block 0, reasoning block 1, a tool-call block 2…).
- Chunk kinds: `block-start{index,blockType}`, `text-delta{index,text}`,
  `reasoning-delta{index,text}`, `tool-call-delta{index,id,name,argumentsDelta}`,
  `block-end{index,block:<Part>}` (the assembled block — authoritative),
  `usage{usage}`, `finish{reason:{kind,failure?}}`, plus unknown (ignore).
- **Draft vs durable**: the draft is transient. When `end` commits with
  `seq`, the durable `assistant/message` event (or the next snapshot) replaces
  the draft wholesale. The reference gives the durable message the same row
  identity as the draft (`m<turn>.<step>`) so the widget swaps content without
  flicker and without a duplicate row. Do the same: one row per
  turn+step+assistant, not one per source.
- A snapshot's `assistantStream:{revision, activeAttempt?}` is the resume
  baseline: set the expected revision from it and, when `activeAttempt` exists,
  render an in-progress row immediately (a resync in the middle of a turn must
  not blank the answer).
- `finish.reason.failure` carries provider errors (`code`, `status`); surface as
  a retry notice, not a hard error — `llm/retry` events follow when the Host
  retries automatically.
- Stop (`session/cancel`) does not necessarily end the stream immediately: the
  Host may emit a final partial `end{committed, interrupted}`. Wait for the
  durable `turn/end` to leave the running state, with a 10 s cap.

### 4.5 Pending calls, host requests and their lifecycle

- Every unary call is one HTTP exchange (own timeout, own abort). Never share a
  timeout across calls; a 120 s timeout on a 200 ms catalog read hides bugs.
- Mux opens are tracked in a pending map keyed by `streamId` until the stream
  ends/cancels; a stale `item` for an unknown stream id is a protocol error in
  the reference (it closes the socket). Be strict: unknown stream ids indicate
  state desync.
- Host requests (approvals/questions) are the exception to "nothing replays":
  the Host **redelivers pending ones with the same `eventId`** on the next
  generation. Therefore:
  1. Key UI cards by `eventId`.
  2. On a new generation, wait a **3 s grace** for redeliveries, then retract
     cards that are no longer pending (`mux.pendingRequests` is the authority).
  3. When the local UI answers, call `resolvePendingRequest(eventId)` to forget
     it locally; the Host does not send a `cancel` to the answering client.
  4. On `cancel` frames remove the card and stop polling (there is nothing to
     poll — the card is event-driven).
- Answers use the current generation's `clientId`; a stale answer is the
  reference's documented retry case ("identifies no active event stream"): on
  that message, reopen `$events` (or wait for the next generation) and retry
  once. Do not loop.
- The composer's "queued prompt" state comes from the `inbox` projection and
  `agent/inbox/spliced` events; do not maintain a local queue that can drift
  from the Host's.

### 4.6 Timeouts, retries and their defaults

Centralize these in one constants file (`dsh_timeouts.dart`), as the reference
does. Values are the reference's proven defaults:

| constant | value | notes |
|---|---|---|
| connect (TCP/TLS + WS upgrade) | 10 s | `HttpClient.connectionTimeout` + WS handshake |
| unary request | 120 s | pass 10–30 s for catalogs |
| mux ready | 15 s | Host's own deadline; a timeout is a lost link |
| client ping | 15 s | plus `dart:io` auto-pong to Host pings every 2 s |
| HTTP idle (per read) | 15–20 s | body read stall, not total duration |
| stream upload | 600 s | long body, no total cap |
| activation probe | 2 s | throwaway follow first frame |
| boot graph read | 1–2 s, 4 MiB | version/capability detection |
| discovery | 30 s | `llm/discoverModels` |
| stop request | 10 s | then "still running" |
| reconnect caps | 500 ms … 10 s | jittered, reset on ready |
| resync cap | 6 | then surface a protocol error |
| host-request grace | 3 s | after new generation |
| background list read | 1 s budget in UI, isolate decode | startup latency |

Retry policy per error class: transport/protocol/5xx/408/429 with backoff up to
6 attempts (reference watch) or the mux's own schedule; a business `ok:false`
is **never** retried automatically (a rejected prompt must not send twice);
401/403 never retried.

### 4.7 Heartbeat and dead links

The Host pings every 2 s and terminates a socket after 2 missed pongs (~4 s).
`dart:io` answers pings automatically; set `pingInterval = 15 s` for the
client's own liveness check (a phone that sleeps through the Host's pings sees
the socket close and must reconnect). Do not implement an application-level
heartbeat: the WebSocket protocol has one, and a second one doubles the
traffic for no information. When the socket closes, rely on
`onDone`/`onError`; never poll `/api` to "check if connected".

### 4.8 Compression, sizes and where the CPU goes

- **WS**: `permessage-deflate` is enabled by default on the Host (`'deflate'`,
  zlib level 1). `dart:io`'s WebSocket negotiates and decompresses
  transparently — nothing to implement, but it means a long snapshot costs CPU
  on the UI isolate to *decode JSON*, not to decompress.
- **HTTP**: gzip is **off** by default (`webserver.compression:'none'`), optional
  per deployment (`'gzip'`, threshold 1024, SSE/multipart excluded). Set
  `autoUncompress = true` and `accept-encoding: gzip` so a compressed deployment
  costs nothing. Brotli is not implemented.
- Frame sizes (defaults): mux uplink per stream 256 KiB
  (`gateway/uplink-overflow` beyond); API JSON body 300 MiB; a `session/follow`
  snapshot on a long session can be several MiB. Decode frames above ~1 MiB off
  the UI isolate (`Isolate.run` with a JSON decode) exactly as the reference
  does; small control frames stay synchronous and preserve ordering.
- Uploads: stream raw bytes to `/api/session/uploadFileBinary`; never base64 a
  large file into a JSON body (the base64 `fileUploads/upload` path is the
  ≤30 MiB fallback only).
- Attachments in history are fetched per render; cache bytes in an
  LRU keyed by `attachmentId`, bounded by memory, cleared when the chat closes.
  There is no disk cache (invariant).

### 4.9 Error classification → UX (a single mapping table)

The client's UI state should be a pure function of classified errors, not of
raw exceptions:

| classification | UI state | recovery |
|---|---|---|
| `transport` (connect refused, timeout, TLS) | `offline/connecting` banner; composer disabled | automatic reconnect (mux) |
| `carrier-refused` 401/403 | `unauthorized` + "重新登录" | user pastes a new WebUI URL |
| `host business error` (`ok:false`) | toast/inline text on the action | user acts; no automatic retry |
| `stream error` (mux `error` frame) | stream-level notice (e.g. a terminal panel) | reopen the stream if it still matters |
| `protocol` / mux desync | chat-level "重新同步" | automatic resync; then a surfaced error |
| `carrier lost` | transient "重连中…"; streams reopen | automatic |
| `gateway/uplink-overflow` | terminal/job input warning | reduce input burst |
| `session/*` domain | mapped text on the composer/chat | depends: switch model, stop other tab, etc. |

The reference keeps two dedicated mappers (`chat_error_text.dart`,
`engine_error_text.dart`) with a code→localized-string switch and a fallback
that shows `code: message`. Cuplivo needs the same two (ARB strings), and a
fallback so an unknown new Host code is still legible.

### 4.10 Performance rules that keep the chat smooth

- **No polling loop anywhere.** Every list that the Host can change is cached
  and invalidated by a host event (`api-session/added|removed|status|activity`,
  `session/created|disposed`, `plugin-manager/changed`,
  `settings/document-updated`, `llm/*`, `workspace/*`, `commands/change`,
  `skills/change`, `permission-presets/catalog-changed`, `theme/change`,
  `locale/change`). The reference's `features_state.dart` is exactly this
  pattern (`_refreshOn([...])`), and it is why the app has no refresh buttons.
- **Watch `session/control` once, globally** (`baseline` + `projection` frames)
  to drive the session list's running dots, titles, permission and model chips
  without opening any session's transcript. A snapshot per session to draw a
  row is the anti-pattern.
- **Startup**: list sessions (and the model catalog/permission catalog) in
  parallel; the reference reads the session list in a background isolate so the
  first frame is not blocked by JSON decode. Budget: first list paint under 1 s
  on a warm connection; skeletons before that.
- **Folding is O(events) per snapshot, not per frame.** Apply each live event
  incrementally into the derived row list; do not re-fold the transcript on
  every token. The reference caches derived rows per transcript revision
  (`chat_rows_cache.dart`) and derives only when the transcript changed; a
  streaming draft updates one row.
- **Widget rebuild scope**: the chat screen watches a `select`ed tuple
  (transcript rows, running, permission, model, pending requests) rather than
  the whole controller; a token stream must not rebuild the sidebar.
- **Bounded memory**: scrollback of a chat is bounded by what the user loaded
  (start 500 messages, pages of 500 as they scroll); a 50k-event session must
  not be materialized because the mux delivered it — the snapshot does that
  already, so never fetch `page` eagerly for the whole history at open.
- Cancel every timer/subscription in `dispose`; the reference's states
  (`syncing`, `resyncing`, `streamLost`) are the visible consequences of getting
  disposal wrong.

### 4.11 Traps that cost the reference real debugging time

1. **The snapshot is not "history"; it is the state.** Any projection, title,
   running flag or pending request derived only from live events is wrong until
   the snapshot is applied. Apply it first, then enable controls.
2. **`seq`-ordered apply, not arrival-ordered.** A repaired history page may
   deliver older events after newer ones.
3. **A second snapshot on the same stream is an error**, not an update — a client
   that merges it silently will duplicate rows.
4. **Assistant revisions are per follow**, not per session: any reopen resets the
   expectation to the snapshot's `assistantStream.revision`.
5. **`eventId` is stable across generations, `clientId` is not.** Mixing them up
   makes approvals answerable only once per reconnect.
6. **401 is not "offline".** Classifying it as transport produces an infinite
   retry loop against a server that will never accept the token.
7. **The cookie is per authority and survives restarts; the launch token does
   not.** Never persist the token; never reuse a cookie for a different
   `host:port` (even the same machine).
8. **WebSocket `Origin`/`Host`/Sec-Fetch rules**: `dart:io` passes by default,
   but a hand-rolled `HttpClient` with a stray `Origin` header gets 403, and a
   reverse proxy that strips `Host` gets 403 too. Keep one `DshEndpoint` that
   owns the header policy.
9. **HTTP redirects**: login answers a 30x; the `/api` POSTs must not be
   redirected (a proxy redirect turns a POST into a GET and the RPC disappears).
   Disable redirect-following for API calls; allow it only in the login exchange
   and inspect it manually.
10. **`multipart/form-data` results** must be decoded before envelope parsing;
    a JSON parser on the multipart body produces a confusing protocol error.
11. **`Content-Length` and chunked**: `dart:io` handles it; a hand-built request
    must not set `Content-Length` for streamed uploads.
12. **Cancelling a stream is asynchronous**; after `cancel()` a late `item` for
    that stream id is normal in-flight traffic. Ignore frames for cancelled
    streams instead of closing the socket (the reference's strictness applies to
    ids it never opened).
13. **Do not open a second `session/follow` for the same session from the same
    client** ("watch" and "preview" both following it duplicates approvals).
    One owner per session id; screens share the controller.
14. **History fill can loop** if the Host's page keeps returning events outside
    the requested range; bound the loop (the reference breaks when a page's
    usable slice is empty) and fall back to a resync.

---

## 5. Reference pattern: mapping remote DSH state into a native chat UI

dsh-go's Flutter app is the only prior art that renders this protocol natively.
Its layering is worth copying structurally (not textually):

```text
DshClient (protocol: connection, carrier, rpc, mux, session api, models, transcript)
        │  typed events + pure transcript fold + projections
        ▼
Riverpod notifier per open chat (ChatState: sync flags, pending prompts, model, errors)
        │  ChatState
        ▼
derived rows (chat_rows.dart) ──► widgets (tool cards, marks, composer)
```

Its `ChatTranscript` (pure Dart, no Flutter) does the folding; the state notifier
holds transport/session lifecycle and user intents; widgets are stateless
renderers of a `ChatState`. Cuplivo should keep exactly that split — the
`lib/core/dsh/` layer is the left column, the feature layer the middle, the
widgets the right.

### 5.1 Who owns which piece of state

| state | source of truth | owner | persistence |
|---|---|---|---|
| connection/generation | mux (`states`, `generation`) | one `DshRemoteSession` per open remote | in memory |
| session list | `session/list` + `api-session/*` host events | app-level controller (shared by sidebar) | memory |
| projection control (`session/control`) | baseline + projection frames | app-level controller | memory |
| workspace rail | `workspace/follow` | app-level controller | memory |
| model catalog / permission catalog / plugin list / settings describe | unary reads + host events | app-level caches with generation-tagged invalidation | memory |
| one chat transcript | `session/follow` snapshot + events + `session/page` | per-session `DshChatController` | memory only |
| draft prompt text, staged attachments, selected mode (queue/steer) | Cuplivo UI | composer state (feature layer) | memory; never persisted for a remote |
| optimistic pending prompts | Cuplivo UI, reconciled by `requestId` | chat controller | memory |
| pending approvals/questions | `$events` waterfalls (authoritative) | chat controller keyed by `eventId` | memory |
| derived rows (turn grouping, tool cards) | transcript, memoized | chat controller | in memory, invalidated per transcript revision |
| cookie | channel layer | `DshRemoteStore` | `flutter_secure_storage` |
| launch token | login only | nowhere (never persisted) | — |
| remote profile (`DshRemote`) | Cuplivo settings | `DshRemoteStore` | settings DB |

Rules that prevent most bugs:

- **One owner per session id.** The sidebar may show a running dot from the
  control projection; it must not open its own follow for that session.
- **Controllers are created on chat open and disposed on chat close**; the mux
  and the catalogs outlive them. Leaving a chat cancels its follow and its
  `userQuestions/attachWait`; returning creates a fresh controller and gets a
  fresh snapshot (this is the remote-live product rule, not a cache miss).
- **UI reads derived data only**; no widget touches the mux or a raw event.

### 5.2 The event → transcript fold (copy these behaviors)

1. **Snapshot replaces, events append.** On a first snapshot: clear the log,
   store header/projections/cursor/inbox, apply records. On a resync snapshot:
   merge by `seq` (records may overlap already-rendered events) and never clear
   what the user is looking at until the new fold is ready.
2. **Replacement surface events are invisible to the human transcript**:
   `surfaceOp` present and not `append` ⇒ skip rendering (but keep `seq`).
   `ignorable:true` unknown events ⇒ keep `seq`, skip rendering.
3. **Tool calls are resolved globally, not per turn.** A `tool/result` may
   arrive after the turn ended (late approval, background job). Fold tools into
   a `callId → tool` map; the row builder reads that map. The reference keeps
   "unresolved tools" and marks them cancelled at `turn/end`.
4. **Optimistic prompt echo.** The send path adds a local prompt row keyed by
   `requestId`; when a `user/message` with `source.rpcId == requestId` lands, it
   replaces the optimistic row instead of adding a second one. A prompt that the
   Host placed in its inbox but has not yet materialized appears via the `inbox`
   projection / `agent/inbox/spliced`; the local row must merge with that queue
   entry too (the reference tracks positions and claimed seqs, including the
   hard case where a claim and its consumption both happen while disconnected —
   see `_trackSnapshotClaims`).
5. **Assistant draft replacement.** One row identity per turn+step
   (`m<turn>.<step>`); the streaming draft and the durable
   `assistant/message` share it. When the durable message arrives, the draft is
   dropped (see §4.4).
6. **Notices** come from `turn/end.reason`: completed → nothing; aborted →
   "已停止"; error → the error text + retry affordance; max-tokens → a hint;
   interrupted → "Host 重启导致中断". `llm/retry` adds a transient retry notice.
7. **Title** is the last `session/title` in the loaded log, else the `title`
   projection; a rename updates both.

### 5.3 Row derivation rules (the reference's `chat_rows.dart` contract)

The derived list is what the list view renders; keep it a pure function of the
transcript with memoized reuse.

- **Turns**: rows between `turn/start` and `turn/end` form one visual turn.
  Intermediate assistant messages (tool-driving steps) are the *process* of a
  turn; the final answer is the last assistant message of the turn (the
  reference's `isFinalAnswer`). Process rows are collapsed under a
  "思考过程/工具调用" header once the turn completes; the final answer stays
  expanded. This is the single largest readability win and is visible in the
  official UI too.
- **Tool grouping**: three or more consecutive tool calls collapse into one
  group card (`toolGroupThreshold = 3`), expandable; approval-pending or failed
  tools are never hidden inside a collapsed group.
- **Row keys are stable** (`rowKey`): `u<seq>` for user, `m<turn>.<step>` for
  assistant, `t<callId>` for tools, `n<seq>` for notices, `p<requestId>` for
  pending prompts. Stable keys let the Flutter list reuse elements and are what
  makes streaming (one changing row) cheap.
- **Ordering**: strictly by transcript order (`seq`); pending prompts render
  after the last durable row, in inbox order (steering first).
- **Markdown/rendering**: Cuplivo's own message renderer and theme (brief: reuse
  Cuplivo's rendering); the reference uses Cuplivo-like markdown blocks too.
  Math/code/table support comes from Cuplivo, not from DSH.
- **Footnotes/metadata**: model name, token usage and duration are optional
  secondary text under the final answer; the reference shows them collapsed.

### 5.4 Tool cards (status machine and views)

Statuses are derived, not transported: `streaming` (draft argues a tool call),
`running` (call without result), `awaitingApproval` (pending approval request
for the callId), `succeeded`, `failed` (result error), `denied` (approval
outcome not `allowed-once`), `cancelled` (turn ended without a result).

- The card shows the tool name (mapped to a friendly label per known name, raw
  otherwise), a one-line argument summary (parsed from `arguments` JSON; never
  show the raw JSON inline), status icon, duration, and an expandable body:
  result text (markdown), images (fetched by reference), and the failure
  message on error.
- Approval-pending cards carry the approval card inline (approve/deny) — the
  reference's `_AskUserToolCard` pattern. Questions render as their own card
  above the composer, not inside a tool row, when they are free-form.
- Long outputs are truncated with "展开全部"; a tool result that is a file
  attachment renders a download/open chip (bytes come from the attachment ref).
- Unknown tools render generically — never drop a call because its name is
  unknown (parity: the official UI shows them).

### 5.5 Approval and question cards

- Approval card content: tool name, `reason`/`displayReason` (prefer a localized
  `displayReason` matching the app locale, else `reason`), the call's argument
  summary, and two actions (`允许一次` / `拒绝`). Render "让其他客户端回答" as
  a dismiss action (`{kind:'next'}`) only if the reference/spec asks for it.
- Question card: header/question text, options as a list of buttons
  (multi-select when `multiSelect`), a free-form input for "其他答案"
  (`custom`), and submit/cancel. `plan-review` renders the plan markdown above
  the options; `approval`-intent renders approve/reject/always with
  `intent.display` labels as the official card does.
- Cards are **modal-ish**: the composer stays usable (a prompt can be queued),
  but a visible banner/count shows pending requests. Never auto-answer.
- Disappearing cards (`cancel`) must animate out; the reference's rule "answer
  is idempotent, losing the race is success" prevents "请求已失效" errors from
  surfacing after the fact.

### 5.6 Composer controls: model, effort, permission, stop

- **Model chip** shows provider + model (+ effort when the model has efforts).
  Tapping opens a sheet fed by `session/modelCatalog`, grouped by provider,
  with `failures` shown as disabled groups (their message as subtitle). Selecting
  calls `session/selectModel`; the sheet stays open until the result settles,
  then closes and the chip updates from `selected`/projection.
- **Effort** is a secondary segmented control inside the model sheet, visible
  only when the selected model advertises efforts; options use `name` (localized
  by the Host), values use `id`. Default selection per §3.5.
- **Permission chip** reads the `permissions` projection and `permissionPresets/
  catalog`; selecting sends `/permission <value>` through `commands/execute`
  (§3.6). `danger-full-access` asks for confirmation first. Hide the chip when
  the projection key is absent, and disable it when the catalog failed to load.
- **Send/stop**: while `running`, the send button becomes stop
  (`session/cancel`) with the queue/steer affordance: plain tap cancels,
  long-press or the "排队" affordance sends `mode:'queue'`, and an "插入" action
  sends `mode:'steer'` when the turn is running. During `syncing`/`streamLost`
  the composer is disabled (the reference's `controlReady`), except that the
  draft remains editable.
- **`+` menu** (§3.11): commands, skills, file, image. Keep its data
  re-fetched per session (preset/cwd change the lists).
- **Slash menu**: typing `/` lists `commands/list` + `skills/list` filtered by
  prefix; unknown command lines are sent as prompts (the Host decides whether
  the line is a command).

### 5.7 Sync, reconnect and error UX

The reference's visible states are the right model:

| state | trigger | UI |
|---|---|---|
| `loading` | first open, no snapshot yet | skeleton transcript |
| `syncing` | follow opened/reopened, snapshot not applied | transcript retained + subtle sync strip; controls disabled |
| `streamLost` | follow ended without replacement snapshot (6 failed resyncs, Host ended) | banner "连接已中断" + retry button; transcript read-only |
| `resyncing` | manual retry in flight | spinner on the banner |
| `stopping` | stop requested | send button shows "停止中" with a 10 s cap |
| `connection` | mux state | global banner for `reconnecting`/`unauthorized` |
| `error`/`syncError` | classified error | inline error row (not a dialog) + action |

- A transient `reconnecting` is **not** an error state: show a thin banner and
  keep the transcript. Only `unauthorized` (needs a new URL) and `streamLost`
  (needs a retry) are actionable.
- Never clear the transcript on reconnect; the new snapshot merges over it.
- Error text is mapped (§4.9); an unknown code still shows `code: message`.
- The clock-skew note: event `time` is Host time; the reference estimates skew
  from live events (min sample) and uses it for relative timestamps. Optional
  for Cuplivo (server-rendered relative times are acceptable if the client
  doesn't show durations).

### 5.8 Landing the WebView on the official surface (the `dsh_web_open.js` pattern)

DSH Web is one page: there are no routes, and the plugin's page is reached by
clicking the official UI. The reference's bridge does this by:

1. waiting for the page to settle (`document.readyState`, then a few animation
   frames);
2. clicking by **accessible name** (localized labels in zh/en) rather than CSS
   classes: sidebar entries `插件`/`Plugins`, `自动化任务`/`Automation tasks`,
   `设置`/`Settings`, settings tabs `通用设置`/`General`, `模型`/`Models`,
   `内置插件`/`Built-in plugins`, `Agent 预设`, `账号与余额`, `工作区文件`, and
   `button[aria-label^="查看 "]` for a plugin's "view" action;
3. preferring stable DOM markers when present: `[data-plugin-package]`,
   `[data-plugin-item]`, `[data-plugin-panel]`;
4. writing plugin/session selection state into `dsh.sessions.current` (the
   official page's session selection state) instead of clicking a session row —
   chat selection is expressed as application state;
5. bounded steps (the reference budgets 15 s) and a fallback: if a step fails,
   the WebView is simply left on the page it reached (the user can finish by
   hand) instead of showing an error.

Cuplivo should treat this as a **best-effort landing**, not an integration:

- A small JS asset (not a fork of the reference's 545-line script) that clicks
  one of the three official entries and, for chat, sets the current session.
- Localized label lists must be maintained per DSH locale; a missing label
  degrades to "the official page opens" — never to an error.
- The official DOM is not a public API: a packaging update can rename a label.
  Therefore the WebView surface must always be usable without landing (sidebar
  visible), and the Flutter chrome must not depend on the WebView's location.
- Do not attempt to read data out of the page (parity + fragility); the WebView
  is for surfaces that have no API.

**Where this is actually needed**: plugin settings pages, plugin panels, and
the 自动化任务 page if not built natively. It is *not* needed for chat, sessions,
models, permissions, or plugin enable/disable — those are native.

### 5.9 Copy / do-not-copy summary

| pattern | verdict |
|---|---|
| layered client with generation-aware mux and typed errors | **copy** |
| pure transcript fold + memoized derived rows + stable row keys | **copy** |
| optimistic prompt echo reconciled by `requestId`, inbox splice tracking | **copy** |
| assistant draft sharing the durable row key | **copy** |
| snapshot-first, resync-on-gap, history fill bounded | **copy** |
| approvals keyed by `eventId`, 3 s grace after reconnect | **copy** |
| host-event-driven cache invalidation, no polling | **copy** |
| separate error-text mappers with unknown-code fallback | **copy** |
| local DB mirror of remote sessions for offline reading | **do not** (invariant) |
| client-side command registry/DOM automation as a primary control path | **do not** (best-effort WebView only) |
| a GUI bridge plugin installed into DSH for inventory/panels | **do not** (product scope) |
| native terminal/xterm renderer in MVP | **defer** |
| rendering DSH's own web UI for chat/settings | **do not** (official UI must be native) |

---

## 6. Recommended Cuplivo design (`lib/core/dsh/` + `lib/features/harness/`)

`architecture.md` §3 fixes the file list and the Provider convention; this
section fills in responsibilities, public surfaces and behavior. Where this
section and `architecture.md` disagree, `architecture.md` wins.

### 6.1 Design rules

1. **Pure Dart core.** `lib/core/dsh/**` imports only `dart:*` and sibling
   `dsh` files (never `package:flutter/*`, never `provider`, never a widget).
   This keeps the protocol unit-testable in the default `flutter test` run and
   reusable by a hypothetical desktop/CLI host.
2. **One client per remote**, one mux per client, one follow per open chat.
   There is no global "current session".
3. **Core exposes streams and futures, not models.** No `ChangeNotifier` in
   core (that is Flutter foundation); the feature layer adapts core streams into
   Provider notifiers.
4. **Wire fidelity over convenience.** Request/response shapes stay close to the
   Host's names (`session/follow`, `assistantStream`, `requestId`) so a reader
   can cross-check against Appendix A; only obvious ergonomics (typed models,
   enums for string unions) are added.
5. **Everything is capability-gated.** Any endpoint that may be absent throws
   `DshUnsupportedException` (or returns a `null` capability), and the catalog
   exposes `bool get capabilities`. Unknown events/projections/content blocks are
   skipped, never fatal.
6. **No persistence in core.** Cookies are handed in and out as values; the
   feature layer owns `flutter_secure_storage` and `DshRemoteStore`.

### 6.2 Module map — the frozen surface lives in `client-api.md`

The concrete class/method contract is **`docs/cuplivo-dsh/client-api.md`**
(owner `dsh-client-core`), written before the implementation and used by every
feature slice. This section records the *responsibilities and design reasons*
behind that surface; if they ever disagree, `architecture.md` and
`client-api.md` win and this section is amended.

| file | responsibility | design notes |
|---|---|---|
| `dsh_errors.dart` | sealed `DshException` hierarchy: `DshEndpointException`, `DshAuthException`, `DshRemoteException(code, message, details)`, `DshTransportException`, `DshProtocolException`, `DshUnsupportedException`, `DshClosedException` | not in `architecture.md`'s first list; it exists so lower layers throw typed errors without an import cycle. Amend `architecture.md` if it stays. |
| `dsh_endpoint.dart` | parse the pasted WebUI line, hold `baseUri`/`authority`/`secure`/`token`, build `indexUri`, `apiUri`, `muxUri`, `uploadUri`, `fileUri` | token is carried only until `login()`; `authority` drops the default port exactly like the `Host` header; IPv6 bracketed; explicit `DshEndpointException` field for the form |
| `dsh_transport.dart` | `DshCookie`, `DshTransport` *interface*, `DshHttpTransport` + injectable `DshHttpClient`/`DshIoHttpClient`, `login()`, `verify()`, `useCookie()`, `post`/`get`/`postBytes`, `openMux()`, timeouts, header policy | interface + injectable client keeps unit tests socket-free and leaves room for a tunnel carrier; no `Origin`/`Referer`/`Sec-Fetch-*`; `autoUncompress = true`; `login()` never follows the redirect |
| `dsh_rpc.dart` | `{type:'client-request', rpcId, method, payload:{args}}` envelope; `server-response` decode; status→exception mapping; `idempotent` read retry; `dshUuidV4()` | gateway answer echoing `rpcId:"invalid-request"` is still an error; one retry only for idempotent reads |
| `dsh_mux.dart` | `/api/remote.mux`: one socket, generations, `$events` ready handshake, host requests + pending set, logical streams, auto-reopen, backoff, keepalive, disposal | `open(autoReopen: true)` streams re-deliver the Host's baseline after a reconnect; pending requests survive a generation for `hostRequestGrace` then are retracted; `answerHostRequest` retries once on a stale `clientId` |
| `dsh_events.dart` | wire vocabulary: `DshSessionSnapshot`, sealed `DshSessionEvent` catalogue, assistant-stream frames/chunks, `DshHostEvent`/`DshHostRequest`, mux frames, workspace updates | every event keeps `seq`, `time`, `type`, `surfaceOp`, `sourceEventSeqs`, `ignorable`, `raw`; unknown types are a concrete `DshUnknownSessionEvent` |
| `dsh_models.dart` | tolerant JSON helpers (`jsonMap`, `jsonList`, `jsonInt`, `jsonEpochMs`, …) + immutable models for messages, sessions, models, providers, permissions, workspaces, commands/skills, plugins, settings, account | one shared parser keeps the feature layer from re-implementing wire tolerance; `raw` retained where schema drift is likely |
| `dsh_catalog.dart` | typed reads/writes: sessions, workspaces, models/providers/credentials, permissions, settings, commands, skills, plugins, account; `watchSessionControl()`/`watchWorkspaces()`; `supports(endpoint)` capability probe | catalog is the only place that knows the official merge recipes (§3.5/§3.8/§3.9); `supports` caches 404→false and never throws for absence |
| `dsh_session.dart` | one session: `watch()` (snapshot → contiguous events → assistant frames → host requests, with activation), prompt/cancel, model/permission writes, commands/skills, approvals/questions, history paging, upload/attachment, rename; `DshSessionStore` = handle + `DshTranscript` + `changes` stream | `watch(activate: true)` is the normal flow; gap repair lives inside the watch; `DshSessionStore` is what the Flutter controller owns |
| `dsh_projection.dart` | pure `DshTranscript` reducer: snapshot replace, append-origin durable events, assistant draft replacement, tool status derivation, pending requests, notices; `DshTranscriptItem` sealed rows | no I/O, no Flutter; row keys (`m<turn>.<step>`, `t<callId>`) are stable for widget reuse; `DshSessionStore.changes` is the repaint tick |
| `dsh_client.dart` | public entry: `DshClient(endpoint)` → `login`/`useCookie`/`connect`/`loadCatalog`/`createSession`/`openSession`/`close` | one client == one remote == one mux; `login()` discards the token; `connect()` resolves after the first ready generation |

Feature layer (the slices that are landing in parallel; names follow
`implementation-contract.md`'s ownership table):

| file | responsibility |
|---|---|
| `lib/features/harness/models/dsh_remote.dart`, `dsh_web_ui_link.dart` | device-local connection record + pasted-link parsing/validation for the form |
| `lib/features/harness/services/dsh_remote_store.dart` | `JsonBlobStore<DshRemote>` under `dsh_remotes_v1`, `deviceLocal` policy |
| `lib/features/harness/services/dsh_credential_store.dart` | the v1 cookie in `flutter_secure_storage`, keyed by remote id |
| `lib/features/harness/state/dsh_gateway.dart` | the adapter seam between the pure Dart client and the feature layer (link states, user-actionable failure classes) |
| `lib/features/harness/state/dsh_connections_provider.dart` | all remotes, one live link each, owner-order integration (`HarnessOwnerSource`); the only writer of store + cookie |
| per-slice state (`harness-home`/`harness-chat`) | catalog cache provider and the open-chat controller, per `architecture.md` §3/§5 |

Design reasons behind the API shape, worth keeping when the surface evolves:

- **Transport is an interface, not a class hierarchy.** `DshHttpTransport` is
  the only implementation today; a tunnel/relay carrier later is a second
  implementation, not a fork of the client.
- **`dsh_errors.dart` is deliberate.** Errors are the client's user-facing
  contract (the UI maps classes + codes, never strings); one small file keeps
  them importable from every layer.
- **`DshTranscript` is separate from `DshSession`.** The reducer is testable
  without sockets (`test/core/dsh/*projection*`), and the UI tick
  (`DshSessionStore.changes`) is honest: it fires when rows changed, not per
  chunk.
- **Watchers auto-reopen; consumers treat a baseline as a replacement.** This is
  the generation model from §4.1 encoded in the API, so no screen re-implements
  reconnect logic.
- **Capability flags, not version gates.** `supports(endpoint)` + projection-key
  absence decide visibility; the only version-driven branch is the activation
  gate (§7.3), because the field itself must not be sent to hosts that lack it.

### 6.3 State ownership (Provider-style)

| class | kind | notifies on | consumers |
|---|---|---|---|
`DshConnectionsProvider` | `ChangeNotifier` | remote list, per-remote link status | drawer, connect flow, home shell
`DshCatalogProvider` | `ChangeNotifier` | sessions/workspaces/catalogs/settings snapshots | drawer, settings tabs, models page
`DshChatController` | `ChangeNotifier` exposing an immutable `DshChatViewState` | transcript rows revision, running/sync flags, model/permission, pending requests | chat page
`DshGateway` (adapter in `state/dsh_gateway.dart`) | plain object with `Stream`s, one per remote | — (wrapped by the provider) | provider + slices
core (`DshClient`, `DshSessionStore`…) | plain objects with `Stream`s/futures | — | feature layer only

Provider details that matter for frame cost:

- Prefer `Selector<DshChatController, T>` / `context.select` on the *smallest*
  slice each widget needs (`rows`, `running`, `pendingApprovals.length`,
  `model`), exactly like the reference's Riverpod `select`. A chat that rebuilds
  on every token is the failure mode.
- Rows come from a memoized reducer; `DshChatViewState.rows` keeps list identity
  until the transcript actually changes, so `select` can compare by identity.
- The composer's draft text is local `TextEditingController` state in the
  feature layer; do not round-trip it through the controller (avoids a rebuild
  per keystroke).
- Connection status belongs to `DshConnectionsProvider` so a banner outside the
  chat page can show it; the chat controller derives `syncing`/`streamLost` from
  its own handle.
- One `DshCatalogProvider` per connected remote, created with the connection and
  disposed with it; no Provider owns a long-lived cache after disconnect
  (invariant 1).

**How the catalog stays fresh without polling** (`architecture.md`: cache +
`refresh()`): the provider subscribes once to `client.mux.hostEvents` and maps
the invalidating events of Appendix C to `refresh()` calls, debounced by
~250 ms; a generation change forces a full refresh. This mirrors the reference's
`features_state.dart` `_refreshOn([...])`.

### 6.4 Lifecycle and disposal

- **App start / remote list**: `DshConnectionsProvider` loads `DshRemote`s; no
  connection is opened until the user enters a remote (drawer tap or chat open).
- **Enter remote**: if a stored cookie exists → `useCookie(stored)` +
  `connect()` (validate with `GET /`, then mux ready); otherwise the connect
  flow asks for a WebUI URL again. `lastConnectedAt`/`lastError` update the
  remote record (device-local only).
- **Leave remote / switch remote**: keep the connection (sessions keep running
  on the Host), but close the open chat controller (cancel follow). A single
  live connection per remote; several remotes may be connected at once, each
  with its own mux — keep the number small (memory and battery), and close
  connections for remotes not visited for a while if the app needs to.
- **Chat open**: `client.openSession(id)` → `DshSessionStore.start()` → first
  snapshot → render. **Chat close**: `store.dispose()` cancels the watch (and
  the `userQuestions/attachWait` it owns), then dispose the controller.
  Reopening is a fresh snapshot (no cache).
- **App background**: cancel nothing gratuitously; the mux survives short
  backgrounding and reconnects after longer ones. On resume, if the mux is
  `unauthorized`, show the re-pair banner; if a chat's apply loop reported
  `streamLost`, show its retry.
- **Remote deletion**: close the client (mux + sockets), delete the secure
  cookie entry, dispose catalog/chat controllers, remove the owner order entry.
- **Errors**: `DshUnsupportedException` hides a capability and logs once;
  `DshRemoteException` shows inline; `DshAuthException` (401/403) closes the
  mux, sets `unauthorized`, and keeps the remote record so a new token can be
  pasted. `DshFailure` in `dsh_gateway.dart` is the persisted, user-actionable
  projection of that class.
- Every `StreamSubscription`, `Timer`, `WebSocket` and `Isolate.run` must be
  reachable from a `dispose()`; the reference leaks nothing across chat
  switches and neither may Cuplivo.

### 6.5 Mapping to Cuplivo abstractions

- **Owner identity**: `ChatOwnerKind.harness` + `ChatOwner.harness(id)` per
  `architecture.md` §2; the drawer lists `ChatOwner` entries and the harness
  mode reads `DshConnectionsProvider`. No `Assistant` record, no model, no
  prompt — this is what keeps remotes out of backups/sync/edit pages.
- **Home integration**: harness mode inside `HomePage`'s existing scaffolds
  (mobile/desktop), same drawer, same app bars, same right-rail geometry
  (§3 of `architecture.md`). The local controllers (`ChatService`,
  `HomeViewModel`, `ChatController`, `AssistantProvider`) are never entered.
- **Rendering reuse (the honest version)**: reuse Cuplivo's *renderer leaves*
  and theme, not the local message pipeline:
  - `lib/shared/markdown/markdown_with_code_highlight.dart` for assistant text
    and tool result text (it already reads `SettingsProvider`, so fonts,
    code theme, math and citation rendering match local chats);
  - `lib/shared/markdown/*` handlers for links/images; `link_image_handlers`
    plus a harness-scoped image fetcher that adds the cookie (a plain
    `Image.network` would 401);
  - shared widgets (`SectionCard`, `CustomBottomSheet`, `IosFormTextField`,
    `IosCheckbox`, `InteractiveDrawer`), Lucide icons, `flutter_animate` for
    motion, Cuplivo theme tokens throughout;
  - image viewer, file chips, reasoning card chrome: small shared widgets, or
    harness copies styled identically where the local ones are entangled with
    controller state.
- **Do not construct `ChatMessage`/`MessagePart` for DSH data.** They are
  Hive-annotated local models that require a `conversationId`, and using them
  invites persistence, local sync and assistant-regex coupling — three
  invariant violations. `DshRow` is a separate, in-memory model.
  `ChatMessageWidget`/`MessageListView` are **not** reusable as-is (they read
  `ChatController`, `TtsProvider`, `AssistantProvider`, `ChatService`, the
  intelligent-UI host and local tool services); copying that wiring would drag
  the local world into harness mode. Reuse their *visual language* and the
  shared leaves above, not the widget.
- **Composer**: new harness composer (text field + `+` menu + model/effort/
  permission chips + send/stop), built from the same shared widgets and
  Cuplivo's composer constants.
- **Settings surfaces**: `pages/assistant/` reuses the provider-settings page
  chrome (rows, cards, bottom sheets) but its data comes from
  `DshCatalogProvider` and its writes go through `DshCatalog`.
- **l10n**: every new string in `app_en.arb` + `app_zh.arb` (then the translate
  sync), including the error-string tables.

### 6.6 Adapt vs write fresh

| piece | decision | reason |
|---|---|---|
| connection/cookie/login | write fresh, informed by §2–§3 | small, exact wire knowledge; reference code is AGPL-adjacent prior art to learn from, not to import |
| RPC envelope + multipart decode | fresh (≈200 lines) | trivial, testable |
| mux (generations, backoff, pending requests, uplink) | fresh, same state machine as §4 | the hardest part; the *rules* are documented here so no code transfer is needed |
| session follow + gap fill + history | fresh, per §4.2–§4.3 | tests are the spec (contiguous seq, snapshot-first, bounded fills) |
| assistant draft → durable replacement | fresh | row key trick documented in §4.4/§5.2 |
| transcript reducer + row derivation | fresh, pure Dart | deterministic unit tests; reference's fold rules summarized in §5 |
| wire models/parsers | fresh | JSON shapes in §3/Appendix A; tolerate missing fields |
| markdown/code rendering | **reuse Cuplivo** | invariant 4 |
| theme, shared widgets, icons, animation | **reuse Cuplivo** | invariant 4 |
| l10n, secure storage, prefs store, webview page | **reuse Cuplivo** | already solved in the app |
| Cuplivo `ChatMessage` pipeline | **not reused** | local-model coupling, invariant risk |
| reference `chat_rows` visual rules | copy the rules (thresholds, row keys, collapse behavior) | product parity without code transfer |
| reference WebView landing JS | minimal fresh script, labels from §5.8 | fragile DOM contract; do not fork 545 lines |

### 6.7 Lean cut list (what MVP does *not* build)

- no local cache, no offline transcript, no optimistic history, no background
  sync of DSH data;
- no terminal emulator (read-only panel or deferred);
- no browser card (no API);
- no schedule creation UI (read-only list optional);
- no goals/todos strips unless the acceptance images show them;
- no plugin market/install flows beyond list + enable/disable (install from a
  phone is rare and the official UI covers it);
- no DeepSeek account login;
- no per-plugin native settings forms in v1 — the schema-driven form viewer is
  shared with engine settings, but exposing every plugin's namespace is a
  follow-up feature;
- no fork/edit/regenerate/feedback actions; the reference has them, the brief
  does not ask for them.

---

## 7. Version deltas: the reference's releases vs 0.2.2-rc.1

### 7.1 What was verified against what

- The reference client (`packages/dsh_client`, 23k lines) documents itself as
  verified against **DSH 0.2.0-rc.2 and 0.2.1-rc.2** (both session format
  version 4) and its live tests are environment-gated against a real Host of
  those releases.
- The dsh-go *app* additionally knows **0.2.2-alpha.2 / 0.2.2-rc.1** and gates
  one behavior on them: session activation (`session/follow {activate:true}`)
  is only attempted on a 0.2.2 release, because older Hosts reject the field.
- This note's target is the installed **0.2.2-rc.1**; every shape in §2/§3 was
  read from its typings. Where the reference already tolerates a 0.2.2 shape
  (it does in several places), that is called out so the reader does not
  mistake tolerance for a requirement.

### 7.2 Deltas that change client behavior

| area | reference-era behavior (0.2.0/0.2.1) | 0.2.2-rc.1 behavior | client action |
|---|---|---|---|
| session model write | `session/selectModel` returned `{selected, defaultSave?}`; `defaultSave` reported the next-session default write | returns `{selected}` only; the next-session default moved to **`session/initializeDefaultModel`** | never read `defaultSave`; use the new endpoint if "make default" is offered |
| cold-session prompting | prompt into a background session could queue work that never starts unless something activated it | `session/follow {activate:true}` is the supported promotion path (snapshot first, then prompt) | `watch(activate: true)`; gate by release (§7.3) |
| history endpoint | `session/page` canonical; result `{records, hasMore}` | **`session/events`** canonical, `session/page` a deprecated alias; result adds `cursor` (inclusive cut) | call `session/events`; `page` still works and is not worth a compat branch |
| control projection frames | one projection per frame: `{type:'projection', sessionId, seq, key, value}` | batched per committed event: `changes:[{key, val}]`; `val` is the key (not `value`) | parse batched frames; reference's per-key stream is a convenience layer |
| live passive state | none | `session/state`, `session/wait`, `session/observeState`, `session/observeProjections`, `session/observeEvent` | optional; useful for list rows and "wait for turn end"; not needed for the chat itself |
| surface origin | events carried no surface marker the reference read | surface-eligible events carry `surfaceOp` (`'append'` or a replace range), `ignorable`, `sourceEventSeqs`; only `system/message`, `developer/message`, `user/message`, `assistant/message`, `tool/result` are surface-eligible | render append-origin only; treat an absent marker as append; keep `seq` continuity for skipped events |
| approval answers | `$events/result` with `{kind:'result', value:{kind:'allowed-once'|'rejected'}}` | same; audit vocabulary `allowed-once`/`rejected`/`cancelled`/`unavailable` | unchanged |
| question intents | reference passed `intent` through as a raw map (knew `plan-review`) | adds `intent.kind === 'approval'` with `approve`/`reject`/`always`, localized `display`, `subject` | render the fixed card when the tag is known, generic options otherwise (encoding identical) |
| attachment bytes | `session/attachment {attachmentId}` (older); reference probes full ref then falls back | requires the full `ImageAttachmentRef` under `{attachment:{…}}`; `attachmentId` is rejected as an argument error | always send the full ref |
| file upload route | `POST /api/session/uploadFileBinary?sessionId=&name=` with fallback `fileUploads/upload` | same route plus **`mediaType`** for a staged image receipt (`{receiptId, image}`) | use the streamed route with `mediaType` for photos |
| provider model discovery | `llm/discoverModels` and `llm/discoverModelsWithHeaders` (headers list) | only `llm/discoverModels`; request has no `headers` field | never send headers; a UI that edits headers cannot test them via discovery |
| schedules | `schedule/create|update|delete|list|…` | `update`/`delete` removed: `schedule/edit`, `schedule/deleteInactive`, plus `view`/`list`/`history` result shapes | out of MVP; if built, use the new verbs only |
| workspace defaults | none | `workspace/initializeDefault` creates/returns the default workspace | optional; a drawer can show a `默认工作区` group derived from sessions instead |
| plugin manager | listBundles/listPlugins/set*Enabled/install/remove/inspect/registries/wait/cancel | adds `listVersions`, `readBundleDetail`, `updateBundle`, `listVersionExemptions`, `setVersionExemption`, `pluginMarket/*`, `pluginRecommendations/*`; `ChangeResult` gained fields (`restartReason`, `failedAt`, …) | MVP uses the surviving core methods; additive fields are ignored |
| account / subscription | no remote account surface | `account/*` (sign-in attempt, state watch, balance, bonuses) | out of scope (browser OAuth only) |
| projection keys | `title`, `agentPreset`, `permissions`, `modelSelection`, `todos`, `sessionListMetadata`, `inbox`, `tokenUsage`, `imageLimits` | adds `turnOutline`, `sessionStats`, `contextPressure`, `tokenBreakdown`, `goal`, `plan`, `actionCards`, `userQuestions`, `subagents`, `working-directory/change` event, `workingDirectory` | additive; absence = capability absent; the chat needs only `title`/`permissions`/`modelSelection`/`inbox`/`sessionListMetadata`/`imageLimits` (+ `todos` if the strip is built) |
| session list rows | `agentAvailable`, `formatStatus`, `blank`, `running`, `parentSessionId`, `cwd`, `projections` | same fields; new `origin` | hide archived ids (from workspace baseline) and child sessions (`parentSessionId != null`) unless a child view exists; list includes archived sessions |
| boot graph | `release.version`, `rev`, `entries`, `packages` | adds `batches` (prefetch grouping) | parse tolerantly; `release.version` is the activation gate |
| operator login | none | `GET /connect?token=…&interactions=…` mints a v2 cookie | not used (architecture invariant 2; the v1 cookie serves API + mux + WebView) |
| JSON-RPC/HTTP carrier | same envelope/status semantics | same | unchanged |
| mux numbers | ready 15 s, ping 2 s server / 15 s client, retry caps, uplink 256 KiB, permessage-deflate | same defaults (verified in `dsh-api-gateway`) | same constants |

Delta of *reference code* worth noting for anyone reading it later: the
reference is **more compatible than the target needs** — it probes
`session/attachment` argument shapes, keeps `defaultSave`, parses both control
frame shapes, falls back to inline uploads, and gates activation by release.
A 0.2.2-only client can drop those branches (§7.4), which is a large part of
why Cuplivo's client can stay small.

### 7.3 Feature detection recipes (no version-string gating)

1. **Endpoint presence** — call it; HTTP 404 (mapped to
   `DshUnsupportedException`) means the installed Host does not have it. Cache
   the verdict per generation (`DshCapabilities.supports(endpoint)`); a
   `gateway/method-not-found` or `gateway/method-unavailable` code inside a 200
   envelope means the same thing. Do not use the reference's carrier allow-list
   (`allowsEndpoint`): that is a tunnel artifact, not a Host capability.
2. **Projection-key presence** — for per-session capability, a key absent from
   the snapshot's `projections.values` means the composed Host has no such
   service (`permissions`, `imageLimits`, `todos`…). Hide the control; never
   invent a default value.
3. **Settings namespace presence / schema** — engine settings, session-log
   upload and provider adapters are detectable from `settings/describe`
   (`namespaces[].ns`, `schema`, `writable`). Preferred over probing, because it
   is one read.
4. **Plugin package presence** — the boot graph (`packages`/`entries`) plus
   `pluginInventory/list` tell which client halves exist; nothing tells their
   slots. Use it only for "is there a plugin page to open" / WebView entry
   labels, never for native panel rendering.
5. **Release version** — read `GET /` and parse `__DSH_BOOT__`
   `release.version`, once per generation, bounded to 1–2 s. The **only**
   behavior it may gate is sending `activate` on `session/follow`: an unknown or
   older release disables activation (prompting still works on sessions with a
   live agent). Do not gate anything else on a semver comparison; the Host's
   capability answers are more truthful.
6. **Unknown data** — unknown session-event types are `ignorable`/unknown and
   skipped; unknown projection keys are ignored; unknown `StreamChunk` kinds are
   ignored; unknown `Message.part` types render as a generic block or are
   omitted; unknown JSON fields are preserved when writing settings/provider
   profiles (§3.7/§3.8).

### 7.4 Compatibility branches a 0.2.2-only client should skip

- `session/attachment` argument probing (always full ref);
- `defaultSave` handling (`session/selectModel` result is `{selected}`);
- legacy single-projection control frames (parse `changes[]` only);
- `fileUploads/upload` base64 fallback (keep only if a Host may predate the
  streamed route; the product targets 0.2.2, so a missing route can surface
  `DshUnsupportedException` and disable attachments);
- `discoverModelsWithHeaders` (no such method);
- old schedule verbs (`update`/`delete`);
- subagent routing (`promptSubagent`, `interruptByParent`): Cuplivo does not
  show child sessions; if one is opened by deep link, show its transcript
  read-only rather than routing prompts;
- carrier allow-lists and tunnel capability probes (no tunnel in scope).

The one branch to keep is the **activation release gate** (§7.3.5): it is a
field-presence gate, not a capability claim, and it degrades to "no activation"
rather than to an error.

---

## 8. Licensing and provenance

### 8.1 Facts

- **Cuplivo**: AGPL-3.0 (repository `LICENSE`; the fork follows upstream
  Kelivo's license). Everything added by this feature ships under it.
- **dsh-go** (the reference repository): **AGPL-3.0** at the
  repository root, with `sdk/` and `examples/` under MIT and its brand/mascots
  explicitly excluded (`ASSETS.md`). Its `THIRD_PARTY_NOTICES.md` records that
  parts of its Dart client derive from DeepSeek Harness packages under MIT (for
  example `packages/dsh_client/lib/src/binary_response.dart` from
  `@deepseek-ai/dsh-client-connection`). So the reference tree is **not a
  uniform license**: root AGPL, some subtrees MIT, assets reserved.
- **DeepSeek Harness 0.2.2-rc.1** (the target): `package.json` says
  `"license": "MIT"`, `LICENSE` is MIT © 2026 DeepSeek. The installed Host's
  protocol surface (type declarations, wire shapes) is therefore MIT-licensed
  material.
- The reference images under `docs/cuplivo-dsh/reference/` (untracked) are
  product screenshots used as acceptance targets; they are not shipped assets.

### 8.2 Policy for this feature (and for the docs)

1. **Write fresh code informed by the wire, not by the reference's source.**
   `protocol.md` (0.2.2 wire ground truth) and this note's tables are the
   inputs. No file, function or comment block is copied from dsh-go. This keeps
   provenance unambiguous and avoids importing a foreign app's structure into
   Cuplivo.
2. **Design knowledge is not a license obligation.** Behaviors such as "key
   approvals by `eventId`", "share the row key between draft and durable
   message", or "history pages of 500" are engineering facts; they are
   attributed in `docs/cuplivo-dsh/*.md` as reference study, not relicensed.
3. **If code is ever ported** (e.g. a schemastery node walker from DSH's MIT
   typings/implementation, or a snippet from dsh-go's MIT `sdk/`): record it in
   the repo's `THIRD_PARTY_NOTICES.md` with source package, version, license and
   the copied region, and keep the MIT notice in the file header. AGPL portions
   of dsh-go (the `dsh_client` package) must not be ported piecemeal; a port
   would have to carry an AGPL notice and a provenance record, which is a
   product decision for the Lead, not a refactor convenience.
4. **The protocol shapes are facts, the text isn't.** Field names, endpoint
   names and status semantics may be reproduced in docs and code; DSH's own
   prose (doc comments, descriptions) is MIT but must not be pasted into
   Cuplivo strings/docs in bulk without a notice. This note paraphrases.
5. **Brand**: the DeepSeek whale glyph is already shipped by Cuplivo for the
   DeepSeek provider (`assets/icons/deepseek-color.svg`); the harness row reuses
   that existing asset, which is nominative use and requires no new license
   grant. Do not add official DSH Web screenshots, mascots or wordmarks as
   app assets; the names "DeepSeek Harness" / "DeepSeek" in strings identify
   the remote product and stay descriptive.
6. **Attribution in the PR**: the docs already name dsh-go and DSH as research
   sources; the PR body should keep that line. No license header changes are
   needed for fresh code under AGPL-3.0.

### 8.3 What this means for the implementation

- `lib/core/dsh/**` is Cuplivo code, AGPL-3.0, no third-party header.
- Any future copy of an MIT DSH snippet gets `// Ported from @deepseek-ai/dsh-…
  (MIT, © DeepSeek)` plus a `THIRD_PARTY_NOTICES.md` entry.
- The `LICENSE`, `README` license section and `THIRD_PARTY_NOTICES.md` are not
  modified by this feature unless a port happens.

---

## 9. Phased implementation checklist and file estimate

The phases follow `roadmap.md` §4. Each phase lists what to build, the files it
owns (per `implementation-contract.md` scopes), the tests that prove it in
`pr-check`, and the acceptance signal. Current status is noted where the branch
has already landed part of it (as of this writing).

### 9.1 P1 — protocol client (`lib/core/dsh/**`, owner `dsh-client-core`)

- [x] `dsh_errors.dart`, `dsh_endpoint.dart`, `dsh_events.dart`, `dsh_models.dart`
      exist; `dsh_transport/rpc/mux/catalog/session/projection/client` follow.
- [ ] `DshEndpoint.parse`: bare/printed/scheme-less forms, mount path, default
      port, IPv6, token required, endpoint exception fields (form validation).
- [ ] `DshTransport.login`: `GET /?token=` no-redirect, v1 `Set-Cookie` parse
      (attributes, expiry), explicit `Host`, no `Origin`; `verify()` 200/401;
      `useCookie()` resume; timeouts; `HttpClient.autoUncompress`.
- [ ] `DshRpc.call`: envelope shape, rpcId echo, `ok:false` mapping, 401/403/404/
      405/413/415 mapping, multipart decode, idempotent retry once.
- [ ] `DshMux`: `$events` ready handshake (15 s), generation counter and
      `clientId`, pending host requests + `hostRequestGrace` retraction,
      logical stream bookkeeping, auto-reopen streams, backoff caps, ping 15 s,
      close/dispose; `answerHostRequest` with one stale-client retry.
- [ ] `DshCatalog`: sessions/workspaces/models/providers/permissions/settings/
      commands/skills/plugins/account reads, `supports()` probe caching, the
      two native settings convenience writes, provider merge recipe, credential
      state, discovery.
- [ ] `DshSession`: `watch()` (activation gate, snapshot-first, gap repair via
      `session/events`, assistant frame revision continuity, host request
      forwarding), prompt (text/images/receipts/queue/steer/requestId/time zone),
      cancel, model/permission writes, approvals/questions (allow/reject/next,
      timed waits), history paging, upload/attachment, rename, close.
- [ ] `DshTranscript` + `DshSessionStore`: snapshot replace, append-origin filter,
      tool status fold, draft replacement, pending requests, notices, stable
      rows/keys, `changes` tick, disconnect stale flag.
- [ ] `DshClient`: login/useCookie/connect/loadCatalog/createSession/
      openSession/close; one mux; error/phase propagation.

**Tests** (`test/core/dsh/`): endpoint parsing table; cookie header/expiry;
rpc envelope + status mapping + multipart; mux ready/backoff/retry/pending
grace/stream reopen (fake transport); follow snapshot ordering + gap fill with
fake pages (`500`-page boundary); assistant revision skip → resync; attachment
ref shape; permission `/permission` command; catalog merge and 404 caps;
transcript fold corpus (fixtures from `protocol.md`); transcript row keys and
tool status transitions; store start/dispose idempotence. **No Flutter imports**
(the test run enforces this by compiling core under the default suite).

**Acceptance**: `pr-check` green with the unit suite; a tiny `bin/`-free probe
is *not* added to the repo (protocol probing stays outside the branch).

### 9.2 P2 — remote identity and persistence (`harness-foundation`)

- [x] `DshRemote` model, store (`dsh_remotes_v1`, device-local), credential
      store, `DshConnectionsProvider` with `HarnessOwnerSource`, owner-order
      integration, create/rename/delete, `DshGateway` seam, failure text.
- [ ] Wire the gateway to `DshClient` (login → persist cookie → connect →
      catalog) once `lib/core/dsh/` is complete; map typed exceptions to
      `DshFailure`; `lastConnectedAt`/`lastError`.
- [ ] Connect flow pages: create menu entry, *连接到一个新的 DeepSeek Harness*,
      *直接连接* form, URL validation inline, check screen with the remote card.
- [ ] Settings entry: the DSH assistant card ("远程连接的 DeepSeek Harness") and
      its settings shell with the tabs from R8.

**Tests** (`test/features/harness/…`): store round-trip/corruption, provider
create/rename/delete/order, cookie key lifecycle on delete, connect form
validation, failure → localized text.

### 9.3 P3 — settings pages (`harness-foundation` + `harness-chat` for models)

- [ ] 连接设置: name, URL masked, status, reconnect, re-pair, delete.
- [ ] 通用设置: **only** `permission.defaultPreset` and
      `session-log-deepseek.enabled` (schema-driven rows; hidden when absent).
- [ ] 模型: merged provider list (official order), `自定义提供商` first row,
      provider detail (API key via credential ref, base URL, models with
      context/max-tokens/input, reasoning efforts), model discovery for drafts,
      delete/reset rules; no local model registration.
- [ ] 插件 settings tabs: Flutter tab strip; body = WebView on the official
      page (whole SPA, v1 cookie) or the native plugin manager list (bundles +
      toggles) when the tab is the manager itself.
- [ ] Every write goes through `settings/mutate` with the read revision;
      `settings/conflict` re-reads and asks; failures keep the form value.

**Tests**: schema form generation for object/union/secret/credential-ref from
small fixtures; provider merge ordering; credential state rendering;
`expectedRevision` presence; permission settings write path; conflict handling.

### 9.4 P4 — home/sidebar (`harness-home`)

- [x] Home mode seam, drawer sidebar widget, geometry for the right rail.
- [ ] Drawer: remote owner row, search, 插件 / 自动化任务 / 更多, workspace
      sections from `workspace/follow`, session rows with running/title, bottom
      bar (settings/avatar), new-session button.
- [ ] Session list hygiene: archived filtered, child sessions hidden, title
      fallback, running dot from `session/control`, empty state per workspace.
- [ ] New-session flow: `session/create` (+ workspace), optimistic open, empty
      state with composer focused.
- [ ] Right-rail trigger replacing the minimap (button in the app bar).

**Tests**: drawer grouping/order, archived/pinned filtering, new-session
creation call, rail toggle geometry; golden-free widget behavior tests.

### 9.5 P5 — chat (`harness-chat`)

- [ ] Conversation body: `DshSessionStore` driven list, snapshot loading,
      streaming draft, durable replacement, history prepend, scroll anchoring
      (Cuplivo scroll/selection components), turn folding (process collapsed,
      final answer expanded), tool cards (statuses, expand, images), notices,
      queued prompts, approval/question cards, error rows.
- [ ] Composer: text, `+` menu (commands/skills/file/image), model chip +
      effort sheet, permission chip, send/stop, queue/steer, disabled while
      syncing, draft preserved, attachments staged via upload route.
- [ ] Sync UX: `syncing`/`streamLost` strips, retry, unauthorized re-pair
      banner, 10 s stop cap, per-code error text.
- [ ] App bar: title from session, right-rail button, no local chat actions
      (fork/regenerate/feedback) that DSH cannot serve through this UI.

**Tests**: transcript→row mapping fixtures, tool status matrix, approval card
answer encoding, composer disabling per sync state, model/effort selection,
permission command call, error text mapping.

### 9.6 P6 — right rail (`harness-home` + `harness-chat`)

- [ ] Push behavior (chat shifts off-screen, no stacking), transition animation.
- [ ] Official entries in Flutter: 工作区文件 (files API optional read-only),
      新建终端 (read-only attach or deferred), 更多工具; **浏览器 omitted**
      (no API — capability rule).
- [ ] Plugin contributions: `插件面板` WebView entry; no fabricated per-plugin
      rows.
- [ ] Rail closes on session switch; state not persisted per session.

### 9.7 P7 — hardening

- [ ] All strings in ARB (`dsh*` prefix), `flutter gen-l10n` output committed,
      `translate.py` sweep clean, no hardcoded Chinese/English.
- [ ] l10n for error mapping tables; unknown code fallback.
- [ ] Accessibility: semantic labels on icons/status dots, contrast, dynamic
      text, 44 px targets; keyboard traversal on desktop.
- [ ] Desktop/mobile layouts both verified; empty/loading/error states for
      every surface; long titles/URLs; offline/reconnect; expired credential;
      Host restart mid-turn (`interrupted` notice); very long tool output.
- [ ] Performance pass: no rebuild storms, bounded memory, background list read
      on startup, no polling.
- [ ] License/provenance line in PR body (dsh-go AGPL + DSH MIT acknowledgment).

### 9.8 P8 — acceptance

- [ ] One E2E scenario (`integration_test/e2e/dsh_remote_acceptance_test.dart`)
      running against the real e2e-vps Host: connect → owner card → drawer
      workspaces/sessions → open a seeded session → streaming answer → tool
      card + approval → stop/queue → model & effort sheet → permission switch →
      settings 通用设置 two rows → models provider page → plugin WebView opens →
      right rail push → create new session.
- [ ] Screenshots captured for every R1–R11 surface that the flow touches and
      compared with `docs/cuplivo-dsh/reference/` before the PR is final.
- [ ] `pr-check` green; `/e2e` comment run green; PR body Chinese with evidence.

### 9.9 Estimated new-file list (implementation, not this doc)

| area | files | rough lines |
|---|---|---|
| core client | 11 files under `lib/core/dsh/` (incl. `dsh_errors.dart`) | 5,500–7,500 |
| core tests | `test/core/dsh/*_test.dart` (8–12 files) + fixtures | 3,000–4,500 |
| remote identity/persistence | `models/` 2, `services/` 2, `state/` 2 | 1,300–1,800 |
| connect + assistant settings pages | `pages/connect/` 3–5, `pages/assistant/` 5–8 | 2,200–3,200 |
| home/drawer/rail | `pages/home/` 4–7, `widgets/` 4–6, side-panel edits | 2,000–3,000 |
| chat | `pages/chat/` 3–5, `widgets/chat/` 8–14, controller 1–2 | 3,200–4,800 |
| plugins WebView | `pages/plugins/` 2–3 + landing JS asset | 500–800 |
| tests (feature) | `test/features/harness/**` 8–14 files | 2,500–3,500 |
| E2E | 1 scenario + helpers | 500–800 |
| l10n | `app_en.arb`/`app_zh.arb` keys (+ generated) | ~150 keys |

Total implementation ≈ 18k–26k lines including tests — the same order as the
reference's client package alone, because Cuplivo writes both the client and the
UI. The reference's app adds another ~20k UI lines; Cuplivo's UI is smaller
because it reuses Cuplivo's shell and renderer (that is the point of the design).

### 9.10 Definition of done for the feature

1. A fresh install can add a DeepSeek Harness by pasting the printed URL, and
   the remote owner appears in the drawer.
2. Opening a session streams a real turn natively (text, reasoning, tools,
   approval), switching model/effort/permission works, and stopping works.
3. Every surface in `ui-spec.md` R1–R11 exists with the intended native/WebView
   split; the 浏览器 card is absent with a capability reason, not broken.
4. Nothing DSH-originated is persisted; deleting the remote removes the record
   and the cookie; the app still works offline for local conversations.
5. `pr-check` green, one E2E run against a real Host green, screenshots match
   the reference images, PR body Chinese with evidence and the license line.

---

## 10. Risks, open questions, and where the Lead may want to decide

### 10.1 Technical risks (ranked)

1. **WebView authentication.** Injecting an `HttpOnly` v1 cookie into the
   WebView jar is the only way to authenticate the plugin page (the launch token
   is not retained). `flutter_inappwebview` supports the cookie fields, but
   platform backends can differ; the fallback (same cookie without `HttpOnly`)
   works for the Host but must be tested on both platforms in E2E. If a platform
   refuses cookie injection entirely, the plugin surfaces degrade to "open the
   official page in the device browser" — a visible capability gap to report.
2. **DOM-landing fragility** for plugin pages. Labels/roles can change with any
   DSH release. Mitigation: landing is best-effort; the page is always usable
   without it; no data is read out of the WebView.
3. **The right rail's promise vs. no browser API.** R7 names a 浏览器 card that
   DSH 0.2.2 cannot serve. `architecture.md` already decided to omit it; the
   acceptance screenshots must not expect it (or the Lead should re-scope it as
   a Cuplivo utility with a visible "not a DSH capability" difference).
4. **Terminal card.** A real terminal is a large component; a read-only
   attach is cheap, a full emulator is not. Decide MVP scope before the rail
   slice lands.
5. **Transcript rule drift** (surfaceOp append-only, tool-result-after-turn,
   inbox splice) — the fold is where subtle duplicates/omissions appear. The
   fixture corpus from `protocol.md` and a strict unit matrix is the mitigation.
6. **No local build loop.** A single compile error costs a CI round trip. Keep
   slices small, batch imports, and let `dart analyze` (allowed locally) catch
   type errors before push — but no behavioral verdict without CI.
7. **E2E reachability of the real Host** (already a roadmap risk). If the LAN
   Host is unreachable from the runner, the scenario needs a reported fallback;
   screenshots then fail acceptance honestly.
8. **Version drift during the branch's life.** If the target DSH updates past
   0.2.2-rc.1, re-verify: `session/events`, control `val`, surfaceOp, plugin
   manager additions, schedule verbs, upload `mediaType`. The feature-detection
   recipes (§7.3) keep the client working; the deltas table is the checklist.
9. **Live WebSocket on mobile networks**: NAT/proxy timeouts are shorter than
   the 2 s heartbeat design assumes only in pathological cases; the mux
   reconnects, but a chat may see repeated snapshot rebuilds. Mitigation: keep
   the follow's `maxMessages`/`turnWindow` as the official client does, so a
   snapshot is small; don't accumulate huge in-memory logs.
10. **Model/provider parity**: the models page mirrors DSH's provider schema,
    which is adapter-specific and can grow (pi-ai knobs). Scope it to R11's
    fields; unknown fields are preserved, not rendered.

### 10.2 Open questions for the Lead (decisions, not research gaps)

1. **浏览器 card**: hide entirely (architecture says so) or show a disabled
   row with "当前服务端不支持"? R7's screenshot parity may prefer the latter.
2. **Terminal card**: read-only MVP, full xterm in a later phase, or omit?
3. **Plugin settings tabs**: honest MVP is one `插件` tab whose body is the
   official page; per-plugin tabs need DOM discovery. Which does acceptance
   expect?
4. **`自定义提供商` creation on a phone**: R10/R11 name the row; is full
   creation in scope, or is editing existing providers enough?
5. **Automation (自动化任务)**: native read-only list, WebView, or defer?
6. **DeepSeek account row**: hide, or show as "请在官方网页登录"?
7. **Multi-remote**: is one connected remote at a time enough for the PR?
8. **Reference/local model separation**: confirm no DSH model ever appears in
   the local conversation model list (product rule) — the current `lib/core/dsh/`
   design assumes it.
9. **Brand**: the whale glyph is already used for the DeepSeek provider; reuse
   it for the harness avatar (current implementation) or use a neutral icon?
10. **E2E seed data**: which sessions/workspaces the e2e-vps Host must have so
    the screenshots match the reference images (P4 owns the environment).

---

## 11. v2 implementation note (remote-control round)

This section maps the v2 code that landed in the same worktree; it deliberately
does not repeat the wire contract. Read
[`client-api.md`](client-api.md) §15 for methods, payloads and stream frames,
and treat the official-client behavior described there as the reference.

### 11.1 Terminal wiring

- `lib/features/harness/services/dsh_terminal_runtime.dart` adapts DSH's
  `terminal/*` endpoints to Cuplivo's `WorkspaceRuntime`/`PtySession`
  interfaces ([`v2-reuse-map.md`](v2-reuse-map.md) §1). `DshWorkspaceRuntime`
  implements `openPty` as `terminal/create` + `terminal/attach`; the Host owns
  the cwd/shell/env, so the local `cwd`/`env`/`mounts` arguments are ignored
  and the panel only reads `terminal/environment` for display.
- `DshPtySession` turns `snapshot`/`output` frames into the byte stream the
  `terminal_view` emulator consumes, publishes `state`/`ack` changes through a
  `writable` notifier, splits a write at the Host's `maxInputBytes`, keeps one
  uplink sequence across `write` and `resize`, and completes its exit future
  on `state:exited|failed`. An unknown frame is ignored, never fatal.
- `lib/features/workspace/terminal/widgets/terminal_surface.dart` is the
  extracted page body (tab strip, emulator, key bar) used by both
  `lib/features/workspace/terminal/terminal_page.dart` and the harness hosts:
  `lib/features/harness/widgets/terminal/dsh_terminal_panel.dart` (rail) and
  `lib/features/harness/pages/terminal/dsh_terminal_page.dart` (full screen),
  sharing `dsh_terminal_launcher.dart`. When the Host reports
  `writable:false`, the surface shows its read-only banner and no key bar.
- The emulator renders through `terminal_view`'s `TerminalPainter`: output is
  painted cells, not text widgets. Widget tests therefore assert the seam's
  host side (frames fed, `write` calls' sequence/data, `terminal/close` on
  dispose) rather than looking for screen text.

### 11.2 Attachment flow

- The existing composer picker stages local paths; before `session/prompt`,
  `lib/features/harness/services/dsh_attachment_upload_service.dart` turns
  them into prompt parts. Images stay inline bytes
  (`DshPromptAttachment.image`, base64) after the Host's `imageLimits` budget
  is enforced (count, `mediaTypes`, `maxImageBytes`, `maxMessageImageBytes`);
  documents go through the upload route and become `DshPromptAttachment.file`
  with the receipt id.
- Refusals are typed (`DshAttachmentFailure` with the real numbers) and mapped
  to a localized sentence; the draft is kept, so nothing is half-sent.
- In the transcript, image parts are durable references, not URLs:
  `DshGatewayChatSession` prefetches `DshSession.attachmentBytes` (which calls
  `session/attachment`) per `attachmentId` into an in-memory map and maps them
  to the existing chat attachment model. Nothing is written to disk.

### 11.3 Context ring

- `lib/features/harness/services/dsh_context_usage.dart` maps the Host's
  `contextPressure` projection to the shared ring's `ContextUsageSnapshot`
  (`usedTokens`, `contextWindow`, ratio) and feeds the composer override.
  The buckets are zero and the state is `exact` on purpose: DSH computes one
  honest total, so Cuplivo does not fabricate its twelve composition buckets;
  the sheet shows the real two-segment used/free bar.
- The ring is hidden when the projection or the window is absent; a state with
  no denominator never renders.
- One detail to keep in mind: DSH's own meter takes
  `projectedTokens ?? pressureTokens`, while this mapper currently reads
  `pressureTokens` (the projection model calls the former a post-turn hint).
  The two differ slightly while a projected estimate exists; reconcile when
  the mapper is next touched.

### 11.4 Plus and slash menus

- `lib/features/harness/widgets/chat/dsh_plus_sheet.dart` mirrors the official
  `+` menu structure but only enables rows with a wire path: 添加 —
  文件 (attachment picker); 目标/计划/反馈 are disabled with their honest
  reason. 指令 — 压缩 runs `/compact` only when the catalog advertises it,
  权限 and 模型 open the existing pickers, 下载日志 is disabled (the protocol
  has no log-download endpoint).
- `lib/features/harness/widgets/chat/dsh_slash_commands_sheet.dart` lists the
  Session's `commands/list` roster; `harness_conversation_view.dart` intercepts
  a send whose leading token is an advertised command and calls
  `DshGateway.executeCommand` → `commands/execute`. A success text is shown as
  a notice and a failure keeps the draft; any line the Host does not claim is
  sent as an ordinary prompt again. A slash line carrying attachments is sent
  as a prompt instead of a command.

### 11.5 Plugin surfaces without plugin knowledge

- DSH plugins contribute React slots inside the official SPA and the Host RPC
  does not enumerate them, so Cuplivo reads the official UI once: the harvest
  script in `lib/features/harness/services/dsh_surface_harvest.dart` reads the
  sidebar labels (`[data-slot="sidebar.panellist"]`) and the right-rail guide
  cards (`[data-sidebar-right-guide-entry]` + kind), and posts
  `{v, sidebar, rail}` to the `CuplivoHost` handler.
- `DshWebUiView` (`lib/features/harness/widgets/dsh_web_ui_view.dart`) runs the
  script once per view generation and tolerates a miss;
  `DshSurfaceSnapshot.parse` degrades to empty on any unexpected payload. The
  home controller keeps one snapshot per authority
  (`harness_surface_entries.dart` builds stable keys from labels), and R5/R7
  render the labels verbatim with generic icons — no plugin name, id or label
  is hardcoded. Opening a harvested row runs a landing script that clicks its
  label (or its rail kind) in the embedded official WebUI; built-in rows stay
  native and are excluded from the harvested list.
- The slot/DOM evidence and the bounded landing protocol are in
  [`plugin-compat.md`](plugin-compat.md) §4–§6; nothing here asserts a URL.

### 11.6 Honest limits

- **PDF/office previews are WebView-dependent.** PDFs open through the
  embedded official WebUI on the authenticated `/api/file?path=…&v=…` URL, so
  they need a platform whose WebView backend is available. Office documents
  are classified but currently show the unsupported metadata card — no native
  renderer and no office→PDF conversion is wired, so they would need the same
  WebView path (or Host-side conversion) before they can render.
- **Unmounting the rail terminal closes the Host terminal.** The rail panel
  owns the launch, and `dispose()` calls `closeCreatedTerminals()` →
  `terminal/close`; switching rail tabs or leaving the page ends that shell.
  Only terminals this launch created are closed — a terminal it attached to
  from another surface is not adopted.
- **Relative images in remote markdown do not resolve.** The markdown preview
  materializes the remote file's text locally; a relative image link has no
  workspace base URL, so it renders unresolved (absolute links still need the
  authenticated route). Documented as acceptable for v2 in
  [`v2-reuse-map.md`](v2-reuse-map.md) §5.
- **Harvested plugin rows need one official-WebUI visit.** The snapshot is
  in-memory only and taken when a WebUI page opens; before that visit the
  sidebar/rail show only the built-in entries.

---

## Appendix A — endpoint index (0.2.2-rc.1)

All names are `<namespace>/<method>` for `POST /api/<namespace>/<method>` or a
mux `open`. ★ = the brief's acceptance flow needs it, ○ = optional/nice-to-have,
— = documented for completeness, out of scope.

```text
$events/result                      unary      ★ answer approvals/questions (mux clientId)
session/list create follow events page prompt cancel updateQueue rename   ★
session/attachment search fork state wait projections observeState        ○ / —
session/observeProjections observeEvent initializeDefaultModel            ○ / —
session/control  (mux)                        ★ list metadata + permission/model
session/modelCatalog selectModel              ★
session/fork search canOpenWorkspacePath openWorkspacePath workspacePathApplications  ○ / —
permissionPresets/catalog                     ★
commands/list execute                         ★
skills/list fileReferences/list sessionReferenceResolver/candidates       ○
fileUploads/upload                            ★ (fallback only)
settings/describe mutate update replace openSettingsDocument              ★ describe/mutate
credentials/describe set unset                ★ (describe/set)
llm/listProviders listConfigurableProviders discoverModels                ★ / ○
workspace/follow create rename delete insertBefore insertSessionBefore    ★ follow/create/rename
workspace/archiveSession unarchiveSession pinSession unpinSession initializeDefault  ★ archive
directoryPicker/list createDirectory          ○ ; pick — (host desktop)
pluginManager/listBundles listPlugins setBundleEnabled setPluginEnabled   ★ list + toggle
pluginManager/installBundle removeBundle inspect registries waitForInstall cancelInstall  ○
pluginManager/listVersions readBundleDetail updateBundle                  —
pluginManager/listVersionExemptions setVersionExemption                   —
pluginInventory/list                          ★ (native plugin rows)
pluginMarket/listIndexes readEntryDetail search setIndexes                —
pluginRecommendations/describe                —
agentPresets/list read select                 ○ (preset picker, if built)
job/list follow kill                          ○
schedule/catalog create edit deleteInactive deliveryLimits history list run view  ○/—
toolResults/watch                             ○
workspaceFiles/list read readBytes stat changes  ○ (rail)
terminal/create attach list close rename shells environment retain        ○ (rail)
officeToPdf/generation render                 —
goals/get create edit pause resume complete clear                         —
actionCards/act                               —
messageFeedback/list put delete sessionFeedback/record                    —
speech/catalog configure prepare follow cancelPreparation transcribe      —
account/getState getProfile getBalance startSignIn cancelSignIn signOut getUnnotifiedBonuses ackBonusNotified hasRunningAccountTasks watch watchExpiry  —
remoteAccess/follow                           —
subagents/prompt interruptByParent            —
cotTranslation/limits translate               —
productAnalytics/enabled report watchPolicy   —
dynamicCordisRunner/* liveshareShares/* forgePanel/* pluginRegistryProbe/fastest  —
userQuestions/answer attachWait               ★ (timed questions)
```

(Not shown: `$events` itself and the `remote.mux` frame vocabulary — §2.3/§2.4.)

## Appendix B — error codes a client actually branches on

Codes arrive as `DshRemoteException.code` (HTTP 200 `ok:false`, or a mux
`error` frame). Unlisted codes: show `code: message`, never crash.

| code group | codes | client behavior |
|---|---|---|
| gateway/carrier | `gateway/bad-request`, `gateway/arguments-invalid`, `gateway/protocol`, `gateway/internal`, `gateway/cancelled`, `gateway/service-unavailable`, `gateway/peer-disposed`, `gateway/uplink-overflow`, `gateway/method-not-found`/`method-unavailable`, `gateway/not-found` | arguments-invalid = client bug/version drift (log, don't retry); method-not-found/not-found = capability absent; cancelled = user/intent cancellation; uplink-overflow = terminal/job input too fast; internal/service-unavailable retryable once |
| session | `session/not-found`, `session/agent-busy`, `session/writer-held`, `session/model-unavailable`, `session/provider-models-unavailable`, `session/provider-credentials-unavailable`, `session/attachment-invalid`, `session/fork-unavailable`, `session/steer-unavailable`, `session/queue-item-not-found`, `session/conflict`, `session/migration-required`, `session/invalid-time-zone`, `session/wait-timeout`, `session/workspace-attach-failed`, `session/projections-unavailable`, `session/observation-ended` | map to text: model/credentials → open model/provider settings; busy/writer-held → another client is writing, retry later; steer-unavailable → fall back to queue; wait-timeout → normal for `session/wait` |
| settings/credentials | `settings/conflict`, `settings/rejected`, `credential/rejected`, `llm/model-discovery-rejected` | conflict → re-read revision and re-apply; rejected → explain env-supplied credential cannot be overwritten |
| permission | `permission/...` (invalid preset / locked) | reload `permissionPresets/catalog` and keep old value |
| workspace/files | `workspace/invalid-path`, `workspace/name-conflict`, `workspace/not-found`, `workspace/move-invalid`, `workspace/session-active`, `workspace-file/not-found`, `workspace-file/not-text`, `workspace-file/too-large`, `workspace-file/outside-workspace`, `workspace-file/not-directory`, `workspace-file/not-regular-file`, `workspace-file/unknown-workspace`, `directory-picker/unavailable`, `directory-picker/unreadable`, `directory-picker/exists`, `directory-picker/create-failed` | inline messages; `session-active` details carry what must stop (offer `stopActivity:true` after confirmation) |
| plugins | `plugin-manager/unknown-bundle`, `plugin-manager/detail-unavailable`, `plugin-manager/invalid-language`, `plugin-market/*` | show the Host message; re-list after a change |
| terminal | `terminal/control-unavailable`, `terminal/limit-reached` | read-only panel / close a terminal |
| schedule | `schedule/input-invalid`, `schedule/target-archived` | form validation / refresh list |
| agent preset | `agent-preset/conflict`, `invalid`, `locked`, `not-found` | preset picker only (optional) |
| questions | `user-question/...`, `subagent/*` | question card failure; subagent out of scope |

## Appendix C — host events a catalog/transcript caches on

Delivered as `$events` `emit` frames (`{"type":"emit","event":name,"args":[…]}`);
`waterfall` frames are the approvals/questions (§3.4). Treat unknown names as
no-ops, and re-list after any event you cannot interpret:

| event | invalidates |
|---|---|
| `api-session/added`, `api-session/removed`, `api-session/status`, `api-session/activity` | session list/rows, running dots |
| `session/created`, `session/disposed`, `session/event` | session list; `session/event` only if a screen wants log-level push (the follow already delivers it) |
| `settings/document-updated` (ns, revision), `settings/conflict` | settings describe / engine settings / provider forms |
| `credentials/reference-updated`, `credentials/record-updated` | provider API-key state |
| `llm/models-updated`, `llm/adapters-updated` | model catalog, provider list |
| `permission-presets/catalog-changed` | permission presets |
| `commands/change`, `skills/change` | composer `+`/slash menus |
| `plugin-manager/changed`, `plugin-manager/install-state`, `install-log`, `update-state`, `plugin-market/changed` | plugin list, install progress |
| `workspace/...` (via `workspace/follow`, not emits) | workspace rail |
| `schedule/changed` | automation list |
| `locale/change`, `theme/change` | only when the WebView/official page is open (native UI follows Cuplivo settings) |
| `agent/status`, `agent/error`, `agent/assistant-stream`, `agent/inbox/*` | only if a screen subscribes outside `session/follow` (normally not) |

`$events` is not a public versioned API: never *require* an event; on a
generation change re-read the catalogs once and continue (that is the
no-polling refresh path of §6.3).
