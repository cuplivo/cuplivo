# Re-base runbook

Companion to [ADR-0004](adr/0004-follow-upstream-rebase.md): the decision is to re-base on the
latest Kelivo **stable** and *re-do* Cuplivo's features on it, never to port the fork forward.
This file records the mechanics of that replay, so the next re-base is a replay and not a porting
project.

Two re-bases have been run: 4.0 → `df60f7425` and 4.1 → `3c92d1062`. The numbers below are the
second one's; the *rules* are what to carry forward.

## The replay units, in order

Each line is one unit, replayed onto the new baseline. Order matters only where units share files:
the image series (`chat_input_bar.dart`, `home_page_controller.dart`) and the composer units touch
the same regions, so the crop unit goes last.

| # | Unit | Notes |
| --- | --- | --- |
| 1 | `feat!: Cuplivo identity on the Kelivo baseline` | the re-brand, the sweep for files upstream added since the old baseline, **and** the "clear the analyze gate" work — the gates are red on a fresh baseline, so all of it belongs to the same unit. Mechanical: renames, application id, platform identity, removal of the built-in `kelivo` search service. **Over a thousand files**; see the identity rules below |
| 2 | `fix(android): bundle the current proot tooling and fix the fetchProot 404` | `tool/fetch_proot.sh`, `tool/proot_checksums.txt`, `android/app/src/main/jniLibs/NOTICE`. Build tooling on purpose kept out of the feature units |
| 3 | `feat(image): manual compression editor with explicit format control and bounded working memory` | ADR-0002 + ADR-0005 |
| 4 | `feat(sync): LAN sync, the dual stack, candidate probing and a panel that tells the truth` | ADR-0003 |
| 5 | `feat(care): 「Ta的来信」跨平台回归，助手设置新增「角色扮演」页签` | proactive care: the port, the audit fix split out of it, and the desktop entry points |
| 6 | `feat(image): crop the unsent image in its preview` | depends on 3 (the compression pipeline and its deferred crop step) and 5 (the composer it edits) |

After the feature units come the non-feature tail, normally one commit each: the carry of Cuplivo's
content files (README / CONTRIBUTING / CHANGELOG / this file) **plus** the CI collapse, the l10n
cleanup of messages the new baseline retired, and the rewrite of this runbook. The mechanical
reformat is re-derived last (rule 10).

Units from earlier series that are **gone, and must not come back**:

- **The composer-draft unit (`#930`) is discarded.** Upstream now ships its own per-conversation
  draft (`lib/core/database/composer_draft_store.dart`, `lib/core/models/composer_draft.dart`), so
  re-replaying ours would fight it. Before assuming a unit is still needed, check whether upstream
  grew the same capability — a discarded unit leaves dead l10n keys behind, not dead code.
- **The `await` gate fix is discarded as of this re-base** — upstream made the same four fixes
  itself. See rule 7; this is the case that rule exists for.
- **There is no release unit.** A re-base is not a release: no version bump, no new tag, no
  changelog section, no release dispatch. `pubspec.yaml` keeps the version line the old tip had
  (`4.1.0+4` for this one) while taking upstream's dependency changes, so the published tag still
  describes the tree. Re-tagging and re-dispatching is a separate, deliberate act (AGENTS.md →
  Releases).

## Rules

1. **Replay features, not the fork's tree.** Cut a scratch branch at the last unit before the
   reformat commit and replay onto the new baseline with
   `git rebase --onto <new-baseline> <old-baseline> <scratch>`; never merge master into the fork.
   Read the *real* conflicts rather than predicting them: on this re-base the diffstat (+8626/−4388,
   125 files) suggested heavy collisions and the actual count was 9 + 1 + 2 conflicting files across
   three units.
2. **`lib/l10n/` is regenerated, never merged.** Every unit touches the ARB files and the generated
   `app_localizations*.dart`, so they conflict everywhere. In practice the resolution is *take ours*:
   the identity unit builds the new ARB out of the fork's, so the fork's keys are already present and
   the unit's own keys are a subset. **Verify that before trusting it** — a dict-level diff of
   `(unit ∪ base)` against our ARB per locale must report zero missing keys and zero differing
   values. Then `flutter gen-l10n` and prove it idempotent (`git status --short -- lib/l10n` empty).
   Never hand-splice ARB: merge at dict level and validate with `json.loads` before writing, or you
   will ship truncated `@key` metadata. `app_zh_Hans` deliberately carries 24 fewer messages than the
   other three locales — that gap is pre-existing, so diff the gap against the old tip before
   treating it as a regression.
