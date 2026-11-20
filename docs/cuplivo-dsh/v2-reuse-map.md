# Cuplivo × DeepSeek Harness v2 — reuse map

Research for the v2 round (settings parity, terminal, context ring, attachments,
embedded WebView, file previews). **No code changes**; this document tells the
implementation slices which existing Cuplivo asset to reuse, which to extend,
and what has to be new. Every claim is anchored to a file and line at the
current head, plus the DSH facts in `protocol.md`, `client-reference.md`,
`architecture.md`, `ui-spec.md` and `cuplivo-integration.md`.

Decision vocabulary:

| decision | meaning |
|---|---|
| **Reuse** | use the existing widget/service unchanged; only wiring is needed |
| **Extend** | additive change to an existing file (new optional parameter, new case in an existing switch/model) |
| **New** | a new file or widget/service that does not exist today |
| **Drop** | remove the current Cuplivo behaviour; it is invented or wrong for v2 |

At a glance:

| surface | reuse | extend | new | drop |
|---|---|---|---|---|
| terminal | `terminal_view` renderer, `TerminalSessionManager`, tab strip, key bar | `TerminalPage` (runtime/manager injection, extracted surface), `HarnessRailPage.terminal`, core `DshStream` uplink | `DshPtySession`/`DshWorkspaceRuntime` adapter, `TerminalSurface`, rail panel | `_RailTerminalPage` placeholder, read-only/blank fallbacks |
| context ring | `ContextUsageRing` | `ChatInputBar` override, core/feature session view models | `dsh_context_usage.dart` mapping, `DshContextUsageSheet` | guessed ratios / fabricated bucket breakdown |
| attachments | picker (`FileUploadService`), draft pipeline, `ComposerAttachmentCard` | composer callbacks, `DshSessionHandle` upload, `DshComposerSubmission`, user transcript entry | upload service, remote image provider | text-only send assumption |
| WebView | `DshPluginWebPage` cookie/load/failure logic, `InAppWebView` stack | extract `DshWebUiView` (+`initialUrl`), platform-unsupported policy | landing-script assets (when needed) | per-plugin URL assumption |
| previews | all `File`-based preview widgets, `FilePreviewFrame`, type identity | `DshFileStat` (`absolutePath`/`version`), `readFileBytes` via `/api/file` | preview cache, `DshFilePreviewPage`, `DshRemoteFileCard` | fake previews for unrenderable kinds |
| settings tabs | connection/general bodies, `DshModelsTabBody` | tab strip → spec list, `_tabId`, active-tab fallback | `DshSettingsTabSpec`, plugins/presets bodies, plugin tabs | invented `内容` tab |

Two rules apply to every surface below:

1. **Health over decoration.** A control only renders when the live Host
   actually serves the data behind it (`DshCapabilities`,
   `DshSessionView.error`, catalog `failures`); otherwise the surface is absent
   or shows an honest empty state. v2 is a parity round, not a mockup round.
2. **No new packages for these six surfaces.** `terminal_view`,
   `flutter_inappwebview`, `webview_flutter`, `file_picker`, `image_picker`,
   the preview widgets and the context ring all exist in the tree. If a slice
   believes it needs a package, that is a design error to escalate, not to add.

---

## 1. Terminal panel

### Existing assets

| asset | path:line | what it gives us |
|---|---|---|
| VT renderer | `dependencies/terminal_view` (`pubspec.yaml:153-154`) | `Terminal`, `TerminalController`, `TerminalView` — full VT100 emulation, resize callbacks, selection |
| terminal page | `lib/features/workspace/terminal/terminal_page.dart` | tab strip + key bar + pinch zoom + overflow menu; body at `:427-538`, emulator at `:508-538` |
| session manager | `lib/features/workspace/terminal/terminal_session_manager.dart` | `TerminalSessionManager` (`:246`), `open(...)` (`:308`), PTY wiring (`:380-420`): `terminal.onOutput → pty.write`, `terminal.onResize → pty.resize`, `pty.output.listen`, `pty.exitCode.then` |
| session model | `lib/features/workspace/terminal/terminal_session_manager.dart:117` | `TerminalSession{terminal, pty, mounts, cwd, targetKey, fontSize, exitCode}` |
| PTY seam | `lib/core/services/workspace/workspace_runtime.dart:133` | `PtySession{output, write, resize, exitCode, close}` — exactly the five operations the manager drives |
| runtime seam | `lib/core/services/workspace/workspace_runtime.dart:152,179` | `WorkspaceRuntime.openPty(...)`, `WorkspaceRuntimeProvider` (process-wide local runtime) |
| reusable chrome | `lib/features/workspace/terminal/widgets/terminal_tab_strip.dart:16`, `terminal_key_bar.dart:13` | multi-tab strip and mobile key bar, both keyed for tests |

### DSH wire

`terminal/*` is request/response + streams (verified list in
`client-reference.md:1226-1246`; `protocol.md:585-587`):

- `terminal/environment {agentId}` → `{cwd, maxInputBytes, maxBufferedBytes, maxCols, maxRows, scrollback}` — the shell workspace and caps.
- `terminal/create {agentId, request:{id, cols, rows, shellPath?}}` → `WebTerminalInfo`; `terminal/list {sessionId}`, `terminal/rename`, `terminal/close`, `terminal/retain`.
- `terminal/attach {agentId, id}` (mux stream) → `snapshot` frame with the full screen + `inputWindow?`, then ordered `output`, `state`, `ack` frames.
- Uplink is the only client→host stream: `{type:'write',sequence,data}` and
  `{type:'resize',sequence,cols,rows}` mux `item` frames; sequences are
  consecutive from 1; `ack` refuses with `read-only` / `not-running`; overflow
  fails the stream. `client-reference.md:1238-1246` explicitly warns that a
  faithful terminal needs a VT renderer and recommends a read-only MVP over a
  half-working shell.

