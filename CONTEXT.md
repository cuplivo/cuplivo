# Cuplivo Context

Domain language for this repository. Terms here are decision-bearing: an ADR or a code comment that
contradicts one of them is a bug, not a preference.

## Project lineage (项目血脉)

- **Kelivo**: the upstream project (`Chevey339/kelivo`) this app is a fork of. Versions are its
  own (`v1.3.0`); the name legitimately appears in attribution, interop terms and external URLs.
- **Cuplivo 3.x**: the archived fork line (terminal release v3.2.1), source of the identity values
  and boundary decisions this line inherits.
- **Cuplivo 4.0 / `cuplivo-4-0`**: this line — a re-baseline on Kelivo v1.3.0 with the Cuplivo
  identity, version `4.0.0+`.
- **Legacy K/C data**: data produced by either lineage (Kelivo installs, Cuplivo 3.x backups).
  Both must keep resolving on import; see Identity below.

## Branding & Naming Boundary (品牌与命名边界) — ADR-0001, ADR-0029

- **Renamed surfaces (已更名面)**: everything a user or a third party can see or receive —
  application id / bundle ids / app groups, app and window titles, notification strings and channel
  names, notification/thread ids, about-page text, share-extension text, HTTP `User-Agent`,
  OpenRouter `X-OpenRouter-Title` + referer, MCP client name, OS-registered URL schemes, and
  downloaded/temporary file prefixes (`cuplivo_tts_`, `cuplivo-table-`, `cuplivo-mermaid-`, export
  and preview temp files).
- **Legacy Kelivo surfaces (旧名保留面)**: names kept on purpose because they are protocol,
  persistence, or external-infrastructure identity, and renaming them breaks data or model-facing
  behavior:
  - `kelivo_*` MCP tool names and `@kelivo/*` server ids — persisted in assistant config and
    recorded in tool events and conversation history.
  - `kelivo://` content links (`workspace`, `chat`, `session`, `skills`, `tmp`, `mounts`,
    `terminal`) — emitted to models, stored in messages, parsed by the file-link resolver.
  - `kelivo-file://` attachment URIs — the wire form stored in messages and backups.
  - `KelivoOpenURL` — the OSC 1337 marker the guest shell emits and the terminal strips.
  - `kelivo_backups`, `kelivo.db`, `kelivo.restore-*`, `.kelivo_restore`, `kelivo-schedule`,
    `kelivo_background` and other persisted keys/format ids.
  - `kelivo.psycheas.top`, `search.psycheas.top`, `afdian.com/a/kelivo`, `kelivo-helper` — external
    infrastructure Cuplivo does not control.
  - `KelivoImageSettingsMapper` and "Kelivo backup" interop terms — they describe the upstream
    project, which still exists.
  - Internal identifiers: `KelivoFileUri`, `KelivoApplication`, `KelivoISH*`,
    `kelivo_fetch/`, isolate/queue labels, guest-side script and path names
    (`kelivo-open`, `.kelivo-ish-build`, `/run/kelivo/...`).
- **Rule of thumb**: if a third party or a stored payload can observe the string, rename it; if it
  is a key into stored data or a name on the wire between two processes, keep it.

## Identity (身份)

- **App scheme vs content scheme**: OS-registered deep links use `cuplivo` (MCP OAuth callback uses
  the current application id); the `kelivo://` namespace is content, never registered with the OS.
- **Side-by-side installs**: the applicationId differs from both Kelivo and Cuplivo 3.x, so
  installs coexist and never overwrite each other. Data migration is therefore *not* implemented;
  restoring a backup is the supported path between them.
- **Legacy bundle ids**: the `kelivo-file://` whitelist accepts `com.psyche.kelivo`,
  `psyche.kelivo`, `com.cup11.cuplivo` and `com.cuplivo.cuplivo`, and the Windows `AppData` vendor
  prefixes `com.psyche` / `com.cup11` / `com.cuplivo`, so backups and absolute paths recorded by
  either lineage keep resolving.

## Input Draft Persistence (输入草稿跨重启保留)

