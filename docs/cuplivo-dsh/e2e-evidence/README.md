# End-to-end evidence (real DeepSeek Harness host)

These screenshots are the acceptance evidence for PR #1104. They come from the
`Android E2E` workflow (`.github/workflows/e2e-android.yml`, `/e2e`), run
[45045170799](https://github.com/cuplivo/cuplivo/actions/runs/45045170799) on
`feat/cuplivo-dsh` at `ca12b3652`, driving a **real** DSH 0.2.2-rc.1 host over
HTTPS with the repository's `E2E_DSH_URL` / `E2E_DSH_TOKEN` secrets.

The scenario (`integration_test/e2e/dsh_remote_acceptance_test.dart`) runs in
Chinese (`zh_CN`) so the surfaces match the reference images, and captures one
screenshot per numbered reference in `docs/cuplivo-dsh/ui-spec.md`:

| file | reference | surface |
| --- | --- | --- |
| `r1_create_menu.png` | R1 | 助手与群聊 create menu 中的 DeepSeek Harness 行 |
| `r2_settings_connection.png` | R2 | DSH 设置页：连接设置（测试端点已打码） |
| `r2_builtin_plugins.png` | R2 | DSH 设置页：内置插件（Host 插件清单，只读） |
| `r2_agent_presets.png` | R2 | DSH 设置页：Agent 预设（Host roster 合并插件清单） |
| `r3_connected_card.png` | R3 | 助手与群聊中的已连接远程卡片 |
| `r4_local_sidebar.png` | R4 | 本地抽屉把远程列为 owner |
| `r5_dsh_drawer.png` | R5 | DSH 抽屉：插件 / 自动化任务 / 更多 + 工作区与会话 |
| `r6_chat.png` | R6 | 聊天界面与真实流式回答 |
| `r6_preset_menu.png` | R6 | 输入框上方 Agent 预设选择器（Host 真实 roster） |
| `r6_preset_chip.png` | R6 | 选中 PTC 模式后的预设 chip 与权限 chip |
| `r6_plus_menu.png` | R6 | 输入框加号菜单（官方「添加/指令」结构） |
| `r6_tool_turn.png` | R6 | 真实 bash 工具卡片与二轮回答 |
| `r6_context_ring.png` | R6 | 上下文使用比例圆环（真实 contextPressure） |
| `r6_attachment.png` | R6 | 附件 chip、上传与引用附件内容的回答 |
| `r7_right_rail.png` | R7 | 原生右栏（工作区文件 / 新建终端 / 更多工具） |
| `r8_general_settings.png` | R8 | 通用设置：两个纳入范围的设置 |
| `r9_models.png` | R9 | 模型 tab（供应商与启用状态） |
| `r10_add_provider.png` | R10 | 添加供应商（自定义提供商在首行） |
| `r11_provider_detail.png` | R11 | 供应商详情（API 密钥、模型目录） |
| `r12_terminal.png` | R12 | 右栏真实 Host PTY |
| `r12_terminal_command.png` | R12 | 终端写文件后工作区文件列表可见 |
| `r13_text_inline.png` | R13 | 文本文件在右栏内联预览（Host 分页文本读取） |
| `r13_png_inline.png` | R13 | PNG 工作区文件内联预览 |
| `r13_pdf_preview.png` | R13 | PDF 全屏预览页 |
| `r13_binary_preview.png` | R13 | 二进制文件的诚实元数据卡片 |
| `final_state.png` | — | 场景结束时的最后一帧 |

## Official WebUI contracts (`dom-contract/`)

The hosted emulator's Chromium renderer cannot render the official DSH SPA
(a platform limit documented in the PR and in `docs/cuplivo-dsh/e2e-scenario.md`),
so the emulator run proves the native surfaces and the honest fallback there.
The same run's `dom-contract` job executes the exact scripts the app ships
(`tool/e2e/print_dsh_surface_scripts.dart` from `DshSurfaceScripts`) in desktop
Chrome at 412×915 against the same real host, and captures:

| file | surface |
| --- | --- |
| `dom-contract/01-host-root.png` | Host 根页面在 412×915 下的渲染 |
| `dom-contract/02-settings-dialog.png` | 官方设置对话框（分区 General / Models / Built-in plugins / Agent presets） |
| `dom-contract/03-sidebar-panel.png` | 官方侧栏面板（Plugins 落地） |
| `dom-contract/04-right-rail-page.png` | 官方右栏 diff 页落地 |
| `dom-contract/05-more-menu.png` | 官方「更多」弹出菜单 |

Redaction: the real E2E host name in `r2_settings_connection.png` is painted
out; credentials never appear (the stored credential lives in the platform
secure storage and the token is injected by the workflow as a dart-define).
The reference images provided by the owner are untracked and are not part of
this repository.
