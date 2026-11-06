# A — ownership and order ride; openness stays home

**Status:** accepted (round `clarity-mw32ggrw-0c75de`, 2026-11-05) and implemented on this
branch. The deltas between this design and the code are in §Implementation notes.

LAN sync sends *what the setup is*: which provider sits in which group, which tag
belongs to which assistant, which world books and instruction injections an
assistant has enabled, and where the order of a synced list puts them.

It does not send *what this screen is doing*: which sections are collapsed.

## The problem this replaces

`BusinessKeyRegistry` (`lib/core/database/business_settings_router.dart:18`) is
four hand-written sets. 186 business preferences, 77 synced, and **109 keys in a
middle state** — backed up, never synced — where only a prose comment (if that)
says why. `classify()` returns the disposition `preference` for all 109, so
"backed up but not synced" is indistinguishable from "correctly local".

The two keys #1062 reports and the two #1054 reports are four of those 109. Two
tests pin the state rather than catch it: the writer scan
(`test/core/database/business_key_registry_sync_test.dart:139`) fails only on
`unknownPreference`, and `:51` asserts the instruction-injection key *must not*
sync.

## The table (both variants share this core)

One row per key, one policy, one reason from a **closed** enum. No key can be in
two policies; no synced key can be missing from the backup.

```dart
enum KeyPolicy { synced, backupOnly, localOnly, discarded }

enum PolicyReason {
  syncCompanionOfEntity,   // ownership/organization of an entity that travels
  newDeviceConfiguration,  // configuration a new device wants as its own
  deviceViewState,         // collapsed sets, open flags, panel/tab width
  windowGeometry,          // window position, size, maximized
  sessionPosition,         // where this device is looking right now
  platformCapability,      // an OS/hardware feature or fallback
  networkEnvironment,      // this device's network path and patience
  runtimeDiagnostics,      // logs, counters, traces
  backupScheduleState,     // this device's schedule and run stamps
  deviceStoragePath,       // a filesystem location on this device
  droppedLegacy,           // a key only read to discard it
}

final class KeyRule {
  const KeyRule(this.policy, this.reason, [this.note = '']);
  final KeyPolicy policy;
  final PolicyReason reason;
  final String note; // for the reader; never an input to CI
}

// 206 rows: the 186 business preferences + 14 platform-only + 6 discarded.
static const rules = <String, KeyRule>{
  'theme_mode_v1': KeyRule(KeyPolicy.synced, PolicyReason.newDeviceConfiguration),
  'provider_group_map_v1': KeyRule(
    KeyPolicy.synced,
    PolicyReason.syncCompanionOfEntity,
    'providerKey → groupId; the groups themselves travel as rows',
  ),
  'provider_group_collapsed_v1': KeyRule(
    KeyPolicy.backupOnly,
    PolicyReason.deviceViewState,
  ),
  'window_width_v1': KeyRule(KeyPolicy.localOnly, PolicyReason.windowGeometry),
  // …
};
```

Every question the code asks becomes a derived query over that one map — the
four sets and `BusinessKeyDisposition` disappear:

```dart
static bool isSynced(String key) => rules[key]?.policy == KeyPolicy.synced;
static bool livesInBusinessStore(String key) => switch (rules[key]?.policy) {
  KeyPolicy.synced || KeyPolicy.backupOnly => true,
  _ => false,
};
static bool isDeviceLocal(String key) => rules[key]?.policy == KeyPolicy.localOnly;
static bool isDiscarded(String key)  => rules[key]?.policy == KeyPolicy.discarded;
static BusinessEntityKind? entityKindFor(String key) // unchanged, from the enum
```

Entity source keys (`assistants_v1`, `provider_configs_v1`, …) stay outside the
table: they are rows, not preferences, and `BusinessEntityKind` already owns
them. `providers_order_v1` is a third shape — a *projection*: it is never
stored, `exportSnapshot` writes it from the provider rows' `sort_order`
(`business_settings_router.dart:498`), and the runtime view is republished from
those rows (`business_preferences.dart:260,279`). **No membership change there**;
the table gets a test instead of a row.

## The companion table

The table has the same shape in both variants; which preference keys organize
which entity kind. `classify` cannot see this today, which is why the same
defect keeps coming back in a new family.

```dart
static const companionKeys = <BusinessEntityKind, Set<String>>{
  assistant: {
    'assistant_tag_map_v1',
    'instruction_injections_active_ids_by_assistant_v1',
    'world_books_active_ids_by_assistant_v1',
  },
  provider: {'provider_group_map_v1'},
  providerGroup: {'provider_group_map_v1'},
  worldBook: {'world_books_active_ids_by_assistant_v1'},
  instructionInjection: {'instruction_injections_active_ids_by_assistant_v1'},
  assistantTag: {'assistant_tag_map_v1'},
  mcpServer: {'mcp_presentation_v1'},
  assistantMemory: {}, quickPhrase: {}, searchService: {}, ttsService: {},
  memoryEntry: {}, workspace: {}, skill: {}, groupChat: {},
  userProfileField: {},
};
```

