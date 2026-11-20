# DSH protocol client — public API contract

Status: implementation contract for `lib/core/dsh/**` (owner `dsh-client-core`).
Everyone building the feature layer codes against **this file**, not against the
implementation. If the surface below changes, this file is updated in the same
change and the team is told.

Ground truth behind it: `docs/cuplivo-dsh/protocol.md` (0.2.2-rc.1 wire
capture), `docs/cuplivo-dsh/client-reference.md` (client-layer design),
`docs/cuplivo-dsh/architecture.md` (invariants, module layout).

## 1. Rules the client holds to

1. **Flutter-free.** Everything under `lib/core/dsh/` imports only `dart:*` and
   sibling `dsh_*` files. No `package:flutter`, no Drift, no Cuplivo models.
2. **No persistence.** The client stores nothing on disk. The cookie is returned
   to the caller to put in secure storage; everything else is live state that is
   dropped on `close()`.
3. **Transport and business failure are separate domains.** 401/403/404/4xx are
   carrier results (`DshAuthException`, `DshUnsupportedException`,
   `DshProtocolException`); HTTP 200 with `result.ok:false` is a business answer
   (`DshRemoteException(code, message, details)`); sockets are
   `DshTransportException`.
4. **One cookie, one authority, one mux.** The login cookie is bound to
   `host[:port]`; every request sends that exact `Host` and no `Origin`. One
   `DshClient` == one remote connection == one WebSocket.
5. **Login is the v1 browser cookie** (`GET /?token=…`), not `/connect` (v2):
   the same cookie authenticates `/api`, `/api/remote.mux` **and** the WebView
   SPA, so plugin pages can reuse it. The launch token is used once and never
   retained by the client after `login()`.
6. **Reconnect is a generation.** Losing the WebSocket voids every logical
   stream; nothing is replayed. `DshSession.watch()` re-opens `session/follow`
   and re-emits a snapshot; `DshTranscript` replaces its state from that
   snapshot. `DshCatalog`'s live streams re-open and re-deliver baselines.
7. **Append-origin only.** The transcript renders durable message events with
   `surfaceOp == 'append'`; replacement events are model context and are
   skipped. Unknown event types/projection keys/content blocks are tolerated.
8. **Feature-detect, never gate on a version string.** Endpoints absent from a
   Host answer HTTP 404 → `DshUnsupportedException`; `DshCatalog` caches a
   capability flag per endpoint and exposes it as a boolean.

## 2. Files

| file | contents |
|---|---|
| `dsh_errors.dart` | sealed `DshException` hierarchy + endpoint exception (shared; one small file beyond the §3 list so lower layers can throw typed errors without import cycles) |
| `dsh_endpoint.dart` | `DshEndpoint`: URL/token parsing, authority, secure flag, URI builders |
| `dsh_transport.dart` | `DshCookie`, HTTP/WebSocket carrier (`DshTransport`, `DshHttpTransport`, `DshIoHttpClient`), login, upload, raw HTTP response bytes, request/asset timeouts |
| `dsh_rpc.dart` | `DshRpc`: `{type:'client-request'…}` envelope, `server-response` decode, error mapping, one retry for idempotent reads, `dshUuidV4()` |
| `dsh_mux.dart` | `DshMux`: `/api/remote.mux` connection, generations, `$events` ready + host requests, logical streams (incl. `sendItem` uplink), reconnect backoff, keepalive, disposal |
| `dsh_events.dart` | wire event vocabulary: `DshConnectionState`, session log events, `session/follow` snapshot frames, assistant-stream frames/chunks, host events, approvals/questions, mux frames, workspace updates, `DshSessionUpdate` |
| `dsh_models.dart` | tolerant JSON helpers + domain models: messages/parts/usage, session summaries/state/projections (incl. `contextPressure`), file stats, agent presets, model catalog, providers, permissions, commands, skills, plugins, settings, account, credentials |
| `dsh_catalog.dart` | typed reads/writes for sessions, workspaces, models, providers, plugins, commands, skills, permission presets, agent presets, settings, account; live `session/control` + `workspace/follow` watchers; capability probes |
| `dsh_session.dart` | one session handle: `watch()` (snapshot + live events + host requests), prompt (text/images/files), cancel, model/reasoning/permission writes, approvals/questions, history paging, commands/skills, upload, terminal stage-1 RPCs, dispose; `DshSessionStore` = handle + `DshTranscript` + change stream for the UI controller |
| `dsh_projection.dart` | `DshTranscript`: folds snapshot + durable events + live assistant frames into ordered renderable items and UI state (no Flutter) |
| `dsh_terminal.dart` | terminal stage 1: `terminal/*` constants, `DshTerminalEnvironment/Info/Shell`, tolerant `terminal/attach` frames (`snapshot`/`output`/`state`/`ack`/unknown), `DshTerminalAttachment` (frames + write/resize/close) |
| `dsh_client.dart` | public entry: `DshClient(endpoint)` → `login`, `useCookie`, `connect`, `loadCatalog`, `createSession`, `openSession`, workspace-file stat/bytes, `close` |

## 3. Errors (`dsh_errors.dart`)

```dart
sealed class DshException implements Exception {
  const DshException(this.message);
  final String message;
}

/// Invalid pasted UI URL / token form. Show next to the input field.
final class DshEndpointException extends DshException {
  final String? field; // 'url' | 'token'
}

/// 401/403 (or 409 on the mux upgrade): the cookie is missing/expired/foreign
/// or the Host/Origin fence refused us. Ask the user for a fresh WebUI URL.
final class DshAuthException extends DshException {
  final int? statusCode;
}

/// Host answered `ok:false` (or a stream `error` frame).
final class DshRemoteException extends DshException {
  final String code;             // e.g. 'session/not-found', 'gateway/arguments-invalid'
  final Map<String, Object?> details;
  bool get isGatewayError;       // code starts with 'gateway/'
  bool get isNotFound;           // session|workspace|job/not-found
}

/// DNS/TCP/TLS/timeout/WebSocket loss. Retryable unless [retryable] is false.
final class DshTransportException extends DshException {
  final Object? cause;
  final bool retryable;
}

/// Malformed envelope/frame/JSON; version mismatch or client bug.
final class DshProtocolException extends DshException {}

/// Endpoint not mounted in this DSH version (HTTP 404). Hide the capability.
final class DshUnsupportedException extends DshException {
  final String endpoint;
}

/// Caller closed the client/stream.
final class DshClosedException extends DshException {}
```

All I/O futures throw these; no raw `SocketException`/`FormatException` crosses
the boundary. Login may also throw `DshProtocolException` when the redirect
carries no `dsh-auth-*` cookie.

## 4. Endpoint (`dsh_endpoint.dart`)

```dart
class DshEndpoint {
  const DshEndpoint({required this.baseUri, this.token, required this.authority, required this.secure});

  /// Accepts: bare `host:port`, `host:port/?token=…`,
  /// `http(s)://host:port/?token=…`, and the whole `dsh web: <url>` line.
  /// Surrounding whitespace/quotes and a `?token=` value are optional; the
  /// path is kept as a mount prefix (`https://h/ui/?token=…` → `/ui`).
  /// Throws [DshEndpointException] for no host, unsupported scheme,
  /// userinfo-in-URL, bad port, or a token that is present but unusable.
  factory DshEndpoint.parse(String input);

  final Uri baseUri;      // scheme://host[:port][/mount], no query/fragment
  final String? token;    // launch token, only kept until login()
  final String authority; // host[:port] as sent in the Host header & cookie binding
  final bool secure;      // https/wss

  bool get hasToken;
  String get origin;          // scheme://authority
  Uri get indexUri;           // GET /?token=… (login) — throws when no token
  Uri apiUri(String endpoint);
  Uri get muxUri;             // ws(s)://authority[/mount]/api/remote.mux
  Uri uploadUri(String sessionId, {String? name, String? mediaType});
  Uri fileUri(String absolutePath, {String? version});

  DshEndpoint withToken(String token);
  DshEndpoint withoutToken();
}
```

`authority` omits a default port (`http:80`, `https:443`) exactly as the Host
header does; IPv6 literals are bracketed. `apiUri('session/list')` →
`<base>/api/session/list`.

## 5. Transport (`dsh_transport.dart`)

```dart
class DshCookie {
  const DshCookie({required this.name, required this.value, required this.authority, this.expiresAt});
  factory DshCookie.fromJson(Map<String, Object?> json);
  final String name;        // 'dsh-auth-<base64url(sha256(authority))>'
  final String value;       // 'v1.<payload>.<signature>' — opaque bearer
  final String authority;   // host[:port] it is bound to
  final DateTime? expiresAt;
  String get header;        // 'name=value'
  bool isExpiredAt(DateTime now);
  Map<String, Object?> toJson();
}

abstract interface class DshTransport {
  DshEndpoint get endpoint;
  DshCookie? get cookie;
  String get authority;
  bool get secure;

  /// GET /?token=… , followRedirects:false, explicit Host, no Origin.
  /// Captures the v1 `Set-Cookie` into [cookie] and returns it.
  Future<DshCookie> login(String token);

  /// GET / with the cookie: authenticates the pair before the mux opens.
  Future<void> verify();

  /// Set a cookie restored from secure storage (no login, no token).
  void useCookie(DshCookie cookie);

  /// POST /api/<endpoint> with the authenticated transport; returns the raw
  /// HTTP response. Status mapping is the RPC layer's job.
  Future<DshHttpResponse> post(String endpoint, Object? envelope);

  Future<DshHttpResponse> get(Uri uri);
  Future<DshHttpResponse> postBytes(Uri uri, List<int> bytes, {required String contentType});
  Future<DshSocket> openMux();
  Future<void> close({bool force = false});
}

class DshHttpResponse {
  final int statusCode;
  final Map<String, String> headers;
  final List<String> setCookie;
  final String body;        // UTF-8 view (JSON envelopes, diagnostics)
  final Uint8List? bytes;   // raw carrier bytes, when the carrier captured them
  Uint8List get bodyBytes;  // bytes ?? utf8.encode(body)
}

abstract interface class DshSocket {
  Stream<Object?> get frames;  // decoded JSON values, one per text frame
  void send(Object? frame);
  Future<void> get done;
  Future<void> close([int code, String? reason]);
}

class DshHttpTransport implements DshTransport {
  DshHttpTransport(DshEndpoint endpoint, {DshCookie? cookie, DshHttpClient? httpClient});
}

/// Injectable byte-level HTTP/WS client (real implementation: [DshIoHttpClient]).
abstract interface class DshHttpClient {
  Future<DshHttpResponse> send(DshHttpRequest request);
  Future<DshSocket> upgrade(DshHttpRequest request);
  void close({bool force = false});
}

