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
| 3 | `9746532a4` | done: analyze clean, gen-l10n idempotent, full suite green at this tip (`+12840 ~94`); 65 recycle cases, 907 in `test/core/database` + storage + the storage-space pages, 343 in `test/core/services/chat` + the assistant cascade. §10 lists what it deliberately left for units 4, 5 and 11 |

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
  carried and what it re-opened. `00a2b7de0` is frozen for this plan; a later tip is a new re-base,
  not a retarget in place.
- The pinned formatter wants six files laid out differently at unit 2's tip —
  `lib/core/providers/settings_provider.dart`, `lib/features/chat/pages/image_viewer_page.dart`,
  `test/builtin_provider_test.dart`, `test/core/utils/token_estimator_test.dart`,
  `test/settings_provider_business_preferences_test.dart` and
  `test/shared/markdown/markdown_inline_code_escape_test.dart`. They are unit 1's carried content, so
  the format gate stays red until unit 14: the reformat is derived at the tip, never per unit.
- The count is 15 here; if the record folds into unit 1 the series is 14, and that is a decision to
  take at the tip, not now.

## 8. The `00a2b7de0` retarget — what the range carries

`git fetch upstream` moved `master` from `23bfa30e3` to `00a2b7de0`: six commits, and not a small
hop — 107 files, four subsystems. The series is built on `00a2b7de0`; this section is what the hop
carried and what taking it re-opened, so that §3's units are replayed against the right tree.

| commit | what it carries |
|---|---|
| `bb1e64ed9` | `feat(backup): run due external backups and clean interrupted transfers (#1462)` — the external-backup scheduler, its staging, partials and folder access, a rewritten `backup_page.dart` and `setting/backup_pane.dart` |
| `e54097c17` | `fix(chat): expose skills in the tablet toolbar (#1477)` — the *entry*, not the surface |
| `01796eda5` `581ef7d97` `00a2b7de0` | macOS login-keychain authorization and cancellation, a remembered backup password in a device-protected keychain (new `BackupPasswordKeychain.swift`, `MacBackupPasswordStore.swift`), manual encrypted backups |
| `f4d78f893` | `fix(chat): recognize model-led RTL prose… (#1465)` — inside `dependencies/markstream`, `prose_direction_resolver.dart` becomes `render/prose_direction.dart` |

### 8.1 `e54097c1` and the group-chat quick entries: one seam, two owners

`e54097c1` changes three things. `chat_input_section.dart` gains
`openSkills = isDesktop || isTablet ? onOpenSkills : null`, and `skillsActive` follows `openSkills`
instead of re-testing `isDesktop`. `home_page.dart`'s `onOpenSkills` now branches: desktop keeps
`showDesktopSkillsPopover`, everything else dismisses the keyboard and opens
`showConversationSkillsSheet`. Its test adds `isTablet: true` cases for both the toolbar and the
overflow menu.

`#1081` (`03e033d5e`, folded into unit 11) changed the *surfaces*, not the entry:
`conversation_skills_sheet.dart` and `desktop/skills_popover.dart` gained
`List<Assistant>? members`, a member strip above the rows and the rule that "the panel writes that
member's own list" (`scopeToAssistant: roster != null`); `bottom_tools_sheet.dart` passes the roster
in. It did **not** touch the skills handler in `home_page.dart`.

The line-level overlap is absorbed by the fold, and that is now load-bearing: `#1052` added
`isDesktop && !isGroup` and the `isGroup ? null :` exclusions to the entry arguments, `#1081` removed
them again. Folded into one unit, the net patch contains none of those lines — so the retarget's
`openSkills` line has nothing to conflict with, and a group inherits the tablet entry for free. Had
`#1081` stayed its own commit, its "remove `isGroup`" hunks would land on the line upstream just
rewrote.

The seam is: **upstream owns reach, the fork owns content.** Which form factor shows the entry, and
which surface it opens, is upstream's; what the surface shows for a roster is the fork's.
`showConversationSkillsSheet` is already conversation-scoped (`required String conversationId,
required Assistant? assistant`) and reads `chat.getConversation(id)?.extras`, so a group can use
upstream's tablet path unchanged. Two additions and one expectation remain for unit 11:

1. `home_page.dart`'s new else-branch passes only `conversationId` and the current assistant. A group
   has no current assistant, so the branch must also pass `members: <roster>`; the sheet's parameter
   is optional, so omitting it compiles and silently drops the per-member panel — the exact class of
   loss this plan exists to prevent.
