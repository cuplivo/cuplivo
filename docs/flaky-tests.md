# Flaky tests

Tests that can pass or fail with no code change, gathered from CI history and a local
run. Measured at `b607c7f00`. Written before any fix landed, so every section is the
evidence as found; what has since been fixed is tracked under **Status** below, and no
claim here was softened to match a fix.

The point of the list is triage: a red PR check currently costs roughly as much time as a
real regression, because the same handful of tests fail, pass, and fail again on
unchanged code. Everything below is either **reproduced** (with the command), **read in
source**, or marked as **not reproduced**.

## Status

**Fixed** — each with the root cause the section below names:

| what | fix |
|---|---|
| §2 — the `'401'` substring probe in `lib/core/providers/mcp_provider.dart` | a URL is stripped from the text and `401` is matched with digit guards, extracted as `mcpErrorTextLooksUnauthorized` and pinned by `test/core/providers/mcp_auth_text_test.dart` |
| §3 — `chat_input_bar_attachment_cleanup_test.dart` › 源文件删除失败会记录日志且保留源文件 | the test waits for the release it asserts on (`debugHasPendingArtifactDeletes`) instead of polling a log for 2 s; it also runs on Windows now, via an open handle rather than `chmod` |
| §3 — `chat_input_bar_attachment_cleanup_test.dart` › 超过 5000 个字符的粘贴内容转为文本附件 | the fixed 100 ms delay is gone; the test waits for the long-paste write tail (`debugTextPasteWriteSettled`), which the paste path completes only *after* it has released the file |
| §3 — `restore_bundle_staging_test.dart` › does not delete candidate while the revalidation isolate has not exited, and its db-isolate sibling | the test-only native-sleep hang now precedes the isolate's first cancel check, so the isolate provably cannot exit before the host abandons it |

Verified with Dart 3.13.0 (the SDK CI pins): `dart format` clean and
`dart analyze --fatal-infos lib test integration_test` clean over the whole project; the four
affected files green, and the full local suite re-run (see §4). The regression test for §2
was shown to fail against the pre-fix implementation before it was accepted.

**Deliberately not changed** — each was in the inventory, and each turned out to have a
reason not to touch it:

* **`sync_engine_integration_test.dart` `_unusedPort()` and the port-release rebinds in
  `mobile_loopback_oauth_test.dart`.** The fix on paper is to hold the socket open, but that
  changes what the test exercises: a bound-but-silent socket *accepts* the connection and
  stalls it, whereas "nothing is listening" gets an immediate refusal, and several of those
  cases assert on the refusal. Holding the port would trade a rare flake for different
  behavior. A correct fix keeps the port free *and* stops anyone else claiming it, which
  needs per-worker port reservation rather than a one-line change.
* **The 250 µs spin at `chat_actions_stream_subscription_test.dart:70-71` is load-bearing.**
  The test asserts that a busy burst yields an event-loop turn *before* draining; the spin
  blocks the thread without yielding, which is what makes that assertion meaningful instead
  of self-satisfying. Replacing it with an `await` would have the test prove that its own
  `await` yields. It costs ~64 ms of CPU and cannot fail for timing reasons — a slower spin
  only makes `processedBeforeTimer` smaller, which is the direction the assertion wants.
* **The fixed ports `1455` (`chatgpt_browser_oauth_test.dart:96`) and `54545`
  (`claude_oauth_test.dart:279`).** Both tests exist to prove fallback *away from the real
  preferred port*, and one asserts `redirect_uri == 'http://localhost:1455/auth/callback'`.
  Injecting a port means threading a preferred-port parameter through
  `ProviderOAuthService` / `ClaudeOAuthAdapter` and weakening that assertion. Neither has
  ever gone red on CI; the exposure is a developer with the app running locally. It belongs
  in its own change alongside the adapter refactor, not folded into a flake fix.

**Still open**: the `pubspec.lock` question in §6. The 8 deterministic Windows failures
listed in §4 were resolved afterwards — see **§4a**.

## How this was measured

* **CI** — `gh run list --repo cuplivo/cuplivo --workflow pr-check.yml --limit 60`, then
  `gh run view <id> --log-failed` for every red run. `.github/workflows/pr-check.yml` is
  the only test workflow (Ubuntu, Flutter 3.47.6, `flutter test`).
* **Merged tree** — the whole suite is run locally on Windows (`flutter test`), and the
  suspect files were run individually and as whole files.
