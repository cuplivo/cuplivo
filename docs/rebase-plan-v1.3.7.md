# Next re-base: the v1.3.7 forecast and the unit assembly

Companion to [rebase-runbook.md](rebase-runbook.md). This is the *forecast* pass — it measures, it
does not replay. Everything below was read from the repository on 2026-11-25; the numbers are
reproducible from the commands in the runbook.

## 1. Where the line stands

| | |
| --- | --- |
| merge base | `c2b48958d` = upstream tag **v1.3.6**, and it is still a plain ancestor of both sides — **upstream did not rewrite** |
| fork | `4c20b4462`, **47 commits** above the baseline; `pubspec.yaml` says `4.8.0+11`; tags `v4.7.0` and `v4.8.0` sit inside the line |
| upstream | `a9b3fe75e`, **116 commits** above the baseline |
| nearest release | **`v1.3.7` = `e0832d2b4`**, 70 commits above the baseline; `master` is `v1.3.7-46-ga9b3fe75e` |

So the two candidate targets differ by 46 commits, and the shape of the difference is the whole
decision:

| | `v1.3.7` (`e0832d2b4`) | `upstream/master` (`a9b3fe75e`) |
| --- | --- | --- |
| commits above baseline | 70 | 116 |
| diffstat | 523 files, +42 922 / −11 729 | 748 files, +135 488 / −34 566 |
| files added by upstream (identity sweep, rule 3) | **56**, of which 13 `.dart` carry `package:Kelivo/` | **183**, of which 45 do |
| `AppDatabase.currentSchemaVersion` | **5** (unchanged) | **6** — new `generation_tables.dart`, `media_repository.dart`, `app_database.g.dart` +8 973/−5 010 |
| `lib/core/database/business_data.dart` | byte-identical | byte-identical |
| `.github/workflows/` | **zero changes** | 5 files, 2 lines each |
| new `*_v1` keys written | **8** (7 preferences + 1 SQL row key) | **27** (26 preferences + the same row key) |

## 2. Target: `v1.3.7`, and the reason is not the size

Three facts decide it, and only one of them is a conflict count.

**A. Schema 5 → 6 breaks a standing gate that no local test can paper over.** The fork writes its
schema number into every archive (`manifest['database']['schemaVersion']`), and
`test/core/database/kelivo_vocabulary_test.dart` asserts
`AppDatabase.currentSchemaVersion <= KelivoVocabulary.v1_3_2.schemaVersion` — 5, read off Kelivo
v1.3.2 and still true up to v1.3.6. Taking master sets the constant to 6, so the assertion can only
go green by pinning a Kelivo release that opens schema 6 — and **no released Kelivo does**;
v1.3.7 is still schema 5. The fork's entire reverse-import promise ([ADR-0017](adr/0017-kelivo-reverse-import.md))
would be false on the day it shipped. That is an ADR decision, not a rebase step.

**B. Master supersedes three fork features at once — and the supersession is a rewrite, not a
replay.** Each of these landed *above* the tag:

| upstream commit | fork unit it displaces | what it costs to take |
| --- | --- | --- |
| `c2ef5d46a feat(sidebar): add customizable mobile layout and desktop rail` | 10 group-chat, 16 home-owner | `side_drawer.dart` **+672/−1270** — the drawer is rebuilt around a new `SidebarLayout` / `SidebarEntry` / `MobileSidebarEntries` abstraction. Both units rewrote that file; they must be re-anchored, not merged. `desktop_nav_rail.dart` +185/−90, `home_page.dart` +201/−112 |
| `493380ba5 feat(translate): manage visible target languages` + `fe41aaf5f` | 8 translate | the fork's unit becomes ~3 files (its four extra languages + its 9-language default); the manager, the key and the sheet are upstream's |
| `f4836a7c0 feat(creation): integrate image generation into chat` and 41 more | 20 image-job | the fork's 95-file unit loses 42 paths to upstream's ownership and its data model changes from "state embedded in `ImagePart`" to "normalized batch/item rows in new tables" — which is the schema bump of A |

**C. The 46 commits above the tag are still churning.** 25 of the 42 creation commits are fixes to
the creation family itself. Vouching for that surface on the day the fork rebases onto it is a
different risk from rebasing onto a tag.