The current core has **no uplink**: `DshStream` only exposes server→client
`items` (`lib/core/dsh/dsh_mux.dart:547-566`); `open` is at `:174` and `cancel`
at `:623`. There is no `sendItem`/`write` on the stream.

### Decisions

**Reuse** the renderer and the manager. The cleanest v2 shape is an adapter, not
a fork of the terminal UI:

- **New** `lib/features/harness/services/dsh_terminal_runtime.dart`:
  - `DshPtySession implements PtySession` — owns one DSH terminal
    (`terminal/create` then `terminal/attach`), converts `snapshot`+`output`
    frames to `Uint8List` for `output`, maps `state`/close to `exitCode`.
  - `DshWorkspaceRuntime implements WorkspaceRuntime` — `supportsPty = true`;
    `openPty` calls `terminal/environment` for `cwd`, creates the terminal and
    returns the adapter. `openInSystemTerminal`/`revealInFileManager` are not
    needed (no host-side equivalent for a remote terminal).
  - Agent id is the DSH **session id** (no separate agent id on this wire).
- **Reuse unchanged** `TerminalSessionManager.open(runtime: dshRuntime, ...)`,
  `TerminalSession`, `TerminalTabStrip`, `TerminalKeyBar`, the OSC-1337
  interceptor and pinch/wakelock behaviour.
- **Extend** `TerminalPage` so it can be hosted by the harness:
  - accept the runtime/manager from the harness instead of reading
    `WorkspaceRuntimeProvider` (`terminal_page.dart:432-435` currently reads the
    process-wide local runtime);
  - extract what `:427-538` builds into a **new** public
    `TerminalSurface` widget (`lib/features/workspace/terminal/widgets/terminal_surface.dart`)
    used by both `TerminalPage` (Scaffold wrapper) and an inline rail panel.
    This is a move, not a rewrite: same key bar, same emulator, same keys.
- **Extend** `HarnessRailPage.terminal` (`lib/features/harness/pages/home/harness_right_rail.dart:732-750`,
  enum at `harness_home_controller.dart:12`): the `_RailTerminalPage`
  placeholder becomes the new inline `DshTerminalPanel` (manager created
  locally, bound to the open `DshSessionHandle.sessionId`, `mounts: const []`).
  The full-screen path can stay `TerminalPage` with the overridden runtime, so
  the "new terminal" rail card and the drawer keep one implementation.
- **New** (core, small) `DshStream.sendItem(Map<String,Object?> value)` in
  `lib/core/dsh/dsh_mux.dart` so the adapter can send `write`/`resize`. The
  frame shape already exists (`{'type':'item','streamId':...,'value':...}` in
  the mux doc comment at the top of the file); nothing else needs to change.
- **Phase the input**: ship attach + render first (read-only banner, no key
  bar), then enable write/resize once a spike confirms the real frame shapes
  and sequence/ack behaviour. `terminal/attach`'s snapshot encoding is
  code-read only (`protocol.md:56-57`), so this is the honest order; a
  read-only panel beats a broken prompt. Do **not** render an editable composer
  when `ack` reports `read-only`.

### Risks

- Snapshot/output frame field names are not verified live; keep the frame
  decoder tolerant (`jsonMap`, accept `data`/`text`, ignore unknown keys) and
  treat an unknown snapshot as "attach failed" rather than a blank screen.
- `terminal/create` needs `cols/rows`; take the initial size from
  `terminal/environment` caps and the widget's first layout, then resize.
- Do not reuse the local `WorkspaceRuntimeProvider` as the source of truth for
  a remote terminal; it is the sandbox/process runtime for Cuplivo's own tools.

---

## 2. Context / token ring

### Existing assets

| asset | path:line | what it gives us |
|---|---|---|
| ring widget | `lib/shared/widgets/context_usage_ring.dart:99` (`ContextUsageRing`), painter `:49` | compact arc, warning/error thresholds, tooltip, keys |
| snapshot model | `lib/features/home/services/context_usage_service.dart:251-296` | `usedTokens`, `contextWindow`, `ratio`, `state`, `buckets`, `hasUnknownNativeTokens`; states at `:30-38` |
| details widgets | `lib/shared/widgets/context_usage_details.dart:196,281,483` | summary header, stacked bar, breakdown |
| composer insertion | `lib/features/home/widgets/chat_input_bar.dart:5647-5664` (`_ContextUsageInputControl`), rendered at `:5189-5197` | ring in the input bar, tap wired to `onOpenContextUsage` |
| service registration | `lib/main.dart:1057` | `ContextUsageService` for **local** conversations |

The ring is currently gated on a non-empty local `conversationId`
(`chat_input_bar.dart:5189-5192`) and reads `ContextUsageService?` from the
provider tree; the DSH composer passes `conversationId: null`
(`lib/features/harness/pages/chat/harness_conversation_view.dart:344-357`), so
no ring can appear today.

### DSH data

- `contextPressure` projection: `{pressureTokens, projectedTokens, contextWindow}`
  (`protocol.md:1724`, sample `{8930, 8943, 1048576}` at `protocol.md:2030`).
  This is exactly the meter's numerator and denominator.
- Session-level `tokenUsage` is a different shape (`uncachedInputTokens`,
  output, cache read/write; `lib/core/dsh/dsh_models.dart:310-338`).
- Per-step `DshTokenUsage` (`lib/core/dsh/dsh_models.dart:277-306`) is already
  mapped into `DshSessionView.usage` (`dsh_gateway_models.dart:1028-1066`).
