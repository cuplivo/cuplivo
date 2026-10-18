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
- **Conversation link (对话链接)**: `cuplivo://conversation/<conversationId>[?message=<messageId>]` is
  the app-scheme route — what the iOS Live Activity opens, and what **Copy Link** writes on a
  conversation or on a single message. It is a pointer, not a copy: it resolves only where the
  conversation exists (the device that copied it, or a device LAN sync carried it to, because merged
  rows keep their ids), so a device that does not hold it says so instead of ignoring the tap, and a
  link never creates a conversation. An id is an opaque row key — the grammar carries whatever a
  stored conversation or message has, percent-encoded, and `ConversationLink.supportsId` is the one
  rule the writer and the parser share, so no copied link is ever one the parser would refuse. Only
  a platform that registers `cuplivo` offers the copy action (`ConversationLink.osRegistered`;
  Android and iOS today).
- **Side-by-side installs**: the applicationId differs from both Kelivo and Cuplivo 3.x, so
  installs coexist and never overwrite each other. Data migration is therefore *not* implemented;
  restoring a backup is the supported path between them.
- **Legacy bundle ids**: the `kelivo-file://` whitelist accepts `com.cuplivo.cuplivo`,
  `psyche.kelivo`, `com.cup11.cuplivo` and `com.cuplivo.cuplivo`, and the Windows `AppData` vendor
  prefixes `com.psyche` / `com.cup11` / `com.cuplivo`, so backups and absolute paths recorded by
  either lineage keep resolving.

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
  it already has, and a receiver that *cannot* pull asks the holder to push the same bytes over
  the connection it already has (推回退, the blob plane's half of the workspace rule below).
  Blobs follow URIs: whatever a travelling row references is offered, without
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
  blobs; every business entity kind — assistant, provider, MCP server, world book, quick
  phrase, memory entry, search/TTS service, instruction injection, tag, skill, user profile
  field, and **workspace** (its record; its files ride a face of their own, see Workspace
  carriage); and the `syncedPreference` keys below.
- **A workspace rides as a record, and — when managed — as files (工作区)**: the *record* (name,
  kind, bindings, position) is an ordinary entity row and travels like any other. A **managed**
  workspace's directory also travels, on its own file face and under its own rules (Workspace
  carriage below). A **linked** workspace travels as *neither*: it names a host path that means
  nothing on the peer, so its row is filtered out at the row level — the one entity kind with a
  per-row exclusion, and it has to stay that way, because a row that never entered the manifest
  cannot be read as a deletion.
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
  does not arrive goes pending and is retried once per session, reported meanwhile — and a blob the
  holder pushes over the working direction counts as landed here, not as pending. A **retry is
  superseded by a fresh advertisement, never preferred to it** (same target, new hash: the picture was
  re-referenced or the skill body edited), because asking for the stale hash forever is a stall neither
  report names; and a push is accepted only for a `(kind, key)` this session asked for, **at that
  entry's hash** — the route's hash is the request, not a hint, so another valid-looking file's bytes
  cannot be booked under a legitimate entry. A blob
  failure defers a skill record but not a conversation.
- **Device-local** (never rides sync): `localOnly`, `discarded` and `unknownPreference`
  dispositions, all `display_*` keys (fonts reference local file paths), `global_proxy_*`,
  `tts_engine_v1`/`tts_language_v1` (platform fallbacks), and the session-position keys
  `current_assistant_id_v1` / `selected_model_v1` — those say where *this device* is
  looking, not how the app should be configured.
- **`syncedPreference`**: a disposition in `BusinessKeyRegistry` (the classifier stays
  the single authority; no parallel allowlist). Contains theme/locale **plus the custom
  palettes `theme_palette_v1` can name**, title/summary/translate/ocr/compress model+prompt
  keys **with their limits and thinking toggles**, memory prompts **and the rest of the memory
  configuration (model, thinking, legacy mode, injection cap, migration batch size)**,
  `asr_services_v1`/`asr_selected_service_id_v1`,
  `tts_speech_rate_v1`/`tts_pitch_v1`/`tts_selected_service_id_v1`, `search_*`,
  `pinned_models_v1`, user name/avatar, `webdav_config_v1`/`s3_config_v1`,
  `chat_bubble_style_overrides_v1`, `tool_schema_overrides_v1`.
- **Half a family is a bug**: a key that names, selects or configures something whose sibling
  already rides sync must ride too, or the new device arrives with the feature half-configured
  — `theme_palette_v1` = `custom` with no palette definition (falls back to the default palette
  while the settings page still shows it as selected), a compress model and prompt with different
  limits, a memory pipeline that cannot run for want of a model. Membership follows the family,
  not the key.
- **The writers are checked, not just the list**: `business_key_registry_sync_test.dart` walks
  `lib/` for every key written through a preference setter and fails on any that classifies as
  `unknownPreference`. Fail-closed is the right default for a key nobody has thought about — but
  it is also how whole families stayed behind while only the listed keys were ever asserted.
- **Skill holdbacks**: a skill's record and its directory blob travel together (slice 3): the
  record is applied only once its body has converged — already identical here, or pulled and
  re-hash verified in this session — because a record without its body would install a broken
  skill on the peer. A body that did not converge is reported back in the push acknowledgement, so
  the sender keeps its record and body and re-sends instead of reading the peer's silence as a
  deletion. Workspace *files* answer the same question on their own face (a file that did not
  arrive is reported and retried, never read as a deletion), while a workspace's *record* does not
  wait for its files at all: the row is what makes the workspace exist on the peer.