* **Recorded history** — two sibling worktrees carry a `.toolbridge/known-failures.json`:
  `cuplivo-fix-lan-sync-ui` (the fuller one, 5 entries explicitly `"kind": "flaky"`) and
  `cuplivo-exp-export-pdf-no-web`. **This worktree had none when the numbers below were
  taken**; one was written later, and after §4a it holds zero entries.
* **Static scan** — every `*_test.dart` under `test/` and `integration_test/` (847 files)
  searched for the hazard classes in §5.

### Sandbox note for the next person

`gh run view --log-failed` fails under the DSH sandbox with
`creating cache entry: ... Access is denied` because gh caches logs under
`%LocalAppData%\GitHub CLI`. Point `LOCALAPPDATA` at a writable directory (e.g. one inside
the worktree) and the command works unchanged. Do not escalate for this.

## 1. CI: every red run in the window

Window: 2026-10-08 → 2026-10-18, 60 runs, 11 red.

Nine of the eleven are test failures, and **every one of them is a single test** — each log
ends `N tests passed, 1 failed, 6 skipped` (one run reports `2 failed`). That is the
signature to look for: not a broken feature, a lost race.

| run | date | branch | failing test | assertion |
|---|---|---|---|---|
| 39043220734 | 10-17 | `feat/quote-msg-v4` | `restore_bundle_staging_test.dart` › does not delete candidate while the revalidation isolate has not exited | `expect(backupIsolateStillAlive(error!), isTrue)` → `false` |
| 38861275709 | 10-16 | `fix/backtick-escape-v4` | `chat_input_bar_attachment_cleanup_test.dart` › 超过 5000 个字符的粘贴内容转为文本附件 | upload dir set ≠ pre-paste set — an extra `pasted_1792132717188.txt` appeared |
| 38361856114 | 10-13 | `fix/lan-sync-fk-failure` | `data_sync_backup_file_test.dart` › …size-rejects | `expectLater` wanted `FormatException('manifest_size')`, got `Future` emitting `null` |
| 38104006898 | 10-11 | `fix/proactive-care` | same as above | same |
| 38062264027 | 10-10 | `feat/lan-sync-v5` | same as above | same |
| 38039217137 | 10-10 | `feat/lan-sync-v5` | same as above **+** `mcp_provider_remote_session_test.dart` › unknown tool result is never replayed after a socket drop | `contains('result is unknown')` → got `MCP OAuth authorization is required.` |
| 38022626117 | 10-10 | `feat/lan-sync-v5` | `data_sync_backup_file_test.dart` › …size-rejects | same |
| 37727415920 | 10-08 | `feat/draft-image-preview-crop` | `chat_input_bar_attachment_cleanup_test.dart` › 源文件删除失败会记录日志且保留源文件 **+** the mcp test above | `loggedDeletionFailure()` → `false`; `MCP OAuth authorization is required.` |
| 37724903822 | 10-08 | `feat/draft-image-preview-crop` | `chat_input_bar_attachment_cleanup_test.dart` › 源文件删除失败会记录日志且保留源文件 | same |

Two of the eleven are **not** test failures and are listed so they stop being confused with
flakes:

| run | date | failing gate |
|---|---|---|
| 39045612771 | 10-17 | `Dart format (changed files only)` |
| 38399653216 | 10-13 | `Generate l10n and ensure committed outputs` |

### The distinct set

| test | red runs | verdict |
|---|---|---|
| `test/features/home/widgets/chat_input_bar_attachment_cleanup_test.dart` › 源文件删除失败会记录日志且保留源文件 | 2 | **flaky**, mechanism read in source (§3) — **fixed**, see Status |
| `test/features/home/widgets/chat_input_bar_attachment_cleanup_test.dart` › 超过 5000 个字符的粘贴内容转为文本附件 | 1 | **flaky**, matches the local registry — **fixed**, see Status |
| `test/core/services/backup/restore_bundle_staging_test.dart` › does not delete candidate while the revalidation isolate has not exited | 1 | **flaky**, matches the local registry; wall-clock budgets. **Reproduced locally (§4) and now fixed**, see Status |
| `test/core/providers/mcp_provider_remote_session_test.dart` › unknown tool result is never replayed after a socket drop | 2 | **flaky**, root cause found and proved (§2) |
| `test/core/services/backup/data_sync_backup_file_test.dart` › DataSync backup file export succeeds for a package that restore still size-rejects | 5 | **not a flake** — a wrong test, fixed by #1011 (§6) |

