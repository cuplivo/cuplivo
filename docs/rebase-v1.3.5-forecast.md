# Pre-rebase forecast: Cuplivo 4.6 line → Kelivo `v1.3.5`

Written before the replay, from measurements on this machine, so the replay can be planned instead
of discovered. Companion to [`rebase-runbook.md`](rebase-runbook.md) (which records replays *after*
they close) and [ADR-0004](adr/0004-follow-upstream-rebase.md). Every number below is a git reading,
not an impression; re-run the commands before trusting a stale copy.

- **Target**: `v1.3.5` = `a03255cb8` (2026-11-08), 52 commits on `v1.3.4`, **479 files,
  +152 238 / −14 129**. `upstream/master` is `cb95d6af0`, **9 commits past the tag** — if the replay
  takes days, expect the same hop the `b1702b3a9` pass needed.
- **Source**: `master` = `ecd47c3f6` (Cuplivo 4.6.0), **34 commits** above `4a7da9b6f`, which is both
  the v1.3.4 tag and `git merge-base master upstream/master` — so the replay is 34 units onto 52
  upstream commits, with no partial baseline already applied.
- **Both sides touched** 214 files: 2097 fork-changed vs 479 incoming. **125 of those 214 are brand
  substitution only** on our side (`package:Kelivo/` → `package:Cuplivo/`, `com.psyche.kelivo` →
  `com.cuplivo.cuplivo`, `Kelivo` → `Cuplivo`); the other 89 need a real three-way merge.

## What the incoming range actually is

Five themes, in descending order of how much they cost the replay:

1. **Context compaction is rebuilt.** `c2eabf0f0` (14 933+/3 194−, 96 files) replaces
   `compress_context_options.dart` (452 lines removed) with `lib/core/models/compression_config.dart`,
   `compression_engine.dart`, `compression_templates*.dart`, `chat_compression_repository.dart`,
   `compression_controls.dart`, `compression_template_library.dart`, `context_operations_panel.dart`,
   `context_message_count.dart`; `cc794b332` adds opt-in OpenAI native compaction;
   `84b2d835b`/`9cca434ca` fix the controls and the post-compression context count.
2. **Three new locales plus an l10n toolchain.** `3b7976aa4` (104 854+/7 005−) adds `app_ru.arb`,
   `app_ko.arb`, `app_tr.arb` (4 866 keys each) and `tool/l10n/` (13 files: a Python `translate.py`
   with `status`/`sync`/`check`, a separate Dart package, per-locale fingerprint state, native-resource
   sync). `159d94735` declares its `flutter_tools` SDK dependency.
3. **Provider/model surface**: sponsor providers (`a9f6cccc5`, `b85cc314e`), Ollama capability
   discovery (`e4c05bd61`), custom balance APIs (`c8b0462e7`), request/image budgets (`d83653f41`),
   model icons (`1f8187c94`), per-assistant full memory injection (`ef512dbad`).
4. **Chat timeline and images**: measured block extents across rebuilds (`24b49de7b`, `1b52562d7`,
   `5670b7393`, `652738c1f`), anchoring while markdown images load (`a03255cb8`, `6882b6215`), quoting
   selected reasoning (`35fc0b17a`), response-speed controls (`51777f798`).
5. **Platform fixes**: browser local files and navigation state on Windows (`73afa4ec7`), orphaned
   workspace processes on Android (`7da358545`), WebView drain before plugin teardown (`5579567dc`),
   iOS browser safe-area scroll (`1a9217d29`), Inno Setup's localized installer strings.

`dependencies/` moves too (21 files): markstream's `selectable_rich_text.dart`, `markstream_theme.dart`,
`code_block.dart`, `html_style.dart` (the system-bold accessibility pass, `11073111c`) and 14 files in
the vendored `flutter_inappwebview*` families. Vendored by path — no local patch, but the PDF emitter
walks markstream's tree and the theme mapper consumes its styles, so both get re-read.

## The conflict surface, computed

`git merge-tree --write-tree --merge-base=<unit>^ v1.3.5 <unit>` per commit, `CONFLICT (content)`
only, with `lib/l10n/`, the changelogs, `CONTEXT.md`, `AGENTS.md`, the READMEs, `pubspec.yaml` and
`docs/` filtered out (those resolve by the carry or by `flutter gen-l10n`):

