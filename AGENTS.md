# AFENTS.md

## Project overview

Cuplivo is a cross-platform LLM chat client built with Flutter, targeting iOS, Android, macOS, Windows, and Linux. Package name is `Cuplivo` — imports use `package:Cuplivo/...`. It is a community fork of Kelivo, re-baselined on Kelivo upstream `master` at `b1702b3a9` (2026-10-26); upstream's newest published tag is still `v1.3.1` and older than the 4.3, 4.4 and current baselines, so master is the live line. From 4.0 on, every version re-bases on that upstream line and re-does Cuplivo's own features as cherry-picks on it.

## Architecture

- **Feature-based structure**: `lib/features/<feature>/` with `pages/`, `widgets/`, `models/`, `utils/` subdirectories.
- **Desktop / mobile split**: most UI pages have separate desktop and mobile layouts (e.g. `home_desktop_layout.dart` / `home_mobile_layout.dart`). Desktop-only code lives in `lib/desktop/`. Use `ResponsiveHelper` from `lib/shared/responsive/` to branch by screen type.
- **State management**: Provider (`lib/core/providers/`).
- **Database**: Drift (`lib/core/database/`). Schema versions tracked in `drift_schemas/`.
- **Localization**: ARB-based (`lib/l10n/`), English template (`app_en.arb`). Run `flutter gen-l10n` after editing ARB files and commit the generated output exactly as it is written — the generator formats its own files, so never hand-edit or reformat them. CI regenerates and compares (`pr-check.yml`), and a generated file that was reformatted outside the package (e.g. a copy under the system temp directory, where the package's language version does not apply) fails that comparison.

## Pre-commit checklist

Format changed Dart files with `dart format`, including files under `lib/`,
`test/`, `integration_test/`, `dependencies/markstream/lib/`, and
`dependencies/markstream/test/`. For code changes, run static analysis before
committing:

```bash
dart analyze --fatal-infos lib test integration_test
(cd dependencies/markstream && flutter pub get && dart analyze --fatal-infos)
```

For ordinary changes, run only the test files or directories covering the
changed behavior and affected callers, using `flutter test <test paths>`.
If `markstream` is affected, also run its relevant tests from
`dependencies/markstream`; root-package checks do not cover this path package.

Run the full test suites locally only when merging a major feature, such as a
cross-feature integration or broad architectural change:

```bash
flutter test
(cd dependencies/markstream && flutter pub get && flutter test)
```

All required checks must pass. Documentation-only changes do not require Dart
analysis or Flutter tests. CI (`pr-check.yml`) still runs static analysis and
the full test suites for both packages on every PR.

It formats with the Dart SDK bundled in the Flutter version its workflow pins
(`FLUTTER_VERSION`, currently 3.47.6 -> Dart 3.13.0). A newer local SDK lays the same code out
differently, so `dart format` with the local SDK both reformats files CI would leave alone and
leaves files CI wants changed — either way turning the PR check red. Format with that pinned Dart
whenever the local one differs, and confirm with `--output=none --set-exit-if-changed` before
pushing.

`pubspec.lock` is committed — both here and in `dependencies/markstream` — and `pr-check.yml` runs
`flutter pub get --enforce-lockfile`, so CI resolves exactly the set that was tested instead of a
fresh one. That is the baseline's policy as of `199647a5d`; the `e15df5485` replay paid for it, with a
stale local lock pinning `drift 2.34.3` while CI took `2.35.3` (7 deprecation infos in the committed
`app_database.g.dart`, invisible locally) and CI's fresh `sqlite3 3.8.0` breaking the recycle bin's
staging (13 cases). Neither is a `pubspec.yaml` ceiling any more: `199647a5d` pins `drift 2.35.3` and
the lock pins `sqlite3 3.5.2`, so a bump is now a commit that changes the lock, never a silent
resolution. This fork adds packages upstream does not have (`pdf`, `basic_utils`,
`device_info_plus`), so it cannot inherit upstream's lock verbatim: seed ours from the baseline's and
run **one** `flutter pub get` — that kept upstream's pins and added only ours. Check the lock into
the same commit as any `pubspec.yaml` change, or the next CI run fails on `--enforce-lockfile`.

## Releases

- **Version**: `pubspec.yaml` only (`version: X.Y.Z+N`); the release tag is `vX.Y.Z`.
- **Rebases**: master is rewritten whenever the line re-bases on a new Kelivo baseline. Re-create the
  release tag on the new tip and re-dispatch `release.yml` for it, so the published assets match the
  rewritten tree.
- **Changelog**: `CHANGELOG.md` (English) and `CHANGELOG_CN.md` (Chinese) carry the same entries,
  newest first, with keep-a-changelog headings (`Added` / `Changed` / `Removed` / `Fixed`). Update
  both in the version-bump commit.
- **Build**: `.github/workflows/release.yml` is the only build workflow (Flutter 3.47.6;
  `workflow_dispatch` with `publish_release` + `release_tag`; artifacts `Cuplivo_<platform>_*`). It
  is the workflow that uploads to a GitHub Release — do not re-add per-Flutter-version copies.
- **Release body**: the Chinese block first, then the English one, taken from the two changelogs.

## Upstream policy

Cuplivo follows upstream: a new version re-bases the code base on the newest Kelivo line — upstream
`master`, since its last published tag (`v1.3.1`, `4742d2e28`) is older than the 4.3, 4.4 and current
baselines — and re-does Cuplivo's own features on that baseline instead of porting the fork forward.
Never let the fork diverge permanently — the 3.x line ended because hand-syncing every upstream change
became unmaintainable. See `docs/adr/0004-follow-upstream-rebase.md`.

A re-base never carries patches to a package we consume. `dependencies/markstream` is upstream's
code, vendored by path; a defect found there is filed on upstream and waited for, not patched
locally — a local patch is the first thing the next re-base silently drops, and it makes the
package's own gate meaningless. The 4.4 re-base deferred the hand-cursor fix (#1014) this way
(Chevey339/kelivo#1269) and recorded the gap in `docs/markstream-delta-audit.md`. That issue was
closed `NOT_PLANNED` upstream on 2026-10-20 and both defects are still in the vendored package at
`199647a5d`, so the gap is now permanent rather than pending: re-check it per re-base, keep it
documented, and do not patch it locally.

## History normalization (rewrite pass)

Between a release and the next re-base the line collects fix-ups, and a pass folds them into replay
units so the next re-base replays 18 commits instead of 35. The unit table and the procedure live in
`docs/rebase-runbook.md`; what the 4.4 pass added:

- **A follow-up folds into its unit only when the files it crosses are the changelogs, `lib/l10n/`,
  `main.dart` or a document.** Measured: `#1030`+`#1037` into sync crossed only `main.dart`;
  `#1007`+`#1008` into care crossed `home_page_controller.dart`; `#1034` into the link unit crossed
  one test file. Those folds are what removes a conflict round at the next re-base.
- **Do not fold the content carry below the units that write the changelogs.** The carry installs the
  released section every feature unit appends to, so folding it into the identity unit turns one
  document conflict into one per unit. If it is folded anyway, materialise the changelogs from the old
  tip into the last unit that touches them and say so — the per-unit attribution no longer holds for
  those lines.
- **Prove a rewrite with ancestry as well as the tree.** An empty `git diff <old-tip> <new-tip>` is
  necessary, never sufficient: a `commit-tree` that omitted `-p <baseline>` reproduced the same tree
  while cutting every upstream commit out of the line. Always also assert
  `git merge-base --is-ancestor <baseline> <new-tip>`, `git rev-list --count <baseline>..<new-tip>`,
  and that the total commit count moved by exactly the units removed.
- **A fold keeps its folded messages.** `git commit -C <base>` keeps only the base message; assemble
  base subject and body plus every folded body and feed it to `git commit-tree -F`. Those bodies are
  the evidence the next re-base reads.
- **A landing's fix-ups fold by path from the tip, not by replaying their patches.** The `199647a5d`
  landing's 21 tail commits became four — the baseline's own repairs, the lock and release wiring, the
  record, and the reformat at the tip. Each one is
  `git restore --source=<old-tip> --staged --worktree -- <its paths>` on top of the last unit, so the
  tip tree is reproduced byte for byte by construction; the one constraint is that no path may be
  split across two of them, which is why `f75363461` and `724affebc` contribute their document hunks
  to the record and the rest to another commit. This is the cheap direction: a tail that cannot fold
  back into its unit (the unit's own test files are in the way) can still merge with its neighbours,
  and that removes a replay round without moving the conflict surface.
- **The brand rename applies to the incoming side too.** The identity unit renames `Kelivo` → `Cuplivo`
  in ARB *keys and values*. A merge that kept a fork value because it already equalled
  `rename(upstream)` must still write `rename(upstream[k])`; taking the raw upstream value put 53
  `Kelivo` strings back into `lib/l10n/` and turned ten string assertions red while `dart analyze`
  stayed clean and every ARB was still valid JSON. Upstream's pre-rename key
  (`searchServiceNameKelivo`) is dropped, not kept beside the fork's (`searchServiceNameCuplivo`).
  Prove it before pushing: `git grep -c Kelivo master -- lib/l10n/` prints nothing, and the generated
  files are re-derived by `flutter gen-l10n` from the package root.
- **The new baseline's tests are POSIX-only; the Windows run is what finds them.** The 4.4 replay
  surfaced 18 failures that were all in tests upstream never runs on Windows: path assertions
  written with `/` (five files fixed with `p.equals` / `p.normalize`), `window_manager` 0.5.2's
  Windows-only `isFullScreen` probe at the head of `startDragging` (an unanswered channel hands the
  await a null), and a widget test whose 2 s interleave window no longer covered the durable
  empty-database acknowledgement the fork adds to the last deletion. None was a product defect, and
  repairing them belongs to the baseline-repair unit, not to an optional cleanup. The `e15df5485`
  replay added two classes to that set: a `/` literal frozen into a path filter
  (`data_sync_backup_file_test.dart`), and persisted names the identity sweep had rewritten in a test
  fixture (`restore_failure_screen_test.dart` looked for `cuplivo-snapshot-…` while discovery matches
  `kelivo-snapshot-`, and for a `cuplivo-data` folder where the durability fault matches `kelivo-data`).
  The eight `test/goldens/markdown_backdrop_golden_test.dart` cases were a third class: their
  baselines are pixel fixtures, and Skia's text rasterisation differs between the image that generated
  them and this machine. Their baselines were generated **on the CI image** (ubuntu-24.04) so that
  `pr-check.yml` compares against its own renderer — a fixture that fails everywhere is a fixture that
  was never generated where it runs, not a platform to register. Upstream retired the whole golden
  layer at `4671dbe48` (`ccd0815e9`, "remove screenshot goldens and fix Linux browser checks"), which
  ends the question the registry could only answer per-run: their 259 entries were dropped with the
  suites, because a registration names a test that must still exist.
- **Register a Windows failure only after a control run at upstream's tip.** The eight goldens were
  not guessed at: `git worktree add … e15df5485`, `flutter pub get`, the same file, and all eight
  failed there with the same magnitudes. A registry entry is a claim that the failure is the
  platform's, and the claim is only worth the control run behind it. The claim has to be re-earned
  when the baseline moves: `199647a5d` got its own control worktree and reproduced the same eight at
  the same percentages (2.07/1.46/1.35/0.71 light, 2.04/1.45/1.34/0.70 dark), which is why the
  entries could stay. The `3924a5d0e` re-base re-earned the claim for two new classes — the
  generated-UI goldens (241 cases) and the embedded browser engine (63) — each with its own
  control run at that tip; `docs/flaky-tests.md` §13 carries the numbers and the one exception
  (four case names containing a colon that the local registry cannot key). The `4671dbe48` re-base
  then *retired* 259 of those 320 entries because upstream deleted the golden suites, and added two
  of its own after the same kind of control run at `05506b840` — see §14. A registry is a claim
  about a test that exists, so it shrinks as well as grows. The pass finished on `b1702b3a9`, which is
  that line plus upstream's Windows custom-data-directory work.
- **Back up before the force push**: `backup/master-<sha>`, plus a `backup/series-<old-baseline>` when
  a series branch is replaced, both pushed.

## Benchmarks are not tests

`test/perf/*_bench.dart` print timings and contain no `expect()`, so they cannot
fail. They are named out of the default `_test.dart` glob and so are skipped by
`flutter test`. Run one explicitly:

```bash
flutter test test/perf/timeline_scroll_bench.dart
```

## UI guidelines

- **Use app-defined widgets** from `lib/shared/widgets/` and `lib/shared/dialogs/` instead of raw Flutter/Material widgets wherever an equivalent exists (e.g. `SectionCard`, `CustomBottomSheet`, `IosFormTextField`, `IosCheckbox`, `InteractiveDrawer`).
- **BottomSheet**: both Flutter's built-in bottom sheet and `CustomBottomSheet` are fine on mobile. Never use any bottom sheet on desktop — use a dialog or another interaction pattern instead.
- **Icons**: use `lucide_icons_flutter`, not `Icons.*` from Material.
- **Animations**: use `flutter_animate` / `animations` for motion.
- When building a new page, create separate desktop and mobile layouts unless the page is trivially simple. Wire them together via `ResponsiveHelper`.

## Code style

- Do not preserve backward compatibility. Remove obsolete paths instead of adding compatibility layers, fallbacks, or migrations.
- Choose the simplest implementation that fully meets the current requirements. Avoid speculative abstractions, configuration, and indirection.
- Grow the system in layers. Start from the smallest version that works end to end, and add each new capability on top of a product that already works. Never trade a working product for unfinished complexity.
- Keep components modular and concerns clearly separated.
- Prefer established, well-maintained libraries when they reduce overall complexity or improve reliability. Do not reimplement common functionality without a clear reason.
- Lean on the dependencies already in the project before writing your own implementation or adding packages. Do not assume a library lacks a capability without checking its documentation and types.
- Make architectural decisions for the long term. Do not accept a stopgap that only works for now and is meant to be replaced later.

## Blast radius (blast radius)

A shared rule — a predicate, a TTL, a cap, a sweep, a fold, a default — is changed by *every* call
site it has, not by the one being edited. The LAN sync review of slices 18–21 found the same defect
twice: a fix added a second caller to a rule whose body assumed the first one's state (a sweep keyed
on age-since-hello swept a live session; a "not a verdict" guard existed on one of the two probe
paths). Before editing one:

- **List every caller and say what changes for each.** Unchanged callers are named as unchanged — in
  the commit message or the PR description, not only in your head. A grep for the symbol is the
  minimum; a rule reachable from two flows needs both flows read.
- **A new call site gets the rule's state table, not its happy path.** Enumerate the states the rule
  can be asked about (for a session: never answered a round, dialing, answered, yielded and unbeaten,
  idle, a beat in flight) and write the test per cell — or assert the invariant where the state is
  built, so an unenumerated state fails loudly instead of silently.
- **Give the rule one choke point.** If the same decision is implemented twice, the second
  implementation is the bug: extract it before adding a third caller.
- **A limit that another limit depends on is derived, not restated.** Numbers that must agree
  (a fan-out and the cap that answers it) live in one file, one computed from the other, with a test
  asserting the relationship.
- **Prove the guard.** A new assertion, refusal or default is shown to fail when the violation it
  guards is injected, then reverted byte-exact (see the global protocol: back up *before* injecting).
  Where the shape allows, make the proof permanent: assert that the broken state is itself broken.

## Local dependencies

Several packages live under `dependencies/` and are referenced by path in `pubspec.yaml` (e.g. `markstream`, `mcp_client`, `flutter_tts`, `flutter_math_fork`, `downsize`). The analyzer excludes `dependencies/flutter_math_fork/**` and `dependencies/flutter_tts/**`.

## Useful commands

```bash
flutter pub get                             # install dependencies
flutter gen-l10n                            # regenerate l10n files
dart run build_runner build                 # regenerate Drift code
```