**What v1.3.7 costs instead.** At the tag, `493380ba5` is not there, so the fork keeps its own
visible-target-language unit; `f4836a7c0` is not there, so it keeps its own inline image unit; and
the sidebar is still the shape both of those units were written against. The fork re-replays two
features that upstream will own in the next hop — a known expiry, accepted deliberately, because
the next hop is the natural moment to also move the vocabulary floor (once Kelivo ships a schema-6
release) as an ADR rather than as a side effect.

**If master is chosen anyway**, the plan below is unchanged except: units 8 and 20 shrink to their
surviving deltas, units 10 and 16 need re-anchoring on `SidebarLayout`, and a schema-6 ADR has to
precede the first gate run. Nothing else in the assembly moves.

## 3. What upstream brought in the v1.3.7 window (70 commits)

Grouped by what they mean for this fork, not by date:

- **Backup / restore, rewritten.** `369a55a5e perf(backup): streamline large exports and restore
  progress` (+789 lines across `data_sync.dart`, `restore_bundle_staging.dart` +291/−227, new
  `backup_file_export.dart`, `backup_file_digest.dart`, `backup_archive_limits.dart`),
  `aee4f2ec0 feat(backup): guide imports through the official toolbox` (new `import_toolbox.dart`),
  `83d336ca7`, `541ae2ed1`, `ccfe3833c`. This is the single largest collision with the fork's
  backup units (11, 18) — and see §6 for the one place it undoes a fork repair.
- **Search services.** `60270b2e3 feat(search): customize web search service icons`,
  `72a6f84a1 feat(search): add 4get search provider`, `571bbd383 feat: add opt-in Keenable search
  provider`, `9d229088c`. All three insert cases into `search_service.dart` beside the built-in
  `kelivo` service the fork deleted; see §7.
- **Chat surface.** `2464e2c70 feat(chat): customize thinking and tool cards` +
  `200cccdbb` (the `chatBubbleStyleOverridesFor({bool isUser})` → `(ChatBubbleStyleTarget)` rename),
  `56e65b185`/`a5a1c392b`/`b98f1b819` (markdown inline code, table widths), `6a8c6e938 feat(chat):
  manage per-image context exclusions`, `3518c3dc1 feat(chat): allow model response speed
  overrides`, `42c286213 feat(chat): configure conversation find shortcut`.
- **World book groups** `2864748ad` — a new preference key *and* a `BusinessSettingsMerger` branch.
- **Provider/balance** `0645ae566` + four follow-ups, **OAuth** `fc4d5e488`, `bdc124379`,
  `4466b3853`, **storage** `3e7f8987d`, `43d751465`.
- **Vendored markstream moved**: 14 files (`table_block.dart` +192, `selectable_rich_text.dart`
  +237, `document_selection_test.dart` +364). The fork does not patch the package — confirmed,
  no fork commit touches `dependencies/` — so it takes upstream's tree and adapts its own callers.
- **Polish, no fork bearing**: `0a44bc364` full-width desktop layout, `2e2dfbba5` Android status
  animations, `f1eac838c` the Windows WebView dispatcher queue, `9f4916367` macOS window dragging,
  `dd6c1de31` ASR transcripts, and the release commit `e0832d2b4` (version 1.3.7+89, which the
  content carry overwrites).

## 4. The unit assembly

**47 commits → 24 replayed units + the re-derived reformat.** Four commits disappear without being
replayed: the reformat (`bbf2b9b89`, re-derived at the tip per rule 10), the merge commit
(`c0127cbe9`, a PR merge — its two commits replay on their own and it falls out), and the two
release commits (`b2ddcc98e` 4.7.0, `b94aa1fec` 4.8.0), whose content — the version line and the
released changelog sections — belongs to the **content carry** in unit 1, since a re-base is not a
release.

Every fold below passed rule 13's test against the *intervening* commits; the fold removes replay
rounds but does not shrink the conflict surface, which is the union of the same paths.

