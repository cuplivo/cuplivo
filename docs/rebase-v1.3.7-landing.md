# The v1.3.7 landing — attempt two

Attempt one (branch `backup/v1.3.7-attempt1`) replayed all eighteen units onto `v1.3.7` and is
structurally complete: eighteen commits, the e2e gate reached, `flutter pub get` resolving. It is
**not** green — `dart analyze --fatal-infos` reports 1841 issues — and the pattern of those issues
says the pass resolved conflicts at the wrong altitude: twenty-one decisions were taken at once,
and the damage is spread across six unrelated places with no unit boundary to localise it.

This attempt replays the same eighteen commits **one at a time**, verifying each one before the
next. The first two units also run the test suite, because they are the floor everything else
replays on.

## What attempt one established

The conflict inventory, by unit, with the decision that was taken. This is the map for attempt
two: a unit absent from this list replayed clean.

| unit | conflicts | decision taken |
| --- | --- | --- |
| 1 identity | 104 paths | carry → the replayed commit; everything else → the new base, then swept with `tool/identity/rename.json` |
| 2 baseline-repair | 25 paths (12 ARB, 4 l10n state) | all → the new base; the l10n settle in this unit is v1.3.6-era and must not survive a baseline move |
| 3 recycle | 1 (`storage_space_page`) | new base's `Column` layout, plus `uploads: uploads,` re-added at the call |
| 4 sync-lan | 6 | imports unioned; `desktop_home_page` and `business_migration_engine_test` → new base; `business_settings_router`, `message_builder_service`, `sandbox_path_resolver` → the unit's version |
| 12 suggestions | none | replayed clean |
| 13 group-chat | 10 paths | per block: imports unioned, upstream's independent tests kept beside ours, feature rewrites taken from the unit |
| 14 backup | 4 | `backup.dart`, `data_sync` → new base (upstream rewrote config parsing to `fields.trimmed`); `s3_backup_provider`, `backup_pane` → the unit's version |
| 15 markdown-image | 2 | `desktop_home_page` → the unit's version (it is the one that speaks `DesktopTab`); `desktop_nav_rail` imports unioned |
| 16 image-job | 1 | both tests kept |
| 17 subagent | 3 | both sides concatenated — **this is what broke them** |
| 18 dsh | 1 (`settings_provider`) | the unit's side: `KelivoIN` stays removed |

Two rules the pass proved and attempt two inherits:

1. **In a rebase the stages are reversed from a merge.** Stage 2 is the branch being rebased *onto*
   (upstream); stage 3 is the commit being replayed (ours). Reading them the other way turned the
   whole tree into `name: Kelivo` and produced 65371 `depend_on_referenced_packages` errors — the
   fork's package name came from the wrong side, so every `package:Cuplivo/` import looked foreign.
2. **Concatenating two conflict sides is only safe when they are siblings.** It is right for
   import lists and for two independent `test(` blocks. It is wrong for two method bodies: the
   result parses, because a body is a valid expression list, and the analyzer then reports the
   method's parameters as unused local variables.

## The damage, and where it lands

Attempt one's 1841 issues fall into three classes. Each maps to the unit that should own the fix,
which is the reason for replaying one at a time.

**A. Upstream files that were never swept** (~15 test files). `package:Cuplivo/` still appears in
`test/core/providers/backup_server_settings_test.dart`, `model_provider_list_metadata_test.dart`,
`test/features/backup/import_toolbox_test.dart`, `test/support/backup_page_harness.dart` and
others. These are files v1.3.7 *added*: they never conflict, so the identity replay never touched
them. Rule 19 of the runbook — the brand rename applies to the incoming side — has to be run over
the whole tree, not only over the conflicted paths. **Owner: unit 1.**

**B. Five packages imported but not declared.** `visibility_detector` (`main.dart`,
`provider_balance_badge`), `connectivity_plus` and `clock` (`provider_balance_refresh`),
`chinese_codec` (`text_file_decoder`), `nm`. The fork's pubspec carried them; taking the new
base's `pubspec.yaml` at unit 1 dropped them, and upstream's code still imports them.
**Owner: unit 1**, with the pubspec's `dependencies:` block.