class DshIoHttpClient implements DshHttpClient { ... } // dart:io HttpClient / WebSocket
```

`DshTransport.get` is also the raw-byte GET path: `DshIoHttpClient` keeps the
exact response bytes (`DshHttpResponse.bytes` / `bodyBytes`) alongside the UTF-8
`body`, so PNG/PDF/attachment downloads are not corrupted by decoding. The
`GET /api/file` 302 to the versioned cache URL is followed **by `DshClient`
locally, with the same cookie and authority** (the shared transport keeps
`followRedirects:false`); see §13.

Behaviour: 10 s TCP/TLS connect, 30 s default request timeout, 10 minutes for attachment upload, 120 s for `llm/discoverModels`; `HttpClient.autoUncompress = true`; no `Origin`,
`Referer`, or `Sec-Fetch-*` headers; `Host` always the endpoint authority;
`WebSocket` opened with `dart:io` (deflate negotiated transparently), client
`pingInterval` 15 s for dead-link detection. `login()` does **not** follow the
303/302 (`followRedirects:false`); it only parses status + `Set-Cookie`.

## 6. Unary RPC (`dsh_rpc.dart`)

```dart
class DshRpc {
  DshRpc(this.transport, {this.timeout = const Duration(seconds: 30)});
  final DshTransport transport;
  final Duration timeout;

  /// Sends `{"type":"client-request","rpcId":uuid,"method":endpoint,
  /// "payload":{"args":args}}`, decodes `server-response`, returns `value`.
  Future<Object?> call(
    String endpoint, {
    Map<String, Object?> args = const {},
    Duration? timeout,
    bool idempotent = false, // retries once on a retryable transport failure
  });
}

String dshUuidV4(); // rpcIds, streamIds, prompt requestIds
```

Mapping: 200+`ok:true` → `value` (absent → `null`); 200+`ok:false` →
`DshRemoteException(code, message, details)`; 401/403 → `DshAuthException`;
404 → `DshUnsupportedException`; 400/405/413/415 → `DshProtocolException`;
5xx/network/timeout → `DshTransportException`; wrong `type`/`rpcId`/missing
`result`/non-object body → `DshProtocolException`. A gateway validation answer
echoing `rpcId:"invalid-request"` is accepted as a normal (error) result.
`idempotent: true` is for reads only (`list`, `page`, `state`, `projections`,
`describe`, catalogs); never for `session/prompt`, whose inbox admission may
already have landed.

## 7. Mux (`dsh_mux.dart`)

`DshConnectionState` is declared in `dsh_events.dart` (shared by mux, session
and store): `idle, connecting, connected, reconnecting, unauthorized, closed`.

```dart
const String dshRemoteMuxPath = '/api/remote.mux';
const String dshHostEventsEndpoint = r'$events';
const String dshHostEventResultEndpoint = r'$events/result';

class DshMuxGeneration {
  final int number;       // 1, 2, … per successful ready handshake
  final String clientId;  // goes into every $events/result answer
  final String home;
}

class DshMuxOptions {
  const DshMuxOptions({
    this.readyTimeout = const Duration(seconds: 15),
    this.pingInterval = const Duration(seconds: 15),
    this.retryCaps = const [500ms, 1s, 2s, 4s, 8s, 10s], // 50–100 % jitter
    this.autoReconnect = true,
    this.maxAttempts,      // null = retry forever
    this.retryDelay,       // test hook: Duration Function(int attempt)
    this.hostRequestGrace = const Duration(seconds: 3),
  });
}

class DshMux {
  DshMux(this.transport, {this.options = const DshMuxOptions(), DshRpc? rpc});
  final DshRpc rpc;

  DshConnectionState get state;
  DshMuxGeneration? get generation;        // null until first ready
  DshException? get lastError;
  Stream<DshConnectionState> get states;   // broadcast
  Stream<DshHostEvent> get hostEvents;     // ready excluded
  List<DshHostRequest> get pendingRequests;

  Future<DshMuxGeneration> get ready;      // starts the socket if needed

  /// Opens one logical stream now (frames wait for the next ready). With
  /// autoReopen (default) the same DshStream survives reconnects; the Host
  /// re-delivers a baseline, which consumers must treat as replace.
  Future<DshStream> open(String endpoint, {
    Map<String, Object?> args = const {},
    bool autoReopen = true,
  });

  /// `$events/result` with the current generation's clientId; retries once if
  /// the generation changed mid-flight (Host reports an unknown clientId).
  Future<void> answerHostRequest(String eventId, Map<String, Object?> outcome);

  Future<DshMuxGeneration> reconnect(); // after unauthorized/exhaustion
  Future<void> close();
}

class DshStream {
  final String id;
  final String endpoint;
  final Map<String, Object?> args;
  final bool autoReopen;
  Stream<Object?> get items; // decoded `value` of each item frame
  bool get isClosed;
  Future<void> cancel();     // client→host cancel (cleanup)
}
```

The mux opens `$events` first on every socket and waits for
`{type:'ready',clientId,host:{home}}`; only then is the generation live and
queued stream `open` frames are sent. Server `error` frames close the logical
stream with `DshRemoteException`; losing the socket voids everything and
auto-reopen streams get a fresh opener on the next generation. `DshMux.close()`
is a normal local shutdown: open streams complete **without** an error (only
generation loss for a non-reopen stream, or a remote `error` frame, errors a
stream). Pending
waterfalls are kept for `hostRequestGrace` after a new ready; those not
redelivered (same `eventId`) are retracted. `answerHostRequest` also emits a
local `DshHostRequestCancelled` after a successful answer so a UI can drop the
card immediately.

## 8. Wire events and models (`dsh_events.dart`, `dsh_models.dart`)

`dsh_models.dart` exports tolerant JSON helpers (public; the feature layer
reuses them for plugin JSON): `jsonMap`, `jsonList`, `jsonString`, `jsonInt`,
`jsonDouble`, `jsonBool`, `jsonEpochMs`, `jsonIsoDateTime`, `jsonStringList`,
`tryDecodeJson`.

Models (immutable; `raw` kept where forward compatibility matters):

- messages: `DshPart` (`DshTextPart`, `DshReasoningPart`, `DshImagePart`,
  `DshFilePart`, `DshToolCallPart`, `DshUnknownPart`), `DshMessage`,
  `DshMessageSource`, `DshImageAttachment`, `DshFileAttachment`,
  `DshTokenUsage` (step shape) and `DshSessionUsage` (projection shape; note
  `uncachedInputTokens`, not `inputTokens`), `DshLlmFailure`
- sessions: `DshSessionSummary` (+`DshProjectionHints`), `DshSessionCreated`,
  `DshSessionHeader` (`version`, `isReadable` for version > 4), `DshSessionState`,
  `DshQueuedItem`, `DshSessionProjections` (typed getters + `values`),
  `DshImageLimits`, `DshHistoryPage` (raw `records`, used by the session layer),
  `DshSessionAttachment`, `DshUploadReceipt`
- models/providers: `DshModelSelection`, `DshReasoningEffort`,
  `DshReasoningInfo`, `DshModelInfo`, `DshProviderGroup`, `DshModelCatalog`,
  `DshModelCatalogFailure`, `DshProviderInfo`, `DshConfigurableProvider`,
  `DshModelDiscoveryRequest`, `DshDiscoveredModel`
- permissions/commands/skills: `DshApprovalOutcome`, `DshPermissionPreset`,
  `DshPermissionPresetCatalog`, `DshCommandDescriptor`, `DshCommandResult`,
  `DshCommandExecution`, `DshSkill`
- workspaces: `DshWorkspace`, `DshWorkspaceBaseline`, `DshWorkspaceValue`,
  `DshWorkspaceCreated`
- plugins: `DshLocalizedText` (resolve locale → language → `en`), `DshPluginInventory`,
  `DshPluginInventoryEntry`, `DshPresetPluginRow`, `DshAgentPresetPluginGroup`,
  `DshPluginBundleInfo`, `DshPluginInfo`, `DshPluginChangeResult`
- settings/account: `DshSettingsDescription`, `DshSettingsNamespace`,
  `DshSettingsSecret`, `DshSettingsPathOp` (`DshSettingsSetOp`,
  `DshSettingsUnsetOp`), `DshCredentialInfo`, `DshAccountState`, `DshAccountLinks`
- session control: `DshSessionControlUpdate` sealed →
  `DshSessionControlBaseline(Map<String, DshSessionProjections>)` and
  `DshSessionControlProjection(sessionId, List<DshSessionControlChange>, seq)`.
  Each change carries `key` + complete new `value`; `key`/`value` getters are
  conveniences for the single-change frame.
- v2 additions: `DshContextPressure{pressureTokens, projectedTokens,
  contextWindow, ratio}`, `DshFileStat{absolutePath, path?, version?, bytes?,
  mediaType?, raw}`, `DshAgentPresetSummary{id, order, isDefault, name?, raw}`.
  `DshPluginInventory.agentPresets` is already a parsed
  `List<DshAgentPresetPluginGroup>` (id/name/isDefault/broken/rows), so plugin
  settings can use it without re-parsing the inventory JSON.

`dsh_events.dart` exports:

- mux frames: `DshMuxFrame` → `DshMuxItem`, `DshMuxEnd`, `DshMuxError`,
  `DshMuxUnknown`
- follow snapshot: `DshSessionSnapshot { header, cursor, records, hasMore,
  projections, assistantStream }`, `DshAssistantStreamBaseline`,
  `DshAssistantStreamAttempt` (also `streamTimes`/`firstChunkTime`, UTC)
- durable events: `DshSessionEvent` sealed hierarchy with `seq`, `time`,
  `type`, `surfaceOp`, `isAppendOrigin`, `sourceEventSeqs`,
  `ignorable`, `raw`: `DshTurnStarted`, `DshTurnEnded` (→ `DshTurnEndReason`
  with `DshLlmFailure`), `DshStepStarted`, `DshStepEnded`, `DshUserMessageEvent`
  (`isHumanPrompt`), `DshAssistantMessageEvent`, `DshAssistantAttemptEvent`,
  `DshToolCallEvent`, `DshToolResultEvent`, `DshTitleEvent`,
  `DshModelSelectionEvent`, `DshPermissionPresetEvent`, `DshSandboxModeEvent`,
  `DshApprovalPolicyEvent`, `DshApprovalAskedEvent`, `DshApprovalDecidedEvent`,
  `DshCommandRunEvent`, `DshCommandDoneEvent`, `DshInboxSplicedEvent`,
  `DshLlmRetryEvent`, `DshWorkingDirectoryChangedEvent`,
  `DshAgentPresetSelectedEvent`, and `DshUnknownSessionEvent` (kept for
  ordering; never rendered)
- live assistant stream: `DshAssistantStreamFrame` → `DshAssistantStreamStart`,
  `DshAssistantStreamChunkFrame`, `DshAssistantStreamEnd`,
  `DshAssistantStreamUnknown`; `DshAssistantStreamOutcome` →
  `DshAssistantStreamCommitted(eventType, seq)` / `DshAssistantStreamAbandoned`;
  `DshStreamChunk` → `DshBlockStartChunk`, `DshTextDeltaChunk`,
  `DshReasoningDeltaChunk`, `DshToolCallDeltaChunk`, `DshBlockEndChunk`,
  `DshUsageChunk`, `DshFinishChunk` (+`DshFinishReason`), `DshUnknownChunk`.
  `revision` is a **per-frame counter** used only to drop out-of-order frames;
  `attemptId` identifies the attempt.
- host events: `DshHostEvent` sealed → `DshHostReady(clientId, home)`,
  `DshHostEmit(event, args)` (helpers: `arg0`, `sessionSummary`, `running`,
  `revision`, `namespace`, `name`), `DshHostUnknown`; host requests:
  `DshHostRequest` → `DshApprovalRequest` (eventId, sessionId, toolName, callId,
  reason, displayReason, `describe(locale)`), `DshUserQuestionRequest`
  (questions, wait) with `DshUserQuestion`, `DshQuestionOption`, `DshQuestionWait`,
  `DshUnknownHostRequest`; `DshHostRequestCancelled`. Answers:
  `DshApprovalDecision` (`allowOnce`/`rejected`), `DshQuestionAnswer`
  (`selected` = option **labels**).
- workspace updates: `DshWorkspaceUpdate` sealed → `DshWorkspaceBaselineUpdate`,
  `DshWorkspaceReplaceUpdate`, `DshWorkspaceUpsertUpdate`,
  `DshWorkspaceRemoveUpdate`, `DshWorkspaceOrderUpdate`,
  `DshWorkspaceArchivedUpdate`, `DshWorkspacePinnedUpdate`; parser
  `DshWorkspaceUpdate.tryParse(Object?)` returns null for unknown frames.
- session watch updates: `DshSessionUpdate` sealed →
  `DshSessionSnapshotUpdate`, `DshSessionEventUpdate`,
  `DshSessionAssistantFrameUpdate`, `DshSessionHostRequestUpdate`,
  `DshSessionConnectionUpdate(state, error)`.

## 9. Catalog (`dsh_catalog.dart`)

```dart
class DshCatalogSnapshot {
  final List<DshSessionSummary> sessions;     // stored order (UI sorts)
  final List<DshWorkspace> workspaces;
  final List<String> archivedSessionIds;
  final List<String> pinnedSessionIds;        // most-recent-first
  final DshModelCatalog models;
  final List<DshProviderInfo> providers;
  final List<DshConfigurableProvider> configurableProviders;
  final DshPermissionPresetCatalog permissionPresets;
  final DshPluginInventory plugins;
  final DshSettingsDescription settings;
  final DshAccountState? account;
  final DshCapabilities capabilities;
  final DateTime loadedAt;
}

