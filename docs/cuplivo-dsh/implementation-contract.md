# Implementation contract — ownership, toolchain, workflow

This is how the team builds the feature on one worktree without stepping on each
other. The Lead commits, pushes and owns the PR; teammates edit files only.
Architecture and surface requirements: `architecture.md`, `ui-spec.md`.

## Branch and validation

- Branch `feat/cuplivo-dsh` (already pushed; draft PR #1104).
- **Local test/build/analyze/screenshot runs are forbidden**: never
  `flutter test`, `flutter build`, `flutter run`, `dart analyze`, or a local
  browser/screenshot check. Validation is GitHub Actions (`pr-check` on every
  push, `/e2e` for UI acceptance) or `us-vps1`.
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

## DSH settings surface (v2)

The assistant settings page is a five-tab DSH surface, in this order:
`connection` / `general` / `models` / `plugins` / `agentPresets` (连接设置 /
通用设置 / 模型 / 内置插件 / Agent 预设). The invented 内容 tab is gone.

- `连接设置` is Cuplivo's own connect surface; `通用设置` keeps the two exposed
  settings; `模型` reads the remote provider/model catalog.
- `内置插件` is a native, read-only body over `catalog.plugins` (mapped from
  `pluginInventory/list`): plugin-localized title, module name, enabled/disabled,
  Loader phase and diagnostics. No toggles or management RPCs in this round.
- `Agent 预设` is a native, read-only body over the inventory's optional
  `agentPresets` groups (mapped into `DshCatalogSnapshot.agentPresets`): name/id,
  default badge, plugin rows and broken reason; no select action.
- Tabs live in `lib/features/harness/pages/assistant/dsh_settings_tabs.dart`
  (`DshSettingsTabSpec`), are rendered by
  `lib/features/harness/widgets/dsh_settings_tab_strip.dart` (strip key
  `dsh-settings-tabs`, per-tab `dsh-settings-tab-<id>`, models keeps
  `dsh-models-tab`), and the bodies are in
  `lib/features/harness/pages/assistant/dsh_settings_tab_bodies.dart`.
- Plugin-registered settings tabs are driven by the shared harvest inventory:
  the page listens to `DshSurfaceInventory.shared`, and every
  `snapshot.pluginSettingsSections` entry (a `settings.section` label the
  official dialog shows that is not in `DshSettingsSectionLabels.builtIn`)
  becomes a tab with id `plugin:<slug>` (ASCII slug, `section-<ordinal>` when
  the label has no ASCII, tab key `dsh-settings-tab-plugin-<slug>`, body root
  key `dsh-settings-plugin-body-<slug>`). The body is
  `DshPluginSettingsTabBody`: the official Web UI inline, landed with
  `DshSurfaceHarvest.settingsScript(landLabel: label)`; it is built lazily on
  first selection. The 内置插件 tab has one `dsh-settings-open-official`
  affordance that performs the settings visit. Inventory `meta.title` is never
  turned into a tab — see `plugin-compat.md` §3.4a.

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

## v2 acceptance anchors

The v2 E2E (`integration_test/e2e/dsh_remote_acceptance_test.dart`, designed in
`e2e-scenario.md`) reaches a Cuplivo surface through its stable widget key, never
through layout; the one deliberate exception is a harvested row/card, whose
authoritative value is the Host's own label (the key is the secondary anchor).
Keys are part of the contract — adding, renaming or removing one updates this
table and `e2e-scenario.md` in the same commit. The harvest/landing recipes
behind the rows and cards are in `plugin-compat.md` §4–§6; the
hosting/preview reuse decisions they encode are `v2-reuse-map.md` §4 (WebView
hosting) and §5 (preview fallback).

| surface | keys | E2E route |
|---|---|---|
| Assistant settings (R2, R8–R11) | strip `dsh-settings-tabs`; per tab `dsh-settings-tab-<id>` — ids `connection`, `general`, `models` (keeps the historical `dsh-models-tab`), `plugins`, `agentPresets` | owner card → assistant settings page; 内置插件 / Agent 预设 only after the connected catalog reports plugin capability; 通用设置 rows (R8) and models slice (R9–R11) run inside the same page |
| DSH sidebar rows (R5) | `dsh-drawer-entries` container; `dsh-sidebar-entry-<id>` per row (pre-harvest ids `plugins`, `automations`, `more`; a harvested row uses its label's slug); legacy `dsh-entry-<id>` anchors remain asserted | local drawer → expand the current-assistant tile → tap the `DeepSeek Harness` owner → DSH drawer; open 插件 once (pre-harvest) so the official page posts the harvest, then the drawer shows the Host's rows (`搜索服务` is the live signal) and taps land the official page by label; 更多 stays one built-in row |
| Right-rail cards (R7) | rail `dsh-right-rail`; built-in cards `dsh-rail-workspace-files`, `dsh-rail-new-terminal`, `dsh-rail-more-tools`; harvested plugin cards `dsh-rail-entry-<id>`; back/expand/close `dsh-rail-back`, `dsh-rail-expand`, `dsh-rail-close`, opened by `dsh-right-rail-button` | app-bar rail button → rail; harvested cards appear after one official WebUI open and open the landed official page; 新建终端 is built-in |
| Native terminal (R12) | panel `dsh-terminal-panel`, surface `dsh-terminal-view`, header `dsh-terminal-header`, expand `dsh-terminal-expand`, states `dsh-terminal-readonly` / `dsh-terminal-unavailable`; full screen `dsh-terminal-page` | rail → `dsh-rail-new-terminal`; assert the Host shell title and cwd from `terminal/create` + `terminal/environment`, type a command through the surface's IME path, then return via `dsh-rail-back` and assert the created file in the rail's workspace files |
| Remote file preview (R13) | card `dsh-remote-file-card`, retry `dsh-remote-file-retry`, WebView pane `dsh-file-preview-web-<generation>`, page root `dsh-file-preview-page` | rail → workspace files → tap the file: png/text render inline, pdf and binary open the full-screen page (pdf accepts the WebView or the honest metadata card; `blob.bin` accepts only the card) |
| Composer plus menu (R6 v2) | sheet `dsh-plus-sheet`; rows `dsh-plus-attach`, `dsh-plus-goal`, `dsh-plus-feedback`, `dsh-plus-compact`, `dsh-plus-permission`, `dsh-plus-model`, `dsh-plus-download-log`; section headers `dsh-plus-section-add`, `dsh-plus-section-commands` | composer `+` → sheet; every row is present, disabled rows carry their reason; native pickers behind `dsh-plus-attach` are not drivable from an integration test (noted in `e2e-scenario.md`) |
| Slash commands (R6 v2) | sheet `dsh-slash-sheet`; row `dsh-slash-command-<name>` | composer `/` when the Host's `commands/list` is non-empty |
| Context ring (R6 v2) | `dsh-context-ring` | after a real turn whose live session state carries `contextPressure` |

Keys for the harvested rows/cards are derived by `dshSurfaceEntryId` from the
Host's label; the id stays stable while the harvested set is unchanged (a
label collision gets a numeric suffix) and is never used for display or landing
(the scripts click the label / language-neutral rail kind).
