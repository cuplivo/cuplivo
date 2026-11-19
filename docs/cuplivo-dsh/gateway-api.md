# DSH gateway — the seam between the feature state and the protocol client

Status: implementation contract for `lib/features/harness/state/dsh_gateway.dart`
(+ `dsh_gateway_models.dart`) and its only consumer,
`lib/features/harness/state/dsh_connections_provider.dart`. Owner:
`harness-foundation`. The protocol client itself is owned by `dsh-client-core`
(`docs/cuplivo-dsh/client-api.md`); this file is what the later home/chat/model
slices code against, so they never import `lib/core/dsh/`.

## Why a seam

`lib/core/dsh/` is Flutter-free and speaks the protocol's own domain types.
The feature layer needs a small, stable, mockable surface:

- `state/` imports only `models/` + `services/` (no `package:flutter` in the
  adapter except what the provider needs), and never `lib/core/dsh/`;
- one adapter implementation
  (`lib/features/harness/services/dsh_client_gateway.dart`, landed) maps client
  types → the view models below. A wire change stops there;
- the state layer stays testable with fakes (no sockets, no cookie jar).

## Surface

```dart
// state/dsh_gateway.dart
abstract interface class DshGateway {
  // lifecycle ---------------------------------------------------------
  Future<DshConnectResult> connect({required DshRemote remote,
      String? launchToken, String? storedCookie});
  Future<void> disconnect();                 // idempotent
  Future<void> retry();                      // reconnect after a drop
  Stream<DshLinkStatus> get linkStatusStream; // adapter-driven changes
  Stream<DshRemoteUpdate> get updates;       // catalog patches + session control

  // catalog -----------------------------------------------------------
  Future<DshCatalogSnapshot> refreshCatalog();
  Future<void> updateGeneralSettings(DshGeneralSettings settings);

  // sessions (home slice) ---------------------------------------------
  Future<DshSessionSummary> createSession({String? workspaceId, String? cwd});
  Future<void> renameSession(String sessionId, String title);
  Future<void> setSessionPinned(String sessionId, {required bool pinned});
  Future<void> setSessionArchived(String sessionId, {required bool archived});
  Future<DshSessionHandle> openSession(String sessionId);

  // workspace files (right rail) --------------------------------------
  Future<List<DshFileEntry>> listFiles(String sessionId, String path);
  Future<String> readTextFile(String sessionId, String path);
  Future<DshFileStat> statFile(String sessionId, String path);
  Future<List<int>> readFileBytes(String sessionId, String path);
}

abstract interface class DshSessionHandle {
  String get sessionId;
  DshSessionView? get current;
  Stream<DshSessionView> get views;          // full-state view per update

  Future<void> prompt(String text, {DshPromptMode mode = queue,
      List<DshPromptAttachment> attachments = const []});
  Future<void> cancel();
  Future<void> selectModel(DshModelSelection selection);
  Future<void> initializeDefaultModel(DshModelSelection selection);
  Future<void> runPermissionCommand(String presetId);
  Future<void> answerApproval(DshApprovalRequest request,
      {required bool approved, String? note});
  Future<void> answerQuestions(DshQuestionRequest request,
      List<DshQuestionAnswer> answers);
  Future<void> rejectQuestions(DshQuestionRequest request,
      {String message = 'declined'});
  Future<void> loadOlder();
  Future<void> close();                      // idempotent
}
```

Everything throws `DshGatewayException(DshFailure, detail)` across the seam;
raw client exceptions never cross it. `DshFailure.notConfigured` means no
adapter is wired yet (the foundation slice).

## View models (all in `dsh_gateway_models.dart`)