Note the file-level clustering: `chat_input_bar_attachment_cleanup_test.dart` produced red
runs from **two different tests**, and `mcp_provider_remote_session_test.dart` from two
different tests as well (the second, `server without tools capability stays connected with
an empty list`, is in the local registry but has not gone red on CI yet). A file whose
*multiple* tests flake is a file whose harness is racy, not a file with a couple of unlucky
assertions.

## 2. The one root cause that is fully proved: a random port read as "HTTP 401"

`McpProvider._looksUnauthorized` classifies a failure as an authentication failure by
**substring match on the error text** — `lib/core/providers/mcp_provider.dart:1812-1822`:

```dart
bool _looksUnauthorized(Object error) {
  if (error is mcp.McpHttpError) {
    return error.statusCode == 401 ||
        (error.statusCode == 403 && _isInsufficientScope(error));
  }
  final message = error.toString().toLowerCase();
  return message.contains('401') ||
      message.contains('unauthorized') ||
      message.contains('invalid_token') ||
      message.contains('authentication failed');
}
```

For a non-`McpHttpError` it string-matches. When it returns true,
`mcp_provider.dart:2806-2818` throws the real error away, marks the server
`needsAuthorization`, and returns the tool result
`'MCP OAuth authorization is required.'`.

The mock server in that test — `test/core/providers/mcp_provider_remote_session_test.dart:1837-1841` —
simulates a mid-response socket drop with the standard Dart idiom:

```dart
final socket = await request.response.detachSocket(writeHeaders: false);
socket.destroy();
```

That produces a `package:http` `ClientException`, and `ClientException.toString()` embeds
the URI. **The URI contains the ephemeral port.** Proved with a throwaway script against the
identical construct (deleted afterwards):

```
A detachSocket(writeHeaders:false)+destroy port=34010
   type    : ClientException
   toString: ClientException: Connection closed before full header was received, uri=http://127.0.0.1:34010/mcp
   contains("401") -> true
C control (random port) port=64831
   toString: ClientException: ... uri=http://127.0.0.1:64831/mcp
   contains("401") -> false
```

So: whenever the mock server's random port happens to contain the substring `401`, a plain
connection drop is misread as an auth failure and the assertion at
`mcp_provider_remote_session_test.dart:864-867` fails with `MCP OAuth authorization is
required.` — exactly the string in the two red CI logs. On Linux, **0.56 %** of ephemeral
ports (158 of the 28232 in 32768–60999) contain `401`; the raw-socket variant additionally
puts the *client's* local port in the message, widening it.

This is not a test bug. The test is exposing a real defect: user-facing MCP error messages
depend on a random TCP port number. The same `_looksUnauthorized` runs in production.

**Consequence for triage:** this test's failure rate is not "load" and cannot be fixed by
raising a timeout. It fails on ~1 run in 180 and will keep failing on `master` regardless of
who touches the file. Confirm the mechanism reproduces with the script above rather than
waiting for a red run.

## 3. The other mechanisms, read in source

**Log side effect asserted before it lands** —
`chat_input_bar_attachment_cleanup_test.dart:1251-1311`. The test swaps the global
`debugPrint` for a list-capturing closure (`:1254`), calls `mediaController.clearImages()`
(`:1300`), then polls up to 100 × 20 ms for the marker line to appear (`:1301-1306`) and
asserts (`:1307`). Two tells in the red logs: the failure is
`Expected: true / Actual: false` on `deletion failure must be diagnosable via logs`, and in
run 37727415920 the delete-failure line **is present in the captured console output** while
the asserted list was still empty — i.e. the real `debugPrint` was restored by the `finally`
at `:1313-1315` before the fire-and-forget deletion reported. The comment at `:1293-1296`
shows the author already knew the timing was load-bearing.

This test is `skip: !(Platform.isMacOS || Platform.isLinux)` (`:1319`), so **it never runs on
a Windows dev machine** — a Windows dev cannot reproduce it locally at all, while CI runs it
on every PR. That combination (CI-only, load-sensitive, 2 s budget) is why it went red twice.

