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
| 5 | `feat(sync): a restore is an edit — protocol v8` | the bin's restore survives a sync round instead of being re-deleted; the workspace plane stages what it replaces | 4 |
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
| 4 | `a9137a796` + `971f8293e` | done: analyze clean across `lib test integration_test`; the sync subsystem replayed with `#1068`'s policy table folded in. 574 cases in the unit's own set, 2,725 in the database/chat/backup/providers set it touches, and the full suite `+13344 ~94` with one failure that was this unit's own comment tripping a text gate. §11 records the repairs the old commit needed, the table's thirteen transposed rows, and what it changes about §10's list |
| 5 | `a81991887` | done: protocol v8 (the row clock in the announcement, `copyWrittenSinceAgreement`, the business face's clock pair) and the bin's sync half — the staging §10.2 listed. analyze clean, gen-l10n idempotent, format no changes, 526 cases across the sync, recycle and provider suites. §12 records what the unit's source turned out to be |
| 6 | `4360703f7` | done: 69 files — the cross-platform care port, the roleplay tab, the backgrounded letter (`#1064` folded). analyze clean, gen-l10n idempotent, format clean, 112 care cases + 2,452 in the home/assistant/chat/providers/models set. §13 records the two files whose fold was silently dropped, and the one API the baseline had never had |
| 7 | `bbc456ac2` | done: 19 files — `ConversationLink` and the two native handovers (`#1034` folded; it was the same feature on the second platform). analyze clean, gen-l10n idempotent, format clean, 108 cases in the unit's files and 2,450 across `test/features/chat` + `test/features/home` |
| 8 | `dae39a81c` | done: 34 files, the PDF exporter (2.8k-line emitter, document model, fonts, dialog) with the old line's own landing repairs folded in; the unit's duplicate citation module collapsed onto the baseline's. analyze clean, gen-l10n idempotent, format no changes, 92 export cases and 3,333 across chat/home/shared. §14 records why this unit could not compile as written |
| 9 | `383b0f18d` | done: 10 files — the visible target set, the manager, the shared `effectiveTranslateLanguage` rule, and five languages the catalog never had. analyze clean, gen-l10n idempotent, format no changes, 31 cases across the translate page (both form factors), the catalog, the manager and the dropdown. §15 records the one place this unit was *older* than the baseline |
| 10 | `70659cc35` | done: 11 files — the per-assistant opt-out in both assistant layouts, one predicate for the "not in effect yet" note, and the render gate moved to one accessor. analyze clean, gen-l10n idempotent, format no changes, 21 cases in the unit's own five files and 3,207 across assistant/home/backup/sync/models/providers. §16 records the unit whose own test was red against its own code |
| 11 | `7918424bc` | done: 141 files — the four group-chat commits folded into one unit: topics, the director, the roster, the shared owner order, the composer's roster-following entries, and the group's reasoning/tools/skills panels. analyze clean, gen-l10n idempotent (38 keys × 4 ARBs), format no changes except the six unit-14 files, 461 cases across the unit's surfaces and the full suite green after the six failures it caught were fixed. §17 records the six forward references, the fourth helper collapse, and the two tests rewritten to an invariant |
| 12 | `ca1f34cfd` | done: 25 files — a named backup reader, the pinned Kelivo vocabulary, archive format 3 → 4 with 2 and 3 still readable, and the standing test that refuses an unlisted business kind. analyze clean, gen-l10n idempotent, format no changes except the six unit-14 files, 666 cases across the vocabulary, portability, backup feature and backup service suites. §18 records the hunk a reorganized page moved, and the rule the carry already held |

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

Next: unit 13, `feat(markdown-image)`.

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

Each row landed in unit 4 with one deviation, and §11 records it: the two helpers unit 3 had already
moved (`workspace_paths.dart`, `business_state_reloader.dart`) came back in the replay, and the unit had
to *delete* the copies rather than re-declare them — `workspace_content_index.dart` was carrying its own
`isSafeWorkspaceRelativePath`/`workspacePathWithin`, and `sync/business_state_reloader.dart` was a second
copy of a class that already lived one directory up.

### 10.2 Unit 5 (`a restore is an edit — protocol v8`) re-introduces

**Delivered in `a81991887`.** Every bullet below landed; the three amendments unit 4 made to this list
(superseded in §11.2) stood, and the unit's total was 13 files, +1,099/−144. See §12 for why the source
turned out to be easy to find.

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

Unit 4 changed three things about this list, because `#1068` landed between the two halves:

- `syncDeletePreference`'s guard is `BusinessKeyRegistry.isSynced(key)`, not `BusinessKeyRegistry
  .classify(key) == BusinessKeyDisposition.syncedPreference` — the disposition enum is gone. The staging
  call still does not exist there; unit 5 adds it beside the new guard.
- The older-peer test (`sync_engine_integration_test.dart`, "a key an older peer cannot accept is re-sent,
  never read as a deletion") arrived with `#1068`, and its recycle-bin assertions — `_Side(withRecycle:
  true)`, `a.recycle`, `RecycleEntryType.preference`, the empty-bin check — were left out here for the
  same reason. Unit 5 restores them with the staging.
- `test/features/settings/translate_language_catalog_test.dart` is unit 9's; `#1068` edited it, so unit 9
  must take the edited version rather than the one its own commit carries.

