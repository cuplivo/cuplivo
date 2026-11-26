# ADR-0019: On-demand, incremental Android-emulator E2E

**Status:** Proposed (2026-11), revised for incremental PR acceptance
**Deciders:** cuplivo

## Context

Acceptance for this fork depends on two things a unit test cannot show: what
the new UI looks like and whether the changed flow still works end to end.
Today both are manual: a PR arrives, `pr-check.yml` runs static analysis and the
unit suites, and a maintainer builds a debug APK, installs it, and clicks
through the changed screens. That loop is slow, is repeated for every UI PR,
and produces no durable evidence beside the diff.

The constraints that shape a solution:

- `pr-check.yml` runs `dart analyze`, `flutter test`, l10n and format gates on
  `ubuntu-latest`, but **no Gradle task at all**; an Android build break is
  currently found at release time (or by hand).
- Flutter is pinned (`3.47.6`), the root lockfile is enforced, and the repo
  already has a large `integration_test/` tree with a documented screenshot
  driver.
- Pixel/golden suites were tried here and retired: rasterisation, fonts and
  the host image make them flaky (`docs/flaky-tests.md`). A screenshot layer
  must not repeat that mistake; the deliverable is evidence for a human, not a
  pixel verdict.
- The repository is public. Standard Linux GitHub-hosted runners support KVM
  and are free for public repositories, so an emulator job is affordable;
  macOS runners are not (iOS is out of scope).
- A full emulator run costs 10–20 minutes. Running it on every push would slow
  every PR and burn runner time for docs-only changes. It must be opt-in.
- Fork PRs get a read-only token on `pull_request`, which rules out posting
  images in comments from the test workflow itself.
- A fixed six-screen walkthrough was piloted. It proved the screenshot/video
  pipeline, but it made every E2E run re-review unrelated surfaces, produced a
  fixed screenshot set that invited visual-regression expectations, and did not
  answer the question the maintainer actually has: “does this PR's new UI
  work?” It also accumulated stale screens and required per-PR test edits.

## Considered options

| option | why not chosen |
|---|---|
| Golden tests (`flutter test`, host Skia) | headless widget trees, not the production app; fonts/renderer differ between host and device; this repo already retired a golden layer for exactly that reason |
| `flutter test integration_test/... -d emulator-5554` | no driver, so `binding.takeScreenshot` bytes never reach the host; no video |
| Maestro | black-box YAML flows on the compiled APK; good screenshots/video and system dialogs, but requires a second tool and Semantics identifiers across the app, and would not reuse the existing `integration_test/` code |
| Patrol | native Espresso/XCUITest harness, excellent for permission dialogs, but its own CI documentation recommends device labs over default runners; adds a dependency and a second test DSL |
| Firebase Test Lab / emulator.wtf | most stable emulator and built-in video, but moves the tests out of the workflow, needs a billing account and secrets, and is harder to run locally |
| `/e2e` via `peter-evans/slash-command-dispatch` | mature ChatOps action, but it requires a PAT secret; a GITHUB_TOKEN cannot create the dispatch event it relies on |
| Run on every `pull_request` | 10–20 minutes per push; docs-only changes do not need an emulator; required-check latency would be unacceptable |
| Fixed six-screen walkthrough | piloted; always reruns unrelated screens, invites a visual baseline, and does not scale with UI changes |
| **reactivecircus/android-emulator-runner + `flutter drive` + one changed acceptance scenario + `adb screenrecord`, triggered on demand** | chosen: first-party `integration_test` code, no new test framework, free Linux runner, screenshots through the documented driver path, artifacts are plain PNG/MP4, and the PR pays only for its own acceptance |

## Decision

1. **One workflow** (`.github/workflows/e2e-android.yml`) with three request
   paths: `/e2e` PR comment (author or collaborator), the `run-e2e` label
   (same-repository PRs can comment; forks get artifacts), and
   `workflow_dispatch` (optional PR number; an explicit target is required for a
   ref-only run). It never runs on ordinary pushes.
