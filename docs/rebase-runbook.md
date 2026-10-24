# Re-base runbook

Companion to [ADR-0004](adr/0004-follow-upstream-rebase.md): the decision is to re-base on the
latest Kelivo **stable** and *re-do* Cuplivo's features on it, never to port the fork forward.
This file records the mechanics of that replay, so the next re-base is a replay and not a porting
project.

Seven re-bases have been run: 4.0 → `df60f7425`, 4.1 → `3c92d1062`, 4.2 → `4742d2e28`, the 4.4 line →
`cf2af98e6` (`v1.3.1-11`), 4.4 → `a83647077` (upstream master: the storage/backup rework, the
recovery screens and the markdown theme tokens), 4.4 → `e15df5485` (upstream master, 31 commits
on: the integrated browser over four vendored `flutter_inappwebview` forks plus
`liquid_glass_widgets`, password-encrypted backups, MCP presentation groups, the long-image export
rework and a markdown contrast pass) and 4.4 → `199647a5d` (upstream master, seven commits further
on: iOS native selection menus, the world-book copy/batch transfer, macOS Developer-ID
notarization, and the commit that commits both lockfiles and makes CI enforce them). The conflict
counts quoted below are the 4.1 one's; the *rules* are what to carry forward. The unit list below
is the 4.4 line's series as replayed onto `e15df5485` and then onto `199647a5d` (14 content units,
normalized from the 34-commit line, each unit's l10n re-derived by `flutter gen-l10n`): baseline
repair → features → four landing commits — the new baseline's own repairs, the lock and the release
wiring, the record, and the mechanical reformat at the tip. The `199647a5d` landing was then
normalized from 35 commits to 18 by materializing the landing commits' paths from the tip
(§ *The landing is 18 commits*), which is lossless by construction.

## The replay units, in order

Each line is one unit, replayed onto the new baseline. Order matters because units share files: the
composer and home units (`chat_input_bar.dart`, `home_page_controller.dart`) touch the same regions, so
the baseline-repair unit — which restores the composer API — replays before them, and `#1008`'s composer
fix now rides inside the care unit instead of standing alone. A follow-up folds into its unit when the
only crossing files are the changelogs, `lib/l10n/`, `main.dart` or a document; rule 13 is the test, and
every fold below names the crossings it accepts.

| # | Unit | Notes |
| --- | --- | --- |
| 1 | `feat!: Cuplivo identity on the Kelivo baseline` | the re-brand, the sweep for files upstream added since the old baseline, the "clear the analyze gate" work, **plus the content carry folded in**: both READMEs, AGENTS.md, both changelogs, the `version:` line, the CI collapse to one `release.yml`, the release-notes CI step, the About mark asset, the runbook rewrite and the markstream audit. Mechanical: renames, application id, platform identity, removal of the built-in `kelivo` search service. **Over a thousand files**. Costs four `CHANGELOG*` unions in the early feature units. At a re-base the carry is still materialised with `git checkout <old-master> -- <paths>`, inside this unit's resolution |
| 2 | `fix(tests): baseline repair — Windows suite, CI, l10n` | the l10n cleanup of the messages the new baseline retired, the `#1011` backup test, the two upstream test repairs, `#1032` (the flaky root causes and eight Windows failures), `#1041` (the eight full-suite failures plus the master CI trigger) and `f0f570358` (legacy Kelivo identities, upstream composer API). **Second on purpose**: every later unit then replays on a tree the gates can pass. Costs three `chat_input_bar.dart` crossings when 3, 6 and 7 replay, and the ARB hunks of five later units are re-resolved with `flutter gen-l10n` (rule 2) |
| 3 | `feat(image): manual compression editor with explicit format control and bounded working memory` | ADR-0002 + ADR-0005 |
| 4 | `feat(sync): LAN sync, the dual stack, candidate probing and a panel that tells the truth` | ADR-0003, **plus two follow-ups folded in**: `#1030` (workspace carriage, first-class endpoints, a rebuilt panel) and `#1037` (a close to the tray no longer stops the listener, [ADR-0015](adr/0015-close-to-tray-listener.md)). Only `main.dart`, the one-line registration site, crosses (rule 13) |
| 5 | `feat(care): 「Ta的来信」跨平台回归，助手设置新增「角色扮演」页签` | proactive care: the port, the desktop entry points, the `#1007` trigger contract ([ADR-0006](adr/0006-proactive-care-trigger-contract.md)) and the `#1008` composer/assistant-name fix, folded in. Accepts crossings on `home_page_controller.dart` (units 6 and 8) and on `#1008`'s own Android alarm files |
| 6 | `feat(image): crop the unsent image in its preview` | depends on 3 (the compression pipeline and its deferred crop step) and 5 (the composer it edits) |
| 7 | `fix: re-port input focus retention on app resume (#1012)` | the desktop hotkey plus the composer it focuses |
| 8 | `feat(chat): copy a conversation or message link (#1013)` | **plus `#1034` folded in** (Android deep links): iOS and Android links are one unit. Accepts one crossing on `test/message_more_sheet_test.dart` (`#1027`) |
| 9 | `feat(chat): weigh the compression readout in tokens, tool results included (#1026)` | ADR-0011 |
| 10 | `feat(reply): a message reply carries a quote citation (#1027)` | ADR-0012 |
| 11 | `feat(export): a PDF laid out from markstream's tree, no WebView and no second renderer (#1028)` | ADR-0013 |
| 12 | `feat(translate): user-managed target languages incl. Bengali (#1039)` | ADR-0014 |
| 13 | `feat(suggestions): a chat-suggestions switch per assistant (#1040)` | — |
| 14 | `feat(recycle): a recycle bin for deletions, losing merges and workspace files (#1035)` | ADR-0016 |
| 15 | `fix: the new baseline's suite, fixtures and preference keys` | the landing repair: the two tests the baseline reshaped (`0bb6bc952`), the Windows-only assumptions the suite still carried (`6f4252bf5`), the non-nullable selection-toolbar items (`8407fbc88`), the migration retry's 1 s poll budget (`e4b111e31`), the browser cases the platform cannot run and the golden fixtures generated on the CI image (`71b0afa17`, `724affebc`), the two pre-rename ARB messages upstream still ships (`379fd2b35`), and the MCP presentation key the sync registry owed (`5efd382ff`). Not folded into unit 2, its natural home: the repairs touch test files units 3-14 own, so folding would mean replaying the whole series |
| 16 | `chore(deps): the lock and the release wiring the gates run against` | `00d9c4580` (the seeded `pubspec.lock` every gate now runs against), `f75363461`'s `.gitignore` line for golden failures, and `515e807e2` — the notarization signs `cuplivo.app` and `Cuplivo_macos_*.dmg`, and `docs/homebrew/kelivo.rb` is deleted (rule 15) |
| 17 | `docs(rebase): the invariants and the 199647a5d record` | `docs(agents)` `2eda72787` folded in, then `76993e753`, `956bec9fe`, `81271f940`, `e362f75bf`, `779452761`, `78436c40b`, `ea19c6cc1`, plus the document hunks of `f75363461` and `724affebc` |
| 18 | `style: reformat the files the 3.47.6 formatter lays out differently` | re-derived at the tip (rule 10); never replayed, and never folded into a content unit — a mixed unit could be neither dropped nor re-derived. **Last on purpose**: the series tip is the reformat, which is what makes the `<old-master>~1` cut in the procedure correct again |

