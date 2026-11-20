# Android E2E acceptance scenario — design

One scenario file: `integration_test/e2e/dsh_remote_acceptance_test.dart`.
It starts from the shape of `example_acceptance_test.dart` /
`acceptance_support.dart` and runs in the incremental `/e2e` harness
(`e2e-android.yml`; real endpoint only for same-repo PRs — infra PR #1105).

The scenario covers the R1–R11 scope of `docs/cuplivo-dsh/ui-spec.md` plus the
v2 surfaces: the Host-reported settings tabs (R2), the official-WebUI harvest
that turns R5/R7 into the remote's own labels, the composer plus menu, a real
tool turn, the composer context ring (R6), the Host terminal (R12) and remote
file previews (R13).

## Inputs

- `String.fromEnvironment('E2E_DSH_URL')` — base URL, no query (e.g. the
  operator's HTTPS endpoint; empty on forks).
- `String.fromEnvironment('E2E_DSH_TOKEN')` — current launch token.
- Both empty → hermetic mode (boot + local surfaces + screenshot, DSH section
  skipped with a printed reason). Exactly one set → fail with a clear message.
- Both set → real mode. The tokenized URL handed to the UI is
  `"$E2E_DSH_URL/?token=$E2E_DSH_TOKEN"`; the scenario never prints the token,
  never asserts on hostnames, and the workflow's artifact guard already fails the
  job if the token reaches published files.

All v2 steps below run in real mode only. Hermetic mode stops at the
direct-connect form (create menu → engine sheet → form), so a fork PR with no
host still boots the app, drives every local navigation and produces its
screenshots without touching the network.

## Steps (real mode)

Each step ends with `capture(..., '<name>')` when it produces evidence.

1. `bootSeededApp` (existing helper).
2. Drawer → `+` action of the owner list → create menu; assert the third row
   `DeepSeek Harness` (R1); screenshot `r1_create_menu`.
3. Tap it → mode sheet → `直接连接` → direct-connect form.
4. The form is empty, so assert the WebUI URL field's token placeholder
   (`dshWebUiUrlHint`, e.g. `例如127.0.0.1:3080/?token=PEaxKDfNOHzbHp…`); it is
   the field's `hintText` and only renders while nothing is entered.
5. Enter the name `DeepSeek Harness` and the tokenized URL; tap `确认`. Wait for
   the assistant card in 助手与群聊 (R3); screenshot `r3_connected_card`.
6. Open the DSH assistant settings page via the card. Assert the tab strip by id
   (R2): `连接设置`, `通用设置`, `模型` always; `内置插件` and `Agent 预设` only
   after the connected catalog reports `pluginInventory/list`. Screenshot
   `r2_settings_connection`.
   - 内置插件: read-only note (`dshPluginsReadOnly`), the Host's own plugin rows
     (status `已启用`, module subtitle `@…`); screenshot `r2_builtin_plugins`.
   - Plugin-registered settings tabs (generic): tap the
     `dsh-settings-open-official` row, wait for the official WebUI page, and
     wait (bounded, two attempts) until
     `DshSurfaceInventory.shared.snapshotFor(<authority>).settings` is
     non-empty — the visit is the only source. When it arrives, go back and
     assert one `dsh-settings-tab-plugin-*` tab per `pluginSettingsSections`
     entry with the Host's label (the tested host's two plugins register no
     `settings.section`, so that list is empty by evidence; the log reports the
     count of harvested official sections). When it does not arrive — the
     hosted emulator cannot render the official single-page app at all, its
     Chromium renderer exits within a second — the scenario asserts the route
     opened, captures it, logs the platform limit and continues; the
     `dom-contract` job proves the same recipe against the real Host. Either
     way the visit captures `r2_official_settings`; screenshots when the
     snapshot is non-empty: `r2_plugin_settings_tabs`,
     `r2_plugin_settings_body`.
   - Agent 预设: read-only note (`dshAgentPresetsReadOnly`), the default
     composition group (`standard`, badge `默认`); screenshot
     `r2_agent_presets`.
   - 通用设置 (R8): the two rows (default permission, session-log upload);
     screenshot `r8_general_settings`.
7. 模型 tab, in the same settings session: provider rows from the live catalog
   (R9), 自定义提供商 first (R10); screenshot `r9_models`. Open the
   add-provider picker (`r10_add_provider`), then deepseek-official's editable
   detail form (R11, `r11_provider_detail`). Leave settings and return to the
   home surface.
8. Open the local drawer, expand the current-assistant tile, tap the
   `DeepSeek Harness` owner row (R4): screenshot `r4_local_sidebar`. In harness
   mode assert the pre-harvest drawer (R5): built-in `插件`/`自动化任务`/`更多`
   rows; screenshot `r5_dsh_drawer`.
9. Create a session. Before the first prompt, assert the composer's
   **Agent 预设** chip (`dsh-preset-chip`) opens on the Host default and is
   selectable while the Session is blank: open it, assert the picker
   (`dsh-preset-standard|ptc|minimal|cordis`) lists the Host roster and that
   the shipped rows use Cuplivo's localized copy; screenshot
   `r6_preset_menu`. Pick `ptc` — a real `agentPresets/select` write — and wait
   for the chip to report `PTC 模式`; screenshot `r6_preset_chip`. Pick
   `standard` again so the tool turn runs the default composition. Then send a
   short prompt (`你好，请用一句话介绍你自己`), wait for the streamed assistant
   answer; assert the app-bar title/subtitle (R6); screenshot `r6_chat`.
10. Composer plus menu: assert both groups `添加`/`指令` and every row
    (文件/目标/计划/反馈, 压缩/权限/模型/下载日志), screenshot `r6_plus_menu`.
    Honest disables are rendered, not hidden (the row copy states the missing
    wire).
11. Tool turn: send `请用 bash 工具执行这条命令：echo CUPLIVO_E2E_TOOL_OK，然后
    把完整输出贴给我`, wait until the folded transcript holds a `bash`
    `ToolUIPart` (the list is virtualized, so the rendered card can sit outside
    the built range) and a second assistant message whose text quotes the
    marker; then scroll the transcript up until the card's localized
    `调用工具: bash` header is visible and screenshot `r6_tool_turn`. If the
    Host's permission preset gates shell tools, the scenario answers the
    pending 允许 prompt (`dsh-approval-allow`) the same way a user would. Then
    wait for the composer context ring
    (`dsh-context-ring`), which appears once the Host's `contextPressure`
    projection has a positive context window; screenshot `r6_context_ring`.
    Attachments run through the composer's deterministic staging seam
    (`DshComposerE2e.stage`): the scenario writes `e2e-notes.txt`, stages it as a
    real `DocumentAttachment`, asserts the composer chip
    (`chat-input-document-previews`), sends
    `读取我附加的 e2e-notes.txt 并回复它第一行`, waits for the transcript card, and asserts the answer quotes the
    file's first line (`CUPLIVO_E2E_ATTACHMENT_OK`); screenshot `r6_attachment`.
12. Open the right rail; assert it pushes the chat off-screen and renders the
    built-in cards `工作区文件`/`新建终端`/`更多工具` (浏览器 intentionally
    absent — capability parity); screenshot `r7_right_rail`. Close the rail.
13. Harvest: open the drawer, tap the pre-harvest `插件` row (this WebUI load is
    what runs the official-sidebar harvest), return, and wait (bounded) for the
    snapshot. When it arrives, the drawer renders the Host's own rows verbatim —
    labels that exist only in the official DOM, so no fabricated row can pass —
    and `更多` stays one built-in row, never duplicated; screenshot
    `r5_harvested_sidebar`. Then tap each harvested row and capture the official
    page it lands on: the first two rows (`r5_plugins_page`,
    `r5_search_service_page`) and the built-in `更多` row (`r5_more_menu`). Every
    WebUI open also re-harvests, so one open/return is enough.
    When no snapshot arrives (the hosted emulator's WebView cannot render the
    official app), the scenario asserts the built-in drawer rows stay complete
    and usable, logs the platform limit, and leaves the harvest/landing proof to
    the `dom-contract` job; the page captures are skipped because there is no
    loaded official page to show.
14. R7 harvested cards: open the rail again and assert the Host's own rail cards
    by label; screenshot `r7_harvested_cards`. Tap `代码变更` → official page;
    screenshot `r7_diff_page`. When the harvest is empty (same platform limit),
    assert the built-in cards `工作区文件`/`新建终端` stay usable instead and skip
    the two captures.
15. R12 terminal: tap the `新建终端` card. Assert `dsh-terminal-panel`,
    `dsh-terminal-view`, a header with the live shell title (`bash`) and Host
    cwd (contains `workspace`), and no read-only banner; screenshot
    `r12_terminal`. Type
    `echo CUPLIVO_E2E_TERMINAL_OK > cuplivo-e2e-terminal.txt` through the
    terminal's IME connection, submit Enter, screenshot `r12_terminal_command`.
    `terminal_view` paints glyphs to a canvas, so the assertion is the workspace
    side effect: the file appears in the rail 工作区文件 listing.
16. R13 previews: 工作区文件 → `assets/pixel.png` renders inline in the rail
    (screenshot `r13_png_inline`); `docs/report.pdf` and `data/blob.bin` open the
    full-screen preview page. A PDF may render through the authenticated
    `/api/file` WebView or fall back to the honest card; `blob.bin` must render
    the metadata card (`dsh-remote-file-card`, text
    `dshFilesPreviewUnavailable`), never a blank pane. Screenshots
    `r13_pdf_preview`, `r13_binary_preview`.
17. Close the rail, `expect(tester.takeException(), isNull)` and capture
    `final_state`.

The scenario leaves created sessions and the terminal's file on the E2E host
(`/var/lib/dsh-e2e`); the operator resets with `dsh-e2e-reset` when deterministic
state matters. It must not depend on pre-existing sessions.

## Screenshots

`r1_create_menu`, `r3_connected_card`, `r2_settings_connection`,
`r2_builtin_plugins`, `r2_official_settings`,
`r2_plugin_settings_tabs` (only when the Host reports a
plugin-contributed settings section), `r2_plugin_settings_body`,
`r2_agent_presets`, `r8_general_settings`, `r4_local_sidebar`,
`r5_dsh_drawer`, `r9_models`, `r10_add_provider`, `r11_provider_detail`,
`r6_preset_menu`, `r6_preset_chip`, `r6_chat`, `r6_plus_menu`,
`r6_tool_turn`, `r6_context_ring`, `r6_attachment`,
`r7_right_rail`, `r5_harvested_sidebar`, `r5_plugins_page`, `r5_search_service_page`,
`r5_more_menu`, `r7_harvested_cards`, `r7_diff_page`,
`r12_terminal`, `r12_terminal_command`, `r13_png_inline`, `r13_pdf_preview`,
`r13_binary_preview`, `final_state`.

`r5_plugins_page`, `r5_search_service_page`, `r5_more_menu` and
`r7_harvested_cards`/`r7_diff_page` require the official WebUI to render in the
emulator's WebView. On a host where its Chromium renderer cannot (see
"Platform-view limits"), those captures and the harvested-row assertions are
skipped with a logged reason, and the `dom-contract` job carries that proof
against the real Host.

