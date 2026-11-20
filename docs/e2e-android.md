# Android E2E: incremental PR acceptance

This is the fork's on-demand Android acceptance run. When a UI PR asks for it,
a disposable emulator boots the production app, drives the PR's changed
acceptance scenario, and publishes screenshots, a screen recording, a short
key-operations clip and an installable debug APK.

The harness is deliberately **not** a visual-regression suite:

- there is no fixed screenshot set and no pixel comparison;
- only the acceptance scenario added or modified by the PR runs;
- a scenario is normal repository code, so it merges and stays dormant unless
  a later PR changes it;
- a UI PR that does not change a scenario skips the emulator entirely.

The goal is to replace “build the branch locally, then click through the new
screen” for the PR's own UI, not to re-review the whole app on every PR.

- Workflow: `.github/workflows/e2e-android.yml`
- Example scenario: `integration_test/e2e/example_acceptance_test.dart`
- Shared setup: `integration_test/e2e/acceptance_support.dart`
- Fixture: `test/support/e2e_app_seed.dart`
- Driver: `test_driver/e2e_review.dart`
- Decision record: [ADR-0019](adr/0019-automated-android-e2e.md)

## How to request a run

The run is **not** part of every PR check. It starts only when someone asks for
it:

| request | who | result |
|---|---|---|
| comment `/e2e` on the PR | PR author, or an owner/member/collaborator | run + sticky comment with screenshots/video and artifact links |
| add the `run-e2e` label | anyone with triage permission | same as above for a same-repository PR; a fork PR gets artifacts only (its `pull_request` token is read-only) |
| Actions → Android E2E → Run workflow | anyone with write access | optional `pr_number` plus an optional `target`, or a `ref` plus a required `target`; a PR run comments, a ref-only run does not |

Notes:

- `/e2e` also works for fork PRs: the workflow is taken from the default branch
  and only checks out the fork's commit into a read-only job.
- Adding the label again after the first run does not retrigger it. Remove and
  re-add it, or comment `/e2e`.
- Draft PRs are allowed to request a run; a run is never started
  automatically.
- The sticky comment has the header `android-e2e`, so the latest attempt
  updates the same comment instead of adding another one.
- A skipped request also updates that comment, so the PR never silently ignores
  `/e2e`.

## Incremental contract

The `request` job lists the PR's changed files with the paginated GitHub
pull-files API (fork-safe). It keeps added/modified files matching exactly:

```text
integration_test/e2e/<name>_test.dart
```

Then:

| changed scenarios | result |
|---|---|
| 0 | skip; no build, no emulator; comment explains how to add a scenario |
| 1 | build and drive that file only |
| more than 1 | skip; ask the author to consolidate or split the PR |

One target per PR is deliberate. It keeps one test APK build, one emulator
session, one recording and one reviewable comment. If a feature needs several
flows, put them in one scenario file; if it needs several unrelated
acceptances, split the PR.

The selection is **file-level**, not screenshot-level. A one-line change runs
the whole scenario, which is why scenarios must stay small.

A change only to `acceptance_support.dart` or `e2e_app_seed.dart` does not
select a scenario. Use a manual dispatch with an explicit `target` when changing
shared harness code.

## Add a scenario for a UI PR

1. Copy `integration_test/e2e/example_acceptance_test.dart` to
   `integration_test/e2e/<feature>_acceptance_test.dart`.
2. Keep one app boot per file. Use `bootSeededApp` from
   `acceptance_support.dart`.
3. Navigate to the new UI, assert the state, and call `capture` for the one or
   two frames a reviewer needs. A typical scenario captures 1–3 screenshots.
4. Do not add a light/dark matrix or a tour of unrelated screens. This harness
   is not the place for a fixed regression walkthrough.
5. Request `/e2e` on the PR.

```dart
testWidgets('feature acceptance scenario', (tester) async {
  await bootSeededApp(tester, binding);

  // Navigate to the new UI and assert what the reviewer should see.
  expect(find.byType(MyNewPanel), findsOneWidget);
  await capture(tester, binding, 'my_new_panel');
});
```