The tail is no longer a run of one-commit chores: the l10n cleanup and every test/CI repair now belong
to unit 2, and the content carry, the CI collapse, the release-notes step and the runbook itself belong
to unit 1. The carry owns the version line, so it is also what replaces the old line's release commits
— there is no release unit in the series. The mechanical reformat is re-derived last (rule 10) and is
the series tip, which is what makes the `<old-master>~1` cut below correct.

The `e15df5485` replay added tail commits after the units, and only because their corrections could
not be folded back into the unit that owns them without replaying the whole series again: a
`fix(tests)` for the two tests the new baseline reshaped, a `fix(l10n)` for the two messages upstream
still ships under their pre-rename names, the re-derived reformat (unit 15 there), and — once the full
Windows suite had been run — a second `fix(tests)` for the three test-side assumptions it found (see
`docs/flaky-tests.md` §10) plus a `feat(sync)` for the one new upstream preference key that needed a
disposition decision. A one-line correction belongs in its own unit when the replay is still open;
once it is closed, a tail commit with the evidence in its message is the cheaper record.

The `199647a5d` landing closed the same way and then folded itself: its 21 tails (that paragraph's
commits, the nine this baseline added, and `docs(agents)`) became **four** — unit 15 the baseline's
suite, fixtures and preference keys, 16 the lock and the release wiring, 17 the record, 18 the
reformat at the tip. They are folded by *path from the tip* rather than by replaying their patches:
each landing commit materializes its paths from the old tip
(`git restore --source=<old-tip> --staged --worktree -- <paths>`), which reproduces the tip tree byte
for byte as long as no path is split across two of them — `f75363461` and `724affebc` each hand their
document hunks to 17 and the rest to 16 and 15. The fold is what removes the replay rounds; it does
not move the conflict surface, which is the union of the same 77 paths.

Units from earlier series that are **gone, and must not come back**:

- **The composer-draft unit (`#930`) is discarded.** Upstream now ships its own per-conversation
  draft (`lib/core/database/composer_draft_store.dart`, `lib/core/models/composer_draft.dart`), so
  re-replaying ours would fight it. Before assuming a unit is still needed, check whether upstream
  grew the same capability — a discarded unit leaves dead l10n keys behind, not dead code.
- **The `await` gate fix is discarded as of this re-base** — upstream made the same four fixes
  itself. See rule 7; this is the case that rule exists for.
- **The proot-tooling unit is absorbed.** Upstream bundles the pinned PRoot runtime itself
  (`707772844` sits in the baseline), so `tool/fetch_proot.sh` and `tool/proot_checksums.txt` are
  upstream's files now and no Cuplivo commit touches them. Re-adding the unit would fight upstream's own
  tooling — the same case as the `await` gate fix (rule 7).
- **There is no release unit.** A re-base is not a release: no version bump, no new tag, no
  changelog section, no release dispatch. `pubspec.yaml` keeps the version line the old tip had
  (`4.3.0+6` for the 4.3 line) while taking upstream's dependency changes — but the *content carry* is
  what puts that line and the released changelog into the series, so the old line's release commits are
  absorbed by the carry rather than replayed (`git log -S'4.1.0+4' -- pubspec.yaml` shows the carry
  introducing the line on the last re-base). Re-tagging and re-dispatching is a separate, deliberate act
  (AGENTS.md → Releases).

## Rules

