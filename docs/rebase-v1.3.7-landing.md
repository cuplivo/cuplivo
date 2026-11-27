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

**A. Upstream files that were never swept** (~15 test files). `package:Kelivo/` still appears in
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
| unit 1 identity | not started |
| units 2–17 | not started |
| gates | analyze per unit; tests on units 1 and 2; l10n at the tip |
