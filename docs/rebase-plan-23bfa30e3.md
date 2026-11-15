# Re-base onto Kelivo `00a2b7de0` — the plan

This document is the goal. The mechanics live in [the runbook](rebase-runbook.md); where the two
disagree, this document wins for this re-base.

## 1. The goal

**Put Cuplivo 4.6's product back on a clean upstream baseline as fifteen commits that each stand on
their own.** A person who checks out any one of them gets a tree that builds, passes its own tests,
and means something — not a patch pile where only the tip runs.

In priority order:

1. **Every commit is self-consistent.** `dart analyze --fatal-infos` is clean, the commit's own tests
   pass, and the tip passes the full suite. "The units do not compile" is a property of the old
   series, not a law; this re-base exists partly to end it.
2. **The upstream baseline is green on Windows by the second commit.** Everything the new baseline
   broke on this platform is repaired there, so every later unit replays onto a tree whose gates can
   pass.
3. **No product capability is lost silently.** The two deliberate drops (the manual image editor and
   the compression readout) are recorded with what they cost; everything else in 4.6 is present.
4. **The series is replayable.** One commit per feature family, in dependency order, so the next
   re-base replays units instead of re-splitting a tree.
5. **The history is honest.** A dropped unit has an ADR or a record; a folded follow-up keeps its
   message; a removal is carried by a standing test, never by a claim in a commit message.

What this is **not**:

- Not a release. No version bump, no tag, no `release.yml` dispatch. `pubspec.yaml` keeps `4.6.0+9`.
- Not tree-equality with the old tip. Two units are dropped, so the trees must differ; equality is
  checked only over the parts that were not dropped.
- Not a port of the fork forward. The old tree is a *content source*, never a base.

## 2. Definition of done

| check | target |
|---|---|
| series | 15 commits above `00a2b7de0` (13 content + reformat + record) |
| ancestry | `git merge-base --is-ancestor 00a2b7de0 HEAD` |
| per commit | `dart analyze --fatal-infos lib test integration_test` clean; the commit's own tests pass |
| per commit | `flutter gen-l10n` idempotent (`git status --short -- lib/l10n` empty) |
| tip | full `flutter test` green; the browser engine's cases run on every host, including Windows |
| tip | `python tool/l10n/translate.py check` exits 0 |
| tip | `dart format --output=none --set-exit-if-changed` names no file |
| identity | `git grep -c Kelivo -- lib/l10n` matches only `backupPageTargetKelivo*`; `package:Kelivo/` only in documents |
| l10n | seven ARBs share one inventory; every message has a description; `@kelivo/fetch` in all seven |
| backups | `backup/master-<old-tip>` and `backup/series-23bfa30e3` pushed before any force push |

## 3. The fifteen commits, by what each one delivers

The order is a dependency order, not a chronology. Each line names the *outcome* first and the
content second.

| # | commit | the outcome it delivers | depends on |
|---|---|---|---|
| 1 | `feat!: Cuplivo identity on the Kelivo baseline (00a2b7de0)` | a tree that is upstream's, renamed and carried: package `Cuplivo`, `com.cuplivo.cuplivo`, platform identity, seven ARBs branded, the fork's documents and CI, the built-in `KelivoIN` gone with a standing test that keeps it gone | — |
| 2 | `fix(tests): the new baseline's suite` | the upstream baseline is green on this machine, so every later unit replays onto a passing tree | 1 |
| 3 | `feat(recycle): the bin (core)` | deleting a conversation, a merge loser or a workspace file is recoverable, without depending on sync | 2 |
| 4 | `feat(sync): LAN sync, the dual stack, candidate probing (#1083)` | two devices converge over the LAN, with one policy table deciding what travels | 3 |
| 5 | `feat(sync): a restore is an edit — protocol v8` | the bin's restore survives a sync round instead of being re-deleted; the workspace plane stages what it replaces; #1084's skill-body lifecycle | 4 |
| 6 | `feat(care): 「Ta的来信」, the roleplay tab, the backgrounded letter` | proactive care arrives on every platform it claims, with the composer and alarm contract it needs | 5 |
| 7 | `feat(chat): copy a conversation or message link (#1013, #1034)` | iOS and Android links are one feature | 6 |
| 8 | `feat(export): a PDF from markstream's tree` | export needs no WebView and no second renderer | 7 |
| 9 | `feat(translate): user-managed target languages incl. Bengali` | the visible target set is the user's | 8 |
| 10 | `feat(suggestions): a chat-suggestions switch per assistant` | suggestions are a per-assistant choice | 9 |
| 11 | `feat(group-chat): topics, the director, the roster (#1081, #1074)` | multi-agent conversations, one owner order, and one switch separating assistants from groups | 10 |
| 12 | `feat(backup): a backup written for a named reader (#1071)` | a Cuplivo backup goes back into Kelivo: the reader's vocabulary is a contract, not private storage | 11 |
| 13 | `feat(markdown-image): one clean picture, one tab's input` | rendered Markdown becomes one image, and a tab keeps its own input | 12 |
| 14 | `style: reformat the files the pinned SDK lays out differently` | the format gate has nothing to say; droppable and re-derivable | 13 |
| 15 | `docs(rebase): the 00a2b7de0 record` | the next re-base reads numbers instead of an impression | 14 |