1. **Replay features, not the fork's tree.** Cut a scratch branch at the last unit before the
   reformat commit and replay onto the new baseline with
   `git rebase --onto <new-baseline> <old-baseline> <scratch>`; never merge master into the fork.
   Read the *real* conflicts rather than predicting them: on the 4.1 re-base the diffstat (+8626/−4388,
   125 files) suggested heavy collisions and the actual count was 9 + 1 + 2 conflicting files across
   three units. On `e15df5485` the surface was larger and the count still modest — a `git merge-tree`
   of the whole series named ~300 files changed on both sides, the replay actually conflicted on 31
   (25 in the identity unit, 2 in care, 1 in the link unit, 3 in the PDF export), and units 2, 3, 6,
   7, 9, 10, 12, 13, 14 and 15 applied clean.
2. **`lib/l10n/` is merged per key, then regenerated — never resolved by taking a side.** Every unit
   touches the ARB files and the generated `app_localizations*.dart`, so they conflict everywhere, and
   "take ours" stopped being safe the moment upstream's new code started calling messages the fork has
   never had: this baseline alone added 200 of them, so a unit's own ARB is a *subset*, not a superset.
   Merge at dict level, per key, in this order:
   - upstream changed the value and our side still equals the old baseline's → take
     `rename(upstream)`, `@`-metadata included, because the annotation describes its placeholders;
   - our side changed it, or the key exists only in the fork → keep ours;
   - upstream only → append `rename(upstream)`, **except** a key the identity unit renamed: that one is
     dropped, not added beside the fork's name (`aboutPageKelivoSearch*` and `searchServiceNameKelivo`
     are the two that have arrived this way, and they carry the fork's value byte for byte).

   The brand rename applies to the incoming side: `Kelivo`/`kelivo` → `Cuplivo`/`cuplivo`, with the
   whitelisted protocol/persisted names restored afterwards. Prove it before moving on:
   `git grep -c Kelivo -- lib/l10n` prints nothing, then `flutter gen-l10n` from the package root and
   confirm it is idempotent (`git status --short -- lib/l10n` empty). Never hand-splice ARB: write it
   from a dict and validate with `json.loads` first, or you will ship truncated `@key` metadata.
   `app_zh_Hans` deliberately carries 24 fewer messages than the other three locales — that gap is
   pre-existing, so diff it against the old tip before treating it as a regression.
