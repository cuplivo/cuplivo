# Re-base runbook

Companion to [ADR-0004](adr/0004-follow-upstream-rebase.md): the decision is to re-base on the
latest Kelivo **stable** and *re-do* Cuplivo's features on it, never to port the fork forward.
This file records the mechanics of that replay, so the next re-base is a replay and not a porting
project. It describes the 4.1 line; update it whenever the series below changes.

## The replay units, in order

Each line is one cherry-pick unit. The order is not cosmetic: units 4, 6 and 7 share files
(`lib/features/home/widgets/chat_input_bar.dart`, `lib/features/home/controllers/home_page_controller.dart`),
and unit 7's diff was authored on top of 4 and 6, so it replays last among the features.

| # | Unit | Notes |
| --- | --- | --- |
| 1 | `feat!: Cuplivo identity on the Kelivo v1.3.0 baseline` | the re-brand **plus** the "clear the format, analyze and test gates" work — the gates were red on the fresh baseline, so both belong to the same unit. Mechanical: renames, application id, platform identity, removal of the built-in `kelivo` search service |
| 2 | `fix(android): bundle the current proot tooling and fix the fetchProot 404` | `tool/fetch_proot.sh`, `tool/proot_checksums.txt`, `android/app/src/main/jniLibs/NOTICE`. Build tooling on purpose kept out of the feature units |
| 3 | `feat(image): manual compression editor with explicit format control and bounded working memory (#925, #946)` | ADR-0002 + ADR-0005 |
| 4 | `feat(chat): persist the unsent input draft across restarts (#930)` | composer draft store |
| 5 | `feat(sync): LAN sync, the dual stack, candidate probing and a panel that tells the truth (#932, #947, #952)` | ADR-0003 |
| 6 | `feat(care): 「Ta的来信」跨平台回归，助手设置新增「角色扮演」页签 (#935, #976, #996)` | proactive care: the port (#935), the audit fix split out of #976, and the desktop entry points (#996) |
| 7 | `feat(image): crop the unsent image in its preview (#992)` | depends on 3 (the compression pipeline and its deferred crop step), 4 and 6 (the composer it edits) |
| 8 | `chore(release): …` | **one** release unit. Version, `CHANGELOG.md` / `CHANGELOG_CN.md`, `CONTEXT.md` and the README "what's new" section are regenerated for the new baseline, so a unit per published bump buys nothing |

## Rules

1. **Replay features, not the fork's tree.** `git cherry-pick` each unit onto the new baseline and
   resolve; do not merge master into the fork.
2. **`lib/l10n/` is regenerated, never merged.** Seven files (`app_en.arb`, `app_zh*.arb`, the three
   generated `app_localizations*.dart`) are touched by almost every unit, so they conflict
   everywhere. Take the ARB keys you need, then run `flutter gen-l10n`; do not hand-merge the
   generated Dart.
3. **One release unit, and it is regenerated.** Re-derive the version from `pubspec.yaml`, write both
   changelogs, and create the new tag on the new tip (AGENTS.md → Releases). Old tags stay on the
   pre-rewrite commits, which the backup branches keep reachable — retagging an already-published
   version is neither possible nor needed.
4. **One unit, one message.** A unit's commit body carries the sub-commit narrative of the PRs it
   came from; keep it when you replay, so the "why" survives the re-base.
5. **Verify by tree equality, then by gate.** The replay of a unit must produce a tree whose content
   equals the fork's — anything else is an accidental port. Then run the full gate with the Dart SDK
   CI pins (`FLUTTER_VERSION` in `.github/workflows/pr-check.yml`, currently Flutter 3.44.9 → Dart
   3.12.2): `dart format --output=none --set-exit-if-changed lib test`,
   `dart analyze --fatal-infos lib test integration_test`, `flutter test`. A newer local SDK
   reformats files CI leaves alone — it is not a failure signal.

## Procedure

```bash
git checkout -b rebase/kelivo-<version> <new-baseline>
# for each unit, in the order above:
git cherry-pick -n <sha-of-the-unit-in-the-fork>
#   resolve conflicts; for lib/l10n/* prefer the ARB side and re-run:
flutter gen-l10n
dart format lib test
dart analyze --fatal-infos lib test integration_test
git commit -C <sha-of-the-unit-in-the-fork>
# finally: version bump + both changelogs + the new tag, then the release workflow
```

## What this line learned (keep — it is the point of the runbook)

- A unit that straddles two features cannot be reordered freely: `#992` (crop in the unsent-image
  preview) edits files that `#930` and `#935` also edit, so it sits after them. Splitting it by hand
  to make the image series contiguous costs more than it buys.
- A follow-up on a feature already in the series belongs in that feature's unit: `#996` (the desktop
  care entry points) landed after `#992`, but it touches only care files, so it folds into unit 6
  without touching #992's diff. Check that overlap before deciding.
- Build tooling and release chores must stay out of feature units; otherwise every cherry-pick drags
  them along.
- The identity unit is the expensive one (over a thousand files) and is mechanical; treat it as a
  scripted rename, verified by `dart analyze`, not as a merge to reason about file by file.