| view model | carries | client-api.md source |
|---|---|---|
| `DshCatalogSnapshot` | general settings, permission presets, model catalog, workspaces + their sessions, ungrouped sessions, plugin entries, commands, skills, capabilities, per-section failures, loadedAt | §9 `DshCatalogSnapshot` |
| `DshModelCatalog` / `DshProviderGroup` / `DshModel` / `DshReasoningEffort` | provider groups, model rows, per-provider failure message, reasoning choices, remote default selection | §9 `DshModelCatalog`, `DshProviderInfo` |
| `DshWorkspace` / `DshSessionSummary` | workspace title/path, sessions in server order, per-session title/workspace/running/queued/pinned/archived/updatedAt | §9 `DshWorkspace`, `DshSessionSummary` |
| `DshPluginEntry` | id/title/description/enabled/diagnostic (panel body is a later WebView slice) | §9 `DshPluginInventory` |
| `DshCommand` / `DshSkill` | composer plus-menu entries | §9 `listCommands` / `listSkills` |
| `DshCapabilities` / `DshCapability` | presence flags; a missing capability hides the control (capability parity) | §9 `DshCapabilities` |
| `DshCatalogFailure` / `DshCatalogSection` | per-family failure, so one failed read does not blank the drawer | §9 `load()` tolerance |
| `DshSessionControl` | per session: title, running, queued, selected model+effort, permission preset, pending approvals/questions, unread | §9 `watchSessionControl()` |
| `DshCatalogPatch` (`DshSessionUpsert`, `DshSessionRemoved`, `DshWorkspaceUpsert`, `DshWorkspaceRemoved`, `DshWorkspaceOrder`, `DshCatalogInvalidated`) | live workspace/session deltas the provider merges | §9 `watchWorkspaces()` |
| `DshSessionView` + `DshTranscriptEntry` (`DshUserEntry`, `DshAssistantEntry`, `DshToolEntry`, `DshNoticeEntry`) | full renderable session state: entries, title, running/streaming/stale/queue, selected model, permission preset, pending approvals/questions, usage, error | §11 `DshTranscript` |
| `DshApprovalRequest` / `DshQuestionRequest` / `DshQuestionAnswer` / `DshQuestion` | host requests the chat UI answers | §10/§11 |
| `DshFileEntry` / `DshFileStat` | right-rail file listing/preview | §10 `fetchAttachment`, project file RPCs |

Attachments for prompts are `DshPromptAttachment(receiptId, name?, mediaType?)`;
the chat slice uploads bytes itself in a later slice (client §10
`uploadFile`/`fetchAttachment`). No file bytes ride the catalog.

## How later slices reach it

Through `DshConnectionsProvider` only (registered in `main.dart`):

```dart
final connections = context.read<DshConnectionsProvider>();
connections.remotes;                                  // records, not display order
connections.linkStatus(id);                           // idle/connecting/ready/failed
connections.catalogFor(id);                           // DshCatalogSnapshot?
connections.sessionControlsFor(id);                   // Map<sessionId, control>
connections.remoteById(id);
connections.createRemote(name: ..., link: ...);       // creation form only
connections.connect(id, launchToken: ...);            // creation form / retry
connections.retry(id);
connections.updateGeneralSettings(id, settings);      // assistant settings page
connections.refreshCatalog(id);
connections.openSession(id, sessionId);               // returns DshSessionHandle
connections.gatewayFor(id);                           // session writes/home actions
connections.dispose();                                // owner only
```

The provider subscribes to `gateway.updates` and
`gateway.linkStatusStream` after a successful connect, merges catalog patches
into `catalogFor`, stores session-control projections, and drops all of it on
`disconnect`/`deleteRemote`/`dispose`. One gateway per remote; callers never
construct one.

## Credential rules enforced here

- `connect` passes a stored cookie read from `flutter_secure_storage`
  (`cuplivo.dsh.cookie.<remoteId>`) and persists `DshConnectResult.cookie`
  (the v1 browser cookie minted by a fresh `/?token=` login) only after success.
- The launch token is a `connect` argument and is never stored, logged or put in
  a view model.
- v2 `/connect` is not used (one mux per v2 peer, no WebView cookie).

## Adapter implementation (landed)

`lib/features/harness/services/` holds the only code that imports `lib/core/dsh/`:

| file | responsibility | client surface (`client-api.md`) |
|---|---|---|
| `dsh_client_gateway.dart` | `DshClientGateway implements DshGateway`: pairing, catalog read, live streams, session/control + workspace patches, general settings writes, workspace-file RPCs | §3 `DshClient.pair`/`connect`/`loadCatalog`, §7 `DshCatalog`/`DshRpc`, §9 catalog + live control, §12 files |
| `dsh_client_gateway_mapping.dart` | pure functions from client models to the view models (catalog join, control projection, workspace patches, transcript rows, host requests, file entries); no sockets, no Flutter | §9–§12 domain types |
| `dsh_client_session_handle.dart` | `DshClientSessionHandle implements DshSessionHandle`: subscribes `DshSessionStore.changes`, re-folds `session/control` projections, emits folded `DshSessionView`s, translates prompt/answer/permission calls | §10/§11 `DshSessionStore` |

`main.dart` registers the factory beside the provider:
`gatewayFactory: (_) => DshClientGateway()`.

### Connect / reconnect

1. `DshEndpoint.parse(remote.baseUrl)` validates the stored origin.
2. With a launch token: `DshClient.pair(<indexUri>?token=…)` (login → verify →
   mux ready); the token is not retained after pairing.