**C. `backup_pane.dart` is structurally broken.** From line ~1056 the file reads
`final StatelessWidget = ...` and `final required = ...`: two method bodies were concatenated and
the analyzer parses each method's parameters as unused locals. Five more files carry dead code
from the same manoeuvre (`chat_message_widget.dart:4757` `child`, `chat_actions.dart:648`
`_copyToolEvents`, `home_view_model.dart:1655` `id`, `home_page.dart:1751` `owner`,
`chat_input_section.dart:239` `showResponseSpeedAction`).
**Owner: the unit that introduced each** — the backup unit for `backup_pane`, the subagent unit for
the other five.

## What unit 1 cost, measured

Replayed one unit at a time, unit 1 produced **19 analyzer issues in the whole tree** — and every one
of them named a merge decision rather than a typo. Four causes, in the order they were found:

**A. `lib/l10n/` was resolved by taking a side, which is the one thing rule 2 forbids.** All seven
ARBs conflicted, the resolver's default wrote upstream's file, and the result was *coherent*: 5140
messages, every `@description` present, valid JSON. It had also lost the fork's 378 keys. The
tell was two strings, not the file: `aboutPageQQGroup` came back undefined while upstream's 96 new
messages were all there. Rebuilt per key against the unit's own tree: 5507 messages, **94** added
from upstream with the brand rename applied, **20** values taken from upstream (18 upstream-changed,
2 name collisions), **5** keys upstream retired in this window dropped with the code that called
them, and the two `miniMapSearch*` collisions resolved to upstream outright.