2. `skillsActive` now evaluates `_isSkillsActive(context, a)` for a group on tablet. That helper asks
   `skills.resolveForAssistant(assistant, conversationOverride: …)` with a null assistant, i.e. the
   global list plus the conversation override — not "does some member have a skill". Unit 11 decides
   the roster rule instead of inheriting a light that means nothing.
3. Expect a small conflict in `chat_input_section.dart`'s `ChatInputBar(...)` argument list
   (upstream's hunk is lines 217-225; unit 11 inserts `leading:`/`leadingExtent:` and the strip into
   the list opened at line 208). Keep upstream's `openSkills`/`skillsActive`, add the fork's
   arguments.

### 8.2 `3849c87c7`: already on the baseline, and it survives the retarget

`3849c87c7 fix(macos): start Flutter before showing the main window` is `23bfa30e3`'s parent — `git
log --oneline -2 23bfa30e3` prints it directly below — so it is already in the tree and nothing needs
replaying. Its change is two files: drop `super.applicationDidFinishLaunching(notification)` from
`AppDelegate.swift`, and run the engine in `MainFlutterWindow.awakeFromNib`
(`flutterViewController.engine.run(withEntrypoint: nil)`, present at
`macos/Runner/MainFlutterWindow.swift:601`).

The rebrand does not touch it: unit 1's `macos/Runner/` diff is the app icons, `AppInfo.xcconfig`,
`RestoreHarness.xcconfig` and `Info.plist`, and the fork never touched either Swift file
(`git log 4857da608..master -- macos/Runner/AppDelegate.swift macos/Runner/MainFlutterWindow.swift`
is empty). The retarget keeps it too: `23bfa30e3`→`00a2b7de0` changes `MainFlutterWindow.swift` by
+59 lines at the end (the backup folder and keychain channels) and +48 at line 455, with
`super.awakeFromNib()` and the `engine.run` line as context. Verdict: nothing to do, before or after
the retarget.

### 8.3 Preventing an over- or under-rename

This range is the first real test of the sweep, because it carries both kinds in one diff: **35** new
`import 'package:Kelivo/…'` lines to rename, **41** new ARB values naming `Kelivo` across the seven
locales, and about **thirty** persisted or protocol names to protect (`kelivo_backup_*`,
`kelivo_auto_<installId>_`, `.kelivo-autobackup-<id>.json`, `kelivo/backup_keychain`,
`kelivo.backup.encryption_password`, `kelivo_backups/`, `kelivo-managed-keychain-*`, and
`"Kelivo local backup keychain v1"` — which reads like prose and is an HKDF salt). The method is
runbook rule 19: a checked-in spec (`substitutions`, `protected`, `mechanical`), a forward check for
what is left, an **inverse** check that each protected name is still *present* where upstream has it,
a substitution-exactness check for what went too far, and the proof that the inverse check fails when
the known defect is injected.

It is in the tree now: `tool/identity/rename.json` (28 protected names, each with a floor and a
reason), `tool/identity/mechanical.txt` (1515 derived files) and `tool/identity/verify.py`. CI runs
the forward half on every PR; the full check runs after unit 1 and at the tip. Measured on this
series: 1515 mechanical files, 313 hand-resolved, 20 brand tokens the change introduced that nobody
had classified. The spec's first draft was wrong twice, and both are worth keeping: `KelivoPtyJni` is
a `#define LOG_TAG` the fork's own identity commit renames to `CuplivoPtyJni` (a log line is
branding), and the bare `'kelivo'` literal's total in `browser_workspace_resources.dart` is four, not
two, so the entry has to be the *comparison* (`uri.scheme == 'kelivo'`, count 2) — which is exactly
the pair a sweep breaks when it renames one side and not the other.

### 8.4 What the retarget re-opens

- **Unit 1** ran the sweep over the new range: 1,563 files still carried `package:Kelivo/`, 37 ARB
  values and 4 descriptions named `Kelivo` across the seven locales, and the ~30 protected names held.
  It cost thirteen conflicts, all of them in files unit 1 owns, and no product change: the four
  per-Flutter-version build workflows are deleted after taking the bump's `libsecret` facts, the
  fork's `release.yml` carries them, and the three brand-string crossings are three-way.
- **Unit 2** found a fifth failure class the `23bfa30e3` run never had — the backup staging move,
  recorded in §6. The nineteen path fixes stayed valid, and the new files needed their own look.