3. Without one: the stored `DshCookie` is decoded (JSON in the secure store),
   its `authority` is compared with the stored origin before it is sent, and
   `DshClient.pair(baseUrl, storedCookie: …)` resumes.
4. `loadCatalog(includePlugins: true, includeSettings: true, includeAccount:
   false)` → `mapDshCatalog` → `DshConnectResult(catalog, cookie: <DshCookie
   JSON>)`; only then are the live streams subscribed. Between the two the
   adapter runs the protocol's idempotent `session/initializeDefaultModel`
   bootstrap and tolerates a Host that does not expose it. `retry()` calls
   `mux.reconnect()` and re-reads the catalog, then emits
   `DshCatalogInvalidated`.
5. `DshConnectionState` → `DshLinkStatus` (connecting/reconnecting →
   `connecting`; unauthorized → `failed(auth)`; closed → idle) and open session
   handles get the corresponding `DshFailure` so their transcript stays
   rendered with a stale/error banner.

### Updates stream

- `catalog.watchSessionControl()`: a baseline seeds every session; each
  projection frame is merged and emitted as `DshSessionControlUpdate`, and the
  same frame is applied to an open handle's `DshTranscript` (so a title or
  permission change made elsewhere appears without a snapshot). The last
  control per session is cached and replayed to the first listener, because the
  provider subscribes only after `connect` returns.
- `catalog.watchWorkspaces()`: upsert/remove/order map to
  `DshWorkspaceUpsert`/`DshWorkspaceRemoved`/`DshWorkspaceOrder`; a
  baseline/replace (first frame or after a reconnect) and the archived/pinned
  sets have no patch shape, so they emit `DshCatalogInvalidated` and the
  provider answers with `refreshCatalog()`.
- `client.hostEvents`: `api-session/added` upserts the session summary;
  `api-session/status` updates the running flag and emits a control projection.
  Approvals/questions stay inside the session store (they are per-session
  waterfalls).

### Catalog mapping notes

- Session summaries are joined into their workspace from
  `DshWorkspace.sessionIds`; ids in no workspace become `ungroupedSessions`;
  `archivedSessionIds`/`pinnedSessionIds` set the per-session flags.
- Permission presets come from `permissionPresets/catalog.options`; the
  general-settings default is `defaultPreset`, the Session-Log switch is
  `settings.namespace('session-log-deepseek').value.enabled`.
- Provider lookup failures are listed as disabled provider groups
  (`failureMessage`) instead of hidden rows.
- Capabilities come from `DshCapabilities.supports(...)`: `session/modelCatalog`
  → models, `workspace/follow` → workspaces, `pluginInventory/list` → plugins,
  `workspaceFiles/list` → sessionFiles, `commands/list`/`skills/list` →
  commands/skills. `approvals` is set for any connected Host (mux waterfalls
  are not HTTP probes). Endpoints the Host rejects (the client records
  `known == false`) become entries in `DshCatalogSnapshot.failures` for their
  section instead of failing the whole catalog.
- `commands`/`skills` are session-scoped on the wire
  (`commands/list {agentId}`, `skills/list {request.sessionId}`), while the
  gateway snapshot carries one global roster. The adapter asks the first listed
  session with `agentAvailable` (best effort, after the catalog batch) so the
  composer plus menu has the server's roster; a Host that does not expose
  either endpoint records a per-section failure instead. A session whose preset narrows the roster is not
  represented — the seam has no per-session command read yet (see gaps).

### General settings writes

`updateGeneralSettings` diffs the request against the last read and writes both
changed paths through `settings/mutate` with the namespace's current revision
(from one `settings/describe`): `permission.defaultPreset` (`set`, or `unset`
for null) and `session-log-deepseek.enabled`. Two separate writes; a partial
failure surfaces as `DshGatewayException` and the provider does not update its
cached general settings.

### Workspace files

The client deliberately has no workspace-file API, so the adapter calls the
protocol endpoints through the public `DshRpc.call`:

| seam | wire call | args |
|---|---|---|
| `listFiles(sessionId, path)` | `workspaceFiles/list` | `{workspaceFileScopeId, path: path.isEmpty ? '.' : path}` |
| `readTextFile(sessionId, path)` | `workspaceFiles/read` | `{workspaceFileScopeId, path, range: {offset: 0}}` |
| `statFile(sessionId, path)` | `workspaceFiles/stat` | `{workspaceFileScopeId, path}` |

Entries map `{name, type, size?}` to `DshFileEntry`; child paths are joined with
`/` from the workspace-relative listing path (`''` is the root the home adapter
uses). `statFile` reports `isDirectory: false` (the wire result has no type).

### Deliberate gaps in the client (not worked around in `lib/core/dsh/`)

