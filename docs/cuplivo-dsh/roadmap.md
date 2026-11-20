# Cuplivo as a remote control for DeepSeek Harness — roadmap

Status: planning (this document is the delivery contract for the feature branch
`feat/cuplivo-dsh`; it is updated as phases land).

## 1. Objective

Give Cuplivo a second kind of assistant: a **remote DeepSeek Harness (DSH)**.
Cuplivo connects to a DSH `dsh web` server (URL carrying a launch token), and
natively renders the official DSH surfaces while the *Dsh* server keeps every
session, message and setting. Cuplivo is a remote control, not a second store:

- no DSH session/message data is persisted by Cuplivo; only the connection
  record needed to reach the server is local;
- official DSH UI surfaces are re-created in Flutter with Cuplivo's own
  rendering pipeline and design system;
- plugin-provided UI (panels, settings pages, drawer entries) is hosted inside
  a WebView;
- every rendering choice follows Cuplivo's existing settings;
- capability parity both ways: no button in Cuplivo that DSH cannot serve, and
  no DSH capability left unreachable.

The product brief, including the reference screenshots, lives outside the
repository and is not committed. This document is the engineering breakdown.

## 2. Delivery rules (from the brief, restated as gates)

1. **No local Cuplivo build, test or analysis runs** (and no local browser or
   screenshot checks). Validation goes through the repository's GitHub Actions:
   `pr-check.yml` for analyze/format/l10n/tests and the on-demand Android E2E
   (`.github/workflows/e2e-android.yml`, `/e2e` comment) for UI acceptance.
2. **One E2E acceptance scenario per PR**, under
   `integration_test/e2e/<name>_test.dart`, capturing the important frames.
3. **UI quality first.** The E2E screenshots must be compared against the
   brief's reference images before the PR is declared done; where the brief is
   silent, use Cuplivo's native design language.
4. **Decoupled, legible code.** A protocol client with no Flutter imports, a
   state layer, and presentation that reuses Cuplivo components — no
   copy-pasted ad-hoc widgets, no speculative abstraction.
5. **The E2E run must exercise a real DSH server**, not only mocks, so the
   acceptance screenshots show a real remote turn. A hermetic fallback is only
   acceptable when the real endpoint is unavailable, and must be stated in the
   PR.
6. **Never commit secrets or private infrastructure** (tokens, API keys, IPs,
   hostnames used only for testing). The temporary test key from the brief is
   used through secrets/environment only.
7. The PR body is written in Chinese, includes the E2E screenshots, and
   explains the architecture and the verification evidence.

## 3. Workstreams

| id | workstream | owner | deliverable |
|----|------------|-------|-------------|
| P1 | DSH protocol ground truth | `dsh-protocol` | `docs/cuplivo-dsh/protocol.md` |
| P2 | Client reference study + Cuplivo client design | `dsh-client-reference` | `docs/cuplivo-dsh/client-reference.md` |
| P3 | Cuplivo integration map | `cuplivo-recon` | `docs/cuplivo-dsh/cuplivo-integration.md` |
| P4 | E2E infra: e2e-vps DSH + CI wiring | `e2e-infra` | `docs/cuplivo-dsh/e2e-infra.md` |
| P0 | Architecture contract, integration, PR | Lead | this doc + branch + PR |

## 4. Implementation phases

0. **Research and contract** — P1–P4 land; the Lead fixes the module layout,
   public interfaces and data flow in `docs/cuplivo-dsh/architecture.md`.
1. **DSH client** — a pure-Dart client: launch-token login, unary RPC,
   `remote.mux` WebSocket, session activation/watch, catalog reads (models,
   providers, workspaces, plugins, commands, skills, engine settings), prompt
   send/cancel, remote transcript projection. No Flutter imports.
2. **Remote assistant identity and persistence** — a DSH assistant kind with a
   connection record, the creation flow (new assistant sheet → *DeepSeek
   Harness* → *连接到一个新的 DeepSeek Harness* → *直接连接*), connection
   settings, and the assistant list entry.
3. **Settings pages for the DSH assistant** — 连接设置 / 通用设置 / 模型 /
   plugin surfaces; only the two ungoverned general settings are exposed; models
   and providers mirror the server; plugin settings pages are Tab entry
   (Flutter) + page body (WebView).
4. **Home and sidebar** — DSH assistant in the drawer, workspace grouping,
   remote session list, plugin/automation entries, new-session creation.