- **Draft (草稿)**: the normal chat composer's unsent content — text, image paths and document
  attachments. Persisted as one JSON blob under the single global key `chat_draft_v1`
  (`chatInputDraftPrefsKey`), in classic `SharedPreferences`. Deliberately **not** per-conversation:
  the composer's content is shared across conversations, so the draft is too.
- **Owner**: `InputDraftPersistence` (`lib/features/home/services/input_draft_persistence.dart`) —
  800 ms debounced writes, immediate flush when the app leaves `resumed`, immediate removal on
  clear. The input bar (`_ChatInputBarState`) mirrors the draft at all times: every text-controller
  change and every media mutation re-schedules a save.
- **Preload, not lazy read**: `ensureInitialized()` runs in `main()` before `runApp`, so the restore
  at input-bar mount is synchronous and race-free — user input cannot precede it, and therefore no
  overwrite-confirm dialog exists. Restore is consumed **once per process**
  (`takeDraftForRestore()`); a later remount (layout switch, desktop window recreate) is not a cold
  start and never re-restores.
- **Clear semantics**: `sent` clears immediately (the content is durable in the conversation). At
  submit time the composer is emptied and the draft is set to a **safety copy of what was handed to
  `onSend`** — the only way a draft can hold the submitted text, since a snapshot derived from the
  emptied composer would keep the media and drop the text. That copy is what a process death during
  the send leaves behind: the user's message comes back as input rather than disappearing (with the
  accepted consequence that a message the server already accepted may be sent twice). `rejected`
  re-syncs the draft with the composer after the attachments are restored. `queued` **keeps** the
  safety copy, because the send queue is memory-only and the draft is then the queue's only durable
  copy; the copy is dropped when the queued input actually drains into the conversation
  (`HomeViewModel.onQueuedInputDrained` → `ChatInputBarController.clearPersistedDraft()`), and kept
  when a drain attempt fails and re-queues. Fully empty content (whitespace-only text counts as
  empty) removes the key rather than storing an empty blob. Best-effort guarantee only: the prefs
  write is async fire-and-forget, so a kill inside the platform-channel window can still leave a
  stale key.
- **Bounded payload**: a draft is encoded and checked against `InputDraftPersistence.maxEncodedLength`
  (256 KB). Past that bound the non-local image paths are dropped first (a `data:` image URI carries
  a whole base64 blob, and the platform reads and writes the preference store as one value); a draft
  that still exceeds it is not persisted at all, and the key is removed rather than left holding an
  older draft that no longer mirrors the composer.
- **Cancelled dictation never wins**: the draft service is registered before the composer, so on
  `paused` its lifecycle flush runs while a partial transcript is still in the composer. Cancelling
  the voice session therefore re-schedules and flushes the restored pre-dictation value in the same
  synchronous dispatch, so a suspend cannot persist a transcript the user cancelled.
- **Local-only, by registry**: the key is listed in `BusinessKeyRegistry.localOnlyKeys`
  (`lib/core/database/business_settings_router.dart`). This is load-bearing, not cosmetic: the
  legacy-prefs → SQLite business migration deletes every key it does not classify as `localOnly`,
  so an unregistered key would be swept out of `SharedPreferences` on the next launch; the same
  disposition also keeps the draft out of settings export/merge. Because the draft is stored in
  raw `SharedPreferences`, its owner is also registered in the frozen allowlist of
  `test/business_shared_preferences_static_gate_test.dart` — the second, deliberate registration
  point for any new device-local store.
- **Restore filtering**: media paths are resolved through `SandboxPathResolver` (sandbox container
  paths shift between launches) and dropped when the file no longer exists; a draft whose text is
  blank and whose media is entirely gone is discarded instead of restoring an empty bar.
- **Storage delete guardrail**: deleting composer-referenced uploads from the storage manager warns
  (never blocks) via `storageSpaceDeleteDraftWarning`, using `draftReferencedFiles()` — the union of
  the pending and persisted draft's files — and `countDraftReferencedPaths()`, which compares paths
  with `p.equals` because a restored draft carries separator-normalized paths while the storage
  listing keeps the OS-native form (a raw string comparison never matches on Windows).

## Community channels (社区入口)

