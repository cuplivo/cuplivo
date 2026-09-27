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

## LAN Sync (局域网同步)

- **Device continuity (设备间接续)** — the job LAN sync is hired for: conversations follow the
  user across their devices with no manual merge step. Not a bulk-transfer tool, not a backup
  channel (WebDAV/S3/local snapshots own that), not a hub topology with one canonical device.
- **Paired device (已配对设备)**: a peer whose identity and trust were established once during
  *pairing* and persist afterwards; discovery only automates reconnecting to paired devices.
- **Device identity**: per-install keypair minted at first pairing use; deviceId = hash of
  the public key; stable across app updates. Pairing = QR code (endpoint + key fingerprint —
  MITM-proof on hostile LANs) or 6-digit PIN when no camera is available; both screens
  confirm. Trust thereafter = the client pins the listener's self-signed certificate, and every
  `sync/*` request proves the pairing with the per-peer secret minted at pairing — the channel
  must resist LAN sniffing and impersonation because the sync face carries API keys. Mutual TLS
  is not the mechanism: `dart:io` aborts the handshake against a self-signed *client* certificate
  (ADR-0002 amendment).
- **Sync payload = entity rows**: peers exchange versioned repository rows (JSON), never a
  database file or a backup zip — a newer build's schema must never be handed to an older build.
- **Foreground constraint**: sync runs while the app is running (foreground on mobile,
  foreground-or-tray on desktop); no mobile background daemon in the first version.

### Sync scope (同步面)

- **Syncable** (rides sync): conversations + messages + parts + content-addressed asset
  blobs; every business entity kind except **workspace** (assistant, provider, MCP server,
  world book, quick phrase, memory entry, search/TTS service, instruction injection, tag,
  skill, user profile field); and the `syncedPreference` keys below.
- **Workspace stays device-local**: linked workspaces carry a host path by definition;
  managed workspaces are the user's local project directories — unbounded in size and
  semantically "work on this machine", not app content.
- **Skill = record + directory blob**: a skill rides sync as two pieces — its entity
  record (LWW for settings) and its on-disk directory as one zip blob keyed by a directory
  hash (sha256 over sorted (relative path, file digest); the record's `updatedAt` does not
  track content edits, so content delta detection is hash-based). Content conflict resolves
  deterministically off the checkpointed hash (unchanged side adopts the changed side; both
  changed → newer record `updatedAt`, then higher deviceId wins); the loser's edit is
  reported, never silently dropped. Apply = staging + atomic directory swap, re-hash
  verified on receipt; extraction reuses the `skill_archive` hardened unpacker.
- **Device-local** (never rides sync): `localOnly`, `discarded` and `unknownPreference`
  dispositions, all `display_*` keys (fonts reference local file paths), `global_proxy_*`,
  `tts_engine_v1`/`tts_language_v1` (platform fallbacks), and the session-position keys
  `current_assistant_id_v1` / `selected_model_v1` — those say where *this device* is
  looking, not how the app should be configured.
- **`syncedPreference`**: a new disposition in `BusinessKeyRegistry` (the classifier stays
  the single authority; no parallel allowlist). Contains theme/locale, title/summary/
  translate/ocr/compress model+prompt keys, memory prompts, `asr_services_v1`,
  `tts_speech_rate_v1`/`tts_pitch_v1`/`tts_selected_service_id_v1`, `search_*`,
  `pinned_models_v1`, user name/avatar, `webdav_config_v1`/`s3_config_v1`,
  `chat_bubble_style_overrides_v1`, `tool_schema_overrides_v1`.
- **Skill and workspace holdbacks (slice 2)**: workspaces stay device-local permanently; a
  skill's *record* is deliberately not synced until its directory blob arrives, because a
  record without its body would install a broken skill on the peer.
- **New-device test** (新设备测试): the rule for classifying a preference key — *would a
  brand-new device want this value to arrive with the pairing?* Business config yes;
  window geometry, proxies, platform flags and fonts no.

### Conversation merge semantics (对话合并语义)

- **Transfer unit vs merge unit**: the two are distinct. The *transfer unit* is the
  conversation subtree (conversation row + messages + parts + asset references, moved and
  applied atomically — nothing can fall through a conversation boundary). The *merge unit*
  is the row.
- **Deterministic symmetric merge**: merging is a pure function of both sides' row states —
  row present on both sides: newer `COALESCE(updated_at, timestamp)` wins, ties broken by
  deviceId; row present on one side: union in. Both devices compute the same result
  independently. There is deliberately **no direction knob** (no initiatorWins/serverWins) —
  the 3.x session-priority control existed only because its merge was not symmetric.
- **Concurrent append** (same conversation used offline on two devices) merges by timestamp
  interleave into one conversation. Rare by nature; lossless by design.
- **Deletions**: conversation deletion propagates via the existing `tombstone_rows`; message
  deletion is detected by diffing against the per-peer sync checkpoint (the set of rows the
  peer last saw), not by new tombstone scopes.

### Discovery & pairing (发现与配对)

