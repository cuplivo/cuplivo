# Issue #123 + Backup v2 — Implementation Control Contract

Status: **IMPLEMENTED** (slices A-G landed on `refactor/preferences-sqlite` in
two commits: `3f50e241` KV migration, `22f34df2` JSONL+LWW backup v2).

Branch: `refactor/preferences-sqlite`
Scope decisions resolved in the design grill (mirror CONTEXT.md additions + ADR-0048).

## Primary Setpoint

1. **Migration**: Move all business SharedPreferences keys into a SQLite KV table
   (`preference_rows(key, value, updated_at)`) via a one-shot startup gate, with
   `BusinessPreferences` as the single writer facade. Except: `assistants_v1`
   (owned by typed `assistant_rows` + data_sync), and the localOnly set
   (upstream 9 + `codex_oauth_v1` + `grok_oauth_v1` + `chat_draft_v1`).
2. **Backup v2**: Export chats as JSONL streams
   (`chats_meta.json` sentinel + `conversations.jsonl` + `messages.jsonl`, events
   inlined per-message line) instead of one `chats.json` blob, and ship a
   `settings_meta.json` (key → updated_at) enabling per-key LWW preference
   merge on restore. Old zips and old builds stay back-compatible.

## Acceptance

- `dart run build_runner build --delete-conflicting-outputs` clean (new table).
- `dart format` on changed paths; `dart analyze --fatal-infos lib test` green.
- New unit tests (see Slice tests) + existing related tests green:
  `data_sync_backup_file_test.dart`, `schema_heal_discoverable_test.dart`,
  `chat_database_repository_test.dart`.
- Full manual test plan (below) executed on Windows + one mobile platform.
- Docs: AGENTS.md `§3.14` sentence "Lightweight settings use shared_preferences"
  updated to "business preferences use SQLite KV (BusinessPreferences);
  device-local state keeps shared_preferences" — same change as the code.
