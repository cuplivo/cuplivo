# AFENTS.md

## Project overview

Cuplivo is a cross-platform LLM chat client built with Flutter, targeting iOS, Android, macOS, Windows, and Linux. Package name is `Cuplivo` — imports use `package:Cuplivo/...`. It is a community fork of Kelivo, re-baselined on Kelivo v1.3.1; from 4.0 on, every version re-bases on the latest Kelivo stable and re-does Cuplivo's own features as cherry-picks on that baseline.

## Architecture

- **Feature-based structure**: `lib/features/<feature>/` with `pages/`, `widgets/`, `models/`, `utils/` subdirectories.
- **Desktop / mobile split**: most UI pages have separate desktop and mobile layouts (e.g. `home_desktop_layout.dart` / `home_mobile_layout.dart`). Desktop-only code lives in `lib/desktop/`. Use `ResponsiveHelper` from `lib/shared/responsive/` to branch by screen type.
- **State management**: Provider (`lib/core/providers/`).
- **Database**: Drift (`lib/core/database/`). Schema versions tracked in `drift_schemas/`.
- **Localization**: ARB-based (`lib/l10n/`), English template (`app_en.arb`). Run `flutter gen-l10n` after editing ARB files and commit the generated output exactly as it is written — the generator formats its own files, so never hand-edit or reformat them. CI regenerates and compares (`pr-check.yml`), and a generated file that was reformatted outside the package (e.g. a copy under the system temp directory, where the package's language version does not apply) fails that comparison.

## Pre-commit checklist

Format changed Dart files with `dart format`, including files under `lib/`,
`test/`, `integration_test/`, `dependencies/markstream/lib/`, and
`dependencies/markstream/test/`. Then run both packages before every commit;
all checks must pass:

```bash
dart analyze --fatal-infos lib test integration_test
flutter test
(cd dependencies/markstream && flutter pub get && dart analyze --fatal-infos && flutter test)
```

CI (`pr-check.yml`) enforces the same gates on every PR. Root-package checks
do not cover the `markstream` path package.

It formats with the Dart SDK bundled in the Flutter version its workflow pins
(`FLUTTER_VERSION`, currently 3.47.6 -> Dart 3.13.0). A newer local SDK lays the same code out
differently, so `dart format` with the local SDK both reformats files CI would leave alone and
leaves files CI wants changed — either way turning the PR check red. Format with that pinned Dart
whenever the local one differs, and confirm with `--output=none --set-exit-if-changed` before
pushing.

## Releases

- **Version**: `pubspec.yaml` only (`version: X.Y.Z+N`); the release tag is `vX.Y.Z`.
- **Rebases**: master is rewritten whenever the line re-bases on a new Kelivo stable. Re-create the
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

Cuplivo follows upstream: a new version re-bases the code base on the latest Kelivo stable and
re-does Cuplivo's own features on that baseline instead of porting the fork forward. Never let the
fork diverge permanently — the 3.x line ended because hand-syncing every upstream change became
unmaintainable. See `docs/adr/0004-follow-upstream-rebase.md`.

A re-base never carries patches to a package we consume. `dependencies/markstream` is upstream's
code, vendored by path; a defect found there is filed on upstream and waited for, not patched
locally — a local patch is the first thing the next re-base silently drops, and it makes the
package's own gate meaningless. The 4.4 re-base deferred the hand-cursor fix (#1014) this way
(Chevey339/kelivo#1269) and recorded the gap in `docs/markstream-delta-audit.md`.

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