3. **The identity unit must sweep upstream's new files, and the sweep belongs in that unit.** A
   cherry-pick only merges *conflicting* files, so files upstream added after our old baseline keep
   upstream's own `package:Kelivo/` imports and branding because they never conflicted. Enumerate
   `git diff --name-only --diff-filter=A <old-baseline> <new-baseline>` and run the rename set over
   them. Fold the result into the identity commit rather than leaving a trailing sweep commit: a unit
   has to be self-consistent, and with the sweep left out the identity commit's own tree imports a
   package name that no longer exists.
4. **Only sweep tokens upstream's new code *introduced*.** The tree is fully swept at the old tip, so
   the exact work is the set difference: for every file upstream touched, compare its brand-matching
   lines at the old tip against the current tree and take what is new. Classify every survivor against
   the whitelist (`kelivo://workspace|chat|session|skills|tmp|mounts`, `kelivo-file://`,
   `KelivoOpenURL`, `KelivoFileUri`, `KelivoISH*`, `KelivoApplication`, `KelivoPtyJni`, `kelivo_*` tool
   ids, `kelivo.db`, `kelivo_backups`, `kelivo.restore-*`, `.kelivo_restore`,
   `kelivo.psycheas.top` / `search.psycheas.top`, `afdian.com/a/kelivo`, `KELIVO_PERF_SCENE`,
   `PackageInfo` mock `appName:`/`packageName:` values, temp-dir prefixes, and the intentional
   `Chevey339/kelivo` attribution in README / CONTEXT / `.github`). On this re-base that reduced 65
   surviving brand lines in 10 files to 9 files' worth of import fixes.
5. **A token grep misses the disguised forms.** `[Kk]elivo` inside a regex (`xdotool search --class`)
   contains neither the literal `Kelivo` nor `kelivo`, so a rename pass and a leftover grep both walk
   past it. Grep for bracketed and escaped spellings too, and re-check any file that *inspects*
   identity rather than stating it.
6. **Verify by gate, not by tree equality.** A pure-substitution self-test is invalid: the identity
   unit also rewrote whole documents and carried gate fixes, so only ~75% of files can ever match a
   substitution — and a *clean* merge can still carry upstream's branding. The useful signal is the
   classification (branding-only vs semantic). Close every unit with
   `dart analyze --fatal-infos lib test integration_test`, and run the unit's own tests before moving
   on, because a semantic conflict (a restructured function that merged silently) is exactly what the
   analyzer and those tests exist to catch.
7. **Ask whether upstream already made this change before replaying the unit.** A unit can be fully
   absorbed: the `await` gate fix touched three files, and upstream's 9 commits had fixed all four
   sites themselves — two of them byte-identically. Compare your delta against upstream's before
   resolving anything; when upstream absorbed the unit, **discard it** rather than re-applying it.
   Keep only a genuinely *additional* fix, and only if it is also the better one.
8. **Two implementations of one defect: take upstream's and delete ours.** Our identity unit carried a
   61-line `http_header_map.dart` plus its test to make OAuth header replacement case-insensitive;
   upstream fixed the same defect inline in the same commit series. Keeping both leaves two mechanisms
   for one behaviour. Delete the helper, its test and every call site — and before deleting, prove the
   surviving call sites are real: the helper's stated premise was a `LinkedHashMap` crash that a
   three-case probe could not reproduce against the pinned SDK.
9. **Upstream can retire a mechanism your side's context still carries.** A conflict hands you the
   *old* symbols along with your own additions: our sync unit's hunk still contained
   `idleCacheBackfillSlotLimit` and `_scheduleIdleCacheBackfill`, which upstream had removed outright
   in favour of windowed loading. Resolve by taking upstream's structure and keeping only your genuine
   delta, then grep the whole tree for the retired symbols to prove nothing dangles.
10. **The reformat commit is re-derived, never replayed.** Upstream reformats its own tree, so a
    replayed formatter pass conflicts with the reformat it now sits on. Drop it and run the formatter
    again on the rebased tree: conflict-free by construction, and the resulting commit touches only
    files Cuplivo itself changes. This is also why the identity unit does *not* carry the gate-clearing
    reformat.
11. **Never hand-resolve a conflict block without reading what sits outside the markers.** Removing
    the `<<<<<<<`/`=======`/`>>>>>>>` lines by hand silently drops the lines the conflict *didn't*
    cover: upstream's `result.headers.addAll(authHeaders)` lived between two conflict blocks and would
    have vanished. When your side's delta on a file was only the conflicting hunk,
    `git checkout HEAD -- <file>` is exact and safe — verify that by reading your unit's full diff for
    that file first. Afterwards, re-read the whole function rather than just the resolved region.