**Wall-clock budgets as pass conditions** — `restore_bundle_staging_test.dart:1280-1322`
sets `debugIsolateKillGrace = 40 ms`, `debugIsolateExitDeadline = 80 ms`,
`debugIsolateTimeout = 150 ms`, then asserts the isolate is *still alive* by the time the
call returns (`:1322`). Under a loaded runner the 40/80/150 ms ladder resolves before the
test observes it. This file has already been through one unflake pass —
`6a293ef08 "fix(ci): format tool title and unflake restore isolate tests … skip isolate kill
in staging tests so they do not race under full-suite load"`, which is an ancestor of HEAD —
and the test still went red on 10-17. The approach is not converging; the assertion needs to
stop depending on wall-clock margins.

**Fixed delay standing in for a signal** — the same file's sibling assertion at
`chat_input_bar_attachment_cleanup_test.dart:377-389` completes a gate, waits
`Future.delayed(100 ms)` (`:380`), then asserts the upload directory is unchanged (`:389`).
Under load the third paste's temp file is still being cleaned up. The fix shape is to await
the cleanup, not to lengthen the delay.

## 4. Locally registered known failures

`cuplivo-fix-lan-sync-ui/.toolbridge/known-failures.json` holds 5 entries marked
`"kind": "flaky"`, all with the same reason — *"Full-suite load only: passes in isolation"*:

| file | test |
|---|---|
| `test/core/providers/mcp_provider_remote_session_test.dart` | server without tools capability stays connected with an empty list |
| `test/core/services/backup/backup_progress_kernel_test.dart` | runBackupIsolate acks sqlite close after timeout returns with isolate still alive |
| `test/core/services/backup/restore_bundle_staging_test.dart` | does not delete candidate while the revalidation isolate has not exited |
| `test/core/services/search/search_request_logging_test.dart` | search and usage requests are written to the common request log |
| `test/features/home/widgets/chat_input_bar_attachment_cleanup_test.dart` | 超过 5000 个字符的粘贴内容转为文本附件 |

CI and the local registry agree by exact name on two of the four CI-red tests —
`restore_bundle_staging_test.dart`, and `chat_input_bar_attachment_cleanup_test.dart` ›
超过 5000 个字符…. They agree on the other two at **file** level: the registry already lists a
*different* test in each of `mcp_provider_remote_session_test.dart` and
`chat_input_bar_attachment_cleanup_test.dart`, and for the latter its own reason reads "the two
other tests in this file are already registered". For both files that is the same conclusion —
the racy harness is the subject, not one unlucky assertion. `search_request_logging_test` and
`backup_progress_kernel_test` share the log-polling shape of §3.

The same registry holds **~80 further entries** that are not flaky — `"kind": "platform"`
(Windows path separators and drive-letter case, temp files still locked at teardown, tests
needing a POSIX shell) and `"kind": "defect"` (`Map addAll` type errors in
`provider_oauth_service_test.dart`, `claude_oauth_test.dart`, `scheduled_task_text_executor_test.dart`).
Those are deterministic and belong to a different list.

**The registries are per-worktree and they drift.** Neither sibling file was written against
`b607c7f00`, and §6 is a worked example of one entry that no longer reproduces.

### What actually reproduces at HEAD (measured, not copied)

A full `flutter test` at `b607c7f00` on Windows: **8578 passed, 62 skipped, 9 failed**, 12 m 35 s.
Eight of the nine are already-recorded platform failures. The ninth is the CI flake from §1,
reproduced locally.

| # | test | how it fails | recorded? |
|---|---|---|---|
| 1 | `test/core/database/composer_draft_store_test.dart` › imported conversation IDs cannot escape the private directory | `Expected: true / Actual: false` | yes |
| 2 | **`test/core/services/backup/restore_bundle_staging_test.dart` › does not delete candidate while the revalidation isolate has not exited** | **`Expected: true / Actual: false` at `1322:9`** | yes — `"kind": "flaky"` |
| 3 | `test/features/home/services/world_book_context_usage_test.dart` › world book invalidation scoped=false force=false | `PathAccessException: Deletion failed … errno = 32` at `:180` — temp tree still locked | yes |
| 4-7 | `test/native_input_attachments_test.dart` › chat / gemini × stream=true/false sends original PDF without image input through tool continuation | `Expected: ['application/pdf','audio/m4a','video/mp4'] unordered` | yes — 4 entries |
| 8-9 | `test/shared/utils/save_file_picker_test.dart` › TargetPlatform.android / .iOS preserves trailing spaces in the source and name | `Expected: 'hello 世界' / Actual: 'selected'` at `:145` — Windows strips trailing spaces | yes — 2 entries |

