# DeepSeek Harness `dsh web` wire protocol — ground truth for a native client

Status: research note for `feat/cuplivo-dsh`. This is the server API contract a
Dart/Flutter client implements against. It is written so that the client can be
(and was) implemented without reading DSH sources again.

- **Protocol version tested: DSH `0.2.2-rc.1`** (installed at
  `/usr/local/lib/node_modules/@deepseek-ai/dsh`), stock `dsh web` profile:
  `@deepseek-ai/dsh-base` + `@deepseek-ai/dsh-web-app` only. A second, isolated
  instance was booted for every capture below (isolated `DSH_HOME`, scratch port,
  fresh browser/API credentials); the long-running production instance was not
  probed.
- Authoritative sources used: the generated `typert.remote-client.d.ts` /
  `typert.host.js` faces of every installed `@deepseek-ai/dsh-*` package, the
  compiled client/server bundles, and live HTTP/WS capture against the isolated
  instance.
- Reference client cross-check: `/root/research/dsh-go/packages/dsh_client`
  (`dsh_client`, README claims verification against DSH `0.2.0-rc.2` and
  `0.2.1-rc.2`). Where it differs from 0.2.2-rc.1 this document says so in §8.
- Nothing in this file is Cuplivo code. Never copy tokens, hosts or IDs from a
  real deployment into this repository; the samples below are redacted.

Legend used in the samples: `dshtoken` = launch token, `<session-id>` /
`<workspace-id>` / `<rpc-id>` = UUID-shaped identifiers, `<host>` = deployment
authority, `…` = elided.

## 0. Verification status

Live-verified against 0.2.2-rc.1 (real requests, isolated instance):

| Area | Verified |
|---|---|
| `GET /?token=` → 303 + `Set-Cookie` v1; wrong token 401; index 200 with v1 cookie | ✅ |
| `GET /connect?token=…&interactions=answer` → 302 `./api/remote.mux` + v2 cookie; no token 401; bad `interactions` 400 | ✅ |
| v2 API cookie rejected by `GET /` (401) but accepted by `/api` + mux | ✅ |
| Host/Origin fence: cross-`Origin` 403; untrusted `Host` on WS upgrade 403; no cookie on `/api` 401 | ✅ |
| `POST /api/<endpoint>` envelope: success, `ok:false` failure, `gateway/arguments-invalid`, `session/not-found`, plain 404 for an unknown endpoint | ✅ |
| Unknown endpoint → HTTP 404 `not found` (plain text body) | ✅ |
| `session/control` baseline + live projection update frames; fresh baseline on reconnect | ✅ |
| `session/observeState` (state immediately), `session/observeProjections` (`ready`), `workspaceFiles/changes` (`ready`) | ✅ |
| `$events`: `ready` / `emit` / `waterfall` frames; `$events/result` answer accepted, unknown `clientId` rejected | ✅ |
| `session/follow`: snapshot, replay records, live `event` items, `assistant-stream` frames | ✅ |
| `session/create`, `list`, `state`, `page`, `events`, `projections`, `rename`, `selectModel`, `prompt`, `cancel`, `wait`, `fork`, `search` (disabled result), `initializeDefaultModel`, `canOpenWorkspacePath`, `openWorkspacePath` (failure), `workspacePathApplications` | ✅ |
| Real prompt → streamed turn → commit (`turn/start` … `assistant/message` … `turn/end`), including text+image+file content parts and multi-step tool use | ✅ |
| Approval waterfall (`approval/request`) answered `rejected`; audit events appended | ✅ |
| User-question waterfall (`user-questions/request`) answered; question projection follows | ✅ |
| `commands/list`, `commands/execute` (`/permission …` changes the `permissions` projection) | ✅ |
| `skills/list`, `goals/create`/`get`, `schedule/create`/`list`/`view`/`edit`/`delete`, `permissionPresets/catalog` | ✅ |
| `workspace/create`/`rename`/`insertBefore`/`delete`/`initializeDefault`, `workspace/follow` baseline, `directoryPicker/list`, `directoryPicker/pick` (unavailable on web) | ✅ |
| `workspaceFiles/list`, `/api/session/uploadFileBinary?sessionId=…`, `/api/file?path=…` (302 to versioned URL, 403 for a directory) | ✅ |
| `llm/listProviders`, `llm/listConfigurableProviders`, `llm/discoverModels` (rejected with 401 from an upstream), `settings/describe`/`update`/`mutate` (+ `settings/conflict`), `credentials/describe`, `account/getState`, `pluginInventory/list`, `pluginManager/listBundles`/`listPlugins`/`registries` | ✅ |
| Presence/absence probe for the 0.2.2 endpoint catalogue (§8) | ✅ |

Code-read only (not exercised live) and stated as such where it appears:
multipart/attachment responses, TLS/`Secure` cookies, `--trusted-host`
acceptance of a non-loopback authority, response gzip, `terminal/*`, `job/*`,
`subagent*`, `pluginMarket/*`, `messageFeedback/*`, `session/attachment`
success path, `session/updateQueue` success path, `session/observeEvent`,
`account/watch`, `job/follow`, `remoteAccess/follow`, `toolResults/watch`,
WebView/plugin-panel hosting, provider create/update/delete through settings
(the flow is code-read from the official Models page).

---

## 1. Transport and authentication

### 1.1 Endpoint layout

A `dsh web` server is one HTTP origin (`host:port`, optionally under a mount
prefix from `--public-url`). Everything a client needs is on four routes:

| Route | Method | Purpose |
|---|---|---|
| `/?token=<launch token>` | GET | Browser-session login: mints the **v1** cookie, 303 to `./` |
| `/connect?token=<launch token>&interactions=answer` | GET | API-operator login: mints the **v2** cookie, 302 to `./api/remote.mux` |
| `/api/<namespace>/<method>` | POST | Unary RPC over the JSON envelope (§2) |
| `/api/remote.mux` | GET + WebSocket upgrade | Multiplexed logical streams (§3) |
| `/api/session/uploadFileBinary?sessionId=…[&mediaType=…]` | POST | Raw-byte attachment upload (non-RPC route, §4.10) |
| `/api/file?path=<absolute path>[&v=…]` | GET/HEAD | File bytes for images/attachments (non-RPC route, §4.10) |

The launch URL is printed on the server's stdout at startup:

```
dsh web: http://<host>:<port>/?token=<43-char base64url token>
```

The token is **per-process**: it is regenerated on every boot and is not
persisted. The printed URL also carries any `--public-url` path prefix, so parse
it as a URL and keep the base path; resolve all routes relative to it.

### 1.2 Browser-session login (`GET /?token=…`, cookie v1)

`BrowserAuth.authorizeIndex` accepts the launch token only on `GET /` with
exactly one `token` query parameter and a Host that passes the trust fence. A
valid token answers:

```http
HTTP/1.1 303 See Other
cache-control: no-store
location: ./
referrer-policy: no-referrer
set-cookie: dsh-auth-<base64url sha256(authority)>=v1.<payload>.<sig>; Max-Age=2592000; Path=/; Expires=<utc>; HttpOnly; SameSite=Strict
```

Anything else (wrong token, token on another path, more than one `token`, other
method) answers the same minimal **401** with body:

```
dsh web authentication required; reopen the URL printed by dsh web.
```

A `GET /` carrying a valid **v1** cookie instead of a token serves `index.html`
(200, the SPA shell with server-injected globals, see §7.6). A **v2** cookie is
*not* accepted here (401) — see §1.3.

Cookie details (verified via decoded payload):

- Name: `dsh-auth-` + base64url(SHA-256(**authority** as the request saw it)).
  For plain HTTP the authority is `host:port`; for TLS it is the full
  `https://host:port` origin. A different port therefore means a different
  cookie name; persisting a cookie across a port change is useless.
- Value v1: `v1.<base64url JSON>.<base64url HMAC-SHA256(body)>`, body
  `{version:1, authority, issuedAt, expiresAt}`.
- Attributes: `Max-Age=2592000` (30 days, `cookieMaxAgeDays` default),
  `Path=/`, `Expires`, `HttpOnly`, `SameSite=Strict`, and `Secure` **iff the
  listener itself serves TLS** (`--tls-cert`/`--tls-key`). A proxy's forwarded
  headers or `--public-url` never add `Secure`.
- Signing secret: 32 random bytes persisted in `$DSH_HOME/.credentials.yaml`
  (`client-connection/browser-session`, `kind: grant`). So a v1 cookie survives
  `dsh web` restarts on the same home and port for up to 30 days, while the
  launch token does not. Treat the cookie as a bearer credential (secure
  storage) and re-login on 401.
- The server never accepts a token more than once per request and never
  redirects it anywhere else.

The v1 cookie is a **browser Peer**: principal `{kind:'owner'}`,
`interactions = 'answer'` (the Peer default). It authenticates `/api`, the mux
upgrade, and the SPA index. It can open several mux sockets concurrently.

### 1.3 API-operator login (`GET /connect?token=…`, cookie v2)

`/connect` exchanges the same launch token for an *independent* API peer:

```http
GET /connect?token=dshtoken&interactions=answer
→ HTTP/1.1 302 Found
cache-control: no-store
location: ./api/remote.mux
set-cookie: dsh-auth-<same name>=v2.<payload>.<sig>; Max-Age=2592000; Path=/; Expires=…; HttpOnly; SameSite=Strict
```

- `interactions`: at most one query parameter, either `answer` or `none`;
  omitted defaults to **`none`**. Any other value or a repeated parameter is a
  **400** whose body is `interactions must be declared once as answer or none`.
- A peer created with `interactions=answer` may open `$events` and answer
  approvals/questions; `interactions=none` may call every unary RPC (verified)
  but `$events` fails with a `gateway/interactions-forbidden` stream error.
  A browser (v1) peer is always `answer`.
- v2 payload adds a random peer id: `{version:2, authority, id, issuedAt,
  expiresAt}`. The signed id is how `/api` maps the cookie back to a live peer;
  the cookie is **only valid while that peer lives** (i.e. while the process
  runs). A fresh `/connect` on a restarted server is required.
- The redirect target `./api/remote.mux` is a hint only; a native client can
  ignore it and use the cookie directly.
- **One socket per v2 peer**: a second WebSocket upgrade with the same v2
  cookie is rejected with **409** while the first is open (verified). If a
  client needs several concurrent sockets it must either use a v1 cookie or
  request one `/connect` per socket.
- A v2 cookie cannot render the SPA (`GET /` → 401).

**Recommendation for Cuplivo:** use the **v1 browser cookie** for everything
(login via `GET /?token=…`). It is accepted by `/api`, the mux, and the SPA
(needed for WebView hosting in §7.6), it allows several sockets, and it survives
restarts. Use `/connect?interactions=answer` only when the product wants a
separate API identity per device; if it is used, keep its cookie value separate
from the v1 value (both share one cookie name, so one browser cookie jar can
only hold one of them).

### 1.4 Host / Origin trust fence (`--trusted-host`)

Every `/api` request and every mux upgrade runs the same fence
(`isTrustedApiRequest`) before authentication:

1. A `Host` header is required (a non-browser client must send it explicitly).
2. Its hostname must be one of:
   - loopback: `localhost`, `[::1]`, or any IPv4 `127.0.0.0/8`;
   - the listener's own **bind IP literal** (any port; this is why a plain
     `http://<lan-ip>:3080` works without configuration when the server binds
     that address);
   - a `--trusted-host` **authority**: an exact `host:port`, or a port-less
     `host` matching any port.
3. `Sec-Fetch-Site: cross-site` is rejected.
4. If an `Origin` header is present it must be the same http(s) authority as
   `Host`; otherwise 403. Native clients should simply **not send `Origin`**.

Running `dsh web` on a non-loopback address prints a warning, and the it help
text recommends `--trusted-host`. Practical rule for Cuplivo: the user must
have started the server with `--host <LAN IP>` (or a concrete interface) and, if
the app dials a **hostname or a NAT address that is not the bind address**, with
`--trusted-host <that authority>`. Behind an HTTPS reverse proxy the proxy must
also be admitted (`--trusted-host app.example`), and `--public-url` alone grants
nothing.

Failure codes: 401 = missing/invalid credential; 403 = fence (untrusted Host,
cross-site or cross-origin); 409 = duplicate socket ownership for a v2 peer.

### 1.5 HTTP vs HTTPS

- Plain HTTP: scheme `http` / `ws`; cookie without `Secure`; the fence still
  applies (Host is the defence against DNS rebinding).
- TLS listener (`--tls-cert`, `--tls-key`): scheme `https` / `wss`; cookie gains
  `Secure`; the accepted authority becomes the full origin (cookie name
  changes with scheme).
- If a TLS proxy terminates in front of a plain-HTTP DSH, the app must use
  `https`/`wss` toward the proxy and send the proxied public `Host`; the cookie
  stays non-`Secure` (which only matters to browsers, not to a native client).
  A WebView on an `https` page cannot use a host-only non-`Secure` cookie for
  that origin.

### 1.6 Readiness, timeouts, heartbeats, reconnects

- There is **no** health/version endpoint in 0.2.2. Readiness = `GET /` returns
  200 with a valid cookie **and** the mux accepts the upgrade and `$events`
  answers `ready`. The server mounts the mux route only after the application
  is ready, so an upgrade before readiness fails.
- The official frontend's recovery timings are injected into the index as
  `globalThis.__DSH_CONNECTION_RECOVERY__` (verified):
  `{backoffBaseMs:500, backoffFactor:2, backoffMaxMs:10000,
  generationReadyWarnMs:3000, generationReadyTimeoutMs:15000}`.
- The server pings every `websocketHeartbeatIntervalMs` (default **2000 ms**)
  and terminates a socket after **2** missed pongs (≈4–6 s). Any WebSocket
  library that answers Ping automatically is fine; a client may also ping on
  its own (the reference client uses 15 s for dead-link detection).
- There is no request timeout on unary RPCs and no idle timeout on streams;
  client-side deadlines are the client's business (`session/wait` takes its own
  `timeoutMs`).
- No replay/resume across sockets (§3.9); reconnect = new generation.

### 1.7 Limits

| Limit | Default | Notes |
|---|---|---|
| Request body, buffered routes | 314,572,800 bytes (300 MiB) | `client-connection.maxRequestBodyBytes`; image budget check adds 1 MiB envelope headroom |
| Aggregate images per message | 20 MiB message image bytes, 50 MiB per image, 20 images | Live `imageLimits` projection: `{maxImageBytes:52428800,maxImagesPerMessage:20,maxMessageImageBytes:20971520}` |
| WS uplink inbox per stream | 262,144 bytes | `streamInboxBytes`; exceeding fails the stream (`gateway/uplink-overflow`) |
| WS permessage-deflate | enabled (`websocketCompression: 'deflate'`) | messages ≥ 1024 bytes are compressed |
| HTTP response gzip | `'none'` unless configured (`compression: 'gzip'`) | no request compression, no Content-Encoding on JSON by default |
| WebSocket heartbeat | 2 s, 2 missed pongs → terminate | see above |

---

## 2. Unary RPC (`POST /api/<namespace>/<method>`)

### 2.1 Envelope

Request (JSON, `content-type: application/json`, exactly this shape):

```json
{
  "type": "client-request",
  "rpcId": "<rpc-id>",
  "method": "session/list",
  "payload": { "args": { "_request": {} } }
}
```

- `rpcId`: client-chosen correlation string. The official client uses a random
  UUID v4. The server echoes it; the client must compare it and reject a
  mismatch.
- `method` must equal the path's `<namespace>/<method>`; a mismatch yields a
  `gateway/bad-request` result whose `rpcId` still echoes the request.