### 10.3 Unit 11 re-introduces

As §8.1 says: `members: <roster>` at `home_page.dart`'s new else-branch, and the `skillsActive`
decision for a roster (`_isSkillsActive` with a null assistant reads the global list plus the
conversation override, which is not "some member has a skill").

### 10.4 Two things unit 3 changed that a later unit must not undo

- The `json(...)` wrapper around each `json_group_array` in `_readConversationSubtree`. Without it
  SQLite embeds the array as a string on this build, the decode finds no rows, and a delete stages
  nothing — silently. Runbook rule 20 carries the trap.
- `schema_columns.dart`'s header used to describe the map as "every table LAN sync may write". Unit 4
  widened it to name both readers (the bin's row snapshots and the sync apply's SQL); the map itself
  stayed shared, and the two columns lists did not diverge.

## 11. Unit 4's replay — the old commit is not only non-compiling, it is corrupt

The plan expected unit 4 to be the series' largest conflict surface: 40,851 insertions over 118 files,
and `chat_database_repository.dart` rewritten by 858 lines while unit 3 had threaded `recycle` through the
same file. The measured surface was **20 conflict blocks in 13 files**, and the reason is worth carrying
into the next re-base: `f36104732` is a squash of a feature branch rebased onto the baseline, so most of
its edits are *additions* to files this branch had not touched. The conflicts were the imports and the
four files the two sides both rewrote.

What made the unit expensive was not the conflicts. It was that **the old commit does not compile, and
not only because it calls later code.** Three separate kinds:

1. **Committed conflict markers.** `desktop_settings_page.dart` carried a `||||||| .scratch/st-base.tmp`
   block whose "theirs" half was the whole pre-`DesktopAdaptivePanes` widget tree, and
   `assistant_provider.dart` carried one whose "theirs" half was the old `_duplicateLocalFile` body
   wrapped in a `try`. Both regions were reconstructed from this branch's version plus the commit's real
   change (a `lanSync` menu item → `DesktopSyncPane`; `canonicalStorage` on the copied avatar path).
2. **A method spliced into itself.** `updateMessageFields`'s header and body appear twice in the old
   blob: the outer header opens, a second header opens inside it, one complete body closes, and a
   truncated second body follows. The class therefore closed one brace early, every method after it
   became a top-level function, and `dart analyze` reported 318 errors of the shape "isn't defined for
   the type `ChatDatabaseRepository`" — none of them in the file itself. The repair is this branch's
   body plus the commit's one semantic change (`updated_at` floored at the row's own timestamp, so a
   local edit cannot lower the LWW clock of a message authored under a skewed peer clock).