**Why the order is what it is.** Recycle precedes sync so the bin is a product on its own; the sync
integration follows as its own commit because it changes the sync *protocol* (v7 → v8) and that is a
compatibility decision, not a recycle detail. Group-chat precedes backup because group-chat adds
`BusinessEntityKind.groupChat` (`sourceKey: 'group_chats_v1'`), and an older Kelivo reader throws
`FormatException` on that key inside `_rowIdsByKind`; #1071 is the answer to exactly that break, so it
cannot come earlier. Care precedes the composer-touching units because they share
`chat_input_bar.dart` and `home_page_controller.dart`.

## 4. The decisions this plan makes, and what each costs

| decision | goal it serves | what it costs |
|---|---|---|
| Drop the image unit entirely | one editor over one composer; the fork stops competing with upstream's `e416814f5` editor and its five `ImageUploadQuality` presets | explicit PNG output and the bounded working image (ADR-0005) are gone; the `dependencies/downsize` patch goes with them. Recorded as withdrawn in ADR-0002/0005 and CONTEXT |
| Drop the compression readout | upstream's compaction rework owns the estimate surface now | the token readout and the reply hooks are not replayed; ADR-0011/0012 stay withdrawn |
| Fold `#1078/#1080` into unit 1 | the removal lands where the baseline's provider list is resolved, and its standing test travels with it | the identity commit is no longer purely mechanical; its subject has to say so |
| Fold `#1081` and `#1074` into group-chat | one group-chat unit, not three | a reorder makes the same change arrive twice; the tip tree must be checked, not just the markers |
| Put recycle before sync | the bin does not depend on the network | two path helpers move out of `sync/` into `lib/utils/`; the sync-side staging moves to unit 5 |
| Make unit 2 the only home for Windows repairs | every later unit replays onto a passing tree | unit 2 is large and test-heavy; it is also the commit that proves the baseline |
| Complete the browser test's platform fake instead of skipping the platform | the Windows dialog bridge is product code that a real host runs; a fake missing two DevTools overrides is a harness gap, not a platform without an engine | the fake answers `addDevToolsProtocolEventListener` and `callDevToolsProtocolMethod`, so the Windows-only path is exercised on Windows instead of being skipped there |
| Reformat as its own tip commit | the format gate stays droppable and re-derivable | one more commit; it can never be folded into a feature unit |

## 5. The method (secondary)

The runbook's procedure, with the one change this plan makes: **the series is built forward and gated
per commit**, not replayed tip-first.

1. `git cherry-pick` each unit onto `reorg/green-00a2b7de0`; resolve with `rename(upstream)` when the
   fork's only change to a file was the two substitutions, a three-way merge when both sides moved,
   and by hand when neither rule applies.
2. After each unit: `dart analyze --fatal-infos`, then the unit's own tests. A unit that does not
   compile is a defect in the unit, not an accepted intermediate state.
3. Folds: `git cherry-pick -n <follow-up>` then `git commit --amend`, so the unit keeps one message
   and the folded body is appended to it.
4. The reformat is re-derived at the tip with the pinned SDK; it is never replayed.
5. The record is written last, from the gates actually run.