The plan's §7 expected to rename the fork's `miniMapSearchMatchCount` and keep both. Measured, the
fork's copy has **no caller** at the unit's own tree — its minimap is `mini_map_sheet.dart` — so the
cheaper move was to keep upstream's name, value and plural semantics and let the fork's dead copy go.
Two upstream values genuinely name the other product (`backupPageChatboxUnsupportedBackupVersion`,
`backupPageImportFromOtherAppsSubtitle`: the archive they describe *is* Kelivo's), so they joined the
ARB whitelist rather than being swept — a decision, recorded in `rename.json` and here.

**B. Upstream's v1.3.7 code brings the retired built-in Kelivo search back.** Six files, ten
`KelivoOptions` references, four `'kelivo'` branches in the two type switches, and
`unlockKelivoSearch()` with its two About-page strings. The unit's own tree has none of them: the
fork deleted the service, its options type, its unlock door and the About-page tap handler that
opened it. Rule 9 read backwards: there the *upstream side* retired a mechanism our context still
carried, here the *fork* retired one upstream still carries, and either way the side that retires it
wins — so the incoming references go with the mechanism. The three orphan strings
(`aboutPageCuplivoSearch*`, `searchServiceNameCuplivo`) went too: they were renamed by the identity
sweep and then lost their last caller, so keeping them would have preserved a promise the tree cannot
keep.

**C. The identity sweep ran over the ten files that name the needle.** `tool/identity/rename.json`,
`verify.py`, `test_verify.py`, `.github/workflows/pr-check.yml` and the six documents that record the
substitution (`CONTEXT.md`, `docs/rebase-runbook.md`, `docs/rebase-v1.3.5-forecast.md`,
`docs/rebase-v1.3.6.md`, `docs/rebase-plan-v1.3.7.md`, `docs/flaky-tests.md`). Rewriting
`package:Kelivo/` in the spec turns each substitution into `X → X` and the forward check into "grep
for the name we just adopted": the tool reports *clean*, `dart analyze` reports *clean*, and only
`test_verify.py::test_the_spec_still_spells_the_needles_it_is_exempt_from` fails. The workflow is the
sharpest case — it is the file that *runs* the sweep, and the swept sentence was the one explaining
what the sweep looks for. The same sweep turned `com.psyche.kelivo` into a second
`com.cuplivo.cuplivo` inside `kelivo_file_uri.dart`'s bundle-id whitelist — a set that stays
syntactically valid while every path an older install wrote stops resolving. Three brand strings in
code were also missed rather than over-renamed (`provider_oauth_adapter`'s two headers,
`keenable_search_service`'s `appTitle`, and `tool_image`'s iOS prompt plus its test), and
`assets/skills/skill-creator/SKILL.md` had upstream's unbranded rewrite merged over the fork's.

The permanent answer is in the spec and the runbook: `com.psyche.kelivo` is now a protected name with
`"rewritten": true` (it is a *presence* claim, not a "the substitution must not touch it" claim), the
test proves that flag still names a substitution source, `.github` joined the scanned roots with a
spec-listed exemption (`names_the_needle`, asserted to still contain the needle), and rule 3 says the
sweep's file list is the incoming range **minus** `tool/identity` and the docs.

**D. The native-resource digest belongs to unit 2.** The gate's native half hashes the 24 permission
descriptions, the share-extension strings and the Android phone-control labels. The unit's own tree
carries the state file from the released line, which was derived from **25** items — the fork tip adds
`ios.NSLocalNetworkUsageDescription`, and that entry arrives with unit 2. At unit 1 the digest was
therefore stale by one key, so the three `native_*.json` files were re-derived for the 24 items the
unit actually has; unit 2 re-derives them again when its Info.plist entry lands. Nothing about the
translations changed — only the claim about which sources they were written against.

Two smaller findings: ADR-0018's retirement had been reverted in six places by the same "take
upstream's side" default — `'KelivoIN'` back in `_builtInProviderKeysInOrder`, back in the first-launch
seeding, its Qwen models and overrides back in `defaultsFor`, its base URL back in `_defaultBase`, its
default-enabled flag back in `defaultEnabled`, and the one-shot inline migration back in place of
`_retireDeadBuiltInProviderConfig()` — and four test files needed reformatting because the extra
character in `package:Cuplivo/` pushes one import past eighty columns.

## What the unit-1 test run found

`flutter test` at this commit: **12985 passed, 90 skipped, 181 failed**. That number is the unit
boundary doing its job — three of the failures were this unit's, and the rest belong to units that
come after it. Measured by path: of the 42 failing files, **31 are in unit 2's patch**, the commit
whose subject is `fix(tests): the new baseline's suite — Windows and the backup staging rework`, and
they account for 154 of the 181 cases.

**This unit's three.**

- `kelivoin_removal_test`: the merge had restored `KelivoIN`'s default base URL, its default-enabled
  flag *and* its Qwen prefill on top of the seeding and the built-in-key entry — five places, not
  three. ADR-0018 says the provider has no seeding, no defaults, no prefill and no built-in identity,
  and the test asserts every one of them.
- `restore_failure_space_test` looked for "Update Kelivo before restoring them" while the ARB says
  "Update Cuplivo…": upstream rewrote that test in this window, and the incoming side needed the
  rename — the same rule that makes `rename(upstream)` apply to the ARBs themselves.
- `browser_workspace_resources_test` expected the scope's scheme to be `cuplivo` while the product
  speaks `kelivo`. The identity sweep renamed the *assertion* and left the protected value alone:
  the runbook's `KelivoLink.scheme` defect in its cheapest form, and the fixture URL one line above
  still saying `kelivo://` is what gave it away.

**Everything else is later units' payload**, and the shape is uniform: POSIX path literals in
upstream's tests (`endsWith('/index.html')`, `'…/images/x.png'`), Windows file-handle teardown
(`PathAccessException: Deletion failed, errno 32` across the image and storage tests), the vendored
browser engine's missing `addDevToolsProtocolListener` (70 cases in one file), and `window_manager`'s
`isFullScreen` probe handing `startDragging` a null (8 cases).

Ten files, 28 cases, sit in **no** unit's patch: `workspace_file_navigation`, `view_image`,
`native_input_attachments`, `chat_send_race`, `workspace_permissions`, `import_toolbox`,
`world_book_page`, `storage_upload_session`, `backup_restore_error_message`, `icon_cache`. They pass
on v1.3.6 and fail on v1.3.7, so they are new baseline work rather than a replay miss: unit 2's scope
has to grow by them, which is a change to this attempt's plan and not to this unit.

## Unit 2: 181 → 23, and why not zero

Unit 2 replayed onto this branch with **26 conflicted paths** and left the suite at **13144 passed,
95 skipped, 23 failed** — the 158 cases it repairs, minus the 3 this attempt's unit 1 had already
fixed at their root.

The conflicts were three shapes, and the second is the one worth remembering:

- **l10n, 17 paths** (7 ARBs, 6 generated, 4 state files). Unit 2's message says the case out loud:
  *"the `lib/l10n` surface is settled here at the tip's content … the cost is that this unit's strings
  describe features the later units have not built yet"*. So its ARB hunks are not the "v1.3.6-era
  settle" the attempt-one table called them — they are the fork's whole key set, 247 of them, and
  dropping them loses every string the later units' code calls. Re-merged per key with this unit's
  tree as the fork side: 5752 messages, upstream's 94 additions kept, unit 1's five retired keys and
  three orphan strings still gone, state fingerprints recomputed for all four locales.
- **the native digest closes its loop.** Unit 2 adds `ios.NSLocalNetworkUsageDescription`, the three
  `native_*.json` digests come back to the released line's exact values (`94c424c6…`, `510b9f15…`,
  `0c236b51…`), and the `.lproj` files already carry the translations. Unit 1's note said this would
  happen; it happened to the byte.