Hermetic mode captures `hermetic_local_drawer`, `hermetic_create_menu`,
`hermetic_engine_sheet`, `hermetic_create_form`, `final_state`.

## Stable test hooks

Widgets the scenario drives expose a `ValueKey` (or `const Key`) so the test does
not depend on layout: `dsh-create-menu-item`, `dsh-engine-mode`,
`dsh-connect-name`, `dsh-connect-url`, `dsh-connect-confirm`, `dsh-owner-card`,
`dsh-owner-row`, `dsh-settings-tabs`, `dsh-settings-tab-connection`,
`dsh-settings-tab-general`, `dsh-models-tab`, `dsh-settings-tab-plugins`,
`dsh-settings-tab-agentPresets`, `dsh-drawer-entries`, `dsh-sidebar-entry-<id>`
(pre-harvest built-ins: `plugins`/`automations`/`more`; harvested rows: slug of
the Host label, e.g. `dsh-sidebar-entry-搜索服务`), `dsh-session-row`,
`dsh-new-session`, `dsh-composer`, `dsh-send`, `dsh-transcript`,
`dsh-preset-chip`, `dsh-preset-<id>`, `dsh-plus-sheet`,
`dsh-plus-section-add|commands`, `dsh-plus-attach|goal|feedback|
compact|permission|model|download-log`, `dsh-context-ring`,
`dsh-approval-allow`,
`dsh-right-rail-button`, `dsh-right-rail`, `dsh-rail-back|title|expand|close`,
`dsh-rail-workspace-files|new-terminal|more-tools`, `dsh-rail-entry-<id>`,
`dsh-terminal-panel`, `dsh-terminal-view`, `dsh-terminal-header`,
`dsh-terminal-readonly`, `dsh-terminal-unavailable`, `dsh-remote-file-card`,
`dsh-remote-file-retry`, `dsh-file-preview-web-<gen>`,
`chat-input-document-previews`, and the preview page's documented root key
`dsh-file-preview-page` (the scenario also falls back to the
`DshFilePreviewPage` widget type).

