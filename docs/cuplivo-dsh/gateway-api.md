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
- one adapter implementation (`lib/features/harness/services/`, later slice)
  maps client types → the view models below. A wire change stops there;
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