12. **`git checkout --ours` during a cherry-pick means the branch you are on**, i.e. upstream's side —
    not "our fork". Resolving the identity unit that way is how our own Windows portability fixes were
    briefly lost and had to be re-applied by hand. Say "ours = upstream" out loud before using it.

## The CI rule

`.github/workflows/release.yml` is the only build workflow. Upstream publishes one workflow per
Flutter stable line (`build-stable-<minor>.yml`); we do not keep them all. Derive ours from the
newest one at re-base time:

1. Copy upstream's `build-stable-<minor>.yml` to `release.yml`.
2. Rename the identity: `Kelivo` → `Cuplivo`, `kelivo` → `cuplivo` (this covers artifact names,
   the macOS `.app`, the Windows `.exe` and installer, and the DEB/RPM package and desktop entries),
   then set the Windows `MyAppPublisher`, the installer `AppId` (ours is
   `B924949D-FD7C-4688-B812-4ED64BFAACDC` — it must not collide with upstream's) and the RPM
   changelog author.
3. Update `tool/build_appimage.sh` / `tool/test_appimage.sh` with the same two renames, then re-check
   rule 5 against them: the AppImage window-class probe is where the disguised form lives.
4. Bump `FLUTTER_VERSION` in `pr-check.yml` to the same version, and update AGENTS.md's
   "currently <version> -> Dart <version>" wording.
5. Delete the other build workflows. Do not re-add per-Flutter-version copies.

## Procedure

```bash
# a scratch branch, so master is untouched until the line is verified
git branch --force rebase/onto-<new-baseline> <old-master>~1   # drop the mechanical reformat
git rebase --onto <new-baseline> <old-baseline> rebase/onto-<new-baseline>

# per conflict, in order
#   ask first whether upstream already did this (rule 7) and whether our side still needs it (rule 9)
#   l10n        -> take ours + `flutter gen-l10n` (verify first, rule 2)
#   imports     -> upstream's list, Cuplivo-prefixed
#   identity    -> sweep upstream's new files and grep for leftovers (rules 3-5)
dart analyze --fatal-infos lib test integration_test

# identity sweep, folded into unit 1
git commit --fixup=<identity-sha> && git rebase -i --autosquash <new-baseline>

# the mechanical reformat, re-derived last (rule 10)
dart format lib test integration_test

# gates, in this order
flutter gen-l10n && git status --short -- lib/l10n      # must be empty
dart analyze --fatal-infos lib test integration_test
dart format --output=none --set-exit-if-changed lib test integration_test
flutter test                                            # only the registered known failures

# land
git branch -f master rebase/onto-<new-baseline>
#   no tag, no version bump; the old tags stay on the backup branches
```

## What this line learned (keep — it is the point of the runbook)

- **A unit that straddles two features cannot be reordered freely.** The crop unit edits files the
  composer units also edit, so it replays after them. Splitting it to make the image series
  contiguous costs more than it buys.
- **A follow-up on a feature already in the series belongs in that feature's unit.** Check the
  overlap before deciding; a follow-up that touches only that feature's files folds in for free.
- **Build tooling and release chores stay out of feature units**, or every cherry-pick drags them
  along.
- **Some units were authored against APIs that no longer exist.** The care unit asked for a global
  `thinkingBudget` on `ChatApiService.generateMessage`; the new baseline retired that key in favour
  of per-request `ReasoningRequest`. The fix is to port the unit's *intent* onto the new API (the
  care flow now calls `selectReasoningRequest`, the same chain the file already documented for model
  resolution) — not to reinstate the retired parameter or the retired preference key.
- **Registering a test failure as "known" needs a control run.** Nine Windows failures looked like
  our regression; running the same files in a clean worktree at upstream's own tip reproduced them
  (ten, in fact). Only after that is a failure honestly "upstream's, on this platform".
- **Adopting an upstream correction is not the same as taking upstream's file.** Upstream moved the
  macOS deployment target from 11.0 to 12.0 and bumped its Flutter requirement; our README carries the
  fork's own download table, so "take ours" would have kept a now-false system requirement. Resolve
  the table from ours and the *facts* from upstream — the deployment target is verifiable in
  `macos/Podfile` and the `MACOSX_DEPLOYMENT_TARGET` settings.
- **Git writes inside the DSH sandbox fail for an environment reason, not a repository one.** The
  confined subprocess runs at *low* mandatory integrity level while `.git` and other pre-existing
  directories are unlabelled (medium), and Windows refuses that write regardless of the DACL — the
  directory can grant the caller `FullControl` and the write still fails. Escalate git writes (or use
  the bridge for `flutter`/`dart`) instead of repairing permissions; see AGENTS.md.