3. **Forward references.** `SandboxPathResolver.canonicalStorage`, `isLinkedWorkspace`,
   `workspacePayloadNamesId` and `RestoreBundleMover.resetSyncState` are called by this commit and
   defined by later ones. Each definition is small and is genuinely part of this feature (a stored
   spelling that can travel, workspace portability, a replaced database dropping its checkpoints), so
   each came in here rather than being dropped from the call site.

The test harness needed the same treatment. The widget cases drive the pairing panel, whose countdown is
a `Timer.periodic` and whose progress bar repeats forever, so `pumpAndSettle` runs to its ten-minute
deadline — the failure `docs/flaky-tests.md` §15 records. The `pumpPanel`/`_closePanel` helpers that fix it
were added by the old line's 4.5 close-out (`b264ef05a`), i.e. *after* this commit, so they were applied
here: 15 `pumpPanel` calls and 9 `_closePanel` teardowns. A unit whose own tests cannot finish has not met
the definition of done.

### 11.1 The policy table (`#1068`), folded

`bb079ed2d` is the runbook's family-table entry for sync, and the plan's unit 4 already says "one policy
table deciding what travels", so it folds here. Its conflicts were 5 files — `BackupPortability`,
`business_repository`, the registry itself, and two tests — because the table was written against the
old line's key set. The rules that resolved it:

- **The table is the authority.** `BusinessKeyRegistry.rules` replaces the three hand-kept sets *and*
  `BackupPortability.devicePreferenceKeys`; the portability layer now derives its strip list from
  `KeyPolicy.deviceLocal`. Taking the table wholesale was the only option that keeps one authority.
- **A key upstream added needs a row, and the row is transposed from the lists this branch kept by
  hand.** The reliable way to find the gap is to diff the table against the three sets unit 3 still
  carried (`preferenceKeys`, `localOnlyKeys`, `discardedKeys`), not to wait for the analyzer: it found
  exactly two keys, which is the check that the transposition is complete. Between that and the
  writer scan the unit added **thirteen** rows: five `backup_auto_*`, `environment_native_shell_path_v1`,
  `backup_password_remember_manual_v1` and `backup_password_verifier_v1` (all eight were in
  `BackupPortability.devicePreferenceKeys` → `deviceLocal`); `desktop_autostart_hidden_v1` and
  `ollama_model_metadata_v1` (they were `localOnlyKeys` → `platformOnly`, and both really are
  `SharedPreferences` keys, which the export test catches); then four with no counterpart at all
  (`native_compression_v1`, `compression_defaults_v1`, `compress_new_conversation` → synced with the
  compression family; `display_use_legacy_code_block_style_v1`, `tts_playback_speed_v1` → backupOnly),
  and `attachment_retention_days` in the retention windows. Two pinned lists moved with them: "the
  synced face is pinned" gained three keys, and the writer scan's pinned *unresolved* list lost one.
- **The writer scan is not the whole guard**, and the last two rows prove it: it resolves a literal, a
  `Class.const` and a one-hop getter, but a key passed through a map (`setMany({...})` for the backup
  password state) is invisible to it. The `setMany` debug assert is what found those, through 14
  backup-encryption and backup-page cases. A row added for a *runtime* assert still needs its
  classification argued, so it is not a mechanical follow-up.
- **The writer scan was blind to a modified class header.** `AttachmentRetention` is declared
  `abstract final class`, so `^class\s+(\w+)` could not attribute `preferenceKey` to it and the write
  landed in the pinned unresolved list instead of being checked. The pattern now accepts the modifiers;
  the entry resolved and the key got its row.

### 11.2 What unit 4 leaves for unit 5

Everything §10.2 lists still stands, with the three amendments recorded there. Two more:

- `BusinessEntityKind.groupChat` does not exist until unit 11, so the table's companion row for it
  (`chat_owner_order_v1`) is absent here. Unit 11 adds the kind and the row together — the registry test
  asserts one companion row per kind.