- `payload` must be **exactly one plain object with only an `args` key**.
  `args` keys are the descriptor's wire parameter names — **exactly**, with all
  required names present and no extra names. Unknown/missing names produce
  `gateway/arguments-invalid`.
  - Names follow the TypeScript parameter names of the generated face. The
    quirk to know: `session/list` requires the literal key `_request`
    (`{"args":{"_request":{}}}`) because the parameter is named `_request`;
    a `{}` is rejected. Everything else in the catalogue is a plain name such
    as `request`, `agentId`, `sessionId`, `path`, etc.
- Endpoint grammar: two `/`-separated segments from `[A-Za-z0-9_$.-]`
  (`$events/result` keeps its literal `$`).

Response (HTTP 200, JSON):

```json
{ "type": "server-response", "rpcId": "<same>", "result": { "ok": true, "value": { } } }
{ "type": "server-response", "rpcId": "<same>", "result": { "ok": false, "error": { "code": "session/not-found", "message": "session \"…\" not found", "details": { "sessionId": "…" } } } }
```

- `result.ok === true` may omit `value` for void methods (e.g.
  `session/initializeDefaultModel`, `credentials/set`). Treat absent `value` as
  `null`.
- `result.ok === false` always carries `error.code` (stable string),
  `error.message` (diagnostic, may be localized? no — English), and
  `error.details` (object; shape is per-code, see §6).
- The HTTP status is 200 for both branches. Only transport/auth/fence
  rejections use non-200 statuses (§2.3).

### 2.2 Binary result attachments (multipart)

When a result value embeds binary (for example `workspaceFiles/readBytes`,
`officeToPdf/render`), the server replaces each byte string with `null` and
answers `multipart/form-data`: one `metadata` part holding the JSON envelope
plus `attachments: [{path: [...], codec: 'bytes', part: 'bytes-0'}]`, and one
`bytes-N` Blob part per attachment. To rebuild the value, parse `metadata`,
walk each `path` (array indices as numbers, object keys as strings), and set
the `null` placeholder to the corresponding part's bytes. Detect multipart by
the response `content-type`. Not exercised live in the default profile (listed
as code-read in §0), but the shape is exactly as above.

### 2.3 Transport-level rejections (not the envelope)

| Status | Body | Cause |
|---|---|---|
| 401 | `unauthorized` | No/invalid/expired credential on `/api` |
| 403 | `forbidden` | Host/Origin fence (§1.4) |
| 404 | `not found` (plain text) | Unknown endpoint, method not claimed by the gateway, or wrong path |
| 400 | `body is not JSON` | Body unparsable |
| 415 | `content type must be application/json` | Wrong `content-type` |
| 400 | `{"type":"server-response",…,"result":{"ok":false,"error":{"code":"gateway/bad-request",…}}}` | Envelope invalid (bad rpcId/type) or `method` ≠ URL endpoint; the body is still an envelope, `rpcId` echoing the raw id when it was a string |

An endpoint that exists in one DSH release and not another answers **404 plain
`not found`** — that is the feature-detection signal (§6.3). A 404 is *not* a
`RemoteError` and must not be retried.

### 2.4 What the client should send

- `headers`: `content-type: application/json`, `cookie: <auth cookie>`,
  `host: <authority>` (only needed if the HTTP library would otherwise send a
  different authority), and **no `Origin`**.
- Do not follow redirects for `/api`; a 302 there is unexpected.
- Reuse the HTTP connection pool, but expect the server to close idle
  keep-alive sockets after ~5 s; a request racing that close surfaces as a
  transport error (`ECONNRESET`-like) and is safe to retry once for idempotent
  reads (all `session/*` reads, `settings/describe`, `*/list`, etc.).
- Correlate by `rpcId`; allow out-of-order responses if the HTTP layer pipelines
  (the reference HTTP carrier does not pipeline; one request per channel call).

---

## 3. Streaming: `/api/remote.mux` WebSocket

One WebSocket carries an arbitrary number of **logical streams**. The route is
mounted after application readiness; the upgrade uses the same cookie and the
same Host/Origin fence as `/api`.

### 3.1 Upgrade

```http
GET /api/remote.mux HTTP/1.1
Host: <host>:<port>
Cookie: dsh-auth-…=v1.…
Upgrade: websocket
Connection: Upgrade
Sec-WebSocket-Key: …
Sec-WebSocket-Version: 13
```

- No subprotocol is required or negotiated (`ws.Server({ noServer: true })`
  with default options).
- `permessage-deflate` is negotiated when the client offers it
  (`websocketCompression: 'deflate'` is the default).
- Rejection statuses are written before the socket is handed to `ws`:
  **401** (unauthenticated), **403** (fence), **409** (this v2 peer already owns
  a socket).
- The reference client sends no `Origin` header; `dart:io` `WebSocket` does not
  by default.

### 3.2 Frame envelope (both directions are JSON text frames)

Client → Host:

```json
{"type":"open","streamId":"<id>","endpoint":"session/follow","payload":{"args":{ … }}}
{"type":"item","streamId":"<id>","value":<json>}          // uplink item (only for uplink-capable endpoints)
{"type":"end","streamId":"<id>"}                          // uplink half-close
{"type":"cancel","streamId":"<id>"}                       // cancel the logical stream
```

Host → Client:

```json
{"type":"item","streamId":"<id>","value":<json>}
{"type":"end","streamId":"<id>"}
{"type":"error","streamId":"<id>","error":{"code":"…","message":"…","details":{}}}
```

Semantics:

- `streamId` is a client-chosen non-empty string, unique among open streams on
  that socket (the official client uses UUIDs; the reference Dart client uses
  UUIDs; any ASCII id works, e.g. `ctl`, `ev` — verified).
- A duplicate `open` for an id that is still open terminates the connection
  (server-side `duplicate Remote stream id`). Clean up ids when `end`/`error`
  arrives.
- `open.payload` has the same `{args:{…}}` shape as unary RPC (`$events`
  requires exactly `{args:{}}`).
- `cancel` aborts the endpoint's signal; the server then answers `end` (or
  `error` when the abort carried a Remote failure). A client may simply send
  `cancel` and drop its bookkeeping; late frames for the id can be ignored.
- `error` is terminal for the logical stream and carries a `RemoteError`
  (`code`,`message`,`details`). The physical socket usually stays open.