- `contextPressure` is **not parsed anywhere yet**: grep finds no occurrence in
  `lib/core/dsh/` or `lib/features/harness/`. The raw projection map is
  available (`DshProjectionHints.values` at `dsh_models.dart:374-397`;
  `DshTranscript.projections` at `dsh_projection.dart:261`;
  `DshSessionProjections` at `dsh_models.dart:599-649`), so this is additive.
- Model title/context window: `session/modelCatalog` groups
  (`DshModelCatalog`, `dsh_gateway_models.dart:325-347`); the model id is in
  `selectedModel` (`dsh_gateway_models.dart:1058`). Note the feature `DshModel`
  (`:227-262`) currently drops `contextWindow`; the ring must take the window
  from `contextPressure`, not from the model row.

### Decisions

- **Extend** core with a small `DshContextPressure{pressureTokens,
  projectedTokens, contextWindow}` + `DshSessionProjections.contextPressure`
  getter, and **extend** `DshTranscript` with a forwarding getter. No new
  service.
- **Extend** `DshSessionView` with `DshContextPressure? contextPressure`
  (populated by `mapDshSessionView`, `dsh_client_gateway_mapping.dart:593-634`).
- **Extend** `ChatInputBar` with an explicit snapshot override (e.g.
  `ContextUsageSnapshot? contextUsageOverride`) so the harness composer can
  render the ring without a local `ContextUsageService`, and relax the
  `conversationId` gate **only** when that override is provided. The private
  `_ContextUsageInputControl` then prefers the override over the provider
  (`chat_input_bar.dart:5647-5664`).
- **Reuse** `ContextUsageRing` unchanged with a snapshot built by **new**
  `lib/features/harness/services/dsh_context_usage.dart`:
  `usedTokens = pressureTokens`, `contextWindow`,
  `state = ContextUsageState.exact` (the Host computed it),
  `buckets.history = pressureTokens` as the only truthful bucket,
  `hasUnknownNativeTokens = false`, stable synthetic `conversationId`
  (`dsh:<remoteId>:<sessionId>`), `providerKey/modelId` from the selection.
  `ratio` then works exactly as today.
- **Do not reuse** `ContextUsageBreakdown` for the tap target. DSH exposes a
  single pressure number, not Cuplivo's 12 buckets; rendering the breakdown
  would fabricate a composition. **New** small `DshContextUsageSheet` that
  reuses `ContextUsageSummaryHeader` / `ContextUsageStackedBar` with two
  segments (used vs window) and a line showing `projectedTokens` as the
  post-turn projection. If `contextPressure` is absent (older Host / projection
  not loaded), show no ring at all — never a guessed ratio.
- The model pill (`_DshComposerModelPill`, `harness_conversation_view.dart:670+`)
  already owns model display; the ring only adds the usage meter next to it.

### Tests

Widget test for the sheet with a synthetic snapshot; a mapping unit test for
`contextPressure` → `ContextUsageSnapshot`; a no-projection case asserting the
ring is absent. No terminal/WebView involvement, so these run in the normal
`flutter test` set.

---

## 3. Attachments (picker, media flow, upload state)

### Existing assets

| asset | path:line | what it gives us |
|---|---|---|
| composer media API | `lib/features/home/widgets/chat_input_bar.dart:400-460` (`addFiles`, `insertText`, `clearFiles`, `restoreInput`, `snapshotInput`) | programmatic draft media |
| picker service | `lib/features/home/services/file_upload_service.dart:26-42` constructor, `:152` photos, `:193` camera, `:315` files | gallery/camera/file picking incl. desktop `FilePicker` fallback, compression, staging into the upload dir |
| picker wiring | `lib/features/home/widgets/chat_input_bar.dart:758-760,842-844` | nullable callbacks; when null the buttons are hidden (`:3684+`) |
| draft shape | `lib/core/models/chat_input_data.dart:5-21` | `DocumentAttachment{path,fileName,mime}`, `ChatInputData{text,quotes,imagePaths,documents,...}` |
| attachment card | `lib/features/home/widgets/composer_attachment_card.dart:16-33` | metadata-only preview card (icon, name, size) |
| staged-file dedupe | `lib/utils/upload_dedupe.dart:13-36` | shared upload-dir cleanup (`deleteIfUnshared`) |
| DSH upload + fetch (core) | `lib/core/dsh/dsh_session.dart:546-578` (`uploadAttachment` returns `DshUploadReceipt`), `:580-599` (`attachmentBytes` → base64 `session/attachment`) | the two network operations the flow needs |
| DSH prompt parts (core) | `lib/core/dsh/dsh_session.dart:64-92` (`DshImageInput`, `DshFileInput`, `DshPrompt`), `:389-413` | prompt content builder: images inline base64, files as `receiptId` |
| DSH prompt seam (feature) | `lib/features/harness/state/dsh_gateway.dart:111-116`, `lib/features/harness/services/dsh_client_session_handle.dart:94-117` | `prompt(text, attachments:)`; today files only and the receipt/name/mediaType pair is defined at `dsh_gateway_models.dart:833-847` |
| limits | `lib/core/dsh/dsh_models.dart:664-699` (`DshImageLimits`), from the `imageLimits` projection | max bytes / count / pixels / media types |

### DSH wire

- `POST /api/session/uploadFileBinary?sessionId=&name=&mediaType=` — raw bytes,
  `application/octet-stream` only, bare `{ok,value:{receiptId,file|image}}`
  reply (`protocol.md:1182-1203`). With `mediaType` the receipt carries the
  staged image; without it, a file receipt.
- `session/prompt` content parts (`protocol.md:762-790`, verified live):
  `{type:'text'}`, `{type:'image', mediaType, data:<base64>, name?}`,
  `{type:'file', receiptId}`. The durable turn stores file/image attachments as
  blocks; history reads them back (`DshImagePart`/`DshFilePart`,
  `lib/core/dsh/dsh_models.dart:71-115`).
