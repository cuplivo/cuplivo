# B — the whole organization view rides

**Status:** not taken. Round `clarity-mw32ggrw-0c75de` chose variant A
(`a-ownership.md`); this file is kept as the record of the alternative and of why
it lost (a peer's collapse can rearrange a screen the user is looking at).

LAN sync sends *what the setup is* **and** *how the organization screen looks*:
which provider sits in which group, which tag and which book an assistant has,
where the group order puts the "ungrouped" bucket — and which sections are
collapsed.

One rule, no carve-out: an organization surface travels whole. That is already
what MCP does.

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
  syncedViewState,         // how a synced organization surface is displayed
  newDeviceConfiguration,  // configuration a new device wants as its own
  deviceViewState,         // this device's own panel/window display state
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
    KeyPolicy.synced,
    PolicyReason.syncedViewState,
    'the organization screen the peer sees',
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

Entity source keys stay outside the table: they are rows, not preferences.
`providers_order_v1` is a third shape — a *projection*: never stored,
`exportSnapshot` writes it from the provider rows' `sort_order`
(`business_settings_router.dart:498`), the runtime view is republished from those
rows (`business_preferences.dart:260,279`). **No membership change there**; the
table gets a test instead of a row.

## The companion table

Both variants add the same one: which preference keys organize which entity
kind. `classify` cannot see this today, which is why the same defect keeps
coming back in a new family.

```dart
static const companionKeys = <BusinessEntityKind, Set<String>>{
  assistant: {
    'assistant_tag_map_v1',
    'instruction_injections_active_ids_by_assistant_v1',
    'world_books_active_ids_by_assistant_v1',
  },
  provider: {'provider_group_map_v1'},
  providerGroup: {'provider_group_map_v1', 'provider_group_collapsed_v1'},
  worldBook: {'world_books_active_ids_by_assistant_v1',
              'world_books_collapsed_v1'},
  instructionInjection: {'instruction_injections_active_ids_by_assistant_v1',
                         'instruction_injection_group_collapsed_v1'},
  assistantTag: {'assistant_tag_map_v1', 'assistant_tag_collapsed_v1'},
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
| `provider_ungrouped_position_v1` | where "ungrouped" sits in the group order | **synced** |
| `provider_group_collapsed_v1` | groupId → collapsed | **synced** |
| `assistant_tag_collapsed_v1` | tagId → collapsed | **synced** |
| `world_books_collapsed_v1` | bookId → collapsed | **synced** |
| `instruction_injection_group_collapsed_v1` | groupKey → collapsed | **synced** |
| `mcp_presentation_v1` | MCP groups + per-server group/icon + collapsed | synced (unchanged) |

A row whose reason is `syncedViewState` may only be `synced` — that is the
distinction from `deviceViewState`, the reason the window geometry and the side
panel width keep. The doctrine is narrowed, not abandoned: *chat* session
position (`current_assistant_id_v1`, `selected_model_v1`) stays local; a
*shared organization surface* travels whole.

## What a paired device does

- First pairing: groups arrive populated and in the same order, every assistant
  has its books and injections checked, and every section arrives expanded or
  collapsed exactly as the PC had it.
- Later sessions: collapsing a group on the PC collapses it on the phone too,
  while the page is open. Regrouping still moves both.
- The MCP carve-out that today's code has to explain disappears: every
  organization screen behaves the same way.

## Failure modes, accepted on purpose

1. **Whole-value LWW.** A synced preference is one row: the newer *value* wins,
   verbatim (`business_repository.dart:903`). Two devices that collapse at once
   do not merge their maps — the loser's map is replaced, staged in the recycle
   bin and counted in the session report. This is cheaper to accept here than for
   ownership maps, because the value being lost is a display flag.
2. **View churn on the wire.** Every collapse/expand is a preference write with a
   new clock, so it becomes a manifest entry and, after a session, a row transfer
   and a reloader pass. Collapsing three sections is three writes; a busy
   organization screen is now a source of session work, where under A it is one
   local SQLite write and nothing else.
3. **Dangling ids are inert.** A map entry naming a provider or book that never
   arrived is filtered at read time (`instruction_injection_store.dart:216`,
   `world_book_store.dart`), so ordering between entity and preference rows in a
   batch cannot break a screen. Entity rows are applied before preferences
   (`business_repository.dart:840` then `:903`).
4. **An older peer ignores the key.** The read and apply paths are
   registry-filtered, so a device on an older build neither advertises nor
   accepts it: one-way transfer until both are updated, no protocol bump.
5. **Reason rot.** A free-text `note` cannot be a reason. The enum is the reason;
   a test asserts every value has at least one key (no dead buckets) and that
   `syncedViewState` appears only on `synced` rows.
6. **The discovery blind spot.** `JsonBlobStore.writeAll` writes
   `setString(storageKey, …)` — a getter, which the source scan cannot follow
   (`json_blob_store.dart:49`); `desktop_scheduled_tasks_v1` is the key that got
   in that way. The scan resolves one-hop getters, and
   `BusinessPreferences.setMany` gets a debug-only assert that the key is in the
   table. An exhaustive test is only as trustworthy as the discovery it
   exhausts.

## Tests that pin it

1. **Partition.** Every key written through a preference setter (getter-resolved)
   is in the table; `restore_*` is the only dynamic family.
2. **Membership pin.** The synced set is asserted as a literal list: 86 keys.
3. **Companion.** Exhaustive over kinds; companions synced.
4. **Name rules.** `_by_assistant$|_tag_map_v1|_group_map_v1` ⇒ synced;
   `window_*|desktop_*|display_*` ⇒ not synced. Every key this variant adds is
   still caught by the first rule, which is the point: the net catches the next
   omission before a reviewer reads the table.
5. **Reason hygiene.** Every reason value used; `syncedViewState` never on an
   unsynced row; `deviceViewState` never on a synced row.
6. **Behaviour.** `business_repository_sync_test.dart` applies a batch carrying
   the five keys and a collapsed map, asserts the rows land, and asserts the
   panels read them back through the registered reloaders (`lib/main.dart:144`).

Each guard is shown to fail against the violation it guards before it lands.

## Order of work

1. Table + derived queries + the 206 rows, membership unchanged (zero wire
   change; the pin proves the derived sets equal today's lists).
2. Companion table + exhaustive test + name rules — fails on today's registry,
   naming exactly the four #1062/#1054 keys.
3. Flip the nine rows to `synced`; correct the `:51` assertion.
4. Discovery gate (getter resolution, debug assert).

## What this forecloses

- The line "view state stays local" is gone for organization surfaces; the next
  proposal to sync the open tab, the side-panel mode or the selected model now
  has a precedent value (`syncedViewState`) rather than a doctrine against it.
- A peer's collapse can rearrange a screen the user is looking at, and the
  session report will count display-flag replacements as lost rows.
- Reverting later is not a quiet edit: users would lose a behaviour they were
  given, so an A-style rule would have to be argued against shipped behaviour,
  not against an empty slot.