**216 (unit, file) stops over 33 of the 34 units; 147 distinct files — 109 `lib/`, 99 `test/`,
7 platform, 1 `integration_test/`.** 56 of those files stop in the identity unit alone, 98 in the
feature and landing units (7 appear in both).

The probe is deliberately pessimistic (it applies each unit against the bare tag instead of against
its rebased predecessor, so it cannot see an earlier unit's resolution). Calibrate it against the last
replay: `4a7da9b6f` was forecast at 25 and stopped on 6, and `e15df5485`'s surface of ~300
both-sides-changed files stopped on 31. **Expect 40–60 real stops, most of them cheap.**

| # | unit | subject | stops | first files |
|---|---|---|---|---|
| 1 | `87f613717` | feat!: Cuplivo identity on the Kelivo baseline | 56 | 7 `lib/` (`providers_pane.dart`, `link_image_handlers.dart`, …), 45 `test/`, `project.pbxproj`, `Info.plist`, `main.cpp` |
| 2 | `506a83100` | fix(tests): flaky root causes + 8 Windows failures | 5 | `builtin_provider_test.dart`, `composer_draft_store_test.dart`, +3 |
| 3 | `47eab361f` | feat(image): manual compression editor | 1 | `image_compressor_test.dart` |
| 4 | `f36104732` | feat(sync): LAN sync | 3 | `Info.plist`, `business_settings_router.dart`, `forward_compat_normalize_test.dart` |
| 5 | `3c65bd020` | feat(care): 「Ta的来信」 + roleplay tab | 2 | `KelivoApplication.kt`, `main.dart` |
| 6 | `7e5e8fdb6` | feat(image): crop in preview | 1 | `chat_input_bar.dart` |
| 7 | `28e800170` | fix: focus retention on resume | 0 | — |
| 8 | `30c3c9131` | feat(chat): conversation/message links | 3 | `MainActivity.kt`, `BackgroundRuntimeTest.kt`, `home_page_controller_switch_test.dart` |
| 9 | `4718e1d67` | feat(chat): compression readout in tokens | 2 | `compress_context_options.dart`, `home_view_model_compress_context_test.dart` |
| 10 | `d8d0445e3` | docs(reply): ADR-0012 + UI hooks | 7 | `hotkey_provider.dart`, `desktop_home_page.dart`, `hotkey_event_bus.dart`, `hotkeys_pane.dart`, +3 |
| 11 | `d593bfdd4` | feat(export): PDF from markstream's tree | 1 | `diagram_exporter.dart` |
| 12 | `df97d069f` | feat(translate): target languages incl. Bengali | 5 | `business_settings_router.dart`, `desktop_translate_page.dart`, `language_select_sheet.dart`, +2 |
| 13 | `0efe19988` | feat(suggestions): per-assistant switch | 1 | `settings_provider_chat_suggestions_test.dart` |
| 14 | `1a04207ff` | feat(recycle): recycle bin | 5 | `business_repository.dart`, `storage_space_page.dart`, `main.dart`, `app_directories.dart`, +1 |
| 15 | `2184720ca` | fix(rebase): the 4.5 landing | 12 | `business_settings_router.dart`, `settings_provider.dart`, 4 `app_*` ARB, +6 |
| 16 | `b264ef05a` | fix: the 4.5 line's fixes | 7 | `assistant_provider.dart`, `browser_native_engine.dart`, `chat_service.dart`, +4 |
| 17 | `5136e617b` | feat(group-chat): multi-agent topics | 23 | `business_settings_router.dart`, `conversation.dart`, `settings_provider.dart`, 5 provider files, +17 |
| 18 | `8b9e15859` | chore(release): Cuplivo 4.5.0 | 0 | — |
| 19 | `237c9a097` | fix(replay): the baseline's suite and fixtures | 29 | `business_repository.dart`, `chat_database_repository.dart`, `compress_context_options.dart`, +26 |
| 20 | `fbe7e11dc` | docs(reply): the `4a7da9b6f` record, reply retired | 8 | `hotkey_provider.dart`, `desktop_home_page.dart`, `chat_action_bus.dart`, +5 |
| 21 | `60dce5b0f` | fix(group-chat): leave on assistant choice | 3 | `home_page_controller.dart`, +2 |
| 22 | `972335d89` | fix(image-viewer): mobile paging | 5 | `image_viewer_page.dart`, `chat_input_bar.dart`, +3 |
| 23 | `bb079ed2d` | refactor(sync): one policy table | 5 | `business_repository.dart`, `business_settings_router.dart`, +3 |
| 24 | `d905ab981` | test(view-image): catalog before specs | 1 | `view_image_provider_test.dart` |
| 25 | `c89e433b3` | fix(care): carrier + deadline | 3 | `mobile_background.dart`, `home_page_controller.dart`, `home_view_model.dart` |
| 26 | `f9ff80edb` | feat(markdown-image): text into one picture | 1 | `side_drawer.dart` |
| 27 | `5a8ef3630` | feat(chat-owners): assistants vs group chats | 4 | `business_settings_router.dart`, `assistants_pane.dart`, `assistant_settings_page.dart`, +1 |
| 28 | `9466a37b5` | feat(backup): a backup Kelivo can import | 3 | `backup_portability.dart`, +2 |
| 29 | `e6abd6623` | fix(composer): one "+" on a phone | 3 | `chat_input_bar.dart`, `chat_input_section.dart`, +1 |
| 30 | `fe8cafd2f` | fix(markdown-image): one tab's input | 2 | `desktop_home_page.dart`, `desktop_nav_rail.dart` |
| 31 | `ef0d5280f` | fix(provider): remove built-in KelivoIN | 6 | `settings_provider.dart`, `providers_page.dart`, `builtin_provider_test.dart`, +3 |
| 32 | `27f1beeaf` | fix(provider): KelivoIN follow-ups | 0 | — |
| 33 | `e31d9d4c1` | feat(group-chat): quick entries follow the roster | 9 | `assistant_provider.dart`, `reasoning_level_popover.dart`, `tools_popover.dart`, +6 |
| 34 | `ecd47c3f6` | chore(release): Cuplivo 4.6.0 | 0 | — |

**Hot files** (units that stop on them): `business_settings_router.dart` (6),
`chat_input_bar.dart` (5), `message_builder_service_test.dart` / `main.dart` /
`settings_provider.dart` / `home_view_model.dart` / `home_page_controller.dart` /
`chat_input_section.dart` (4 each). `settings_provider.dart` alone absorbs 13 upstream commits this
range.

The order the runbook already fixes is the right one here too: unit 1 (identity) first, unit 2
(baseline repair) second so the later units replay on a tree the gates can pass, and the group-chat,
composer and settings units late, because they own the files the incoming compaction and
provider work rewrote.

## Mechanical classes — no conflict marker, still work

1. **The identity sweep (§ rule 3) is 128 added files, 72 of them carrying a brand token.**
   43 are `.dart` files with `package:Kelivo/` imports — mostly the new compression, budget, provider
   and translate tests (`compression_engine_test.dart`, `native_compaction_test.dart`,
   `request_budget_test.dart`, `assistant_provider_memory_injection_test.dart`, `chart…`). They arrive
   *after* unit 1 and no conflict will ever mention them.
2. **The Android tree grows an upstream package directory again.** `7da358545` adds
   `android/app/src/main/kotlin/com/psyche/kelivo/workspace/WorkspaceProcessOwner.kt`, its test, and
   `android/app/src/main/cpp/workspace_process.h`. git reports this as `[file location]`, not a
   conflict: the file lands at upstream's path with `package com.psyche.kelivo.workspace` while the
   rest of the tree is `com.cuplivo.cuplivo`. Move and repackage both Kotlin files, and re-check the
   C++ include from `termux_pty.cpp` (a file both sides touched).
3. **`ios/Runner/Info.plist`**: add `ru`, `ko`, `tr` to `CFBundleLocalizations`, and adopt upstream's
   *new* calendar/reminders privacy wording ("Event content may be sent to the AI provider you
   selected") with the brand renamed — the old text claimed on-device-only processing.
4. **`.github/workflows/`**: `release.yml` (fork-owned) takes one hunk from `build-stable-47.yml` —
   the three Inno Setup `{cm:CreateDesktopIcon}` / `{cm:UninstallProgram}` / `{cm:LaunchProgram}`
   strings that replace hardcoded Chinese. No Flutter version move, so no re-derivation.
5. **Nothing else in the delivery layer moves.** `pubspec.yaml` changes only its `version:` line,
   `pubspec.lock` and `dependencies/markstream/pubspec.lock` are untouched, `app_database.dart` and
   `app_database.g.dart` are byte-identical, `currentSchemaVersion` stays **5**, `_backupFormatVersion`
   stays **3**. So: no drift regeneration, and rule 17 asks only for the vocabulary test plus a
   re-read of the Kelivo v1.3.5 reader — not a new pin.
6. **Two upstream deletions the fork's own files depend on**:
   `.github/scripts/check_no_new_untranslated.py` (replaced by `tool/l10n`) — our `pr-check.yml` still
   calls it, so the step breaks by missing file, and
   `test/settings_provider_memory_injection_test.dart` — the fork's only change there is the
   `package:Kelivo/` → `package:Cuplivo/` import rename, so upstream's deletion wins.

## The l10n maths, which is where this replay differs from every previous one

- `app_en.arb`: **+216 keys, −2 removed (`memorySettingsFullInjectionTypes{Title,Subtitle}`), 12
  changed values**; the fork's tree carries **430 keys upstream does not have** (its renames plus its
  features) and lacks **218** keys present at the tag (the 216 new ones, plus pre-rename names the
  identity sweep dropped).
- Three new locales arrive *with* their translations (4 866 keys each), so they do not add
  untranslated strings — but they do add three brand-swept ARB files and three generated
  `app_localizations_*.dart` files, and `app_zh_Hans`'s known 24-key gap stays whatever it is.
- `tool/l10n/translate.py check` fingerprints `[en[key], zh[key], en['@'+key], locale, GLOSSARY,
  PROMPT_VERSION]` per key and **rejects** a stale fingerprint, a key-set difference from English, or
  a stale native resource. On this tree that means: every key whose English or Chinese value the fork
  renamed is stale (order 50 keys), the 430 fork-only keys have no translation at all in
  `ko`/`ru`/`tr`, and `GLOSSARY` still carries upstream's brand. **Upstream's CI step cannot be
  adopted as-is**; the fork must either run `sync` with an API key and endpoint it does not have, seed
  the three new locales, or keep its own `check_no_new_untranslated.py` gate and leave the tool
  vendored but unrun. This is decision 1 below.

## Rule-7 checks (has upstream absorbed a unit?)

| unit | verdict |
|---|---|
| compression readout (`4718e1d67`, ADR-0011) | **not absorbed.** Upstream's `compress_context_options.dart` still estimates tokens by character share; our delta (the walked list, tool calls and results weighed, images counted separately) survives — but it now lives on a file upstream cut in half and beside `compression_config.dart`, so it is re-implemented on the new model, not replayed |
| message reply (`#1027`) | stays retired: no reply symbol exists at our tip, and upstream's `35fc0b17a` extends its *own* reasoning quote |
| per-assistant switches (`0efe19988`) vs `ef512dbad` full-injection picker | two features, one page. Keep both; the assistant settings page is rewritten by the incoming side, so the merge is on upstream's structure |
| KelivoIN removal (`ef0d5280f`) | upstream adds sponsor providers to `_builtInProviderKeysInOrder` — allowed by rule 18; `test/core/providers/kelivoin_removal_test.dart` is the standing gate that must stay green |
| image compression (`47eab361f`, ADR-0002/0005) vs `d83653f41` request budgets | different surfaces (working memory vs request budget), but both touch the image path and `business_settings_router.dart`. Read `request_budget.dart` before resolving |
| browser workspace protocol (`f36104732`) | `73afa4ec7` touches `browser_workspace_resources.dart` and `main.dart`; the `kelivo://` scheme and the workspace pseudo-host (`5619d84aa`) must stay `kelivo` in both |
| markstream hand-cursor gap | the incoming change rewrites the span-walking helper (`_withSpacing` → `_withAccessibilityStyle`) but not the cursor behaviour; the audit's line references are stale, the gap is unchanged, and the upstream issue stays closed `NOT_PLANNED` |

## Plan

**Pre-flight.** Bridge `git fetch` (the sandbox cannot reach the credential store), label the
worktree's files for the sandbox (once, from a normal shell), and set `core.editor true`.
Back up first: `backup/master-ecd47c3f6`, and `backup/series-4.6-4a7da9b6f` before any normalization.

## Normalization — done, 34 → 20 units

Two passes on `reorg/series-4.6`, on top of `master` untouched.

**Pass 1 folds five adjacent pairs.** Each fold is `git reset --soft <lo>^` at the upper commit, so the
surviving commit carries the *upper* commit's tree byte for byte — there is no patch application, so no
fold can invent a conflict — and the folded bodies are kept under `folded from <sha>:` in the message
(because the next re-base reads them, not the subject).

| folded | into | why it is the same concern |
|---|---|---|
| `2184720ca` the 4.5 landing | `b264ef05a` the line's fixes | both are the landing: rebuild, lock, record, then the suite/PDF/brand fixes it needed |
| `8b9e15859` release 4.5.0 + `237c9a097` the replayed baseline's repairs | `fbe7e11dc` the `4a7da9b6f` record | one close-out: the release, the repairs it needed, and the record that retires the reply |
| `7e5e8fdb6` crop in preview | `28e800170` focus retention | both edit the composer the other units share |
| `4718e1d67` compression readout | `d8d0445e3` the reply's ADR-0012 hooks | the two surfaces the next baseline retires (see below) |
| `ef0d5280f` KelivoIN removal | `27f1beeaf` its follow-ups | the follow-up's crossings are two docs and a fork-only test (rule 13's free case) |