5. **Chat** — Cuplivo-native rendering of remote turns and tool events, the
   input box with remote model / reasoning effort / permission mode and the
   DSH plus-menu, the new right-rail button replacing the minimap.
6. **Right rail** — push the conversation off-screen (no stacking), WebView
   panels for plugin contributions, Flutter-native entries for official ones.
7. **Hardening** — l10n for every new string, accessibility, desktop/mobile
   layouts, error/empty/loading states, reconnection, token rejection.
8. **Acceptance** — one E2E scenario covering the new surfaces, screenshots,
   PR checks green, PR body in Chinese with evidence.

## 5. Verification strategy

- `pr-check.yml`: `dart format` on changed files, `flutter gen-l10n` output
  committed exactly, `tool/l10n/translate.py check`, identity sweep, analyze,
  full test suite. Every push runs it; iterate until green.
- E2E: push an acceptance scenario, comment `/e2e` on the PR; inspect the
  sticky comment screenshots and video; fold UI corrections back into the
  branch and re-run.
- Protocol correctness: probes run against a real DSH server during research
  (outside the repository); the final E2E run against a real server is the
  integration proof. Unit tests for pure-Dart client protocol bits live in the
  repo and run in `pr-check.yml` (no local runs).

## 6. Risks and mitigations

| risk | mitigation |
|------|------------|
| Protocol drift between the installed DSH 0.2.2-rc.1 and the reference client | P1 captures the installed `.d.ts` contract; feature-detect optional endpoints |
| No local build/test loop, slow E2E feedback | batch changes into coherent commits; keep the E2E scenario tolerant of seed data; rely on `pr-check` for unit/analyze |
| E2E cannot reach the real DSH (firewall/TLS/fork security) | P4 owns connectivity; hermetic stub fallback documented in the PR if unavoidable |
| Renderer assumptions (Cuplivo's chat model expects local DB rows) | P3 maps the seams; phase 1 introduces a projection independent of Drift |
| New strings vs. l10n CI (all locales) | follow the `tool/l10n` contract from P3; run `flutter gen-l10n` output as generated |
| Scope creep into a second product | capability parity only for what the brief names; plugin UI stays in WebView |

## 7. PR plan

- Branch: `feat/cuplivo-dsh`, one PR against `master`.
- Commit sequence: protocol client → remote assistant/persistence → settings →
  home/sidebar → chat → right rail → l10n/polish → E2E scenario → docs.
- PR is opened as a draft once the first coherent slice lands (CI feedback
  early), and finalized after green checks + E2E screenshots.
- The PR text is Chinese, ends with the verification evidence (run links,
  screenshots) and notes the AGPL-3.0 reference acknowledgement for design
  inspiration.

## 8. Working rules clarifications (owner, 2026-11-19)

- **Local test/build/analysis runs are completely forbidden** (no `flutter test`,
  `flutter build`, `flutter run`, no local `dart analyze`).
  Formatting and l10n codegen (`dart format`, `flutter gen-l10n`,
  `translate.py sync`, `flutter pub get` for tooling) remain allowed; every
  behavioural verdict comes from GitHub Actions.
- The product brief's **reference images may live in the repository temporarily**
  for development/review at `docs/cuplivo-dsh/reference/` (untracked via the
  local git exclude; never committed to the PR). Final acceptance must compare
  the E2E screenshots against those images, surface by surface.

## 9. Delivered status (2026-11-20)

Phases 0-7 are implemented on `feat/cuplivo-dsh` (PR #1104). Evidence is the CI
record, never a local run:

- `pr-check`: format, l10n (`translate.py check`, 0 pending across all locales),
  identity sweep, `dart analyze --fatal-infos` (clean), full `flutter test`.
- Android E2E on a **real** DSH 0.2.2-rc.1 host through the repository's
  `/e2e` workflow: create the remote from the create menu, connect with the
  launch URL, owner card, settings shell (连接设置 / 通用设置 / 模型 / 内容),
  local drawer listing the remote (R4), DSH drawer (R5), a new session answered
  by the real host (R6, streamed Chinese answer), the right rail (R7), the
  models tab (R9), the add-provider picker (R10) and an existing provider's
  editable detail (R11). Screenshots and a recording are uploaded as workflow
  artifacts and summarized in the PR body.
- Deferred, documented in the PR: terminal attach (`terminal/attach` stream not
  wired; honest placeholder), attachment picker (client supports
  `session/attachment`, UI not opened), plugin pages (host WebUI in a WebView,
  no per-plugin URL), binary workspace-file preview (transport is JSON-only),
  browser rail card (no browser API in DSH 0.2.2), and provider-detail model
  metadata that the live catalog gateway does not expose (context window, max
  output, input modalities start empty for adapter-default models).
- Several of those deferrals were closed by the v2 round below; §10 is the
  current scope, §9 stays as the first-PR record.

## 10. v2 round scope (2026-11-20)

The v2 round closes the plugin/UI compatibility gap the first PR deferred.
Engineering contract: `architecture.md` §9; acceptance anchors:
`implementation-contract.md` "v2 acceptance anchors". Compatibility evidence
and the generic JS recipes: `plugin-compat.md` §4–§6 (sidebar rows, right rail,
no per-panel routes). Reuse decisions: `v2-reuse-map.md` §1–§6.

### 10.1 Delivered

| area | what landed | acceptance |
|---|---|---|
| Native terminal (R12) | `DshTerminalPanel` inline in the right rail plus a full-screen `DshTerminalPage`; `DshWorkspaceRuntime` over the Host's `terminal/*` endpoints, reusing the workspace terminal emulator; a writable Host PTY when the Host reports a shell, a visible read-only surface otherwise, and an honest unavailable card instead of a fake prompt | real PTY proven by the header's Host shell/cwd and a file written through the terminal (`dsh-terminal-panel/view`) |
| Binary/remote file preview (R13) | `DshFilePreviewPage` + `DshPreviewCache`: remote text/images are materialized into a bounded temp file and reuse the existing workspace previews; PDF (and unavailable image bytes) open the authenticated `/api/file` in the shared WebView; anything else renders `DshRemoteFileCard` with a reason — never a blank pane | png/text inline, pdf/blob full-page (`dsh-remote-file-card`, `dsh-file-preview-web-<gen>`) |
| Attachment picker and prompt parts (R6) | the plus menu's 文件 row opens the native image/document pickers; `DshAttachmentUploadService.prepare` turns the composer input into prompt attachments — images inline under the Host's budgets from `session/limits`, documents uploaded to `session/attachment` and carried as receipts; typed failures map to localized sentences | plus-sheet capture and the service tests; native pickers are not drivable from integration tests |
| Context ring (R6) | `DshContextUsage` maps the live `contextPressure` readout to the composer's ring; the ring is hidden when the Host reports no readout, never estimated | `dsh-context-ring` after a real turn |
| Plus and slash menus with honest rows (R6) | `DshPlusSheet` mirrors the official 添加/指令 structure and enables only rows with a wire (文件; 压缩 only when the catalog advertises `compact`; 权限; 模型), while 目标/计划/反馈 and 下载日志 stay visible with their short reason; `DshSlashCommandsSheet` lists the Host's `commands/list` | `dsh-plus-sheet` rows and the slash sheet |
| Plugin-compat harvest for R5/R7 (R5, R7) | `DshSurfaceHarvest` reads the official sidebar labels and right-rail cards (label + language-neutral `kind`) from the official WebUI on first open; `DshSurfaceInventory` keeps one in-memory snapshot per authority; R5 rows and R7 plugin cards render the Host's own labels natively, built-ins stay native, and a tap lands the WebUI on that row/card. 更多 stays one native row that lands DSH's own `PanelMoreMenu` | harvested rows/cards replace the built-ins after one WebUI open (`dsh-sidebar-entry-<id>`, `dsh-rail-entry-<id>`) |
| Settings tabs matching DSH (R2) | five native tabs — 连接设置, 通用设置, 模型, 内置插件 (read-only inventory), Agent 预设 (read-only groups) — data-driven, with the Host-reported tabs appended only when the catalog reports plugin capability | `dsh-settings-tabs` / `dsh-settings-tab-<id>` |

### 10.2 Not delivered (explicit)

- **Plugin `settings.section` tabs.** DSH plugins can register root settings
  sections, but `pluginInventory` metadata is package metadata, not a settings
  tab; v2 ships only the five native tabs. A plugin's own configuration page is
  reached through the 插件 WebUI (harvest + landing), not as a Cuplivo tab.
- **Per-panel deep links.** DSH has no URL routing for panels, settings
  sections or rail pages; every plugin surface opens the whole SPA and is
  steered by a best-effort landing script. There is no link to ship.
- **Terminal persistence across rail unmount.** The terminal exists only while
  its panel/page is mounted; unmounting disposes the PTY (`DshWorkspaceRuntime`
  closes the terminals it created) and reopening starts a new terminal.
