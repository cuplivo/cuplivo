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
| `dsh_events.dart` | wire event vocabulary: session log events, `session/follow` frames/snapshot, assistant-stream frames/chunks, host events, approvals/questions, mux frames, workspace updates |
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

Behaviour: 10 s TCP/TLS connect, 30 s default request timeout, 120 s for
`llm` discovery/upload; `HttpClient.autoUncompress = true`; no `Origin`,
`Referer`, or `Sec-Fetch-*` headers; `Host` always the endpoint authority;
`WebSocket` opened with `dart:io` (deflate negotiated transparently), client
`pingInterval` 15 s for dead-link detection. `login()` does **not** follow the
303/302 (`followRedirects:false`); it only parses status + `Set-Cookie`.

## 6. Unary RPC (`dsh_rpc.dart`)

```dart
class DshRpc {
  DshRpc(this.transport, {this.timeout = const Duration(seconds: 30)});

  /// Sends `{"type":"client-request","rpcId":uuid,"method":endpoint,
  /// "payload":{"args":args}}`, decodes `server-response`, returns `value`.
  /// idempotent: true retries once on DshTransportException (catalog reads).
  Future<Object?> call(String endpoint, [Map<String, Object?> args = const {}],
      {Duration? timeout, bool idempotent = false});
}

String dshUuidV4(); // rpcIds, streamIds, prompt requestIds
```

Status/envelope mapping: 200+`ok:true`→value (absent→null); 200+`ok:false`→
`DshRemoteException`; 401/403→`DshAuthException`; 404→`DshUnsupportedException`;
405/413/415/400→`DshProtocolException`; 5xx/network/timeout→
`DshTransportException`; wrong `type`/`rpcId`/missing `result`→
`DshProtocolException` (a gateway validation answer echoing
`rpcId:"invalid-request"` is accepted as an error).

## 7. Mux (`dsh_mux.dart`)

```dart
enum DshConnectionState { idle, connecting, connected, reconnecting, unauthorized, closed }

class DshMuxGeneration {
  final int number;     // 1, 2, … per successful ready handshake
  final String clientId; // goes into every $events/result answer
  final String home;
}

class DshMuxOptions {
  const DshMuxOptions({
    this.readyTimeout = const Duration(seconds: 15),
    this.pingInterval = const Duration(seconds: 15),
    this.retryCaps = const [500ms, 1s, 2s, 4s, 8s, 10s],
    this.autoReconnect = true,
    this.maxAttempts,          // null = retry forever
    this.retryDelay,           // test hook; overrides retryCaps
    this.hostRequestGrace = const Duration(seconds: 3),
  });
}

class DshMux {
  DshMux(this.transport, {this.options = const DshMuxOptions(), DshRpc? rpc});

  DshConnectionState get state;
  DshMuxGeneration? get generation;     // null until first ready
  DshException? get lastError;
  Stream<DshConnectionState> get states; // broadcast
  Stream<DshHostEvent> get hostEvents;   // deduped, ready not included
  List<DshHostRequest> get pendingRequests; // approvals/questions still awaiting an answer

  /// Resolves with the first ready generation; starts the socket if needed.
  Future<DshMuxGeneration> ready;

  /// Open one logical stream. Waits for the first generation. With
  /// autoReopen:true (default) the same [DshStream] continues across
  /// reconnects — its baseline is re-delivered by the Host, so consumers must
  /// treat a new baseline as a full replacement. With false, the stream fails
  /// with DshTransportException and the caller reopens.
  Future<DshStream> open(String endpoint, [Map<String, Object?> args = const {}],
      {bool autoReopen = true});

  /// Answer an approval/question waterfall through `$events/result` using the
  /// current generation's clientId. Retries once when the Host reports a stale
  /// client (a reconnect happened mid-answer).
  Future<void> answerHostRequest(String eventId, Map<String, Object?> outcome);

  /// Manual reconnect after `unauthorized`/`maxAttempts` exhaustion.
  Future<void> reconnect();
  Future<void> close();
}