**Pass 2 reorders into feature families**, folding each family's later members *back* into the family's
unit (cherry-pick onto it, then `reset --soft <unit>^`), so the unit sits where the family starts and
everything between replays onto content that already contains the later work. Each fold is closed by
comparing the tip tree with `master`'s.

| family unit | members |
|---|---|
| image | #925/#946 compression editor, #992 crop + #1012 focus, #1067 viewer paging, #1070 view-image test |
| sync | LAN sync, #1068 policy table |
| care | care port, #1064 backgrounded letter |
| group-chat | #1052 topics, #1069 group exit, #1072 phone composer |
| markdown-image | #1075 render, #1077 per-tab input |

Proofs, in the runbook's order — tree first, then ancestry and count:

```
git diff --name-only master reorg/series-4.6     # only docs/ — the record commit
git merge-base --is-ancestor 4a7da9b6f reorg/series-4.6    # holds
git rev-list --count 4a7da9b6f..reorg/series-4.6           # 21 = 20 units + the record, from 34
```

Units 1 and 2 keep their hashes, so the identity unit and the baseline repair are still the ones the
last re-base produced. **The one member that would not fold**: #1081 (the composer's quick entries
follow the roster) into the group-chat unit — five fold conflicts, and the mechanical resolution left
`home_page.dart` with the `isGroup` block twice, with no conflict marker anywhere; only the tip-tree
comparison caught it. It stays its own unit until someone resolves it by hand. That is also why every
fold in this pass ends on a tree check rather than on a marker scan. Folding the reply *pair* across its
ten-commit gap is not a fold at all: the paths in
between make it a rewrite, which is why the pair was resolved inside the 4.5 close-out instead.