- Image base64 goes through the Host's `imageLimits` verification; a large
  image is cheaper uploaded once and referenced — but the image **prompt part**
  carries `data`, and the documented receipt reference is a `file` part
  (`protocol.md:1197-1199`). Treat receipt-referenced images as a spike, not a
  dependency.
- History images are fetched with `session/attachment` (`protocol.md:1189`),
  which the core already implements (`dsh_session.dart:580`).
- `fileUploads/upload` is the small-body RPC fallback only (`protocol.md:1201-1203`).

### Decisions

**Reuse** the picker and the draft pipeline; the DSH composer currently passes
no picker callbacks (`harness_conversation_view.dart:372-383`), which is the
only reason attachments are missing.

- **Extend** `harness_conversation_view.dart`: construct a
  `FileUploadService` bound to the existing `_draftController`
  (`harness_conversation_view.dart:344-386`), with `hasWorkspace: () => true`
  (the Host accepts arbitrary files; the local workspace gate does not apply)
  and `getContext: () => context`; pass `onPickPhotos`, `onPickCamera`,
  `onUploadFiles`. Desktop drag/drop can reuse
  `FileUploadService.onFilesDroppedDesktop` in the same slice.
- **Reuse** `ComposerAttachmentCard` for staged files; **extend** it with an
  optional upload `status` (`queued/uploading/failed`) + `progress` used only
  on the DSH path, so a file that failed to upload is visible before send
  instead of surfacing as a generic send failure. Image tiles already show
  draft compression state; upload state reuses the same layered badge pattern.
- **Extend** `DshSessionHandle` with
  `Future<DshUploadReceipt> uploadAttachment(Uint8List bytes, {String? name, String? mediaType})`
  and add a thin passthrough on `DshSessionStore` (core; the method exists on
  `DshSession` at `dsh_session.dart:546`). Feature implementation calls
  `_store.session.uploadAttachment` or the store wrapper.
- **Extend** `DshPromptAttachment` with `kind` (`file`/`image`) and wire the
  handle's `prompt` to build **new** `DshPrompt` parts:
  - files: upload on send, then `DshFileInput(receiptId)`;
  - images: inline `DshImageInput(bytes, mediaType, name)` (verified shape),
    with the existing image compression/downscale pipeline ensuring
    `imageLimits`; only fall back to the upload receipt (as a `file` part) when
    the image exceeds the inline size and a spike confirms the Host accepts it.
- **New** `lib/features/harness/services/dsh_attachment_upload_service.dart`:
  reads staged paths, uploads sequentially with per-file status, enforces
  `DshImageLimits` for images and the Host's documented body cap for files, and
  returns prompt parts. It is the one choke point for "what goes on the wire"
  (no duplicate upload logic in the composer).
- **Extend** `DshComposerSubmission.submitWithReason`
  (`lib/features/harness/controllers/dsh_composer_submission.dart:45`): build
  `DshPromptAttachment`s from `input.documents`/`input.imagePaths`, call the
  upload service, then `session.prompt`. A rejected prompt keeps the draft
  (existing contract, `submitWithReason` doc at `:17-31`): leave the staged
  local files in the draft and re-upload on retry. Upload receipts are tied to
  the session, so they are not carried across a failed send; attachments are
  never cleared by a rejection.
- **Extend** the transcript read path so sent media is visible:
  `DshUserEntry.attachments` is already mapped
  (`dsh_client_gateway_mapping.dart:500-531`) but dropped when the chat item is
  built (`lib/features/harness/controllers/dsh_gateway_chat_session.dart:157-165`)
  and when the transcript is folded (`dsh_transcript_fold.dart:126-137` builds
  `TextPart` only). Add attachments to `DshUserMessageItem`
  (`dsh_chat_session.dart:528-544`), fold them into `ImagePart`/`FilePart`
  (`lib/core/models/message_part.dart:232-330`) with a `dsh://attachment/<id>`
  uri, and add a **new** authenticated image provider/widget that calls
  `session/attachment` through the handle (core `attachmentBytes`) and caches
  bytes; file chips reuse the existing `FilePart` row and show no open action
  unless bytes are available.
- **Drop** nothing in the picker flow; the only removal is the old assumption
  that the DSH send path is text-only.

### State and limits

- Send is disabled while uploads are in flight (existing `loading`/
  `state.busy` pattern in `harness_conversation_view.dart:376-383`).
- Reject images over `DshImageLimits` (`maxImageBytes`, `maxImagesPerMessage`,
  `maxMessageImageBytes`, `maxImageDimension`) with a specific message before
  upload; apply the Host's documented body cap to files instead of hardcoding a
  number (`protocol.md:346-348`).
- Staged local files are owned by the draft; on remove/clear they go through
  `UploadDedupe.deleteIfUnshared` (same as local conversations).
- l10n: new strings for upload states/errors/attachment chips; all four
  non-English locales via the existing `translate.py` pipeline.

### Tests

Controller/key-less unit tests for the attachment service (limits, ordering,
file vs image part), widget test for the card status, and a fold test asserting
that a user entry with one image + one file produces `ImagePart` + `FilePart`.

---

## 4. Embedded WebView infrastructure

### Existing assets