- `syncDeleteEntity` keeps unit 3's signature and stages nothing; only `_deleteEntity` stages, for a
  local delete.

## 12. Unit 5's source: the bin's other half was in the bin's commit

The plan expected unit 5 to be assembled from `237c9a097` (the old line's replay-repair landing),
because that is the commit where the recycle bin's sync integration is *visible* in the 4.6 history's
shape. It is not where it *was written*: `git log -S` on each of the five product hunks and on
`kSyncProtocolVersion = 8` named one commit, and it is `1a04207ff` — the same commit that carried the
bin. The old line shipped the bin and its sync face together; only this series' ordering separates them.

That made the unit cheap to derive, and it is the mirror image of runbook rule 20: rather than replay a
broken intermediate, ask **which commits touched the file after the commit you are deriving from**.

    git log --oneline 1a04207ff..backup/series-4.6-4a7da9b6f -- lib/core/services/sync/

The answer was `bb079ed2d` alone — the policy table, already folded into unit 4. So for every file in
`lib/core/services/sync/`, the 4.6 tip is *exactly* unit 4 + unit 5, and the file can be taken whole. No
three-way merge, no hunk reading. The files outside that directory needed the query run per file, and it
paid twice:

- `business_repository.dart` was touched afterwards by `237c9a097` **and** `5136e617b` (group-chat), so
  it was hand-merged: four hunks are unit 5's, and the fifth (`deleteEntity`'s `group:` parameter, whose
  doc says "a group chat taking its row and its conversations with it") is unit 11's and was left out.
- `business_preferences.dart` was the trap. Its tip version is **older** than this branch's: the old
  line never had upstream's `c66ade4a8` (the `close()`/`_closed` guard that lets the desktop exit path
  drain and close the database) or its `getDouble` cast. Taking the tip's file — the rule the rest of
  the unit followed — would have deleted a baseline repair. Its only unit-5 content is a `reload()`
  that unit 3 already landed, so the file is untouched here.

Two things the unit changed in the plan rather than in code:

- **`#1084` is not in this series.** §3 said unit 5 carries "the skill-body lifecycle"; `b091ffa2a` is
  not an ancestor of the 4.6 tip, so the skill-body refactor is later work and 4.6 ships the directory
  sync unit 4 brought. The §3 row is corrected above.
- **`syncApplyPeerDeletion`'s `origin: remote` is in `chat_database_repository.dart`, not in the
  recycle commit.** §10.2 said "the recycle commit's staging hunks"; the delete hook landed in
  `237c9a097`, one line plus an import, and is here.

The lesson for the next re-base is worth stating separately, so it becomes runbook rule 22: **a unit's
file set is derivable from commit archaeology, and the recipe is the `..` range on the path.** It
converts "which of these twenty commits do I take?" into one command per file, and it is the only cheap
way to tell "the tip's file is my unit plus what I already have" from "the tip's file is my unit plus
three units I have not replayed".

## 13. Unit 6: the fold that git said it applied

`c89e433b3` (`#1064`, the backgrounded letter) folds into the care unit. Its cherry-pick reported
`Auto-merging` for eleven files and a conflict for two, and the result was wrong in a way nothing in the
output hinted at: **two files came out byte-identical to the care commit's own version, with the fold's
changes simply absent** — `lib/core/services/proactive_care_alarm_service.dart` (the whole
`assistantStoreLoaded` guard, the plan/omit split, `_omittedSummary`) and
`lib/core/services/proactive_care_conversation_policy.dart` (`plan`, `ProactiveCareScheduleOmission`,
`ProactiveCareSchedulePlan`).

This is rule 21's class again, but the mechanism is new, and it is the *fold*, not the source commit:
the first `cherry-pick --no-commit` leaves its result in the index, and the second one's three-way merge
then sees a "ours" that never existed when its patch was written. Three of the second commit's hunks
vanished; nothing failed. The tell was not in git's output but in `dart analyze` — two call sites
passing a parameter that did not exist.