| # | unit | members (position above baseline) | files | pause | note |
| --- | --- | --- | --- | --- | --- |
| 1 | `feat!:` identity + content carry | 1 | 1921 | 104 | 73 of the pauses are test files whose only fork change is `package:Kelivo/` → `package:Cuplivo/` — resolve as `rename(upstream)`, not by hand |
| 2 | `fix(tests):` baseline repair, Windows suite, l10n | 2 + 20 + 21 + 24 + 44 | 78 | 35 | the ios `path = …` literals, the two l10n sweeps, the l10n-gate cause, and `5ecbfcf01`. **Second on purpose**: the gates must be able to pass from here |
| 3 | `feat(recycle):` bin | 3 | 30 | 2 | |
| 4 | `feat(sync):` LAN sync + protocol v8 | 4 + 5 | 122 | 22 | adjacent; the bin's sync half belongs to the same unit |
| 5 | `feat(care):` 「Ta的来信」 | 6 | 69 | 9 | |
| 6 | `feat(chat):` link | 7 | 19 | 7 | |
| 7 | `feat(export):` PDF from markstream's tree | 8 | 34 | 0 | applies clean; see §6 for the overlay debt it carries |
| 8 | `feat(translate):` visible target set | 9 | 10 | 4 | **shrinks**: Bengali is absorbed by `23dc301c4`, so drop the `bn` catalog entry and `languageDisplayBengali`; keep `pt/hi/th/vi` and the 9-language default |
| 9 | `feat(suggestions):` | 10 | 11 | 1 | no upstream equivalent |
| 10 | `feat(group-chat):` topics, director, roster, owner order | 11 + 36 | 170 | 49 | `8ba8c9927` folds up for free (its only overlaps with the 25 intervening commits are ARB files) |
| 11 | `feat(backup):` written for a named reader | 12 | 25 | 8 | |
| 12 | `feat(markdown-image):` | 13 | 40 | 6 | no upstream equivalent |
| 13 | `refactor(sync):` premise + skill-body owner | 14 + 15 + 45 | 44 | 36 | `7f9f1e534` (the body-clock test) has zero overlap with anything between — it is that unit's own test file |
| 14 | `fix(memory):` snapshot carrier | 27 | 12 | 4 | |
| 15 | `fix(recycle):` a conversation's documents | 28 | 5 | 3 | cannot fold into 3 — `chat_database_repository.dart` and `recycle_service.dart` belong to units 10, 13 and 17 |
| 16 | `refactor(home):` one owner pipeline | 29 | 39 | 8 | see §5 on the sidebar |
| 17 | `refactor(sync):` family registration + grant | 30 + 31 | 69 | 52 | the widest single unit — it rewrites the enum→registration boundary across the DB layer |
| 18 | `fix(backup):` the reader's floor | 32 | 39 | 30 | cannot fold into 11: `data_sync.dart` is owned by 13 and `backup_portability_test.dart` by 17 |
| 19 | `ci(e2e):` | 33 + 34 | 16 | 2 | |
| 20 | `feat(image-job):` inline image in the reply | 37 | 95 | 12 | no upstream equivalent at v1.3.7 |
| 21 | `feat(sync):` lanes, byte budget, protocol 10, mutation clock | 38 + 39 + 40 + 41 | 74 | 51 | one adjacent run; the four commits are one design |
| 22 | `feat(subagent):` handoff + delegate target | 42 + 47 | 114 | 54 | `4c20b4462`'s only crossing is `home_page_controller.dart` against `55dc738c1`; accept it, the merge is local |
| 23 | `fix(export):` PDF inside Share | 46 | 36 | 23 | a **landing commit**, not a feature: it repairs unit 7 and cannot fold back into it (six units own its files) |
| 24 | `docs(rebase):` the record | 18 + 19 + 22 + 23 + 25 + 26 | 5 | 5 | replay the policy content; rewrite the v1.3.6 record into this pass's |
| 25 | `style:` reformat | 16 | 5 | — | **re-derived, never replayed** (rule 10), and last, so the series tip is again the reformat |

`pause` = the number of paths the 3-way merge stops on, predicted per commit and summed per unit
against `v1.3.7`; `delmod` cases included. 527 pauses over **289 distinct paths**: 111 code, 144
test, 15 docs/changelog, 13 l10n files (ARBs and generated output — cheap, per rule 2), 4 l10n
state files, 2 CI/deps. **The count is an upper bound**, not a promise: it merges each unit against
raw upstream, so a file an earlier unit already settled is re-forecast as hostile. The previous
replays predicted a ~300-file surface and stopped on 31; plan for 30-60 stops weighted to the files
below.

## 5. Where the pauses will be