| asset | path:line | what it gives us |
|---|---|---|
| DSH WebView host page | `lib/features/harness/pages/plugins/dsh_plugin_web_page.dart` | full-page host for the official WebUI |
| cookie split | same file `:24-53` (`DshWebViewCookie.parse`) | turns the stored `name=value` browser cookie into what the jar needs; value never in `toString` |
| failure taxonomy | same file `:56-57` (`unsupported/unauthorized/network`) | honest 401/403/offline states |
| page contract doc | same file `:59-106` | protocol has **no per-plugin URL**; loads `http(s)://<authority>/`; v2 API cookie must never be injected; 401 means reconnect |
| preparation | same file `:114-153` (`_platformSupported`, `_prepare`) | platform guard (no Linux), desktop WebView2/WKWebView environment creation |
| cookie injection | same file `:155-184` | host-only cookie for IP literals, path `/`, strict SameSite; best-effort |
| load/lifecycle | same file `:187-244` | `_onLoadStart/_onLoadStop/_onReceivedError/_onReceivedHttpError` → failure states, generation-keyed retry |
| build | same file `:246-345` | Scaffold + AppBar + honesty note + `InAppWebView` + loading overlay; states at `:311-462` |
| call site | `lib/features/home/pages/home_page.dart:1268-1305` | opens the host for 插件 / 自动化任务, cookie from `SecureDshCredentialStore.readCookie` (`lib/features/harness/services/dsh_credential_store.dart:9,44`) |
| JS/evaluate precedent | `dsh_plugin_web_page.dart:96-107,206-216` (one-shot `initialScript` after load), `lib/core/services/browser/browser_native_engine.dart:408-470` (`addJavaScriptHandler` channels), `:162,569,672` (`evaluateJavascript`) | the two directions of JS work exist in the repo, but on different stacks |
| alternate stack | `lib/shared/pages/webview_page.dart:1-120` (`webview_flutter` + `JavaScriptChannel`), `lib/features/workspace/widgets/preview/html_file_preview.dart` | inline WebView precedent; keep `flutter_inappwebview` for DSH (cookie manager + desktop environment are already solved there) |

### Decisions

**Extend, don't fork.** The page's body is already the embeddable part:

- **New** `lib/features/harness/widgets/dsh_web_ui_view.dart`: extract
  `DshPluginWebPage`'s body (`:311-345` + the failure/loading/state widgets and
  `_injectCookie`/`_prepare`) into a standalone `DshWebUiView`
  (`remote`, `cookie`, `initialUrl`, `initialScript`, `onRequestReconnect`,
  `showHonestyNote`). `DshPluginWebPage` keeps its Scaffold/AppBar and mounts
  the extracted widget; the settings tab and any future rail panel mount the
  same widget. Behaviour (generation key, cookie jar, 401/403 taxonomy) must
  not be re-implemented in the new host.
- **Extend** the extracted widget with an `initialUrl` (default
  `remote.baseUrl`) so file previews can point it at an authenticated
  `/api/file?path=…` URL (section 5) without a second cookie/load
  implementation.
- **Reuse** `DshWebViewCookie` and the `SecureDshCredentialStore` read; the
  WebView never receives the v2 API cookie and never gets the launch token.
- **New** (only when a landing script is actually needed) a tiny JS asset per
  landing target under `assets/dsh/landing/` executed through `initialScript`,
  using accessible-name label lists (`client-reference.md:1822-1856`). Landing
  is best-effort: if the script fails, the view stays on the official page the
  user can navigate by hand; never an error dialog. Do not try to read data out
  of the DOM (`client-reference.md:1844-1851`). JS channels (`addJavaScriptHandler`)
  stay unused until a landing script needs a result — the current one-shot
  script needs none.
- **Inline hosting decision**: the settings tab hosts `DshWebUiView` inline
  (full pane width, official settings page). The right rail **does not** embed
  the WebUI: at rail width the official page is cramped and a native platform
  view inside an expanding rail is a layout/leak risk; plugin/automation rail
  cards keep opening the full page (`DshPluginWebPage`) as today. This matches
  the docs' honest MVP (`client-reference.md:1124-1140`, `:2505-2507`).
- **Platform policy** stays as coded at `dsh_plugin_web_page.dart:114-124`:
  Android/iOS/macOS/Windows supported; Linux (and web) show the unsupported
  state. A caller must not build `InAppWebView` on an unsupported platform to
  "see if it works".

### Tab/rail hosting rules

- **Native views and tab switching**: `IndexedStack` builds every child, and
  the settings page uses one (`dsh_assistant_settings_page.dart:156-180`). A
  hidden WebView would be created for every non-active tab. Keep
  `IndexedStack` for the tab transition but give every WebView tab a
  `SizedBox.shrink()` child while it is not active (or mount only the active
  body); the native tabs are catalog-backed and can rebuild.
- One cookie jar per host authority, which `CookieManager` already gives us;
  two remotes on different authorities do not collide.
- Retry after 401 is `onRequestReconnect` → assistant connect settings, the
  existing path (`home_page.dart:1293-1305`).

### Tests

Widget tests for the extracted view's failure/loading states with a fake
controller factory are possible only with a platform view; the shipped test
suite instead covers `DshWebViewCookie.parse` (pure) and the failure-state
widgets. E2E covers the real page on the e2e-vps Host (the plugin panel check
already exists in `docs/cuplivo-dsh/e2e-scenario.md`).

---

## 5. File preview components and fallback policy

### Existing assets

| asset | path:line | what it gives us |
|---|---|---|
| dispatcher | `lib/features/workspace/widgets/preview/file_preview.dart` | `classifyFilePreview` (`:49-59`), UTF-8 sniff (`:61-78`), `showFilePreview` (`:87+`), `buildFilePreviewBody` (`:159-178`), `FilePreviewFrame` (`:261+`) |
| kinds | `file_preview.dart:47` | `image / markdown / html / csv / code / binary`; **no PDF kind** |
| type identity | `lib/features/workspace/widgets/preview/preview_file_type.dart` | extension sets, icon+tint per family (`PreviewFileTypeStyle`, archive/audio/video/font styles) |
| widgets | `lib/features/workspace/widgets/preview/`: `image_file_preview.dart:20`, `markdown_file_preview.dart:18`, `code_file_preview.dart:43`, `csv_file_preview.dart:19`, `html_file_preview.dart:14`, `binary_file_preview.dart:19` | all render from a local `File` |
| rail inline preview | `lib/features/harness/pages/home/harness_right_rail.dart:483-500` | the rail already previews text and images inline through `HarnessWorkspaceFiles` |
| remote file seam | `lib/features/harness/pages/home/harness_session_catalog.dart:145-154` | `list`, `readText`, `readBytes` |
| gateway file API | `lib/features/harness/state/dsh_gateway.dart:81-91` | `listFiles`, `readTextFile`, `statFile`, `readFileBytes` |
| gateway impl | `lib/features/harness/services/dsh_client_gateway.dart:381-410` | `statFile` mapped; `readFileBytes` **throws unsupported** because `workspaceFiles/readBytes` is a multipart binary response the core transport cannot decode |
| PDF capability | `pubspec.yaml:99,104` (`syncfusion_flutter_pdf`, `pdf`) | writing/generating only — no PDF viewer anywhere in the repo |

