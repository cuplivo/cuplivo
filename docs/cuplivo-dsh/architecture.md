# Cuplivo ⇄ DeepSeek Harness — architecture contract

Status: agreed layout for the `feat/cuplivo-dsh` branch. Research notes:
`protocol.md` (server API ground truth, DSH 0.2.2-rc.1), `client-reference.md`
(Dart client study + design), `cuplivo-integration.md` (host seams),
`e2e-infra.md` (acceptance harness), `ui-spec.md` (surface requirements from the
owner's images). This file states the decisions the implementation must hold to;
when a detail here disagrees with a research note, this file wins and is amended.

## 1. Invariants

1. **Cuplivo stores no DSH session data.** No DSH message, transcript, title,
   workspace, model choice or setting is written to Cuplivo's database, backups,
   sync or caches. A connection record (display name, base URL, authority,
   credential reference) is local; everything else is fetched live and dropped on
   disconnect.
2. **Credentials are not settings.** The DSH browser-session cookie (`v1`) lives
   in `flutter_secure_storage` keyed by the remote id; the connection record in
   `BusinessPreferences` never carries it. The launch token the user pastes is
   used once for login and only kept in memory for the connect attempt. A `v2`
   API cookie (`/connect`) is explicitly not used: it allows one mux peer, cannot
   authenticate a WebView, and is outlived by the v1 cookie.
3. **The protocol client is Flutter-free.** Everything under `lib/core/dsh/`
   imports only SDK libraries and sibling `dsh` files. It is unit-testable in the
   default `flutter test` run and reusable by a future desktop/CLI host.
4. **The UI reuses Cuplivo.** Every surface uses Cuplivo's theme tokens, shared
   widgets, Lucide icons and the existing message renderer. A new raw Material
   widget is justified in the PR when it replaces nothing that already exists.
5. **Rendering follows Cuplivo settings.** Markdown, code blocks, tool cards,
   reasoning cards, font size, appearance, animations and text selection all read
   the same `SettingsProvider` as a local conversation.
6. **Capability parity.** A Cuplivo control exists only when the connected server
   exposes it, and no server capability named by the brief is left unreachable
   without a visible reason. DSH 0.2.2-rc.1 facts this pins:
   - `session/selectModel` returns `{selected}` only; the next-session default is
     `session/initializeDefaultModel`.
   - a session's permission has no write RPC: read `permissionPreset` from the
     projections and change it with the `/permission` command; the *default* for
     new sessions is a settings write (`permission.defaultPreset`).
   - `session/prompt` on a cold session requires activation (a `session/follow`
     with `activate:true` whose snapshot is awaited first).
   - the right-rail **浏览器** card has no remote API in 0.2.2-rc.1 → it is not
     rendered; workspace files and terminals are real (`workspaceFiles/*`,
     `terminal/create|attach|retain`), and terminal input/output rides the
     `terminal/attach` stream.
   - plugin panels have **no per-panel URL**; the only honest WebView is the
     whole DSH SPA authenticated with the v1 cookie.
7. **Remote means live.** There is no offline cache and no optimistic history.
   The transcript is a projection of the server's session log, rebuilt on every
   open and patched by live events.

## 2. Domain model

```
DshRemote            // local connection record; stored in prefs, listed in UI
  id                 // uuid, stable across renames
  name               // display name, defaults "DeepSeek Harness"
  baseUrl            // e.g. http://192.168.1.20:3080  (no query)
  authority          // host[:port] as the server binds the cookie to
  transportSecure    // whether the scheme is https
  createdAt, lastConnectedAt, lastError

DshRemoteRef         // ChatOwner identity for one remote
  == ChatOwner(kind: harness, id: remote.id)
```

`ChatOwnerKind` gains `harness`. Existing `ChatOwner.assistant/group`
constructors stay; `ChatOwner.harness(id)` is added and the exhaustive switches
(`chat_owner.dart`, `ChatOwnersProvider`, settings panes, drawer) are updated in
the same commit. A new `isHarness`/`isAssistant` predicate replaces implicit
"not group ⇒ assistant" assumptions.

Deliberate deviation from `cuplivo-integration.md` §0.2: a remote is **not** an
`Assistant` with a discriminator. That alternative would drag remotes into
assistant backups, LAN sync merges, group-member pickers, model selectors and the
assistant edit page, and would put the launch credential in an Assistant payload.
The owner-kind seam keeps the remote domain device-local by construction.

Inside a remote, the server's identifiers are the only keys:
`DshSessionId`, `DshWorkspaceId`, `DshProviderId`, `DshModelId`, `DshPluginId`.
They are never converted to Cuplivo ids.

## 3. Module layout

```
lib/core/dsh/                     # pure Dart client (no Flutter imports)
  dsh_endpoint.dart               # URL/token parsing, authority, scheme checks
  dsh_transport.dart              # v1 login -> cookie, HTTP carrier, WS upgrade
  dsh_rpc.dart                    # unary RPC envelope + typed call helper
  dsh_mux.dart                    # remote.mux: generations, streams, reconnect
  dsh_events.dart                 # wire event/stream models (session log, frames)
  dsh_models.dart                 # catalog/domain models
  dsh_catalog.dart                # sessions/workspaces/models/plugins/settings
  dsh_session.dart                # one session: snapshot+watch, prompt, cancel,
                                  # approvals, model/effort/permission
  dsh_projection.dart             # event fold -> transcript items
  dsh_client.dart                 # owner of one remote

lib/features/harness/             # Flutter feature
  models/dsh_remote.dart          # local connection record (toJson/fromJson)
  services/dsh_remote_store.dart  # JsonBlobStore<DshRemote> + secure cookie refs
  services/dsh_connection.dart    # per-remote lifecycle (connect/retry/close)
  state/dsh_connections_provider.dart   # all remotes + link status
  state/dsh_catalog_provider.dart       # models/providers/workspaces/plugins
  state/dsh_chat_controller.dart        # one open session: projection + actions
  pages/connect/…                 # creation flow: sheet -> mode -> URL -> check
  pages/assistant/…               # DSH assistant card + settings pages/tabs
  pages/home/…                    # harness-mode widgets embedded in HomePage
  pages/chat/…                    # conversation surface body (chat slice)
  pages/plugins/…                 # WebView host (whole SPA, v1 cookie)
  widgets/…                       # shared primitives (avatar, status dot, rail)

test/core/dsh/                    # protocol/projection unit tests
test/features/harness/…           # state/widget tests for the feature
integration_test/e2e/dsh_remote_acceptance_test.dart   # single E2E scenario
```

State follows Cuplivo's Provider conventions (a `ChangeNotifier` per moving
part, registered in `main.dart`, disposed with the app). No new state package.