class DshCapabilities {
  Map<String, bool> get known;      // probed/read endpoints
  bool? lookup(String endpoint);    // null = never probed
  bool supports(String endpoint);   // unknown => false (feature hidden)
  void record(String endpoint, bool present);
}

class DshCatalog {
  DshCatalog(DshRpc rpc, DshMux mux);
  final DshCapabilities capabilities;

  Future<DshCatalogSnapshot> load({
    bool includePlugins = true,
    bool includeSettings = true,
    bool includeAccount = true,
  });

  // sessions
  Future<List<DshSessionSummary>> listSessions();
  Future<DshSessionCreated> createSession({String? cwd, String? workspaceId, String? agentPreset, String? sessionId});
  Future<String> renameSession(String sessionId, String title);
  Future<String> forkSession(String sessionId, {int? atSeq, bool allowMigration = false});
  Future<DshSessionState> sessionState(String sessionId);
  Future<DshSessionProjections?> sessionProjections(String sessionId);

  // workspaces (no unary list: the follow baseline is the list)
  Future<DshWorkspaceBaseline> loadWorkspaces();       // opens, reads baseline, cancels
  Stream<DshWorkspaceUpdate> watchWorkspaces();
  Future<DshWorkspaceCreated> createWorkspace(String path);
  Future<DshWorkspace> renameWorkspace(String workspaceId, String title);
  Future<void> deleteWorkspace(String workspaceId);
  Future<List<String>> reorderWorkspaces(String workspaceId, {String? beforeWorkspaceId});
  Future<DshWorkspace> reorderWorkspaceSessions(String workspaceId, String sessionId, {String? beforeSessionId});
  Future<DshWorkspace?> initializeDefaultWorkspace();
  Future<List<String>> archiveSession(String sessionId, {bool? stopActivity});
  Future<List<String>> unarchiveSession(String sessionId);
  Future<List<String>> pinSession(String sessionId, {required bool pinned});

  // models / providers / credentials
  Future<DshModelCatalog> loadModelCatalog();
  Future<DshModelSelection> selectModel(String sessionId, DshModelSelection selection);
  Future<void> initializeDefaultModel();
  Future<List<DshProviderInfo>> listProviders();
  Future<List<DshConfigurableProvider>> listConfigurableProviders();
  Future<List<DshDiscoveredModel>> discoverModels(String settingsNs, DshModelDiscoveryRequest request, {Duration timeout = const Duration(seconds: 120)});
  Future<Map<String, DshCredentialInfo>> describeCredentials(List<String> refs);
  Future<void> setCredential(String ref, String value);
  Future<void> unsetCredential(String ref);

  // permissions / commands / skills
  Future<DshPermissionPresetCatalog> loadPermissionPresets();
  Future<List<DshCommandDescriptor>> listCommands(String sessionId); // commands/list roster
  Future<List<DshSkill>> listSkills(String sessionId);

  // settings
  Future<DshSettingsDescription> describeSettings();
  Future<DshSettingsNamespace> updateSettings(String ns, Map<String, Object?> patch, {int? expectedRevision});
  Future<DshSettingsNamespace> replaceSettings(String ns, Map<String, Object?> section, {int? expectedRevision});
  Future<DshSettingsNamespace> mutateSettings(String ns, List<DshSettingsPathOp> ops, {int? expectedRevision});
  Future<void> setDefaultPermissionPreset(String preset); // permission.defaultPreset
  Future<void> setSessionLogUpload(bool enabled);        // session-log-deepseek.enabled

  // agent presets / plugins / account
  Future<List<DshAgentPresetSummary>> listAgentPresets(); // agentPresets/list {presets:[{id,order,isDefault,name?,description?,broken?}]}
  Future<String> selectAgentPreset(String sessionId, String presetId); // agentPresets/select {agentId,agentPreset}
  Future<DshPluginInventory> loadPluginInventory();
  Future<List<DshPluginBundleInfo>> listPluginBundles();
  Future<List<DshPluginInfo>> listPlugins();
  Future<DshPluginChangeResult> setBundleEnabled(String name, bool enabled);
  Future<DshPluginChangeResult> setPluginEnabled(String entryId, bool enabled);
  Future<DshAccountState> accountState();

  // live control surface
  Stream<DshSessionControlUpdate> watchSessionControl();