The repair is rule 22's: take the tip's file, after the range query says the only commits after the base
that touched it are this fold and the 4.5 close-out's fixes. But the *lesson* is a fold procedure:

- After a `--no-commit` fold, **diff every file the folded commit touches against that commit's own
  version** (`git diff <fold> -- <paths>`), not against the base. An empty diff is the only proof the
  fold is in. That is one command and it would have caught this immediately.
- Where the diff is not empty, the choice is per file, not per commit: here the care files took the
  tip's version whole, while `mobile_background.dart`, `BackgroundRuntime.kt` and their test kept this
  branch's version — the tip's has unit 7's link work in it, and the care hunks in ours had applied.
- `AssistantProvider.isLoaded` is the one *product* addition the unit needed: upstream's newer provider
  kept the load state private, and the care code's contract ("do not re-arm from a half-loaded store")
  asks for it. `main.dart` has to wire `proactiveCareAssistantStoreLoaded` as well — the guard compiles
  and does nothing without it.

Runbook rule 23 carries the fold procedure.

## 14. Unit 8: the unit that does not compile, and the rule it duplicated

Two mechanics worth carrying forward, both new in kind.

**The unit's own repairs live in later commits, and they are not features.** `d593bfdd4` calls
`markdownParserOptionsFor`, `kelivoInlineSyntaxes`, `markdownImageSizeOf`, `exportChatMessagesPdf` and
`HomePageController.exportSelectedAsPdf`; the old line added every one of them in `2184720ca`,
`b264ef05a` or `237c9a97` — the 4.5 landing, the 4.5 fixes and the replay repair. Rule 22's range query
answers "is the tip still my unit?" per file, and here it said yes for the three *new* files (their only
later commits are those repair commits), so they came across whole. For the two shared files the answer
was no in a way the query cannot see: `kelivo_markdown_extensions.dart` and `link_image_handlers.dart`
are **older at the tip** in their widget-facing parts (the tip lacks `chatProseDirection` and
`imageStorage`), so the unit's three helpers were added to this branch's files instead. A file can be
newer and older at once; only the diff says which half.

**A unit can bring a second implementation of a rule the baseline already has.** The unit added
`features/chat/utils/citation_index.dart` — a 77-line copy of `citation_syntax.dart`'s
`citationSearchItems`, `citationIndexLookup` and `resolveCitationIndex`, with the last one's arguments
swapped. On the old line there was one of each; on this baseline the unit's copy would have made two
`resolveCitationIndex` definitions, and `chat_message_widget.dart` imports both files. The collapse was
the only resolution that leaves one choke point: the module is deleted, its callers use the baseline's
three functions, and the unit's test file survives as the first coverage that rule ever had. Its
"newest first" case also had to flip, because the baseline's function is handed `parts.reversed`.

Runbook rule 24 is the general form.

## 15. Unit 9: when the unit is older than the baseline

Every previous unit was the baseline's junior or its senior in a uniform way, which is why rules 21 and
22 worked: "the tip is still my unit" or "my side is newer". This one is both, in different places, and
the split is per *file part*:

- **Older**: the fork's `desktop_translate_page.dart` renders the destination as a read-only
  `TextField`; this baseline had replaced it with `TranslationOutput` (markstream, so streaming math
  renders in the target pane). Taking the unit's page made the desktop variant of
  `translate_page_test` fail with `Bad state: Too many elements` — `find.byType(TextField)` matched two
  fields where the test enters into one. The baseline's tree stays; the unit's *rule* was applied to it.
- **Newer**: the unit's `language_select_sheet.dart` (692 lines against this branch's 323) adds the
  manager, the clear sentinel, and five catalog entries; and its desktop dropdown is a two-column
  rewrite of the shared widget.
- **Corrupt either way**: `desktop_select_dropdown.dart` came out of the merge with its members at top
  level — rule 21's brace imbalance again, in a file that is 692 lines on this branch and 747 at the
  tip, while the merge produced 1110. Taken whole from the tip with its test, which the 4.5 landing had
  already reconciled with the rewrite.

