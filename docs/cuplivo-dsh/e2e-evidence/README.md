# End-to-end evidence (real DeepSeek Harness host)

These screenshots are the acceptance evidence for PR #1104. They come from the
`Android E2E` workflow (`.github/workflows/e2e-android.yml`, `/e2e`), run
[44657449902](https://github.com/cuplivo/cuplivo/actions/runs/44657449902) on
`feat/cuplivo-dsh` at `6d325ec62`, driving a **real** DSH 0.2.2-rc.1 host over
HTTPS with the repository's `E2E_DSH_URL` / `E2E_DSH_TOKEN` secrets.

The scenario (`integration_test/e2e/dsh_remote_acceptance_test.dart`) runs in
Chinese (`zh_CN`) so the surfaces match the reference images, and captures one
screenshot per numbered reference in `docs/cuplivo-dsh/ui-spec.md`:

| file | reference | surface |
| --- | --- | --- |
| `r1_create_menu.png` | R1 | 助手与群聊 create menu with the DeepSeek Harness row |
| `r2_settings_connection.png` | R2 | DSH assistant settings, connection tab |
| `r3_connected_card.png` | R3 | connected remote card in 助手与群聊 |
| `r4_local_sidebar.png` | R4 | local drawer listing the remote owner |
| `r5_dsh_drawer.png` | R5 | DSH chat drawer (插件 / 自动化任务 / 更多, workspaces, sessions) |
| `r6_chat.png` | R6 | chat surface with a real streamed answer |
| `r7_right_rail.png` | R7 | right rail pushing the chat aside |
| `r8_general_settings.png` | R8 | 通用设置 with the two scoped settings |
| `r9_models.png` | R9 | 模型 tab (providers, 启用/不可用 pills) |
| `r10_add_provider.png` | R10 | add-provider picker, 自定义提供商 first |
| `r11_provider_detail.png` | R11 | existing provider detail (API 密钥, 模型目录) |
| `final_state.png` | — | the last frame of the scenario (models list after R11) |

Redaction: the real E2E host name in `r2_settings_connection.png` is painted
out; credentials never appear (the stored credential is in the platform secure
storage and the token is injected by the workflow as a dart-define). The
reference images themselves are untracked and are not part of this repository.