Replaying 20 units instead of 34 removes fourteen rounds. The cost of pass 2 is that the composer units
no longer replay in the order that made their patches conflict-free against each other — the runbook's
first lesson — so at replay time a composer conflict now carries a family's whole content on one side.
That is the trade this line chose: fewer rounds, each one slightly heavier.

## Decided, and what they change

1. **Target is `upstream/master` (`cb95d6af0`), not the tag.** Measured: 63 commits / 522 files, 234
   files in common with the fork, **224 predicted stops over 153 distinct files** — +8 and +6 over the
   tag's 216/147, i.e. nearly free — and three of the nine commits past the tag land exactly where the
   replay will stop anyway: `eff2f3e03`/`3c81186d7` (native compaction selection and forks, on
   `compress_context_options.dart`), `c66ade4a8` (SQLite closed during desktop exit, on
   `app_exit_flush.dart`/`chat_database_gateway.dart`), `3aa5aee7d` (manually edited archives, on our
   `backup_portability.dart`). Landing on the tag would mean re-resolving all three.
2. **ADR-0011 is withdrawn; the pre-flight estimate surface is upstream's to own now.** At `cb95d6af0`
   no widget renders `compressUsage*` (the four keys survive as orphans), `estimateCompressionTokens`
   has no `lib/` caller, and the new `context_operations_panel.dart` reports the task's real
   `usage.promptTokens`/`completionTokens` after the fact. So the unit becomes a deletion: the dialog's
   readout block, `CompressContextSplit`, `compressWeightTextForMessage`,
   `compressWeightImageCountForMessage`, `_toolResultImageUris`, the four keys, and the two test cases
   that assert the band. Upstream also deleted `keepRecentStartIndex`, `compressRequestCharBudget`,
   `buildBoundedConversationText` and `chunkMessagesForCompression` (the engine plans segments now),
   while `selectKeepRecentMessages`, `countUserMessages` and `conversationLineForCompression` survive —
   **take upstream's** for those three.

