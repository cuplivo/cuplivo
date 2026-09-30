# Cuplivo Context

Domain language for this repository. Terms here are decision-bearing: an ADR or a code comment that
contradicts one of them is a bug, not a preference.

## Project lineage (项目血脉)

- **Kelivo**: the upstream project (`Chevey339/kelivo`) this app is a fork of. Versions are its
  own (`v1.3.0`); the name legitimately appears in attribution, interop terms and external URLs.
- **Cuplivo 3.x**: the archived fork line (forked from Kelivo v1.1.17, terminal release v3.2.1),
  source of the identity values
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
  and preview temp files), and the release/build identity: artifacts
  `Cuplivo_<platform>_<version>_<arch>`, the Windows installer's own AppId
  `B924949D-FD7C-4688-B812-4ED64BFAACDC` (never upstream Kelivo's, or the two installers would
  upgrade and uninstall each other), publisher `cuplivo`, `cuplivo.exe`, DEB/RPM packages named
  `cuplivo`.
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
  *pairing* and persist afterwards. Pairing is the opt-in: nothing syncs until a device is
  paired, and a paired device is reached at the address it was last seen at.
- **Device identity**: per-install keypair minted at first pairing use; deviceId = hash of
  the public key; stable across app updates.
- **Pairing QR (配对二维码)**: the pairing path — one image shown by the responder carrying its
  candidate endpoints, its certificate fingerprint (= deviceId) and the open window's PIN, so
  scanning pairs in one step with no typing. The fingerprint is what the joiner pins inside the
  TLS callback, before any request byte leaves the device: that is the difference from a typed
  PIN, which proves nothing about *which* device answered (an active relay can terminate both
  legs). The image is bound to the one-shot window, so a stale photo pairs nothing, and its
  exposure equals the old same-screen "endpoints + PIN" display. Re-scanning a paired device is
  the repair action for a drifted endpoint: it overwrites the address and rotates the secret.
- **Pairing window (配对窗口)**: how the responder consents — it opens a five-minute, one-shot
  window and shows the QR/PIN; the window closes when a peer pairs (its dialog pops), when it
  expires, or after five wrong PIN guesses (the counter that keeps a 6-digit code from being
  brute-forced inside the window). There is no separate approval prompt: showing the code *is*
  the approval, and the joiner's half is the scan (or typing the PIN). Without a camera the PIN
  path remains, and then only the typed code plus line of sight stands in for the fingerprint.
- **Trust thereafter**: the client pins the listener's self-signed certificate, and every
  `sync/*` request proves the pairing with the per-peer secret minted at pairing — the channel
  must resist LAN sniffing and impersonation because the sync face carries API keys. Mutual TLS
  is not the mechanism: `dart:io` aborts the handshake against a self-signed *client* certificate
  (ADR-0003 amendment).
- **Blob**: a content-addressed transfer unit on the sync wire — the bytes of one file whose
  canonical URI appears in a travelling row, or of one skill directory as a zip. A blob's
  identity is its hash (`/sync/blob/<sha256>`): the receiver pulls what it lacks and skips what
  it already has. Blobs follow URIs: whatever a travelling row references is offered, without
  enumerating payload kinds.
- **Asset manifest**: the blob list a side publishes alongside the rows it sends (kind, target,
  content hash, size). It travels in the same batch as the rows, in both directions, so each
  side can compute its own needs without a negotiation beat.
- **Sync payload = entity rows**: peers exchange versioned repository rows (JSON), never a
  database file or a backup zip — a newer build's schema must never be handed to an older build.
  Blobs are the one binary exception, and they are content, not schema.
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
  verified on receipt; extraction reuses the `skill_archive` hardened unpacker. The hash, the
  served zip and the extraction share **one dot-file policy** — everything rides except the sync
  plane's own `.sync-*` scratch names and the OS bookkeeping files (`.DS_Store`, `Thumbs.db`,
  `desktop.ini`) — because a name the hash ignores but the extractor installs is a divergence the
  content clock can never see. A directory whose carried set is empty still has a body — the empty
  one — which the writer serves and the receiver applies, so the empty-body hash is never an
  unservable promise. A record whose
  body did not converge is **deferred**, never installed broken; deleting a skill removes the row
  and the directory together, or the rescan resurrects it.