- **New-device test** (新设备测试): the rule for classifying a preference key — *would a
  brand-new device want this value to arrive with the pairing?* Business config yes;
  window geometry, proxies, platform flags and fonts no.

### Workspace carriage (工作区承载)

- **The record rides rows, the files ride a file table (文件表)**: a managed workspace's *record*
  travels as an entity row under the ordinary row-level LWW rule; its *files* travel on a face of
  their own, described by a per-pair, per-workspace table of `relative path → (size, mtimeMs)`
  carried in **both** directions of the delta batch. A linked workspace travels as neither.
- **Files are pulled, and pushed only when a pull cannot happen (推回退)**: each side advertises its
  table and fetches what it lacks over `POST /sync/wsfile` from the listener that holds the bytes. The
  table is the whole negotiation; there is no manifest beat for workspace content. A peer that cannot
  be *dialled back* — the shape every NAT makes, an Android emulator always — asks for the files it
  planned and could not land in its push acknowledgement (`workspaceRequests`), and the initiator
  pushes exactly those over the connection it already holds (`PUT /sync/wsfile`, the pair base64url in
  headers, the raw file as the body). The request set is the **write authorization**: only a pair the
  caller itself advertised, at the size that was asked for, is ever written.
- **Identity is (size, mtime); there is no content hash**: a file is what its metadata says it is.
  The price is the mtime family's known limits (below); the gain is that a workspace's bytes are
  never read to decide whether they changed.
- **Every pair keeps a two-sided ledger (账本)**: the last revision *both* sides proved, stored as
  two stamps (mine, peer) inside that pair's checkpoint. **The side that lands a file advances its
  entry** — whether it fetched the file or the peer pushed it — and never the sender, because a sender
  cannot know what arrived. On the responder that finalisation happens once, at the fetch beat, after
  every push of the session has landed. A missing entry is always the conservative reading: send or
  fetch again, never delete.
- **Absence is a deletion, and an edit beats it**: a path the ledger holds that the peer's table no
  longer lists is deleted here, and the mirror image holds there — unless the other side's stamp is
  newer, in which case the file is fetched back. A session against a peer whose database was
  bulk-replaced (a different data epoch) sends `allowDeletes: false`, exactly as the row faces do.
- **A landing verifies before it destroys (先校验，后落盘)**: the staged bytes are checked against the
  advertised size *before* the destination is touched. The file already at that path is, at that
  moment, the only copy this device has, so a refusal that had deleted it first left the path empty —
  a file the device never lost, gone until the next session fetched it back. The post-rename stat
  stays as the belt for a writer that lands in between, and a rejected landing leaves the old version
  exactly where it was.
- **A workspace is planned only when both sides advertised a table**: a missing table means "not
  shared" (switched off, over a cap, not this peer's), an empty table means "shared, and it has no
  files" — opposite statements for the deletion rule, so they are never collapsed into one.
- **The files land after the row does (先落行，再落文件)**: each side walks its workspaces *after* its
  own business apply, because a workspace record that just arrived is what makes its folder this
  device's to populate — and the folder is therefore empty, which is exactly what tells the plan to
  fetch everything the peer advertised. Planning from a walk taken before the apply would make every
  workspace cross one session later than the record that announced it.