The method note: **a file whose merge result is longer than either side is corrupt**, and the fix is the
tip (rule 22), not a hand-merge. The other note: when only part of a file is older, the unit's *rule* is
the thing to transplant — `effectiveTranslateLanguage` here — not its widget tree.

One deferred dependency closed: `translate_language_catalog_test.dart` is unit 4's deferral, and its
tip version carries `#1068`'s edit, so this unit adds the edited file rather than the unit's own.

## 16. Unit 10: the unit's own test was red against the unit's own code

Every previous unit was repaired because its tree would not compile or because a rule had been
duplicated. This one is repaired by its own tests, and the two halves are worth separating.

**The analyzer half is rule 21 again, with a new source.** The unit's test file calls
`HomeViewModel.visibleChatSuggestions` and `debugMaybeGenerateSuggestionsFor`, and the unit adds
neither; `dart analyze` on the whole tree names both. They were added by `237c9a097` — the replay-repair
commit unit 8 already knew as the source of its export helpers — which also tightened `isCurrent` to
resolve the assistant again. A repair commit is not one unit's property, and the range query of rule 22
is what shows the sharing rather than making it look like a coincidence.

**The test half is new in kind.** With the three symbols transplanted, `dart analyze` was clean and
twenty of twenty-one cases passed. The twenty-first, "an opt-out while the request is in flight
discards the reply", failed: the reply landed. The unit's `isCurrent` compares the `Assistant`
snapshot taken before the async gap, so an opt-out that arrives later is invisible to it, and the
unit's commit body — "re-reads it inside `isCurrent`, so an opt-out that lands mid-flight drops the
response" — describes code the commit does not contain. The tip re-resolves the assistant from
`convo.assistantId` inside `isCurrent`, and that is the version taken.

The method note: **run the unit's tests even when the analyzer is clean, and when one is red, ask
whether a later commit changed the same expression before touching the test.** The test is the only
artefact in the unit that says what the feature was supposed to do; the code around it is the part the
old line changed afterwards.

Two smaller notes. The changelogs conflicted for a reason worth knowing: the source commit's own
changelog hunk is a *deletion*, produced by a nested `<<<<<<<` in the old line's history — documents
are carried complete in unit 1, so both files take ours. And one adaptation, not a repair: this
baseline flow-promotes `conversationId` at that point in `home_page.dart`, so the unit's
`chat.getConversation(conversationId!)` was asserting what the analyzer already knew (the tip has the
same line without the `!`).

One thing deliberately *not* taken: the tip's `if (convo.isGroupConversation) return;` at the head of
the suggestion pass. The tip has it because group-chat followed this unit; it belongs to unit 11, and
its absence is what unit 11 has to check when it arrives.

## 17. Unit 11: the repair commit as a per-unit dependency

This unit is four commits folded into one, 141 files, and it drew on `237c9a097` more than any other:
six of the things it needs only ever landed there. That is now a pattern rather than a surprise, and
the preflight is cheap — `git log --oneline <unit>..<tip> -- <the unit's paths>`, then read that
commit's message, which enumerates what it restored.

**The forward references, in the order the analyzer found them:**

- `ChatMessage.senderId` — the model field itself, with its five plumbing points (`toJson`,
  `fromJson`, `copyWith`, constructor). The database column and its migration were in the unit.
- The repository's read and edit paths: `senderId: row.senderId` on the way out and
  `senderId: original.senderId` when an edit creates a version. Without the second, an edited member
  reply loses its author; three `group_chat_schema_test` cases say so.
- `ChatService.beginUserMessage` — the repository counterpart (`_repo.beginUserMessage`, with a doc
  comment naming the group case) was in the tree; the service wrapper was not. Added with the
  sibling's serialisation and cache updates.
- `senderId` parameters on `beginRegeneration`, `beginAssistantGeneration` and `addMessage`, plus the
  `_GatedChatService` fake in `chat_send_race_test.dart` that overrides the last one.

