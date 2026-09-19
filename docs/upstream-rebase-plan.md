# Cuplivo v4.0.0 Upstream Re-baseline Plan

> Single page of record for re-basing the Cuplivo fork onto upstream Kelivo.
> Approved plan: replay (never merge), drive to release-ready; **the actual release is executed manually by the user** (no tag / `publish_release` / GitHub Release by the agent).

## 0. Baseline & Branch Model (locked 2026-09)

| Item | Value |
|---|---|
| Old line (archive/LTS) | `cuplivo` → `ee54b508` (= `origin/master`, v3.2.1+40) |
| Merge base | `c8c9ff37` (2026-06-22) |
| Upstream baseline (locked) | `upstream/master` = **`915a8b1d`** (2026-09-17, v1.2.7+76) |
| New integration line | `cuplivo-v4` (from `915a8b1d`) |
| Replay branches | `port/<feature>` (one per feature, `cherry-pick -x` / rewrite, `range-diff` evidence) |
| Release | v4.0.0 (+41), same app id `com.cup11.cuplivo`, artifact contract `Cuplivo_<platform>_<v>_*` unchanged |

Delta measured at freeze: fork ahead 1070 commits (700 non-merge, modifying delta 552 files / +129,719 −48,934); upstream +496 commits.

Hard rules: no wholesale `git merge upstream/*` into the line; no `-X ours` / `-X theirs`; subagents use `qwen-token-plan-cn/qwen3.8-flash`; the old `kelivo.sqlite` (schema v23) is never deleted during migration; product identity (app id, artifact names, update endpoint `cuplivo/cuplivo`) never changes.

## 1. Four-Category Triage

### Collapse (use upstream; no replay)
| Feature | Upstream equivalent | Note |
|---|---|---|
| OAuth sign-in (Grok/Codex device-code) | `provider_oauth.dart` `{chatgpt, grok, kimi, claude}` superset | users re-login once (accepted); old localOnly SP tokens not migrated |
| Theme system core | upstream `lib/theme/` same architecture, ahead (`surface_ladder.dart`) | adopt upstream; keep fork-only `tool/check_colors.py` + ADR 0038/0040 |
| Workspace/sandbox/skills/scheduled tasks/background generation | upstream mature implementations | fork-side copies die with the old line |
| Android sandbox runtime (proot) | upstream: `fetch_proot.sh` + cpp + ndk28 | adopt upstream lineage; readelf gate adapts |

### Keep (fork identity; replay always)
Branding patch series replayed onto the new baseline (see §3 P1): platform ids, binary icons (carried, never regenerated), display names, Tier-A outbound identity (UA/OpenRouter/MCP client name/notification strings), QQ group, README positioning, artifact & update contract. ADR-0029 kept-by-design residue (`kelivo_*` tool names, `@kelivo/*` server ids, external URLs) untouched.

### Port — signature (5; user-selected)
| Feature | Upstream status | Main cuplivo surfaces | Risks |
|---|---|---|---|
| Group chat + Director | absent | `lib/features/group_chat/**`, GroupChat(Rows)/Member tables, kind=group | AGENTS(old) 3.20 triple wiring: clearAllData/export/restore; migration must carry group data |
| Proactive care (Ta 的来信) | partial (scheduled tasks ≠ mechanism) | `proactive_care_*` services, 5 assistant cols + 2 conversation cols, MethodChannel, alarms | semantic clash; Android-only |
| Incremental backup + LAN sync | absent (upstream = whole-DB snapshot ZIP v2 + S3) | `sync/lan_sync_*`, `incremental_backup.dart`, `data_sync.dart` | highest conflict; redesign on upstream backup v2; website helper coupling |
| Multi-AI side-by-side | absent | `multi_ai_engine.dart` (1052 l), HomeViewModel weaving | strip `webChatMultiAIFallback*` (web view dropped) |
| Message reply (QQ-style quote) | absent | `message_rows.quote_json` (v20), selection/menu UI | new column on the NEW lineage |