The old scenario files stay in the repository. They are not rerun on every PR,
so they do not become a maintenance or runtime tax. Delete a scenario only when
the UI it covers is removed.

## What a run produces

| artifact | contents |
|---|---|
| `e2e-screenshots` | `screenshots/*.png` from the changed scenario, `failure-screenshots/*.png` when the run failed |
| `e2e-video` | `e2e.mp4` (or `.webm`), `highlights.mp4`, `preview.gif`, `record.json` (artifact root) |
| `e2e-logs` | `logs/flutter-drive.log`, `logs/logcat.txt`, `logs/logcat-tail.txt`, `index.html`, `summary.md`, `pr-comment.md` |
| `cuplivo-debug-apk` | `Cuplivo-debug-arm64.apk`, a debug build of the requested commit |

The job summary lists the status, duration, scenario path, captured names and
artifact names. `e2e-logs` contains a self-contained `index.html` gallery:
download the artifact, unzip and open it.

The sticky comment inlines at most six screenshots; a scenario that captures
more gets the first six plus a pointer to the artifact. The artifact branch
still contains every PNG.

## Video

`tool/e2e/run_android_e2e.sh` records the device screen around the `flutter
drive` invocation with `adb shell screenrecord` (180-second cap). The driver
writes a host timestamp for each screenshot to
`screenshots/screenshots.json`; `tool/e2e/make_highlights.py` cuts a short
key-operations clip and a GIF preview from that window. The full recording is
still uploaded when the clip fails.

The recording is device-level, so it includes the app under test only; native
dialogs, the IME and the status bar are not in the Flutter-surface screenshots.
Keep scenarios short so the recording stays reviewable.

## Security model

- `run` checks out and executes the PR commit with `contents: read` only.
- `publish` never executes PR code. It downloads the run's artifacts, validates
  PNG/MP4/GIF headers and size caps, pushes them to a per-PR
  `e2e-artifacts-pr-<n>` orphan branch, and posts/updates the sticky comment.
- `skip` only posts the “why nothing ran” comment; it has
  `pull-requests: write` and does not checkout PR code.
- The repository has no PAT and no `pull_request_target` in this workflow.
  `/e2e` uses the default branch's workflow, which is also the universal path
  for fork PRs. A fork label run gets a read-only token, so publishing is
  skipped there.
- Artifact validation happens before anything is published; a malformed or
  oversized artifact fails the publish step instead of reaching the comment.

## Operational notes

- Job timeout: 45 minutes; a normal incremental run is about 15 minutes.
- Artifacts and the PR artifact branch are retained for 14 days; closing the PR
  deletes the branch, so old comment images stop resolving after cleanup.
- The workflow needs to exist on the default branch before `/e2e` can be used.
  On the workflow's own pre-merge PR, use the `run-e2e` label or
  `workflow_dispatch` with an explicit target.
- The emulator profile is API 36, `pixel_7`, `google_apis`, `x86_64`,
  SwiftShader, with animations and the spellchecker disabled.
- The cleanup workflow runs on PR close and weekly; it deletes the per-PR
  artifact branch.

## First-run checklist

1. The changed scenario is the only one selected; no other `integration_test/e2e`
   file was driven.
2. The scenario asserts the new UI before calling `capture`; a screenshot is
   evidence, not the assertion.
3. The comment shows the scenario path, 1–3 screenshots (at most six inline),
   a working GIF/video link and the debug APK artifact.
4. A run with no changed scenario skips without starting an emulator and leaves
   a clear comment.
5. A fork PR run shows artifacts and skips the comment job without failing.
6. The recording is present and covers this scenario, not a fixed app tour.
7. `python3 tool/e2e/test_build_report.py` passes in `pr-check.yml`.

## Real-DSH acceptance endpoint

The Android E2E run can exercise a **real DeepSeek Harness server** for
same-repository PRs. The `request` job resolves the PR head repository through
the pull API (or `pull_request` metadata); only when it is this repository does
the `run` job receive `E2E_DSH_URL` and `E2E_DSH_TOKEN` from repository secrets
of the same names. A fork PR, and any run where the head origin cannot be
proven to be this repository, gets neither value.