Ranked by how many units stop on the path — this is the list to read first, not the file count:

| paths | file |
| --- | --- |
| 5 | `lib/core/database/business_settings_router.dart` |
| 5 | `lib/main.dart` — every unit registers here; it is a one-line conflict in each |
| 5 | `test/core/services/backup/data_sync_backup_file_test.dart` |
| 4 | `lib/core/database/business_repository.dart`, `chat_database_repository.dart`, `lib/core/services/recycle/recycle_service.dart` |
| 4 | `lib/core/services/sync/{sync_engine,sync_models,sync_data_plane}.dart` |
| 4 | `lib/features/home/widgets/side_drawer.dart` |
| 3 | `settings_provider.dart`, `assistant_provider.dart`, `sync_provider.dart`, `data_sync.dart`, `sync_merge.dart`, `workspace_content_sync.dart`, `desktop/tools_popover.dart`, `chat_tools_sheet.dart`, `chat_input_section.dart`, the two recycle pages, `sync_messages.dart`, `sync_report_breakdown.dart` |

And the upstream commits that own most of that surface — 56 of the 70 touch at least one
predicted-pause path:

| paths | upstream commit |
| --- | --- |
| 30 | `369a55a5e perf(backup): streamline large exports and restore progress` |
| 29 | `d0420c88e feat(chat): read and validate text attachments without a workspace` |
| 29 | `60270b2e3 feat(search): customize web search service icons` |
| 27 | `6a8c6e938 feat(chat): manage per-image context exclusions (#1521)` |
| 26 | `2864748ad feat(world-book): add book groups (#1546)` |
| 26 | `0645ae566 feat(provider): add automatic balance refresh (#1500)` |
| 25 | `83d336ca7 fix(backup): preserve server settings across cold starts` |
| 23 | `2464e2c70 feat(chat): customize thinking and tool cards (#1499)` |
| 22 | `3518c3dc1 feat(chat): allow model response speed overrides (#1519)` |
| 21 | `aee4f2ec0 feat(backup): guide imports through the official toolbox` |

## 6. Two places upstream moved *against* the fork

These are the pauses that look routine and are not.

**The restore-staging cancel ordering.** The fork's unit 2 deliberately moved
`ctx.throwIfCancelled()` to *after* `debugNativeSleepIgnoringKill` in both candidate isolates, with
"Keep the order" comments explaining that the hang is what keeps the isolate alive past the host's
abandon timer — the flake being fixed. `369a55a5e` rewrites the file (+291/−227) and keeps the
check *before* the hang in both places, exactly as the baseline had it: upstream never took the
fix, and the rewrite is where re-applying it now has to happen. Take upstream's structure and
restore the fork's ordering at the two new sites; do not resolve by taking either side whole. The
in-tree comments are the evidence that this is intentional, not stale.

**The export progress overlay.** `_runWithExportingOverlay` and its progress widget exist at
`c2b48958d` and at `upstream/master`, and are **absent from the fork's tip** — the previous replay
took the fork's side of that conflict and dropped upstream's machinery, against rule 8. The PDF
unit (7) and its landing commit (23) are where that gets repaired: upstream's overlay, our PDF path
driving it, one recorded stage.

## 7. Standing gates that will move

**Backup vocabulary (rule 17) — clean.** `business_data.dart` is byte-identical across all three
revisions: **no new `BusinessEntityKind`, no new `BackupCategory`, no new manifest root key, no
archive-format bump** in the v1.3.7 window. `KelivoVocabulary.v1_3_2` stays true as written, and its
own doc comment can now say the range was re-measured to v1.3.7. Nothing to disposition — which is
exactly what makes §2's schema-5 argument the binding one.

**`KelivoIN` and the search service (rule 18) — the search half is the live one.** Upstream still
seeds `ensureProviderConfig('KelivoIN', …)` (8 occurrences in `settings_provider.dart` at every
revision; only line numbers move), so a merge re-brings it and
`test/core/providers/kelivoin_removal_test.dart` has to stay in the replay. But the half that will
actually come back is `search_service.dart`: the fork deleted
`lib/core/services/search/providers/kelivo_search_service.dart` and its four call sites, upstream
still ships both, and `72a6f84a1` / `571bbd383` insert `case '4get'` and `case 'keenable'` *right
beside* the deleted `case 'kelivo'`. Any merge of that file restores the built-in service silently.
The removal gate covers the chat-provider surface only — extend it with a case for the search
service, and grep the merged tree for `kelivo_search_service.dart`, `case 'kelivo'`,
`KelivoSearchOptions`.