### Port — utilities (13; user-selected, all)
image-gen options panel · input drafts · AI log analysis · startup assistant pin · stats filters · smart OCR + PDF/Office processing modes (one combined assistant migration) · reasoning-effort vocabulary · subsequence Markdown copy · math formula export (LaTeX/PNG) · world book groups (backup format) · save temp conversations (~60 lines) · translate visible-language management.

### Dead (not replayed; user decision)
- Web conversation view + style library + WebView PDF export (platform channels, vendored JS, shell server) — dropped; its CI gate `web-chat-checks` removed.
- `cache_rows` (OCR cache), `deleted_record_rows` (recovery bundles) — no upstream counterpart, not ported.

## 2. Data Migration (same app id, first-run auto)

Upstream `acceptsLiveSchema` accepts only 0/3 → the v23 `kelivo.sqlite` can never be opened live. Design: first-run detect `kelivo.sqlite` → vendored **read-only v23 reader** (Cuplivo Drift schema classes) → transcribe to upstream legacy shape (`chats.json` v1 + `settings.json`) → feed upstream `replaceAllDataFromBackup` + `BusinessRestoreService` → rename old file `kelivo.sqlite.pre-v4.bak` (never delete). Field-mapping spec: agent report of 2026-09 + `git show 0b950eeb:lib/core/services/backup/kelivo_v2_compat_converter.dart` (1060-line field-level spec; note `0b950eeb` is NOT an ancestor of `ee54b508`). Group-chat/proactive-care/quote data migrates only as the matching Port features land. Business keys already align with upstream `sourceKey`s; unknown fields are tolerated upstream. Website helper (`website/packages/core`) supports new format + keeps 3.2.1 format in the same change (ADR-0060 single-PR rule).

## 3. Replay Order & Verification Gates