The values reach the app as compile-time Dart defines from a `0600` JSON file
(`--dart-define-from-file`), never as command-line arguments, and the file is
deleted right after the build. A scenario reads them with
`String.fromEnvironment('E2E_DSH_URL')` / `String.fromEnvironment('E2E_DSH_TOKEN')`:

| defines | scenario contract |
|---|---|
| both empty | hermetic run: boot, navigate and capture as usual; skip only the assertions that need a live server (or use the in-process stub); must pass |
| both set | real run: connect, create a session, send one prompt, assert the streamed answer, capture the screenshots |
| exactly one set | misconfiguration: fail with a clear message instead of silently running hermetically |

`E2E_DSH_URL` is the base root (`https://<host>:<port>`, no token, no trailing
slash); `E2E_DSH_TOKEN` is the DSH launch token (minted per DSH process, so it
rotates with every server restart). Compose the connection URL in the scenario
as `$E2E_DSH_URL/?token=$E2E_DSH_TOKEN` when the connection form takes the
tokenized URL.

When the endpoint is configured for a same-repository run, a second job,
`dom-contract`, proves the official-WebUI DOM recipes the app ships: it prints
them with `tool/e2e/print_dsh_surface_scripts.dart` and runs
`tool/e2e/dsh_dom_contract.js` — a dependency-free Node script that drives the
runner's desktop Chrome at phone width (412×915) over the DevTools protocol —
against the live Host. It asserts the harvested sidebar rows, right-rail cards,
settings sections and the three landing recipes (sidebar row, rail card, 更多).
This job exists because the Android emulator's Chromium renderer exits within
seconds on that single-page app, so the emulator run can only assert the honest
fallback; the DOM contract is where "the generic compatibility works against
the real Host" is proven, and it needs the same two secrets but no emulator.
The job logs `[dom-contract] ok …` / `FAIL …` lines and skips itself when the
secrets are absent.

Two preflight steps run before the build and fail in seconds when the endpoint
is unreachable or the token is stale. A step after the run deletes any artifact
that contains the token and fails the job, because `e2e-logs`, screenshots,
video and the review APK are published. The endpoint is operator
infrastructure: its address and token live outside this repository.

### Requesting a real-endpoint run

A same-repository PR gets a real-endpoint run by asking for E2E the normal way
(`/e2e` comment, `run-e2e` label, or a workflow dispatch with the PR number).
Nothing else is needed: the request job resolves the PR head repository through
the pull API, and a same-repository head receives `E2E_DSH_URL` /
`E2E_DSH_TOKEN` from repository secrets automatically. A fork PR never
receives them and runs the hermetic path.

The endpoint is operator infrastructure and can be rotated or down. When it
is, the run fails in seconds at **Preflight the real-DSH endpoint** with the
reason (rejected launch token versus unreachable host) instead of failing later
inside the emulator, and the hermetic fallback still produces UI evidence.

### After this wiring lands on master

A feature PR needs no per-PR configuration: `/e2e` runs the default branch's
workflow, so once the wiring is on `master` a comment on a same-repository
feature PR exercises the real endpoint with the scenario from that PR's head
commit. Refresh `E2E_DSH_TOKEN` only after the DSH server itself restarted;
the workflow preflight names that condition when the token is stale.

## Limits

- One acceptance target per PR; multiple changed scenario files are rejected
  with guidance.
- File-level incrementality: no attempt to select individual screenshots from a
  diff.
- Shared helper/seed changes do not auto-select a scenario.
- No pixel/golden comparison, no light/dark matrix, no fixed six-screen
  walkthrough.
- The pull-files API is paginated; PRs with more than 3000 changed files are out
  of scope for this repository.
- Flake policy: the run is hermetic by default (no network, no credentials,
  seeded database, fixed device profile, bounded pumps) and stays that way on
  fork PRs; a same-repository run may additionally reach the real DSH endpoint
  described above. Do not add automatic retries to hide flicker; quarantine a
  provably harness-flaky step with an issue link, following
  `docs/flaky-tests.md`.