- **code, 2 paths.** `backup_staging.dart`: upstream's non-creating `resolveRoot()` split stays, this
  unit's `debugRootOverride` seam rides in front of it. `sandbox_path_resolver.dart`: this unit's
  `normalizeForMatch`/`_nativeForIo` work stays, and v1.3.7's query/fragment handling in
  `tryDecodeLocalFileUri` is restored on top — the only baseline-move hunk in that file.
- **tests, 7 paths.** Three take this unit's version (its repair, its model spec). Two take the
  branch's, because v1.3.7's rework already did what this unit was doing — it replaced the hardcoded
  `…/tmp/kelivo_backup_staging` with `BackupStaging.resolveRoot()` and a `stagingDirectory` local
  (rule 7). One is a rename/rename collision: upstream **moved** `test/core/services/mcp/mcp_icon_cache_test.dart`
  to `test/utils/icon_cache_test.dart` and renamed `McpIconCache` → `IconCache` in this window, so the
  fork's file has no subject; upstream's test stays, with this unit's `p.equals` path comparison
  re-applied.

**The 23 that remain are not the same class as the 158.** They split four ways, and only the first is
this unit's:

1. **Windows platform, 4.** Mixed separators in one expectation (`storage_image_usage`), and two
   teardown `PathAccessException`s (`chat_send_race`, `storage_space_images`).
2. **A string this unit settles but a later unit makes true, 1.** `backup_restore_error_message_test`
   wants the toolbox's "Import Backup File" wording, which is unit 14's flow; the message it reads is
   the settled ARB's Cherry Studio one.
3. **Behaviour v1.3.7 changed under a v1.3.6 test, 8.** `view_image`'s five redirect/download cases
   record no requests at all, and `import_toolbox` (2) plus `tool_handler_skills_refresh` (3) exercise
   seams the new baseline moved.
4. **Layout numbers that moved with the strings, 2.** `world_book_page` measures a label 49 px
   narrower than v1.3.6 did — the same reason as (2), a settled string, not a broken widget.

So a mid-series commit **cannot** be test-green once the l10n surface is settled at the tip's
content: its strings describe features whose code arrives eleven units later, and the tests that read
them land in between. Unit 2's job was the floor, and the floor is what it is: 181 → 23. The
remaining work is either the last tip-only repairs or the units whose subjects those tests name, and
the plan's "gate units 1 and 2" line should be read as *run the suite there*, not *zero it there*.

### The platform pass over those 23

The four Windows cases were repairable on the spot and are repaired (23 → 17):

- `storage_image_usage_test` compared the stored path to the cache's own spelling with `==`.
  `IconCache` resolves its root through `AppDirectories`, which joins with `/`; the storage service
  joins with `p.join` — one file, two spellings. Both comparisons use `p.equals` now, and the `path`
  import the replay had dropped as "unused" is back, because it is used.
- `chat_send_race_test` and `storage_images_test_fixture` deleted their temp root once and lost the
  race with a database or image handle (`errno = 32`). Both now use `deleteDirectoryWhenReleased`,
  with `keepLockedLeftovers` set: those harnesses keep a reader open past the test, which is the
  helper's own documented case where the unlink cannot be won on Windows, and each directory is
  per-test.

The 17 that remain are the string/seam classes (2–4 above) — they belong to the units whose subjects
they name, and the tip's gate is where they close.

### The second pass: 23 → 13, and three of the classes are not the tree's

- **4 repaired.** `backupPageCherryStudioUnsupportedBackupVersion` now takes upstream's value. The
  fork's text told the reader to export an older Cherry Studio format, which stopped being true the
  moment this tree gained upstream's toolbox — and upstream's new tests assert the toolbox wording,
  so the earlier "both sides changed, keep ours" was right for v1.3.6 and wrong here. The key joins
  the ARB whitelist beside the two other toolbox strings, because all three describe the same
  `Kelivo` archive. Two more are path spellings: `data_sync_backup_file_test` compared `fix()`'s
  result with `'${root}/upload/pic.png'`; it uses `p.join` now.