3. **The identity unit must sweep upstream's new files, and the sweep belongs in that unit.** A
   cherry-pick only merges *conflicting* files, so files upstream added after our old baseline keep
   upstream's own `package:Kelivo/` imports and branding because they never conflicted. Enumerate
   `git diff --name-only --diff-filter=A <old-baseline> <new-baseline>` and run the rename set over
   them. Fold the result into the identity commit rather than leaving a trailing sweep commit: a unit
   has to be self-consistent, and with the sweep left out the identity commit's own tree imports a
   package name that no longer exists.

   On `e15df5485` that was 1193 added files, and the work came in four shapes: 86 added `.dart` files
   importing `package:Kelivo/`; one Android unit test upstream added under
   `android/app/src/test/kotlin/com/psyche/kelivo/`, which git had already *detected* as a rename into
   our package path but not rewritten inside (the `package` line and imports); the platform identity in
   new Swift/Kotlin and the two `Info.plist`s; and 113 added files carrying a brand token in prose.
   Documentation under `docs/` and the vendored packages' own notes stay verbatim — they describe
   upstream's project and record measurements of upstream's builds, and rewriting them would falsify
   the record. What must not survive is the *code* referencing a package that no longer exists:
   `git grep 'package:Kelivo/'` (only the runbook's own prose may match) plus a green
   `flutter pub get`/`dart analyze` is the proof.
   **The sweep is two rules, and 1095 of the identity unit's 1292 files are only those two rules.**
   Diffing the identity commit against its parent and replaying the substitutions proves it: every
   line of those 1095 files is `package:Kelivo/` → `package:Cuplivo/`, `com.psyche.kelivo` →
   `com.cuplivo.cuplivo`, or a path move. That is what makes a conflicted identity file resolvable by
   construction — `rename(upstream's new content)` — instead of by hand, and it is the check to run
   first on any identity conflict: if `rename(base) == identity` for that file, take `rename(theirs)`.

   **This is not a one-off: the sweep belongs to every replay, not only the one that builds the
   identity commit.** The `199647a5d` replay reused the existing identity commit, and the base had
   meanwhile grown files that did not exist at `e15df5485` — four new `.dart` tests importing
   `package:Kelivo/…`, which no conflict will ever hand you because the identity unit's patch never
   mentions them. Treat the sweep as "files added by the *incoming* range", whatever the replay
   shape: `git grep 'package:Kelivo/'` after unit 1 is the check, `dart analyze` is what finds them
   when you forget, and they are invisible in `git status` because nothing was ever in conflict.
4. **Only sweep tokens upstream's new code *introduced*.** The tree is fully swept at the old tip, so
   the exact work is the set difference: for every file upstream touched, compare its brand-matching
   lines at the old tip against the current tree and take what is new. Classify every survivor against
   the whitelist (`kelivo://workspace|chat|session|skills|tmp|mounts`, `kelivo-file://`,
   `KelivoOpenURL`, `KelivoFileUri`, `KelivoISH*`, `KelivoApplication`, `KelivoPtyJni`, `kelivo_*` tool
   ids, `kelivo.db`, `kelivo_backups`, `kelivo-snapshot-<ms>.zip`, `kelivo.restore-*`, `.kelivo_restore`,
   `kelivo.psycheas.top` / `search.psycheas.top`, `afdian.com/a/kelivo`, `KELIVO_PERF_SCENE`,
   `PackageInfo` mock `appName:`/`packageName:` values, temp-dir prefixes, and the intentional
   `Chevey339/kelivo` attribution in README / CONTEXT / `.github`). On this re-base that reduced 65
   surviving brand lines in 10 files to 9 files' worth of import fixes.

   The whitelist is only a policy until something greps for it, and the sweep is what breaks it: a
   blind `Kelivo` → `Cuplivo` pass over the identity unit's file list rewrote the persisted snapshot
   prefix in `test/shared/widgets/restore_failure_screen_test.dart` to `cuplivo-snapshot-…`, which no
   production code reads — `recovery_file_discovery.dart` matches `^(?:kelivo-snapshot-|kelivo_backup_)`
   — so the archive silently stopped being discovered and the failure surfaced two layers away as
   "validation failed". After the sweep, grep the tree for every entry in this list, not for the brand
   tokens; a name the app persists is exactly the case where a passing analyzer proves nothing.

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

   Two caveats from `e15df5485`:
   - **An intermediate unit is allowed not to compile, and the identity unit usually does not.** The
     identity commit in this series carries later-unit content in the files it shares with upstream
     (the replay of the previous re-base resolved those conflicts by taking the fork's whole file), so
     its tree can reference a file that arrives in unit 4 — `restore_bundle_mover.dart` imports
     `../sync/sync_store.dart`, and `update_provider.dart` imports `device_info_plus` before the unit
     that adds the dependency. The gate belongs to the tip: run the analyzer per unit for *its* own
     damage, and do not spend a round making a unit compile that the series never did.
   - **`dart analyze` is also the migration test for our own absorbed content.** On this replay it
     found exactly two tests left speaking an API upstream had reshaped, and nothing else.
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

   The `e15df5485` replay hit the same shape in the export: our PDF unit had grown its own
   `export_progress_overlay.dart` (one caller, no progress state) while upstream had meanwhile built
   `_runWithExportingOverlay(context, (progress) …)`, `_ExportedImageResult` and a progress widget in
   the same file. The resolution kept upstream's machinery, switched the PDF path to it, reported the
   one stage the PDF owns (`saving`), and deleted the overlay file. The tell is a conflict whose two
   sides are *the same idea with different names*; the test is whether the surviving side can absorb
   the delta, not which side is newer.
9. **Upstream can retire a mechanism your side's context still carries.** A conflict hands you the
   *old* symbols along with your own additions: our sync unit's hunk still contained
   `idleCacheBackfillSlotLimit` and `_scheduleIdleCacheBackfill`, which upstream had removed outright
   in favour of windowed loading. Resolve by taking upstream's structure and keeping only your genuine
   delta, then grep the whole tree for the retired symbols to prove nothing dangles.
10. **The reformat commit is re-derived, never replayed.** Upstream reformats its own tree, so a
    replayed formatter pass conflicts with the reformat it now sits on. Drop it and run the formatter
    again on the rebased tree: conflict-free by construction, and the resulting commit touches only
    files Cuplivo itself changes. This is also why the identity unit does *not* carry the gate-clearing
    reformat. **It must also be the series tip:** on the 4.3.0 line it sat ten commits below the tip, so
    the `~1` cut would have dropped the care `#1008` fix instead of the reformat. Normalize the series so
    the reformat is last, or name it explicitly in a `rebase -i` todo.

    **The pass covers `dependencies/markstream` too, and this is the gate that finds it.** CI's format
    step names the Dart files a change touched, and on a rewrite that set is the whole re-base —
    including the vendored package. `e15df5485` brings a markstream laid out for an older Dart, so the
    first run on the rewritten `master` was red on 25 files there (7 `lib/src`, 18 `test/`) while the
    root tree was already clean; the fix is the same `dart format` over
    `dependencies/markstream/{lib,test}`, and it is style-only. Run the formatter over all five paths
    before pushing and the format step has nothing to say. Note that a `flutter pub get` inside that
    package rewrites its `analysis_options.yaml` with platform excludes — restore that file first, it
    is upstream's.
11. **Never hand-resolve a conflict block without reading what sits outside the markers.** Removing
    the `<<<<<<<`/`=======`/`>>>>>>>` lines by hand silently drops the lines the conflict *didn't*
    cover: upstream's `result.headers.addAll(authHeaders)` lived between two conflict blocks and would
    have vanished. When your side's delta on a file was only the conflicting hunk,
    `git checkout HEAD -- <file>` is exact and safe — verify that by reading your unit's full diff for
    that file first. Afterwards, re-read the whole function rather than just the resolved region.
12. **`git checkout --ours` during a cherry-pick means the branch you are on**, i.e. upstream's side —
    not "our fork". Resolving the identity unit that way is how our own Windows portability fixes were
    briefly lost and had to be re-applied by hand. Say "ours = upstream" out loud before using it.
13. **Fold a follow-up into its unit only when the overlap is free.** Compare the follow-up's file set
    with every commit between it and its unit: intersections that are only the changelogs, `lib/l10n/`
    and a one-line registration site (`main.dart`) fold cleanly — the ARB files are regenerated anyway
    and the changelog merges as a union. When the follow-up edits a file the intervening units own
    semantically, it stays its own unit: the care `#1008` fix edits the composer's
    `home_page_controller.dart` and `chat_message_widget.dart`, so folding it up would re-resolve the
    crop, focus, markdown and link units for no gain. On the 4.3 series this folded the two sync
    follow-ups and kept `#1008` separate.
14. **A file with no conflict marker can still be wrong.** Git merges by hunk, so a commit that adds a
    *new* line naming the other product lands silently: `639b60a51` added
    `bash tool/macos_sign_and_notarize.sh sign-app "…/Release/kelivo.app"` and a `Kelivo_macos_*.dmg`
    notarize step to the four macOS build jobs, our `release.yml` is the rename of one of them, and
    the merge reported "Auto-merging .github/workflows/release.yml" with the paths still upstream's —
    in a job whose every other line says `cuplivo.app`. The re-base is not done when the conflicts are
    resolved; it is done when grepping for the other product's *identifiers* comes back clean:
    `package:Kelivo/`, `kelivo.app`, `Kelivo_macos_`, and any path or bundle id a build produces. An
    inconsistent file — one app name among several — is a conflict git failed to report.
15. **A note that describes upstream's distribution is deleted, not swept.** `docs/homebrew/kelivo.rb`
    arrived with the notarization commit as a cask draft for `Chevey339/kelivo`'s own releases. Swept
    by the rename rules it would claim `com.cuplivo.cuplivo` as Kelivo's zap path; unswept it
    advertises a cask this fork does not submit, and `docs/macos-signing.md` walked a reader through
    filing it. Both went, and the signing doc's verification commands now name our artifacts. The
    "docs stay verbatim" rule below covers notes that *record* upstream (CONTEXT.md, the ADRs,
    measurement logs); it does not cover a procedure our own workflow executes.
16. **The CI image is a platform, and a first run can be the first time it is exercised.** The
    `199647a5d` replay's `pr-check.yml` run was the first one to get past `dart analyze` since the
    baseline's browser and golden tests were added, and it reported 13 ubuntu-only failures: five
    browser cases that mount a page on a platform where `BrowserService` has no engine
    (`browser_platform_unsupported`), and eight `markdown_backdrop` goldens whose PNGs were generated
    on a machine whose font stack differs from the runner (1.4–2.2 % here, 0.67–2.07 % on Windows).
    Neither is a fork regression, and neither had ever been observed. The repair is one rule each:
    a test that mounts a platform service asks that service's platform predicate and skips, and a
    pixel fixture is **generated on the image that will compare it** — a one-off
    `workflow_dispatch` job running `flutter test --update-goldens`, its artifact downloaded and
    committed, the workflow then deleted. A fixture that fails on every platform is not a platform
    failure to register; it is a fixture that was never generated where it runs.

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

A re-base that does not move the Flutter line has no CI work to do: on `e15df5485` upstream's
workflow files were byte-identical to the ones the previous re-base derived `release.yml` from, so the
right answer was to leave `.github/workflows/` untouched. Check that first (`git diff --stat
<old-baseline> <new-baseline> -- .github/workflows/`) instead of re-deriving by habit.

The carry itself is a union, not a checkout: `pubspec.yaml` takes upstream's file (its new
dependencies, path overrides and the `shaders:` section) and re-applies the fork's deltas — `name:
Cuplivo`, the fork's `version:` line, `device_info_plus`, `basic_utils`, `pdf` with the `archive`
override, and the About-mark asset. Same shape for `.gitignore` (ours wins) and the two READMEs (ours,
with the baseline fact re-read from upstream's tree).

## Procedure

```bash
# a scratch branch, so master is untouched until the line is verified
# (the series ends with the mechanical reformat — unit 18 — so ~1 drops exactly that; the release
#  commits are not in the series — the content carry owns their content)
git branch --force rebase/onto-<new-baseline> <old-master>~1
git rebase --onto <new-baseline> <old-baseline> rebase/onto-<new-baseline>

# per conflict, in order
#   ask first whether upstream already did this (rule 7) and whether our side still needs it (rule 9)
#   l10n        -> dict-level three-way merge, then `flutter gen-l10n` (rule 2)
#   imports     -> upstream's list, Cuplivo-prefixed
#   identity    -> mechanical files resolve as rename(theirs); the rest by a real 3-way merge
#   the sweep   -> rename set over `--diff-filter=A` files, folded into unit 1 (rules 3-5)
dart analyze --fatal-infos lib test integration_test

# identity sweep, folded into unit 1
git commit --fixup=<identity-sha> && git rebase -i --autosquash <new-baseline>
#   a job has no terminal: set `git config --local core.editor true` first, or `rebase --continue`
#   blocks in Vim forever

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
- **A follow-up on a feature already in the series belongs in that feature's unit** — when the overlap
  is free. Check it with rule 13 before deciding: on the 4.3 line the two sync follow-ups folded in and
  the care `#1008` fix did not.
- **Build tooling and release chores stay out of feature units**, or every cherry-pick drags them
  along.
- **Some units were authored against APIs that no longer exist.** The care unit asked for a global
  `thinkingBudget` on `ChatApiService.generateMessage`; the new baseline retired that key in favour
  of per-request `ReasoningRequest`. The fix is to port the unit's *intent* onto the new API (the
  care flow now calls `selectReasoningRequest`, the same chain the file already documented for model
  resolution) — not to reinstate the retired parameter or the retired preference key.