**Row 2 is the finding.** It is the same failing line as CI run 39043220734 — `1322:9`, same
assertion, same values — but here on **Windows** while CI is Linux, and the file passes when run
alone. That rules out a platform explanation: the assertion depends on how loaded the machine
is, not on the OS. It reproduces on demand, cheapest first:

```bash
flutter test test/core/services/backup/restore_bundle_staging_test.dart   # green
flutter test                                                              # → -1, at 1322:9
```

**The registries over-report, and they disagree with each other on the same machine.**
Cross-checking this one run against both files:

* `cuplivo-exp-export-pdf-no-web` — 9 entries, of which **8 fired, exactly** (rows 1, 3-9). Its
  ninth entry is the `data_sync_backup_file_test` Windows claim, which did **not** fire —
  independent corroboration of §6.
* `cuplivo-fix-lan-sync-ui` — ~80 entries, of which **exactly one fired** (row 2, its `"kind":
  "flaky"` entry). None of its `%TEMP%` path-separator, drive-letter-case or "needs a POSIX
  shell" entries reproduced. Worth noting that those entries' expected values all embed
  `%TEMP%` paths, so they are sensitive to how the temp directory is provided — which is itself
  a reason not to record them as per-test facts.

The practical consequence: "run the suite locally and diff against the registry" is not yet a
usable flake detector — the registry over-reports, and the one real flake (§1's sibling, row 2)
sits *among* the deterministic failures rather than in noise. Refreshing the registry against
HEAD is a prerequisite (see §7).

### After the fix

The table above is the state *before*. Once row 2's fix landed, re-measuring:

* `test/core/services/backup/` run as a whole directory — the load that reproduced row 2 — gave
  **523 passed, 14 skipped, 0 failed**.
* `test/features/home/widgets/chat_input_bar_attachment_cleanup_test.dart` gives **17 passed**
  (it was 16 + 1 skipped on Windows before the fix, because the log test was skipped there), and
  `restore_bundle_staging_test.dart` plus the two MCP files give 60 more, all green.
* **The full suite, run to completion: 8585 passed, 61 skipped, 8 failed** — and the 8 are
  exactly rows 1, 3-9 of the table above, the registered platform failures. The run before the
  fix had **9**: those same 8 plus row 2. Row 2 is the entire difference, and it is the test that
  failed at `1322:9` on both CI (Linux, run 39043220734) and this machine (Windows, inside a
  whole-suite run). The fixed run took 10 m 50 s against the broken run's 12 m 35 s.

So the expected state of a full local run is now: the **8** platform failures of rows 1, 3-9, and
nothing else. `.toolbridge/known-failures.json` in this worktree has been trimmed to match — its
eight entries name exactly the eight tests that failed, line for line, and its `flaky` entry for
row 2 is gone. (That is a name-level match verified against the run's own failure list; the
bridge's own "known / new" digest line was not read back for this run.)

## 4a. The eight Windows failures, resolved

Those eight are **gone** — not registered, not skipped wholesale, fixed. Four of them were not
platform limitations at all: they were one **product bug on Windows** that the test was right to
catch.

### Four `native_input_attachments_test.dart` cases — a real duplicate-upload bug

Both `chat` and `gemini` (× `stream=true/false`) failed with a *duplicated audio part* — chat's
`singleWhere((p) => p['type'] == 'input_audio')` raised `Bad state: Too many elements`, gemini
saw four `inline_data` parts where three were expected:

```
Actual: [... 'application/pdf', 'audio/m4a', 'video/mp4', 'audio/m4a']
  Which: has too many elements (4 > 3)
```

`NativeInputAttachments.build` de-duplicates the parts it emits with
`seen.add(SandboxPathResolver.resolveForIo(ref.uri))` (`native_input_attachments.dart:78-82`).
`resolveForIo` returns an existing path **verbatim**, so two spellings of one file produce two
keys. The test supplies exactly that pair — the structured ref is built as
`'${dir.path}/voice.m4a'`, and on Windows `dir.path` is backslashed, so the ref URI is a
*mixed-separator* string, while `userImagePaths` carries `audio.uri.toString()`, a `file://` URI
that decodes to an **all-backslash** path (`Uri.toFilePath` round-trip verified against the
bundled Dart SDK; the two differ only in separator spelling). Linux has no such pair — every
spelling is `/` — which is why CI was always green.

That is a user-visible defect, not a test artefact: on Windows, the same attachment can reach
the provider **twice** whenever one reference is a path and the other a `file://` URI. The fix
canonicalises only the *comparison key*:

```dart
if (!seen.add(SandboxPathResolver.normalizeForMatch(source))) continue;
```

`normalizeForMatch` is `_normalizeSeparatorsForMatch` made public — the helper `fix()` already
used for the image-side de-duplication, so both halves of that code now key on the same form. It
converts `\` → `/` only for Windows drive paths, so POSIX (where `\` is a legal filename
character) is untouched. The image paths never had the bug: their key goes through
`SandboxPathResolver.fix`, which normalises before probing.

### `composer_draft_store_test.dart` — a separator-brittle assertion

`expect(dir.path.startsWith('${root.path}/files/'), isTrue)` hard-coded `/` while
`ComposerDraftStore.directoryFor` builds the path with `p.join`, which emits `\` on Windows. The
security property under test (an imported id cannot escape the private directory, because the
directory name is the SHA-256 of the owner) holds on Windows — the assertion failed before the
test ever reached it. Now compared with path semantics,
`expect(p.isWithin(p.join(root.path, 'files'), dir.path), isTrue)`, which is platform-neutral and
expressly asserts containment rather than a prefix string.

### Two `save_file_picker_test.dart` cases — a fixture Windows cannot express

The test writes `File('${source.path} ')` to get a *second* file whose name ends in a space, then
asserts the original still reads `'hello 世界'`. Win32 strips trailing spaces from file names, so
on Windows both names resolve to one file and the second write clobbers the first — the
`'selected'` in the failure is the fixture overwriting itself, not the saver misbehaving. That
last assertion is a *precondition* (the two paths must be different files); the behaviour under
test — the trailing space surviving into the `sourcePath` / `fileName` channel arguments and the
staged bytes being the selected file's — is asserted by the mock handler and holds on Windows.
Only the precondition is now POSIX-guarded, so the case keeps running (and keeps testing the
saver) on Windows instead of being skipped whole.

### `world_book_context_usage_test.dart` — a process-global log sink, not a locked temp tree

The teardown failed with `errno = 32` (ERROR_SHARING_VIOLATION) deleting its temp directory, and
only ever in the **first** test of the file. The earlier note here said "temp tree still locked";
the actual holder is a **log file**. None of the leftovers is empty, and the three sampled each
hold the same single entry:

```
kelivo_world_book_usage_<id>\logs\context_logs.txt   (10854 bytes)
```

`ContextLogger` (like `RequestLogger` and `FlutterLogger`) is a static singleton holding an
`IOSink` opened on the first write under `<appData>/logs/` and closed only by `setEnabled(false)`
— `RequestLogger.activeLogFileNames` already documents exactly this hazard. The test's settings
load enables all three, the first write lands in the first test's directory, and the handle then
outlives every teardown in the process: the first teardown cannot remove its directory, and later
tests are unaffected because the sink never moves. This is why the failure was pinned to one test
and why it survived a delete-retry (tried first, 4 attempts over 650 ms, still `errno 32` — the
handle is process-lifetime, so retrying could only have masked it). The teardown now closes the
three sinks before deleting, the same close/reopen dance `StorageUsageService` already performs
around its filesystem work.

### Verification

* the four files: **66 passed, 0 failed** (before: 58 passed, 8 failed)
* `dart format` — 1 file reformatted; `dart analyze --fatal-infos lib test integration_test` —
  `No issues found!`
* non-vacuity: reinstating the old de-duplication key (`seen.add(source)`) puts the four
  `native_input_attachments_test.dart` cases back in the red, so the normalised key is what makes
  them pass — the fix is load-bearing, not incidental
* the whole suite: **8593 passed, 61 skipped, 0 failed** — the first full local run with nothing
  failing, and `.toolbridge/known-failures.json` is now `{"entries": []}`

Upstream shares this code — the registry's earlier note records the same four cases failing at
upstream's own tip on Windows — so the normalised de-duplication key is a fix worth carrying
back rather than keeping as a fork-only patch.

## 5. Structural hazards (static scan of 847 files)

These are the shapes that produce the flakes above; counts are occurrences / files.

| hazard | count | worst example |
|---|---|---|
| real-time waiting instead of fake time — `Future.delayed(` | 309 / 129 | `chat_send_race_test.dart:445` polls 50 ms × 200 |
| `.pump(Duration(...))` used as synchronisation | 553 / 122 | vs `pumpAndSettle` 1593 / 171 |
| `.timeout(` as a pass/fail condition | 120 / 42 | `dio_http_client_handshake_test.dart:79` — a 20 ms budget decides the outcome |
| per-test `Timeout(...)` raised for headroom | 51 files | `mcp_provider_remote_session_test.dart` — 20 declarations at 8 s |
| loopback `HttpServer.bind` / `ServerSocket.bind` | 229 / 76 | mostly `port: 0`, fine; the exceptions are below |
| `DateTime.now()` in assertions / ids | 172 / 58 | `desktop_process_runtime_test.dart:174` asserts `elapsed < 1500 ms` |
| `Stopwatch` / `.elapsed` | 159 / 36 | `restore_business_lease_test.dart:275` asserts `elapsed > 300 ms` |
| assertions on log side effects | 53 / 21 | `chat_input_bar_attachment_cleanup_test.dart:1254`, `dio_http_client_error_logging_test.dart:47`, `search_request_logging_test.dart:103`, `flutter_logger_test.dart:48` |
| process-global test state | — | `SharedPreferences.setMockInitialValues` **120 files**; `debugDefaultTargetPlatformOverride =` **321**; `PathProviderPlatform.instance =` **165**; `HttpOverrides.global =` **19** |

Specific defects worth naming:

* **Fixed ports.** `chatgpt_browser_oauth_test.dart:96` binds `127.0.0.1:1455` (the real
  ChatGPT callback port) and `claude_oauth_test.dart:279` occupies `54545`
  (`lib/core/services/auth/claude_oauth_adapter.dart:34` prefers exactly that port). Both
  collide with a running app or a parallel job. CI is usually clean; a dev machine with the
  app open is not.
* **Bind-then-release (TOCTOU).** `sync_engine_integration_test.dart:757-762`
  (`_unusedPort()` — bind port 0, read it, close, hand the number to the code under test),
  used at 8 call sites; same shape in `mobile_loopback_oauth_test.dart:96-99,128-131`.
  Another process can take the port in the window.
* **Unseeded randomness: none.** All 10 `Random(` uses are explicitly seeded
  (`image_compress_editor_test.dart:1471`, `output_buffer_test.dart:13`, …). This hazard is
  cleanly absent.
* **Goldens: none.** `test/goldens/frosted_surface_golden_test.dart` deliberately asserts
  widget contracts instead of pixels, because `ui.Image.toByteData` hangs in this VM. No
  font/platform golden risk exists.
* **~18 hand-rolled poll helpers, no shared one** (`pumpUntil`, `_waitFor`, `_waitUntil`,
  `waitForLog`, `_pumpUntilFound`, …), including three near-identical copies of
  `_pumpUntilFound` under `test/features/settings/pages/`. `fake_async` is already a dev
  dependency (`pubspec.yaml`) and is used in **10 of 847 files**.
* **No `retry:` / `@Retry` anywhere**, so no test retries itself. The only place a flake is
  written down is a local `.toolbridge/known-failures.json`, which is gitignored
  (`.gitignore:71`), per-worktree and partly stale (§4) — so on CI every flake is simply a
  red run.

A note on one construct the scan rated highly: the spin at
`chat_actions_stream_subscription_test.dart:70-71`
(`while (work.elapsedMicroseconds < 250) {}`) is inside a test's `onData` callback used to
force overlap. It burns CPU and is worth deleting, but it asserts ordering, not elapsed time
— it is a smell, not a demonstrated flake. The real load-sensitive gates in that file are
the `await ....timeout(const Duration(seconds: 1))` calls (113, 137, 169, 193, 254, 260 …).

## 6. Corrections to the existing records

**`data_sync_backup_file_test.dart` › …size-rejects is not flaky, and the Windows entry for
it does not reproduce.** The five red CI runs (10-10 → 10-13) stop the moment
`2e8a07fd2 "test(backup): target the ZIP size field the reader actually adopts (#1011)"`
landed, and CI has been green on it since. At HEAD the test passes both in isolation and as
a whole file:

```
flutter test test/core/services/backup/data_sync_backup_file_test.dart
→ 96 passed, 1 skipped
```

The `cuplivo-fix-lan-sync-ui` registry records it as a deterministic Windows failure. That
worktree's file is **byte-identical** to HEAD's (`git hash-object` matches:
`2f0333be498c41579208161b3fe4889203b297b8`), so the difference is environmental, and the
obvious candidate was the unpinned `archive` package — that worktree resolved `archive 4.3.0`
while this one resolved `4.5.2` (`pubspec.lock` is **gitignored**, `.gitignore:51`, so every
worktree and every CI run resolves independently). I tested that directly by rewriting the
lockfile to `archive 4.3.0` and re-running the test: **it passed**. The hypothesis is
falsified; the Windows entry should be re-checked against HEAD before anyone acts on it.

**The gitignored lockfile is itself a structural risk**, independent of that result: CI runs
`flutter pub get` with no committed lockfile, so any transitive dependency can change
behaviour between two runs of the same commit. Worth a deliberate decision, separately from
this list.

## 7. Recommended order

Items 1-3 below are **done**; item 5 is **declined for now**, with reasons in **Status**.
Items 4, 6 and 7 remain.

1. ~~**Fix `_looksUnauthorized`** (`lib/core/providers/mcp_provider.dart:1812-1822`) to stop
   substring-matching `'401'` on free text~~ — done. It was a user-visible bug, not just a
   flaky test: the error a user sees for a dropped socket depended on which TCP port the
   socket got.
2. ~~**Make the two `chat_input_bar_attachment_cleanup_test.dart` assertions wait on the work
   instead of on a duration** (`:377-389` fixed 100 ms delay; `:1301-1311` poll for a log
   line the test itself could await). Then un-skip it on Windows so it is reproducible
   locally.~~ — done, and it now runs on Windows too.
3. ~~**Replace the wall-clock margins in `restore_bundle_staging_test.dart:1280-1322`** with a
   deterministic signal.~~ — done, by moving the test-only hang ahead of the isolate's first
   cancel check, so the isolate cannot exit while the host is still deciding. Note for
   whoever touches this next: the *order* of those two statements is the fix, and a later
   baseline may carry it in the other order. The db-isolate sibling at `:1185` had the same
   defect and the same fix.
4. **Land one shared poll/deadline helper in `test/support/`** and a fake-time convention,
   then migrate the ~18 private copies. `fake_async` is already available. The three files
   fixed here each grew their own small wait, which is exactly the pattern this item is
   meant to stop.
5. **Delete the two fixed-port probes** (`1455`, `54545`) and the five bind-then-release
   helpers in favour of a port allocated by the code under test or a real socket pair. Not
   done: the two halves need different things (a preferred-port parameter for the first, a
   per-worker port reservation for the second), and the hold-open shortcut changes what those
   tests exercise. See **Status**.
6. ~~**Refresh this worktree's `.toolbridge/known-failures.json` against HEAD** so local runs
   stop reporting the 8 deterministic Windows failures as new (§4).~~ — done, by fixing the
   eight instead of registering them: **§4a**. The registry is now empty, which is the state to
   keep it in — an entry is a promise that the failure is understood. Note the file is
   gitignored (`.gitignore:71`), so this is local-only either way; a *tracked* baseline list is
   still not available to CI. **Decide on `pubspec.lock`** separately; it is gitignored too, so
   CI re-resolves every transitive dependency on every run.
7. **Make the format and l10n gates fail with the remedy in the log.** Two of eleven red runs
   were these, and neither log tells the contributor what to run. `AGENTS.md` already
   documents that CI formats with the *pinned* Dart SDK — the gate should say which version
   it used.

## 8. Reproducing any of this

```bash
# CI history
gh run list --repo cuplivo/cuplivo --workflow pr-check.yml --limit 60
gh run view <run-id> --log-failed          # set LOCALAPPDATA somewhere writable first

# a single suspect test, verbosely
flutter test test/core/providers/mcp_provider_remote_session_test.dart \
  --plain-name "unknown tool result is never replayed after a socket drop" \
  --reporter expanded

# the whole file (catches cross-test state, which isolation hides)
flutter test test/core/services/backup/data_sync_backup_file_test.dart

# README reminder: the file-level cluster is the signal
#   a file whose *several* tests flake has a racy harness
```

Failure-rate estimates in this document are per-run, from the observed CI window; they are
order-of-magnitude, not measured rates.