- **5 are this machine's, not the tree's.** This shell exports `HTTP_PROXY`/`HTTPS_PROXY`, and
  `workspace_image_download`'s guard — upstream's file, byte-identical to `v1.3.7` — refuses when
  `HttpClient.findProxyFromEnvironment` is anything but DIRECT. A one-file probe settles it:
  `findProxyFromEnvironment('http://127.0.0.1:9/x')` is DIRECT, `('https://example.com/x')` is
  `PROXY 127.0.0.1:10808`. The five `view_image` cases stub *public* URLs, so they trip a guard that
  is doing exactly what it says. CI has no proxy; nothing here should change for them.
- **2 are font metrics.** `world_book_page` measures a label and a badge 49 px apart at text scale
  1.4 with a CJK-bearing title — the same rasteriser difference that made the golden layer a
  per-platform registration, and not something a test-side tolerance should paper over.

**6 remain real**: `storage_space_images` ×2 (the deletion snackbar never appears), `data_sync` ×1
(the startup snapshot retry), `tool_handler_skills_refresh` ×3 (a renamed skill shows twice — the
visible list gains the new name without dropping the old). None of them is identity or l10n; all
three are behaviour the new baseline moved, and each is worth its own look rather than a guess.

### The third pass: 13 → 9, and one of them was a fork-vs-baseline spelling mismatch

Two causes, both found by reading the chain instead of the assertion:

- **`tool_handler_skills_refresh`, 3 cases.** The test edits the *target* of a symlinked `SKILL.md`
  and expects the visible name to change. Upstream's v1.3.7 refresh (`refreshSkills` +
  `isLinkedSkillEntrypoint` in `workspace_tools_service.dart`, which this tree took verbatim) asks
  `SkillsService.isLinkedEntrypointTarget(hostPath)`, and that was
  `_linkedEntrypointTargets.containsValue(hostPath)` — a byte comparison between two spellings
  produced by two different tools. The map stores `p.canonicalize(resolveSymbolicLinks())`, which
  **lower-cases the whole path on Windows**; the caller passes the fork's
  `WorkspacePaths.canonicalHostPath`, which deliberately keeps the case. So on Windows the predicate
  was false, the rescan never ran, and the pane kept the old name — while the line above it, editing
  `SKILL.md` itself, worked. `p.equals` at the boundary fixes it; the comment says why, because the
  next reader will otherwise "simplify" it back.
- **`data_sync_backup_file`, 1 case.** `.where((f) => f.path.endsWith('/previous/preserved.txt'))`
  — the `/`-literal-frozen-into-a-path-filter class the runbook already names, in a file the earlier
  census had only counted. It matches by basename now.

**9 remain, and 7 of them are not the tree's**: the five proxy cases and the two font-metric cases
above. **2 are real** — `storage_space_images`' "image filters, counts and protected selection", in
both desktop variants. Measured with a probe inside the delete branch rather than guessed at: the
page calls `deleteUploadFiles` with exactly one path, and the service throws

```
PathAccessException: Cannot delete file, path = '…\storage_images_76e81bfe\avatars\unused.png'
  (OS Error: 另一个程序正在使用此文件, errno = 32)
```

so the catch branch shows the *error* snackbar and the wait for `已删除 1 个项目` times out. The
handle is the tile's own thumbnail: each row renders
`SafeResizeImage.wrap(FileImage(File(entry.path)), …)`, and on Windows the unlink loses to it while
the row is still on screen. Clearing `ImageCache` before the delete does **not** help — the mounted
row re-decodes and re-opens the file inside the same frame — so the fix is a product one (drop the
rows before deleting, or let the delete wait for the reader), not a test tolerance. This is upstream's
code, its own CI is `ubuntu-latest` only, and a POSIX unlink succeeds with an open handle, which is
why the defect only exists here. It is the one item in the census that is the tree's, and it is
Windows-only.

### Unit 3: one conflict, and it was the two units' shapes meeting