- **A reused subsystem brings its *scheduling* half and its *reporting* half — on the platforms
  that have one.** The care port took Kelivo's alarm plumbing and arrival notification but dropped
  `PreparedScheduledTasks` (the in-app executor Kelivo's own iOS scheduler runs due work with) and
  the exact-alarm state its task list reports — so care looked armed everywhere and delivered
  nothing in the foreground on iOS. When a unit reuses an upstream subsystem, diff the whole
  subsystem, not just the entry point it calls — and mirror only the halves upstream actually has
  on that platform: Kelivo has no in-app executor on Android (`ScheduledTasksService.configureDevice`
  returns early there), so care must not add one either
  ([ADR-0006](adr/0006-proactive-care-trigger-contract.md)).
- **Reusing an upstream channel means reusing its *identifiers*, its *replace-all semantics*, and
  its *timing*.** `ScheduledTaskNotifications` prefixes `scheduled-task:` in both `schedule` and
  `cancel`, so callers pass the bare id (`IosProactiveCareScheduler.notificationIdFor`) and
  `rescheduleAll` must explicitly cancel conversations that dropped out of the pending set; and the
  catch-up on a notification-tap cold start must run again at the end of `initChat` because
  `resumed` precedes the conversation cache load. Both mistakes are invisible from a single call
  site — read the adapter, check replace-all symmetry across platforms, and check when the
  lifecycle event actually fires. ADR-0006 decisions 11-15 pin them down, and because no workflow
  compiles `android/app/src/test/` at all, when a unit touches `scheduled/` or `ios/Runner/`, build
  it and run its Kotlin tests deliberately rather than trusting the PR gates.
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

  On the `e15df5485` re-base the deviation was per *object*, not per command: the workspace root and
  anything created under it carried `Low Mandatory Level:(OI)(CI)(NW)`, but the 7711 files and 2330
  directories checked out before DSH provisioned the workspace still carried no label — so the
  sandbox could create a file in `.scratch/` and not overwrite a file git had written in `lib/`, with
  `permission denied` and a DACL that grants everything. Labelling the tree once (the same Low label
  with inheritance the root already carries, applied to files and directories, `.git`/`build`/
  `.dart_tool` left alone) turned every later write into an ordinary one. `icacls` cannot set it from
  inside the sandbox — do the relabel from a normal shell, once, before the replay.
- **Normalize the series before the re-base, and prove the pass by tree equality.** The 4.3.0 line
  needed one: fold the sync follow-ups into their unit, keep `#1008` separate, absorb the two release
  commits into the content carry, and move the reformat to the tip. The proof that the pass lost nothing
  is `git diff --quiet <old-master> reorg/series-<line>` at the series tip (the runbook rewrite aside):
  the series reproduces the old tip's tree byte for byte. Fold *there* rather than inside the replay —
  while the old tree is still the reference a hunk lost to a bad resolution shows up at once, and once
  upstream's changes are mixed in it cannot. The 4.3 pass cost three conflicts (`CHANGELOG*.md` ×2, the
  runbook's modify/delete) and produced a 16-commit series from a 20-commit line.
- **A conflict's incoming side carries context that is not its intent.** The sync fold's `CHANGELOG.md`
  conflict offered the whole 4.2.0 / 4.1.0 / 4.0.1 sections as "theirs", while the commit's actual
  intent was one `### Fixed` entry under `## [Unreleased]`. Taking "theirs" wholesale would have
  replayed three releases' worth of changelog inside a sync fix — rule 11, applied to a fold. Read the
  hunk, then keep only what the commit was about.
- **Materialize whole-file boundary commits from the target tree instead of replaying their patches.**
  The content carry and the reformat are whole-file operations: `git checkout <old-master> -- <paths>`
  plus `git rm` for the paths `<old-master>` no longer has makes them conflict-free by construction, and
  it is what lets the tree-equality check above be exact. Their patches are never applied, so a
  formatting-only conflict cannot invent one.
- **Never resolve a conflicted file by taking one side wholesale.** `git checkout --theirs -- <file>` on
  a conflict is not "take the incoming hunk": it restores the *old baseline's* whole file plus the unit,
  so on the 4.4 replay it silently rewound 239 lines of newer upstream code in
  `home_page_controller.dart` (twelve tests died at once) and dropped the keys Git had auto-merged into
  the ARBs. Resolve by hunk — or, when the two sides' changes are disjoint, re-derive the file with a
  real three-way merge (`git merge-file -p --diff3 ours base theirs`) rather than picking a side.
- **A conflict preview is free.** `git merge-tree <base> <ours> <theirs>` prints the merge and its
  conflict markers without touching the working tree or the index, so the plan can name the conflicting
  files before anything is mutated. Its `changed in both` list is the *surface*, not the verdict: on 4.4
  it named twelve files and the cherry-pick actually conflicted on four.
- **A re-base never carries a patch to a package we consume.** The 4.4 line's hand-cursor fix (#1014)
  needed two changes inside `dependencies/markstream`, and the vendored patch was written and reverted
  on purpose: a local patch is the first thing the next re-base drops, and it makes the package's own
  gate measure a tree nobody else has. File it upstream
  ([Chevey339/kelivo#1269](https://github.com/Chevey339/kelivo/issues/1269)), record the gap in
  `docs/markstream-delta-audit.md`, and leave the mechanism alone.
- **A vendored package's gate needs a working directory, and `flutter test -C` does not exist.**
  `flutter pub get -C dependencies/markstream` works; `analyze`/`test` need the caller to *be* there. In
  the DSH sandbox that means a one-off `package.json` whose script `cd`s into the package and runs the
  three commands, deleted afterwards — and `flutter pub get` rewrites
  `dependencies/markstream/analysis_options.yaml`, so restore that file before the format gate.

## Verification of the `e15df5485` replay

Measured on Windows on 2026-10-23, in the order the gates were run. The point of the table is that
the next replay can compare against numbers instead of an impression.

| gate | result |
| --- | --- |
| `dart analyze --fatal-infos lib test integration_test` | No issues found |
| `flutter gen-l10n` | idempotent — `git status --short -- lib/l10n` empty |
| `dart format --output=none --set-exit-if-changed` (pinned Dart 3.13.0) | 0 changed of 2216 files — `lib`, `test`, `integration_test`, `dependencies/markstream/{lib,test}` |
| `flutter test` | **10005 passed, 62 skipped, 8 failed** — all eight the registered Windows golden cases |
| `dependencies/markstream`: `pub get`, `dart analyze --fatal-infos`, `flutter test` | No issues found; **296 passed** |
| `gradlew :app:testDebugUnitTest --tests '*BrowserWebViewHostTest*'` | BUILD SUCCESSFUL |
| `flutter build windows --debug` | `√ Built build\windows\x64\runner\Debug\cuplivo.exe` (778 s) |
| `gh workflow run release.yml -f publish_release=false` | run `40056162793`: macOS / Windows / Android / iOS / Linux **5/5 success** (the release-body job is skipped, by design) |
| `pr-check.yml` on the rewritten `master` | green — analyze, both packages' tests, l10n and the format step on `ubuntu-latest`, which is the only place the POSIX path assumptions are exercised in the direction this machine cannot |

The series itself: 15 replay units, the `docs(agents)` commit, and four tail commits — `fix(tests)`
×2, `fix(l10n)`, `feat(sync)` — which is 20 commits on top of `e15df5485`;
`git merge-base --is-ancestor e15df5485 HEAD` holds, no tag points at the tip, and `pubspec.yaml`
still says `4.3.0+6`.

## Verification of the `199647a5d` replay

Measured on Windows on 2026-10-24, in the same order as the table above, against the **committed**
lock (`flutter pub get --enforce-lockfile`) — which is what CI resolves too, so this table and the CI
run finally describe the same dependency set.

| gate | result |
| --- | --- |
| `dart analyze --fatal-infos lib test integration_test` | No issues found — after dropping three `!` that became redundant when upstream made `AppTextSelectionToolbar.buttonItems` non-nullable |
| `flutter gen-l10n` | idempotent — `git status --short -- lib/l10n` empty |
| `dart format --output=none --set-exit-if-changed` (pinned Dart 3.13.0) | 0 changed of **2224** files |
| `flutter test` | first run **10063 passed, 65 skipped, 9 failed**; after the `_waitUntil` deadline repair, **10064 passed, 65 skipped, 8 failed** — the eight registered golden cases and nothing else (against the baselines as they were; they have since been regenerated on ubuntu-24.04, so this machine now reports 0.67–2.07 % instead of 0.70–2.07 %, rule 16) |
| `dependencies/markstream`: `pub get --enforce-lockfile`, `dart analyze --fatal-infos`, `flutter test` | No issues found; **296 passed** |
| `gradlew -p android :app:testDebugUnitTest --tests '*BrowserWebViewHostTest*'` | BUILD SUCCESSFUL (119 s) |
| `flutter build windows --debug` | `√ Built build\windows\x64\runner\Debug\cuplivo.exe` (706 s) |
| `gh workflow run release.yml -f publish_release=false` | run `40075370914`: macOS / Windows / Android / iOS / Linux **5/5 success** (the release-body job is skipped, by design). The macOS job also ran the new Developer-ID sign and notarize steps, which no-op cleanly with no secrets configured |
| `pr-check.yml` on the rewritten `master` | three runs, and the story is rule 16: `40075337329` red on 13 ubuntu-only tests (5 browser cases with no engine there, 8 goldens generated elsewhere); `40078790202` after the browser guards — **10111 passed, 8 failed, 18 skipped**; `40079570731` at the tip `724affebc` — **green on every step**, the last two read against the CI image's own baselines |

The series is 14 replayed content units and four landing commits on top of `199647a5d` (§ *The
landing is 18 commits*); `git rev-list --count 199647a5d..master` prints the live total — it moves
with every follow-up commit, so this paragraph deliberately does not name it.
`git merge-base --is-ancestor 199647a5d HEAD` holds, no tag points at the tip, and `pubspec.yaml`
still says `4.3.0+6`.

Two failures on this replay belonged to the machine, not the tree, and neither changed a line:
`:mobile_scanner:compileDebugKotlin` died on a corrupted Kotlin incremental cache in the pub cache
(re-running that one task cleared it, with an `org.jetbrains.kotlin.incremental.storage` stack trace in
the log as the tell), and the first Windows link failed because `build/windows` still held objects
from the previous `record` version — deleting that directory was the fix.

### The landing is 18 commits
The replay closed at 35 commits: 14 replayed content units, then 21 tails written while the gates were
being cleared. Those 21 became four landing commits, so the next re-base replays 18 — and the pass is
proved by the tip tree, not by inspection:

| # | Landing commit | Folded in |
| --- | --- | --- |
| 15 | `fix: the new baseline's suite, fixtures and preference keys` | `0bb6bc952`, `6f4252bf5`, `8407fbc88`, `e4b111e31`, `71b0afa17`, `724affebc`'s fixtures and its one-off `regen-goldens.yml`, `379fd2b35` (`fix(l10n)`), `5efd382ff` (`feat(sync)`) |
| 16 | `chore(deps): the lock and the release wiring the gates run against` | `00d9c4580`, `f75363461`'s `.gitignore` line, `515e807e2` |
| 17 | `docs(rebase): the invariants and the 199647a5d record` | `2eda72787` (`docs(agents)`), `76993e753`, `956bec9fe`, `81271f940`, `e362f75bf`, `779452761`, `78436c40b`, `ea19c6cc1`, plus the document hunks of `f75363461` and `724affebc` |
| 18 | `style: reformat the files the pinned SDK lays out differently` | `41288ec37`, `7eb2cc808` |

Why those four and not fewer: the landing content cannot fold back into the unit that owns it — the
repairs touch test files units 3-14 own, so folding them into unit 2 would mean replaying the whole
series again — and the reformat must stay droppable (rule 10), so it is one commit of its own. Two
landing commits are the floor after that (the repairs and the record, which is what a 16-commit series
would look like); four is what keeps each concern reviewable. Sixteen is the floor overall: below it
the reformat would have to share a commit with a content unit and could no longer be re-derived.

The mechanism is one `git restore --source=<old-tip> --staged --worktree -- <paths>` per landing
commit, on top of the last unit. Each path belongs to exactly one of them, so materializing the tip's
content for it is exact — no patch is applied, so a formatting-only conflict cannot invent one. The
partition is 29 paths in 15, 5 in 16, 7 in 17 and 36 in 18 out of the 77 the tails changed; the only
deletion (`docs/homebrew/kelivo.rb`) goes through `git rm`, because `git restore` does not delete.

Prove it in this order — tree first, ancestry and count after, per the rule above:
`git diff --quiet <old-tip> <new-tip>`; `git diff --stat 6052bf812 <new-tip>` unchanged; then
`git merge-base --is-ancestor 199647a5d <new-tip>` and
`git rev-list --count 199647a5d..<new-tip>` = 18. The 14 units keep their hashes — nothing before
`6052bf812` moves — so a unit's message and tree are still the ones the table describes.

The landing changed no code: the only edits were these documents, so the green `pr-check` on the
pre-normalization tip stays valid evidence for the tree, and the push re-runs it on the new one.

### The baseline commits its lockfiles; a fork with extra packages seeds them
`199647a5d` commits `pubspec.lock` and `dependencies/markstream/pubspec.lock`, un-ignores both, and
switches `pr-check.yml` to `flutter pub get --enforce-lockfile`. That retires the whole class of failure
the `e15df5485` replay hit, where CI resolved a fresh dependency set on every run while a long-lived
worktree kept whatever lock it last wrote — the same tree, the same SDK, a different resolution:

1. **`drift 2.35.3` deprecates a member the committed schema emits.** `app_database.g.dart` was
   generated by `drift_dev 2.34.5` and calls `$_getPrefetchedData`; the 2.35 runtime deprecates it, so
   `dart analyze --fatal-infos` reported **7 infos in that one generated file** — red on CI, green
   locally. Regenerating with `drift_dev` 2.35 silences it, but the generated code then speaks the
   newer runtime, which is why that replay capped the dependency instead.
2. **`sqlite3 3.8.0` breaks the recycle bin.** A conversation delete stops staging its `RecycleEntry`
   rows: 13 cases across `recycle_conversation_test`, `recycle_cascade_test` and `recycle_draft_test`
   failed with an empty entry list, and two sync sessions re-deleted a conversation that was restored.
   Bisected: 3.5.1, 3.5.2, 3.7.0 and 3.7.1 pass, 3.8.0 fails deterministically — and it reproduced
   with the previous generated schema and `drift 2.34.4`, so the code generator was not implicated.

That replay left two ceilings in `pubspec.yaml`, each with its measurement in a comment. The next
baseline made them unnecessary: its lock pins `drift 2.35.3`, `drift_dev 2.35.2`, `sqlite3 3.5.2` and
`archive 4.5.2`, and its `app_database.g.dart` *is* drift_dev 2.35 output — so the `199647a5d` replay
deleted both ceilings while resolving the very commit that had added them. The measurement survives
here; the constraint does not need to.

**The rule for a fork:** it cannot inherit upstream's lock verbatim, because it adds packages upstream
does not have (`pdf`, `basic_utils`, `device_info_plus` here). Seed, then re-resolve once: the lock
arrives with the baseline, a single `flutter pub get` keeps every version it can still satisfy (all
four above stayed put) and adds only the fork's own packages, and that result is committed. Prove it
with `flutter pub get --enforce-lockfile` — exactly what CI runs — and put that command in the gate
list beside `dart analyze`. From then on a dependency bump is a commit that changes the lock, so a
regression like `sqlite3 3.8.0` cannot arrive without one.

Two things to know if you do regenerate the schema with `build_runner`:

- **It prunes `chat_message.g.dart` and `conversation.g.dart`.** Both are `part` files
  `chat_message.dart` / `conversation.dart` declare, and the current builder no longer emits them;
  `conversation.dart` says in a comment that its part file is *intentionally* stale. Restore both from
  git — deleting them breaks the compile.
- **Regenerate before the reformat, not after.** `drift_dev` writes its own formatting; the pinned
  `dart format` is what decides whether the committed file passes CI's format step, so check the
  regenerated file with it (`0 changed` here).