- **Cuplivo QQ group**: `1101061750` — `https://qm.qq.com/q/9Rnnf7XyNO` (the only QQ entry).
- **Cuplivo Discord**: `https://discord.gg/kaTf8CXG4`.
- Upstream Kelivo's community channels are not listed in the app.

## Image Compression (图片压缩) — ADR-0002

- **Compression mode (压缩模式)**: one mutually exclusive stance for how attached images are handled,
  chosen in settings.
  - **auto (自动)**: every attached image is re-encoded at attach time with the configured preset.
  - **manual (手动)**: attachments are kept as pristine originals and the compress editor is the only
    compression surface. This is the default.
  - **off (关闭)**: attachments stay pristine and no compression UI is offered at all.
- **Original (原图)**: an attachment whose bytes are exactly what the picker handed over, before any
  re-encode. It is also the third choice in the editor's format control, meaning "keep this image as it
  is" — the escape hatch that makes per-image skipping explicit instead of inferred.
- **Format (格式)**: the output encoding the user picks — JPEG (lossy, has 质量) or PNG (lossless, no
  质量). WebP is never produced: some providers reject it.
- **Long edge (长边)**: the target size of the image's longest side. It only ever shrinks.
- **Quality (质量)**: 30-100 lossy strength, meaningful for JPEG only — the editor's slider
  floor is 30, and the stored value is clamped to the same range.
- **Savings (节省)**: (original bytes − result bytes) / original bytes, shown as an estimate before the
  user commits. The estimate row reads as two sides — resolution above size on each side — with the
  change above an arrow between them. A PNG of a photo can legitimately grow, and the estimate says so
  before the apply by showing that growth (a `+N%` warning tone) instead of hiding it.
- **Split compare (分屏对比)**: the editor body's 1:1 comparison — the original on the left of a
  draggable divider, the current parameters' result on the right, over the region on screen. The image
  is letterboxed inside the preview area at its own aspect ratio, never stretched or cropped to fill
  it; 1:1 means one image pixel per logical pixel, and the fit state shows the whole image. A result
  tile is drawn only while it belongs to the parameters currently selected, so changing a parameter
  never leaves a stale encode on screen. The decoded cache behind the comparison is bounded in both
  dimensions, which keeps memory and the per-tick crop proportional to what can be displayed.
- **Apply to all (应用到全部)**: broadcasts the editor's current parameters to every attached image.
- **Remembered parameters (记住的参数)**: the last parameters the user confirmed in the editor — 原图
  included — which seed the next editor session. A long edge remembered from a larger image is
  normalised to the image being edited, so the panel's readout always equals what will be applied.
- **Draft-owned copy (草稿自有副本)**: a stored copy the draft itself created. It is released when the
  chip is dropped from the composer, but never once the attachment has been submitted: a persisted
  message may reference it.
- **Compressed file naming (压缩产物命名)**: a compressed artifact is named `.jpeg` or `.png`, never
  `.jpg`: some providers accept only the `jpeg` spelling. A pristine copy keeps the name it was
  picked under, except that an extensionless pick gets the extension its own bytes imply, because
  MIME inference would otherwise declare it `image/png` whatever it holds. `.jpg` and `.jpeg` count
  as one name family when identical bytes are deduplicated.

### Relationships

- Exactly one 压缩模式 is active. 原图 attachments exist in 手动 and 关闭; re-encoded ones exist in 自动 or
  after an explicit editor apply.
- 质量 applies to JPEG only, so PNG hides the control.
- The editor is offered only where it can act: an attachment whose bytes cannot be decoded shows no
  apply action, and a remote or `data:` attachment never opens the editor at all.
- The 分屏对比 and the artifact written to disk must come from the same parameter pipeline; a visible
  difference between them is a bug, not a preview artifact. A tile is shown only while it encodes the
  parameters currently selected.
- Manual compression is one-way: the editor re-encodes from the image's current stored bytes, so
  re-compressing a compressed image loses another generation, and the pristine 原图 is not recoverable
  once a compression has been applied.
- Short edge case that motivates the manual default: a long screenshot whose long edge is far larger
  than any preset cap would be reduced to illegibility by 自动, so 手动 leaves that decision to the user.