`recycle` replayed with **30 paths and one conflict** — `storage_space_page.dart`'s upload-manager
branch. v1.3.7 hands a precomputed `uploads` list to `_UploadManager`; this unit wraps that widget
in the section chrome (`title`, `subtitle`, `hintLine`, `Expanded`). Neither side is a version of the
other, so the resolution is both at once: this unit's `Column`, with `uploads: uploads` handed down
inside it. The other 29 paths merged on their own — the schema, `recycle_service`/`recycle_store`,
the two recycle pages, `workspace_paths` and `app_directories` (both still carrying the identity
unit's rename), and `main.dart`.

No ARB in the diff, so this unit costs no l10n pass: `dart analyze` 0, `dart format` 0 changed, its
own eight test files 65 passed.

### Unit 4 in flight: where the pause actually is

`sync-lan` is applied but not committed, and it earned its "22 pauses" line the hard way: **6
conflicted paths of 206**, five now resolved and one open.

- `sandbox_path_resolver.dart` is a both-sides-rewrote-the-file case: unit 4's copy carries
  `canonicalStorage`, and v1.3.7's query/fragment handling in `tryDecodeLocalFileUri` has to be put
  back on top of it.
- `business_settings_router.dart` is the structural one. v1.3.7 still keys the registry as
  `preferenceKeys` + `localOnlyKeys` sets; unit 4 replaces both with a 300-row `rules` table
  (`KeyRule(policy, reason)`) and the `isSynced`/`isDeviceLocal`/`isRegisteredInBusinessStore`
  predicates. The table wins — the sets have no other reader — and v1.3.7's four constants stay
  beside it, with five rows added for the keys the table never learned: `balance_refresh_interval_v1`,
  `balance_refresh_on_reply_v1`, `chat_bubble_style_thinking_tool_card_v1` (synced /
  newDeviceConfiguration) and the two caches `codex_client_version_v1`, `model_list_metadata_v1`
  (platformOnly / runtimeDiagnostics).
- `desktop_home_page.dart` is a tab model collision: v1.3.7 tracks `_tabIndex` + `_visitedTabs` (21
  uses), unit 4 introduces `DesktopTab` and a `_pageFor` shim written against a `DesktopTab`-typed
  shell that arrives later in the series. The int model stays, the shim goes, and unit 4's real entry
  point for the pane — `desktop_settings_page`'s sync section — merged on its own.
- two mechanical ones: `restore_bundle_mover`'s two imports, and the migration test's
  `rules.keys` loop keeping v1.3.7's typed values for the balance keys.

**Open: `message_builder_service.dart`, 6 hunks.** Hunks 1 and 4–6 are mechanical; hunks 2, 3 and 6
are the collision the plan predicted — v1.3.7 folds memory injection into `MemoryInjectionPass`
built inside the assembly, unit 4 decides it earlier as `memoryPlan = resolveMemoryPlan(...)`
because "the memory decision belongs to the request, not to the message being assembled" (its own
words: the ordering that put the snapshot on the oldest message of a freshly synced conversation).
Both are live implementations of one feature and neither is a version of the other, so it needs the
two flows read side by side rather than a side picked. The ~1800 analyzer issues the tree reports
right now are that file's parse fallout, not 1800 defects.

## Procedure for this attempt

```bash
git branch --force landing-137 v1.3.7
# switch to it, then commit this document before anything else
git cherry-pick -n <unit 1>      # resolve, then commit
flutter pub get && dart analyze --fatal-infos lib test integration_test
flutter test                      # units 1 and 2 only
git cherry-pick -n <unit 2>      # ...
```

Rules that apply at every stop:

* resolve with the per-unit decision in the table above, **not** with a global policy;
* never concatenate two method bodies — if a block is not an import list or a sibling statement,
  read the surrounding function and write the merge;
* run `dart analyze --fatal-infos lib test integration_test` before committing a unit, and do not
  carry a known-bad unit forward: a red unit makes every later judgement unreliable;
* **the backup unit gets read, not resolved.** `desktop/setting/backup_pane.dart` plus the
  `backup.dart` / `data_sync` split is the one place where upstream rewrote the same code the fork
  rewrote, so its conflict is a design question (whose config parsing wins) rather than a
  mechanical one. Upstream's `fields.trimmed` parsing is the newer shape and should win; the fork's
  contribution is the archive *target*, which rides beside it.

## Progress

| | |
| --- | --- |
| backup of attempt one | `backup/v1.3.7-attempt1` |
| attempt two branch | `landing-137`, cut from `v1.3.7` |
| unit 1 identity | **committed**: analyze 0, format 0 changed, l10n pass ×4, its own 3 suite failures fixed |
| unit 2 baseline-repair | **committed**: 181 → 23 suite failures, analyze 0, l10n pass ×4 at 5752 messages, native digests back to the released line's values |
| baseline census | 23 → 13 → **9**: 7 are this machine's (5 proxy, 2 font metrics), 2 are real and open |
| unit 3 recycle | **committed** `3a3f32467`: 1 conflict of 30 paths, analyze 0, format 0, its own 8 test files 65 passed |
| units 4–18 | not started |
| gates | analyze per unit; tests on units 1 and 2; l10n at the tip |