  // capability probe (cached): call with {}; 404 => false, any mounted answer => true
  Future<bool> supports(String endpoint);
}
```

`load()` issues independent reads concurrently (sessions, workspaces, models,
providers, presets, plugins, settings, account), records a capability flag per
endpoint, tolerates absent optional endpoints (capability false + empty
collection) and propagates auth/transport faults. `session/list` is required: a
404 there fails the load because the surface cannot function.
`watchWorkspaces()` / `watchSessionControl()` reopen after a generation loss and
re-emit the Host baseline; consumers replace local state wholesale.
There is **no** provider CRUD, workspace/list or workspace/select endpoint in
0.2.2; configuration writes go through `settings/*` with the revision CAS.

## 10. Session handle (`dsh_session.dart`)

```dart
class DshSessionOptions {
  const DshSessionOptions({
    this.maxMessages = 100,             // opening snapshot window
    this.turnWindowMinMessages = 100,
    this.turnWindowMinTurns = 10,
    this.historyPageMessages = 60,      // session/page size
    this.snapshotTimeout = const Duration(seconds: 20),
    this.promptTimeout = const Duration(seconds: 30),
    this.assistantStream = true,
  });
}

class DshSession {
  DshSession({required this.sessionId, required this.mux, required this.rpc,
      required this.transport, this.options = const DshSessionOptions()});
  static Future<DshSession> open({required mux, required rpc, required transport,
      required String sessionId, bool activate = false, options});

  final String sessionId;
  Stream<DshSessionUpdate> get updates;   // broadcast; snapshot-first
  DshSessionSnapshot? get snapshot;
  DshSessionHeader? get header;
  DshSessionProjections get projections;
  int get lastEventSeq;                   // -1 before the snapshot
  bool get hasMoreHistory;
  Future<void> get ready;

  Future<void> watch({bool activate = false}); // idempotent; completes on snapshot
  Future<DshPromptReceipt> prompt(DshPrompt prompt, {String? requestId, String mode = 'queue'});
  Future<void> cancel();
  Future<void> updateQueue(String itemId, {required String action, DshPrompt? edit});

  Future<void> answerApproval(String eventId, DshApprovalDecision decision);
  Future<void> answerQuestions(String eventId, List<DshQuestionAnswer> answers);

  Future<DshModelSelection> setModel(DshModelSelection selection);
  Future<DshCommandExecution> executeCommand(String line); // the ONLY commands/execute path
  Future<DshCommandExecution> setPermission(String preset); // delegates to executeCommand('/permission <preset>')
  Future<DshSessionState> currentState();
  Future<DshUploadReceipt> uploadAttachment(Uint8List bytes, {String? name, String? mediaType});

  // terminal stage 1 (read-only attach; agentId == sessionId)
  Future<List<DshTerminalShell>> terminalShells();          // terminal/shells {agentId}
  Future<DshTerminalEnvironment> terminalEnvironment();     // terminal/environment {agentId}
  Future<List<DshTerminalInfo>> listTerminals();            // terminal/list {sessionId}
  Future<DshTerminalInfo> createTerminal({required int cols, required int rows, String? shellPath, String? id});
  Future<DshTerminalAttachment> attachTerminal(String id);  // mux {agentId,id}
  Future<void> closeTerminal(String id);                    // terminal/close {agentId,id}
  Future<Uint8List> attachmentBytes(DshImageAttachment attachment);
  Future<DshSessionHistoryPage> loadOlder();
  Future<void> dispose();
}

class DshPrompt {
  const DshPrompt({this.text, this.images = const [], this.files = const []});
}
class DshImageInput { Uint8List bytes; String mediaType; String? name; } // inlined base64
class DshFileInput  { String receiptId; }                               // uploadFileBinary receipt
class DshPromptReceipt { String requestId; bool accepted; }             // matches source.rpcId
class DshSessionHistoryPage { List<DshSessionEvent> events; bool hasMore; }
```

Event and chunk `time` values are parsed as UTC (`DshSessionEvent.time`,
`DshAssistantStreamChunkFrame.time`) and the transcript carries them onto rows
and the draft, so the chat can render timestamps without re-reading raw frames.

`watch()` is the activation path: `openSession(id)` → `watch(activate: true)`
before the first `prompt()` on a cold session. The stream is **not resumable**:
each generation begins with a snapshot (emitted as `DshSessionSnapshotUpdate`),
then contiguous committed events; a live `seq` jump is filled from
`session/page` before the live event is forwarded, duplicates are dropped, and
events for this session's approvals/questions are forwarded as
`DshSessionHostRequestUpdate` plus connection transitions as
`DshSessionConnectionUpdate`. Prompt images are sent inline as base64
(`{type:'image',mediaType,data,name}`); files as
`{type:'file',receiptId}` from `POST /api/session/uploadFileBinary`.
Approval answers are plain strings (`allowed-once`/`rejected`); the waterfall
`next` envelope is `{kind:'next'}`; question answers are
`{answers:[{id,selected,custom?}]}`.

### `DshSessionStore` — the state object the feature layer owns

```dart
class DshSessionStore {
  DshSessionStore({required DshSession session, DshTranscript? transcript});
  final DshSession session;
  final DshTranscript transcript;

  Stream<void> get changes;   // broadcast repaint tick; no Flutter types
  bool get isRunning;
  Future<void> start({bool activate = true}); // subscribes watch() and folds all updates; `changes` fires a microtask later
  Future<DshPromptReceipt> prompt(DshPrompt prompt, {String mode = 'queue'});
  Future<void> cancel();
  Future<void> answerApproval(String eventId, DshApprovalDecision decision);
  Future<void> answerQuestions(String eventId, List<DshQuestionAnswer> answers);
  Future<DshSessionHistoryPage> loadOlder(); // also prepends into the transcript
  Future<void> setModel(DshModelSelection selection);
  Future<void> setPermission(String preset);
  Future<void> dispose();
}
```

The Flutter controller is a thin `ChangeNotifier` mapping `changes` to
`notifyListeners()`. Store errors arrive as stream errors on `updates` and are
recorded on the transcript connection state; they do not kill the store.

## 11. Projection (`dsh_projection.dart`)

```dart
class DshTranscript {
  // feeding
  void applySnapshot(DshSessionSnapshot snapshot); // full rebuild (also reconnect)
  void prepend(List<DshSessionEvent> events);      // older history, ascending seq
  void applyEvent(DshSessionEvent event);
  void applyProjection(String key, Object? value, int seq); // session/control frame
  void applyAssistantFrame(DshAssistantStreamFrame frame);
  void applyHostEvent(DshHostEvent event);
  void setConnection(DshConnectionState state, {DshException? error});

  // state (read-only)
  DshSessionHeader? get header;
  DshConnectionState get connection;
  DshException? get connectionError;
  DshSessionProjections get projections;
  DshSessionSnapshot? get snapshot;
  String? get title;                       // null => "New chat"
  String? get permissionPreset;
  DshModelSelection? get modelSelection;   // projection `next`
  DshImageLimits get imageLimits;
  int? get activeTurn;
  bool get isRunning;
  DshTurnEndReason? get lastTurnReason;
  DshLlmFailure? get lastFailure;
  DshTokenUsage? get usage;
  DshContextPressure? get contextPressure; // projection `contextPressure`; null = no ring
  DshDraft? get draft;                     // transient live step
  List<DshChatRow> get rows;
  List<DshApprovalRequest> get pendingApprovals;
  List<DshUserQuestionRequest> get pendingQuestions;
  List<DshApprovalRequest> get decidedApprovals;
  bool get awaitingInput;
  DshUserMessageRow? get firstUserMessage;
}

sealed class DshChatRow { int get seq; DateTime? get time; } // time is UTC
final class DshUserMessageRow { DshMessage message; DateTime? time; String text; images; files; String? requestId; }
final class DshAssistantMessageRow { DshMessage message; int turn, step; DateTime? time; DshTokenUsage? usage; bool interrupted; String text, reasoning; }
enum DshToolState { running, succeeded, failed, cancelled }
final class DshToolRow {
  String callId, name, arguments;           // arguments = raw JSON text
  DateTime? time;                          // tool/call event time, kept after result
  DshToolState state; String? resultText; Object? meta;
  DshApprovalOutcome? approvalOutcome;     // ask/decided audits
  Map<String, Object?>? decodedArguments;
}

class DshDraft {
  String attemptId; int revision, turn, step;
  DateTime? time;                          // first live chunk (UTC); resumed baseline replays it
  String text, reasoning;
  List<DshLiveToolCall> toolCalls;         // streaming tool cards
  DshTokenUsage? usage; DshLlmFailure? failure; bool active;
}
```

Fold rules (from `protocol.md` §5.2–§5.6):

- a snapshot replaces header, projection values and rows; it is also the
  reconnect path;
- only append-origin events become rows (`surfaceOp` replacement is model
  context and skipped); a `user/message` row requires `source.kind == 'user'`;
- `assistant/message` is the durable answer (text + collapsed reasoning); tool
  calls become `DshToolRow`s keyed by `callId`, `tool/result` settles them by
  `callId` and carries `meta`; `approval/asked|decided` annotate the card and
  are not separate rows;
- live assistant frames build `DshDraft` (text/reasoning accumulate; tool-call
  deltas accumulate `argumentsDelta` in arrival order and become live tool
  rows); `attemptId` is authoritative, `revision` is a per-frame counter; a
  chunk whose attempt is not the active draft is dropped as stale; an `end`
  frame drops the draft and the durable message follows;
- waterfalls become `pendingApprovals`/`pendingQuestions`; `cancel`, settle and
  `approval/decided` remove them; reconnecting keeps them until the Host
  retracts;
- row/draft `time` is the event's UTC `time` (chunk time for the draft); it is
  nullable so fixtures, older snapshots and events without `time` still fold;
- unknown events, chunks, parts and projection keys are ignored; gaps are
  filled by the session layer so the fold stays ordered.

The feature layer maps `DshChatRow`/`DshDraft` to widgets; it must not import
anything above the wire vocabulary.

## 12. Client entry (`dsh_client.dart`)

```dart
class DshClient {
  DshClient(this.endpoint, {
    DshTransport? transport,
    DshHttpClient? httpClient,
    DshMuxOptions muxOptions = const DshMuxOptions(),
    Duration connectTimeout = const Duration(seconds: 10),
    Duration requestTimeout = const Duration(seconds: 30),
  });

  final DshEndpoint endpoint;       // token-free after pair()
  final DshTransport transport;
  final DshMuxOptions muxOptions;
  late final DshRpc rpc;
  late final DshMux mux;
  late final DshCatalog catalog;

  DshCookie? get cookie;             // persist in secure storage, per remote
  DshConnectionState get state;
  DshException? get lastError;
  Stream<DshConnectionState> get states;
  Stream<DshHostEvent> get hostEvents;
  DshCatalogSnapshot? get catalogSnapshot;
  bool get isClosed;

  Future<DshCookie> login(String token);   // v1 cookie + verify GET /
  void useCookie(DshCookie cookie);        // resume without a token
  Future<void> verify();
  Future<DshMuxGeneration> connect();      // mux ready (first generation)

  Future<DshCatalogSnapshot> loadCatalog({bool includePlugins = true, bool includeSettings = true, bool includeAccount = true});

  // workspace-file preview bytes (core owns transport/auth; no feature HttpClient)
  Future<DshFileStat> statWorkspaceFile(String sessionId, String path, {Duration? timeout});
  Future<Uint8List> readFileBytes(String sessionId, String path, {Duration? timeout}); // stats + GET /api/file, exact bytes
  Future<Uint8List> readAbsoluteFileBytes(String absolutePath, {String? version, Duration? timeout});

  Future<DshSession> createSession({String? cwd, String? workspaceId, String? agentPreset});
  DshSession openSession(String sessionId, {DshSessionOptions options = const DshSessionOptions()});
  Future<DshSessionStore> store(String sessionId, {bool activate = true, DshSessionOptions options = const DshSessionOptions(), DshTranscript? transcript});
  Future<void> closeSession(String sessionId);
  Future<void> close();

  /// parse URL → login or stored cookie → verify → connect.
  static Future<DshClient> pair(String input, {
    DshCookie? storedCookie,
    DshHttpClient? httpClient,
    DshMuxOptions muxOptions = const DshMuxOptions(),
  });
}
```

Typical lifecycle:

```dart
final client = await DshClient.pair(pastedUrl);       // login + verify + ready
final cookie = client.cookie;                         // persist in secure storage
final catalog = await client.loadCatalog();           // first paint data
final store = await client.store(sessionId);          // follows + transcript
store.changes.listen((_) => repaint());
await store.prompt(DshPrompt(text: 'hello'));
...
await store.dispose();
await client.close();
```

The feature gateway already holds a `DshClient` (`_requireClient()`); its
`readFileBytes(sessionId, path)` is a one-liner over
`client.readFileBytes(sessionId, path)` — no new accessor and no second
transport implementation. `readAbsoluteFileBytes` exists for a URL/stat the
preview already has (e.g. caching for a WebView).

Resume path: `DshClient.pair(storedUrl, storedCookie: cookie)` (no token in the
URL). A 401/403 anywhere means the stored cookie is stale: ask for a fresh WebUI
URL; never retry a rejected token. `pair()` keeps only the cookie in
`transport` — `client.endpoint.token` is null after pairing.

## 13. v2 stage-1 additions

### 13.1 Context pressure (token ring)

`contextPressure` projection: `{pressureTokens, projectedTokens, contextWindow}`
(protocol sample `{8930, 8943, 1048576}`). Parsed into
`DshContextPressure` and available as `DshSessionProjections.contextPressure`
and `DshTranscript.contextPressure`. It is **absent → null** (old Host, not yet
loaded): render no ring, never derive it from `tokenUsage`. `ratio` is only
computed when `contextWindow > 0`.

### 13.2 Workspace files and `GET /api/file`

- `workspaceFiles/stat {workspaceFileScopeId:<sessionId>, path}` →
  `{absolutePath, version, bytes?}` → `DshFileStat`.
- `GET /api/file?path=<absolutePath>[&v=<version>]` with the API cookie:
  exact bytes, `302` to a versioned cache URL for versioned paths, `403` for a
  directory, `400` for a relative path.
- `DshEndpoint.fileUri(absolutePath, {version})` builds that URL (never string
  concatenate it).
- `DshClient.readFileBytes(sessionId, path)` stats then GETs and returns
  `Uint8List`; `readAbsoluteFileBytes(abs, {version})` is the already-resolved
  form. The 302 is followed locally with the same cookie/authority; the raw
  bytes come from `DshHttpResponse.bodyBytes`.
- Failures: 401 `DshAuthException`; 400/403 `DshFileException`
  (`isRelativePath`/`isDirectoryOrForbidden`); 404 `DshUnsupportedException`;
  5xx `DshTransportException`.

### 13.3 Agent presets

`agentPresets/list` → `{presets:[{id,order,isDefault,name?,description?,broken?}]}`
→ `DshCatalog.listAgentPresets()` (`DshAgentPresetSummary`, sorted by `order`).
A 404 means the capability is absent. The roster is the authority for order,
published copy and activation failures: the four shipped presets publish no
`name`/`description`, a plugin declaration that names itself owns its copy, and
a row with `broken` cannot compose a Session. `load()` reads the roster into
`DshCatalogSnapshot.agentPresets` next to the rest of the first paint.

`agentPresets/select {agentId, agentPreset}` → committed identity string. The
`agentId` is the **session id**. It is valid only while the Session has not
started its first turn; afterwards the Host refuses with
`agent-preset/locked` and the client maps that to a `DshRemoteException`.
`session/create` accepts the same value as `agentPreset`; `session/list`
projections report the recorded one as `agentPreset`.

`pluginInventory/list` also carries the per-preset plugin composition already
parsed in `DshPluginInventory.agentPresets`; the gateway merges that with the
roster so the settings tab can show the declared plugins for each roster row.

### 13.4 Terminal stage 1 (read-only attach)

Wire (the `agentId` is the **session id**; 0.2.2 has no separate agent id):

| endpoint | kind | args | value |
|---|---|---|---|
| `terminal/shells` | unary | `{agentId}` | `[{path,args,name}]` |
| `terminal/environment` | unary | `{agentId}` | `{cwd,maxInputBytes,maxBufferedBytes,maxCols,maxRows,scrollback}` |
| `terminal/create` | unary | `{agentId, request:{id, cols, rows, shellPath?}}` | `WebTerminalInfo` (client-chosen `id` is echoed) |
| `terminal/list` | unary | `{sessionId}` | `[WebTerminalInfo]` |
| `terminal/attach` | mux stream | `{agentId, id}` | `snapshot`, then ordered `output`/`state`/`ack` |
| `terminal/close` | unary | `{agentId, id}` | void |

Frames (typed, tolerant; code-read names, verified live by the recon slice):
`DshTerminalSnapshotFrame{sequence, screen, info, writable, inputWindow}`,
`DshTerminalOutputFrame{sequence, data}`,
`DshTerminalStateFrame{info, writable}`,
`DshTerminalAckFrame{sequence, refusal?}` (`read-only`/`not-running`), plus
`DshTerminalUnknownFrame` preserved raw.

Uplink (the only client→host stream in 0.2.2): `DshStream.sendItem(value)` sends
`{type:'item', streamId, value}`; `DshTerminalAttachment.write({sequence,data})`
and `.resize({sequence,cols,rows})` wrap it with
`{type:'write',sequence,data}` / `{type:'resize',sequence,cols,rows}`.
Sequences are consecutive from 1 per attachment; the Host answers with `ack`
and refuses with `read-only`/`not-running`. Stage 1 is **read-only**: the panel
attaches and renders frames but does not enable input until the terminal slice
opts into write/resize; `snapshot.writable`/`state.writable` are the truth.

`DshTerminalAttachment` = `{id, stream, isClosed, frames:
Stream<DshTerminalFrame>, write(...), resize(...), close()}`. The terminal UI
slice consumes exactly these names; keep them stable.

## 14. What is deliberately not in this client

- No DSH data persistence/cache/offline mode; the only stored secret is the
  cookie the feature layer keeps.
- No `/connect` v2 operator login: the v1 browser cookie covers `/api`, the mux
  **and** the WebView SPA (needed to host plugin pages).
- No terminal/PTY, schedules/goals, account sign-in, speech, plugin market,
  workspace-file editing: out of the brief's scope. Their endpoints remain
  reachable through `DshRpc.call` / `DshCatalog.supports` if a later phase needs
  them — §15 documents the terminal, workspace-file, attachment, command,
  context and schedule/job surfaces capture-verified on 0.2.2-rc.1, beyond the
  stage-1 typed additions in §13.
- No plugin-panel URL: DSH has none; the WebView hosts the full SPA.
- No transcript rendering decisions (markdown, tool widgets): the projection is
  data-only and Flutter-free.

## 15. v2 surface details (terminal, files, attachments, commands, context, jobs)

§13 documents the stage-1 typed additions already in the client: the context
pressure projection, `workspaceFiles/stat` + `GET /api/file` bytes, agent
presets, and the read-only terminal attachment. This section is the full wire
reference behind those additions and the surfaces that still have **no**
typed wrapper: `workspaceFiles/list`/`read`/`readBytes`/`changes`, attachment
uploads and prompt receipts, commands/skills/`@`, schedules and jobs. It adds
no Dart API; §14 (nothing persisted, no operator session, no plugin page) still
holds. Where a typed shape already exists it is named; otherwise call the
method through `DshRpc.call` / `DshMux` with the args shown.

Redacted captures for every shape below live in
[`fixtures-v2/`](fixtures-v2/README.md); the raw captures (with the live
credentials) stay outside the repository. Numbers in the captures are real:
byte sizes, terminal limits, sequence numbers and token counts are what a
client has to size against.

### 15.1 How these surfaces are called

Unary methods use the same envelope as §6:

```json
{"type":"client-request","rpcId":"<uuid>","method":"terminal/list",
 "payload":{"args":{"sessionId":"<sessionId>"}}}
```

Every fixture's `args` object is exactly `payload.args`. Streams are logical
mux streams (§7): send `{"type":"open","streamId","endpoint","payload":{"args"}}`
and consume `item` frames; the envelopes and "generation voids streams" rule
are unchanged.

Identity arguments are all Session ids under different names:

| Argument | Meaning |
| --- | --- |
| `agentId` | a Session the Host resolves to its live Agent; used by methods that run work (terminal, commands, file uploads) |
| `sessionId` | a Session id only, including a cold/archived one (terminal list, schedule targets, session attachment) |
| `workspaceFileScopeId` | a Session **currently attached to a workspace**; the file scope is resolved through it |

Three failure classes need different handling:

- `gateway/lookup-not-found` with
  `details: {endpoint, field: "workspaceFileScopeId"}` is a **precondition
  failure** (the Session has no live workspace attachment), not a missing
  endpoint. Do not retry the same call; re-attach the Session or fall back to
  a file UI that says "workspace unavailable".
- HTTP 404 on `POST /api/<method>` means the endpoint is absent from this Host
  (`DshUnsupportedException`); feature-detect that way, never with a version
  string (§1 rule 8).
- A business `ok:false` is a `DshRemoteException`; the per-surface code tables
  below say which codes a UI must handle.

Capability flags a future slice should cache per Host: terminal, workspace
files, file uploads, commands/skills, schedules, jobs. All six were present in
the captured Host; a profile without a plugin answers 404 for that namespace.

### 15.2 Terminal

Browser terminals are **Session-scoped, caller-minted identities**. The Host
allocates a real shell process in the Session's execution environment, keeps
it alive across attachment loss, and exposes only the bounded screen + ordered
output as frames. Nothing about the terminal is persisted client-side. The
typed `DshTerminalAttachment` / `DshTerminal*Frame` names and the stage-1
read-only UI contract live in §13.4; the wire detail below covers the rest
(input pacing, retain, concurrent writers, exit and identity rules).

Methods (all unary except `attach` / `retain`):

| Method | Args | Value |
| --- | --- | --- |
| `terminal/environment` | `{agentId}` | `TerminalEnvironment` |
| `terminal/shells` | `{agentId}` | `TerminalShell[]` |
| `terminal/create` | `{agentId, request}` | `WebTerminalInfo` |
| `terminal/list` | `{sessionId}` | `WebTerminalInfo[]` |
| `terminal/attach` | `{agentId, id}` | stream of `TerminalFrame`, uplink `TerminalInput` |
| `terminal/retain` | `{sessionId, id}` | stream of `TerminalRetentionFrame`, no uplink |
| `terminal/rename` | `{agentId, id, title}` | `void` |
| `terminal/close` | `{agentId, id}` | `void` |

```ts
interface TerminalEnvironment {
  cwd: string;                // Session working directory, not validated
  maxInputBytes: number;      // one write frame ceiling (65536 captured)
  maxBufferedBytes: number;   // unacknowledged input retained by the Host (2097152)
  maxCols: number;            // 500
  maxRows: number;            // 200
  scrollback: number;         // bounded screen lines (1000)
}
type TerminalShell = { path: string; args: readonly string[]; name: string };
interface WebTerminalInfo {
  id: WebTerminalId;          // the caller-minted id
  title: string;              // display title, changed by terminal/rename
  shell: TerminalShell;       // the process actually running
  cwd: string;                // initial directory; the shell may cd away
  cols: number; rows: number;
  state: 'running' | 'exited' | 'failed';
  exitCode: number | null;
  error?: string;             // failure detail for state:'failed'
}
```

`terminal/create` request:

```json
{"id":"<caller-minted id>","cols":80,"rows":24,"shellPath":"<one path from terminal/shells, optional>"}
```

Rules that matter to the client:

1. **Mint a fresh id per terminal tab.** The id is caller-chosen,
   `[A-Za-z0-9_-]{1,128}`, and identity is `(sessionId, id)`: two Sessions may
   each hold the same id independently (verified; they are separate processes
   and separate streams). Never derive the id from a title or a shared counter.
2. **Create is idempotent for an open identity.** A second create with the
   same id returns the existing `WebTerminalInfo` and ignores the new
   dimensions. A **closed** identity is refused with
   `terminal/unavailable` "Terminal was closed in this Session"; recreation
   requires a new id. An exited but not closed terminal is still listed and
   can be attached read-only until closed.
3. **Dimensions** must satisfy `2 <= cols <= maxCols`, `1 <= rows <= maxRows`;
   an id must match `[A-Za-z0-9_-]{1,128}`. In 0.2.2 both failures reach the
   client as `gateway/internal` with `"Terminal dimensions exceed the configured
   limits"` / `"Invalid terminal identity"` — guard them in the UI rather than
   relying on a typed error.
4. `terminal/list` does not activate the Session; it returns retained
   identities for the Session even when its Agent is cold. Use it to restore
   right-rail tabs after a client restart.
5. `terminal/attach` must be opened with `agentId`; `terminal/retain` with
   `sessionId`. Both take `{agentId|sessionId, id}` only.

#### Attach frame vocabulary

Every attachment begins with a complete, bounded screen (so a reconnect never
replays history):

```json
{"type":"snapshot","sequence":1,"screen":"\u001b[32;1mdsh@<host>\u001b[0m:~/workspace$ ",
 "info":{"id":"<terminalId>","title":"bash","shell":{"path":"/bin/bash","name":"bash","args":["-i"]},
         "cwd":"<workspace>","cols":80,"rows":24,"state":"running","exitCode":null},
 "writable":true,
 "inputWindow":{"maxBytes":262144,"frameOverheadBytes":49}}
```

Then the stream carries:

| Frame | Fields | Meaning |
| --- | --- | --- |
| `output` | `sequence`, `data` (ANSI text) | next screen output; sequences increase by 1 from 1 |
| `state` | `info`, `writable` | title/dimensions/state changed (resize applied, exit, input control moved) |
| `ack` | `sequence`, `refusal?` | input frame `sequence` accepted (or refused `'read-only'`/`'not-running'`) |
| `retained` | -- | only on `terminal/retain`: physical window hold acknowledged |

Observations from the captures that shape the client loop:

- **Downlink sequence is one output cursor per terminal**, shared by every
  attachment: a snapshot carries the cursor's current value (the captured
  re-attach after `exit 3` got `sequence:3`), later `output` frames continue
  from it, and two attachments to the same terminal receive the same output
  frames with the same numbers. Do not assume a stream starts at 1, and do not
  merge the numbers across terminals.
- **Uplink sequence is per attachment and consecutive from 1** (`write` and
  `resize` share the counter). A new attachment restarts it at 1; nothing is
  replayed. The Host acks each number; re-sending an old number after a detach
  is a new input, not a retry.
- **`ack` may arrive before the output it produces** (the captured write
  produced `ack` then `output`/resize `state`). Treat `ack` as
  "the Host has the bytes", never as "the screen shows the result".
- **`inputWindow`** is the carrier's encoded-frame budget for the uplink
  (262144 bytes, 49 bytes of frame overhead in the capture). The client must
  pace writes: encode `write` frames so a frame stays under
  `maxBytes - frameOverheadBytes`, and stop when unacknowledged bytes reach the
  window. It is absent when the carrier has no inbox limit.
- **Output is not replayed on a new attachment**: the snapshot is the whole
  state. A client may re-open `terminal/attach` at any time to get a fresh
  snapshot; it should reset the emulator to it rather than append.

#### Detach, retain, and control

- Closing the mux stream (or losing the socket) detaches without killing the
  process. Input is never replayed after a detach; unsent input is dropped.
- `terminal/retain` is the **second-window** path: it acknowledges retention
  with `{type:'retained'}` and keeps the physical window open for a Session
  without taking the screen or input, so an inactive layout can hold the
  terminal. It has no uplink frames.
- **Two attachments may render the same terminal.** Captured behavior: both
  snapshots say `writable:true`; the Host gives input control to the writer and
  immediately revokes the other with a `state` frame carrying `writable:false`.
  A subsequent write from the revoked attachment was answered with
  `ack {sequence:1, refusal:'read-only'}`. The client should render `writable`
  from the latest `state`, disable its input line, and re-check on focus.
- `terminal/close` kills the process range and poisons the id. Repeated closes
  succeed. Closing is the only way to reclaim a terminal; otherwise it lives
  for the Host lifetime (with an unattended timeout on the Host side).

#### Process exit

Captured `exit 3`:

```json
{"type":"state","info":{"id":"<terminalId>","title":"bash","shell":{"path":"/bin/bash","name":"bash","args":["-i"]},
 "cwd":"<workspace>","cols":80,"rows":24,"state":"exited","exitCode":3},
 "writable":false}
```

The attach stream **stays open** after this frame (no `end` follows); output
stops and only `terminal/close`, `terminal/rename` or a fresh attach on the
exited row remain meaningful. Re-attaching is supported: the captured snapshot
said `state:'exited', exitCode:3, writable:false` and a write attempt drew
another `writable:false` state frame instead of output. The client closes the
identity (or leaves the exited card with a "closed" state) rather than waiting
for a stream end.

Errors:

| Code | Details | UI |
| --- | --- | --- |
| `terminal/unavailable` | `{}` | identity missing or closing; drop the tab or create a new one |
| `terminal/control-unavailable` | `{reason:'read-only' or 'not-running'}` | write/resize arrived when it could not apply; also surface via `ack.refusal` |
| `terminal/limit-reached` | `{limit:number}` | Session terminal quota exhausted; close an old tab first |

UI recipe for Cuplivo (terminal tab in the right rail): create with the tab's
UUID → open `terminal/attach` → feed `screen` into a terminal emulator and
append `output` → send `write` on keystrokes (batching keystrokes into one
write frame is fine, `sequence` per frame) and `resize` on panel resize →
update chrome from `state` → offer close (kill) and rename. Trigger the
`terminal/environment`/`terminal/shells` calls only when a picker is shown;
`terminal/create` alone is enough for the default shell.

### 15.3 Workspace files

`workspaceFiles/*` is the read-only file surface behind the workspace explorer
and the document preview. It is not a filesystem API: it resolves a **Session's
workspace** and speaks paths inside it. `stat` and the `GET /api/file` byte
route already have typed helpers (§13.2: `DshFileStat`,
`DshClient.readFileBytes`, `DshEndpoint.fileUri`); `list`, `read`, `readBytes`
and `changes` are documented here for the next wrapper.

| Method | Args | Value |
| --- | --- | --- |
| `workspaceFiles/list` | `{workspaceFileScopeId, path}` | `WorkspaceDirectoryListing` |
| `workspaceFiles/read` | `{workspaceFileScopeId, path, range}` | `WorkspaceFileText` |
| `workspaceFiles/readBytes` | `{workspaceFileScopeId, path, options}` | `WorkspaceFileBytes` (multipart) |
| `workspaceFiles/stat` | `{workspaceFileScopeId, path}` | `WorkspaceFileStat` |
| `workspaceFiles/changes` | `{workspaceFileScopeId, path}` | stream of `{kind:'ready'}` / `{kind:'change',change}` |

**Path rules** (these are the surface's sharpest edge):

- `list` takes a **workspace-relative** path (`"docs"`, `"data"`) or the
  absolute workspace root; `"."` lists the root and echoes `path:""`. `"/"`
  is outside the workspace (`workspace-file/outside-workspace`); the empty
  string is refused earlier with `gateway/bad-request` "path is required".
- `read` / `readBytes` / `stat` accept an **absolute Host path or a
  workspace-relative path** (resolved against the Session workspace; `stat`
  echoes the absolute form the client needs for `GET /api/file`). `readBytes`
  additionally accepts `options.baseFile`, resolving a relative target from
  that file's directory — the document preview uses this to fetch related
  assets.
- A listed child's workspace path is the listing `path` joined with `name` by
  `/` (root listing `""` means just `name`).
- Symlinks resolve for listings/stat, but `read` refuses a symlink; `type` in a
  listing is a resolution fact, not a readability promise.

Value shapes (all sizes real in the fixture):

```ts
interface WorkspaceDirectoryListing {
  path: string;                    // "" for the root
  entries: {name: string; type: 'file'|'directory'|'other'; size?: number}[];
  truncated: boolean;              // entry cap dropped children
}
interface WorkspaceFileStat { absolutePath: string; version: string; bytes?: number }
interface WorkspaceFileText extends WorkspaceFileStat {
  offset: number;                  // first line, 1-based
  text: string;                    // page lines joined by '\n', no trailing terminator
  lines: number;                   // 0 when offset is past the last line
  eof: boolean;                    // page includes the file's last line
}
interface WorkspaceFileBytes extends WorkspaceFileStat {
  offset: number; data: Uint8Array; eof: boolean;
}
type WorkspaceFileChange =
  | {absolutePath: string; version: string}
  | {absolutePath: string; absent: true};
```

- `read` pages by lines: `range.offset` defaults to 1, `range.limit` defaults
  to and may not exceed the Host's `maxLines` (5000). A page past EOF returns
  `{offset, text:"", lines:0, eof:true}` (captured); a page holding one empty
  line is distinguished by `lines:1`.
- `readBytes` reads a byte window (`options.range {offset,length}`) or, with no
  range, the complete file under the Host's `maxFileBytes` cap. It never
  decodes and never rejects binary. Range past EOF returns `data: []` with
  `eof` telling the story.
- `stat` is the freshness primitive: `version` is an opaque token; compare it
  with the one embedded in a resource address/listing to know whether a cached
  preview is stale. Never parse it.
- `changes` starts with `{kind:'ready'}` and then pushes current target
  metadata; a directory consumer relists on every frame because a child can
  change without the directory version changing. A file consumer may ignore a
  frame whose `version` it already has.

#### `readBytes` multipart response

`workspaceFiles/readBytes` is a decoded Remote method: the HTTP 200 body is
`multipart/form-data`, not a plain JSON envelope.

```
content-type: multipart/form-data; boundary=----formdata-undici-…
chunked

--boundary
Content-Disposition: form-data; name="bytes-0"; filename="blob"
Content-Type: application/octet-stream

<raw file bytes>
--boundary
Content-Disposition: form-data; name="metadata"

{"type":"server-response","rpcId":"…","result":{"ok":true,"value":{…}},
 "attachments":[{"path":["data"],"codec":"bytes","part":"bytes-0"}]}
--boundary--
```

The `metadata` part is the usual server-response envelope with:

- top-level `attachments`: one entry per binary field, `{path, codec:'bytes',
  part}` where `path` is the field path inside `value`, `codec` is always
  `bytes`, and `part` is the multipart part name;
- the binary field itself is a **`null` placeholder** in `value` (`data:
  null`), not omitted.

The client joins them: locate each part by name, strip the part headers and the
trailing CRLF, assign the bytes to the field path, and only then parse the value
as `WorkspaceFileBytes`. Extra/missing fields make the body invalid. Because
the response is large, do not route it through a JSON `Map`-only parser; the
transport must expose raw bytes (the current `DshTransport` already does, §5)
and the client must parse the boundary itself.

#### Document-preview kinds (official renderer registry)

The DSH sidebar preview (`dsh-client-ui-sidebar-documentpreview`) registers a
renderer per extension with one of two loading modes: `text-pages` (paged
`workspaceFiles/read`) or `bytes-complete` (whole `workspaceFiles/readBytes`).
Cuplivo should mirror the same mapping instead of sniffing MIME by itself:

| Extensions | Mode | Data source |
| --- | --- | --- |
| (no extension / unknown) | text fallback | paged `workspaceFiles/read` until `eof` |
| code-highlight extensions (the `CODE_HIGHLIGHT_EXTENSIONS` set) | text fallback, highlight | paged `workspaceFiles/read` |
| `md`, `markdown` | markdown render | paged `workspaceFiles/read` |
| `html`, `htm` | sandboxed iframe (`srcdoc`) | complete `workspaceFiles/readBytes` |
| `png`, `jpg`, `jpeg`, `gif`, `webp`, `bmp`, `ico`, `svg` | image; SVG renders its XML source as text | complete `workspaceFiles/readBytes` |
| `pdf` | PDF viewer | complete `workspaceFiles/readBytes` |
| `xlsx`, `xls`, `csv`, `tsv` | spreadsheet | `readBytes`; office formats render to PDF via `officeToPdf/render` (+ `officeToPdf/generation` stream) |

Related file addresses:

- `dsh-resource://file/session/<sessionId>/<workspace-relative path>` and
  `dsh-resource://file/absolute/<absolute path>`. These are **resource
  identities** the UI uses for tabs/links; the bytes still come from the RPCs
  above (or the route below).
- `GET /api/file?path=<absolute path>` (`+ &v=<version>` optional) is the
  authenticated, cookie-scoped HTTP route for **markdown inline images** and
  previews that want a URL. It answers `302` to the versioned URL, which
  returns the bytes with `cache-control: private, max-age=31536000, immutable`,
  `content-security-policy: sandbox; default-src 'none'`,
  `x-content-type-options: nosniff`. The redirect pins `v`, so the second
  response is safely cacheable; the first is `no-store`.
- There is **no write/delete API** on this namespace in 0.2.2: it is
  `list/read/readBytes/stat/changes` only. Editing is a Host-side (Desktop)
  capability (`session/openWorkspacePath`, `session/canOpenWorkspacePath`) and
  is not usable for a remote Cuplivo client.

UI recipe: tree = `list` per expanded directory (children paths joined),
infinite text = successive `read` pages, preview freshness = `stat.version`
plus `changes`, image/PDF = `readBytes` and render natively, HTML = WebView
with `srcdoc`/data URL (same sandboxed content policy), markdown inline images
= `/api/file` URL with the cookie sent as an explicit `cookie` header (the
native client holds the value; a WebView can share it, an `<img>` in a page
cannot). Cache nothing on disk; the client is a viewer.

### 15.4 Attachments and uploads

Uploads are staged first, then referenced from a prompt (or a command
invocation). The bytes live on the Host; the receipt is the only handle the
client carries between the two calls, and the client stores neither.

**HTTP route** (preferred, raw bytes, same cookie):

```
POST /api/session/uploadFileBinary?sessionId=<id>&name=<display name>&mediaType=<mime?>
content-type: application/octet-stream
<raw file bytes>
```

- Without `mediaType`: a file upload, response
  `{ok:true, value:{receiptId, file:{attachmentId, name, bytes}}}`.
- With `mediaType`: an image upload, response
  `{ok:true, value:{receiptId, image:{attachmentId:'sha256:…', mediaType,
  width, height, bytes, name}}}`. The Host normalizes/validates the image; the
  receipt's image is what enters the message.
- Carrier statuses: `405` (method not POST), `415` (content-type is not
  `application/octet-stream`), `400` (missing `sessionId`). Business failures
  are HTTP 200 `{ok:false, error:{code,message,details}}` — the same
  `DshRemoteException` taxonomy as RPC, even though the route is not wrapped
  in the client-request envelope.
- `name` is a display name only (sanitized Host-side), never a path.
- Image acceptance limits are a projection (`imageLimits`: `maxImageBytes`,
  `maxImagesPerMessage`, `maxMessageImageBytes`, `maxImagePixels`,
  `maxImageDimension`, `mediaTypes[]`). Read it before the picker so the UI can
  filter; the upload rejects out-of-policy bytes with a business error.

**RPC fallback** (canonical base64; use when a raw-body carrier is awkward):
`fileUploads/upload {agentId, request:{data:<canonical base64>, name?}}` →
`FileUploadValue {receiptId, file}`. Image data can also be sent inline in a
prompt part, so the image route/fallback is only needed to share/retry a
receipt or to reuse the upload for several prompts.

**Prompt content parts** (`session/prompt`, §10 already covers the request):

```json
{"type":"text","text":"…"}
{"type":"image","mediaType":"image/png","data":"<canonical base64>","name?":"…"}
{"type":"file","receiptId":"<receipt from the upload>"}
```

- A receipt is accepted only inside the Agent scope that minted it; send it to
  the same Session. An image-upload receipt becomes that image in the message;
  a file-upload receipt becomes a file block.
- Prompt admission errors map to `session/attachment-invalid`
  (`details.reason: 'corrupt' | 'unsupported' | 'unavailable'`) and are
  retryable only by uploading again.
- The transcript then carries durable references, not receipts:

```json
{"type":"user/message","data":{"source":{"kind":"user"},"content":[
  {"type":"text","text":"…"},
  {"type":"image","attachment":{"attachmentId":"sha256:…","mediaType":"image/png",
                                "width":8,"height":8,"bytes":189,"name":"pixel.png"}},
  {"type":"file","attachment":{"attachmentId":"…","name":"notes.txt","bytes":164}}
]}}
```

- Render the `image` part by fetching bytes with **`session/attachment
  {request:{sessionId, attachment:<the full ImageAttachmentRef>}}`** →
  `{attachment, data:<canonical base64>}`. The Host verifies the content id,
  byte length and dimensions against the reference before returning bytes;
  cache in memory by `attachmentId` (the sha256 is the identity) and drop on
  `close()`. Never assume a URL.
- Render the `file` part as a file card (name + bytes); there is no inline
  body to render unless a viewer explicitly reads it from the workspace.
- Injected user messages (`source.kind` `runtime-context` / `time-context`)
  are not attachments and must not render as human prompts; only
  `source.kind === 'user'` is the human's message.

UI recipe: the composer's paperclip/attachment button uploads through the
route (stream the bytes, show progress, no local copy), holds receipts until
the prompt is accepted, then discards them; the transcript renders image
thumbnails from `session/attachment` (lazy, memory-cached) and file cards;
retry on `session/attachment-invalid` re-uploads.

### 15.5 Composer plus menu, commands, skills, `@` references

The `+` button next to the composer opens the **same candidate popup** as
typing `/`. That popup is the joined, ordered set of the `/` trigger sources:

1. **指令 / Commands** (`source` name `command`): the Host's roster from
   `commands/list {agentId}` first, then client contributions. This build has
   exactly one client contribution: the `/file` row (label 添加文件, "Add
   file"), which is an **action** that opens the native file picker — not a
   slash command that sends text.
2. **技能 / Skills** (`source` name `skill`, `order:2`): `skills/list
   {request:{sessionId}}`; picking a skill inserts plain text `/<name> ` into
   the composer (the model then invokes it through its tool, the Host does not
   run it as a command).

There are **no MCP rows** in this menu in this build, and attachments do not
enter the prompt through the plus menu: files/images come from the picker,
drag-and-drop or paste, and are attached to the message directly.

Roster shapes:

```ts
interface CommandDescriptor {
  definitionId?: string;      // stable plugin identity for catalogue behavior
  name: string;               // lowercase, without the leading slash
  description: string;
  input?: {hint: string; attachments?: boolean};   // free-form input the command accepts
}
interface SkillDescriptor {   // skills/list response entries
  path?: string; name: string; description: string; whenToUse?: string; modelInvocable: boolean;
}
```

Captured Host roster (all six are real in `fixtures-v2/commands.json`):
`compact`, `export`, `feedback`, `goal`, `permission`, `plan` — with `input`
hints on `feedback`, `goal`, `permission`, `plan`, and `attachments:true` on
`goal`/`plan`. The captured `skills/list` was empty.

**Availability rules** (client behavior, but they decide the UX):

- A **leading** `/` offers the full roster (commands + skills).
- An **inline** `/` (after text) offers only commands **without** an `input`
  hint — a command that takes free-form input cannot be recognized mid-line.
- `commands/change` invalidates the cached roster; a Session preset change
  (`agent-preset/selected`) resets it. Re-fetch lazily next time the popup
  opens.
- The popup should filter by prefix and show `description` + `hint`; the plus
  button simply opens it unfiltered.

**Executing a slash line**:

```json
{"type":"client-request","method":"commands/execute",
 "payload":{"args":{"agentId":"<sessionId>","line":"/permission workspace-write","submittedAttachments":[]}}}
```

→ `{commandId, result:{kind:'success', text?} | {kind:'error', text}}`.
The Dart wrapper is `DshSession.executeCommand(String line)`; it is the only
`commands/execute` path in the client (`setPermission(preset)` delegates to it
with `/permission <preset>`, and the catalog only lists the roster). The plus
menu's compact action is therefore just the catalog-advertised line, e.g.
`session.executeCommand('/compact')`; no separate compact RPC exists.
`submittedAttachments` accepts `{type:'image', mediaType, data, name?}` or
`{type:'file', receiptId}`; only commands declaring `input.attachments:true`
can receive them, and a capable composer refuses the submission otherwise.

Two answers need different handling:

- A real command returns `CommandExecution` (`commandId` + `result`); render
  `result.text` in a system/notice row, or let the command's own lifecycle
  events (`command/run`/`command/done`) provide richer presentation.
- **Unknown command line** returns `{result:{ok:true}}` with **no value**
  (captured). That means "the Host did not claim this line": the composer must
  then send it as an ordinary prompt, not show an error.

**`@` references** are a separate trigger (`source` name `reference`) that
merges:

- `fileReferences/list {agentId, query}` → workspace-relative candidates. A
  directory candidate carries `kind:'directory'`; picking a directory drills
  into it and the inserted token is quoted (`@"dir with space/"`) so paths can
  contain spaces.
- `sessionReferenceResolver/candidates` (session ids / subagent names) for
  `@session` mentions.

Picking a candidate inserts **plain text** `@path` into the composer. It is
not an attachment: the transcript renders it as a clickable reference chip
(opening the file/workspace or the session), and the model reads the file
itself through its tools. The client neither uploads nor inlines the target.

UI recipe for Cuplivo: one composer overlay with the trigger `+`/`/`/`@`;
cache `commands/list` + `skills/list` + `fileReferences/list` per Session in
memory; run `/file` locally (open picker); send every other slash line to
`commands/execute` and treat undefined as text; insert skills/`@` as text;
never persist the rosters.

### 15.6 Context usage ring

The context ring is fed by three session projections (same projection
machinery as §11; last-wins, not atomic). §13.1 already parses
`contextPressure` into `DshContextPressure` and exposes it on the session and
transcript; this is the remaining ring detail.

```json
{"tokenUsage":   {"uncachedInputTokens":486,"outputTokens":2,"cacheReadTokens":8448,"cacheWriteTokens":0},
 "contextPressure": {"pressureTokens":8934,"projectedTokens":8947,"contextWindow":1048576},
 "contextBreakdown": {"systemTokens":1452,"toolsTokens":7476,"messageTokens":286}}
```

- **Occupancy** = `contextPressure.projectedTokens ?? contextPressure.pressureTokens`.
  `projectedTokens` is the estimate after the pending request's projected
  growth; `pressureTokens` is the current context size. Both are absent until
  the provider has reported usage for a turn.
- **Percent** = `min(100, round(usedTokens / contextWindow * 100))` (the ring's
  own rule; `contextWindow` is the active model's window and can change with
  the model selection).
- **Panel rows** = `contextBreakdown` (`systemTokens`, `toolsTokens`,
  `messageTokens`). These are heuristic composition figures, not a partition:
  they do not sum to `projectedTokens`.
- `tokenUsage` does **not** feed the ring; it feeds the chat's separate usage
  pill/statistics panel. Billed input = `uncachedInputTokens + cacheReadTokens
  + cacheWriteTokens`; the pill's displayed total is billed input +
  `outputTokens`, and the cache-hit percentage is
  `cacheReadTokens / billedInput`. The ring's headline is only the percent from
  `contextPressure`; the breakdown bar normalizes the three composition rows to
  their own sum (`systemTokens + toolsTokens + messageTokens`).
- Per-attempt usage also rides `assistant-stream` chunks
  (`usage {inputTokens, outputTokens, cacheReadTokens, cacheWriteTokens,
  totalTokens}`) and `assistant/message.data.usage`; those are per step (the
  turn usage panel) and must not overwrite the session projection.
- `request/context` events carry `{provider, model, contextWindow}`; use them to
  update the window label when the model switches.
- `session/projections` is the on-demand read; `session/control` /
  `session/follow` projection frames push updates. Summary projections exclude
  the full `contextBreakdown` set, so fetch the projection when opening the
  panel rather than assuming the transcript summary carries it.
- `imageLimits` is the fourth composer-facing projection (boot-time constant):
  validate picks before upload.

UI recipe: ring as a circular indicator with percent; tap opens the breakdown
panel (system/tools/messages, token usage, window, model); hide the ring when
either the used number or the window is absent; clamp at 100% and show
"context full" when the Host starts compacting (the `compact` command is a
separate action).

### 15.7 Automations and jobs

These two are Host surfaces for long-running work. They are documented for
completeness; the remote-control slice can ship without them, and neither has
a typed wrapper in this client.

#### `schedule` (自动化任务)

All unary `POST /api/schedule/<method>` (the request-shaped methods take a nested `request` object):

| Method | Args | Value |
| --- | --- | --- |
| `schedule/catalog` | `{}` | `ScheduleCatalogEntry[]` (every task) |
| `schedule/list` | `{request:{active?, limit?, offset?}}` | `{items, shown, total, limit, offset}` (paged, active first) |
| `schedule/view` | `{request:{id}}` | entry, or `{id, code:'schedule_not_found'}` |
| `schedule/create` | `{request:{title, prompt, timing, target?}}` | entry |
| `schedule/edit` | `{request:{id, action, patch?, expectedUpdatedAt?}}` | entry / `{id, deleted:true}` / not-found / conflict |
| `schedule/run` | `{request:{id}}` | entry / not-found / `{id, code:'schedule_execution_pending'}` |
| `schedule/history` | `{request:{id, limit, before?}}` | `{id, records, earlierRecordsUnavailable, …}` (newest first, limit 1–100) |
| `schedule/deleteInactive` | `{}` | `{deleted: number}` |
| `schedule/deliveryLimits` | `{}` | `{newSessionIntervalSeconds}` |

`ScheduleCatalogEntry` = the timing record (`kind` `after`/`at`/`every`/
`daily`/`weekly`/`cron`/`rrule` with its timing fields, `title`, `prompt`,
`scheduledAt`) plus:

```ts
{ target: {kind:'session',sessionId} | {kind:'new_once',sessionId,create} | {kind:'new',create},
  involvedSessionIds: string[], status: 'active'|'paused'|'ended',
  createdAt?, updatedAt?, executionActive?, deliveryFloorEndsAt?, lastDelivery?
}
```

Rules:

- `create` needs a non-empty `title` (≤120 chars after trim), non-empty
  `prompt`, authoritative `timing` with at least one **future occurrence**, and
  optional `target` (omit ⇒ one Session created at first delivery and reused).
- **Request timing is snake_case; stored records are camelCase.** The request
  vocabulary is `{kind:'after', after_seconds}` / `{kind:'at', at}` (an RFC 3339
  string or `{date,time,time_zone}`) / `{kind:'every', every_seconds}` /
  `{kind:'daily', daily:{time, time_zone}}` /
  `{kind:'weekly', weekly:{time, time_zone, weekdays:[1..7]}}` /
  `{kind:'cron', cron:{expression, time_zone}}` / `{kind:'rrule', rrule}`. The
  stored `ScheduleRecord` it comes back as uses `afterSeconds`/`everySeconds`,
  `daily.time`/`daily.timeZone`, `weekly.weekdays`,
  `cron.expression`/`cron.timeZone`, `rrule`, plus the computed `scheduledAt`
  (next occurrence while active, final accepted occurrence when ended).
- Targets: request `{kind:'session', sessionId}` (existing, not a delegated
  child), `{kind:'new_once', create?}` (Host reserves the Session id and the
  record then shows `kind:'session'`), or `{kind:'new', create?}` (fresh Session
  each delivery). Creating against an archived/child Session reports
  `schedule/target-archived` or `schedule/input-invalid` (`subagent_session`).
- **`edit` requires `action`** (`'update'` or `'delete'`); omitting it is a
  boundary `gateway/input-invalid`. `patch` must contain at least one field
  (`title`, `prompt`, `timing`, `target`, `active`); `active:false` pauses,
  `active:true` resumes from the first future occurrence.
- `expectedUpdatedAt` is optimistic concurrency: send back the value read; a
  mismatch returns `{code:'schedule_conflict'}` (not an error).
- Business validation failures are `schedule/input-invalid`
  `{details:{code}}` where the code is one of `invalid_prompt`,
  `invalid_selector`, `invalid_rule`, `invalid_time_zone`, `not_future`,
  `time_out_of_range`, `frequency_too_high`, `subagent_session`; a delivery
  targeting an archived Session is `schedule/target-archived {sessionId}`.
- `deleteInactive` only removes **ended** tasks, not paused ones; a paused
  task must be deleted via `edit {action:'delete'}`.
- UI (`dsh-client-ui-schedule`): the 自动化任务 task manager opens as a
  session-header utility and a right-rail tab; the session row and turn cards
  show scheduled follow-ups. Cuplivo should mirror it read-only first (list
  + run + pause/delete), with creation behind a form that computes a future
  timing.

#### `job` (后台任务)

Jobs are Host background processes (shell commands, long tools) owned by a
Session or unowned.

| Stream / method | Args | Frames / value |
| --- | --- | --- |
| `job/list` (stream) | `{request:{sessionId}}` | `{type:'rows', jobs: JobView[]}` |
| `job/follow` (stream) | `{request:{sessionId?, jobId, from?}}` | `opened` → `output` → `status` |
| `job/kill` | `{request:{sessionId, jobId}}` | `{outcome:'requested'|'already-finished'}` |

- **`job/list` is a stream, not a unary call.** Each frame is a **whole-set
  replacement** of the rows the Session can see (its own jobs plus unowned
  jobs), so a reconnect's first frame is the truth. Do not diff/append.
- `JobView` = `{id, kind, label, owner?, status:'running'|'stopping'|
  'completed'|'killed'|'failed', progress?, detail?, startedAt, finishedAt?,
  output:{total, earliest, spillPaths?}, outputLimitBytes?}`.
- `job/follow` opens with `{type:'opened', job, from}`, then coalesced
  `{type:'output', chunks, next, lossy?}` batches, then one
  `{type:'status', job}` once the job settles and its ring drains; the stream
  then closes normally. `from` is an absolute byte offset (resume from a prior
  frame's `next`); `lossy:true` means bytes were evicted before the requested
  offset.
- An unknown job id is refused **on the stream**: the type map declares
  `job/not-found {sessionId, jobId}`, and 0.2.2 actually answered a mux `error`
  frame with `gateway/internal` `"unknown job <id>"` (captured). Treat any
  stream error as "the row is gone" and refresh `job/list`. A kill of a settled
  job is not an error; it returns `already-finished`.
- UI (`dsh-client-ui-jobs`): the 后台任务 header action opens a popover of
  rows with status/progress/detail; selecting a row opens a follow stream and
  renders output chunks (with resume offset); the kill button calls
  `job/kill`. Cuplivo needs this only when it surfaces background tool runs.

### 15.8 Common rules for the v2 slice

1. **No persistence, still.** Receipts, attachment refs, terminal ids, job
   output and schedule entries stay in memory for the Session lifetime; only
   the cookie is persisted, and only by the feature layer.
2. **Generation resets everything.** A mux generation loss voids terminal
   attachments, file watches, job lists and job follows. Re-open them; the
   first frame is a complete snapshot (terminal `snapshot`, file `ready`,
   job `rows`, job `opened`) — never replay from client memory.
3. **Business errors are data.** Match on `code`/`details`, not message text,
   and treat `gateway/lookup-not-found` as a precondition problem.
4. **Feature-detect, don't version-gate.** 404 per endpoint; an unsupported
   namespace hides its panel instead of failing the app.
5. **Numbers stay numbers.** The captures give exact limits (terminal 500×200,
   input window 262144, read page 5000 lines, and 1048576 tokens for the
   captured model's window): size the UI against them, don't hard-code guesses.
6. **Verification contract.** A future slice that wraps a still-untyped
   namespace gets a compile-time DTO, unit tests against the fixtures in
   [`fixtures-v2/`](fixtures-v2/README.md), and only then a UI. Until then,
   `DshRpc.call` with the shapes above is the supported access path.