- **Blob rules**: a received file lands at the path its URI names (URIs are never rewritten —
  that would diverge the conversation digest); writes are confined to the managed asset roots;
  the serving side answers only hashes it published or has registered, and a path a peer names is
  served only from a managed asset root (the path is not the credential); a landed blob is
  registered against the revisions the apply **actually wrote**, keyed off the advertisement rather
  than off what landed — so a rejected revision's parts cannot unlink the winner's own attachment,
  and a blob whose fetch failed is already referenced when its retry lands; a blob that
  does not arrive goes pending and is retried once per session, reported meanwhile. A blob
  failure defers a skill record but not a conversation.
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
- **Skill and workspace holdbacks**: workspaces stay device-local permanently. A skill's record
  and its directory blob travel together (slice 3): the record is applied only once its body has
  converged — already identical here, or pulled and re-hash verified in this session — because a
  record without its body would install a broken skill on the peer. A body that did not converge
  is reported back in the push acknowledgement, so the sender keeps its record and body and
  re-sends instead of reading the peer's silence as a deletion.
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
- **A local edit never lowers a row's clock**: every update path floors `updated_at` at the row's
  own `timestamp` (message updates, the UI's partial-field writes, parts and provider artifacts
  alike), because the effective LWW clock is `COALESCE(updated_at, timestamp)`: a message authored
  under a skewed (future) peer clock must not have a local edit sink below it, or the peer's
  untouched copy wins the next exchange and reverts the edit on both devices.
- **Concurrent append** (same conversation used offline on two devices) merges by timestamp
  interleave into one conversation. Rare by nature; lossless by design.
- **One row per version slot**: a message version group (`group_id` + `version`) can hold
  exactly one row — the schema's unique key says so — but two devices that regenerate the
  same message each create a rival row with a different id. The merge keeps the newer
  `COALESCE(updated_at, timestamp)`, ties to the higher row id (both peers hold the same two
  rows, so both decide alike), and the loser is deleted with its parts and counted as a
  deletion: a discarded regeneration is never silent.
- **A deliberate slot leads the order**: `message_order` is assigned by the slot each row
  carries, with `(timestamp, id)` only breaking a tie. The app itself places rows by slot —
  deleting the version a group is anchored on moves the surviving revision onto the freed
  slot — and the order is in no digest, so a "smarter" re-derivation by timestamp would
  silently undo that placement permanently.
- **Deletions**: a conversation deletion is announced on the hello — the conversations this
  device still holds a shared-history record for but no longer has, with the digest both sides
  last agreed on — so the peer deletes its copy only when it still matches that digest (an edit
  beats the deletion). The list is derived from the per-peer checkpoint, which means it is
  announced for exactly as long as the peer has not caught up, with no retention window; the
  `tombstone_rows` written on deletion stay local bookkeeping. Message deletion is detected by
  diffing against the same checkpoint (the set of rows the peer last saw), not by new tombstone
  scopes.

### Discovery & pairing (发现与配对)