The full-screen preview page is preferred by its `dsh-file-preview-page` root
key, falling back to the `DshFilePreviewPage` widget type while the key lands.

Owners own their keys in their widgets; the scenario only reads them. Harvested
rows are asserted by their **label text** first (the authoritative remote
value) and only secondarily by the slug key.

## Host assumptions

The real run targets the operator host described in
`docs/cuplivo-dsh/e2e-infra.md` after `dsh-e2e-reset`. The assertions that depend
on live data are deliberately tolerant of ordering and counts but not of
absence:

- official UI language follows the WebUI's own locale; the recipes accept both
  the `zh-CN` and `en-US` label sets (`插件`/`Plugins`, `搜索服务`/`Search
  services`, `自动化任务`/`Automation tasks`, `代码变更`/`Changes`, `更多`/`More`)
  and render whichever the Host posts verbatim, so no single language is
  asserted;
- the two pinned plugins `@ds-hu/dsh-better-search` 0.5.0 and
  `@ds-hu/dsh-better-workspaces` 0.4.1 (rail rows `代码变更` / `新建 worktree` /
  `Issue 与 PR`), so the R5/R7 harvest has labels to find;
- terminal: `bash` as user `dsh` with cwd under `…/workspace`;
- workspace seeds: `hello.txt`, `notes.md`, `assets/pixel.png`,
  `docs/report.pdf`, `data/table.csv`, `data/blob.bin`;