- NO regressions: provider proxy local-wins (#512), per-id dedupe merges,
  KelivoV2BackupException, `cuplivo_incr_` forced-merge, backup round-trip
  byte-compatibility with Kelivo settings schema.

## Guardrails

- No consumer may write `preference_rows` directly; all writes go through
  `BusinessPreferences` (single-writer). Direct SQL writes only inside
  restore/migration engine, followed by facade `reload()`/cache update.
- LWW applies to **scalar preferences only**; structured keys keep existing
  per-id merges as the final refinement over the LWW-chosen base.
- Chat merge stays **ID-skip** (never LWW, never wholesale replace).
- `assistants_v1` never written to SharedPreferences (AGENTS §3.14 hard rule);
  its wire path stays in data_sync unmodified.
- Migration failure keeps legacy SP data intact (no receipt → retry next
  launch); degrade-to-defaults only for the documented recoverable validation
  class, with a log (no silent swallow).
- Killed-process proactive-care isolate reads/writes KV table directly
  (no SP), never touches SP: a pre-migration alarm reads empty → graceful skip.

## Boundary

In scope:
- `lib/core/database/app_database.dart` (+ `.g.dart` regen): `PreferenceRows`
  table, schemaVersion 19 → 20, `_healSchemaIfNeeded` addition.
- New: `lib/core/database/business_data.dart`, `business_repository.dart`,
  `business_preferences.dart` (+ `business_preferences_store.dart`),
  `business_migration_engine.dart`, `business_startup_gate.dart`,
  `business_key_registry.dart` (classify entities/localOnly/discarded/preference).
- `lib/main.dart` (gate call before runApp).
- The 34 SP-consuming files: API-only swap
  (`SharedPreferences.getInstance()` → facade; `setMockInitialValues` → facade).
  Keeps own SP: window_size_manager, hotkey_provider, codex/grok oauth
  controllers, input_draft_persistence, main's flutter-log read,
  provenance file in app_directories → **unchanged**.
- `lib/core/services/backup/data_sync.dart`: export of
  `settings_meta.json` + JSONL files; restore sentinel branch; LWW merge;
  `SharedPreferencesAsync` re-pointed at facade.
- `_exportChatsToFile`/`_restoreFromBackupFile`/`_packZipSync`/
  `analyzeIncrementalScope` table-set updates.
- `lib/core/services/proactive_care_message_flow.dart` +
  `proactive_care_alarm_service.dart`: SP reads/writes → KV reads/writes
  (own facade instance in isolate).
- `lib/core/services/backup/restore_refresher.dart`: add
  `BusinessPreferences.reload()`.
- Tests: `test/core/database/business_*`, `test/core/services/backup/`
  jsonl/lww tests, migrate vs mock in existing provider tests.

Out of scope: entity-table routing (upstream's 13 BusinessEntityKind tables),
upstream's BusinessSettingsMerger/router port, upstream media DB, Hive legacy,
`memoryEntry`/`userProfileField`.

## Slices

### Slice A — Schema + repository (land first)
- `PreferenceRows(key TEXT PK, value TEXT, updated_at INTEGER)` in
  `app_database.dart`; schemaVersion 20 + v20 migration step; heal set entry
  (`_ensureTable`) + `schema_heal_discoverable_test.dart` row.
- `BusinessRepository` (drift custom SQL): readSnapshot/setPreference/
  removePreference/clearAll/checkpoint (`PRAGMA wal_checkpoint(FULL)`),
  hasMigrationReceipt/writeMigrationReceipt (in `chat_storage_meta_rows`),
  `sharesDatabaseIdentity`.
- `business_data.dart`: `BusinessEntityValue`-free KV snapshot type
  (`Map<String, (Object?> value, int updatedAt)>`).
- Tests: repository round-trip, receipt, checkpoint identity.

### Slice B — Facade + store interface
- `BusinessPreferencesStore` abstract: `loadAll/write/remove/clear`.
  `SqliteBusinessStore` (wraps repository), `MemoryBusinessStore` (tests).
- `BusinessPreferences`: sync getters, async `setX`/`remove` over serialized
  `_writeTail` tail (cache updates after repo success), `load()`,
  `reload()`, `getKeys/containsKey`, static `instance` + `setMockInitialValues`
  (`@visibleForTesting`, swaps `MemoryBusinessStore`).
- `BusinessKeyRegistry.classify(key)` — localOnly/discarded/preference/entity
  sets (entity only `assistants_v1`, routed out).
- Tests: mock-seed round trip, concurrent set serialization, localOnly write
  rejection (throws).

### Slice C — Migration engine + startup gate
- `BusinessMigrationEngine.run()` (mirrors upstream):
  snapshot legacy SP → route (skip entity/localOnly/discarded) →
  `replaceSnapshotForMigration` (one transaction; re-read; validate
  deep-equal export; write receipt) → durability barrier
  (`checkpoint(FULL)` busy==0) → cleanup legacy keys; receipt-present →
  deferred cleanup only.
- `BusinessStartupGate.migrateAndLoad` — degrades (log + defaults, legacy kept)
  only for recoverable-class StateErrors; called in `main()` before `runApp`,
  stores `BusinessPreferences.instance`.
- The SP write-fence concept: no other consumer can hold SP handle after
  gate (audit `SharedPreferences` imports — each of the 34 files swapped).
- Tests: migrated/alreadyComplete/cleanedAfterReceipt/deferredCleanup,
  export-mismatch degrade, entity-count validation, log assertions.

### Slice D — Consumer swap (mechanical)
- Replace `package:shared_preferences` import + `SharedPreferences.getInstance()`
  with facade in the 34 files; localOnly-listed files untouched.
- `settings_provider.dart` 182 sites; stores (world_book_store, memory_store,
  quick_phrase_store, instruction_injection_store, learning_mode_store,
  instruction_injection_group_provider, tag_provider, mcp_provider,
  tts_provider, user_provider, assistant_provider, filesystem_mounts_provider,
  backup_reminder_provider, chat_provider, backup/cherry/chatbox importers,
  proactive care flow, data_sync).
- Update `restore_refresher.dart` with `BusinessPreferences.reload()` +
  keep existing per-provider reloads.
- Tests: provider tests switch `SharedPreferences.setMockInitialValues` →
  `BusinessPreferences.setMockInitialValues` (91 files, mechanical);
  any test reading real SP directly gets MemoryStore seed.

### Slice E — settings_meta.json + LWW merge
- Export: `_exportSettingsJson` also writes `settings_meta.json`
  (`{key: {updatedAt}}` for keys present in KV rows; localOnly excluded).
- Restore merge: read meta; scalar keys: incoming wins iff strictly newer;
  structured keys: meta-latest base then existing per-id merge refinement
  (provider proxy #512, memories, mcp servers, tags, groups, orders
  unchanged in shape); no meta → legacy path.
- KV rows for keys not yet written post-migration: no meta entry → legacy.
- Tests: LWW newer/older/tie/absent, structured-with-proxy base selection.

### Slice F — JSONL export/restore
- Export: `conversations.jsonl`, `messages.jsonl` (one wrapped object per line,
  events + signature inline in message object), `chats_meta.json`
  (format_version 2, table list, line counts, groupChats/groupMembers JSON
  payload — groups stay small), written last (completion marker).
- `_packZipSync`, include-file walkers, `analyzeIncrementalScope` mirror the
  new table set; legacy `_bk_chats.json` writes removed from new backups.
- Restore: `chats_meta.json` present → JSONL path; absent → legacy
  `chats.json` path (kept); `manifest.json` → KelivoV2BackupException
  (unchanged, checked first). Count mismatch → abort before any write.
  Truncated trailing line tolerated. Per-conversation chunking
  (memory bounded by one conversation) → existing `restoreConversationsBatch`
  per conv; merge mode = existing-ID skip per message, inline
  events/sigs routed to batch inserts.
- Incremental/LAN-sync zips (forced merge) supported via same streams.
- Backup ZIP filename: keep `cuplivo_...` naming; JSONL identified by sentinel
  only (no filename marker — zips are renamed by SAF/FilePicker anyway).
- Tests: round-trip export→restore byte-level parity, sentinel abort on count
  mismatch, merge ID-skip with inline events, incremental scoped subset.

### Slice G — Process hardening
- Proactive-care isolate: own `BusinessPreferences.open(repository)` on the
  same table; replaced SP reads/writes (model config, thinking budget,
  l10n snapshot, decision model).
- Desktop exit flush hooks (`flushPendingWrites`) if present; async-gap audit
  (no consumer reads before gate completes except blocked-main-path).
- Live restore write fence: restore writes through facade (`restoreSingle`
  already does) so cache never diverges; `reload()` after restore.

## Risks

1. **Dual-writer isolate race** (care alarm isolate vs main) — mitigated by
   WAL + busy_timeout + facade per-isolate instance; care writes are rare.
   Tracked.
2. **Old-build + new-zip residual** — destructive only on manual overwrite
   (clearAllData + absent chats.json); LAN/incremental merge is non-destructive.
   Accepted per ADR-0048, stated in PR description.
3. **91 test files churn** — mechanical but broad; risk of tests silently
   passing by reading stale SP (they must swap `setMockInitialValues`).

## Manual Test Plan

- Upgrade-in-place: existing user's SP (with active providers/worldbooks) →
  first launch migrates → all settings + providers intact in UI → SP keys
  (business) removed, localOnly keys (window size/OAuth/draft) present.
- Fresh install: no SP → freshInstall result, defaults work.
- Backup full/export to ZIP → restore overwrite on second device:
  prefs imported, chats streamed, counts match meta.
- Restore merge on device with edits: newer local scalar kept, newer backup
  scalar wins; provider proxy fields never imported (same as today); LAN sync
  two-device round trip.
- Old Cuplivo ZIP → new build: legacy path works.
- Incremental backup (`cuplivo_incr_`): merge restore of delta zips.
- Killed-process proactive care alarm after migration: sends care message.
- Desktop window resize: geometry persists (SP path unchanged).
