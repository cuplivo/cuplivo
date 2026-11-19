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
| `dsh_transport.dart` | `DshCookie`, HTTP/WebSocket carrier (`DshTransport`, `DshHttpTransport`, `DshIoHttpClient`), login, upload, request/asset timeouts |
| `dsh_rpc.dart` | `DshRpc`: `{type:'client-request'…}` envelope, `server-response` decode, error mapping, one retry for idempotent reads, `dshUuidV4()` |
| `dsh_mux.dart` | `DshMux`: `/api/remote.mux` connection, generations, `$events` ready + host requests, logical streams, reconnect backoff, keepalive, disposal |
| `dsh_events.dart` | wire event vocabulary: `DshConnectionState`, session log events, `session/follow` snapshot frames, assistant-stream frames/chunks, host events, approvals/questions, mux frames, workspace updates, `DshSessionUpdate` |
| `dsh_models.dart` | tolerant JSON helpers + domain models: messages/parts/usage, session summaries/state/projections, model catalog, providers, permissions, commands, skills, plugins, settings, account, credentials |
| `dsh_catalog.dart` | typed reads/writes for sessions, workspaces, models, providers, plugins, commands, skills, permission presets, settings, account; live `session/control` + `workspace/follow` watchers; capability probes |
| `dsh_session.dart` | one session handle: `watch()` (snapshot + live events + host requests), prompt (text/images/files), cancel, model/reasoning/permission writes, approvals/questions, history paging, commands/skills, upload, dispose; `DshSessionStore` = handle + `DshTranscript` + change stream for the UI controller |
| `dsh_projection.dart` | `DshTranscript`: folds snapshot + durable events + live assistant frames into ordered renderable items and UI state (no Flutter) |
| `dsh_client.dart` | public entry: `DshClient(endpoint)` → `login`, `useCookie`, `connect`, `loadCatalog`, `createSession`, `openSession`, `close` |

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
  final String body;
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
auto-reopen streams get a fresh opener on the next generation. Pending
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

`dsh_events.dart` exports:

- mux frames: `DshMuxFrame` → `DshMuxItem`, `DshMuxEnd`, `DshMuxError`,
  `DshMuxUnknown`
- follow snapshot: `DshSessionSnapshot { header, cursor, records, hasMore,
  projections, assistantStream }`, `DshAssistantStreamBaseline`,
  `DshAssistantStreamAttempt`
- durable events: `DshSessionEvent` sealed hierarchy with ``seq``, ``time``,
  ``type``, ``surfaceOp``, ``isAppendOrigin``, ``sourceEventSeqs``,
  ``ignorable``, ``raw``: `DshTurnStarted`, `DshTurnEnded` (→ `DshTurnEndReason`
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
  Future<DshCommandExecution> setSessionPermission(String sessionId, String preset); // /permission command
  Future<List<DshCommandDescriptor>> listCommands(String sessionId);
  Future<DshCommandExecution> executeCommand(String sessionId, String line, {List<Map<String, Object?>> submittedAttachments = const []});
  Future<List<DshSkill>> listSkills(String sessionId);

  // settings
  Future<DshSettingsDescription> describeSettings();
  Future<DshSettingsNamespace> updateSettings(String ns, Map<String, Object?> patch, {int? expectedRevision});
  Future<DshSettingsNamespace> replaceSettings(String ns, Map<String, Object?> section, {int? expectedRevision});
  Future<DshSettingsNamespace> mutateSettings(String ns, List<DshSettingsPathOp> ops, {int? expectedRevision});
  Future<void> setDefaultPermissionPreset(String preset); // permission.defaultPreset
  Future<void> setSessionLogUpload(bool enabled);        // session-log-deepseek.enabled

  // plugins / account
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
  Future<DshCommandExecution> setPermission(String preset); // /permission payload
  Future<DshSessionState> currentState();
  Future<DshUploadReceipt> uploadAttachment(Uint8List bytes, {String? name, String? mediaType});
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
  Future<void> start({bool activate = true}); // subscribes watch() and folds all updates
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
  DshDraft? get draft;                     // transient live step
  List<DshChatRow> get rows;
  List<DshApprovalRequest> get pendingApprovals;
  List<DshUserQuestionRequest> get pendingQuestions;
  List<DshApprovalRequest> get decidedApprovals;
  bool get awaitingInput;
  DshUserMessageRow? get firstUserMessage;
}

sealed class DshChatRow { int get seq; }
final class DshUserMessageRow { DshMessage message; String text; images; files; String? requestId; }
final class DshAssistantMessageRow { DshMessage message; int turn, step; DshTokenUsage? usage; bool interrupted; String text, reasoning; }
enum DshToolState { running, succeeded, failed, cancelled }
final class DshToolRow {
  String callId, name, arguments;           // arguments = raw JSON text
  DshToolState state; String? resultText; Object? meta;
  DshApprovalOutcome? approvalOutcome;     // ask/decided audits
  Map<String, Object?>? decodedArguments;
}

class DshDraft {
  String attemptId; int revision, turn, step;
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
  deltas become live tool rows); `attemptId` is authoritative, `revision` is a
  per-frame counter; an `end` frame drops the draft and the durable message
  follows;
- waterfalls become `pendingApprovals`/`pendingQuestions`; `cancel`, settle and
  `approval/decided` remove them; reconnecting keeps them until the Host
  retracts;
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

Resume path: `DshClient.pair(storedUrl, storedCookie: cookie)` (no token in the
URL). A 401/403 anywhere means the stored cookie is stale: ask for a fresh WebUI
URL; never retry a rejected token. `pair()` keeps only the cookie in
`transport` — `client.endpoint.token` is null after pairing.

## 13. What is deliberately not in this client

- No DSH data persistence/cache/offline mode; the only stored secret is the
  cookie the feature layer keeps.
- No `/connect` v2 operator login: the v1 browser cookie covers `/api`, the mux
  **and** the WebView SPA (needed to host plugin pages).
- No terminal/PTY, schedules/goals, account sign-in, speech, plugin market,
  workspace-file editing: out of the brief's scope. Their endpoints remain
  reachable through `DshRpc.call` / `DshCatalog.supports` if a later phase needs
  them.
- No plugin-panel URL: DSH has none; the WebView hosts the full SPA.
- No transcript rendering decisions (markdown, tool widgets): the projection is
  data-only and Flutter-free.