- temporary model key for the short prompts.

If the Host changes a label the wait fails naming the expected label, which is
the intended signal to update this scenario.

## Platform-view limits (documented, not failures)

- **The hosted Android emulator cannot render the official DSH single-page
  app.** Its Chromium renderer process exits within a second of the load
  (`E/chromium: [ERROR:aw_browser_terminator.cc(...)] Renderer process ...
  crash detected (code -1)` on every attempt, independent of API level,
  Vulkan and platform-view composition), so no injected script ever posts. The
  scenario therefore asserts the honest fallback on the emulator: the WebUI
  route still opens and the native surfaces (built-in sidebar rows, rail
  cards, terminal) stay complete; the `dom-contract` job proves the harvest and
  landing recipes against the real Host in a desktop Chrome. This is a
  limitation of the CI emulator, not of the app: the same recipes pass in
  Chrome at 412×915 against the same Host.
- The official WebUI and the PDF pane run in a platform WebView. Their DOM is
  not part of the Flutter widget tree, and integration_test screenshots capture
  the Flutter surface, so the captured images carry Cuplivo's chrome (route
  title/note) rather than the Host's pixels. Assertions therefore anchor on the
  route title plus the harvest, which only a loaded official page can post.
- `terminal_view` paints with a canvas; the scenario asserts the remote PTY
  header and a workspace side effect instead of terminal glyphs.
- PDF rendering is device/WebView dependent: rendered WebView or the honest
  metadata card are both accepted; a blank pane is not.
- The attachment UI normally opens native pickers. The product path after the
  picker (chip → upload → prompt part → transcript card → model answer) is
  exercised through `DshComposerE2e.stage`; driving the OS picker itself is out
  of scope for an integration test.

## Timeouts and flakiness

- Whole test `Timeout(Duration(minutes: 10))`; every wait is bounded by
  `pumpUntil`/`_pumpUntilFound` with a message naming the expected state.
- Harvest waits: the script waits for the official nav/rail (up to ~6 s), then
  posts; the scenario keeps the page mounted for ~12 s before popping and waits
  up to 90 s for `搜索服务`. One open/return is enough; every later WebUI open
  re-harvests.
- Model answers use the temporary key; both prompts stay short to keep the run
  inside the emulator budget.
- The scenario is not a visual regression baseline; its screenshots are the
  acceptance evidence compared against the reference images in the PR.