- **mDNS/DNS-SD is the discovery path**: each device advertises `_cuplivo._sync._tcp`
  (platform NSD on mobile, multicast DNS on desktop) while the app runs; a discovered
  already-paired peer connects and syncs automatically. QR (endpoint + identity) and manual
  IP entry are the fallbacks for hostile networks. AP isolation is a *connectivity* failure,
  reported as such, not a discovery failure.
- **Paired device (已配对设备)**: pairing happens once per device pair and exchanges durable
  identity + trust; afterwards no user action is needed.

### Sync session (同步会话)

- **Trigger cadence (触发节律)**: event-driven — (1) a paired peer discovered on the LAN
  starts a session; (2) local writes open another after a short debounce, if the peer is
  still reachable; (3) a manual "sync now" escape hatch lives in settings. No polling; sync
  density follows usage density.
- **Symmetric version gate (对称拒绝)**: at hello each side refuses a peer whose database
  schema version is newer than its own ("upgrade this device to sync"). Same or older is
  accepted — an older peer's rows merely fill column defaults. Sessions therefore only run
  between equal schema versions; a schema bump pauses sync for the upgrade window instead
  of letting a stale peer mangle newer rows (dropped fields would later win via LWW and
  propagate). The protocol version rides the same exchange; unknown protocol = refuse.
- **N devices, pairwise sessions**: no hub. With A↔B↔C, C receives A's increments through
  B; deterministic idempotent merge makes multi-hop convergence safe. Checkpoints are
  stored per device pair.

- **Session protocol**: a bounded six-beat run over mutual-TLS HTTP (REST-style JSON bodies,
  binary endpoints for blobs): hello (protocol version, schema version, capabilities,
  checkpoint summaries) → negotiate (each side computes deltas) → delta exchange
  (conversation subtrees, entity rows, preference keys, tombstones, asset manifest) →
  blob fetch (receiver pulls by contentHash, skipping hashes it already has) →
  transactional apply + provider reload → checkpoint commit on both sides.
- **One plan, two faces**: conversations and business rows (entities + preferences) are decided
  by the same table — present on one side, newer clock, tie to the higher deviceId — and travel
  in the same batch, so one session moves a conversation and the assistant it references.
- **Business rows carry their own clock**: an applied row keeps the peer's `updated_at`
  (never stamped with local time); that timestamp is what the next session compares. Deletions
  ride the per-peer checkpoint, as message deletions do.
- **Apply without restart**: sync writes ride repository transactions, then trigger one
  state reload (`BusinessPreferences.reload()` + every provider's `_load()` + ChatService
  list refresh). Restart is *not* structurally required — restore needs it only because it
  swaps the database file (cutover), and the Cherry importer's restart dialog is a
  coherence shortcut, not a constraint. Setters write per key and never write back a whole
  in-memory snapshot, so a stale provider cannot clobber synced rows; the remaining native
  SharedPreferences keys (log toggle, font scale, Linux title bar) are all device-local
  and outside the sync face anyway. Restart remains only a crash-recovery fallback.
- **Apply yields to generation**: applying changes to a conversation is deferred while a
  generation is actively writing to it.

### Failure policy (故障政策)

- **Replay-safe recovery**: checkpoints advance only after a successful apply + commit; an
  interrupted session simply recomputes its delta next time, and idempotent row upserts
  make re-application safe. Per-subtree transactions bound the damage of a mid-apply crash.
- **Duplicate session suppression**: when both sides dial simultaneously, the deterministic
  initiator is the lower deviceId; the other side refuses with "busy".
- **Clock skew: accept and surface (接受+显性化)**: hello exchanges clock readings; a
  divergence beyond a threshold raises a yellow-flag warning in the sync report, but sync
  proceeds — true concurrency is rare, ties already fall to deviceId, and fixing the clock
  heals it. No logical clocks in v1.

### Sync panel (同步面板)

- The user-facing surface is a settings section only: pairing entry ("add device" —
  show/scan QR, PIN fallback) + one card per paired device (editable name, platform,
  online state, last sync outcome, unpair). **Pairing is the opt-in** — there is no master
  switch, and no global chrome (no sync icon outside the panel).
- **Listener lifecycle**: the listener runs whenever the app runs, on a preferred port
  (`9527`) that falls back to an ephemeral one when taken, so a peer's stored endpoint and the
  Windows firewall rule stay stable across launches. On Windows the inbound rule is
  port-scoped (`Cuplivo-Sync-TCP-<port>`, no spaces or parentheses so `netsh` quoting
  survives both a plain call and a UAC re-invocation); the preferred port's rule persists, an
  ephemeral port's rule is deleted best-effort on stop. Adding it without administrator rights
  fails silently, so the panel offers a one-click elevated retry.
- **Nothing silent**: the per-session report lists transfers, conflicts and their losers
  (LWW losers, skill-content losers), and warnings (clock skew, version refusal).
- **File avatars degrade**: emoji/url avatars sync (portable values); a `file` avatar falls
  back to the default on the peer, flagged in the report. Full-fidelity avatar carriage
  (blob + path remap) is a deliberate later addition, not v1.

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