### DSH wire

- `workspaceFiles/stat {workspaceFileScopeId, path}` → `{absolutePath, version, bytes?}`
  (`protocol.md:1167`); `read` returns a text page (`:1168`); `readBytes` is
  multipart (`:1169`, `:300-310`).
- `GET /api/file?path=<absolute path>[&v=<version>]` — cookie-authenticated
  bytes, 302 to a versioned cacheable URL, 403 for directories, 400 for
  relative paths; explicitly documented as the workspace-file-preview route
  (`protocol.md:1205-1213`).
- `officeToPdf/render` is out of scope (`client-reference.md:1221-1224`).
- Errors are the `workspace-file/*` family (`protocol.md:1172-1176`), mapped by
  the existing failure text helper.

### Decision per kind

| kind | source | rendering | fallback |
|---|---|---|---|
| text / code / csv | `workspaceFiles/read` text page | **Reuse** `CodeFilePreview` / `CsvFilePreview` via cache materialization (below); the rail keeps its inline text preview | error row + metadata card |
| markdown | `workspaceFiles/read` | **Reuse** `MarkdownFilePreview` via cache materialization; note relative images inside a remote markdown won't resolve locally — acceptable for v2, documented | metadata card |
| image | `/api/file?path=` or `workspaceFiles/readBytes` | **Reuse** `ImageFilePreview` after bytes are materialized; if native bytes are unavailable, full-screen `DshWebUiView` on the `/api/file` URL (same cookie) | metadata card |
| pdf | `/api/file?path=&v=` | **New** `DshFilePreviewPage` embedding `DshWebUiView` on that URL (the "DSH preview panel in a WebView") | metadata card (see below) |
| html/svg | `workspaceFiles/read` | **Reuse** `HtmlFilePreview` (already WebView-based) on a cache file | code preview |
| office (docx/xlsx/pptx) | `/api/file` | raw bytes cannot render in a WebView; v2 does not add a renderer | metadata card with an honest "此类型暂不支持预览" |
| unknown binary | `stat` only | none | **New** `DshRemoteFileCard` |

Implementation details for that table:

- **New** `lib/features/harness/services/dsh_preview_cache.dart`: materializes
  remote text/bytes into a per-remote cache directory (bounded, cleaned by the
  existing temp/cache policy) so every existing `File`-based preview widget is
  reusable unchanged. This is the cheapest path to parity and keeps one
  renderer per kind; do not fork the previews to accept bytes.
- **New** `lib/features/harness/widgets/dsh_remote_file_card.dart`: the honest
  fallback for every kind whose bytes are missing/too large or whose WebView is
  unsupported. It must **reuse** `PreviewFileTypeStyle` and `formatBytes` for
  the icon/size look, and show name + size + a reason ("无法预览" distinguishable
  from "加载失败"), not a fake preview.
- **Extend** `DshFileStat` (`dsh_gateway_models.dart:1090`) with
  `absolutePath` and `version`; `mapWorkspaceFileStat` already receives the
  raw map, so this is a two-field addition. The WebView URL is built with the
  existing `DshEndpoint.fileUri` (`lib/core/dsh/dsh_endpoint.dart:219-224`),
  never string-concatenated by hand.
- **Extend** `readFileBytes` (`dsh_client_gateway.dart:398-410`) to use the
  `/api/file` GET (`DshTransport.get`, `lib/core/dsh/dsh_transport.dart:263,397`)
  instead of the undecodable multipart RPC — text/image previews then need no
  WebView at all. **Spike required**: confirm `/api/file` accepts the API
  transport's credential (the WebView path uses the v1 browser cookie; the
  native transport holds the v2 API cookie — `protocol.md:73-79`). If the spike
  fails, keep the WebView path for images and leave the rail's current
  text-only fallback.
- **Fallback policy** (applies to all kinds, in order): unsupported platform →
  card; missing/relative stat → card with "文件不存在"; oversize → card with
  size; 401 → reconnect action; load error/timeout → card + retry; **never** a
  blank pane. The card is also the v2 answer for PDF on Android if the system
  WebView refuses to render it (Android WebView PDF support is device
  dependent): try the WebView, detect a failed/blank load, fall back to the
  card. Do not add a PDF package to fix this.
- **Full-screen surface**: **New** `lib/features/harness/pages/preview/dsh_file_preview_page.dart`
  with a Scaffold/AppBar and a switch over kind → existing preview body /
  `DshWebUiView` full-pane / `DshRemoteFileCard`. Keep it out of
  `lib/features/workspace/` (that tree is the local workspace surface and its
  runtime assumptions do not hold for a remote file).
- The rail entry point: tapping a file in `_RailWorkspaceFilesPage` opens the
  full-screen page for binary kinds; text/image stay inline (existing rail
  previews), with a "open in full page" affordance where the content is
  truncated.

### Tests