- **Pairing, then nothing automatic about addresses**: the QR image (endpoints + fingerprint +
  PIN) is the recommended path; the PIN dialog is the fallback for a device without a scanner
  (desktop — the phone scans the computer's QR in the primary journey). Both leave a durable peer
  record, and sync uses the stored endpoint.
- **The pairing form names the field that is wrong**: address/port and the pairing code are
  validated and reported separately, so a mistyped address never sends the user to re-check the
  other device. The code is compared with its spaces stripped — the dialog shows it as `123 456`,
  so the space a user copies is not a wrong code.
- **No LAN discovery is implemented**: mDNS/DNS-SD (`_cuplivo._sync._tcp`) is a *deferred*
  option, not a missing piece — the platform cost (iOS Bonjour declarations and local-network
  permission, Android multicast locks, a Windows inbound UDP 5353 rule) buys endpoint
  auto-healing that a re-scan repairs in one gesture. The naming is reserved so adding it later
  is purely additive.
- **Endpoint drift (端点漂移) is a normal, repairable state**: the DHCP/network change that
  moves a peer makes "sync now" report `unreachable` until the address is fixed. Two repairs
  exist and both are ordinary: re-scan the peer's QR (updates the address, rotates the secret),
  or edit the address on the peer card. A drifted endpoint is a connectivity failure, reported
  as such — never a discovery failure.
- **AP isolation** is likewise a *connectivity* failure: on a network that blocks peer-to-peer
  traffic no pairing path helps, and the report says so.
- **Unpairing (解除配对) is local-first, then best-effort remote**: this device always drops the
  pairing immediately; it also asks the peer to forget it, over the same authenticated listener.
  If that notice cannot land nothing is broken — the peer's next session is refused as "no
  longer paired", and the user unpairs it there. A revocation only ever removes the caller's own
  pairing, because the per-peer secret is what proves who is asking.
- **The pairing window lives and dies with its dialog**: the code dialog refuses route-level
  pops (barrier tap, system back), so the only exits are its own close button — which cancels
  the window — and expiry. A dismissed dialog must never leave a live five-minute PIN and QR
  with nothing on screen saying so.
- **The authenticated identity is the caller's only identity**: `/sync/*` proves the caller by
  its per-peer secret, and a hello whose body names a different paired device is refused
  (`identity_mismatch`) rather than served that device's plan. `/pair` is the one route that
  answers before authentication, so its body is capped and every parse failure (bad JSON,
  missing field, unparseable certificate) is a 4xx rather than a 500.

### Sync session (同步会话)

- **Trigger cadence (触发节律)**: (1) the app coming to the foreground (and once after launch)
  runs one quiet round over every paired device with an endpoint, throttled to one round per
  minute; (2) a manual "sync now" in settings, never throttled. No polling, no background
  daemon, and — without discovery — no "peer appeared" trigger: the round is what "picked the
  device up" means.
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
  binary endpoints for blobs): hello (protocol version, schema version, capabilities, the
  initiator's listener port, its clock reading, its data epoch, the deletions it has not seen
  confirmed, checkpoint summaries, and what each side could not apply last session) → negotiate
  (each side computes deltas) → delta exchange (conversation subtrees, entity rows, preference
  keys, and the asset manifest for what each side is sending; the push is acknowledged with what
  was deferred, including skill bodies that did not land) → blob fetch (receiver pulls by
  contentHash, skipping hashes it already has; the responder pulls back over the initiator's
  advertised listener) → transactional apply + provider reload → checkpoint commit on both sides.
  The push and fetch beats always run, even with nothing to send: they are also where the
  responder performs its own blob pull, including the retries its checkpoint still owes.
  Checkpoints also carry what is still owed (pending blobs), the skill-content baseline and the
  peer's data epoch.
- **One plan, two faces**: conversations and business rows (entities + preferences) are decided
  by the same table — present on one side, newer clock, tie to the higher deviceId — and travel
  in the same batch, so one session moves a conversation and the assistant it references.
- **What the plan compares**: each face's digest covers the whole state that face means. A
  conversation's digest covers its message rows (`id:COALESCE(updated_at, timestamp)` lines), so
  the conversation row's own clock is compared *alongside* it — otherwise a rename, a pin or a
  version selection moves nothing the plan looks at and can never transfer. An entity's digest
  covers its payload **and** the list position it occupies (`sort_order`), because a drag rewrites
  every position while leaving every payload untouched. A preference has no position and hashes its
  value alone.
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