- **Unit 4** (sync): the range adds preference keys (`external_backup_auto_*`). The fork's
  fail-closed preference registry needs a row for each, or `setMany` asserts (the runbook's "the suite
  found", cause 1).
- **Unit 12** (`#1071`) now replays onto a rewritten backup subsystem — `backup_page.dart`,
  `setting/backup_pane.dart`, `data_sync.dart`, `backup_portability.dart`,
  `business_settings_router.dart` all moved. It becomes the largest conflict surface in the series.
- **`dependencies/markstream`**: the RTL refactor means `docs/markstream-delta-audit.md`'s hand-cursor
  gap must be re-checked against the new package before it is recorded as still open (AGENTS.md:
  re-check per re-base).
- **The document itself**: §1's frozen baseline, §2's rows, §3's `depends on` column and this title
  all named the old baseline. The retarget rewrote them, and the file is
  `rebase-plan-00a2b7de0.md` now; the unit *content* did not change.

## 9. The retarget, resolved

Two branches exist. `reorg/green-23bfa30e3` is the series as it stood on the old baseline
(`0423cb6ec`, seven commits). `reorg/green-00a2b7de0` is this series: the same seven replayed onto
`00a2b7de0`, and units 3–15 follow there.

The retarget replays the **resolved** units rather than upstream's patches — the `199647a5d`
precedent — so unit 1 costs only the conflicts where the six new commits touch a file unit 1 owns.
`git cherry-pick 79f0b176e` onto `00a2b7de0` reported **thirteen**, against 86 on the first run, and
each resolved as this table said it would:

| files | why they collided | resolution |
|---|---|---|
| `.github/workflows/build-linux-arm64.yml`, `build-stable-47.yml`, `build-stable.yml`, `build.yml` (modify/delete) | unit 1 deletes them; the new range bumped each by four lines | deleted, after taking the bump's facts — `release.yml` is the only build workflow (the CI rule) |
| `.github/workflows/release.yml` | it is the rename of `build-stable-44.yml`, which the new range bumped | kept the branded file, re-applied the bump's facts (`libsecret-1-dev` in the apt list, `libsecret-1-0` in the deb `Depends`) |
| `lib/core/services/backup/data_sync.dart` | the new range rewrites 347 lines of the backup subsystem; unit 1 touched its strings | three-way: upstream's structure, the fork's names |
| `lib/features/home/widgets/side_drawer.dart` (21), `lib/features/intelligent_ui/widgets/genui_content.dart` (9) | brand strings against upstream's edits | three-way |
| `settings_provider_backup_encryption_test.dart` (+103), `backup_encryption_tile_test.dart` (+201), `backup_temp_cleanup_test.dart` (45), `settings_card_layout_test.dart` (+11), `chat_input_section_skills_test.dart` (+64) | new upstream tests that unit 1 had swept | took upstream's test, then re-applied the brand rename — the incoming side is renamed too (the runbook's rule) |

Unit 1 is `8d71b60f3`; unit 2 is `a56653bc9`. What the resolution cost, beyond the table:

- **The incoming side is renamed too**, and it is the class no `git status` reports: the range's own
  copy named `Kelivo` in 37 ARB values and 4 descriptions across the seven locales, and eight files it
  added or extended still carried `package:Kelivo/` — none of them conflicts.
- **The spec was re-derived, not edited.** `rename.json`'s `baseline` is `00a2b7de0` and
  `mechanical.txt` is regenerated: 1,516 mechanical files, 320 hand-resolved, 20 unclassified tokens —
  the same twenty the old baseline had, which is the check that the retarget did not change the
  sweep's character.
- **The first run of the checker found a defect in the checker.** `--forward` failed against
  `tool/identity/rename.json` and `verify.py`: the files that *define* the rule spell the needles on
  purpose. They are exempt now, and the tool's own tests assert the spec still spells every `from`, so
  the exemption cannot hide a rewritten rule. This is the first time the checker ran on a *moving*
  baseline, which is what it was built for.
- **Unit 2 grew a fifth failure class** the old baseline never had: the backup staging move. §6
  records it, and it was 33 of the failures the first full run showed.

The order it ran in:

1. `flutter gen-l10n`, then `dart analyze --fatal-infos lib test integration_test`.
2. `python tool/identity/verify.py --derive --write` against `00a2b7de0`, then `--forward`,
   `--inverse` and `--exact` clean — and the scheme defect injected and reverted to prove `--inverse`
   still fails on it.
3. `git cherry-pick 9ce0fbeb4` (unit 2), then the gates: `gen-l10n` idempotent, analyze clean,
   `flutter test` green (`+12775 ~94`).