`classifyFilePreview`/`fileSniffsAsUtf8Text` already have unit coverage; add
unit tests for the URL builder (`stat` → `fileUri`) and a widget test for the
fallback card's four reasons. WebView rendering is E2E-only.

---

## 6. Settings tab architecture and dynamic tabs

### Existing architecture

`lib/features/harness/pages/assistant/dsh_assistant_settings_page.dart` is a
single 904-line page that owns both the connection form and the tab shell:

- tab state: `int _tab = 0;` (`:55`);
- tab strip: `_DshSettingsTabStrip` (`:579-633`), labels passed as a literal
  list (`:143-151`): `连接设置 / 通用设置 / 模型 / 内容`;
- bodies: `IndexedStack(index: _tab)` (`:156-180`) with connection/general
  builders, `DshModelsTabBody` (`:164-170`, model body at
  `lib/features/harness/pages/assistant/models/dsh_models_tab_body.dart:151`)
  and `_PlaceholderTab` (`:176-181`, widget at `:726-773`);
- test keys: strip `Key('dsh-settings-tabs')` (`:144`), models tab
  `Key('dsh-models-tab')` via a **positional** `_tabKeys` list (`:591-596`).
- the fourth tab `内容` and its placeholder are invented; the ARB keys
  (`lib/l10n/app_en.arb:24485-24526`: `dshTabContent`, `dshContentPlaceholder`)
  describe filler that never had a protocol source.

Native DSH tabs are `通用设置 / 模型 / 内置插件 / Agent 预设 / 账号与余额 /
工作区文件` plus plugin-registered tabs (`client-reference.md:1829-1831`). v2
mirrors the first four plus plugin tabs; 账号与余额 and 工作区文件 stay out of
this round (they are native surfaces with their own tasks), and 连接设置 stays
the first tab because it is Cuplivo's connect/owner surface, not a DSH tab.

### Data source per tab

| tab | source | status |
|---|---|---|
| 连接设置 | local connection record + `DshLinkStatus` | exists today |
| 通用设置 | `catalog.generalSettings` (`DshCatalogSnapshot.generalSettings`, `dsh_gateway_models.dart:603-631`), written through `updateGeneralSettings` (`dsh_gateway.dart:60-61`) | exists today |
| 模型 | `DshModelsTabBody` + `DshProviderSettingsGateway` | exists today (R9–R11) |
| 内置插件 | `catalog.plugins` (`dsh_gateway_models.dart:610,626`), mapped from `pluginInventory/list` (`dsh_client_gateway_mapping.dart:196-210,315-317`); core read methods `loadPluginInventory`/`listPluginBundles`/`listPlugins` (`lib/core/dsh/dsh_catalog.dart:619,628,639`); enable/disable via `setBundleEnabled`/`setPluginEnabled` (`dsh_catalog.dart:648-672`) | read model exists; **no gateway methods / no UI yet** |
| Agent 预设 | `pluginInventory/list` optional `agentPresets` groups (`DshPluginInventory.agentPresets`, `dsh_models.dart:1532-1556`; `DshAgentPresetPluginGroup` `:1500-1529`), `agentPresets/list` (`protocol.md:1422`, not implemented in core), `agent-preset-registry` settings namespace (`protocol.md:961`) | model exists for inventory groups; RPCs missing |
| plugin tabs | no protocol enumeration — see below | **new**, best-effort |

### Dynamic tab architecture

The page must stop hardcoding a four-element list and stop keying tabs by
position. Concrete design:

- **New** `lib/features/harness/pages/assistant/dsh_settings_tabs.dart`:
  ```dart
  @immutable
  class DshSettingsTabSpec {
    const DshSettingsTabSpec({
      required this.id,        // stable: 'connection', 'general', 'models',
                               // 'plugins', 'agentPresets', 'plugin:<entryId>'
      required this.label,     // localized display label
      required this.body,      // WidgetBuilder
      this.key,                // test key, e.g. Key('dsh-models-tab')
    });
    ...
  }
  ```
  The page assembles the list from a **label list + body registry**, not from a
  widget tree: native specs are built in order; plugin specs are appended from
  the inventory. A tab whose data source is unavailable is simply not in the
  list (`DshCapabilities`/catalog `failures` decide), so the strip never shows
  a dead tab.
- **Extend** the existing strip into a public `DshSettingsTabStrip`
  (`lib/features/harness/widgets/dsh_settings_tab_strip.dart`) that takes
  `List<DshSettingsTabSpec>` + `activeId` + `onChanged`; keys become
  `ValueKey('dsh-settings-tab-<id>')` and the models spec keeps its existing
  `Key('dsh-models-tab')` so R9–R11 tests and e2e anchors survive. Reuse the
  current `_TabButton` styling/selection animation verbatim (`:635-725`) — the
  strip is a split-out, not a redesign.
- **Extend** the page state from `int _tab` to `String _tabId`; on catalog
  refresh, if the active id disappeared (plugin disabled/removed) fall back to
  `general` instead of an empty pane.