**Preference keys — 7 new registry rows at the tag, 26 if master is chosen.** The fork's
`BusinessKeyRegistry` is fail-closed and its guard is a source scan
(`test/core/database/business_key_registry_sync_test.dart`): every
`setBool`/`setInt`/`setString`/`setStringList` in `lib/` must resolve to a row. Against `v1.3.7`
the additions are the older window's seven:

- `balance_refresh_interval_v1`, `balance_refresh_on_reply_v1`,
  `chat_bubble_style_thinking_tool_card_v1`, `codex_client_version_v1`,
  `display_desktop_full_width_chat_v1`, `model_list_metadata_v1`, `world_books_grouping_v1`;
- `world_books_grouping_v1` also needs a `BusinessSettingsMerger` branch, or a merge-restore stops
  merging the local grouping;
- upstream's `localOnlyKeys` (`codex_client_version_v1`, `model_list_metadata_v1`) is the fork's
  **`deviceLocal`**, not `platformOnly` — `platformOnly` throws if anything writes through
  `BusinessPreferences`;
- `gen_ui_search_backfill_v1` looks like one and is not: it is a SQLite row key, it travels inside
  the candidate database, and registering it would be wrong.

Master would add 19 more on top (`mobile_sidebar_*`, `desktop_rail_entries_v1`,
`creation_*`, `video_model_v1`, `prompt_enhance_*`, `media_entry_seen_v1`,
`display_chat_image_*`, `translate_visible_language_codes_v1`), and would make
`image_model_v1`'s existing row's reason too narrow. Two of those 19 are a *replacement*, not an
addition: `translate_visible_language_codes_v1` and the fork's `translate_visible_languages_v1`
are one setting under two names, and only one may survive.

**Identity sweep (rule 3) — 13 files, not 1193.** 56 files are added by upstream in the window and
13 `.dart` among them still import `package:Kelivo/`. The in-tree machinery is now the way to do
it: `tool/identity/rename.json`, `tool/identity/verify.py` and `tool/identity/test_verify.py` exist
at the tip, so the sweep is a tool run plus its `--exact`/`--forward`/`--inverse` proof, not an
ad-hoc script. Two whitelist entries the sweep must not touch:
`import_toolbox.dart` hardcodes `https://kelivo.psycheas.top/tools/import` and a `kelivo-import-`
filename prefix — a `cuplivo.psycheas.top` host does not exist and a renamed prefix stops matching
what the web tool emits; and the ARB pair `backupPageTargetKelivo` / `backupPageTargetKelivoNote`
names the *other* application as an import target (`git grep -c Kelivo -- lib/l10n/` prints exactly
those two keys at the tip, and should keep doing so).

**l10n (rule 2) — per unit, as always.** The tag adds **96** messages (`app_en.arb` 5049 → 5140),
and two of them collide by name with keys the fork already has, both from `bb4930d56` (the minimap
search previews):

- `miniMapSearchNoResults` — identical value, different `@description`. Dedupe, take upstream's
  description.
- `miniMapSearchMatchCount` — **not the same string.** The fork's is `'{count}'` (the match *index*
  in the minimap list); upstream's is an ICU plural,
  `'{count, plural, one{1 match} other{{count} matches}}'` (the *occurrences within one message*).
  Two meanings under one key, so one must be renamed — the fork's own widget calls it, so the
  fork's key is the cheaper one to move, and upstream's name plus semantics is what survives. A
  key-set comparison cannot see this: both sides' key sets match and every value is non-empty.
- Two new values also name the other product — `backupPageChatboxUnsupportedBackupVersion` and
  `backupPageImportFromOtherAppsSubtitle`, both describing the official toolbox as converting *into
  a Kelivo backup*. That is a whitelist **decision, not a sweep**: the archive those strings
  describe really is Kelivo's, which is the same reasoning the `backupPageTargetKelivo*` pair
  already earned, and the string is false the moment it says Cuplivo. Record the decision in the
  identity unit's message rather than letting the sweep make it.