The test is exhaustive over `BusinessEntityKind.values`, so a new kind must add
a row (possibly empty) or the test fails, and every listed companion must be
`synced`.

## This variant's membership

| key | what it holds | policy |
|---|---|---|
| `provider_group_map_v1` | providerKey → groupId | **synced** |
| `assistant_tag_map_v1` | assistantId → tagId | **synced** |
| `instruction_injections_active_ids_by_assistant_v1` | assistantId → injection ids | **synced** |
| `world_books_active_ids_by_assistant_v1` | assistantId → book ids | **synced** |
| `provider_ungrouped_position_v1` | where the "ungrouped" bucket sits in the group order | **synced** |
| `provider_group_collapsed_v1` | groupId → collapsed | backupOnly |
| `assistant_tag_collapsed_v1` | tagId → collapsed | backupOnly |
| `world_books_collapsed_v1` | bookId → collapsed | backupOnly |
| `instruction_injection_group_collapsed_v1` | groupKey → collapsed | backupOnly |
| `mcp_presentation_v1` | MCP groups + per-server group/icon + collapsed | synced (unchanged) |

`provider_ungrouped_position_v1` is the one key the issue did not list. It is a
position in a list of synced groups, like the `sort_order` that already travels
with each row and the `chat_owner_order_v1` the sidebar already syncs — so it is
order, and order rides. The four collapsed keys are openness, and openness is
where this device is looking, like `current_assistant_id_v1`.

**MCP is the documented carve-out, not an oversight.** `mcp_presentation_v1` is
one JSON blob in which MCP's groups, each server's group and icon, and the
collapsed set are co-stored. The ownership half must travel; splitting the
collapsed set out of the blob is a separate change (it changes the merge rule in
`business_settings_merger.dart:125`). The table's `note` says so, so the next
reader does not "fix" the inconsistency.

## What a paired device does