- **A workspace id is a path segment (工作区 id 是路径段)**: the id is what `<appData>/workspaces/<id>`
  is built from, and it arrives from the wire (a peer's row) and from a backup. It is one plain
  segment or the row does not sync in **either** direction — never announced, never served by name,
  never accepted from a peer, never deleted through sync — and the filesystem sink refuses it last.
  Anything else would let a row this device never offered name a directory outside the managed tree
  and have this device index, advertise and (on a peer-driven delete) remove it.
  **The row carries that id twice and the halves must agree (一个 id 写两遍，两遍必须一致)**: the
  table's `id` column decides what the row *is*, and the payload's own `id` is what the app lists,
  renames and deletes by. Only the column was once checked, so a row whose column said `w-1` and whose
  payload said `..` was listed as an ordinary workspace — and deleting it with “also delete files”
  removed the app data root itself. `workspacePayloadNamesId` is that rule, read by the same
  row-level filter as the id check, so a row whose halves disagree is not listed either (the panel
  refuses it on load, which is also what stops an update minting a second row under an id of the
  peer's choosing). One unreadable payload costs its own workspace, never the whole list.
- **Caps are hard gates and the switch cannot lift them (上限)**: a workspace over **2,000 files or
  200 MB** has **no content synced at all** — the whole block, never half a table — and the panel
  says so (`2,001+ 文件`, and its size is a lower bound). The ledger has a global 20,000-entry cap
  *derived from* the per-workspace cap (`10 × 2,000`, both in `sync_limits.dart`, the relationship
  asserted in `sync_limits_test.dart`) and drops whole workspaces over it; those fall back to
  conservative
  re-sending, never to deleting. **A workspace the advertised-table cap drops is *named*, not
  silent**: the peer reads its absence as “no opinion” and plans nothing, so it transfers nothing and
  no failure ever mentions it — the one shares-nothing reason the user did not choose, and the field
  exists precisely so that silence is impossible. The per-workspace switch is **device-local**
  (`sync/workspaces.json` records the
  *disabled* set, so a new workspace is on by default) and controls **files only**: the record
  keeps travelling either way, because removing a workspace from the manifest is what deletes the
  peer's copy. The switch is also **written as one serialized mutation** (read-edit-write, never two
  overlapping read-modify-writes of the same file), and it is what protects the folder from a
  peer-driven deletion — see below.
- **A peer's deletion takes the record, and an off switch keeps the folder (关掉开关就保住文件夹)**:
  a managed workspace row removed *by sync* takes its directory with it (a workspace the app no
  longer lists must not keep occupying disk) — **unless the user switched content sync off for that
  workspace**, in which case the row still goes (it is gone on the peer, and a row that stayed would
  be re-advertised) and the folder stays: "off" means this device's files are its own, and a
  peer-driven deletion is exactly the case that promise has to cover. The session report counts what
  the switch protected, because a folder that is invisible in the app and present on disk has to be
  explained somewhere. A folder this kept is orphaned until a workspace with that id exists again.
  The user's *own* delete (the workspace UI) removes the files regardless: that is an explicit
  local action, not a sync-driven one.
- **Pruned, because nobody wants `.git` over Wi-Fi (剪枝)**: the index never walks VCS metadata,
  dependency or build directories, caches, editor directories or OS bookkeeping files — nor the
  sync plane's own `.sync-*` scratch names, so a transfer in flight is never mistaken for content.
- **An index that could not be read is not shared at all (读不动就不同步)**: if any directory
  cannot be listed or any file cannot be stat'ed — or the root cannot even be resolved, an
  unwritable app data directory — that workspace contributes nothing this round —
  no table, no deletions — and the panel shows `无法读取`. The reason is the deletion rule: a file
  missing from a table is indistinguishable from a deleted one, so one permission accident would
  otherwise delete the peer's copy. The price is that a workspace with a single unreadable file
  syncs no content at all until it can be read.
- **Deleting the record deletes the folder**: a managed workspace row removed by sync takes its
  directory with it — a workspace the app no longer lists must not keep occupying disk. The one
  exception is the per-workspace switch: a workspace the user turned off keeps its folder when the
  peer deletes the row (see the caps bullet above).
- **Why not the alternatives**: content hashing would read every byte of every file to answer a
  question mtime answers; directory-level LWW would move a whole tree for one edited file; "seed
  only the first time" leaves the two copies to drift with no way back; and mixing a content digest
  into the row digest would make "the files changed" mean "the row changed" — an extra row transfer
  per edit, plus a fake LWW-loss count. See ADR-0003 slice 18.

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

- **Pairing, then a learned endpoint set**: the QR image (endpoints + fingerprint +
  PIN) is the recommended path; the PIN dialog is the fallback for a device without a scanner
  (desktop — the phone scans the computer's QR in the primary journey). Both leave a durable peer
  record, and sync dials the endpoints that record remembers, best first. The set is capped at
  `kMaxPeerEndpoints` (12): a user-typed address at the cap is **refused and said out loud** (it
  never evicts an address this pair has actually synced over), the card offers the add gesture
  whenever there is room — not only when the set is empty, which was the one state where a second
  network could not be added at all — while automatic learning (pairing candidates, remembered
  history) keeps the freshest twelve and reports what it dropped instead of discarding it silently.
- **An address belongs to the (device, network) pair** (端点集): the same laptop is reachable at
  an office address, a home address and a phone hotspot, so a peer record holds up to **twelve**
  endpoints instead of one. An endpoint is a thing the user manages, not a line of text: it carries
  a device-local `customName` (empty = the bare host is its name), when it was added, how many
  sessions it has carried and what the last probe measured, and the panel draws one tile per
  address with its latency. A session promotes the endpoint it succeeded over to the front and
  keeps the rest behind it as hints, so roaming back to a known network heals itself in one round.
  A re-pair carries the old set over behind the address it just proved (and the candidates the QR
  advertised): the repair gesture for a moved peer must not forget the networks the pair has
  already met, or alternating two places costs a re-scan every time. An address the new pairing
  *mentions again* keeps what the old tile had — the name, when it was first learned, the sessions it
  carried and the probe measurement — because that is the common case (re-pairing at home proves the
  home address again), and one address is one tile: the fresh copy holds the dial position, the old
  copy contributes the facts, and the counts add up rather than one replacing the other. Only the
  certificate
  fingerprint identifies a peer — every connection re-verifies it — so remembering several
  addresses can never reach the wrong device. Manual repair is **per address** — add, edit or
  delete one, with the add gesture offered whenever there is room — because the automatic memory is
  what failed: the user fixes the entry that failed instead of retyping the whole set. A typed
  address must be a real one first: the form refuses a port outside 1–65535 by staying open, so it
  cannot close on an address the store would refuse (`SyncEndpointAdd.invalid`) with nothing said.
- **Candidates are probed in parallel, and the dial spends that proof** (候选探测): a peer with
  several remembered addresses costs one *authenticated* probe per address, all at once — a pinned
  TLS connection plus a `POST /sync/ping` answered with a 204, so an answer proves both that
  something is there and that it accepts this pairing — and the wait is the slowest probe, not their
  sum. The dial spends that answer instead of repeating it: only the addresses the probe reached are
  dialed, best measured round trip first and under a connect budget derived from that same
  measurement, and an address the probe found silent is not dialed at all. A probe that reached
  nothing still buys exactly one dial — and it goes to the first remembered address that has **ever**
  answered, not merely to the memory's head: freshness decides the *order*, but an old answer is still
  the best thing known about an address, and the head may be one that has never replied while the one
  that worked last time sits behind it. (Only that one guess: this is the state in which the probe has
  already asked every address, and a session may not become a second serial probe.) The beat names the
  address being dialed and never a rank among
  candidates: the ranking already happened, and it happened in parallel. Within the proved group,
  the candidates sharing an IPv4 /24 with an address this device holds come first when two answers
  tie, because the remembered order is a history of networks rather than a statement about the one
  this device is standing on — reachability outranks proximity. A single candidate is dialed
  directly, where the dial already is the probe.
- **Advertised candidates are chosen, not dumped** (候选地址): a device advertises every usable
  unicast address the OS reports — IPv4 and IPv6 alike — minus the interfaces a peer cannot use —
  virtual adapters (VMware,
  VirtualBox, Hyper-V, Docker/WSL), VPN and tunnel interfaces (Tailscale, ZeroTier, WireGuard,
  `tun`/`tap`/`utun`), and a phone's cellular interfaces (`rmnet`, `clat`, `pdp_ip`). A shared
  clone subnet is why they are excluded rather than demoted: two machines running the same
  hypervisor carry the same host-only network, and a joiner trying that candidate reaches itself
  and fails the pin. Names a tethered peer *must* dial stay in: `bridge*` (iPhone hotspot),
  Windows' "Local Area Connection* N" (mobile hotspot) and `swlan*` (Android soft AP). The list is
  capped at four addresses — both families together, in interface order — so the QR stays
  scannable. A public address is never filtered out: campus networks hand out globally routable
  addresses directly (in either family), and filtering to RFC1918 alone left those devices
  advertising nothing at all. IPv6 candidates are global unicast (`2000::/3`) and unique local
  (`fd00::/8`); link-local is never advertised, because `fe80::1`'s zone id belongs to *this*
  device's interface and means nothing to a peer. VPN-only users fall back to typing the address.
- **The listener is one socket on both stacks** (双栈): it binds the IPv6 any-address, which also
  answers IPv4 callers — they arrive mapped, `::ffff:a.b.c.d`, and are normalized to their IPv4
  form before storage, since a mapped literal is a valid address to a socket but not to a URI. A
  machine with IPv6 disabled refuses that bind, and falls back to the IPv4 any-address, which is
  what every release before this one did. A host configured with `bindv6only=1` is a known limit
  rather than a covered case: it *accepts* the `::` bind and then serves IPv6 only, so IPv4 peers
  cannot reach this device and nothing in the listener can notice — the sysctl is not visible from
  the socket.
- **An endpoint is stored bare and bracketed only where a human or a URI reads it**: `fd00::1` in
  the endpoint set and the dial, `[fd00::1]:9527` in the QR payload, the address line and the field
  a user types into. Anything that keeps a host of its own keeps the bare form, so the same peer is
  never remembered under two names.
- **The pairing form names the field that is wrong**: address/port and the pairing code are
  validated and reported separately, so a mistyped address never sends the user to re-check the
  other device. The code is compared with its spaces stripped — the dialog shows it as `123 456`,
  so the space a user copies is not a wrong code.
- **A pairing is announced by the paired device's own name**: the name comes from the record the
  pairing wrote — the same name its card will show — so the scanned and the typed paths say the same
  thing, and re-pairing an already-paired device reads as an update rather than as a first pairing.
  The manual form used to close in silence, which left the one success the user triggered entirely by
  hand as the only unreported one.
- **No LAN discovery is implemented**: mDNS/DNS-SD (`_cuplivo._sync._tcp`) is a *deferred*
  option, not a missing piece — the platform cost (iOS Bonjour declarations and local-network
  permission, Android multicast locks, a Windows inbound UDP 5353 rule) buys endpoint
  auto-healing that the remembered endpoint set already covers for every network the pair has
  met, and a re-scan covers for the first visit to a new one. The naming is reserved so adding it
  later is purely additive.
- **Endpoint drift (端点漂移) is a normal, self-healing state**: the DHCP/network change that
  moves a peer makes a session probe its remembered endpoints; the one that answers becomes the
  new head. `unreachable` means *none* of them answered — the peer is off, or it is on a network
  this device has never met, and the two repairs are re-scanning its QR (which updates the set and
  rotates the secret) or typing the address on its card. A drifted endpoint is a connectivity
  failure, reported as such — never a discovery failure. A Windows privacy address that rotated out
  from under an advertised IPv6 endpoint is the same kind of drift, healed the same way.
- **Reaching a candidate is not the same as it being the peer**: an endpoint that cannot be
  connected (refused, timed out) and one that answers with the wrong certificate both fail to
  become the address a session runs on — the pin refuses the wrong device inside the handshake,
  before any request byte, so nothing leaks. That verdict is taken at the probe now: an address
  presenting another device's certificate simply does not answer, so the dial never spends a
  session on it, and the peer's other addresses are still untried. Pairing follows the same
  rule: a QR whose first address belongs to something else still pairs on the address behind it,
  and when *every* address answered as another device the failure says exactly that
  (`fingerprint_mismatch` — a re-scan, not a retry). A *refusal* is different: it is that peer's
  verdict, and its other addresses would only repeat it, so the attempt ends. That covers the
  pairing code too — a wrong PIN is the scanned device answering.
- **The advertised address list is a live fact, and the QR follows it**: the list is re-enumerated
  when the app resumes and when the pairing dialog opens on **either** side — on a desktop, changing
  networks fires no lifecycle event at all, and the entering side advertises its own addresses in
  the pairing request, so a stale list there becomes dead hints in the peer's remembered set. It is
  also the list the dial's order and the probe's tie-break are built from, and a foreground round
  waits for the enumeration rather than racing it: a round that ran first would rank its addresses
  from an empty list, which drops the nearest-subnet tie-break for that round. The QR image is
  re-encoded whenever, and only when, its endpoints changed, so it can never keep advertising a
  network the list underneath it has already left.
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
- **A quiet round that brings data says so (带来数据才吭声)**: a session that delivered
  something to this device announces itself with one toast wherever the user is, one tap from
  the full report dialog — whichever side ran it. The rounds this device starts announce only
  when automatic (a manual press already talks through its card); the rounds a *peer* starts
  that land here through the listener announce too, because this device started nothing and
  would otherwise never hear that the phone's day just arrived. What counts is what *arrived*:
  a session that moved nothing stays quiet (a toast per resume would be noise), and so does one
  that only sent — the news is on the other device, even when the rows that went out were
  business rows, whose report counters deliberately add both directions for the card. Failures
  and refusals stay quiet too (routine on a LAN; the card carries them). While the sync panel
  is *visible* the toast is suppressed — the cards are showing the same news — and visible
  means the user can see it, not that its element is still mounted: the desktop tabs stay
  alive, so a panel left behind on the settings tab stops suppressing.
- **Symmetric version gate (对称拒绝)**: at hello each side refuses a peer whose database
  schema version is newer than its own ("upgrade this device to sync"). Same or older is
  accepted — an older peer's rows merely fill column defaults. Sessions therefore only run
  between equal schema versions; a schema bump pauses sync for the upgrade window instead
  of letting a stale peer mangle newer rows (dropped fields would later win via LWW and
  propagate). The protocol version rides the same exchange; unknown protocol = refuse.
- **N devices, pairwise sessions**: no hub. With A↔B↔C, C receives A's increments through
  B; deterministic idempotent merge makes multi-hop convergence safe. Checkpoints are
  stored per device pair.

- **Session protocol**: a bounded six-beat run over pinned-TLS HTTP (REST-style JSON bodies,
  binary endpoints for blobs and for workspace files): hello (protocol version **7**, schema
  version, the initiator's listener port **and its own candidate addresses**, its clock reading, its
  data epoch, the deletions it has not seen confirmed, checkpoint summaries, and what each side could
  not apply last session) → negotiate (each side computes deltas) → delta exchange (conversation
  subtrees, entity rows, preference keys, the asset manifest for what each side is sending, and each
  side's workspace file tables; the push is acknowledged with what was deferred, including skill
  bodies that did not land, **with the workspace files this side planned and could not land, and with
  the blobs it planned and could not land**) →
  the files and blobs that answer that request, pushed over the connection the initiator opened
  (`PUT /sync/wsfile`, `PUT /sync/blob/<hash>`; **each put is a beat**, because the upload phase
  between the push ack and the fetch is work on a live session and must not be swept as idle) →
  blob fetch (receiver pulls by contentHash, skipping
  hashes it already has;
  the responder pulls back over the initiator's advertised listener, and the same reverse
  connection carries its workspace file pulls) → transactional apply + provider reload →
  checkpoint commit on both sides. **One push and one fetch per session**, enforced from both sides: a
  fetch that has not seen its push is refused (`push_required`), and a second push on a session that
  already took one is refused too (`push_already_taken`) — the push beat writes the state the fetch
  beat and the report are built from, while the counters a landing books into keep accumulating, so
  answering a replay would replace the outcome and still count its bytes twice. The push and fetch
  beats always run, even with nothing to send:
  they are also where the responder performs its own blob pull, including the retries its
  checkpoint still owes. Checkpoints also carry what is still owed (pending blobs), the
  skill-content baseline, the workspace file ledger and the peer's data epoch.
- **A probe is a request, not a socket (探针)**: `POST /sync/ping` answers 204 to a peer that
  presents its pairing secret and nothing else — idempotent, writing nothing, authenticated like
  every `/sync/*` route (401 for a pairing that is gone, 503 when the listener is saturated). Its
  whole value is that a success means **reachable *and* still paired**, which is the pair of facts
  a session needs, and it is cheap enough to ask every ten seconds. It is what replaced the bare
  TCP connect that used to decide the online dot: that probe could answer while every session
  failed, because "the port is open" is not "this peer will talk to me".
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
- **The stored state has one merge path per record (一条写入路径)**: the rule above is about *rows*,
  and the same failure lived in the sync plane's own files. A peer record has two owners writing it at
  once — the panel (a rename, an endpoint edit, the measured latency) and a session (`lastSyncedAt`,
  `lastReport`, the endpoint it promoted) — and each wrote the whole record from a copy read earlier,
  so the last writer won. The visible half was the worst: a successful session came back saying
  “never synced”, because the engine holds the peer object for the session's whole length while the
  provider re-reads the list from disk on the session's first state change, and the post-session probe
  write then saved a pre-session snapshot over the outcome. `SyncStore.mutatePeer` reads and writes
  inside one per-peer section, and every merge goes through it; a whole-record write is only the
  record's *origin* (a pairing answer). The same shape was fixed in the workspace settings file
  earlier (the serialized switch write above).
- **Apply yields to generation**: applying changes to a conversation is deferred while a
  generation is actively writing to it.
- **An open conversation is rebuilt, not left behind**: the apply names the conversations it
  changed, and the chat controller rebuilds the window it is showing when that window's
  conversation is among them. At the bottom the window follows the tail — the messages that just
  arrived are what the user picked the device up for — and above the bottom it is rebuilt around
  the first loaded row, so a reader is not thrown to the end. A write that lands while a local
  generation owns the window is held back and applied when that generation ends. Every other
  notification costs one integer comparison (the per-conversation external-write counter), which
  is what keeps the app's own frequent write traffic from rebuilding windows. A *repaired order*
  counts as changed even though no row's content did: every counter such an apply reports stays at
  zero while the timeline on screen is not the one the database now holds, so the order repair
  rides its own flag into the same reload.
- **An open editor keeps its snapshot**: settings and entity editor pages load once and save what
  they show, so a sync apply that lands underneath one is overwritten on save by the row-level LWW
  rule — and, as everywhere else in the merge, the report counts the local rows it replaced. Live
  reloading a form the user is typing into would be worse than the staleness; the doctrine is
  "never silent", not "never stale".

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
  (no address, unreachable, timeout, peer error, internal) that the panel and the stored record
  localize. The exception text — which carries the peer's address and port — goes to the log only; it
  never reaches a card or a snackbar, and an unrecognized or absent reason falls back to a generic
  line rather than nothing — which is what makes adding a reason safe: a record written before this
  one still holds the value it was written with, and that value still reads.
- **No address is not unreachable (无地址≠连不上)**: "this record remembers nowhere to dial" and
  "every remembered address was tried and none answered" are different states with different
  repairs. Nothing is dialed in the first, so "the other device could not be reached" would send the
  user to check a device this app never tried to reach; it carries its own reason (`no_endpoint`) and
  its own line, which asks for an address. The unreachable line, in turn, names the repairs drift
  already defines rather than stating the fact alone.
- **One session per pair (一对设备一个会话)**: a per-peer single-flight lock covers both roles,
  because the responder and the initiator paths write the same checkpoint file from the copy each
  read at its own hello. An initiator round is refused while a session exists for that pair, and a
  hello from a peer this device is initiating to is refused as busy; a simultaneous
  double-initiate refuses both rounds and the next trigger (launch, resume, manual) retries.
- **A round that has not been answered yet yields (预拨号让位)**: until the peer's hello comes back,
  a round has proved nothing — it may be sitting on an address that never answers, which is exactly
  the one-way-LAN case — so a hello *arriving* during its dial supersedes it: the round closes its
  socket, records nothing at all (not even a failure, because the pair's real outcome is arriving
  from the other side) and lets the inbound session run. Once the hello has been answered the round
  is a live session, and a peer hello is refused as busy instead.
- **A yielded session is provisional (让位来的会话是暂定的)**: the session a superseded round leaves
  behind is a bet that the peer's own client is still there to drive it. In a crossing dial — both
  devices deciding in the same moment — both sides make that bet, so neither client survives and
  each side holds a session nobody will push into; without an expiry that pair stayed busy until the
  listener restarted, because the only sweep lived at the top of the very handler a pair refusing
  its own dials never reaches. A yielded session the peer has not pushed into within four seconds is
  therefore dropped before this device refuses its own round as busy, which makes a crossing cost
  one attempt instead of a restart. A refusal as busy **or as superseded** buys one retry after five
  seconds from **every** trigger (a manual press and a finished pairing included, not just the
  automatic round), delayed by an offset derived from this device's id so two colliding devices
  cannot retry in lockstep — plus a fresh random salt per attempt on the superseded path, because a
  fixed offset is the same offset every time and a pair whose triggers keep landing in the same
  instant would keep crossing. Two limits belong together here: the listener answers at most
  `kMaxPingsInFlight` probes at once and one probe round asks at most `kSyncProbeConcurrency`
  addresses, derived from the endpoint cap in `sync_limits.dart` so a peer's full address memory can
  never saturate its own listener (which would answer `ping_busy`, i.e. "no verdict", for every
  address the round was run to measure). **A cap per round is not a cap per device**, and there is
  more than one round — the tick runs one per peer concurrently and a session adds its own — so the
  probes take slots from one device-wide pool shared by both paths and every peer. That is what makes
  the derivation above a fact about the device rather than about a call: nothing bounds the number of
  paired peers, so no constant could cover `P × kSyncProbeConcurrency`.
- **A session is idle, not old (会话看空闲，不看年龄)**: the held session is dropped when nothing has
  happened on it for two minutes, measured from the peer's last beat — a beat **in flight counts as
  activity** however long it runs, because a first sync of a large library is one push beat lasting
  minutes and killing it makes the peer's own next beat fail against a session the sweep deleted.
  The other rule is the four-second one above (a yielded session never beaten). Both run before
  `syncWithPeer` refuses a round, since a session nobody drives is what does the refusing.
- **One push, then one fetch (先推后取)**: the fetch beat is the second half of a session and is
  refused (`409 push_required`) without the push it belongs to — the responder's workspace ledger is
  produced by that push, so answering anyway would persist an empty ledger, which reads next session
  as "we never agreed about these files" (re-transfer) and turns a file deleted here into one the
  peer never had. A beat that belongs to no live session is refused too (`409
  sync_session_missing`), rather than surfacing as an internal 500.
- **A peer that cannot be dialled back gets pushed to (回连不上就推给它)**: the reverse connection is
  tried over the address the initiator's connection arrived from and then over the addresses its
  hello advertised and the ones this pair remembers (`kMaxReverseDialCandidates`), and **each
  candidate is pinged before it is used** — opening a session is lazy, so a session object is not
  evidence that the peer is there, and a self-dial (the certificate pin refusing this device's own
  listener) then costs milliseconds. When no candidate answers, the responder asks for the files it
  could not land in its push acknowledgement and the initiator pushes them; a miss that a push
  repaired is not also reported as missing. **The blob plane rides the same fallback** — the
  acknowledgement also names the blobs it planned and could not land, and the initiator pushes the
  ones it still backs at that hash (`PUT /sync/blob/<hash>`, kind and key in headers). The receiver
  verifies either way (a file by sha256, a skill directory by re-hashing the extracted tree), so the
  push adds no new kind of trust. A pushed **skill body** is paired with its record in the same
  session: the record was stripped from the business apply while the body was missing, and a
  row-less directory is adopted by the skills rescan as a fresh record stamped *now*, which would
  beat the peer's own record on the next merge. A session whose skill body was pushed therefore
  applies that one record late; the acknowledgement was already sent, so the peer keeps a one-session
  stale baseline and re-offers the record, which converges with no transfer.
- **An address of this device is never remembered as the peer's (本机地址不入端点)**: a NAT rewrites
  the source of a caller's connection to whoever forwards it — an Android emulator makes it the
  host's own LAN address — so the "address the peer connected from" is checked against this device's
  own addresses (and only that: loopback is *not* refused, because another instance of this app on
  one machine is a legitimate peer at 127.0.0.1) before it is stored or promoted as an endpoint.
- **An advertisement lives inside its session (广告不跨会话)**: the files this device tells a peer it
  can serve are a per-session promise: dropped when the initiator's round ends, when the peer is
  unpaired or revokes, when a workspace is switched off, and at the next hello (the responder's table
  has to outlive the fetch response, because the initiator pulls *after* it — the files are served
  from that table by stamp-checked path).
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

- The user-facing surface is a settings section only, in one order on phone and desktop: this
  device (name + system + listening port — **no address**), the workspaces (one row per managed
  workspace: `files · size` and a state pill — syncing / too large / unreadable / off — with a
  switch), the pairing entry ("add device" — show a pairing QR on this device, scan or type the
  code from another), and one card per paired device (name, platform, how long ago, one tile per
  remembered address, sync now, and a ⋯ menu for renaming the device or unpairing it). The rules
  that need prose live behind an ⓘ on each section header rather than in footnotes. **Pairing is
  the opt-in** — there is no master switch, and no global chrome (no sync icon outside the panel).
- **The online dot reports answers, never attempts (在线点只报答案)**: a green dot means
  something answered, and there are three kinds of answer — a remembered endpoint accepted the
  authenticated probe (a ten-second tick that asks the two best-answered addresses, and the silent
  tail only on a full round: start, resume, a panel opening, a finished session, a completed
  pairing — and that tail rotates, least recently asked first, so an address behind the head is
  proved within a few rounds instead of never), a finished session got a reply (a refusal is an
  answer too), or a running session has
  passed its dial and is exchanging bytes right now. A round merely *starting* proves nothing: the
  dot used to turn green on a session's way in, so every automatic round against a sleeping peer
  showed green for exactly the seconds its dial spent failing — trying is not reaching. One probe
  miss and one `ping_busy` are both forgiven: the first is a probe losing a race against a Wi-Fi
  that is waking up, the second is the listener saying "not now", and a dot that flickers gray
  every ten seconds is worse than one a tick stale. **One `ping_busy` anywhere in a round forgives
  that round**, not only a round made of nothing else: the 503 arrives over the *pinned* handshake, so
  the device at that address proved it is this peer and then declined to be judged — stronger presence
  evidence than the silence of a remembered address beside it — and requiring every answer to be
  no-verdict let one silent memory turn a live peer's full round into a miss, two of which darkened
  the dot. That forgiveness is also not only about the dot:
  a `ping_busy` is stored as no verdict at all — on **every** path that stores a probe answer (the
  tick and the round a session runs for itself share one choke point; the rule used to live on one
  of them) — so it can neither replace a measured latency on the
  address's tile and detail nor stamp a fresh "last measured" on the peer record. The source is
  recorded, not just the verdict:
  an answered probe is fresh evidence about the *address* and becomes the stated source, a
  session's own verdict settles the dot when it ends, and the tooltip says which of the two is
  being reported. Which of the two verdicts the label carries follows the dot itself, not the source
  alone: a session that found silence is a grey dot that says "could not connect", never a tooltip
  claiming the last sync connected.
- **The card shows the facts a user acts on**: "last synced" is how long ago, not a timestamp — the
  question on that line is recency, the exact time rides in the tooltip, and past a week the date
  returns, because at nine days old the date is the more useful fact. The addresses are a grid of
  tiles, three to a row, each naming what that network is *called* and what it last measured; the
  address is the tile's identity, so the header carries no IP at all. A tile whose last probe did
  not answer shows `—`, never a stale figure: the persisted measurement, the number of sessions the
  address has carried and when it was added belong to that address's own detail view, which is also
  where it is renamed, edited or deleted. The connecting beat names the address it is dialing and
  never a rank among candidates — the probe ranked every address at once, so "the second of three"
  would describe an implementation detail the user cannot act on.
- **Listener lifecycle**: the listener runs whenever the app runs, on a preferred port
  (`9527`) that falls back to an ephemeral one when taken, so a peer's stored endpoint and the
  Windows firewall rule stay stable across launches. On Windows the inbound rule is
  port-scoped (`Cuplivo-Sync-TCP-<port>`, no spaces or parentheses so `netsh` quoting
  survives both a plain call and a UAC re-invocation); the preferred port's rule persists, an
  ephemeral port's rule is deleted best-effort on stop. Adding it without administrator rights
  fails silently, so the panel offers a one-click elevated retry.
- **Nothing silent, except the routine absence**: the per-session report lists transfers, conflicts
  and their losers — business rows whose local *content* an incoming newer row replaced (LWW losers,
  counted per face), skill-content losers, and workspace files the peer's newer copy replaced — plus
  blobs that arrived, bytes moved, skills whose body converged, workspace files that landed or were
  deleted, workspaces whose content was withheld, and warnings (clock skew, version refusal, files
  that never arrived). A blob or file the peer pushed counts as arrived *here* and never as withheld,
  and the pushing side's own summary names what it sent on the peer's behalf — **including a
  replacement the push performed**: a `peerWins` conflict the fetch could not land and the fallback
  carried is still a local edit that was replaced, so it is counted like the fetched one, and the
  summary never prints “missing 0” beside “pushed 1” for the same file. **A workspace the
  advertised-table cap dropped is counted with the other withheld ones** — it is the only
  shares-nothing reason the user did not choose, and the peer reads it as “not shared” with no
  transfer and no failure to name it. Counters, not per-row
  names: which row lost lives in the log. Adopting a row
  that carries the same content (the peer echoing this device's own row back) is not a loss. The one
  thing the report deliberately does **not** draw is the routine absence — "not reachable right now"
  is a state the card's subtitle already names, and a row repeating it would dress a sleeping peer up
  as an incident.
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

## Context compression (上下文压缩) — ADR-0011

- **Round (轮)**: one user message with non-empty content — the unit both the keep count and the
  dialog's round total count. An assistant reply is never a round of its own, and the kept region
  always begins on a round, so a reply is never separated from the request that produced it.
- **Keep-N (保留N轮)**: summarize every round before the last N, keep the last N rounds (and
  everything after them) verbatim, and fork the conversation as `summary + kept`. The other three
  modes (start / recent / unlimited) send a character window to the summarizer and keep no region
  at all — what falls outside that window is dropped, not summarized.
- **Compression readout (压缩读数)**: what one compression costs before and after, in tokens —
  rounds above tokens on each side, with the reduction over the arrow between them (the shape the
  image editor already uses, ADR-0002 节省). The percentage is the **midpoint** of the result band,
  while the band itself stays on the right-hand side: the summary's own length is the quantity that
  is genuinely unknown, so it is the one that keeps its range. It is counted once, the first time the
  keep-N readout is displayed — the default mode shows no readout, and counting is linear in text
  volume.
- **Estimate basis (估算口径)**: the readout counts what the model would see for a message — body,
  tool call names and arguments, tool results, and images — because tool payloads are usually the
  larger half of a working conversation. Images are charged the unknown-size placeholder
  (`kUnknownImageTokens`), the same charge the context-usage buckets apply: every attached image part
  plus every typed `metadata.mcpResult` image of a tool result. A model without image input receives
  a text marker instead and is still charged, so the error is always toward over-counting. It does
  **not** count reasoning. It is also **not** the text a compression request carries: requests stay
  body-only (`conversationLineForCompression`), so the estimate can be honest about the conversation
  without making a request larger.
- **The split is a token sum, never a character ratio**: character share equals token share only
  when both spans carry the same content mix, and the keep-N cut is exactly where they differ —
  prose against a tool-heavy turn. Measured on the ported estimator, 115 Chinese characters and 700
  ASCII letters both cost ≈100 tokens, so a character-based split would report that kept tail as an
  order of magnitude larger than it is.
- **Result band (压缩后区间)**: the summary is assumed to survive at 10%–30% **of the text the
  summarizer reads** — the body-only tokens of the summarized span, never the tool-inclusive total
  that the two visible numbers describe. Both ends are shown; the reduction percentage is derived
  from the band's midpoint. The band is an assumption, not a measurement, and no number in the dialog
  is more precise than that.

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
