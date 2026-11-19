# Implementation contract — ownership, toolchain, workflow

This is how the team builds the feature on one worktree without stepping on each
other. The Lead commits, pushes and owns the PR; teammates edit files only.
Architecture and surface requirements: `architecture.md`, `ui-spec.md`.

## Branch and validation

- Branch `feat/cuplivo-dsh` (already pushed; draft PR #1104).
- **Local test/build runs are forbidden**: never `flutter test`, `flutter build`,
  `flutter run`. Validation is GitHub Actions (`pr-check` on every push, `/e2e`
  for UI acceptance). Static analysis is the only local check allowed:
  `dart analyze <dirs>` after `flutter pub get --enforce-lockfile`.
- Formatting and codegen are allowed and expected locally:
  `dart format`, `flutter gen-l10n`, `python3 tool/l10n/translate.py sync`.
- Pinned toolchain (matches CI's Flutter 3.47.6 / Dart 3.13.5):
  `PATH=/root/toolchains/flutter/bin:$PATH`. Do not use `/opt/flutter`'s Dart to
  format checked-in files — CI's formatter is the pinned one.
  First-time bootstrap for the pinned SDK:
  `git config --global --add safe.directory /root/toolchains/flutter`.
- No git commands from teammates (no add/commit/push/checkout/stash). The Lead
  commits coherent slices. If the index is locked, wait a few seconds and retry.

## File ownership (write scopes)

| area | paths | owner |
|------|-------|-------|
| protocol client | `lib/core/dsh/**`, `test/core/dsh/**`, `docs/cuplivo-dsh/client-api.md` | `dsh-client-core` |
| remote identity + persistence + state + assistant settings/connect flow | `lib/features/harness/models/**`, `services/**`, `state/**`, `pages/connect/**`, `pages/assistant/**`; `lib/core/models/chat_owner.dart`; `lib/core/providers/chat_owners_provider.dart`; the create-menu/owner-row edits in `lib/features/assistant/pages/assistant_settings_page.dart` and `lib/desktop/setting/assistants_pane.dart`; `main.dart` provider registration | `harness-foundation` |
| harness mode in the existing home + drawer + right rail | `lib/features/harness/pages/home/**`, `widgets/dsh_side_bar.dart`, `lib/features/side_panel/widgets/side_panel_geometry.dart`, `test/features/harness/home/**`, wiring edits in `lib/features/home/{pages,widgets,controllers}/…` | `harness-home` |
| conversation body + composer + model/permission pickers + plugin WebView | `lib/features/harness/pages/chat/**`, `pages/plugins/**`, `widgets/chat/**`, `controllers/**`, `test/features/harness/chat/**` | `harness-chat` |
| research/design docs | `docs/cuplivo-dsh/{protocol,client-reference,cuplivo-integration,e2e-infra}.md` | the researcher who owns it |
| ARB + l10n state | `lib/l10n/**`, `tool/l10n/state/**` | **serialized**: one editor at a time; announce in the team chat |
| CI/e2e workflow | `.github/workflows/e2e-android.yml` | Lead + `e2e-infra` (after approval) |
| commits/branch/PR | everything | Lead |

Rules: a file outside your scope is read-only. Need a small edit elsewhere?
Message the Lead instead of editing. When a shared file must change for your
slice, message the Lead first.

## l10n protocol

- Every user-visible string goes through `lib/l10n/app_en.arb` (key + description)
  and `lib/l10n/app_zh.arb` (Chinese text). Never hardcode UI text.
- Add your keys in one batch, at the end of the JSON object, then run
  `flutter gen-l10n` from the repo root with the pinned toolchain and commit
  exactly the generated output (the generator formats its own files).
- Because the ARB files are shared, only one teammate edits them at a time. Take
  a turn: message the Lead/other implementers that you are in the ARB files,
  finish within the same step (add keys → gen-l10n), then say you are out. If
  the files' version guard reports a stale version, re-read and retry with your
  keys inserted in one contiguous batch; never reformat the files.
- Other locales (`ru`, `ko`, `tr`, `zh_Hant`) are produced by
  `python3 tool/l10n/translate.py sync` — the Lead runs that sweep, not
  individual implementers (translations land in the same commit as the strings).
- The `dsh` feature's strings use the `dsh` prefix (`dshConnectTitle`, …).

## Client public API (contract)

`dsh-client-core` writes `docs/cuplivo-dsh/client-api.md` first (the concrete
class/method surface for `lib/core/dsh/`) and messages the Lead when it exists.
Everyone else reads that file instead of reading the client implementation.
The client must stay Flutter-free (no `package:flutter` import anywhere under
`lib/core/dsh/`), use `dart:io` HTTP/WebSocket (Cuplivo is not a web target),
`package:http` only where a redirect/cookie nuance requires it, and export
typed exceptions, not raw strings.