2. **Incremental target selection.** The request job lists the PR's changed
   files with the paginated GitHub pull-files API (fork-safe) and keeps
   added/modified files matching `integration_test/e2e/<name>_test.dart`.
   Exactly one changed scenario is driven; zero skips the emulator; more than
   one skips with a request to consolidate or split. Selection is file-level,
   not screenshot-level.
3. **One scenario per file, one target per PR.** A scenario boots production
   `main()` against a temporary path-provider root and a seeded Drift database,
   navigates to the new UI, asserts it, and captures 1–3 screenshots. Scenario
   files are normal repository code: they merge, stay dormant unless changed,
   and are deleted only when their UI is removed. There is no fixed six-screen
   walkthrough and no per-merge test cleanup.
4. **Screenshots use the documented integration-test recipe**:
   `convertFlutterSurfaceToImage()` then `binding.takeScreenshot`, with the
   driver writing PNGs. The comment inlines at most six; the artifact branch
   keeps all PNGs. Failure screenshots are separate.
5. **Video is device-level**: `adb shell screenrecord` records the drive
   invocation; the driver's screenshot timestamps cut a key-operations clip and
   GIF preview. GitHub cannot embed MP4 in a comment, so the comment shows the
   GIF and links the recordings.
6. **Artifacts are the source of truth**: `e2e-screenshots`, `e2e-video`
   (including highlights), `e2e-logs` and `cuplivo-debug-apk` (arm64 debug
   build of the requested commit). The debug APK gives reviewers back the
   “manual build” step.
7. **Comments are posted from a separate job with `contents: write` and
   `pull-requests: write`.** It downloads the run's artifacts, validates
   PNG/MP4/GIF headers and size caps, pushes them to a per-PR
   `e2e-artifacts-pr-<n>` orphan branch, and posts/updates one sticky comment
   with raw URLs. The job that executes PR code has `contents: read` only.
   A small `skip` job posts why no emulator ran; it does not checkout PR code.
8. **No PAT and no `pull_request_target`.** `/e2e` uses the default branch's
   workflow and is the universal path for fork PRs; the read-only fork token
   is never given write access.
9. **Advisory, on demand.** It is not a required check. The pilot measures
   duration and flake rate; making it required is a separate decision after
   the harness has a history.

## Consequences

**Positive**

- Reviewing a UI PR no longer requires a local build: the changed scenario's
  screenshots and recording answer “what does the new UI look like” from the PR
  page, and the debug APK is available for clicking.
- Only the PR's own acceptance scenario runs, so unrelated screens do not
  consume reviewer attention or emulator time.
- The debug build check puts Gradle back into PR CI, so an Android build break
  is caught before release.
- Scenario files are versioned and dormant; they do not need to be deleted
  after each merge.
- The harness reuses existing `integration_test` patterns and the existing
  screenshot driver shape; no new test framework or service.
- The cost is opt-in and proportional: a docs-only PR pays nothing, and a UI PR
  pays for one scenario.

**Negative / accepted**

- 8–20 minutes of a free Linux runner per requested run, and a flake surface
  (emulator boot, SwiftShader rendering, screenrecord).
- Screenshots only cover the Flutter surface; native dialogs, IME and status
  bar are not in them. They are also not a pixel diff, so a human still judges
  the change.
- A UI PR that changes no scenario file is skipped. Authors must add one; the
  skip comment and PR template say so.
- Changing `acceptance_support.dart` or `e2e_app_seed.dart` alone does not
  select a scenario; a manual dispatch target is needed to exercise shared
  harness changes.
- The artifact branch stores only the latest run per PR, and closing the PR
  deletes it; old comment images stop resolving.
- A fork PR triggered by the `run-e2e` label cannot be commented on; `/e2e` is
  the path for that case.
- CI does not exercise the release renderer if the Impeller fallback is needed
  to make surface captures work; that gap is documented rather than hidden.

## Follow-ups

- Measure the pilot; then decide whether the check should become required.
- Revisit AVD snapshot caching (the emulator-runner README recipe) if boot
  dominates the duration.
- Revisit multi-target runs only if real PRs repeatedly need them; today one
  target keeps the workflow and the review simple.
- Consider a chat parsing action only if a maintained action stops requiring a
  PAT; today the lightweight `issue_comment` handler is the smaller risk.
- iOS simulator remains out of scope.