- Every stream is independent; ordering is guaranteed **within** a stream, not
  across streams. Correlation between streams (e.g. "this projection change
  belongs to that event") is by `sessionId`/`seq` fields inside the payloads.
- Uplink (`item`/`end`) is used by endpoints whose descriptor accepts a client
  stream. In the 0.2.2 catalogue none of the session/workspace/account streams
  need it; the Gateway `control` channel aborts the stream if the endpoint
  rejects an uplink item. `$events` explicitly **releases** any uplink.

### 3.3 `$events` — the application event stream

`open` with `endpoint:"$events"`, `payload:{"args":{}}`. Requires a Peer with
`interactions=answer`; otherwise:

```json
{"type":"error","streamId":"ev","error":{"code":"gateway/interactions-forbidden","message":"typert gateway: $events: forwarded Remote events require interactions=answer","details":{"endpoint":"$events"}}}
```

The first item is always the handshake:

```json
{"type":"item","streamId":"ev","value":{"type":"ready","clientId":"<event-client-id>","host":{"home":"<home>"}}}
```

then a stream of:

```json
{"type":"item","streamId":"ev","value":{"type":"emit","event":"api-session/status","args":["<session-id>",true]}}
{"type":"item","streamId":"ev","value":{"type":"waterfall","event":"approval/request","eventId":"<event-id>","agentId":"<session-id>","request":{ … }}}
{"type":"item","streamId":"ev","value":{"type":"cancel","eventId":"<event-id>"}}
```

- `clientId` identifies this event-stream generation; it must accompany every
  answer (`$events/result`).
- `emit` args are the Cordis listener arguments of the forwarded event, in
  order, JSON-normalized. See §4.8 for the event list and payload meanings.
- `waterfall` requires an answer. The request object is projected for the wire:
  the `agent` instance and its `AbortSignal` are removed; `agentId` is supplied
  beside it. Pending waterfalls are **redelivered with the same `eventId`** to
  the next answering `$events` stream (a client that reconnects must dedupe on
  `eventId`); `cancel` means the Host withdrew the request and the client must
  close the corresponding card.
- Answering is a normal unary call:

```json
POST /api/$events/result
{"type":"client-request","rpcId":"…","method":"$events/result","payload":{"args":{
  "clientId":"<event-client-id>",
  "eventId":"<event-id>",
  "outcome":{"kind":"result","value":<answer>}
}}}
```

  `outcome` is one of `{"kind":"next"}` (delegate to the Host's remaining
  answerers — for approvals this fails the request closed),
  `{"kind":"result","value":…}` (claim and answer), or
  `{"kind":"rejected","error":{"name","message","code"?,"details"?}}`.
  The successful response is `{"ok":true}` (no `value`).
  Answering with an unknown `clientId` returns
  `{"ok":false,"error":{"code":"gateway/internal","message":"typert gateway:
  Remote event result identifies no active event stream"}}`; answering another
  peer's generation returns `gateway/interactions-forbidden`.
- Approval answer value = `ApprovalOutcome` string:
  `"allowed-once" | "rejected" | "cancelled" | "unavailable"`.
- User-question answer value = `{"answers":[{"id":"<question id>",
  "selected":["<option label>", …],"custom":"<optional free text>"}]}`.
- Only the peer that owns the generation may answer. If several answering
  clients are connected, all of them receive every waterfall (the gateway
  broadcasts to answering clients) — a native client plus an open browser will
  both see the approval card; the first answer wins, the other answer is
  ignored/rejected.

> Readiness: `$events` `ready` is the strongest "Host can serve this client"
> signal. Approvals and questions can only be answered while an answering
> `$events` stream is open. On reconnect the client must reopen `$events`
> **first** (this also re-delivers pending approvals/questions), then the other
> streams.

### 3.4 `session/follow` — one session's transcript journal

```json
{"type":"open","streamId":"<id>","endpoint":"session/follow","payload":{"args":{
  "request":{
    "address":{"kind":"session","sessionId":"<session-id>"},
    "activate":true,
    "assistantStream":true,
    "maxMessages":500,
    "turnWindow":{"minMessages":50,"minTurns":2}
  }
}}}
```

- `address` is `{"kind":"session","sessionId":…}` for a normal session, or
  `{"kind":"subagent","parentSessionId":…,"childSessionId":…,"mode":…}` to
  follow a direct subagent session.
- `activate` (optional) asks the Host to attach/activate the agent for this
  read (needed to make a cold session live/running-capable). The official UI
  activates when opening a chat; a passive read omits it.
- `assistantStream: true` requests process-local live assistant frames
  (`assistant-stream` items). Without it the client only gets committed
  `assistant/message` events at the end of each step.
- `maxMessages` / `turnWindow` cut the opening snapshot: the Host pages back at
  least `turnWindow.minMessages` append-origin user/assistant messages and at
  least `turnWindow.minTurns` turn starts, but never more than `maxMessages`
  records. `hasMore` says whether older records remain.
- First item is a snapshot:

```json
{"type":"item","streamId":"<id>","value":{
  "type":"snapshot",
  "header":{"version":4,"id":"<session-id>","createdAt":1795110874000,
            "cwd":"/home/user/project","isSeeded":false,"agentPreset":"standard"},
  "cursor":20,
  "records":[ … SessionHistoryRecord … ],
  "hasMore":false,
  "projections":{"asOfSeq":20,"values":{ … every projection key … }},
  "assistantStream":{"revision":0,"activeAttempt":null}
}}
```

  `header.version` is the **session log format** version (`4` in 0.2.2), not the
  DSH version. `cursor` is the last covered `seq`; `hasMore` means older
  history exists (page it with `session/page` and `beforeSeq`).
- Then live items: `{"type":"event","event":{…}}` for every committed event
  appended while the stream is open, and
  `{"type":"assistant-stream","frame":{…}}` transient frames for the live
  step (see §5.5). A slot is either a durable event or a transient chunk, never
  both.
- On `activate`, the Host may also emit `assistant/message` settlements and
  inbox events while the turn runs; the stream never rewrites a past event.
- The stream ends with `error` (e.g. `session/not-found`, `session/writer-held`,
  `session/observation-ended`) or `end` when cancelled. It is **not**
  resumable: a reconnect opens a fresh snapshot.

### 3.5 `session/control` — global projection channel

```json
{"type":"open","streamId":"ctl","endpoint":"session/control","payload":{"args":{}}}
```

First item (verified):

```json
{"type":"item","streamId":"ctl","value":{"type":"baseline","value":{"projections":{}}}}
```

then, for every session whose projection changes:

```json
{"type":"item","streamId":"ctl","value":{"type":"projection","sessionId":"<session-id>","seq":17,
  "changes":[{"key":"permissions","val":{"currentValue":"workspace-write"}}]}}
```

- The baseline carries `Record<SessionId, {asOfSeq, values}>` for sessions the
  Host already has materialized; an empty object at connect time is normal.
- Each `projection` frame lists **only the changed keys** with their complete
  new value. `seq` is the committed event that caused the change.
- This stream is how a sidebar keeps running state, titles, token usage,
  queue/inbox, permissions and goal state for *all* sessions without opening a
  `session/follow` per session. It requires exactly one stream per client.
- Baseline is per generation: on reconnect the client replaces its whole
  projection map with the new baseline (verified: a reconnect delivers a fresh
  baseline, here 5 sessions).
- `session/state` is the polling alternative (`running`, `cursor`, `queue`,
  `pendingInput`); the official UI opens control + per-session follow.

### 3.6 Other streams in 0.2.2

| Endpoint | Args | Frames |
|---|---|---|
| `workspace/follow` | `{}` | `{type:'baseline', value:{items:[WorkspaceView], archivedSessionIds:[], pinnedSessionIds:[]}}`, then `replace`/`upsert`/`remove`/`order`/`archived`/`pinned` increments |
| `session/observeState` | `{request:{sessionId}}` | opening item is the current `SessionState` (no ready frame, verified), then one value per change |
| `session/observeProjections` | `{request:{sessionId}}` | `{type:'ready'}` (verified), then `SessionProjectionFrame` values (`projection` frames) |
| `session/observeEvent` | `{request:{sessionId,…}}` | `{type:'ready'}` then `SessionEventFrame` event entries (code-read) |
| `account/watch` | `{}` | `AccountView` snapshots |
| `account/watchExpiry` | `{}` | `'session-expired'` |
| `job/list` | `{request:{}}` | `JobListFrame` snapshots (jobs of this Host) |
| `job/follow` | `{request:{jobId}}` | `JobFollowFrame` (output/lifecycle) |
| `remoteAccess/follow` | `{}` | `{type:'baseline',owner:true}` (owner) or grants baseline + `upsert`/`remove` |
| `toolResults/watch` | `{request:{…}}` | tool-result stream for the trajectory UI |
| `subagents/…` | (n/a) | subagents are followed through `session/follow` with a subagent address |

`terminal/*` in 0.2.2 is request/response only (`create`, `list`, `attach`,
`retain`, `close`, `rename`, `environment`, `shells`); there is no
`terminal/follow` or `terminal/write` (removed — see §8).

### 3.7 Ordering and readiness rules a client must hold

1. A logical stream delivers its opening frame(s) first (`ready`, or
   `snapshot`/`baseline`); nothing for that stream precedes it.
2. `$events` readiness is per **generation**. Open it first after every socket
   (re)connect, and only then treat the connection as usable.
3. Committed events from `session/follow` are the source of truth for a
   transcript. `session/control`/`observeProjections` are derived state; never
   reconstruct a transcript from projection frames.
4. `emit` notifications may arrive **before** the corresponding
   `session/follow` event (they are separate streams). Never treat an emit as
   transcript content; use it to refresh or to show toasts.
5. After a socket is lost, everything one-way is lost: reopen streams, re-read
   the snapshot, re-fetch `session/list` if needed, and reconcile running state
   via `session/control` baseline or `session/state`. Pending waterfalls are the
   only thing the Host redelivers (same `eventId`).
6. Approvals/questions that are settled while disconnected will not reappear:
   reconcile with the `userQuestions` projection and with
   `approval/asked`/`approval/decided` events in the transcript.

### 3.8 Reconnect / resume design (recommended for Cuplivo)

- One long-lived WebSocket per connected Host; a second socket only if the
  product needs concurrent independent peers (v1 cookie allows it; a v2 cookie
  does not — 409).
- Backoff: 500 ms · 2ⁿ capped at 10 s with 50–100 % jitter (the official
  numbers, §1.6); retry forever while the connection is user-selected; surface
  `unauthorized` (401/403 on upgrade) as "re-enter token", not as a transient
  error.
- On reconnect: reopen `$events` (wait for `ready`, capture new `clientId`),
  reopen `session/control`, reopen every `session/follow` in the current view,
  reopen `workspace/follow`. Each follow/control baseline **replaces** local
  state; there is no delta replay.
- While disconnected, keep showing the last transcript but mark it stale; do
  not queue prompts silently: a prompt sent while disconnected must either fail
  visibly or wait for the next ready.
- Ready timeout 15 s, warn at 3 s (official recovery config). If `$events` has
  not delivered `ready` in 15 s, drop the socket and retry.

---

## 4. Endpoint catalogue (0.2.2-rc.1)

Conventions that hold throughout:

- Endpoint strings are `<namespace>/<method>`; the wire `args` object contains
  the descriptor's parameter names **exactly**. Two conventions coexist:
  session-controller methods wrap their payload in `request` (some also take a
  flat `agentId`/`sessionId`), while most other namespaces take flat parameters.
  Each table below states the **exact `args` keys**; when in doubt, §4.16 lists
  the parameter names of every exposed method.
- Branded ids (`SessionId`, `WorkspaceId`, `MessageId`, `JobId`,
  `FileUploadReceiptId`, …) are opaque strings on the wire.
- `null` and an omitted property are different: projections and summaries omit
  keys that are unknown/absent, and `null` is a real value (e.g. `title: null`).
- All results are wrapped as in §2.1. The tables list only the `value` shape.
- Anything marked **unverified** was only read from the generated type faces and
  not exercised live; those calls are safe but their exact happy-path payloads
  should be captured before relying on them.

### 4.1 Sessions

#### `session/list` — `{ "_request": { "cursor"?: string } }` → `{ items: SessionSummary[] }`

`_request` is a real parameter name (quirk); `cursor` is accepted but unused in
0.2.2 — the reply is the complete list, sorted by `updatedAt` descending.
Sessions without a recorded `cwd` are omitted. Verified live with 6 rows.

```json
{ "sessionId": "<session-id>", "updatedAt": 1795110874597,
  "agentAvailable": true, "formatStatus": "current", "running": false,
  "blank": false, "cwd": "/home/user/project",
  "projections": { "kind": "sequenced", "asOfSeq": 20, "values": {
      "title": "Pong", "agentPreset": "standard",
      "tokenUsage": { "uncachedInputTokens": 8802, "outputTokens": 3,
                      "cacheReadTokens": 128, "cacheWriteTokens": 0 },
      "modelSelection": { "lastUsed": {"provider":"deepseek-official","model":"deepseek-flash"},
                          "next": {"provider":"deepseek-official","model":"deepseek-flash"} },
      "userQuestions": { "active": [], "settled": [] }, "goal": null } } }
```

- `projections.kind`: `sequenced` = live registry block, comparable with
  projection baselines; `cached` = persisted cache watermark (cold summary),
  **not** comparable with other sessions' `asOfSeq`. `projections.values` is a
  *partial* summary — omitted keys mean unknown, not absent.
- `formatStatus: 'migration-required'` means the session log predates the
  current format; `session/follow` on it can fail with
  `session/migration-required`.
- `agentAvailable: false` = no live Agent (cold session); `session/follow`
  without `activate:true` works for reading but prompts need an activation or a
  `session/create` reusing the id.

#### `session/create` — `{ "request": { "cwd"?, "workspaceId"?, "sessionId"?, "agentPreset"? } }` → `{ sessionId, agentPreset? }`

`cwd` and `workspaceId` are mutually exclusive. Passing `sessionId` reuses a
blank session with that id if possible (the reply may differ from the request).
Verified: `{"request":{"cwd":"/home/user/project"}}` →
`{"sessionId":"session-…","agentPreset":"standard"}`.

#### `session/state` — `{ "request": { "sessionId" } }` → `SessionState`

Verified: `{"cursor":20,"active":true,"running":false,"queue":[],"pendingInput":[]}`.
`active` = an Agent is attached; `running` = a turn is executing; `queue` is
`null` when no queue exists and otherwise holds
`{id, placement:'queued'|'steering'|'context', rpcId?, content:[blocks]}`;
`pendingInput` lists `'approval'|'question'|'other'` requests awaiting
`$events/result`.

#### `session/page` / `session/events` — `{ "request": SessionPageRequest }` → `SessionEventsPage`

```json
{ "request": { "address": { "kind": "session", "sessionId": "<session-id>" },
               "beforeSeq": 42, "throughSeq": 100, "maxMessages": 50,
               "turnWindow": { "minMessages": 50, "minTurns": 2 } } }
```

→ `{ "records": [ { "type": "event", "event": SessionWireEvent }, … ],
      "hasMore": true, "cursor": 100 }`

- Records are **ascending** `seq`; the page ends just before `beforeSeq`
  (exclusive) or at the log end / `throughSeq` (inclusive). `throughSeq: -1`
  means "empty page pinned at the start".
- `cursor` is the cut the page covered; store it so a later `session/follow`
  snapshot opening can be reconciled (the snapshot reports the cut it used).
- `turnWindow` extends a page backwards to a turn boundary: at least
  `minMessages` append-origin user/assistant messages and `minTurns` turn
  starts, unless `maxMessages` or history exhaustion wins. `minMessages` must
  not exceed `maxMessages` (else `gateway/input-invalid`).
- For a subagent transcript use the `subagent` address:
  `{"kind":"subagent","parentSessionId":…,"childSessionId":…,"mode":"one-shot"|"continuable"|"unknown"}`.
- The list row summary and this event stream are separate: a cold read never
  activates an Agent.

#### `session/projections` — `{ "request": { "sessionId" } }` → `{ kind:'sequenced', asOfSeq, values }`

Full projection block at a cut (verified: `kind:'sequenced'`, `asOfSeq:20`,
`values` holding every key of §5.7). This is the cheapest way to fill a chat
header/sidebar for one session before opening `session/follow`.

#### `session/rename` — `{ "request": { "sessionId", "title" } }` → `{ title, seq }`

Empty/whitespace titles are rejected with `session/title-invalid`. The durable
`session/title` event carries the new title; `title: null` in a projection means
"no title yet" (the UI falls back to the first prompt).

#### `session/fork` — `{ "request": { "sessionId", "atSeq"?, "allowMigration"? } }` → `{ sessionId }`

Verified. With no `atSeq` the Host forks at the latest completed-turn prefix;
`allowMigration:false` makes a migration-required source fail instead of being
migrated for the fork. The child carries `isSeeded: true` in its header.

#### `session/search` — `{ "request": { "query" } }` → `{ items: [{sessionId, snippet}], hasMore }`

**Usually unavailable** in a web profile: it answers `gateway/internal` with
"session search is disabled: this deployment configures the session-query index
with openAt \"never\"" (verified). Treat it as a feature-detected capability
(§6.3) and hide search when it fails that way rather than showing an error.

#### `session/initializeDefaultModel` — `{}` → void

Ensures the deployment/agent default model selection is initialized (used once
after connect by the official UI). Verified `{"ok":true}`.

#### `session/canOpenWorkspacePath` — `{}` → boolean

Verified `false` on a headless web Host. Use it to hide "reveal in file manager"
actions. `session/openWorkspacePath {request:{path, action?:'reveal', application?}}`
→ `{opened:true}` or `gateway/internal` "path open failed" (verified failure on
the web profile).

#### `session/workspacePathApplications` — `{ "request": { "path" } }` → `[{…}]`

Native file-application descriptors for the "open with" UI; `[]` on the web
profile (verified).

### 4.2 Turn control

#### `session/prompt` — `{ "request": SessionPromptRequest }` → `{ accepted: true }`

```json
{ "request": {
    "requestId": "<uuid>",                    // client-minted; persisted on the user message
    "sessionId": "<session-id>",
    "mode": "queue",                          // or "steer"
    "clientTimeZone": "UTC",
    "content": [
      { "type": "text",  "text": "Describe this image." },
      { "type": "image", "mediaType": "image/png", "data": "<base64>", "name": "one.png" },
      { "type": "file",  "receiptId": "<upload receipt id>" }
    ] } }
```

- `content` needs at least one non-blank text part or an attachment.
- `image.data` is the **base64** payload; the server verifies type, byte length
  and dimensions against `imageLimits` (§1.7). `name` is display-only.
- `file.receiptId` comes from `/api/session/uploadFileBinary` (§4.10); the
  durable block becomes `{"type":"file","attachment":{"attachmentId","name","bytes"}}`.
- `queue` appends to the inbox (it runs after the current turn or starts one);
  `steer` injects into the running turn. `session/prompt` never blocks for the
  model: it is a durable inbox admission.
- Reconciliation: the stored `user/message` has
  `source: {"kind":"user","rpcId":"<requestId>","clientTimeZone":"UTC"}` — match
  optimistic UI rows by `rpcId === requestId`.
- Verified live: text+image+file prompt accepted, stored blocks as above; the
  turn ran two steps (tool calls `read`, `read_image`) and ended
  `{"kind":"completed"}`.

#### `session/cancel` — `{ "request": { "sessionId" } }` → `{ accepted: true }`

Interrupts the running turn; the turn ends with
`turn/end {reason:{kind:'aborted', reason:{…}}}`, and the assistant message is
marked `interrupted: true` when it was mid-stream. `accepted:true` does not mean
the turn already stopped — wait for the `turn/end` event.

#### `session/queue` mutations — `session/updateQueue`

`{ "request": { "sessionId", "itemId", "action": QueueAction } }` →
`{ accepted: true }`, where `QueueAction` is
`{"kind":"edit","content":[{"type":"text","text":"…"}]}`,
`{"kind":"remove"}` or `{"kind":"steer"}`. Unknown/consumed item →
`session/queue-item-not-found` (verified), which is normal racing with the
running turn.

#### `session/wait` — `{ "request": { "sessionId", "timeoutMs"?, "afterSeq"?, "maxMessages"? } }` → `{ reason, state, output }`

Blocks until the session is idle / needs input / the timeout elapses. Verified:
`{timeoutMs: 1500}` → `{"reason":"idle","state":{…},"output":{"records":[{"type":"event",…}],"truncated":false}}`.
Use it for "send then read the reply" flows without keeping a socket, and for
long approvals-free agent runs. `reason: 'input-required'` means an approval or
question is pending — switch to `$events`.

### 4.3 Models and reasoning effort

#### `session/modelCatalog` — `{}` → `ModelCatalog`

Verified live:

```json
{ "default": { "provider": "deepseek-official", "model": "deepseek-flash", "reasoningEffort": "off" },
  "routableProviders": ["deepseek-official"],
  "groups": [ { "id": "deepseek-official", "name": "DeepSeek",
                "models": [ { "id": "deepseek-flash", "name": "DeepSeek-V4.1-Flash",
                              "reasoning": { "efforts": [
                                  {"id":"off","name":"Off"}, {"id":"low","name":"Low"},
                                  {"id":"high","name":"High"}, {"id":"max","name":"Max"} ],
                                "defaultEffort": "high" } },
                            { "id": "deepseek-v4-pro", "name": "DeepSeek-V4-Pro", "reasoning": { … } } ] } ],
  "failures": [] }
```

- `groups` = providers whose model lists loaded; `failures` = providers whose
  lookup failed (`{id,name,message}`) — render them as unavailable, not as an
  error. `routableProviders` is the subset usable for routing.
- `reasoning.efforts[].id` is the value to send as `reasoningEffort`;
  `defaultEffort` applies when a selection omits it (each model can differ;
  `off` is a real choice). `reasoning` is absent for non-reasoning models.
- `badge` may carry a provider-authored label; display only.

#### `session/selectModel` — `{ "request": { "sessionId", "provider", "model", "reasoningEffort"? } }` → `{ selected: ModelSelection }`

Verified. The selection is durable (`model/selection` event) and appears in the
`modelSelection` projection as `{ lastUsed, next }`:
`lastUsed` is what produced the latest assistant message, `next` is what the
next turn will use. Selecting a model while a turn runs applies to the next
turn. Unknown route → `session/model-unavailable`; providers without
credentials → `session/provider-credentials-unavailable`.

#### `session/attachment` — `{ "request": { "sessionId", "attachment": ImageAttachmentRef } }` → `{ attachment, data }`

Fetches one prompt image as base64 (`data`), after verifying id/format/bytes/
dimensions. Use it for attacker-safe image rendering when the raw
`attachmentId` path is not reachable (the `attachmentId` is a
`sha256:<hex>` content address on the Host, not an HTTP URL).
`ImageAttachmentRef = {attachmentId, mediaType, width, height, bytes, name?}`.
Invalid → `session/attachment-invalid`. **Success path unverified** (code-read).

### 4.4 Providers, credentials and settings (engine settings)

#### `llm/listProviders` — `{}` → `[{ "id": "deepseek-official", "name": "DeepSeek" }]`

Verified. Static roster of composed provider routes.

#### `llm/listConfigurableProviders` — `{}` → `LlmConfigurableProvider[]`

Verified. One row per route; real rows from the stock profile:

```json
[{"provider":"deepseek-official","displayName":"DeepSeek",
  "settingsNs":"llm-deepseek","settingsPath":[]},
 {"provider":"amazon-bedrock","displayName":"amazon-bedrock",
  "settingsNs":"llm-pi-ai","settingsPath":["providers","amazon-bedrock"],
  "declared":false,"baseURLEnv":["AWS_REGION","AWS_DEFAULT_REGION"],
  "nativeAuth":{"env":["AWS_BEARER_TOKEN_BEDROCK",…],"oauth":false}},
 {"provider":"anthropic","displayName":"anthropic",
  "settingsNs":"llm-pi-ai","settingsPath":["providers","anthropic"],
  "declared":false,"defaultBaseURL":"https://api.anthropic.com",
  "nativeAuth":{"env":["ANTHROPIC_API_KEY",…],"oauth":true}}]
```

- `settingsNs` + `settingsPath` locate this route's profile inside
  `settings/describe`: the DeepSeek route is the whole `llm-deepseek` namespace
  (`settingsPath: []`), while every pi-ai catalog route is one key under
  `llm-pi-ai`'s `providers` dict. The stock profile returns dozens of pi-ai
  catalog routes besides these examples.
- `declared: true` = the route exists only because configuration declared it
  (a hand-added gateway); `false` = the adapter ships it. Absent = the adapter
  draws no distinction.
- `defaultBaseURL`, `baseURLEnv`, `nativeAuth{env,oauth}` describe endpoint and
  authentication: `nativeAuth.env` lists environment credential names the
  adapter would read, `oauth` marks OAuth-capable routes. A route's stored key
  reference is `llm-pi-ai` profile field `apiKeyEnv`; when absent, the official
  UI derives one as `<ROUTE_UPPERCASED_WITH_UNDERSCORES>_API_KEY`
  (`deriveKeyRef`).

**There is no dedicated provider CRUD endpoint.** Create/update/delete are
settings mutations plus credential writes (this is exactly what the official
Models settings page does; code-read, not exercised live):

1. **Create** — `settings/mutate` with
   `{ns:'llm-pi-ai', ops:[{op:'set', path:['providers', '<route>'],
   value:<profile>}], expectedRevision}` where `<profile>` is
   `{displayName?, apiKeyEnv?, api, baseURL, models:[<model>, …], …}`;
   `api` ∈ `'openai-completions' | 'openai-responses' | 'anthropic-messages'`;
   each `<model>` = `{id, name?, contextWindow?, maxTokens?, input?:
   ['text'|'image'|…], reasoningEfforts?: false | [{id, name?, …}], compat?}`.
   Then, if a key was entered, `credentials/set {ref:
   <profile.apiKeyEnv ?? derived ref>, value: '<api key>'}`.
2. **Update** — repeat the same `op:'set'` at the same path with the changed
   profile (the profile schema also has `modelOverrides`, `defaultContextWindow`,
   `defaultMaxTokens`, `defaultInput`, `headers`, `reasoning`,
   `thinkingBudgets`, `cacheRetention`, `transport`, `compat`).
3. **Delete** — `settings/mutate {ns:'llm-pi-ai', ops:[{op:'unset',
   path:['providers','<route>']}], expectedRevision}`. A route present only in
   the composition base layer cannot be unset (the UI reports it as not
   removable).
4. **Reasoning effort options** — per model `reasoningEfforts` (or the route's
   `reasoning`/`thinkingBudgets`); the catalog exposes the resolved choices on
   `session/modelCatalog` as `model.reasoning.efforts`, and the id is what
   `session/selectModel.reasoningEffort` takes.
5. After any write, refresh `llm/listProviders`, `session/modelCatalog` and
   `credentials/describe`; `llm/adapters-updated`/`llm/models-updated` emits
   announce the change.

#### `llm/discoverModels` — `{ "settingsNs", "request" }` → `LlmDiscoveredModel[]`

`request` describes a **draft** route, never a stored one:
`{provider?: string, baseURL?: string, api?: string, apiKey?: string}` — the
credential is one-shot and never stored. A route the adapter already knows may
omit `baseURL` and answer from its registry; a hand-declared route must supply
`baseURL` (+ `api`, and `apiKey` when the endpoint requires auth). Verified
failure: upstream answered 401 → `llm/model-discovery-rejected` (upstream
message in `details`). Each model:
`{id, name?, contextWindow?, maxTokens?, inputModalities?}`. This is how the
official Models page offers model ids for a custom provider.

#### `settings/describe` — `{}` → `{ writable, hasDocument, namespaces: SettingsNamespaceView[] }`

Verified. 21 namespaces in the stock web profile. `SettingsNamespaceView`:
`{autoGenerate, ns, schema, value, base?, user?, applies:'live', secrets:[{…}],
revision}`. `value` is redacted and resolved (defaults → composition base →
user layer); `user` marks user overrides; `secrets` reports configured state
without values; `revision` is the CAS token for writes.

Engine-relevant namespaces in the stock profile (all verified present):

| ns | shape (resolved `value`) | Purpose |
|---|---|---|
| `agent-default-model` | `{provider, model}` | default model for new sessions |
| `llm-deepseek` | provider profile incl. `baseURL` | shipped DeepSeek route |
| `llm-pi-ai` | `{providers: {<id>: {baseURL, apiKey?, models?: […]}}}` | custom/self-hosted providers |
| `permission` | `{defaultPreset}` | default permission preset |
| `session-log-deepseek` | `{enabled}` | upload session logs to the platform |
| `agent-preset-registry` | preset roster settings | which agent presets are listed |
| `ui-settings-general`, `ui-theme`, `locale` | UI only | not needed by a native client |

#### `settings/update` — `{ "ns", "patch", "expectedRevision"? }` → `SettingsNamespaceView`

`patch` is a deep-partial of the namespace's schema. Verified write + CAS
conflict (`settings/conflict` details `{ns, expected, actual}`); other refusals
are `settings/rejected`.

#### `settings/mutate` — `{ "ns", "ops", "expectedRevision"? }` → `SettingsNamespaceView`

`ops` is an ordered list of
`{"op":"set","path":["defaultPreset"],"value":"read-only"}` /
`{"op":"unset","path":[…]}` — the right primitive for a single-row edit
(verified). `path` is relative to the namespace root.

#### `settings/replace` — `{ "ns", "section", "expectedRevision"? }` → `SettingsNamespaceView`

Replaces a whole section (`section` = the section value). **Unverified.**
`settings/openSettingsDocument` → `SettingsDocumentOpenValue` invokes the Host's
editor/launcher for the config document; web profile returns an unavailable
result — a native client should not expose it.

#### `credentials/describe` — `{ "refs": ["<credential ref>", …] }` → `Record<ref, CredentialInfo>`

Verified: `{"configured":true,"source":"file","writable":true}` per ref (no
secret values ever cross the wire in this direction). `credentials/set
{ref, value}` and `credentials/unset {ref}` write/remove one reference; refusals
are `credential/rejected` with the provider's message. Limit:
`MAX_DESCRIBE_REFS` (batch your rows).

### 4.5 Permissions

#### `permissionPresets/catalog` — `{}` → `{ options, defaultOptions, defaultPreset }`

Verified. Each option is a preset descriptor (`{preset, label/description
localized?}`; the catalog in the stock profile lists the read-only /
workspace-write / full-access family). `defaultOptions` are those eligible as a
deployment default; `defaultPreset` is the effective default.

Changing a **session's** permission mode is a command, not a projection write:

```json
POST /api/commands/execute
{ "args": { "agentId": "<session-id>", "line": "/permission read-only",
            "submittedAttachments": [] } }
→ { "commandId": "…", "result": { "kind": "success", "text": "…" } }
```

Verified: the `permissions` projection then reports
`{currentValue:'read-only'}` and a `permission/preset` event is appended. The
same path changes other per-session modes exposed by installed commands
(`/plan`, …). Changing the **deployment default** is a settings write:
`settings/mutate {ns:'permission', ops:[{op:'set', path:['defaultPreset'],
value:'read-only'}]}` (the namespace path used by the official UI).

### 4.6 Approvals and user questions

Both arrive as `waterfall` items on `$events` (§3.3) and are answered through
`$events/result`. The transcript records audit events for approvals; questions
are reconstructed through the `userQuestions` projection.

#### Approval request payload (verified live)

```json
{ "type": "waterfall", "event": "approval/request", "eventId": "<event-id>",
  "agentId": "<session-id>",
  "request": { "toolName": "shell", "callId": "call_…",
               "reason": "…", "displayReason": { "en": "…" } } }
```

Answer: `{"kind":"result","value":"allowed-once"}` — or `"rejected"`,
`"cancelled"`, `"unavailable"`; `{"kind":"next"}` delegates to the Host's
remaining answerers (fails closed). The audit events are
`approval/asked {id, toolName, callId?, reason?}` and
`approval/decided {id, outcome}`; a rejection verified that both appear in the
transcript after the answer.

#### User-question request payload (verified live)

```json
{ "type": "waterfall", "event": "user-questions/request", "eventId": "<event-id>",
  "agentId": "<session-id>",
  "request": { "questions": [ { "id": "q1", "question": "…", "header": "…",
                                "options": [ {"label": "Blue"}, {"label": "Green"} ] } ] } }
```

Answer:

```json
{ "kind": "result",
  "value": { "answers": [ { "id": "q1", "selected": ["Blue"], "custom": "" } ] } }
```

- `id` is the question `id`; `selected` uses **option labels**, not indices.
- `custom` is the "Other" free text (omit or empty when unused).
- For timed questions the request carries
  `wait: {callId, timed: true}`; such a request must be claimed through
  `userQuestions/attachWait {agentId, callId}` (stream; first frame
  `{remainingMs}`) before answering, otherwise the countdown may expire. Closing
  a question panel without answering is not an answer.
- The `userQuestions` projection is
  `{active:[{callId, questions, state:'open'|'continued'}], settled:[{callId, answers}]}`
  and is how a reconnecting client reconciles what it missed.
- Verified end-to-end: the answer was consumed by the `ask_user_question` tool
  and the model continued in the same turn.

### 4.7 Forwarded Host events (`$events` `emit` list)

The mux forwards this allowlist (namespace + event name); args are the listener
arguments in order. Anything not listed is not visible over the wire.

| Event | Args | Meaning |
|---|---|---|
| `api-session/added` | `[summary: SessionSummary]` | session row appeared / Agent created |
| `api-session/removed` | `[sessionId]` | session left the live registry |
| `api-session/status` | `[sessionId, running]` | running state changed |
| `api-session/activity` | `[sessionId, updatedAt]` | user message advanced list ordering |
| `api-session/error` | `[sessionId, message]` (code-read) | Agent failed outside a turn |
| `commands/change` | `[]` | command roster changed (refresh `commands/list`) |
| `agent-preset/selected` | `[sessionId, agentPreset]` | session preset changed |
| `model: llm/models-updated`, `llm/adapters-updated` | `[]` | refresh `session/modelCatalog` / providers |
| `settings/document-updated` | `[ns, revision]` | re-read that settings namespace |
| `credentials/record-updated`, `credentials/reference-updated` | `[ref]` | re-run `credentials/describe` |
| `permission-presets/catalog-changed` | `[]` | refresh `permissionPresets/catalog` |
| `schedule/changed` | `[scheduleId?]` | refresh `schedule/list` |
| `goal/activation-changed` | `[agentId, activation]` | goal auto-continuation eligibility |
| `plugin-manager/*`, `plugin-market/changed` | varies | refresh plugin inventory |
| `cordis/*` | varies | dynamic plugin runtime events |
| `deepseek-account/session-expired`, `deepseek-account/model-sign-in-required` | `[]` | account/credential needs attention |

Waterfalls: `approval/request`, `user-questions/request` (§4.6). Unknown
namespaced events from plugins must be ignored by a client that does not render
them; do not treat an unknown event as an error.

### 4.8 Workspaces and session grouping

A workspace is a registered Host directory; sessions are grouped under it and
ordered manually. `workspace/follow` is the live registry; ungrouped sessions
are those whose `cwd` matches no workspace.

#### `workspace/create` — `{ "request": { "path" } }` → `{ workspace, created }`

Verified. The path must exist and be a directory (realpath resolution →
`workspace/invalid-path`). Idempotent: an already-registered path returns
`created:false`. `WorkspaceView = {workspaceId, path, title, sessionIds,
createdAt, updatedAt}` (ISO-8601 strings), `sessionIds` in manual order.

#### `workspace/follow` — `{}` (stream) → baseline + increments

Verified baseline:
`{"type":"baseline","value":{"items":[],"archivedSessionIds":[],"pinnedSessionIds":[]}}`.
Increments: `{type:'replace',value:WorkspaceBaseline}` (complete state, not a
new generation), `{type:'upsert',workspace}`, `{type:'remove',workspaceId}`,
`{type:'order',workspaceIds}`, `{type:'archived',archivedSessionIds}`,
`{type:'pinned',pinnedSessionIds}`. `pinnedSessionIds` is registry-global and
most-recent-first; `archivedSessionIds` is the archive set. Both replace the
local set when received.

#### Mutations (all verified where noted)

| Method | `args` | Result |
|---|---|---|
| `workspace/rename` | `{request:{workspaceId,title}}` | `{workspace}` ✅ |
| `workspace/delete` | `{request:{workspaceId}}` | `{deleted:true}`; unknown → `workspace/not-found` ✅ |
| `workspace/insertBefore` | `{request:{workspaceId,beforeWorkspaceId?}}` | `{workspaceIds}` (full order) ✅ |
| `workspace/insertSessionBefore` | `{request:{workspaceId,sessionId,beforeSessionId?}}` | `{workspace}` (new `sessionIds` order) |
| `workspace/archiveSession` | `{request:{sessionId,stopActivity?}}` | `{archivedSessionIds}`; running work → `workspace/session-active` unless `stopActivity:true` |
| `workspace/unarchiveSession` | `{request:{sessionId}}` | `{archivedSessionIds}` |
| `workspace/pinSession` / `unpinSession` | `{request:{sessionId}}` | `{pinnedSessionIds}` |
| `workspace/initializeDefault` | `{}` | `WorkspaceValue \| undefined` ✅ |

`workspace/initializeDefault` ensures the Host has a default workspace for its
own cwd (idempotent; verified). A native client that groups by workspace should
call it once after connect, then rely on `workspace/follow`.

**There is no `workspace/list` and no `workspace/select`.** The list comes from
the `workspace/follow` baseline (plus the archived/pinned sets), and "selecting"
a workspace is a client-side choice that only matters when creating a session
(`session/create {workspaceId}`) or grouping the existing sessions by
`summary.cwd`/`WorkspaceView.sessionIds`. Sessions not in any
`WorkspaceView.sessionIds` are ungrouped; render them in an "Ungrouped" bucket
or filter by `cwd`.

#### Directory picker (Host filesystem browsing)

- `directoryPicker/list {path}` → `{path, home, crumbs:[DirectoryEntry],
  entries:[DirectoryEntry], truncated}`; `DirectoryEntry = {name, path, hidden}`;
  verified.
- `directoryPicker/createDirectory {path, name}` → absolute path of the created
  directory; failures `directory-picker/exists`, `.../unreadable`,
  `.../create-failed`.
- `directoryPicker/pick {}` asks the **Host's native** picker; on a headless web
  Host it fails with `directory-picker/unavailable` details
  `{capability:'browse'}` (verified). A native client should implement its own
  picker UI on top of `directoryPicker/list` (or let the user type a path) and
  never depend on `pick`.

### 4.9 Workspace files and media

All file methods are scoped by a **session id** (`workspaceFileScopeId` is a
`SessionId`; the directory is that session's workspace root):

| Method | `args` | Result |
|---|---|---|
| `workspaceFiles/list` | `{workspaceFileScopeId, path}` | `{path, entries:[{name,type:'file'\|'directory'\|'other',size?}], truncated}` ✅ |
| `workspaceFiles/stat` | `{workspaceFileScopeId, path}` | `{absolutePath, version, bytes?}` |
| `workspaceFiles/read` | `{workspaceFileScopeId, path, range:{offset,limit?}}` | `{…stat, offset, text, lines, eof}` |
| `workspaceFiles/readBytes` | `{workspaceFileScopeId, path, options}` | binary via multipart (§2.2) |
| `workspaceFiles/changes` | `{workspaceFileScopeId, path}` (stream) | `{kind:'ready'}` / `{kind:'change',change}` |

- `path` is workspace-relative; `""` is rejected (`gateway/bad-request "path is
  required"`, verified — the root is spelled `"."`).
- Errors: `workspace-file/not-found`, `.../outside-workspace`,
  `.../not-directory`, `.../not-regular-file`, `.../not-text`,
  `.../too-large {path,limit}`, `.../watch-unsupported`.
- `workspaceFiles/changes` is how a live-editing surface watches a file;
  `watch-unsupported` means fall back to polling with `stat`.

### 4.10 Attachments and file serving

#### `POST /api/session/uploadFileBinary?sessionId=<id>[&name=<file name>][&mediaType=<mime>]`

Not an RPC: raw body, `content-type: application/octet-stream` exactly (verified
415 otherwise), optional `name` query parameter for the stored file name and
`mediaType` to stage it as a prompt image. The reply is a **bare**
`{ok:true,value}` / `{ok:false,error}` JSON (no `rpcId` wrapper):

```json
{"ok":true,"value":{"receiptId":"<receipt>",
  "image":{"attachmentId":"sha256:<hex>","mediaType":"image/png",
           "width":1,"height":1,"bytes":70}}}
{"ok":true,"value":{"receiptId":"<receipt>",
  "file":{"attachmentId":"sha256:<hex>","name":"notes.txt","bytes":19}}}
```

Pass `receiptId` in a `file` prompt part (§4.2). Images can also be sent inline
as base64; a large image is cheaper to upload once and reference. Missing
`sessionId` → 400 `sessionId is required`; wrong method → 405 (verified paths).

The equivalent RPC is `fileUploads/upload {agentId, request}` →
`FileUploadValue {receiptId, file|image}` for encoded payloads; the HTTP route
is preferable for large bodies.

#### `GET /api/file?path=<absolute path>[&v=<version>]`

Serves bytes from the Host filesystem with `X-Content-Type-Options: nosniff`
and `Content-Security-Policy: sandbox; default-src 'none'`. Verified: an
existing file answers **302** to `?path=…&v=<opaque version>` (that versioned
URL is cacheable `private, max-age=31536000, immutable`); a directory answers
**403**; a missing `path` or a relative path → 400. Use this for image/attachment
rendering and workspace file preview in a WebView; it requires the same cookie
and passes the same fence (the URL host must be the fence-accepted authority).

### 4.11 Commands, skills and prompt references

#### `commands/list` — `{ "agentId": "<session-id>" }` → `CommandDescriptor[]`

Verified: `[{"definitionId":"…","name":"compact","description":"…"}, …]` — stock
web profile lists `compact`, `export`, `feedback`, `goal`, `permission`, `plan`.
`agentId` is the session id (there is no separate agent id on the wire).

#### `commands/execute` — `{ "agentId", "line", "submittedAttachments" }` → `{ commandId, result: CommandResult }`

- `line` is the raw slash line, e.g. `"/permission read-only"`.
- `submittedAttachments` is `[]` unless the command declares an attachment
  input (the composer's staged images/files).
- `result` is `{kind:'success', text?, sourceEventSeq?}` or
  `{kind:'error', text}`; this is in-band, not a `RemoteError`. The durable
  `command/run {commandId, line, …}` and `command/done {commandId, result}`
  events bracket it.
- A command with no matching definition returns `result.kind:'error'`; the wire
  call itself still succeeds.

#### `skills/list` — `{ "request": { "sessionId" } }` → `{ skills: SkillEntry[] }`

Verified `{"skills":[]}` on the stock profile. Render skills only when non-empty.

#### `fileReferences/list` — `{ "agentId": "<session-id>", "query": "src/" }` → `FileReferenceCandidate[]`

`{path, kind:'file'|'directory'}` — completion for `@path` mentions in the
prompt composer. The chosen path is sent as **plain text** (`@path` in the
message), not as a structured reference; DSH's prompt parser resolves it.
`sessionReferenceResolver/candidates {agentId, query}` returns
`SessionReferenceMentionCandidate[]` for `@session` mentions. Both unverified
live (code-read); they are optional composer sugar.

### 4.12 Goals, schedules and jobs

#### Goals (`goals/*`, args are flat `agentId` = session id)

| Method | `args` | Result |
|---|---|---|
| `goals/create` | `{agentId, request:{objective, maxGoalRounds?}}` | `{ref:{id,revision}}` ✅ |
| `goals/get` | `{agentId}` | `GoalView \| undefined` ✅ |
| `goals/edit` | `{agentId, ref, request:{objective?/maxGoalRounds?/…}}` | `GoalView` |
| `goals/pause` / `goals/resume` | `{agentId, ref}` | `GoalView` |
| `goals/complete` | `{agentId, ref}` | `GoalView` |
| `goals/clear` | `{agentId, ref}` | `{id, revision}` |

`GoalView = {id, revision, objective, phase:'active'|'paused'|'blocked'|'complete',
maxGoalRounds?, roundsStarted, createdAt, updatedAt, activation}`; verified shape
from `goals/get`. `ref` must be the current `{id, revision}` — a stale revision
fails. Goal auto-continuation is Host-side; `goal/activation-changed` events and
the `goal` projection tell the UI whether it is armed. The agent-facing tool is
a separate path; `goals/*` only manages state.

#### Schedules (`schedule/*`)

| Method | `args` | Result |
|---|---|---|
| `schedule/list` | `{request:{active?, limit?, offset?}}` | `{items, shown, total, limit, offset}` ✅ |
| `schedule/view` | `{request:{id}}` | `ScheduleCatalogEntry` or `{code:'schedule_not_found'}` |
| `schedule/create` | `{request:{title, prompt, timing, target?}}` | `ScheduleCatalogEntry` ✅ |
| `schedule/edit` | `{request:{id, action:'update', patch:{title?, prompt?, timing?, target?, active?}, expectedUpdatedAt?}}` **or** `{request:{id, action:'delete', expectedUpdatedAt?}}` | `ScheduleCatalogEntry` \| `{id, deleted:true}` \| `{id, code:'schedule_not_found'\|'schedule_conflict'}` ✅ |
| `schedule/deleteInactive` | `{}` | `{deleted, …}` (ended tasks only) ✅ |
| `schedule/run` | `{request:{id}}` | `ScheduleCatalogEntry` \| not-found \| `{code:'schedule_execution_pending'}` |
| `schedule/history` | `{request:{id, …}}` | delivery page |
| `schedule/catalog` | `{}` | allowed timings/targets descriptors ✅ |
| `schedule/deliveryLimits` | `{}` | `{newSessionIntervalSeconds}` ✅ |

Timing (verified shapes; a wrong shape is `gateway/input-invalid`):

```json
{"kind":"daily","daily":{"time":"09:00:00","time_zone":"UTC"}}
{"kind":"every","every_seconds":3600}
{"kind":"weekly","weekly":{"days":[…],"time":"09:00:00","time_zone":"UTC"}}
{"kind":"cron","cron":{"expression":"0 9 * * *","time_zone":"UTC"}}
{"kind":"after","after_seconds":600}
{"kind":"at","at":{…}}          // absolute one-off
{"kind":"rrule","rrule":"DTSTART…\nRRULE:…"}
```

`target` selects the delivery session (`{kind:'session',sessionId}`) or asks for
a new session per delivery; omission reuses one auto-created session.
Pause/resume is `schedule/edit {request:{id, action:'update', patch:{active:false}}}`
(verified: the returned `ScheduleCatalogEntry.status` becomes `paused`; `true`
resumes from the first future occurrence). Deletion is the same method with
`action:'delete'` (returns `{id, deleted:true}`; verified). `schedule/*`
operations **return outcome objects, not errors**, for not-found/conflict/
pending; a `RemoteError` only appears for `schedule/input-invalid` and
`schedule/target-archived` (§6). `expectedUpdatedAt` is the optimistic-concurrency
token from the `ScheduleCatalogEntry.updatedAt` the editor read.

#### Jobs (`job/*`)

`job/list {request:{}}` (stream) → `{type:'rows', jobs:[JobView]}`;
`job/follow {request:{jobId}}` (stream) → job output/lifecycle frames;
`job/kill {request:{jobId}}` → kill receipt. Job rows are the background
processes the agent started; `JobView` includes id/name/state/timestamps.
**Unverified** (code-read).

### 4.13 Plugins and plugin panels (WebView hosting)

- `pluginInventory/list {}` → `{managementAvailable?, entries:[PluginInventoryEntry],
  agentPresets?}` (verified). `PluginInventoryEntry = {entryId, moduleName, meta?,
  enabled, fiberPhase, diagnostic?}`; `meta` is localized plugin metadata
  (`{title:{en,zh,…}, description:{…}}`). This is the read model for a plugin
  list: enabled state, phase, and metadata. Note that `meta` is package metadata,
  not a page URL.
- `pluginManager/listPlugins` → `PluginInfo[]` (inventory entry + `patchId` or
  `readOnlyReason`); `listBundles` → `BundleInfo[]` (`{name, official,
  availability, installTarget?, version?, meta?, description?, enabled, …}`,
  24 rows on the stock web profile, verified); `registries` → `{registry,
  fallbackRegistries, resolved}` (verified: `registry:null`,
  `fallbackRegistries:['https://registry.npmmirror.com/']`,
  `resolved:'https://registry.npmjs.org/'`); `inspect {spec}` → package
  inspection; `installBundle {spec}`, `removeBundle {name}`,
  `setBundleEnabled {name, enabled}`, `setPluginEnabled {id, enabled}`,
  `updateBundle {name, version}`, `listVersions {name}`,
  `waitForInstall {requestId}`, `cancelInstall {requestId}`,
  `listVersionExemptions`, `setVersionExemption {packageVersion,
  runtimeVersion, enabled, acceptRisk?}`, `readBundleDetail {name, language}`.
  Errors: `plugin-manager/unknown-bundle`, `.../detail-unavailable`,
  `.../invalid-language`; `inspect` refuses a DSH-version mismatch until an
  exemption is granted (`ChangeResult` carries `nextStep` text).
- `pluginMarket/*`: `listIndexes`, `search {url,query}`, `readEntryDetail`,
  `setIndexes {urls}`. Errors are `plugin-market/*` (§6). **Unverified.**
- `dynamicCordisRunner/*` is the dynamic-plugin host half; only interesting if
  the product offers plugin authoring from the UI. **Unverified.**

**Panels / WebViews — the important limitation.** DSH Web serves **one SPA**
(`dist/index.html`, booted with `__DSH_BOOT__`) and has **no per-panel URL
routing**: plugin "panels" and "entries" are React slot registrations inside
that SPA, not standalone pages. Plugin *client* code is served as assets
(`plugins/<pkg>/assets/<path>` and combo scripts), and the Host halves are
reachable only through the Remote endpoints above. Consequences for Cuplivo:

1. There is no supported URL to embed an individual plugin panel. The only way
   to show one natively is to embed the **entire DSH Web UI** in a WebView,
   authenticated with the **v1 browser cookie** (§1.2), and let its own router
   and slot registry render the panel. The reference app (dsh-go) does exactly
   this (`remote_web_page.dart`) and it is the recommended approach.
2. Embedding the SPA again in the same app means a second live client: it opens
   its own mux socket, shows its own approvals/questions (`interactions=answer`)
   and its own transcript. Decide per product whether that is acceptable; if
   not, restrict the WebView to settings-ish panels that do not contend for
   approvals, or do not ship plugin panels at all.
3. Because the SPA needs the v1 cookie and the API client may hold a v2 cookie
   of the same name, a shared cookie jar cannot hold both (§1.3). Use separate
   cookie stores, or use v1 everywhere.
4. Do not try to scrape the SPA DOM or reverse its boot globals for a native
   panel; the injections (`__DSH_BOOT__`, `__DSH_BOOT_READY__`,
   `__DSH_CONNECTION_RECOVERY__`, `__DSH_REMOTE_ACCESS__`,
   `__DSH_CONTACT_CONFIG__`, `__DSH_SHORTCUTS_CONFIG__`,
   `__DSH_DOCUMENT_PREVIEW_CONFIG__`, `__DSH_MODELS_ONBOARDING__`) are internal
   and version-specific.

### 4.14 Account and usage

- `account/getState {}` → `{status:'signed-out'|'credential-stored', attempt,
  links:{usageUrl, topUpUrl}}` (verified `status:'signed-out'`).
- `account/getProfile {client}` / `account/getBalance {client}` →
  `AccountDetails['profile'|'balance'] | null`; `client` is a platform client
  descriptor from the sign-in state.
- `account/startSignIn {client, callbackOrigin, loginSource}` → `AccountView`;
  `account/cancelSignIn {attemptId}` → `AccountView`; `account/signOut {client}`
  → `AccountView`; `account/hasRunningAccountTasks {}` → boolean;
  `account/getUnnotifiedBonuses {client}`; `account/ackBonusNotified
  {accountId, orderId, client}`.
- Streams: `account/watch {}` → `AccountView` snapshots (sign-in progress);
  `account/watchExpiry {}` → `'session-expired'` once the platform session dies.
- Usage/limits are **not** part of the Harness API: the Host exposes the
  platform's `links.usageUrl` / `topUpUrl` and the account state; per-turn token
  usage comes from the `tokenUsage` projection and assistant `usage`
  (§5.4). Do not invent a usage endpoint.

### 4.15 Other namespaces (present, peripheral to Cuplivo)

| Namespace | Methods (args in parentheses) |
|---|---|
| `agentPresets` | `list ()` → `{presets:[{id, order, isDefault, name?, description?, broken?}]}` (roster; a plugin declaration publishes its copy and an activation failure), `read (agentPreset)`, `select (agentId, agentPreset)` → committed identity (the `agentId` is the **session id**; only valid before the Session's first turn — afterwards `agent-preset/locked`) |
| `actionCards` | `act (agentId, callId, verb, payload?)` — interactive cards in a message |
| `sessionFeedback` | `record (request:{sessionId, text?, category?})` — the `/feedback` command |
| `messageFeedback` | `put`, `list`, `delete (request)` — per-message thumbs feedback, persisted Host-side |
| `subagents` | `prompt (request)`, `interruptByParent (childSessionId, parentSessionId, mode)` — subagent transcripts are read with `session/follow` subagent addresses |
| `terminal` | `create (agentId, request)`, `list (sessionId)`, `attach (agentId, id)` (stream), `retain (sessionId, id)` (stream), `close`, `rename`, `environment (agentId)`, `shells (agentId)` — a PTY UI; **not** required for a remote-control client |
| `toolResults` | `watch (request)` (stream) — tool-result expansion data |
| `speech` | `catalog`, `follow`, `prepare`, `configure`, `transcribe`, `cancelPreparation` — dictated prompts |
| `officeToPdf`, `documentPreview` (via `/api/file`) | document rendering |
| `forgePanel/*`, `liveshareShares/*` | experimental forge/live-share panels; not in the stock web profile |
| `cotTranslation` | `limits`, `translate` — chain-of-thought translation |
| `pluginRecommendations`, `productAnalytics`, `pluginRegistryProbe` | telemetry/recommendation helpers; a native client should skip them |
| `officeToPdf` | `generation`, `render` |

### 4.16 Endpoint index (namespaces and parameter names)

Every Remote method declared by the installed 0.2.2-rc.1 packages is listed
below; the profile a client connects to composes a subset (probe absent ones as
in §6.4), and `*` groups lists methods whose detail is not needed by a chat
client. Each entry is `namespace/method(param, …)`; methods marked `(stream)`
must be opened over the mux, never called unary.

```
account/ackBonusNotified(accountId, orderId, client)   account/cancelSignIn(attemptId)
account/getBalance(client)                              account/getProfile(client)
account/getState()                                      account/getUnnotifiedBonuses(client)
account/hasRunningAccountTasks()                        account/signOut(client)
account/startSignIn(client, callbackOrigin, loginSource)
account/watch(stream)                                   account/watchExpiry(stream)
actionCards/act(agentId, callId, verb, payload?)
agentPresets/list() agentPresets/read(agentPreset) agentPresets/select(agentId, agentPreset)
commands/execute(agentId, line, submittedAttachments)   commands/list(agentId)
credentials/describe(refs) credentials/set(ref, value) credentials/unset(ref)
cotTranslation/limits() cotTranslation/translate(request)
directoryPicker/createDirectory(path, name) directoryPicker/list(path) directoryPicker/pick()
dynamicCordisRunner/* (12 methods, plugin authoring)
fileReferences/list(agentId, query)
fileUploads/upload(agentId, request)
forgePanel/* (19 methods) liveshareShares/* (12 methods)
goals/clear|complete|create|edit|get|pause|resume(agentId, …)
job/follow(stream) job/kill(request) job/list(stream)
llm/discoverModels(settingsNs, request) llm/listConfigurableProviders() llm/listProviders()
messageFeedback/delete|list|put(request)
officeToPdf/generation() officeToPdf/render(workspaceFileScopeId, path, priority)
permissionPresets/catalog()
pluginInventory/list()
pluginManager/cancelInstall(requestId) pluginManager/inspect(spec, options?)
pluginManager/installBundle(spec, options?) pluginManager/listBundles()
pluginManager/listPlugins() pluginManager/listVersionExemptions()
pluginManager/listVersions(name, options?) pluginManager/readBundleDetail(name, language, options?)
pluginManager/registries() pluginManager/removeBundle(name)
pluginManager/setBundleEnabled(name, enabled) pluginManager/setPluginEnabled(id, enabled)
pluginManager/setVersionExemption(packageVersion, runtimeVersion, enabled, acceptRisk?)
pluginManager/updateBundle(name, version, options?) pluginManager/waitForInstall(requestId)
pluginMarket/listIndexes() pluginMarket/readEntryDetail(url, name, version, language, options?)
pluginMarket/search(url, query) pluginMarket/setIndexes(urls)
pluginRecommendations/describe(agentId, callId) pluginRegistryProbe/fastest()
productAnalytics/enabled() productAnalytics/report(event) productAnalytics/watchPolicy(stream)
remoteAccess/follow(stream)
schedule/catalog() schedule/create(request) schedule/deleteInactive() schedule/deliveryLimits()
schedule/edit(request) schedule/history(request) schedule/list(request) schedule/run(request)
schedule/view(request)
session/attachment(request) session/cancel(request) session/canOpenWorkspacePath()
session/control(stream) session/create(request) session/events(request) session/follow(stream)
session/fork(request) session/initializeDefaultModel() session/list(_request)
session/modelCatalog() session/observeEvent(stream) session/observeProjections(stream)
session/observeState(stream) session/openWorkspacePath(request) session/page(request)
session/projections(request) session/prompt(request) session/rename(request)
session/search(request) session/selectModel(request) session/state(request)
session/updateQueue(request) session/wait(request) session/workspacePathApplications(request)
sessionFeedback/record(request) sessionReferenceResolver/candidates(agentId, query)
settings/describe() settings/mutate(ns, ops, expectedRevision) settings/openSettingsDocument()
settings/replace(ns, section, expectedRevision) settings/update(ns, patch, expectedRevision)
skills/list(request) speech/cancelPreparation(providerId) speech/catalog()
speech/configure(patch) speech/follow(stream) speech/prepare(providerId, options?)
speech/transcribe(request)
subagents/interruptByParent(childSessionId, parentSessionId, mode) subagents/prompt(request)
terminal/attach(stream) terminal/close(agentId, id) terminal/create(agentId, request)
terminal/environment(agentId) terminal/list(sessionId) terminal/rename(agentId, id, title)
terminal/retain(stream) terminal/shells(agentId) toolResults/watch(stream)
userQuestions/answer(agentId, callId, answer) userQuestions/attachWait(agentId, callId)(stream)
workspace/archiveSession(request) workspace/create(request) workspace/delete(request)
workspace/follow(stream) workspace/initializeDefault() workspace/insertBefore(request)
workspace/insertSessionBefore(request) workspace/pinSession(request) workspace/rename(request)
workspace/unarchiveSession(request) workspace/unpinSession(request)
workspaceFiles/changes(stream) workspaceFiles/list(workspaceFileScopeId, path)
workspaceFiles/read(workspaceFileScopeId, path, range)
workspaceFiles/readBytes(workspaceFileScopeId, path, options)
workspaceFiles/stat(workspaceFileScopeId, path)
$events/result(clientId, eventId, outcome)   [plus the mux-internal `$events` stream]
```

---

## 5. Transcript, events and projections

### 5.1 Three data planes

| Plane | Wire | Semantics |
|---|---|---|
| Durable event log | `session/page`, `session/events`, `session/follow` | append-only, `seq`-ordered facts; the only source of truth for a transcript |
| Live assistant frames | `session/follow` `assistant-stream` items (opt-in `assistantStream:true`) | process-local deltas of the in-flight model attempt; never persisted |
| Projections | `session/projections`, `session/control`, `session/observeProjections` | Host-derived summary views (title, usage, permissions, inbox, goal, …) |

A client renders a chat from (1) for completed content, overlays (2) for the
live step, and uses (3) for chrome (titles, badges, running state, token
usage). Never reconstruct history from (3).

### 5.2 Wire event envelope

Every durable record is `{"type":"event","event":SessionWireEvent}`:

```json
{ "type": "user/message", "seq": 7, "time": 1795110874267,
  "data": { "message": { … }, "source": { … } },
  "surfaceOp": "append", "sourceEventSeqs": [ … ] }
```

- `seq`: per-session, strictly increasing, contiguous from 1. Use it as the
  total ordering key and as the pagination cursor (`beforeSeq`, `throughSeq`,
  `afterSeq`, `asOfSeq`).
- `time`: epoch milliseconds of the commit.
- `data`: event-specific payload (typed per event below; plugins may add types).
- `ignorable: true`: the record is log-only/derivable; a transcript may skip it.
  Unknown events that are not ignorable should be ignored defensively (do not
  fail the stream).
- `surfaceOp` (on message-producing events): `"append"` means this event
  entered the model-visible surface at its own position; a replacement form
  (`{"kind":"replace","start":…,"end":…}`-like object) means it shadowed earlier
  surface nodes. `sourceEventSeqs` lists earlier sources on replacement events.
  **Transcript rule:** render only `surfaceOp === "append"` message events (and
  events without `surfaceOp` that are presentation-only, such as tool calls).
  Replacement copies are model-only: rendering them would duplicate erased
  conversation. Unknown opaque `surfaceOp`/`sourceEventSeqs` JSON on ignorable
  plugin events can be ignored.
- A step can be retried (`llm/retry`, `llm/retry-started`): intermediate
  `assistant/attempt` events preserve the failed attempt's stream and produce no
  transcript row.
- A `compaction/start` … `compaction/end` pair replaces a prefix with a summary;
  the shadowed events stay in the log, and `compaction/summary` is the
  replacement source. A client that keeps the full local log can hide the
  shadowed range behind a "compacted" divider; a fresh reader gets the
  post-compaction surface from the log itself (shadowed events are still
  records, so filter by `surfaceOp`).

### 5.3 Event catalogue

`turn`, `step`, `seq`, `time` are on every payload unless stated. "Render"
column: how a chat surface should treat the event.

| `type` | `data` | Render |
|---|---|---|
| `turn/start` | `{turn}` | opens a turn group |
| `turn/end` | `{turn, reason}` | closes it; `reason.kind` ∈ `completed`, `aborted{reason}`, `blocked`, `error{error:LlmFailure}`, `max-tokens`, `interrupted`, `forked` |
| `step/start` / `step/end` | `{turn, step}` | one model call + its tools; group process rows here |
| `user/message` | the `UserMessage` itself: `{id, role:'user', content:[blocks], source:{kind,…}, form?}` (verified wire keys: `content`, `source`, `role`, `id`) | user row **iff** `source.kind === 'user'`; every other `kind` is injected context → collapsed "context" row or hidden |
| `developer/message` | `{turn, step, message, headerSeq?}` | tool-definition changes; log-only for a transcript |
| `system/message` | `{turn, step, message}` | system prompt; collapsed/hidden |
| `assistant/message` | `{turn, step, message:AssistantMessage, stream:AssistantStreamRecord[], usage?, interrupted?}` | assistant row; `message.content` blocks; `interrupted` marks a cancelled partial answer; `usage` = step token accounting |
| `assistant/attempt` | `{turn, step, stream}` | no row (failed/abandoned attempt) unless the product wants a retry notice |
| `tool/call` | `{turn, step, callId, name, arguments}` | tool card start; `arguments` is the **raw JSON string** from the model (parse leniently, may be partial/streaming in the live frame, complete here) |
| `tool/result` | `{turn, step, message:ToolResultMessage, error?, meta?}` | tool card result; `message.content` holds the result text/blocks, `message.isError`, `message.toolCallId` pairs with `tool/call.callId`; `meta` is tool-owned presentation data (e.g. file diff) |
| `approval/policy` | `{source, policy}` | permission badge/context |
| `approval/asked` | `{id, toolName, callId?, reason?}` | approval card (resolved by the matching `approval/decided`) |
| `approval/decided` | `{id, outcome}` | close the card with the outcome |
| `permission/preset` | `{preset}` | permission mode badge |
| `sandbox/mode` | `{mode, source?}` | sandbox badge |
| `command/run` | `{commandId, name, source, recordInput?, line?}` | slash-command row (usually collapsed: the command's own events carry the visible effect) |
| `command/done` | `{commandId, result}` | command outcome row |
| `model/selection` | `{…ModelSelection}` | model badge |
| `session/title` | `{title}` | update chat title |
| `session/title-llm-request` | `ignorable` | skip |
| `session/end-seed` | fork/seed boundary | divider in a forked session |
| `request/header` | `{header:{config, adapterDefaults?, tools?}}` | log-only (request reconstruction) |
| `request/context` | request/route facts | log-only |
| `agent/inbox/spliced` | `{target, start, inserted}` | queue/inbox change; refresh `session/state` |
| `working-directory/change` | `{cwd}` | header badge |
| `agent-preset/selected` | `{agentPreset}` | header badge |
| `todo/write` | `{todos}` | todo list panel (also `todos` projection) |
| `goal/change` | goal state change | goal panel (also `goal` projection) |
| `schedule/change` | schedule state change | schedules panel refresh |
| `session-log-deepseek/delivery-accepted` | `{sessionId, throughSeq}` | "uploaded to platform" state; ignore politely |
| `job/registered` / `job/settled` | `{…}` | background job rows |
| `plugin deliverables/presented`, `compaction/*`, `image/offload`, `plan/mode`, `llm/retry*`, `web/…`, `team/*`, `feedback/*` | plugin-specific | render only if the product implements that plugin |

Unknown event types must be tolerated: keep the record (for ordering) and skip
rendering. An unknown **non-ignorable** event is still not an error.

### 5.4 Messages, content blocks and usage

`Message` is role-discriminated: `system`, `developer`, `user`, `assistant`,
`tool`; every message has `id` (stable), `content: ContentBlock[]`, `source`.

Content blocks a renderer must handle:

| Block | Shape | Rendering |
|---|---|---|
| `text` | `{type:'text', text}` | markdown |
| `reasoning` | `{type:'reasoning', text}` | collapsible "thinking" card; never part of the quoted answer |
| `image` | `{type:'image', attachment:{attachmentId, mediaType, width, height, bytes, name?, offloaded?}}` | `attachmentId` is a Host content address (`sha256:<hex>`), not an HTTP URL; fetch display bytes with `session/attachment` (§4.3), or `GET /api/file?path=…` when the Host exposes the stored path. `offloaded:true` means the model saw a text placeholder, not pixels |
| `file` | `{type:'file', attachment:{attachmentId, name, bytes}}` | file chip with name/size; preview via `workspaceFiles/*` when reachable |
| `tool-call` | `{type:'tool-call', id, name, arguments}` | tool card header; this is the assistant's request, the durable `tool/call` event repeats it |
| `tool-addition` / `tool-removal` | `{type:'tool-addition', toolName}` / `{type:'tool-removal', toolName}` | log-only (developer messages) |

`UserMessage.source` (and any role's `source.kind`) is a merge-extensible union.
Core kinds: `user` (`{kind:'user'}`; prompt messages carry extra
`{rpcId, clientTimeZone?, principal?}`), `model` (`{kind:'model', provider,
model, replayState?}`), `tool` (`{kind:'tool', callId}`), `system-prompt`. The
stock web profile adds `runtime-context` (`form:'snapshot'`, `sections:[{name,
text}]`), `time-context` (`form:'snapshot'`), `user-approval`, `agent-message`,
`subagent-settled`, `skill-invocation`, `ptc-mode`, `compact-checkpoint`,
`cordis-host-runner`, `user-question-reply`, `team-message`, `goal`,
`plan-mode`, `schedule`, `session-reference`, `model-selection`,
`tool-registry`, `action-cards`, `working-directory`, `webhook`,
`user-rpc` (aliased at runtime as `user` + `rpcId`). A transcript should:
render `user` (and `webhook`/`agent-message`/`team-message`/`goal`/`schedule`
notices as inbound messages if the product wants them), and collapse or hide
every other kind behind a per-turn "N context items" disclosure. `form`
(`instructions` / `catalog` / `snapshot` / `notice` / `relay` / `recall`) tells
the presentation shape; `snapshot` sections are the expandable rows.

`TokenUsage` (assistant `usage` and live `usage` chunk) =
`{inputTokens, outputTokens, cacheReadTokens, cacheWriteTokens, totalTokens}`.
The `tokenUsage` **projection** is a different shape:
`{uncachedInputTokens, outputTokens, cacheReadTokens, cacheWriteTokens}` (no
`totalTokens`; do not mix the two).

Assistant `message.source` = `{kind:'model', provider, model, replayState?}` —
`provider`/`model` here are what actually produced the message (use them for a
per-message model label; `replayState` is opaque adapter data, never render or
forward it).

### 5.5 Live assistant stream (opt-in)

With `assistantStream:true` the snapshot carries
`assistantStream: {revision, activeAttempt?}`; if an attempt is already running
the client can seed its live view from `activeAttempt`. Afterwards a
`{"type":"assistant-stream","frame":…}` item arrives per frame:

```json
{"type":"start","attemptId":"<id>","revision":3,"startedAfterSeq":17,"turn":1,"step":2}
{"type":"chunk","attemptId":"<id>","revision":3,"index":0,"time":1795111823607,
 "chunk":{"type":"block-start","index":0,"blockType":"text"}}
{"type":"chunk", … "chunk":{"type":"text-delta","index":0,"text":"Po"}}
{"type":"chunk", … "chunk":{"type":"block-end","index":0,"block":{"type":"text","text":"Pong"}}}
{"type":"chunk", … "chunk":{"type":"usage","usage":{…}}}
{"type":"chunk", … "chunk":{"type":"finish","reason":{"kind":"stop"},"replayState":{…}}}
{"type":"end","attemptId":"<id>","revision":3,"index":6,
 "outcome":{"kind":"committed","eventType":"assistant/message","seq":17}}
```

Rules:

1. `revision` is a generation counter for the live view. A frame with a
   **higher** revision means older frames are void (a retry/reconnect occurred);
   reset the live buffer. Frames of the same revision apply in `index` order;
   `index` is contiguous per attempt.
2. Chunk kinds: `block-start{index, blockType}` (blockType ∈ text, reasoning,
   tool-call, image, file), `text-delta{index, text}`, `reasoning-delta{index,
   text}`, `tool-call-delta{index, id, name?, argumentsDelta}` (append to the
   argument JSON buffer), `block-end{index, block}`, `usage{usage}`,
   `finish{reason, replayState?}`. Build blocks by index; on `block-end` replace
   the transient block with the completed one.
3. `end.outcome.kind = 'committed'` → the durable event `eventType` at `seq` is
   the authoritative replacement for the whole live buffer. **Drop the transient
   view** and use the committed event (the live text may be exactly equal; the
   durable event is what pagination returns). If a client has already appended
   the durable event (arrives on the same follow stream), drop the transient
   version to avoid a duplicate. `outcome.kind = 'abandoned'` → drop it.
4. Do not persist transient frames anywhere beyond the live view.
5. On reconnect, the new snapshot's `assistantStream` baseline is the only
   valid live state; the previous buffer is void.

### 5.6 Building the transcript (reduction algorithm)

Given `records` from a `session/follow` snapshot or `session/page`:

```
turns = []
current = null
for rec in records (ascending seq):
    ev = rec.event; data = ev.data
    switch ev.type:
      turn/start: current = {turn: data.turn, startSeq: ev.seq, steps: [], user: null,
                             end: null, process: []}; turns.push(current)
      turn/end:   current.end = data.reason; current = null
      step/start: current.steps.push({step: data.step, startSeq: ev.seq, items: []})
      step/end:   close step
      user/message:
        if ev.surfaceOp == 'append' and data.source.kind == 'user':
            if current == null: create an implicit turn (cold/legacy logs)
            if current.user == null: current.user = ev            // prompt row
            else: current.process.push(ev)                       // interleaved input
        else: current.process.push(ev)                           // injected context
      assistant/message (surfaceOp == 'append'): step.items.push(ev)
      tool/call:   step.items.push(ev)
      tool/result: step.items.push(ev)
      approval/asked|decided, permission/preset, sandbox/mode,
      command/run|done, model/selection, todo/write, goal/change: step.items.push(ev)
      session/title: title = data.title
      … ignore log-only / unknown
```

- Pair `tool/call` and `tool/result` by `callId`; a call with no result yet is
  "running" while `session.state.running` is true, else "interrupted".
- A turn with `end == null` is live (`running:true`) or was crash-orphaned
  (cold logs may synthesize `turn/end {reason:{kind:'interrupted'}}`).
- The prompt row is the **first** append-origin `user/message` with
  `source.kind === 'user'` for that turn. Later human inputs inside a turn
  (steer/queue) are process items with their own `rpcId`.
- Reasoning blocks sit inside `assistant/message.content` (durably) and as
  `reasoning-delta` live; render them collapsed.
- For the answer text of a turn: join the `text` blocks of `assistant/message`
  events in step order — do not include `reasoning`.
- Title: `projection.title` if set, else the first prompt's text (truncate),
  else "New chat". `session/title` events update it live.
- `turnOutline` projection is the cheap rail: `[{turn, seq, prompt, response}]`
  (verified), where `seq` is the prompt event's seq — use it to jump
  (`session/page` with `beforeSeq`).

### 5.7 Projection keys

`session/projections` returns all of them; `session/control` sends changed keys;
`session/observeProjections`/`session/follow` snapshot return the same block.
Values are provider-validated; an absent key means "no capability/unknown", not
"empty".

| Key | Shape (0.2.2) | Use |
|---|---|---|
| `title` | `string \| null` | chat title |
| `turnOutline` | `[{turn, seq, prompt, response}]` | navigation rail |
| `tokenUsage` | `{uncachedInputTokens, outputTokens, cacheReadTokens, cacheWriteTokens}` | per-session usage badge |
| `contextPressure` | `{pressureTokens, projectedTokens, contextWindow}` (verified after a turn: `{8930, 8943, 1048576}`) | context-usage meter |
| `contextBreakdown` | per-section token breakdown | context inspector |
| `sessionStats` | `{turns, steps, llmMs, toolMs, ttftMs, ttftSteps, decodeMs, decodeTokens}` | stats panel |
| `permissions` | `{currentValue: '<preset>'}` | permission badge |
| `modelSelection` | `{lastUsed: ModelSelection, next: ModelSelection}` | model badge; `next` is editable state |
| `inbox` | `{'next-turn':[…], 'next-step':[…]}` | queued prompts (also `session/state.queue`) |
| `goal` | `GoalProjection \| null` | goal card |
| `plan` | `PlanProjection` | plan-mode card |
| `todos` | `TodoItem[] \| null` | todo panel |
| `agentPreset` | `string \| null` | preset badge |
| `workingDirectory` | `string \| null` | cwd badge |
| `userQuestions` | `{active:[{callId, questions, state}], settled:[{callId, answers}]}` | question cards, reconnect reconciliation |
| `subagentCatalog` | `SubagentCatalogEntry[]` | subagent list |
| `subagentTiming` | per-subagent timing | progress |
| `subagent` | `SubagentIdentityProjection \| null` | "this is a subagent session" |
| `actionCards` | `ActionCardView` | interactive cards in a message |
| `forkLineage` | `ForkLineage` | fork/lineage UI |
| `sessionListMetadata` | `{blank, lastPromptAt}` | list rows (blank chats) |
| `imageLimits` | `{maxImageBytes, maxImagesPerMessage, maxMessageImageBytes}` | composer limits (verified values in §1.7) |
| `forgeWorktree`, `forgeChangeRequests`, `agentTeam`, `liveshare` | plugin-specific | only when the plugin is installed |

### 5.8 Pagination and windowing

- `session/follow` opens a window cut at `cursor` (the log end it covered) and
  pages back with `maxMessages`/`turnWindow` (defaults in the reference client:
  `{minMessages:50, minTurns:2}`, `maxMessages:500`). The official UI uses the
  same constants; the Host caps a page at 500 records.
- Older history: `session/page {address, beforeSeq: windowStart, maxMessages:
  200, turnWindow}` repeated while `hasMore`. Prepend pages; `turnWindow` keeps
  the page boundary turn-aligned so the UI does not cut a turn in half.
- Gaps: if a live event's `seq` is greater than `lastSeq + 1`, page
  `session/page {address, throughSeq: event.seq - 1, beforeSeq: lastSeq + 1}`
  (or simply re-open `session/follow`) before appending; the transcript order is
  seq order.
- Resync after reconnect: replace the window with the new snapshot (it is
  authoritative for its cut), then continue paging if the user had scrolled
  back; the new snapshot may be smaller than the old window.
- `asOfSeq` in projections is comparable **only** within the same
  `kind:'sequenced'` source; a `cached` summary watermark is not comparable.
- `session/wait` gives an alternative pull path: `{afterSeq: cursor,
  timeoutMs}` returns the assistant records since the cursor.

### 5.9 Derived UI state

- Running: `session.state.running` (or the summary/`api-session/status` emit).
  `queue`/`inbox` show queued prompts; `pendingInput` shows `approval`/
  `question`/`other` — render an "action needed" badge.
- A pending approval/question is visible only while an answering `$events`
  stream is open (plus the projection/`approval/asked` events for history).
- `blank:true` sessions are reusable empty sessions created by
  `session/create`; the client may delete/hide them (`session/delete` does not
  exist — an unused blank session is simply left behind; the Host reuses ids via
  `session/create {sessionId}`).
- Errors: a turn-level failure is `turn/end {reason:{kind:'error', error:
  {message, code, status?, …}}}` — show it inside the turn, not as a global
  error. `api-session/error` emits carry out-of-turn failures for toasts.

---

## 6. Errors, retries and feature detection

### 6.1 Shapes

Two distinct error planes:

1. **Transport rejections** — plain HTTP status + short text (§2.3), or a failed
   WebSocket upgrade (401/403/409). No `code`; map by status.
2. **Protocol failures** — `result: {ok:false, error:{code, message, details}}`
   for unary calls; `{"type":"error","streamId","error":{…}}` for streams;
   `{ok:false,error}` for `/api/session/uploadFileBinary`. `code` is the stable
   contract; `message` is diagnostic English; `details` is a per-code object
   (§6.2) — it may carry useful ids (sessionId, workspaceId, ns, expected/
   actual revisions, path, limit, activity list).

`error instanceof` is meaningless on the wire: branch on `code` and treat
unknown codes as generic failures with `details` preserved for logs.

### 6.2 Code families (complete list in 0.2.2)

`gateway/*` — the Remote bridge itself; a client bug or an unsupported action:

`gateway/arguments-invalid` (wrong arg names — the most common integration
error), `gateway/input-invalid` (shape passed boundary validation but values are
bad), `gateway/bad-request` (envelope/method mismatch, malformed id),
`gateway/internal` (server fault; `details` may be empty),
`gateway/interactions-forbidden` (this peer may not answer `$events`),
`gateway/invocation-unavailable`, `gateway/method-unavailable`,
`gateway/definition-unavailable`, `gateway/service-unavailable`,
`gateway/provider-mismatch`, `gateway/peer-disposed`, `gateway/uplink-overflow`,
`gateway/protocol`, `gateway/result-invalid`, `gateway/signature-invalid`,
`gateway/ambiguous-endpoint`, `gateway/binding-invalid`, `gateway/context-*`,
`gateway/lookup-*`.

Domain codes seen or declared (each has `details`):

- `session/*`: `not-found`, `conflict`, `agent-busy`, `attachment-invalid`,
  `fork-unavailable`, `migration-required`, `model-unavailable`,
  `observation-ended`, `projections-unavailable`, `provider-credentials-unavailable`,
  `provider-models-unavailable`, `queue-item-not-found`, `steer-unavailable`,
  `title-invalid`, `wait-timeout`, `workspace-attach-failed`, `writer-held`,
  `invalid-time-zone`.
- `workspace/*`: `not-found`, `invalid-path {path}`, `name-conflict {name}`,
  `move-invalid`, `session-active {sessionId, activity[]}`.
- `workspace-file/*`: `not-found`, `not-directory`, `not-regular-file {path,
  kind}`, `not-text`, `outside-workspace`, `too-large {path, limit}`,
  `watch-unsupported`.
- `settings/*`: `conflict {ns, expected, actual}`, `rejected`.
- `credential/rejected`; `llm/model-discovery-rejected`.
- `directory-picker/*`: `unavailable {capability}` (no native picker),
  `exists`, `unreadable`, `create-failed`.
- `schedule/input-invalid {code}`, `schedule/target-archived {sessionId}`
  (other schedule outcomes are in-band objects, §4.12).
- `plugin-manager/*`: `unknown-bundle`, `detail-unavailable`,
  `invalid-language`; `plugin-market/*`: `fetch-failed`, `invalid-index`,
  `invalid-index-url`, `invalid-query`, `settings-unavailable`, `unknown-index`,
  `unknown-plugin`, `detail-unavailable`.
- `job/not-found`, `agent-preset/{conflict,invalid,locked,not-found}`,
  `remote-access/denied`, `subagent/{not-found,not-resumable,parent-unavailable,
  unauthorized,delivery-unavailable,attachment-invalid,invalid-time-zone,
  catalog-diagnostic}`, `terminal/{control-unavailable,limit-reached,
  unavailable}`, `speech/{invalid-audio,transcription-failed}`,
  `document-render/failed`, `session-log-deepseek/*` (if composed).

### 6.3 Retryability and terminality

| Situation | Retry? |
|---|---|
| Transport reset / timeout on an idempotent read (`list`, `page`, `state`, `projections`, `modelCatalog`, `settings/describe`, `pluginInventory/list`) | retry once immediately, then exponential backoff |
| `session/prompt` transport failure | **do not blindly retry**: the inbox admission may have landed (the `rpcId`/`requestId` makes it reconcilable — re-read `session/state.queue` and recent events for the requestId first) |
| `gateway/internal`, `gateway/service-unavailable` | retry with backoff (bounded), it is a Host fault |
| `gateway/arguments-invalid`, `gateway/input-invalid`, `gateway/bad-request`, `gateway/protocol`, `gateway/interactions-forbidden` | **terminal** — a client bug/unsupported action; log and surface |
| `session/not-found`, `workspace/not-found`, `job/not-found`, `schedule_not_found` | terminal; refresh the list |
| `session/queue-item-not-found` | terminal for that item; benign race |
| `session/migration-required` | terminal; offer `session/fork {allowMigration:true}` or an upgrade path |
| `session/wait-timeout` / `wait` `reason:'timeout'` | not an error: keep waiting |
| `settings/conflict` | terminal for the write; re-`describe`, merge, retry once |
| `llm/model-discovery-rejected`, `session/provider-credentials-unavailable` | terminal until the user fixes provider config |
| `workspace/session-active` | terminal; offer stop-activity (`stopActivity:true`) |
| `directory-picker/unavailable` | terminal; hide the native-picker affordance |
| 401 on any call/upgrade | re-login (token) — do not retry with the same cookie |
| 403 | terminal: the Host is not admitting this authority (§1.4) |
| 404 `not found` | terminal: endpoint absent in this DSH version (§8) |
| 409 on WS upgrade | terminal for that peer: another socket already owns it |
| stream `error` frame | terminal for that logical stream; reopen it (fresh snapshot) if the feature is still needed |

### 6.4 Feature detection and version negotiation

There is **no** version/capability endpoint in 0.2.2 and no handshake version
field in the envelope. The only version signal is the session log format
(`header.version = 4` in 0.2.2) delivered by `session/follow`, which is not a
protocol version.

Practical strategy:

1. **Probe by presence.** Call a cheap endpoint (`session/list`); a **404 plain
   `not found`** means it/its namespace is absent. Do this per optional feature
   (`session/search`, `pluginManager/*`, `job/*`, `terminal/*`, `schedule/*`,
   `pluginMarket/*`, `dynamicCordisRunner/*`), cache the result for the
   connection and hide unsupported UI.
2. **Probe by error code.** A present endpoint whose capability is off answers a
   domain code: `session/search` → `gateway/internal` "session search is
   disabled" (hide search); `llm/discoverModels` → `llm/model-discovery-rejected`
   (show provider config error); `directoryPicker/pick` →
   `directory-picker/unavailable` (use the browse flow).
3. **Treat unknown codes/events/keys by ignoring, not crashing.** Projection
   values are partial by design; new keys are added by plugins; new event types
   are merge-extensible. Preserve unknown JSON for forward compatibility.
4. **Never gate on an installed version string** — `dsh web` does not expose one
   over HTTP. If the product wants to show a version, show the session format
   version and the negotiated features, or ask the operator.

---

## 7. Live-capture appendix (DSH 0.2.2-rc.1)

Everything below was captured against a stock `dsh web` bundled with
`@deepseek-ai/dsh@0.2.2-rc.1`, on an isolated instance
(`<host>:<port>` = `127.0.0.1` and a scratch port, isolated `DSH_HOME`), with a
throwaway launch token. All tokens, cookie values and content-addressed ids are
redacted. The captures are kept outside this repository.

### 7.1 Login exchange

```http
GET /?token=<launch-token> HTTP/1.1
Host: <host>:<port>

HTTP/1.1 303 See Other
Cache-Control: no-store
Location: ./
Referrer-Policy: no-referrer
Set-Cookie: dsh-auth-<hash>=v1.<payload>.<sig>; Max-Age=2592000; Path=/; Expires=<utc>; HttpOnly; SameSite=Strict
```

```http
GET /connect?token=<launch-token>&interactions=answer HTTP/1.1

HTTP/1.1 302 Found
Cache-Control: no-store
Location: ./api/remote.mux
Set-Cookie: dsh-auth-<same-hash>=v2.<payload>.<sig>; Max-Age=2592000; Path=/; Expires=<utc>; HttpOnly; SameSite=Strict
```

```http
GET /connect?token=<launch-token>&interactions=both   → 400  interactions must be declared once as answer or none
GET /connect                                          → 401  unauthorized
GET /?token=<wrong-token>                             → 401  dsh web authentication required; reopen the URL printed by dsh web.
GET /  (cookie v2)                                    → 401  (only v1 renders the SPA)
POST /api/session/list  (no cookie)                   → 401  unauthorized
POST /api/session/list  (Origin: https://evil.example) → 403  forbidden
WS   /api/remote.mux    (Host: evil.example)          → 403  forbidden
WS   /api/remote.mux    (second socket, same v2 peer) → 409  conflict
```

### 7.2 Unary envelope round trips

```json
→ {"type":"client-request","rpcId":"<rpc-id>","method":"session/list","payload":{"args":{"_request":{}}}}
← {"type":"server-response","rpcId":"<rpc-id>","result":{"ok":true,"value":{"items":[…]}}}

→ {"type":"client-request","rpcId":"<rpc-id>","method":"session/create","payload":{"args":{"request":{"cwd":"/home/user/project"}}}}
← {"type":"server-response","rpcId":"<rpc-id>","result":{"ok":true,"value":{"sessionId":"<session-id>","agentPreset":"standard"}}}

→ … "method":"session/state","payload":{"args":{"request":{"sessionId":"<session-id>"}}}
← … {"ok":true,"value":{"cursor":20,"active":true,"running":false,"queue":[],"pendingInput":[]}}

→ … "method":"session/list","payload":{"args":{}}
← … {"ok":false,"error":{"code":"gateway/arguments-invalid","message":"typert gateway: session/list: args fields do not match the descriptor: missing \"_request\"","details":{"endpoint":"session/list"}}}

→ POST /api/session/nope
← HTTP/1.1 404  not found   (content-type: text/plain;charset=UTF-8)
```

### 7.3 Stream frames

`$events` (answering peer):

```json
← {"type":"item","streamId":"ev","value":{"type":"ready","clientId":"<event-client-id>","host":{"home":"<home>"}}}
← {"type":"item","streamId":"ev","value":{"type":"emit","event":"api-session/status","args":["<session-id>",true]}}
← {"type":"item","streamId":"ev","value":{"type":"waterfall","event":"approval/request","eventId":"<event-id>","agentId":"<session-id>","request":{…}}}
→ {"type":"item","streamId":"ev2","value":…}  // not used by $events
→ POST /api/$events/result  {"args":{"clientId":"<event-client-id>","eventId":"<event-id>","outcome":{"kind":"result","value":"rejected"}}}
← {"ok":true}
```

`session/control`:

```json
← {"type":"item","streamId":"ctl","value":{"type":"baseline","value":{"projections":{…}}}}
← {"type":"item","streamId":"ctl","value":{"type":"projection","sessionId":"<session-id>","seq":17,
    "changes":[{"key":"permissions","val":{"currentValue":"workspace-write"}}]}}
```

`session/follow` opening (trimmed):

```json
← {"type":"item","streamId":"f","value":{"type":"snapshot",
    "header":{"version":4,"id":"<session-id>","createdAt":1795110874000,
              "cwd":"/home/user/project","isSeeded":false,"agentPreset":"standard"},
    "cursor":20,"records":[{"type":"event","event":{…}},…],"hasMore":false,
    "projections":{"asOfSeq":20,"values":{…}},"assistantStream":{"revision":0,"activeAttempt":null}}}
← {"type":"item","streamId":"f","value":{"type":"event","event":{"type":"turn/start","seq":21,…}}}
← {"type":"item","streamId":"f","value":{"type":"assistant-stream","frame":{"type":"start",…}}}
```

`workspace/follow`:

```json
← {"type":"item","streamId":"w","value":{"type":"baseline","value":{"items":[],"archivedSessionIds":[],"pinnedSessionIds":[]}}}
```

### 7.4 A real prompt → streamed turn (deepseek-flash, reasoning off)

User text `Reply with exactly one word: pong` produced this event order (types
only; `seq` numbering depends on prior events in the session):

```
permission/preset  sandbox/mode  approval/policy
command/run  command/done  agent/inbox/spliced
turn/start  agent/inbox/spliced  step/start
system/message  user/message (the prompt)
user/message (runtime-context)  user/message (time-context)
request/header  request/context
session/title  session/title-llm-request
session-log-deepseek/delivery-accepted  session-log-deepseek/delivery-accepted
session/title  assistant/message  step/end  turn/end
```

Live frames for the last step:

```
start {attemptId,turn:1,step:1,startedAfterSeq:10}
chunk block-start reasoning
chunk block-end  reasoning
chunk block-start text
chunk text-delta "p"
chunk text-delta "ong"
chunk block-end text {type:'text',text:'pong'}
chunk usage {inputTokens:8802,outputTokens:3,cacheReadTokens:128,cacheWriteTokens:0,totalTokens:8933}
chunk finish {reason:{kind:'stop'},replayState:…}
end {outcome:{kind:'committed',eventType:'assistant/message',seq:21}}
```

Projections after the turn: `title:'Pong'`,
`turnOutline:[{turn:1,seq:4,prompt:'Reply with exactly one word: pong',response:'pong'}]`,
`contextPressure:{pressureTokens:8930,projectedTokens:8943,contextWindow:1048576}`,
`permissions:{currentValue:'workspace-write'}`,
`sessionListMetadata:{blank:false,lastPromptAt:…}`,
`imageLimits:{maxImageBytes:52428800,maxImagesPerMessage:20,maxMessageImageBytes:20971520}`.

A second prompt with a text + 1×1 PNG + uploaded file produced two steps: the
model emitted `tool/call` for `read` and `read_image`, then a final
`assistant/message` with `content:[{type:'text',text:'Pink pixel; text "hello
from a probe".'}]` and `turn/end {reason:{kind:'completed'}}`. The stored user
message content was:

```json
[{"type":"text","text":"Describe the attached image and the file in five words."},
 {"type":"image","attachment":{"attachmentId":"sha256:<hex>","mediaType":"image/png","width":1,"height":1,"bytes":70,"name":"one.png"}},
 {"type":"file","attachment":{"attachmentId":"sha256:<hex>","name":"file","bytes":19}}]
```

### 7.5 Waterfall answers (verified)

Approval: `request {toolName:'shell', callId:'call_…', reason:'…'}` answered
`"rejected"` → `approval/asked` and `approval/decided {outcome:'rejected'}`
landed in the transcript and the pending input cleared.

User question:
`request {questions:[{id:'q1',question:'…',header:'…',options:[{label:'Blue'},
{label:'Green'}]}]}` answered
`{answers:[{id:'q1',selected:['Blue'],custom:''}]}` → the tool returned and the
model continued in the same turn; the `userQuestions` projection settled the
call.

### 7.6 Served index (WebView hosting)

`GET /` with a v1 cookie: 200, ~40 KB SPA shell; `<script src="plugins/??…">`
combo assets; injected globals:

```
__DSH_BOOT__  __DSH_BOOT_READY__  __DSH_CONNECTION_RECOVERY__
__DSH_REMOTE_ACCESS__  __DSH_CONTACT_CONFIG__  __DSH_SHORTCUTS_CONFIG__
__DSH_DOCUMENT_PREVIEW_CONFIG__  __DSH_MODELS_ONBOARDING__
```

`__DSH_CONNECTION_RECOVERY__ = {backoffBaseMs:500, backoffFactor:2,
backoffMaxMs:10000, generationReadyWarnMs:3000, generationReadyTimeoutMs:15000}`.
The frontend is a single-page app: every route is client-side, and no URL
renders an individual plugin panel (§4.13).

---

## 8. Version compatibility (0.2.0 / 0.2.1 / 0.2.2)

The reference Dart client
(`/root/research/dsh-go/packages/dsh_client`, `dsh_client`) documents wire
semantics for DSH `0.2.0-rc.2` and `0.2.1-rc.2` and its core envelope/`$events`/
`session/follow`/`session/page`/`session/prompt` shapes are **identical** to
what 0.2.2-rc.1 served in §7. Use it as a cross-check for those; do not copy its
endpoint list wholesale.

### 8.1 Present in 0.2.2 that the reference client does not call

`session/observeState`, `session/observeProjections`, `session/observeEvent`,
`session/events` (alias of `session/page`), `session/canOpenWorkspacePath`,
`session/openWorkspacePath`, `session/workspacePathApplications`,
`session/initializeDefaultModel`, `workspace/initializeDefault`,
`workspace/insertSessionBefore`, `pluginManager/listVersions`,
`pluginManager/listVersionExemptions`, `pluginManager/setVersionExemption`,
`pluginManager/updateBundle`, `pluginManager/readBundleDetail`,
`pluginManager/inspect`, `schedule/catalog`, `schedule/deliveryLimits`,
`schedule/deleteInactive`, `account/*`. A new client can use them, but should
feature-detect (§6.4) if it may talk to older Hosts.

### 8.2 Called by the reference client but **absent from the stock 0.2.2 web profile** (verified 404)

| Endpoint | Note |
|---|---|
| `subagent/catalog`, `subagent/descriptor` | replaced in 0.2.2 by `subagents/prompt`, `subagents/interruptByParent` + subagent addresses in `session/follow` |
| `team/member`, `team/task` | agent-team feature is a plugin composition; not exposed in the stock web profile |
| `deliverables/presented` | event type exists (`dsh-tool-present`); no Remote method in the stock profile |
| `workspace/changes` | event type exists in a plugin, no Remote method in the stock profile |
| `terminal/follow`, `terminal/write`, `terminal/resize` | replaced by `terminal/attach` (stream) + `terminal/create`/`retain`/`close`/`rename` |
| `schedule/delete`, `schedule/change`, `schedule/update` | replaced by `schedule/edit` (+ `schedule/deleteInactive` for ended tasks) |
| `companion/*` | dsh-go-specific companion surface, never a DSH Host method |
| `session/uploadFileBinary` as an RPC | it is an HTTP route in 0.2.2 (§4.10) |
| `dsh-go/v1/runtime-capabilities` | dsh-go companion transport, not DSH |

These are exactly the calls that make a naive port of the reference client look
broken against a 0.2.2 Host. Feature-detect them and hide the corresponding UI.

### 8.3 Endpoint behaviour that changed in a way a client must expect

| Behaviour | 0.2.2 rule |
|---|---|
| `session/list` request | requires `{"_request":{}}`; a bare `{}` fails `gateway/arguments-invalid` |
| `session/state` / `session/projections` args | both wrap in `request:{sessionId}` (some earlier docs show flat `sessionId`) |
| schedule timing | typed object (`{kind:'daily',daily:{time,time_zone}}`), not `{hour,minute}`; wrong shape → `gateway/input-invalid` |
| `workspaceFiles/list` path | `""` rejected; use `"."` for the workspace root |
| `session/search` | disabled unless the deployment configures a session-query index; error is `gateway/internal`, not a domain code |
| `$events` on a `none` peer | `gateway/interactions-forbidden` stream error, not an HTTP rejection |
| assistant live stream | `assistant-stream` frames are opt-in (`assistantStream:true`) and carry `revision`; a revision bump voids earlier frames |
| transcript replacements | `surfaceOp: 'append'` is the render filter; replacements are model-only (§5.2) |

### 8.4 Forward compatibility rules

- Unknown endpoint → 404 `not found`: hide the feature.
- Unknown method returns `gateway/method-unavailable`/`invocation-unavailable`:
  same treatment.
- Unknown `error.code`: treat as a generic failure, preserve `details`.
- Unknown projection key, event type, content block type or source `kind`:
  ignore for rendering, keep JSON.
- A newer `header.version` (> 4) in `session/follow`: read-only mode is safe
  (unknown events are ignorable); do not write to a session whose format the
  client does not understand — refuse prompts with an explainable error.
- Additive JSON fields must not break parsing: every decoder should ignore
  extras (no strict mode).

---

## 9. Recommended client transport design (Cuplivo)

This is the shape that fits the architecture contract in `architecture.md` and
was validated by the reference client:

1. **One HTTP client + one long-lived WebSocket per connected remote.** Keep a
   `DshConnection` object owning base URL, authority, secure flag, cookie,
   `$events` clientId/generation and the stream registry.
2. **Login:** parse the pasted/launch URL (`?token=`), `GET /?token=…` with the
   `Host` header and no `Origin`, store the v1 cookie in secure storage keyed by
   remote id. Retry login only on 401. Never store the launch token.
3. **Transport:** `dart:io` `HttpClient`/`WebSocket` (or `package:web_socket_channel`)
   with `Host` header set; no `Origin`; accept `permessage-deflate`. Backoff
   `500 ms · 2ⁿ` capped at 10 s with jitter; ready timeout 15 s (warn at 3 s).
4. **Mux:** one socket, `$events` opened first, then `session/control`,
   `workspace/follow`, and `session/follow` per open chat. A `DshStream` object
   per logical stream with `id`, endpoint, args, open/close, backpressure and a
   `revision`/`generation`. On reconnect reopen all of them; each opening
   baseline replaces local state.
5. **Unary RPC:** `POST /api/<endpoint>` with `{type,rpcId,method,payload:{args}}`,
   UUID correlation, one retry for idempotent reads on transport reset, domain
   errors mapped to a typed `DshFailure(code, message, details)`.
6. **State:** a pure-Dart store (`DshSessionStore`) keyed by session id holding
   `header`, `records` (seq-ordered), `projections`, `state`,
   `assistantStream` buffer, and a `transcript` reducer (§5.6). The UI listens to
   the store; no Flutter imports in `lib/core/dsh/`.
7. **Approvals/questions:** `$events` `waterfall` → typed prompt objects deduped
   by `eventId`, answered through `$events/result` with `clientId` of the current
   generation; a card dismissed without an answer stays pending — re-show it
   after reconnect (the Host redelivers pending waterfalls).
8. **Composer:** text + base64 images (within `imageLimits`) + uploaded files
   (`/api/session/uploadFileBinary` → `receiptId`); `mode:'queue'` normally,
   `mode:'steer'` when the user interrupts the running turn; optimistic row
   matched by `requestId`/`rpcId`; `/` commands via `commands/list` +
   `commands/execute`.
9. **Settings/engine:** `settings/describe` to render engine settings,
   `settings/mutate` for single values (`permission.defaultPreset`,
   `session-log-deepseek.enabled`, provider profiles under `llm-pi-ai`),
   `permissionPresets/catalog` + `/permission` command for a session's mode,
   `session/modelCatalog` + `session/selectModel` for model/reasoning choice.
10. **Plugins:** inventory/management via `pluginInventory/list` +
    `pluginManager/*`; plugin **panels** only by hosting the full DSH SPA in a
    WebView with the v1 cookie (§4.13) — no per-panel URL exists in 0.2.2.
11. **WebView:** use a separate cookie store for the SPA; do not share the API
    cookie header with it (same cookie name, different variant — §1.3).
12. **Observability:** keep the last N frames/errors in memory for a diagnostics
    screen; redact cookie, token, `details` secrets, and hostnames for support
    bundles.

---

## 10. Provenance and redaction

- All endpoint/shape facts were compiled from the installed 0.2.2-rc.1
  `typert.*.d.ts`/host faces and verified by live requests against an isolated
  instance; §0 lists what was and was not exercised.
- The repository must never contain: launch tokens, cookie values, private
  hostnames/IPs of real deployments, content-addressed attachment ids from a
  real session, or message text from a real user. Samples here are synthetic or
  redacted (`<session-id>`, `<rpc-id>`, `dshtoken`, `<host>`, `sha256:<hex>`).
- Temporary probing scripts and captured JSON live outside the repository and
  are not part of the deliverable.