- **Sending is not receipt (发送≠收到)**: a checkpoint entry only advances to state the peer
  actually reached. The push beat answers with what the responder deferred (a generation was
  writing there, a restore held its write fence, or a skill's body did not land), and each hello
  carries what the sender could not apply last session, so the peer re-sends instead of reading
  the silence as a deletion. The fetch beat is acknowledged by nothing, so a conversation sent
  back is *not* advanced there: its entry appears one session later, when both manifests agree
  (`none` means local state is the shared state). Without these a deferred apply deleted the
  sender's own new message on the next session — on both sides of the session, in both faces
  (conversations and business rows) — and an interrupted fetch deleted the only copy on both
  devices. An `iSend` entry also describes the payload that was actually sent, never a fresh read:
  a row written while the session was in flight was never sent, and recording it as peer-seen made
  the next merge delete it here.
- **A deletion is announced, never inferred from an absence**: with the fetch beat no longer
  advancing optimistically, "the peer lacks this" cannot mean "the peer deleted it" — that
  ambiguity is what the announcement resolves. A conversation this device deleted keeps its
  checkpoint entry until the peer's manifest shows the deletion landed, so a peer deletion that
  yielded to a generation is retried rather than re-adopted.
- **A bulk replacement is an epoch, not a deletion**: a restore or an overwrite import replaces
  the local history wholesale, so the rows it drops were never deletions. The replaced device
  resets its own checkpoints and bumps a **data epoch** carried on the hello; a peer seeing a
  different epoch converts its own deletions to re-sends for that session (recovering what was
  lost) while a deletion it made itself still stands, because that travels through the
  announcement rather than an absence. Hooks: the restore cutover and an overwrite import — not a
  restore rollback (which returns to the tracked state) and not an in-app "clear all data" (a
  deletion intent, which propagates).
- **Replay-safe recovery**: checkpoints advance only after a successful apply + commit; an
  interrupted session simply recomputes its delta next time, and idempotent row upserts
  make re-application safe. Per-subtree transactions bound the damage of a mid-apply crash.
- **A settled conversation is not re-read**: the `none` arm refreshes an entry only when it
  disagrees with the manifest it is compared against (digest or row clock). Equal ones are computed
  from the same rows, so rebuilding them would read every message of the whole settled library on
  every launch, resume and manual round; an entry that disagrees — what an interrupted session
  leaves behind — is still rebuilt, which is the heal that keeps a peer deletion from reading as a
  local edit.
- **A failure is a reason, not a sentence**: a failed session carries a structured reason
  (unreachable, timeout, peer error, internal) that the panel and the stored record localize. The
  exception text — which carries the peer's address and port — goes to the log only; it never
  reaches a card or a snackbar, and an unrecognized or absent reason falls back to a generic line.
- **One session per pair (一对设备一个会话)**: a per-peer single-flight lock covers both roles,
  because the responder and the initiator paths write the same checkpoint file from the copy each
  read at its own hello. An initiator round is refused while a session exists for that pair, and a
  hello from a peer this device is initiating to is refused as busy; a simultaneous
  double-initiate refuses both rounds and the next trigger (launch, resume, manual) retries.
- **Every request is bounded**: a peer that stops answering costs one deadline, not the process.
  Client budgets are hello 60 s, push/fetch 20 min, blob 15 min of inactivity, pairing 60 s;
  server routes are bounded too (pair/hello 60 s, revoke 30 s, data routes 30 min), so a body that
  stops arriving cannot hold the serial request loop open and silence pairing and sync alike.
- **Clock skew: accept and surface (接受+显性化)**: hello exchanges clock readings (protocol
  v4); a divergence beyond five minutes raises a yellow-flag line in the sync report — on
  **both** devices, each computing it from the same pair of readings — but sync proceeds
  regardless. The threshold is a fixed health number, not a setting: below it LWW comparisons
  stay honest for any realistic edit rhythm; above it timestamps lie systematically and the fix
  is a device clock. No logical clocks in v1.

### Sync panel (同步面板)

- The user-facing surface is a settings section only: pairing entry ("add device" — show a
  pairing QR on this device, scan or type the code from another) + one card per paired device
  (editable name, platform, endpoint, last sync outcome, sync now, unpair). **Pairing is the
  opt-in** — there is no master switch, and no global chrome (no sync icon outside the panel).
- **No online state**: the card shows the last sync attempt and its outcome, never a presence
  badge. Nothing probes the peer between sessions, so "online" would be a claim the app cannot
  make; a drifted address shows up as a failed attempt, not as an offline device.
- **Listener lifecycle**: the listener runs whenever the app runs, on a preferred port
  (`9527`) that falls back to an ephemeral one when taken, so a peer's stored endpoint and the
  Windows firewall rule stay stable across launches. On Windows the inbound rule is
  port-scoped (`Cuplivo-Sync-TCP-<port>`, no spaces or parentheses so `netsh` quoting
  survives both a plain call and a UAC re-invocation); the preferred port's rule persists, an
  ephemeral port's rule is deleted best-effort on stop. Adding it without administrator rights
  fails silently, so the panel offers a one-click elevated retry.
- **Nothing silent**: the per-session report lists transfers, conflicts and their losers —
  business rows whose local *content* an incoming newer row replaced (LWW losers, counted per
  face), and skill-content losers — plus blobs that arrived, bytes moved, skills whose body
  converged, and warnings (clock skew, version refusal, files that never arrived). Counters,
  not per-row names: which row lost lives in the log. Adopting a row that carries the same
  content (the peer echoing this device's own row back) is not a loss.
- **File avatars travel**: the stored value is the canonical `kelivo-file` form, so an avatar
  blob follows it like any other referenced file and the peer renders the real image. Legacy
  absolute values keep resolving (dual-form reads) and canonicalize on load.

## Release & upstream policy (发版与上游策略) — ADR-0004

- **Follow upstream (随上游)**: a new version re-bases the code base on the latest Kelivo stable and
  re-does Cuplivo's own features on that baseline (cherry-pick) instead of diverging permanently.
  4.0 is the first line built this way; 3.x ended because hand-syncing every upstream change became
  unmaintainable.
- **Coexistence, not migration (并存而非迁移)**: the application id differs from every other
  lineage, so a 4.x install never overwrites Kelivo or Cuplivo 3.x, and data is never migrated
  automatically.
- **Migration path from 3.x (从 3.x 迁移)**: 3.x's 「数据迁移 → 导出 Kelivo 兼容备份」
  (`backupMigrateExportLabel`) produces the full backup this line can restore; the plain backup
  export is not that file.
- **Removed 3.x features (未随行的 3.x 功能)**: group chat, the multi-AI side-by-side comparison,
  the delete-recovery / recycle bin and subagent delegation were not re-implemented on the new
  baseline; `CHANGELOG*.md` records them per release.

## Community channels (社区入口)

- **Cuplivo QQ group**: `1101061750` — `https://qm.qq.com/q/9Rnnf7XyNO` (the only QQ entry).
- **Cuplivo Discord**: `https://discord.gg/kaTf8CXG4`.
- Upstream Kelivo's community channels are not listed in the app.

## Image Compression (图片压缩) — ADR-0002

- **Compression mode (压缩模式)**: one mutually exclusive stance for how attached images are handled,
  chosen in settings.
  - **auto (自动)**: every attached image is re-encoded at attach time with the configured preset, through
    the same 工作图 decode the editor uses. A source over the 工作预算 is skipped like any other skip, so the
    attachment keeps its pristine bytes instead of risking the process.
  - **manual (手动)**: attachments are kept as pristine originals and the compress editor is the only
    compression surface. This is the default.
  - **off (关闭)**: attachments stay pristine and no compression UI is offered at all.
- **Original (原图)**: an attachment whose bytes are exactly what the picker handed over, before any
  re-encode. It is also the third choice in the editor's format control, meaning "keep this image as it
  is" — the escape hatch that makes per-image skipping explicit instead of inferred.
- **Format (格式)**: the output encoding the user picks — JPEG (lossy, has 质量) or PNG (lossless, no
  质量). WebP is never produced: some providers reject it.
- **Working image (工作图)**: the pixels the editor actually holds — the source decoded once at the
  resolution the artifact will have, so peak memory follows the chosen output rather than the file.
  It is bounded by the working budget (14 MP mobile / 20 MP desktop), and its long edge is what the
  long-edge slider can reach. See ADR-0005.
- **Retired working image (已退休工作图)**: a 工作图 a re-decode replaced while the preview may still be
  drawing it. It is released only after the frame that publishes its replacement has painted, because a
  painter captures the image it draws and an animation repaints it without a rebuild — releasing at the
  swap drew a disposed image once per frame. See ADR-0005 decision 11.
- **Reference image (参考图)**: the source decoded once at its reachable long edge, kept for the session
  as the comparison's original side. It exists because the left half used to be drawn from the 工作图,
  which is decoded at the *target*: lowering the resolution then blurred 原图 along with the result
  until the two halves differed only by the encoding, hiding the loss the slider was causing. It is
  display-only — nothing is ever encoded from its pixels — and it is never decoded at all while the
  target is the reachable edge, because there the 工作图 already holds those exact pixels. See ADR-0005
  decision 13.
- **Working budget (工作预算)**: the ceiling on a working image, in pixels, and on a single decode, in
  bytes. The byte ceiling is judged twice, because the risks differ: the raster a decode would allocate
  against the whole budget, and the source file held twice against half of it. A file-inclusive
  judgement used to refuse sources whose decode is cheap — a 200 MP JPEG needs 280 MB of raster and was
  refused for its 30 MB file. When a source cannot be decoded inside the budget, the editor refuses with
  an explanation and no apply action rather than risking a process abort — an out-of-memory kill inside
  a decode is not catchable from Dart. The refusal is a state, not a dead end: the panel keeps the
  source's dimensions and its long-edge control, because a smaller 工作图 is what makes a borderline
  source fit.
- **Artifact (产物)**: the exact byte sequence the current parameters produce, encoded from the working
  image. The size row shows its length, the compressed side of the 分屏对比 draws it, and the apply
  writes those same bytes, so the three can never disagree. It is dropped the moment a parameter
  changes, and only ever written while its parameters still equal the selected ones.
- **Long edge (长边)**: the target size of the image's longest side. It only ever shrinks, and its
  reachable range ends at the working image's long edge, so the slider cannot promise a resolution the
  pipeline will not produce. When the source had to be reduced to fit the budget, the panel says so.
- **Quality (质量)**: 30-100 lossy strength, meaningful for JPEG only — the editor's slider
  floor is 30, and the stored value is clamped to the same range.
- **Savings (节省)**: (original bytes − artifact bytes) / original bytes, shown before the user
  commits. The row reads as two sides — resolution above size on each side — with the change above an
  arrow between them. A PNG of a photo can legitimately grow, and the row says so before the apply by
  showing that growth (a `+N%` warning tone) instead of hiding it.
- **Split compare (分屏对比)**: the editor body's 1:1 comparison — the original on the left of a
  draggable divider, the artifact on the right, over the region on screen. The right half is the
  artifact's own pixels, so 1:1 means one artifact pixel per logical pixel; the left half draws the same
  region from the 参考图, so 原图 is never a re-decode at the target. The image is letterboxed inside the
  preview area at its own aspect ratio, never stretched or cropped to fill it; the default framing fits
  the viewport's width and never magnifies, so a tall screenshot stays legible instead of shrinking to a
  strip, and every framing keeps that aspect ratio and is bounded by it — a zoom cannot leave the window
  narrower than the preview area. Changing a parameter drops the shown artifact immediately, so a stale
  encode is never presented as the current one.
- **Apply to all (应用到全部)**: broadcasts the editor's current parameters to every attached image.
  Only the image the editor was opened for can reuse the editor's artifact; the others run the same
  budgeted pipeline themselves.
- **Processing gate (处理门)**: what the composer hands the editor when the chip it was opened from is
  still running its attach-time pass. The dialog opens on the click and prepares behind that pass,
  because decoding beside it is the doubling the single-pass rule forbids. Until a 工作图 exists there is
  no artifact to write, so the apply actions stay disabled while only closing is offered.
- **Remembered parameters (记住的参数)**: the last parameters the user confirmed in the editor — 原图
  included — which seed the next editor session. A long edge remembered from a larger image is
  normalised to the image being edited once its size is known, so the panel's readout always equals
  what will be applied.
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
- 自动 and 手动 share one 工作图 decode and one 工作预算; they differ in who decides the parameters and in
  what happens to a source that cannot be worked: 自动 skips it and keeps the pristine copy, 手动 offers no
  apply action and says why.
- The editor is offered only where it can act: an attachment whose bytes cannot be decoded shows no
  apply action, a source that cannot be decoded inside the 工作预算 shows an explanation and no apply
  action, and a remote or `data:` attachment never opens the editor at all. A chip whose pass is still
  running is waited out through the 处理门 rather than refused: the click is answered at once.
- The 分屏对比, the size row and the artifact written to disk are one value; a difference between them
  is a bug, not a preview artifact. The shown artifact belongs to the parameters currently selected.
- The working image and the artifact are at the same resolution by construction, so a re-encode can
  never exceed the working image's long edge, and 1:1 is always one artifact pixel per logical pixel.
- The 参考图 sits at the reachable long edge and the 工作图 at the target, so the original side of the
  分屏对比 stays put while the slider moves: the note that says the source was loaded at a percentage to
  stay within memory names that same reachable edge, not the target the user chose.
- Manual compression is one-way: the editor re-encodes from the image's current stored bytes, so
  re-compressing a compressed image loses another generation, and the pristine 原图 is not recoverable
  once a compression has been applied. An applied artifact may differ byte-for-byte from what an older
  build produced for the same parameters, because the resampling now happens in the decode.
- Short edge case that motivates the manual default: a long screenshot whose long edge is far larger
  than any preset cap would be reduced to illegibility by 自动, so 手动 leaves that decision to the user.
  The same screenshots are why the editor decodes at the artifact's size instead of the source's.