4. Only then unit 3.

Nothing in §3's unit order changed. What changed is which tree each unit is replayed onto.

## 10. What unit 3 deliberately left for the units after it

Unit 3 is the bin's **product** half. The sync side of the same feature was not carried, because sync
does not exist on this line yet, and a hook that stages a peer's write has nowhere to hang. This is the
list, by destination, so that nothing is lost by silence — the next unit's replay is where each line is
expected back.

### 10.1 Unit 4 (`feat(sync)`) re-introduces

| what | where | why it is not in unit 3 |
|---|---|---|
| the sync subsystem — engine, merge, models, limits, store, data plane, provider | `lib/core/services/sync/**` | it is unit 4's whole content |
| the four path helpers: `isSafeWorkspaceRelativePath`, `workspacePathWithin`, `nearestExistingAncestor`, `isReallyInsideWorkspace` | `lib/utils/workspace_paths.dart` **already here** | unit 3 moved them out of `workspace_content_index.dart`; unit 4's index must *import* them, not re-declare them |
| `isSafePathSegment`, `isSafeWorkspaceId` | `lib/utils/app_directories.dart` **already here** | shared; the bin asks them whether or not the device has ever synced |
| `BusinessStateReloader` | `lib/core/services/business_state_reloader.dart` **already here** | unit 3 provides it in `main.dart`; unit 4 adds `_wireSyncReloaders` (the 14 `register(...)` calls) and the providers' `reloadAfterExternalChange()` |
| `ChatService.reloadAfterExternalChange` | `chat_service.dart` **already here** | unit 3's version reloads the caches and bumps the context revision; unit 4 adds the `_externalWriteRevisions` map and `externalWriteRevision(id)`, so an open window rebuilds after an apply |
| `currentSchemaColumns` | `lib/core/database/schema_columns.dart` **already here** | the bin builds row snapshots from it; the sync apply builds its SQL from it |
| `BusinessEntityKind.wireName` | `business_data.dart` **already here** | the bin records it per entry; the wire names the kind with it |
| a `BusinessKeyRegistry` row per `external_backup_auto_*` key | `business_key_registry` | §8.4: a key with no row makes `setMany` assert, and the suite finds it as cause 1 |

### 10.2 Unit 5 (`a restore is an edit — protocol v8`) re-introduces

The **sync-side staging** is the bin's other half. Product hunks, all of which are in the old line's
`237c9a097` rather than in the recycle commit:

- `BusinessRepository.syncDeleteEntity` and `syncDeletePreference` — `stageEntityRow` /
  `stagePreferenceRow` **before** the delete, with `origin: RecycleOrigin.remote`,
  `reason: RecycleReason.deleted`. A peer's removal has no clock protecting the local edit, so this is
  the only moment it can be preserved.
- the apply path's losing comparison — stage with `reason: overwritten` immediately before the upsert
  replaces the local value; that is the only point where the losing version still exists.
- `ChatDatabaseRepository.syncApplyPeerDeletion` → `deleteConversation(id, origin: RecycleOrigin.remote)`.
- `WorkspaceContentSync` — the `RecycleService? recycle` it takes, for the file a swap replaces or
  removes, and the `workspaceRoot` the restore needs.

Test cases deleted from unit 3 because they call sync APIs, to be brought back with the hunks above:

- `recycle_business_test.dart`: "a losing local edit is staged, an identical echo is not"; "a
  preference that loses is staged and restorable"; "restoring an overwritten row keeps the version it
  displaced"; "a peer deleting a row stages it before the delete"; "a row this device keeps out of sync
  is not staged"; "a peer deleting a preference stages it before the delete"; "a preference that is set
  again is not written over".
- `recycle_conversation_test.dart`: "a peer deletion stages with the remote origin".

### 10.3 Unit 11 re-introduces

As §8.1 says: `members: <roster>` at `home_page.dart`'s new else-branch, and the `skillsActive`
decision for a roster (`_isSkillsActive` with a null assistant reads the global list plus the
conversation override, which is not "some member has a skill").

### 10.4 Two things unit 3 changed that a later unit must not undo

- The `json(...)` wrapper around each `json_group_array` in `_readConversationSubtree`. Without it
  SQLite embeds the array as a string on this build, the decode finds no rows, and a delete stages
  nothing — silently. Runbook rule 20 carries the trap.
- `schema_columns.dart`'s header still describes the map as "every table LAN sync may write". It is now
  the bin's schema source too; the wording is unit 4's to widen, the map itself is shared.