- First pairing: every group arrives populated, every assistant has its books
  and injections checked, the group list is in the same order — and every
  section is expanded (except MCP's, which arrives as the blob says).
- Later sessions: regrouping on the PC moves the phone's page too. Collapsing a
  group on the PC does nothing to the phone.
- A collapsed state is never overwritten on either device by sync.

## Failure modes, accepted on purpose

1. **Whole-value LWW.** A synced preference is one row: the newer *value* wins,
   verbatim (`business_repository.dart:903`). Two devices that regroup at once
   do not merge their maps — the loser's map is replaced, its lost assignments
   are staged in the recycle bin and counted in the session report. Merging
   entry-wise at apply is rejected: each side would store a value the other never
   had, the digests would never agree, and the row would be re-sent forever.
2. **Dangling ids are inert.** A map entry naming a provider or book that never
   arrived is filtered at read time (`instruction_injection_store.dart:216`,
   `world_book_store.dart`), so ordering between entity and preference rows in a
   batch cannot break a screen. Entity rows are applied before preferences
   (`business_repository.dart:840` then `:903`), so the same batch is complete.
3. **An older peer ignores the key.** The read and apply paths are
   registry-filtered, so a device on an older build neither advertises nor
   accepts it: one-way transfer until both are updated, no protocol bump. The
   push acknowledgement counts rows, it does not name them — a row the peer
   dropped and a row it stored are the same `success` — so the checkpoint now
   records an agreement only on a receipt: the responder names the rows it holds
   (`businessAccepted`, an additive ack field an older peer omits) or its own
   manifest advertises them (`sync_engine.dart`, `_advanceBusinessCheckpoint`).
   A row with neither receipt is offered again every session; nothing is deleted
   here on the strength of the peer's silence. This paragraph was wrong when it
   was written: the receipt was the acknowledgement's `success` alone, so the
   *second* session read "the peer lacks a row I agreed to" as a deletion and
   removed the value from the updated device. Found in review of #1068,
   reproduced end to end, and pinned by the integration test named for it.
4. **Reason rot.** A free-text `note` cannot be a reason. The enum is the reason;
   a test asserts every value has at least one key (no dead buckets) and that
   `syncCompanionOfEntity` appears only on `synced` rows.
5. **The discovery blind spot.** `JsonBlobStore.writeAll` writes
   `setString(storageKey, …)` — a getter, which the source scan cannot follow
   (`json_blob_store.dart:49`); `desktop_scheduled_tasks_v1` is the key that got
   in that way. The scan resolves one-hop getters, and
   `BusinessPreferences.setMany` gets a debug-only assert that the key is in the
   table. Both are part of this work, because an exhaustive test is only as
   trustworthy as the discovery it exhausts.

## Tests that pin it

1. **Partition.** Every key written through a preference setter (getter-resolved)
   is in the table; `restore_*` is the only dynamic family.
2. **Membership pin.** The synced set is asserted as a literal list: 82 keys.
   A change to the wire face is a deliberate edit, not a count.
3. **Companion.** Exhaustive over kinds; companions synced.
4. **Name rules.** `_by_assistant$|_tag_map_v1|_group_map_v1` ⇒ synced;
   `window_*|desktop_*|display_*` ⇒ not synced. A new key that contradicts its
   own name fails before anyone reviews the table.
5. **Reason hygiene.** Every reason value used; no companion reason on an
   unsynced row.
6. **Behaviour.** `business_repository_sync_test.dart` applies a batch carrying
   the five keys and asserts the rows land and the panels read them back through
   the registered reloaders (`lib/main.dart:144`).
7. **Receipt.** `sync_engine_integration_test.dart` hosts the previous build on
   one side (`_LegacyPeerPlane`: the key is neither advertised nor accepted),
   syncs twice and asserts the row survives here, that the bin is empty, and that
   no agreement was recorded — then stops hiding the key and asserts the pair
   converges in two more sessions. Reverting the guard makes the first of those
   assertions fail.

Each guard is shown to fail against the violation it guards before it lands.

## Order of work

1. Table + derived queries + the 206 rows, membership unchanged (zero wire
   change; the pin proves the derived sets equal today's lists).
2. Companion table + exhaustive test + name rules — fails on today's registry,
   naming exactly the four #1062/#1054 keys.
3. Flip the five rows to `synced`; correct the `:51` assertion. The bug is fixed
   by a one-line-per-key edit that the tests demanded.
4. Discovery gate (getter resolution, debug assert).

## What this forecloses

- A collapsed section will never be shared between devices; a user re-collapses
  on each device. If that is wanted later it is one new reason value plus four
  membership flips — but the doctrine comment must change with it.
- MCP's collapsed set keeps riding inside a blob that has to sync, so the rule
  is "value state stays local, except where ownership is co-stored". One
  carve-out, documented, forever — unless the blob is split.
- The table is 278 rows of review surface. That is the price of the middle state
  disappearing; the alternative is the state coming back.

## Implementation notes (2026-11-05)

The code differs from the design above in six places, each a consequence of
what the repository turned out to hold:

1. **Five policies, not four.** `BackupPortability.devicePreferenceKeys` was a
   second hand list answering a question the registry could not: seven business
   preferences that are stored in `preference_rows` and carried *nowhere* — not
   even by a travelling backup. Folding them into `backupOnly` would have been a
   lie and would have put them into backups. They are `deviceLocal`, the list is
   now derived from the table, and the class is the fifth value.
2. **The table has 278 rows, not 206.** The `display_*` family (81 keys) was
   classified by a prefix fallback rather than by a list, and they are written to
   the business store. The prefix is now a *test* (`display_*` ⇒ not synced) and
   the rows are explicit: `backupOnly` / `deviceViewState`.
3. **Reason names.** `backupScheduleState` became `deviceScheduleState` (it also
   covers local snapshots and scheduled tasks) and `droppedLegacy` became
   `legacyBookkeeping` (it also covers a live migration marker). One value was
   added: `notYetReviewed`, see 4.
4. **`notYetReviewed` exists, with 23 keys.** When every row had to name a
   reason, 23 keys had none that was true: image compression settings, the chat
   editing toggles, the per-user bubble style, learning mode, the care decision
   model. They are configuration the new-device test would likely *accept*, and
   they have never been decided. Inventing "platformCapability" for an image
   quality setting is exactly the defect this refactor removes, so the table says
   `notYetReviewed` and a test pins the list: it can only shrink, by deciding.
   The 109-key middle state is therefore 86 reasoned rows plus 23 named ones.
5. **The discovery gate is scoped.** The debug assert in
   `BusinessPreferences.setMany` fires for app-shaped keys (`…_vN`) only, so a
   foreign key — a plugin's, a restored artifact's — is still stored and
   fail-closed instead of crashing a debug build. The name pattern itself is one
   definition (`BusinessKeyRegistry.appKeyPattern`), read by that assert and by
   the writer scan, so widening the convention cannot leave one guard blind to
   what the other enforces.
6. **An agreement needs a receipt.** Found in review of #1068: the checkpoint
   advanced an `iSend` on the strength of the push acknowledgement, which counts
   rows but cannot say which ones the peer refused — an older build skips a key
   it does not sync at apply and answers success. The next session then found the
   row absent on the peer and planned `iDelete`, deleting the user's groups, tags
   and book bindings from the *updated* device (staged in the recycle bin, and
   absent from the session report, so silent). The acknowledgement now names the
   rows the responder holds (`businessAccepted`: `SyncApplyAck` gains one
   optional field, no protocol bump — an older peer omits it, which reads as "no
   receipt"), and a row the peer's own manifest advertises counts too, which
   covers a row it already had. A row with neither receipt is offered again next
   session instead of being withdrawn. This is a rule about the *plan*, not about
   the five keys: any future synced key or entity kind faces the same
   older-peer window.

What the code settles that the design did not spell out: `classify()` and
`BusinessKeyDisposition` are gone, and the seven call sites ask one predicate
each (`isSynced`, `isProviderOrder`, `isPlatformOnly`, `isDiscarded`,
`isDeviceLocal`). An unknown key is still routed into preferences exactly as
before — it just never syncs. The companion table and the four organization keys
are covered by a repository-level test (`business_repository_sync_test.dart`,
"the organization keys travel to a peer"), and each of the three new guards was
shown to fail against the violation it guards before it landed.

