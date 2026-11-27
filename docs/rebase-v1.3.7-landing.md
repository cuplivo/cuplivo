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
| unit 1 identity | **committed**: analyze 0, format 0 changed, l10n pass ×4, its own 3 suite failures fixed; the other 178 are later units' payload (154 of them unit 2's) |
| units 2–17 | not started — unit 2 also owns the 10 files, 28 cases, that no unit's patch covers |
| gates | analyze per unit; tests on units 1 and 2; l10n at the tip |