class DshStream {
  String get id;
  String get endpoint;
  Stream<Object?> get items;  // decoded `value` of each item frame; errors are DshRemoteException
  bool get isClosed;
  Future<void> cancel();      // client→host cancel (mandatory cleanup)
}
```

Frame protocol implemented exactly as captured (§3.2 of `protocol.md`):
`open`/`item`/`end`/`cancel` uplink; `item`/`end`/`error` downlink. The mux opens
`$events` first on every generation, waits for `{type:'ready'}`, and only then
considers the generation live. Server `error` frames close that logical stream
with `DshRemoteException`. `pendingRequests` are keyed by `eventId`; a new
generation keeps prior pendings for `hostRequestGrace` (Host redelivers them),
then retracts the ones that did not reappear; a `cancel` frame retracts one
immediately.

## 8. Wire events and models (`dsh_events.dart`, `dsh_models.dart`)

`dsh_models.dart` exports tolerant JSON helpers (all public, reused by the
feature layer where it parses raw plugin JSON):
`jsonMap`, `jsonList`, `jsonString`, `jsonInt`, `jsonBool`, `jsonEpochMs`,
`jsonStringList`, `tryDecodeJson`.

Models actually needed by the feature layer (all immutable, all keep `raw` JSON
where forward compatibility matters):

- messages: `DshPart` (`DshTextPart`, `DshReasoningPart`, `DshImagePart`,
  `DshFilePart`, `DshToolCallPart`, `DshUnknownPart`), `DshMessage`,
  `DshImageAttachment`, `DshFileAttachment`, `DshTokenUsage`, `DshLlmFailure`
- sessions: `DshSessionSummary` (title/model/tokenUsage/blank/running/cwd/
  workspace-relevant projections), `DshSessionCreated`, `DshSessionHeader`,
  `DshSessionState`, `DshQueuedItem`, `DshSessionProjections` (typed getters +
  raw `values`), `DshProjectionHints`, `DshHistoryPage`
- models: `DshModelSelection`, `DshReasoningEffort`, `DshReasoningInfo`,
  `DshModelInfo`, `DshProviderGroup`, `DshModelCatalog`, `DshModelCatalogFailure`
- providers: `DshProviderInfo`, `DshConfigurableProvider`
- permissions: `DshPermissionPreset`, `DshPermissionPresetCatalog`
- workspaces: `DshWorkspace`, `DshWorkspaceBaseline`
- commands/skills: `DshCommandDescriptor`, `DshCommandResult`,
  `DshCommandExecution`, `DshSkill`
- plugins: `DshLocalizedText`, `DshPluginInventory`, `DshPluginInventoryEntry`,
  `DshAgentPresetPluginGroup`, `DshPresetPluginRow`, `DshPluginBundleInfo`,
  `DshPluginInfo`, `DshPluginChangeResult`
- settings/account: `DshSettingsDescription`, `DshSettingsNamespace`,
  `DshSettingsSecret`, `DshSettingsPathOp`, `DshAccountState`,
  `DshCredentialInfo`

`dsh_events.dart` exports:

- `DshSessionSnapshot { header, cursor, records, hasMore, projections, assistantStream }`
- `DshSessionEvent` sealed hierarchy for the event catalogue an UI renders:
  `turn/start`, `turn/end`, `step/start`, `step/end`, `user/message`,
  `assistant/message`, `assistant/attempt`, `tool/call`, `tool/result`,
  `session/title`, `model/selection`, `permission/preset`, `sandbox/mode`,
  `approval/policy`, `approval/asked`, `approval/decided`, `command/run`,
  `command/done`, `agent/inbox/spliced`, `llm/retry`, `session/error`,
  `working-directory/change`, plus `DshUnknownSessionEvent` (kept, not rendered).
  Every event exposes `seq`, `time`, `type`, `surfaceOp`, `sourceEventSeqs`,
  `ignorable`, `raw`.
- live assistant stream: `DshAssistantStreamFrame` (`start`/`chunk`/`end`) and
  `DshStreamChunk` (`block-start`, `text-delta`, `reasoning-delta`,
  `tool-call-delta`, `block-end`, `usage`, `finish`), with `revision`/`index`.
  `DshAssistantStreamStart`, `DshAssistantStreamEnd`, `DshAssistantStreamBaseline`.
- host events: `DshHostReady`, `DshHostEmit` (+ typed convenience subclasses for
  `api-session/added|removed|status|activity|error`, `commands/change`,
  `settings/document-updated`, `llm/models-updated`, `permission-presets/
  catalog-changed`, `plugin-manager/*`, `schedule/changed`, … all also readable
  as generic emit), `DshHostWaterfall`, `DshHostRequestCancelled`.
- requests: `DshHostRequest` sealed → `DshApprovalRequest` (eventId, sessionId,
  toolName, callId, reason, displayReason), `DshUserQuestionRequest` (eventId,
  sessionId, questions, wait), `DshUserQuestion`, `DshQuestionOption`,
  `DshQuestionAnswer`, `DshApprovalDecision` (`allowOnce('allowed-once')`,
  `reject('rejected')`, `pass`/delegate via `next`), `DshApprovalOutcome`.
- mux frames: `DshMuxFrame` (`DshMuxItem`, `DshMuxEnd`, `DshMuxError`,
  `DshMuxUnknown`) — used by tests and diagnostics.
- workspace updates: `DshWorkspaceUpdate` sealed (`baseline`, `replace`,
  `upsert`, `remove`, `order`, `archived`, `pinned`).

## 9. Catalog (`dsh_catalog.dart`)

```dart
class DshCatalogSnapshot {
  final List<DshSessionSummary> sessions;          // newest first
  final List<DshWorkspace> workspaces;
  final List<String> archivedSessionIds;
  final List<String> pinnedSessionIds;
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
  final Map<String, bool> known;     // endpoint -> present
  bool supports(String endpoint);    // unknown endpoints: false until probed
}

class DshCatalog {
  DshCatalog(DshRpc rpc, DshMux mux);
  final DshCapabilities capabilities;

  Future<DshCatalogSnapshot> load({bool includePlugins = true, bool includeSettings = true, bool includeAccount = true});

  // sessions
  Future<List<DshSessionSummary>> listSessions();
  Future<DshSessionCreated> createSession({String? cwd, String? workspaceId, String? agentPreset, String? sessionId});
  Future<String> renameSession(String sessionId, String title);
  Future<String> forkSession(String sessionId, {int? atSeq, bool allowMigration = false});
  Future<DshSessionState> sessionState(String sessionId);
  Future<DshSessionProjections?> sessionProjections(String sessionId);

  // workspaces (list has no unary endpoint: it is the follow baseline)
  Future<DshWorkspaceBaseline> loadWorkspaces();
  Stream<DshWorkspaceUpdate> watchWorkspaces();      // baseline + increments, auto-reopen
  Future<DshWorkspace> createWorkspace(String path);
  Future<DshWorkspace> renameWorkspace(String workspaceId, String title);
  Future<void> deleteWorkspace(String workspaceId);
  Future<List<String>> reorderWorkspaces(String workspaceId, {String? beforeWorkspaceId});
  Future<List<String>> reorderWorkspaceSessions(String workspaceId, String sessionId, {String? beforeSessionId});
  Future<DshWorkspace?> initializeDefaultWorkspace();
  Future<List<String>> archiveSession(String sessionId, {bool? stopActivity});
  Future<List<String>> unarchiveSession(String sessionId);
  Future<List<String>> pinSession(String sessionId, {required bool pinned});

  // models / providers
  Future<DshModelCatalog> loadModelCatalog();
  Future<DshModelSelection> selectModel(String sessionId, DshModelSelection selection);
  Future<void> initializeDefaultModel();
  Future<List<DshProviderInfo>> listProviders();
  Future<List<DshConfigurableProvider>> listConfigurableProviders();
  Future<List<DshDiscoveredModel>> discoverModels(String settingsNs, DshModelDiscoveryRequest request);
  Future<Map<String, DshCredentialInfo>> describeCredentials(List<String> refs);
  Future<void> setCredential(String ref, String value);
  Future<void> unsetCredential(String ref);

  // permissions
  Future<DshPermissionPresetCatalog> loadPermissionPresets();
  Future<DshCommandExecution> setSessionPermission(String sessionId, String preset);

  // settings
  Future<DshSettingsDescription> describeSettings();
  Future<DshSettingsNamespace> updateSettings(String ns, Map<String, Object?> patch, {int? expectedRevision});
  Future<DshSettingsNamespace> mutateSettings(String ns, List<DshSettingsPathOp> ops, {int? expectedRevision});
  Future<DshSettingsNamespace> replaceSettings(String ns, Map<String, Object?> section, {int? expectedRevision});
  /// Convenience for the two native general settings.
  Future<void> setDefaultPermissionPreset(String preset);
  Future<void> setSessionLogUpload(bool enabled);

  // commands / skills / plugins / account
  Future<List<DshCommandDescriptor>> listCommands(String sessionId);
  Future<DshCommandExecution> executeCommand(String sessionId, String line, {List<Map<String, Object?>> submittedAttachments = const []});
  Future<List<DshSkill>> listSkills(String sessionId);
  Future<DshPluginInventory> loadPluginInventory();
  Future<List<DshPluginBundleInfo>> listPluginBundles();
  Future<List<DshPluginInfo>> listPlugins();
  Future<DshAccountState> accountState();

  // live control surface
  Stream<DshSessionControlUpdate> watchSessionControl(); // baseline replaces; projection frames patch

  // feature detection
  Future<bool> supports(String endpoint);  // cached: call with {}; 404 => false, any answer => true
}
```

`load()` performs the reads in parallel where safe, tolerates absent optional
endpoints (capability false, empty collection, never an exception for a 404),
and propagates auth/transport failures. Catalog writes are settings/command
mutations (there is no provider CRUD or workspace/list endpoint in 0.2.2).

`DshSessionControlUpdate` is sealed: `DshSessionControlBaseline`
(`Map<String, DshSessionProjections>`) or `DshSessionControlProjection`
(`sessionId`, `key`, `value`, `seq`).

## 10. Session handle (`dsh_session.dart`)

```dart
enum DshPromptMode { queue, steer }

class DshSession {
  final String id;

  // --- host events for this session are delivered inside watch() by default
  Stream<DshSessionUpdate> watch({
    bool assistantStream = true,
    bool activate = true,             // promote a cold session before its first prompt
    int maxMessages = 500,
    DshTurnWindow turnWindow = const DshTurnWindow(minMessages: 50, minTurns: 2),
  });

  Future<void> prompt({
    required String text,
    List<DshImageInput> images = const [],
    List<String> fileReceiptIds = const [],
    DshPromptMode mode = DshPromptMode.queue,
    String? requestId,               // caller may supply for optimistic matching
    String? clientTimeZone,          // default: local IANA name
  });
  Future<void> cancel();

  Future<DshModelSelection> setModel(DshModelSelection selection);
  Future<DshCommandExecution> setPermissionPreset(String preset);
  Future<DshCommandExecution> executeCommand(String line);
  Future<List<DshCommandDescriptor>> listCommands();
  Future<List<DshSkill>> listSkills();
  Future<String> rename(String title);

  Future<void> answerApproval(DshApprovalRequest request, DshApprovalDecision decision);
  Future<void> answerQuestions(DshUserQuestionRequest request, List<DshQuestionAnswer> answers);
  Future<void> rejectQuestions(DshUserQuestionRequest request, {String message = 'declined'});
  Future<void> delegateHostRequest(DshHostRequest request); // kind: 'next'

  Future<DshSessionState> state();
  Future<DshSessionProjections?> projections();
  Future<DshHistoryPage> loadOlderHistory({int? beforeSeq, int maxMessages = 200, DshTurnWindow? turnWindow});
  Future<DshUploadReceipt> uploadFile(List<int> bytes, {String? name, String? mediaType});
  Future<List<int>> fetchAttachment(DshImageAttachment attachment);
  Future<void> close();
}

sealed class DshSessionUpdate {}
final class DshSessionSnapshotUpdate extends DshSessionUpdate { final DshSessionSnapshot snapshot; }
final class DshSessionEventUpdate extends DshSessionUpdate { final DshSessionEvent event; }
final class DshSessionAssistantFrameUpdate extends DshSessionUpdate { final DshAssistantStreamFrame frame; }
final class DshSessionHostRequestUpdate extends DshSessionUpdate { final DshHostEvent event; }
final class DshSessionConnectionUpdate extends DshSessionUpdate { final DshConnectionState state; final DshException? error; }
```

`watch()` contract: first item is always a `snapshot`; after it durable events
arrive in contiguous `seq` order (duplicates dropped, holes filled from
`session/page`); assistant frames carry `revision`; host requests for this
session are forwarded including ones pending when the stream opens; after a
reconnect a fresh snapshot is emitted and the generation's pending host requests
are re-forwarded (dedupe by `eventId` in the projection layer). `watch()` may be
called once per session; `close()` cancels it.

Prompting a cold session: `watch(activate: true)` is the supported promotion path
(the session log is read passively, the Agent is activated by the follow), so
`openSession(id)` → `watch()` → `prompt()` is the normal flow.

## 11. Projection (`dsh_projection.dart`)

```dart
class DshTranscript {
  DshTranscript({this.locale = 'en'});

  void apply(DshSessionUpdate update);   // feed every watch() update
  void applyHostEvent(DshHostEvent event);
  void markDisconnected(DshException? error);
  void markConnected();

  // state (all read-only)
  DshSessionHeader? get header;
  int get cursor;
  bool get running;            // a turn is executing
  bool get streaming;          // a live assistant attempt is being folded
  bool get stale;              // disconnected, showing last known transcript
  bool get hasOlderHistory;
  String? get title;           // session/title event > projection title
  DshModelSelection? get selectedModel;   // projection `next`
  String? get permissionPreset;           // projection `permissions.currentValue`
  DshSessionProjections? get projections;
  List<DshTranscriptItem> get items;
  List<DshApprovalRequest> get pendingApprovals;   // live, not the audit trail
  List<DshUserQuestionRequest> get pendingQuestions;
  DshTokenUsage? get usage;    // projection tokenUsage
}

sealed class DshTranscriptItem { String get key; }
final class DshUserMessageItem extends DshTranscriptItem {
  final int seq; final DateTime time; final String text;
  final List<DshImageAttachment> images; final List<DshFileAttachment> files;
  final String? requestId; final String sourceKind;
}
final class DshAssistantMessageItem extends DshTranscriptItem {
  final String id;             // 'a<seq>' durable, 'd<attemptId>' live draft
  final String? rowKey;        // 'm<turn>.<step>' shared by draft and committed row
  final int? seq; final DateTime? time;
  final String text; final String reasoning;
  final bool streaming; final bool interrupted;
  final DshTokenUsage? usage; final String? provider; final String? model;
  final List<String> toolCallIds;   // tool cards that belong to this message
}
enum DshToolStatus { streaming, running, awaitingApproval, succeeded, failed, denied, cancelled }
final class DshToolItem extends DshTranscriptItem {
  final String callId; final String name; final String arguments; // raw JSON text
  final DshToolStatus status; final int? seq;
  final List<DshPart> resultParts; final String? resultText;
  final DshLlmFailure? failure; final DshApprovalOutcome? approvalOutcome;
  final DshApprovalRequest? pendingApproval; final Object? meta;
}
final class DshNoticeItem extends DshTranscriptItem {
  enum DshNoticeKind { error, aborted, interrupted, retry, command, approval, info }
  final int? seq; final DateTime? time; final DshNoticeKind kind; final String text;
}
```

Fold rules (from `protocol.md` §5.2–§5.6):
- snapshot replaces everything (header, cursor, projection values, items);
  after reconnect it is authoritative and the stale flag clears;
- durable `user/message` renders only when `surfaceOp` is append/absent and
  `source.kind == 'user'`; injected context is not a chat row;
- `assistant/message` renders text+reasoning; its `tool-call` blocks become
  `DshToolItem`s; `tool/call` starts a card and `tool/result` settles it by
  `callId`; a call with no result while `running` is running, otherwise
  `cancelled`;
- `turn/end.reason.kind == 'error'` becomes a `DshNoticeItem` inside the turn;
  `aborted`/`interrupted` become notices and mark open cards;
- live `assistant-stream` frames build a draft `DshAssistantMessageItem`
  (`streaming: true`, `rowKey` shared with the eventual durable message) and
  streaming tool cards; a higher `revision` voids the current draft; `end`
  committed/abandoned drops the draft (the durable event is the replacement);
- `approval/asked|decided` update tool cards (awaitingApproval/denied) and are
  not rendered as separate rows; live waterfalls populate
  `pendingApprovals`/`pendingQuestions`, `cancel`/settle removes them;
- unknown events are kept for ordering and never rendered; an event gap does not
  throw (the session watch fills it, the projection stays append-only).

The projection is intentionally independent of Cuplivo DB models and Flutter:
the chat feature maps `DshTranscriptItem` to its widgets.

### `DshSessionStore` — the state object the feature layer owns

`DshTranscript` is a reducer; the session handle is the transport. The feature
layer gets both wrapped in one pure-Dart store (also in `dsh_session.dart`) so a
chat controller only has to listen and read:

```dart
class DshSessionStore {
  DshSessionStore(this.session, {String locale = 'en'});

  final DshSession session;
  final DshTranscript transcript;     // items + all state getters of §11
  DshConnectionState get connection;
  bool get started;

  /// Subscribes watch() and folds every update. Idempotent.
  Future<void> start({
    bool assistantStream = true,
    bool activate = true,
    int maxMessages = 500,
    DshTurnWindow turnWindow = const DshTurnWindow(minMessages: 50, minTurns: 2),
  });

  /// Emits after each applied update (a UI repaint tick). No Flutter types.
  Stream<void> get changes;

  Future<void> prompt({...});          // delegates to session
  Future<void> cancel();
  Future<void> dispose();              // closes watch + store
}
```

`changes` is a broadcast stream; the Flutter controller maps it to
`notifyListeners()`. All errors from `watch()` surface as a `DshNoticeItem`
(or the `stale` flag for connection loss) instead of terminating the store.

## 12. Client entry (`dsh_client.dart`)

```dart
class DshClient {
  DshClient(this.endpoint, {DshTransport? transport, DshMuxOptions muxOptions = const DshMuxOptions()});

  final DshEndpoint endpoint;
  final DshTransport transport;
  late final DshRpc rpc;
  late final DshMux mux;
  late final DshCatalog catalog;

  DshCookie? get cookie;
  DshConnectionState get state;
  Stream<DshConnectionState> get states;
  Stream<DshHostEvent> get hostEvents;

  /// One-shot pairing: token → v1 cookie → verify GET /. The token is not
  /// retained after this call.
  Future<DshCookie> login(String token);

  /// Resume a stored cookie without a token (no login).
  void useCookie(DshCookie cookie);

  /// Open the mux and wait for the first ready generation.
  Future<DshMuxGeneration> connect();

  /// Read the whole catalog once (see DshCatalogSnapshot).
  Future<DshCatalogSnapshot> loadCatalog({bool includePlugins = true, bool includeSettings = true, bool includeAccount = true});

  Future<DshSession> createSession({String? cwd, String? workspaceId, String? agentPreset});
  DshSession openSession(String sessionId);

  Future<void> close();
}
```

Typical feature-layer lifecycle:

```dart
final endpoint = DshEndpoint.parse(pastedUrl);          // form validation
final client = DshClient(endpoint);
final cookie = await client.login(endpoint.token!);      // then persist cookie
await client.connect();                                  // mux ready
final snapshot = await client.loadCatalog();             // first paint data
final session = client.openSession(snapshot.sessions.first.sessionId);
final transcript = DshTranscript();
session.watch().listen(transcript.apply);
await session.prompt(text: 'hello');
...
await client.close();
```

Resume path: `DshClient(endpoint.withoutToken())`, `useCookie(storedCookie)`,
`connect()`. A 401 anywhere means the stored cookie is stale → UI asks for a new
WebUI URL; never retry a rejected token.

## 13. What is deliberately not in this client

- No DSH data persistence, no cache, no offline mode.
- No `/connect` v2 operator login (the v1 browser cookie covers API + mux +
  WebView and is the only cookie a WebView can reuse).
- No terminal/PTY, schedules/goals, account sign-in, speech, plugin market,
  workspace-file editing: out of the brief's scope; their endpoints are still
  readable through `DshRpc.call` and `DshCatalog.supports` if a later phase
  needs them.
- No plugin-panel URL: DSH has none (the WebView hosts the full SPA).