The `ru`/`ko`/`tr` ARBs arrive from the baseline again, so the ~4.7k inherited values need the
rename sweep — the four-defect lesson from the v1.3.6 pass, where the gate could not see them.

Master instead adds **337** messages, of which one collides by name (`languageDisplayArabic` —
identical value, dedupe) and two values name the other product (`creationModelKnown`,
`creationModelUnknown`).

**The lock and the carry.** `pubspec.lock` is committed on both sides and CI runs
`--enforce-lockfile`; seeding is one `flutter pub get`. The carry's deltas to re-apply over
upstream's `pubspec.yaml`: `name: Cuplivo`, `version: 4.8.0+11`, `+ device_info_plus`,
`+ basic_utils`, `+ pdf`, the `archive` override, the About-mark asset — and it must **reconcile
two divergences rather than replay them**: the fork removed `clock`, `connectivity_plus`,
`visibility_detector` and `chinese_codec`, all four of which upstream's new code now depends on, and
the fork holds `image: ^4.8.0` against upstream's `^4.13.0` bump (`90cdf6dc7`). Upstream also
dropped `easy_image_viewer`; the fork still declares it with one commented-out import left.

**Registries that are files, not code.** No known-failure registry is committed
(`git ls-files '*known-failures*'` is empty), so the platform-failure set lives with the local
bridge, not with the tree. Do not expect the runbook's "registered failures" numbers to reproduce
from a clone.

## 8. Order of work

**Before the replay** — on the current tip, once:

1. Normalise to the 24 replayed units, with the re-derived reformat at the tip, and prove it:
   `git diff --quiet <old-tip> <series-tip>` empty, `git merge-base --is-ancestor c2b48958d
   <series-tip>`, and the commit count moved by exactly the removes (47 − 4 = 43 members over 24
   units, plus the reformat = 25 commits). Fold adjacent runs with `git reset --soft`, and a
   non-adjacent pull with `git cherry-pick` then `git reset --soft <unit>^`; keep every folded body
   under a `folded from <sha>:` line — those bodies are what the next pass reads.
2. `git branch --force rebase/onto-v1.3.7 <series-tip>~1` — normalization is what makes the
   runbook's `~1` cut exact again: the reformat is the series tip, so `~1` drops precisely it. In
   the *current* line it is at position 16, which is why this cut cannot be used before the
   normalization pass.
3. `git config --local core.editor true` — a job has no terminal, and `rebase --continue` blocks in
   Vim forever.

**The replay** — `git rebase --onto v1.3.7 c2b48958d rebase/onto-v1.3.7`, one unit at a time:

- ask rule 7 first (has upstream done this?) and rule 9 (did upstream retire the symbol my hunk
  carries?) before resolving anything;
- `lib/l10n/` per key at dict level, then `flutter gen-l10n`; never a side (rule 2);
- `lib/main.dart` and the ARBs are the two files every unit touches — they are one-line pauses, not
  decisions;
- unit 1's 73 test pauses resolve as `rename(upstream)`; prove it with the identity tool rather
  than by eye;
- scan for conflict markers before **every** `git add` — the previous two passes each staged a
  different conflicted file after a clean-looking resolution.

**The landing** — units 23 and 24, then the gates in the runbook's order, then the reformat last
(rule 10). Back up both refs before the force push: `backup/master-4c20b4462` and
`backup/series-<old-baseline>`.

## 9. Open decisions this pass must take

1. **`v1.3.7` vs `master`** — §2. The recommendation is the tag; master costs the schema-6 ADR plus
   three re-anchors, and buys two unit deletions.
2. **Unit 8's shape at the tag** — shrink it (drop `bn`, keep the fork's four extra languages and
   the 9-language default) or drop the unit and wait for `493380ba5` next hop. Shrinking keeps a
   feature users may rely on; dropping is one less thing to maintain for one iteration.
3. **`image` `^4.8.0` vs `^4.13.0`** — the fork's ceiling is a delivery constraint, not a preference;
   upstream's new media code may need the newer API.
4. **Whether the vocabulary floor moves now.** Nothing forces it this pass (§7). Moving it to a
   `v1_3_7` constant beside `v1_3_2` is free and makes the label say 1.3.7 — but only if the
   reverse-import proof is re-run against that release, which is a manual step no gate replaces.