**Home integration decision.** The harness chat lives *inside the existing
`HomePage`* (`HomeMobileScaffold` / `HomeDesktopScaffold`), not in a second home
shell. The two layouts, the shared `SideDrawer` and the desktop side-panel
geometry gain a harness mode: in harness mode the drawer shows the remote's
world (plugins/automation/more, workspaces, sessions) and the body shows the DSH
conversation; the local providers (`ChatService`, `HomeViewModel`,
`ChatController`, `AssistantProvider`) are never entered and harness data never
enters them. This is what keeps the mobile/desktop app bars, drawers, keyboard
handling and side-panel push behaviour identical to the rest of the app.

## 4. Protocol client

- One `DshClient` per connected remote: `DshTransport` (v1 login via
  `GET /?token=…` with explicit `Host`, no `Origin`; cookie capture), `DshRpc`
  (unary envelope), `DshMux` (one `/api/remote.mux` socket; `$events` first,
  then `session/control`, `workspace/follow`, `session/follow` per open chat) and
  catalog reads. It exposes typed methods and streams, and knows nothing about
  widgets.
- Connection lifecycle is per remote: `idle → connecting(login) → ready →
  reconnecting → failed(reason) → closed`. A lost socket voids every stream on
  that generation (no delta replay): reopen streams, re-read snapshots. Backoff
  500 ms · 2ⁿ capped 10 s with jitter; `$events` ready timeout 15 s.
- Errors are typed (`DshAuthException`, `DshTransportException`,
  `DshProtocolException`, `DshRemoteException`) and carry a user-actionable
  message; the UI never renders raw stack traces. 401/403 → "re-paste the WebUI
  link", not a silent retry.
- Feature detection: an endpoint the installed DSH does not expose yields
  `DshUnsupportedException`; the catalog exposes the capability flag and the UI
  hides or explains the surface. Unknown events/projections/content blocks are
  ignored, never fatal.
- Transcript state is a pure-Dart store + reducer: append-origin durable events
  plus a live assistant draft that is replaced by the committed
  `assistant/message`; projection frames are derived UI state, never transcript
  source.

## 5. State and data flow

```
DshConnectionsProvider (remotes + link status, owns store + secure cookie)
   └── DshConnection (per remote)
          ├── DshClient ──> DshCatalogProvider (workspaces, sessions, models,
          │                                     providers, plugins, settings)
          └── open session ──> DshChatController (projection, streaming,
                                                composer, approvals,
                                                model/effort/permission)
```

- `DshConnectionsProvider` lists remotes and keeps at most one live connection
  per remote; it is the only place that reads/writes `DshRemoteStore` and the
  secure cookie entries.
- `DshCatalogProvider` is a per-remote cache with `refresh()`; never persisted.
- `DshChatController` owns exactly one open session: cold snapshot + live events
  into the transcript reducer, exposes `DshTranscriptItem`s for the renderer, and
  answers composer actions. Closing/switching cancels the stream and drops the
  projection.
- Selecting a DSH owner in the drawer enters harness mode in the existing home;
  selecting a session opens it in the conversation body.

## 6. Surface mapping (brief → implementation)

