# Re-base runbook

Companion to [ADR-0004](adr/0004-follow-upstream-rebase.md): the decision is to re-base on the
latest Kelivo **stable** and *re-do* Cuplivo's features on it, never to port the fork forward.
This file records the mechanics of that replay, so the next re-base is a replay and not a porting
project. It was rewritten by the 4.1 → upstream `df60f7425` re-base; the numbers below are that
re-base's, and the *rules* are what to carry forward.

## The replay units, in order

Each line is one cherry-pick unit, replayed onto the new baseline. Order matters only where units
share files: the image series (`chat_input_bar.dart`, `home_page_controller.dart`) and the composer
units touch the same regions, so the crop unit goes last.

| # | Unit | Notes |
| --- | --- | --- |
| 1 | `feat!: Cuplivo identity on the Kelivo baseline` | the re-brand **plus** the "clear the format, analyze and test gates" work — the gates are red on a fresh baseline, so both belong to the same unit. Mechanical: renames, application id, platform identity, removal of the built-in `kelivo` search service. **Over a thousand files**; see the identity rules below |
| 2 | `fix(android): bundle the current proot tooling and fix the fetchProot 404` | `tool/fetch_proot.sh`, `tool/proot_checksums.txt`, `android/app/src/main/jniLibs/NOTICE`. Build tooling on purpose kept out of the feature units |
| 3 | `feat(image): manual compression editor with explicit format control and bounded working memory` | ADR-0002 + ADR-0005 |
| 4 | `feat(sync): LAN sync, the dual stack, candidate probing and a panel that tells the truth` | ADR-0003 |
| 5 | `feat(care): 「Ta的来信」跨平台回归，助手设置新增「角色扮演」页签` | proactive care: the port, the audit fix split out of it, and the desktop entry points |
| 6 | `feat(image): crop the unsent image in its preview` | depends on 3 (the compression pipeline and its deferred crop step) and 5 (the composer it edits) |

Two units from the previous series are **gone, and must not come back**:

- **The composer-draft unit (`#930`) is discarded.** Upstream now ships its own per-conversation
  draft (`lib/core/database/composer_draft_store.dart`, `lib/core/models/composer_draft.dart`), so
  re-replaying ours would fight it. Before assuming a unit is still needed, check whether upstream
  grew the same capability — a discarded unit leaves dead l10n keys behind, not dead code.
- **There is no release unit.** A re-base is not a release: no version bump, no new tag, no
  changelog section, no release dispatch. `pubspec.yaml` keeps the version line the old tip had
  (`4.1.0+4` for this one) while taking upstream's dependency changes, so the published tag still
  describes the tree. Re-tagging and re-dispatching is a separate, deliberate act (AGENTS.md →
  Releases).

## Rules

1. **Replay features, not the fork's tree.** `git cherry-pick -n <unit>` onto the new baseline and
   resolve; do not merge master into the fork. Commit with `git commit -C <unit>` so the unit's
   message and its "why" survive.
2. **`lib/l10n/` is regenerated, never merged.** Every unit touches the ARB files and the generated
   `app_localizations*.dart`, so they conflict everywhere. In practice the resolution is *take ours*:
   the identity unit builds the new ARB out of the fork's, so the fork's keys are already present and
   the unit's own keys are a subset. **Verify that before trusting it** — a dict-level diff of
   `(unit ∪ base)` against our ARB per locale must report zero missing keys and zero differing
   values. Then `flutter gen-l10n`. Never hand-splice ARB: merge at dict level and validate with
   `json.loads` before writing, or you will ship truncated `@key` metadata.
3. **The identity unit must sweep upstream's new files.** A cherry-pick only merges *conflicting*
   files. Files upstream added after our old baseline keep upstream's own `package:Kelivo/` imports
   and branding because they never conflicted. Enumerate `upstream-only` files (`git diff --name-only
   --diff-filter=A <old-baseline> <new-baseline>`) and run the rename set over them. Then grep the
   whole tree for `Kelivo` / `kelivo` and classify every surviving hit against the whitelist
   (`kelivo://workspace|chat|session|skills|tmp|mounts`, `kelivo-file://`, `KelivoOpenURL`,
   `KelivoFileUri`, `KelivoISH*`, `KelivoApplication`, `KelivoPtyJni`, `kelivo_*` tool ids,
   `kelivo.db`, `kelivo_backups`, `kelivo.psycheas.top` / `search.psycheas.top`,
   `afdian.com/a/kelivo`, and the intentional `Chevey339/kelivo` attribution in README / CONTEXT /
   `.github`).
4. **A token grep misses the disguised forms.** `[Kk]elivo` inside a regex (`xdotool search --class`)
   contains neither the literal `Kelivo` nor `kelivo`, so a rename pass and a leftover grep both walk
   past it. Grep for bracketed and escaped spellings too, and re-check any file that *inspects*
   identity rather than stating it.
5. **Verify by gate, not by tree equality.** A pure-substitution self-test is invalid: the identity
   unit also rewrote whole documents and carried gate fixes, so only ~75% of files can ever match a
   substitution — and a *clean* merge can still carry upstream's branding. The useful signal is the
   classification (branding-only vs semantic). Close every unit with
   `dart analyze --fatal-infos lib test integration_test`, and run the unit's own tests before moving
   on, because a semantic conflict (a restructured function that merged silently) is exactly what the
   analyzer and those tests exist to catch.
6. **Upstream's own new APIs beat our old intent.** When a unit conflicts with a rewrite of the same
   region, take upstream's structure and re-apply our *meaning* on top: e.g. the MCP retry now runs
   inside an OAuth-progress `session.wait(...)`, and the message-fields UPDATE now carries upstream's
   new token-extras parameters, while our clock-floor fix and our `await` stay. Re-deriving our
   version verbatim would silently revert upstream's fix.

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
   rule 4 against them: the AppImage window-class probe is where the disguised form lives.
4. Bump `FLUTTER_VERSION` in `pr-check.yml` to the same version, and update AGENTS.md's
   "currently <version> -> Dart <version>" wording.
5. Delete the other build workflows. Do not re-add per-Flutter-version copies.

## Procedure

```bash
git switch -c rebase/kelivo-<new-baseline> upstream/master

# per unit, in the order above
git cherry-pick -n <sha-of-the-unit-in-the-fork>
#   resolve; l10n -> take ours + `flutter gen-l10n` (verify first, rule 2)
#   identity -> sweep upstream-only files and grep for leftovers (rules 3-4)
dart analyze --fatal-infos lib test integration_test
flutter test <the unit's own test files>
git add -A && git commit -C <sha-of-the-unit-in-the-fork>

# carry-overs that are not feature units, in one commit
git checkout master -- README.md README_ZH_CN.md CHANGELOG.md CHANGELOG_CN.md docs/rebase-runbook.md
#   pubspec.yaml: take upstream's dependencies, keep the old `version:` line
#   then the CI collapse above

# verification, then land
flutter test                                   # expect only the registered known failures
git branch -f master rebase/kelivo-<new-baseline>
#   no tag, no version bump; the old tags stay on the backup branches
```

## What this line learned (keep — it is the point of the runbook)

- **`git checkout --ours` during a cherry-pick means the branch you are on**, i.e. upstream's side —
  not "our fork". Resolving the identity unit that way is how our own Windows portability fixes were
  briefly lost and had to be re-applied by hand. Say "ours = upstream" out loud before using it.
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