1. **`workspaceFiles/readBytes`** is a binary multipart response and the client
   transport exposes only JSON envelopes, so `readFileBytes` throws
   `DshFailure.unsupported`; the right rail falls back to text preview. A real
   byte API belongs in `lib/core/dsh` (client-core).
2. **`session/initializeDefaultModel` is a bootstrap, not a setter**; the
   endpoint takes no arguments and only ensures the deployment default
   selection is initialised (the official UI calls it once after connect — the
   adapter does the same). `DshSessionHandle.initializeDefaultModel(selection)`
   therefore ignores its argument; the session `selectModel` call is what
   changes a session's next model. The seam parameter should be dropped; DSH
   0.2.2 exposes no "set default model" RPC.
3. **No decline waterfall for host questions**: `rejectQuestions` answers with
   an empty answer list, the closest 0.2.2 wire form; there is no
   `user-questions/reject` call.
4. **Approval decisions carry no note**; `answerApproval(note: …)` is accepted
   for seam symmetry and dropped (the wire has only `allowed-once|rejected`).
5. **Session-scoped commands/skills** (see above): the adapter fills the global
   snapshot from the first agent-available session, which is a representative roster, not
   the exact one an arbitrary open session may see. A per-session read belongs
   in the seam (`DshSessionHandle` gaining commands/skills) or in a catalog
   helper when a slice needs it.

## Deliberately not here (documented TODOs)

- **Terminal** (`terminal/create|attach|retain`): a later workspace slice. Not
  faked here; add `openTerminal(...)` to `DshGateway` + real adapter when that
  slice lands.
- **WebView cookie injection** for plugin panels/settings pages: later slice;
  the adapter exposes nothing for it yet, and the chat slice must not depend on
  it.
- **Uploads and attachment bytes**: later chat slice (client §10).
- **Provider/model CRUD**: DSH 0.2.2 has no remote CRUD endpoints; the model tab
  writes settings through the adapter, not through this interface today.

## Provider-settings adapter (R11 seam)

The 模型 tab codes against `DshProviderSettingsGateway`
(`lib/features/harness/models/dsh_provider_settings.dart`). It is a **separate,
optional capability**, not part of `DshGateway`, so existing fakes stay valid:

```dart
// state/dsh_gateway.dart
abstract interface class DshProviderSettingsHost {
  DshProviderSettingsGateway? get providerSettings;
}
```

`DshClientGateway implements DshGateway, DshProviderSettingsHost` and returns a
`DshClientProviderSettings` bound to its live `DshClient`
(`lib/features/harness/services/dsh_provider_settings_adapter.dart`). The state
layer exposes it as `DshConnectionsProvider.providerSettingsFor(remoteId)`
(null for adapters that only speak the chat contract); the page injects that
into `DshModelsTabBody(settings:)`. No ARB keys belong to this seam.

Wire mapping (protocol §4.4):

| seam call | client call | notes |
|---|---|---|
| `load()` | `llm/listConfigurableProviders` → `settings/describe` → `credentials/describe` (64-ref chunks) | profile is `settingsPath` inside `settingsNs` (`[]` = whole namespace, `['providers', id]` for pi-ai); `revision` is the namespace CAS token; credential ref = profile `apiKeyEnv` else `<ROUTE>_API_KEY`; `declared` → deletable custom route; `error` → `DshProviderEntry.error` |
| `save(draft)` | `settings/mutate` `set` at `draft.settingsPath` with `expectedRevision` | one `describe` first: stale `draft.expectedRevision` fails as `conflict` before writing; a new route uses the fresh namespace revision. Existing unknown profile fields survive because the write merges the current profile JSON; `models` are rewritten only for new/`declared` routes (shipped routes keep the Host's array); `api` is added for new routes and updated only when already stored; clearing the address removes `baseURL` |
| `delete(entry)` | `settings/mutate` `unset` at `entry.settingsPath` | only `declared` routes; conflict maps like `save` |
| `setCredential` / `clearCredential` | `credentials/set` / `credentials/unset` | plain value never returned or persisted locally |
| `discover(draft)` | `llm/discoverModels` `{settingsNs, request:{provider?, baseURL, api, apiKey?}}` | `settingsNs` is the known route's namespace, else `llm-pi-ai`; advisory result only |

Failure mapping: `settings/conflict` → `DshProviderSettingsFailure.conflict`,
`*/rejected` (`credential/rejected`, `settings/rejected`,
`llm/model-discovery-rejected`) → `rejected`, 404/unsupported → `unsupported`,
transport/auth/closed → `unreachable`, everything else `unknown`; no raw
`DshException` crosses the seam.