- **Extend** `IndexedStack` to keep the children slice but with
  `spec.id == activeId ? spec.body : SizedBox.shrink()` for WebView specs (see
  section 4's native-view rule); pure-Flutter specs can be passed directly.
- **Drop** `_PlaceholderTab` from the tab bodies. A tab whose data source is
  unavailable is not in the spec list at all, so there is nothing to place-hold.
  The widget may survive only as a small empty-state *inside* a rendered tab
  (e.g. "此 Host 没有暴露内置插件列表"). Delete the invented `内容` tab and
  its ARB keys.

### Plugin tabs (best-effort, bounded)

There is no protocol list of settings tabs. The two verified sources are:

- `pluginInventory/list` entries: `entryId`, `moduleName`,
  `meta.title{en,zh,…}`, `enabled`, `fiberPhase`, `diagnostic` — package
  metadata, **not** a settings page or label (`protocol.md:1315-1321`).
- the official page itself: a tab exists only as DOM (`client-reference.md:1822-1856`);
  the docs' honest MVP is one Flutter tab whose body is the official settings
  page, with per-plugin tabs as best-effort DOM landing.

Decision for v2: build the tab **labels** from enabled inventory entries whose
`meta.title` is non-empty (`entryId` in the id, localized `meta.title` used
verbatim — plugin metadata is authored in the plugin, so no Cuplivo l10n key),
appended after the four native tabs and capped (e.g. 8) to keep the strip
usable. Each body is `DshWebUiView` on the official WebUI with a one-shot
landing script that clicks the matching settings-tab label (label list =
inventory title plus the localized official labels already documented for
通用设置/模型/内置插件/Agent 预设). If landing fails, the view shows the
official settings root and the user finishes by hand. `pluginInventory/list`
absent or empty → **no plugin tabs** (not a single fake "插件设置" tab): v2
parity means mirroring what the Host reports, and a generic second
WebUI-only tab would duplicate the sidebar's 插件 entry with no added value.
The previous `内容` placeholder is dropped, not repurposed.

- **New** body widgets: `plugins` tab (`DshPluginsTabBody`) = native rows from
  `catalog.plugins` (enabled state, phase, diagnostic) + toggles/restart
  banner; `agentPresets` tab = `DshAgentPresetsTabBody` = preset groups with
  row summaries (read via `pluginInventory.agentPresets`), selection only if
  the `agentPresets/select` RPC is added (optional for v2; read-only otherwise).
- **Extend** `DshCatalogSnapshot`/mapping only if `agentPresets` groups are not
  already mapped into the feature snapshot (today the feature gateway maps
  inventory `entries` only, `dsh_client_gateway_mapping.dart:315-317`);
  `DshCatalogSnapshot` has no `agentPresets` field yet. Add the mapping and a
  `DshAgentPresetGroup` feature model.
- **Extend** `DshGateway` + adapter with `setPluginEnabled` /
  `setBundleEnabled` and map `DshPluginChangeResult.application` to the
  "需要重启 DSH 生效" banner (same rule as `client-reference.md:1101`); feature
  detection hides the controls when `managementAvailable == false`.
- **New** core RPCs for the Agent preset tab: `agentPresets/list` (and
  `read`/`select` only if the tab is interactive). The core has no methods for
  them today.

### l10n and tests

- Remove `dshTabContent`, `dshContentPlaceholder` and add
  `dshTabPlugins`, `dshTabAgentPresets` plus the two bodies' strings; run the
  four-locale `translate.py` sync and `flutter gen-l10n` as usual (generated
  files untouched by hand).
- Widget tests (extend `test/features/harness/dsh_assistant_settings_page_test.dart`):
  strip builds exactly the specs given; no `内容` tab; models key still resolves
  at its new id; active-tab fallback when a plugin disappears;
  `DshPluginsTabBody` rows and restart banner; `DshAgentPresetsTabBody` groups.
- E2E scenario (`docs/cuplivo-dsh/e2e-scenario.md`) R2 anchors move from four
  fixed tabs to the dynamic set; update selectors to
  `dsh-settings-tab-<id>` while keeping the `dsh-settings-tabs` container key.

---

## Adjacent v2 surfaces (not mapped in detail here)

These belong to the same round but were outside this map's six surfaces; the
seams found during the survey are recorded so the next task starts from them:

- **Sidebar plugin rows (R5)**: `DshSideBar` hardcodes three entries via
  `enum DshSidebarEntry` (`lib/features/harness/widgets/dsh_side_bar.dart:16,133-160`);
  make the row list data-driven (spec list + key per id), as with settings
  tabs. The catalog already carries `plugins`, so no new RPC is needed.
- **Rail plugin entries (R7)**: `HarnessRailExtraEntry` already exists
  (`harness_right_rail.dart:18-33`, section at `:263-276`) and is generic;
  the closed `HarnessRailPage` enum (`harness_home_controller.dart:12`) is the
  only thing blocking per-plugin rail pages — extend it to an id-based page
  selector rather than adding enum members per plugin.
- **Composer plus menu / tool cards**: `dsh_plus_sheet.dart`
  (`lib/features/harness/widgets/chat/dsh_plus_sheet.dart`) and the catalog's
  `commands`/`skills` (`dsh_gateway_models.dart:611-628`) are the sources; the
  transcript's tool cards already render from real `DshToolEntry` rows
  (`dsh_transcript_fold.dart:96-107`, `_mapTool` at
  `dsh_gateway_chat_session.dart:226+`), so v2's "tool cards from real runs"
  is already satisfied and should not be rebuilt.

## Open questions / spikes before implementation

1. **`terminal/attach` frame shapes** (snapshot encoding, `state`, `ack`
   semantics) — code-read only; run one live attach against the e2e-vps Host
   before writing the adapter. Gate write/resize behind the result.
2. **Mux uplink** — `DshStream.sendItem` does not exist; confirm the reference
   frame envelope (`type:'item'` with `value`) against the Host before relying
   on `write`/`resize`.
3. **`/api/file` credential** — does the native API transport's cookie get
   bytes, or is only the WebView v1 cookie accepted? Decides whether native
   image preview needs a WebView at all (section 5).
4. **Receipt-referenced images in prompts** — verified shape is inline
   base64; confirm or drop the "upload large image, reference receipt" path.
5. **PDF in Android WebView** — device-dependent; keep the metadata-card
   fallback, no new renderer package.
6. **Plugin settings-tab labels** — inventory `meta.title` is metadata, not a
   settings tab name; treat landings as best-effort and always leave the page
   usable.
7. **`contextPressure` absence** — if a Host/projection does not expose it, the
   ring is hidden; do not estimate from `tokenUsage`.