| # | Brief surface | Where |
|---|---|---|
| 1 | 助手与群聊: create menu gains “DeepSeek Harness” | `ChatOwnerSettingsPage` menu + `pages/connect/` |
| 2 | “连接到一个新的DeepSeek Harness” with 直接连接 only | `pages/connect/` |
| 3 | Direct-connect form (name + WebUI URL + confirm + LAN/public hint) | `pages/connect/` |
| 4 | Connected assistant card (“远程连接的 DeepSeek Harness”) | `pages/assistant/` |
| 5 | Chat drawer: search, remote row, plugin/automation/more, workspaces, sessions, bottom bar | `SideDrawer` harness mode + `pages/home/` |
| 6 | Chat: Cuplivo renderer, remote model/effort/permission in composer, DSH “+” menu, app-bar right-rail button replacing minimap | `pages/chat/` + home app bars |
| 7 | Right rail pushes chat off-screen; official entries Flutter (workspace files, terminal native; browser hidden by capability), plugin WebView | right-rail widgets + `pages/plugins/` |
| 8 | Assistant settings tabs: 连接设置 / 通用设置 / 模型 / plugin tabs | `pages/assistant/` |
| 9 | Models page mirrors Cuplivo's provider page: DSH providers/models, 自定义提供商 first, provider detail per DSH settings schema | `pages/assistant/models_*` reusing provider widgets |

All strings go through ARB (`lib/l10n/app_en.arb` template + `app_zh.arb`, then
`tool/l10n/translate.py sync` for ru/ko/tr/zh_Hant).

### 6.1 Scope decisions for this PR (product answers to `client-reference.md` §10.2)

- **浏览器 rail card: omitted.** DSH 0.2.2-rc.1 exposes no remote browser API;
  capability parity wins over the reference image. The PR lists the difference.
- **Terminal: native, after the chat slice.** `terminal/create|attach|retain` are
  real (attach is a bidirectional stream) and the repo already vendors
  `dependencies/terminal_view` + the workspace terminal pages, so the card is
  rendered when the capability probe succeeds and the page drives the remote
  terminal with the existing emulator widget (input → attach uplink).
- **Plugin UI: single native `插件` page** (list/enable/disable from
  `pluginInventory/list` + `pluginManager/*`); its panel/settings interiors open
  the WebView host with the whole DSH SPA and the v1 cookie — there is no
  per-panel URL in 0.2.2, so the page is honest about what it is. No DOM-scraping
  heuristics; a deep-landing JS hook exists but is optional and disabled by
  default.
- **自动化任务: native list** (read/toggle/delete via `schedule/*`); creation and
  full editing open the WebView host until a native form is justified.
- **更多: native menu** (settings, plugin page, session info, about/version).
- **Models tab: full native slice** — DSH providers, `自定义提供商` first, provider
  detail driven by the DSH settings schema for the common provider, custom
  provider creation with its own base URL/API key/models and per-model reasoning
  efforts (goal §7). Account/DeepSeek login row: hidden (no login RPC).
- **One connected remote is enough for the PR**; the store and provider model
  support many.
- **E2E data**: the scenario creates its own session and sends a short prompt, so
  the screenshots are self-seeded; the operator's reset keeps the host clean.

## 7. Persistence decision

DSH remotes are **not** assistants: they have no model, no prompt, no memory and
no local conversation. They are stored as:

- `DshRemoteStore extends JsonBlobStore<DshRemote>` with the new
  `BusinessPreferences` key `dsh_remotes_v1`, registered in
  `BusinessKeyRegistry.rules` as `deviceLocal` /
  `PolicyReason.networkEnvironment` — no Drift migration, no generated code;
- the owner order extends the existing `chat_owner_order_v1` list with
  `harness:<id>` keys, so drag order works without a second ordering system;
- the v1 cookie in `flutter_secure_storage`, keyed `cuplivo.dsh.cookie.<remoteId>`,
  deleted when the remote is deleted.

Blast-radius audit for adding `ChatOwnerKind.harness` (each call site checked in
the commit that adds it): `chat_owner.dart`, `chat_owners_provider`,
`assistant_settings_page` and `desktop/setting/assistants_pane` (owner rows),
`side_drawer` (owner rendering), `home_page_controller.openOwner` (branch before
conversation logic), `assistant_select_sheet` (exclude remotes),
`group_member_list` (exclude remotes), and any `!owner.isGroup` predicate.

## 8. Acceptance

- `pr-check`: format, gen-l10n diff, l10n coverage, identity sweep, analyze,
  full tests — green.
- `pr-check` unit tests cover: URL/token parsing, v1 cookie login + redirect,
  RPC envelope/error mapping, mux generations/reconnect, snapshot+live fold,
  catalog parsing, approval/question waterfalls, session list/search, CRUD of
  remotes, owner-kind reconciliation.
- Android E2E (`/e2e`, real endpoint from repository secrets; hermetic stub when
  absent) runs one scenario: create the DSH assistant through the real connect
  form, open a session, send a prompt, see the streamed answer, open the right
  rail, open the models settings page; captures the frames that map to the
  brief's reference images.
- Final comparison: each E2E screenshot vs. its reference image
  (`docs/cuplivo-dsh/reference/`, untracked), differences listed in the PR.