## Replay

`git branch --force rebase/onto-v1.3.5 reorg/series-4.6` (minus the release commit), then
`git rebase --onto cb95d6af0 4a7da9b6f rebase/onto-v1.3.5`, resolving per the runbook's rules —
identity files as `rename(theirs)`, l10n per key then `flutter gen-l10n`, whole-file rewrites by
`git merge-file`, never a side wholesale. Sweep the added files and the two Kotlin files into unit 1.
Drop the readout in the unit that now carries it (unit 8). Close with the landing commits: baseline
suite/fixture repair, the tooling + lock commit (`tool/l10n/pubspec.lock` if the tool is adopted, the
`pr-check.yml` merge either way), the record, and the re-derived `dart format` at the tip. Note the
series tip is a *release* commit, not the reformat, so the procedure's `<old-master>~1` cut does not
apply — name the release commit explicitly.

**Gates**, in the runbook's order, against the committed lock: `flutter pub get --enforce-lockfile`,
`flutter gen-l10n` idempotence, `dart analyze --fatal-infos lib test integration_test` (plus `tool` if
the l10n tool is adopted), `dart format --output=none --set-exit-if-changed` with the pinned Dart
3.13.0 over all five paths, `flutter test`, the markstream package's own three commands, the Android
Kotlin test task, `flutter build windows --debug`, a `release.yml` dispatch, and `pr-check` on the
rewritten master. Expect a Windows-only failure class in the new baseline's tests — the last two
replays each found one, and a registration needs its own control run at `cb95d6af0`.

**Reverse direction (rule 17)**: `flutter test test/core/database/kelivo_vocabulary_test.dart`, then a
restore of this tree's backup into the last released Kelivo build; vocabulary and format version are
unchanged this round, so the check is "still true", not "new decision".

## Still open

1. **`tool/l10n`: adopt, seed, or leave dark.** Adopting upstream's CI steps needs a translation
   `sync` the fork cannot authenticate; seeding `ko`/`ru`/`tr` with 430 English strings satisfies the
   key-set check but ships untranslated UI; leaving the tool in the tree unrun keeps the fork's own
   gate and is the smallest change.
2. **Land the rewrite.** `master` has not moved: the 20-unit series is `reorg/series-4.6`, both backups
   (`backup/master-ecd47c3f6`, `backup/series-4.6-4a7da9b6f`) are pushed, and so is the branch. Landing
   is a force-push of `master`, and it should follow the replay rather than precede it.
3. **#1081 (the composer's quick entries) is still its own unit**, because folding it into group-chat
   put `home_page.dart`'s `isGroup` block in twice with no conflict marker. A hand resolution would
   close the family; until then it is one extra round.