The bridge's git surface has no `checkout`, `reset` or `rm`; units are moved with `cherry-pick`,
`rebase --onto` and `commit --amend`, and deletions go through the working tree plus `git add`.

## 6. Where the work stands

| unit | commit | state |
|---|---|---|
| 1 | `8d71b60f3` | done: analyze clean, gen-l10n idempotent, `package:Kelivo/` gone, the identity checker clean in all three directions — plus the browser workspace scheme restored after the suite caught the over-rename |
| 2 | `a56653bc9` | done: `flutter test` green (`+12775 ~94`), `dart analyze --fatal-infos` clean |

The 115 failures this unit started from were four classes, and only one of them was a platform without
a service:

1. **A fixture built a path with `/`** (19 cases). The comparison was against a `p.join`ed path or a
   path the app had canonicalised, so `\` and `/` never matched. Fixed with `p.equals` at the
   comparison and `p.join` at the construction. The fork's 4.6 had already repaired most of these;
   the replay lost the repair wherever upstream's newer version of the same test arrived, so unit 2
   re-applies it — that is why the fixes read like a re-derivation rather than a discovery.
2. **Two harness gaps.** `browser_native_engine_test` faked the platform controller without the two
   DevTools methods the engine's Windows dialog bridge calls, so all 69 of its cases died in the
   platform interface's default `UnimplementedError`; the fake now answers both, and the Windows-only
   path runs on Windows. Three tests deleted a temp directory a live reader still held (`errno 32`)
   and now use `deleteDirectoryWhenReleased`.
3. **One genuine platform predicate** (5 cases). `android_ime_selection_test` drives the Android key
   packet, which a Windows engine does not deliver; the fork's `androidKeyData = !Platform.isWindows`
   skip came back, so the cases skip here and still run where the packet exists.
4. **Two product defects the suite caught in unit 1's sweep.** The browser workspace scheme `kelivo`
   had been renamed to `cuplivo` while the registry still advertised `KelivoLink.scheme`; and
   `restore_failure_space_test` still expected upstream's "Update Kelivo" sentence where the ARB now
   says Cuplivo.

The retarget added a **fifth class**, and it is the only one that is not about Windows: `bb1e64ed9`
moved a backup's working files out of the system temp directory into a staging root that, on a
desktop host, lives inside the app's own data directory. Eight test files had the old location baked
in — three named `tmp/kelivo_backup_staging` literally, two never mocked `path_provider` because
nothing on the recovery path used to ask for it, one tripped the retention guard with the staging
directory the new inspection creates inside the iOS private root, and `restore_failure_space_test`'s
disk-full and access-denied cases injected `ENOSPC` by swapping the system temp directory, a seam
that went away with the move. The last one needed the one product change in this unit: a
`@visibleForTesting` `BackupStaging.debugRootOverride`, because `Directory.create` cannot be
intercepted by `IOOverrides` and a real directory cannot be made to fail on demand.

Next: unit 3, the recycle bin's core.

## 7. Open risks

- `python tool/l10n/translate.py check` has not completed on this machine; the state files were
  recomputed offline with the tool's own `fingerprint()`. CI's `check` is still the authority.
- `flutter pub get` resolved `sqlite3 3.9.1` from the git override; the runbook records 3.8.0
  breaking the recycle bin's staging. Re-check when unit 3 lands.
- Upstream moved once already: `master` was `23bfa30e3` when this plan was written and is `00a2b7de0`
  now (six commits, 107 files). The series is built on `00a2b7de0`, and §8 records what that range
  carried. `00a2b7de0` is frozen for this plan; a later tip is a new re-base, not a retarget in place.
- The pinned formatter wants six files laid out differently at unit 2's tip —
  `lib/core/providers/settings_provider.dart`, `lib/features/chat/pages/image_viewer_page.dart`,
  `test/builtin_provider_test.dart`, `test/core/utils/token_estimator_test.dart`,
  `test/settings_provider_business_preferences_test.dart` and
  `test/shared/markdown/markdown_inline_code_escape_test.dart`. They are unit 1's carried content, so
  the format gate stays red until unit 14: the reformat is derived at the tip, never per unit.
- The count is 15 here; if the record folds into unit 1 the series is 14, and that is a decision to
  take at the tip, not now.
