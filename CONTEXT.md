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
- **Clear semantics**: `sent` **and** `queued` clear immediately (the content moved to the
  conversation or the queue; a debounced clear could resurrect it on a crash inside the window).
  `rejected` keeps the draft — the content returns to the bar. Fully empty content (whitespace-only
  text counts as empty) removes the key rather than storing an empty blob. Best-effort guarantee
  only: the prefs write is async fire-and-forget, so a kill inside the platform-channel window can
  still leave a stale key.
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
  the pending and persisted draft's files.

## Community channels (社区入口)

- **Cuplivo QQ group**: `1101061750` — `https://qm.qq.com/q/9Rnnf7XyNO` (the only QQ entry).
- **Cuplivo Discord**: `https://discord.gg/kaTf8CXG4`.
- Upstream Kelivo's community channels are not listed in the app.
