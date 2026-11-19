# Android E2E acceptance scenario — design

One scenario file: `integration_test/e2e/dsh_remote_acceptance_test.dart`.
It starts from the shape of `example_acceptance_test.dart` /
`acceptance_support.dart` and runs in the incremental `/e2e` harness
(`e2e-android.yml`; real endpoint only for same-repo PRs — infra PR #1105).

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

## Steps (real mode)

Each numbered step ends with `capture(..., '<name>')`; the names match
`docs/cuplivo-dsh/ui-spec.md` references R1–R11.

1. `bootSeededApp` (existing helper).
2. Open the drawer, tap the `+` action of the owner list → the create menu.
   Assert the third row `DeepSeek Harness` exists (R1); screenshot
   `r1_create_menu`.
3. Tap it → the mode sheet → `直接连接` → the direct-connect form.
4. Enter the name `DeepSeek Harness` and the tokenized URL; tap `确认`.
   Wait for the assistant card in 助手与群聊 (R3) and for the link status to be
   ready; screenshot `r3_connected_card`.
5. Open the DSH assistant settings page via the card's pencil; assert the four
   tabs (连接设置/通用设置/模型/内容) (R2); screenshot `r2_settings_connection`.
   Switch to 通用设置 and assert the two toggles (R8): screenshot
   `r8_general_settings`; switch back to 连接设置.
6. Back to the owner list, then home; open the local drawer and tap the
   current-assistant header tile so the inline owner picker lists every owner:
   assert the `DeepSeek Harness` row with its whale avatar/pencil (R4);
   screenshot `r4_local_sidebar`. Tap the row → harness mode. Assert the drawer
   sections (插件/自动化任务/更多 + workspace + session rows) (R5); screenshot
   `r5_dsh_drawer`.
7. Create a new session and send a short prompt (e.g. `你好，请用一句话介绍你自己`),
   wait for the streamed assistant answer (poll the transcript widget until a
   non-empty assistant item appears, with a generous timeout), assert the
   composer/model pill/subtitle (R6); screenshot `r6_chat`.
8. Open the right rail; assert it pushes the chat (the chat's width/offset
   changed) and the rail cards render (R7, with 浏览器 intentionally absent —
   capability parity) ; screenshot `r7_right_rail`.
9. Open 模型 settings from the assistant settings page; assert provider rows
   (R9) and the 自定义提供商 row first (R10); screenshot `r9_models`; open the
   add-provider picker (R10) and the custom provider detail form (R11);
   screenshots `r10_add_provider`, `r11_provider_detail`.
10. `expect(tester.takeException(), isNull)` and a final capture
    `final_state`.

The scenario leaves created sessions on the E2E host (`/var/lib/dsh-e2e`); the
operator resets with `dsh-e2e-reset` when deterministic state matters. It must
not depend on pre-existing sessions.

## Stable test hooks

Widgets that the scenario drives expose a `ValueKey` (or `const Key`) so the
test does not depend on localized text: `dsh-create-menu-item`,
`dsh-engine-mode`, `dsh-connect-name`, `dsh-connect-url`, `dsh-connect-confirm`,
`dsh-owner-card`, `dsh-owner-row`, `dsh-settings-tabs`, `dsh-drawer-entries`,
`dsh-session-row`, `dsh-new-session`, `dsh-composer`, `dsh-send`,
`dsh-right-rail-button`, `dsh-right-rail`, `dsh-models-tab`,
`dsh-transcript`. Owners own their keys in their widgets; the scenario only reads
them.

## Timeouts and flakiness

- Whole test `Timeout(Duration(minutes: 10))`, each network wait bounded by
  `pumpUntil` with a message naming the expected state.
- Model answers in the E2E host use the temporary key; the prompt must stay
  short to keep the run inside the emulator budget.
- The scenario is not a visual regression baseline; its screenshots are the
  acceptance evidence compared against the reference images in the PR.