P1a package rename (`package:Cuplivo/`→`package:Cuplivo/`, one mechanical pass, its own commit, always first) → P1b branding → P2 CI/build (`build-stable-44.yml`: drop web-chat-checks, readelf gate ↔ upstream proot, keep MSVC runtime bundling #1053, Linux icon key ↔ binary name, keep fallback injection; do NOT adopt upstream's workflow wholesale) → P3 migration (+tests) → P4 schema features (reply → group chat → OCR+doc → proactive care; upstream `SchemaMigrations` + `drift_schemas/` convention; build_runner; heal-coverage judgment per ADR-0019 equivalent) → P5 services (incremental/LAN after group chat; then utilities small→large; `rg "SharedPreferences" lib/core/providers` checkpoint) → P6 docs/governance (new ADR; ADR-0067 superseded-by; AGENTS.md persistence section updated to upstream lineage; README×2 unfreeze + features rewrite; CHANGELOG×2; website unfreeze; migration guide) → P7 release-ready (analyze+tests green → push origin → GHA `workflow_dispatch` `publish_release=false` → release notes draft + manual test plan + publish instructions → hand off; STOP).

Per-patch gates: `range-diff` equivalence, `dart format` changed paths, `flutter gen-l10n` when ARBs touched (4-file sync), `build_runner` when schema touched, `dart analyze --fatal-infos lib test` zero issues, targeted `flutter test` subsets, desktop/platform statement when applicable. Upstream-line AGENTS.md applies on this branch (drift_schemas, lucide icons, no desktop bottom sheets, full `flutter test` in CI).

## 4. Rollback / Trigger Conditions

- Migration converter unprovable-safe ⇒ ship v4.0.0 with guided backup-import fallback (ask user before deviating).
- Incremental/LAN redesign exceeds budget ⇒ fallback "v4.0 upstream snapshot backup only, incremental in 4.1" (ask user at that decision point).
- Upstream moves past `915a8b1d` mid-work ⇒ finish on locked SHA; follow the next minor after release (per-release routine: fetch, replay, shrink delta).
- Any data-loss risk in migration ⇒ abort migration path, keep old file, surface error — never partial writes.

## 5. Artifacts Checklist

- [x] Baseline locked `915a8b1d`; branches `cuplivo` (archive) + `cuplivo-v4` (integration)
- [ ] This plan committed on `cuplivo-v4`
- [ ] Four-category table (§1) — done, evidence in session research reports
- [ ] `port/*` branches + `range-diff` equivalence evidence per feature
- [ ] Migration round-trip tests (v23 fixture → v3 asserts)
- [ ] Migration guide (old feature → upstream equivalent; OAuth re-login; web view removal)
- [ ] GHA artifacts built with `publish_release=false`
- [ ] Release notes draft + manual test plan + user publish instructions

## 本地全量测试的已知基线失败（root 环境，2026-09-17 核实）

在干净基线 915a8b1d 上以 root 复现、与分支改动无关的失败：
- `test/core/services/auth/`：17 例（claude_oauth 10 + codex 2 + kimi 5；干净基线 915a8b1d 同为 +67/-17，已复核）
- `test/features/home/widgets/chat_input_bar_attachment_cleanup_test.dart` "源文件删除失败…"：chmod 0555 对 root 无效，删除成功导致断言落空（环境性）

发布验证口径：本地全量 `flutter test` 以"相对基线无新增失败"为准；CI（非 root）为最终门。另：`flutter test | tail` 的管道退出码是 tail 的，须用完整输出判断。

## P5c-14 多 AI 对比移植侦察（round 18 记录，供全新上下文续作）

**Fork 文件清单**（`git show cuplivo:<path>`）：
- `lib/features/home/services/multi_ai_engine.dart` — 1184 行，`MultiAIEngine extends ChangeNotifier` + `MultiAIMode` + `_MultiAIResponseOperation{,Tracker}`。groupId=threadId 双用（collapse + 卡片分组），round 成员在运行时 `_anchorThreads`（不落消息）
- `lib/features/home/services/message_pipeline.dart` — 221 行，多 AI 重试/再生成的请求重建管道
- `lib/features/home/widgets/multi_ai_comparison_view.dart` — 593 行，对比视图

**关键分叉**（WT 服务 API 已不同，79 errors 直拷不通）：
1. `MessageGenerationService.buildUserMediaPaths` — WT 无（WT: 生成上下文直接收 `userImagePaths`）
2. `MessageGenerationService.resolveRequestOptionsFromMessages` — WT 无（AD-0033 请求元数据回放）
3. `prepareApiMessagesWithInjections` 参数集不同（fork 有 `includeUserQuickInstructions`）
4. `buildGenerationContext` fork 用 `userMediaPaths`/`requestExtraBody`；WT 用 `userImagePaths`/`extraBody`+`imageOptionsBody`
5. `ChatInputData.extraBody` — fork 有；WT 是 `imageOptionsBody`（P5c-8 本轮系列加的）
6. 依赖 `chat_controller.dart`/`stream_controller.dart`/`ask_user_interaction_service`/`tool_approval_service` 均有分叉（39/203 diff 行）

**建议路径**：全新上下文 round；(a) 先移植/对齐 MessageGenerationService 缺失方法（或改写 pipeline 调用点适配 WT API）；(b) 引擎+视图直拷+import 重定基+编译驱动修复；(c) home_page/controller/actions 接线（fork grep MultiAIEngine 三文件）；(d) 剥除 webChatMultiAIFallback*（engine 内 0 处——已确认不在引擎，在别处，需 grep）；(e) subgroupId：WT ChatMessage 已有 groupId 无 subgroupId（P4 记录），引擎用 threadId 双用可绕过列需求。

## P5c-14 多 AI 引擎移植执行卡（round 20 记录，四错误簇+修法）

基座已就绪（`5e746d6d`）：schema v6 subgroupId 全链贯通、message_pipeline.dart 已 WT 化（`requestMetadataAnchorMessageId`/`buildUserMediaPaths`/`extraBody` 均已适配）。

直拷 `git show cuplivo:lib/features/home/services/multi_ai_engine.dart` + import 重定基后剩 4 簇（共 25 错）：

1. **Future vs List**（9 错）：fork `ChatController.messagesForCompleteHistoryContext` 返回同步 List；WT :735 返回 `Future<List<ChatMessage>>`。修法：引擎内所有该调用点加 `await`（调用者已是 async）；`appendPersistedTailMessage` WT :812 为 `Future<void>`（fork 同步 bool）→ 引擎 `if (_chatController.appendPersistedTailMessage(...))` 改 `await` 后判断（需看 fork 语义：true=接受 append；WT 版返回什么需读实现，若 void 则删条件）。
2. **`subgroupActiveGroupIds`**（1 错，:160）：fork ChatController getter——从 fork `chat_controller.dart` 移植（grep `subgroupActiveGroupIds`，按 subgroupId!=null 的消息聚合 groupId）。
3. **`subgroupId:` named 参数**（2 错，:340/:637）：`MessageGenerationService.createAssistantPlaceholder`/`createUserMessage` 无该参——两方法签名加 `String? subgroupId`（默认 null）透传到 ChatMessage 构造。
4. **`requestMetadataAnchorMessageId`**（2 错，:382/:682）：WT 管道无此参（无元数据回放）——引擎调用点删该实参即可。另 :356/:426 non_bool_condition 是簇 1 的 Future<bool> 副作用，await 后自消。

视图（multi_ai_comparison_view.dart 593 行）独立错误面：WindowsAxTreeSafeTooltip（WT 无→用 Tooltip 替换 2 处）、ReadingModePage/MessageMoreAction.readingMode（WT 无→删该 menu 项）、HomePageController.multiAIEngine/addMultiAIModels（接线时加）、l10n multiAI* 键四语言。接线点：home_page_controller/home_view_model/chat_actions/home_page（fork grep MultiAIEngine）。

## P5c-14 视图+接线执行卡（round 22 记录）

引擎/schema/l10n 已就绪（`9b68c2d4`+`92cc44e0`）。视图 `multi_ai_comparison_view.dart` 直拷+import 重定基后仅剩 4 个符号，全在 HomePageController：

1. **`multiAIEngine` getter**：fork home_page_controller.dart :210 `late final MultiAIEngine multiAIEngine;` + :547-563 构造（chatService/chatController/messageGenerationService/streamController + `pipeline: _viewModel.pipeline` + `onMaybeUpdateProactiveCare`）+ :562 addListener(notifyListeners)。WT 差异：无 `_viewModel.pipeline`（WT pipeline 在哪构造需查 chat_actions/message_pipeline 使用处）；onMaybeUpdateProactiveCare 缺省可去掉（fork 参数可选性需查引擎签名）。
2. **`retryMultiAIThread`**：fork :1565-1581（读 settings+currentAssistant → engine.retryThread）——基本直拷。
3. **`switchToSynthesizeMode`**：fork :2790-2810（showSynthesizeTaskSelector + engine.setMode + 预填 prompt）——依赖 `showSynthesizeTaskSelector`（fork 哪个文件需 grep）。
4. **`addMultiAIModels`**：fork :2927-2966（showMultiModelSelector + ModelMultiSelectState + engine.addModels?）——依赖 `showMultiModelSelector`/`ModelMultiSelectState`（grep fork）。

视图结构性修复已完成并验证过的：WindowsAxTreeSafeTooltip→Tooltip、readingMode else-if 删除、canCreateBranch:false、hideActions 去 multiAI 枚举。视图本身不再有其它错误（20 错全部消除验证于本回合）。home_page/home_view_model/chat_actions 的模式入口 UI 按 fork grep MultiAIEngine 三文件对照接。
