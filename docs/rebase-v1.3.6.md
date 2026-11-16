# Re-basing Cuplivo on Kelivo v1.3.6

The 4.7 line. `v1.3.5` → `v1.3.6` is eight upstream commits, and the fork's own
line had moved twice since the 4.6 landing — so this round is mostly *carrying*:
the fifteen units the `00a2b7de0` round proved, plus the two commits that round
never contained.

- **Baseline**: upstream `master` at `c2b48958d`, tagged `v1.3.6`.
- **Fork history it reproduces**: `827b54d75` (the 4.6 landing) **plus**
  `5cdcccf15` (#1083) and `b091ffa2a` (#1084), which landed on `master` after
  that landing and which the `00a2b7de0` series therefore did not have.
- **Branch**: `reorg/series-v1.3.6`.
- **Version**: `4.7.0+10` (4.4.0+7 → 4.5.0+8 → 4.6.0+9 → 4.7.0+10).

## 1. The window, measured

```
git log --oneline --no-merges 00a2b7de0..v1.3.6     # 8 commits
git diff --shortstat 00a2b7de0 v1.3.6               # 72 files, +3484 −868
```

- **No dependency changed**: `pubspec.yaml` differs by the version line alone.
- **No file deleted, none renamed**, four added: `deepseek_endpoint.dart`, the
  built-in-prompt assembly test and its two fixtures.
- **Six ARB keys** (`asrServicesDeepSeekSubtitle`, `homePageDeleteOtherVersions`,
  its confirm text, the two reply-bubble labels, `ttsServicesDeepSeekVoice`) and
  one changed value (`legacyMemoryModeCacheWarning`).
- Eight commits, but they land in the fork's rewrite surface: `chat_service`
  (103 lines), `home_page_controller` (119), `message_builder_service` (233),
  `chat_message_widget`, `message_more_sheet` (105), `settings_provider` (28),
  `chat_database_repository` (58), plus every ARB and its generated files.

## 2. The replay: predicted versus paid

Before touching anything, a per-commit three-way merge (`git merge-tree
--write-tree --merge-base=<parent> v1.3.6 <commit>`) over the fifteen commits
predicted **62 files where both sides changed** and **93 conflict rows**, and
named the hot ones. It also inflated the count, because it measured against
trees that still spelled `package:Kelivo/`.

What the real `git rebase --onto` cost:

| stop | commit | conflicts | resolution |
|---|---|---|---|
| 1 | identity | 5 files | `apply(substitutions, v1.3.6)` for the four code files; our `pubspec.yaml` (upstream changed only its version line) |
| 7 | links | 2 files | both menu entries kept; the upstream "8 rows" assertion becomes 9 on mobile, its height bound 400 → 448 (measured 434.5) |
| 14 | reformat | 1 file | dropped: upstream had already laid `image_viewer_page.dart` out that way |
| — | the other 12 | 0 | applied clean |

So the census was right about *where* and four times pessimistic about *how
much*: thirteen of fifteen commits went in untouched, and the two that stopped
needed seven files and two edits.

The reformat unit is **re-derived, not replayed**: at the new tip
`dart format --set-exit-if-changed` named exactly the same five files the 4.6
line reformatted, and `image_viewer_page.dart` was no longer among them. The
commit is therefore five files, not six, and the tree after it is canonical.

## 3. What the baseline's own suite found

The first full run at the replay's tip was **+13826 ~94, nine failures**. Seven
were one cause, two were another, and neither was our code's:

- **An unregistered preference key.** Upstream's optional reply bubble writes
  `display_show_assistant_body_bubble_v1`, and the fork's registry has a row for
  every key the app writes. Without one, the gate
  (`business_key_registry_sync_test`: "every preference key the app writes has a
  row") failed, and five widget cases died in the same assertion —
  `business_preferences.dart:232: Unregistered preference key`. The row is
  `backupOnly` / `deviceViewState`, like every other `display_show_*_v1`.
- **Two Windows path spellings in the storage view.** Upstream's new
  `storage_space_images_test` keys a thumbnail row by
  `storage-image-<path>` and compares that with the path the fixture wrote.
  `AppDirectories` builds `'<root>/upload'`, so the row carries
  `<root>/upload\<name>` while the fixture wrote `<root>/upload/<name>`; the two
  differed by one separator and both thumbnail cases timed out waiting for a
  decode that had already happened. The fixture returns
  `p.normalize(p.join(...))`, the tile keys the row by the normalised path, and
  the avatars case normalises the key it builds from `AppDirectories`.

**One attempt was made and reverted.** Normalising the *entry* path in
`listUploadEntries` fixed the two cases and turned an Android filter case red:
that same string is what the recycle bin and the attachment-usage map compare,
so normalising it changed what "in use" means. The normalisation stays at the
key, where it is a test identity and nothing else. This is the blast-radius rule
in `AGENTS.md` paying for itself: one line, two callers, opposite verdicts.

## 4. The two units the series never had

`b091ffa2a` is not an ancestor of the 4.6 landing, so the `00a2b7de0` series
reproduced `827b54d75` — not the branch it was cut from. Both commits are
Cuplivo-only (sync, recycle, skills), so they replay onto the new baseline with
very little friction:

| unit | commit | size | conflicts |
|---|---|---|---|
| 16 | `5cdcccf15` #1083 | 28 files, +2231 | 1 import (`data_sync.dart`), 4 l10n state files |
| 17 | `b091ffa2a` #1084 | 30 files, +2395 | 3 imports, `main.dart`'s indentation, 4 l10n state files |

- The imports are the fork's own move of `business_state_reloader.dart` from
  `core/services/sync/` to `core/services/`, which our line had already made.
- `main.dart` came out of the merge with our deeper nesting and without
  `skillsRoot:`; the argument was added back by hand (`recycle:` had merged in).
- The `tool/l10n/state/*.json` conflicts are resolved **in our favour**: a key
  with no state entry is "pending", which is exactly how the other 79 wait for
  `translate.py sync`. Their two new keys join that queue.
- `flutter gen-l10n` was re-run so the generated files carry both keys.

## 5. Where a repair lives, and why it matters

A mid-series repair belongs to the unit that owns the file, not to the tip:

- the registry row → **unit 4**, the commit that introduces
  `BusinessKeyRegistry.rules`;
- the storage fixture and the normalised key → **unit 2**, the commit that
  already owns "the new baseline's suite on Windows".

A commit is amended without an interactive rebase: build its tree from the file
edits, `git commit-tree` it onto the same parent, and
`git rebase --onto <new> <old> <branch>`. The replay is deterministic (the tree
delta is three files), and it was run twice here — once for unit 2, once for
unit 4 — with no conflict either time.

The unit-2 message also lost a duplicated block: the 4.6 fold had appended the
identity-tool body twice, and the second copy is gone.

## 6. The sixteen, as built

```
dcecd495b  feat!: Cuplivo identity on the Kelivo v1.3.6 baseline
88984da43  fix(tests): the new baseline's suite — Windows and the backup staging rework (#1032, #1041)
68b6c0a29  feat(recycle): a recycle bin for deletions, losing merges and workspace files (#1035)
8f764cf1a  feat(sync): LAN sync, the dual stack, candidate probing, and one policy table (#932, #947, #952, #1030, #1037, #1068)
ca9f1c5c6  feat(sync): a restore is an edit — protocol v8, and the bin's sync half
9069e89be  feat(care): 「Ta的来信」, the roleplay tab, and a letter that survives the freezer (#935, #976, #996, #1007, #1008, #1016, #1064)
d42fe35ac  feat(chat): one link for a conversation and a message (#1013, #1034)
77ede69d6  feat(export): a PDF laid out from markstream's tree, no WebView and no second renderer (#1028)
494c43c03  feat(translate): the visible target set is the user's, Bengali included (#1039)
2616f068e  feat(suggestions): a chat-suggestions switch per assistant (#1024, #1040)
221bdf909  feat(group-chat): topics, the director, the roster, and one owner order (#1052, #1074, #1072, #1081)
d8c4169a5  feat(backup): a backup written for a named reader — Kelivo can import it again (#1071)
4bc556672  feat(markdown-image): one clean picture, one tab's input (#1075, #1077)
7aeff339d  refactor(sync): a premise is re-read where it is used (#1083)
097505f23  refactor(sync): one owner for a skill body's shape, disposal and clock (#1084)
bbf2b9b89  style: reformat the files the pinned SDK lays out differently
```

Then `chore(release): Cuplivo 4.7.0` and this record.

## 7. The definition of done, as measured

| check | this tree |
|---|---|
| `dart analyze --fatal-infos lib test integration_test` | clean at unit 1, unit 2, unit 7, the #1084 tree and the tip |
| full `flutter test` at `fix(tests)` | **+12817 ~94, all passed** |
| full `flutter test` at the tip | **+13894 ~94, all passed** (the tree the release commit sits on — the commits above it change the version, the changelogs, `AGENTS.md` and this record) |
| `flutter gen-l10n` | idempotent (byte-identical second run) |
| `dart format --output=none --set-exit-if-changed` | 2741 files, 0 changed |
| `flutter pub get --enforce-lockfile` | green, root and `tool/l10n` |
| `python tool/identity/verify.py --forward` | clean against `v1.3.6` |
| `--exact` at the identity commit | 1516 mechanical + 67 path-moved files, 0 mismatches |
| units 16–17's own suites | 1206 passed, 27 skipped |
| `pr-check.yml` at `8f97c4237` | green in 45m45s: format, gen-l10n idempotency, `translate.py check`, identity sweep, analyze, both test suites |
| `translate.py check` | green measured, not estimated: 0 pending in ru, ko, tr and zh_Hant after the sync |
| `flutter build ios --release --no-codesign` | green — 12m18s in the dry run, 11m44s in the release run (see §9) |

Two notes on the identity check. `--forward` and `--inverse` are the tip's
checks; `--exact` is an *identity-commit* check, because the mechanical set is
defined against the baseline and later units legitimately edit those files
(fifteen of them at the tip). And the identity unit caught the documented blind
spot again: upstream's new `built_in_prompt_assembly_test.dart` arrived with
27 `package:Kelivo/` imports, which no conflict signals.

## 8. Open when this record was written

Three items were open at the landing; all three are closed now, and §9 says how.

- `translate.py check` was red: **82 pending / 5494 messages** in each locale,
  with **71 keys carrying no state entry** (`Wrong keys: 71 missing`). The values
  were there — the replay carried them — so this was the tool's *freshness*
  record, not missing translations.
- `master` was not yet moved and the tag was not cut; both were the owner's step.
- `pubspec.yaml`'s build number and both changelogs were already in the release
  commit, so only the tag was missing.

## 9. What the landing paid after it was pushed

Five commits followed the landing commit, and the ones that matter were for
defects **no local gate could have found**. Two of those defects had shipped
before this pass began.

```
5ecbfcf01  fix(ios): the project names the source files that exist
6ecad1d9e  chore(l10n): sync the strings the re-base left stale
f1f67368b  docs(changelog): the 4.7.0 entry, rewritten
d1913027b  docs(changelog): drop the protocol-bump claim from 4.7.0
8f97c4237  fix(l10n): the ru/ko/tr permission strings regain the local-network line
```

**iOS had been unbuildable since 4.6.0.** `ios/Runner.xcodeproj/project.pbxproj`
named 15 files `Cuplivo…` — 44 filename literals — while the tree and every source
that mentions them say `Kelivo…` (211 `KelivoISH`, 21 `KelivoGeneration…`, no
`Cuplivo…` in either). Xcode stopped at the first one:

```
Error (Xcode): Build input file cannot be found:
.../ios/Runner/CuplivoGenerationActivityAttributes.swift
```

`v4.6.0` (`4cda01e4f`) carries the same mismatch, introduced by the old line's
identity commit `cdfc60a02`; that release's iOS job was *cancelled* rather than
failed — macOS was cancelled in the same run — which is why nothing said so. Its
nine assets are three APKs, four Linux packages and two Windows ones: no `.ipa`,
no `.dmg`.
The repair reverts the 44 literals (`5ecbfcf01`) rather than renaming 15 files,
because the Swift type, the ObjC symbols and their includes all still say
`Kelivo`. Proof: a sweep of every `path = …;` in the project against the tree
reports no missing source file, and CI then built the app twice — 12m18s as a dry
run on `f1f67368b`, 11m44s in the release run.

**The native l10n state attested a file from another lineage.** `check` failed
next with `Wrong keys: 1 missing ['ios.NSLocalNetworkUsageDescription']`, once per
locale. The key belongs to the plist entry the LAN sync unit adds, and upstream
v1.3.6 ships `InfoPlist.strings` for *its own* plist, which has 13 keys, not 14.
`tool/l10n/state/native_{ru,ko,tr}.json` came from the released line, whose digest
was computed with the key present, so it matched today's sources and
`native_sync` returned before writing anything: `sync` could never repair it, and
only CI's `check` was saying so. The three lines are the released line's own
(`b091ffa2a`), whose source text is byte-identical to today's plist entry; after
restoring them, all three locales measure 25 native keys wanted, 25 present,
nothing extra (`8f97c4237`).

**The sync itself, measured.** `sync` against `api.deepseek.com` with model
`deepseek-flash` cost 31342 tokens for four locales × 82 messages — 71 keys absent
from each target ARB and 11 whose source fingerprint had moved.
`app_zh_Hant.arb` additionally lost 49 `@key` blocks that `app_en.arb` does not
carry: the tool keeps exactly the template's key set, and `check` had never
reached zh_Hant because it fails on ru first. The tool writes through a text-mode
handle, so on Windows all eight rewritten files came back CRLF and each diff read
10921 lines; they were returned to LF byte by byte before the commit.

**The release.** `v4.7.0` is a lightweight tag on `8f97c4237`, like `v4.6.0`;
`v4.6.0` stays at `4cda01e4f`. `release.yml` ran from the tag (`43741482320`):
Android, iOS, Linux, macOS and Windows all green, the release-notes job wrote the
body from the two changelogs (Chinese block, then English), and eleven assets were
published — including `Cuplivo_ios_4.7.0+10.ipa`, the first iOS artifact since
`v4.5.0`; `v4.6.0` shipped neither an `.ipa` nor a `.dmg`.