**A baseline rework can make the unit's *test* wrong while its code merges.** Two cases:

- The compression speaker labeller. The unit's test asserts `labelOf` and the bounded/chunked builders
  the fork's line had; this baseline's builder went with upstream's compaction rework and has neither.
  The invariant is "a group's summary keeps the voices apart", so the speaker now rides in the line's
  existing source-message prefix (`Assistant[alice]: …`) and the test was rewritten to that — one
  production line, no new API.
- The tablet skills test. Folding `#1072` changed the compact toolbar's overflow from a second "+"
  (`chatInputBarMoreTooltip`) to an ellipsis (`chatInputBarOverflowTooltip`); this branch's copy of
  the test still tapped the "+", so it taps the ellipsis now. That is the folded unit's own change
  reaching its own test, not a weakening.

**The fourth helper collapse.** `lastHumanUserIndex` (a peer's turn) and this baseline's
`lastUserInputIndex` (injected lore) are orthogonal halves of "the user's own turn", and every provider
would have had to pick one and lose the other. The peer exclusion went into `isUserInputMessage`, the
helper was deleted, and the unit's `message_authorship_test.dart` — the first coverage that predicate
ever had — now asserts both conditions. Rule 24's shape, one layer deeper: not two functions with one
name, but two functions answering one question.

**Two additions the unit needed and did not carry.** `showConversationSkillsSheet` had no `members`, so
home_page's group branch would have compiled and written the conversation's shared override for every
member — §8.1's predicted silent loss; it gains the strip and `scopeToAssistant`. And
`BusinessKeyRegistry.companionKeys` had no row for `BusinessEntityKind.groupChat`; the registry test is
what says a kind and its companion arrive together (`chat_owner_order_v1`).

**Smaller adaptations worth knowing.** The desktop reasoning popover was rewritten upstream into an
80-line `showGeneralDialog` page, so the group popover is a new panel on that page rather than a replay
of the fork's `_ReasoningContent`/`_HoverRow` pair. `builtInSearchOnly` is upstream's
`BuiltInToolMode.none`. `assistants_pane.dart` is a `part of` file, so its six group imports belong to
`desktop_settings_page.dart` — the merge dropped exactly those and the analyzer blames the part.

And one debt from unit 10 closes here: the suggestion pass now begins with
`if (convo.isGroupConversation) return;`, which is what the tip had and unit 10 deliberately left out.

## 18. Unit 12: the hunk a reorganized page moved, and the rule the carry already held

Two mechanics, both about *location* rather than content.

**A merge can place a hunk where the other side reorganized the page.** The mobile backup page was
substantially reorganized at this baseline: the unit's backup-management card (scope tile, then the
new target tile, then the encryption tile) sits where this branch now has the WebDAV section. Git
resolved the conflict by putting the unit's card *inside* the WebDAV list — a merge that compiles
nowhere near where the feature belongs, and that would have put the target picker above "test
connection". The fix is the file's own structure: find the symbol the unit inserts *next to*
(`BackupScopeTile`), and put the tile there. The general shape: when a conflict's two sides look like
different pages, the unit's block belongs beside the same neighbour in ours, not at the conflict's
offset.

**A rewritten tile keeps this branch's shape.** `BackupEncryptionTile` now takes `busy`, not
`enabled`/`onChanged`, so the insertion above it was ported onto this branch's call rather than
replayed with the unit's.

And one duplication the carry makes: the unit's commit adds runbook rule 17, but the runbook was
carried complete in unit 1 and already holds it (plus later rules that reference it). Documents take
ours, and the unit's copy is a duplicate of a row the table already has — rule 24 applied to a
document instead of a module.

A note about this unit's source: its own message carries a `# Conflicts:` line for
`backup_portability.dart`, i.e. the commit is itself a merge resolution. Rule 21's warning applies in
weaker form: its diff can be internally consistent only for the merged files, so read the resulting
file's logic rather than the patch when something looks off.
