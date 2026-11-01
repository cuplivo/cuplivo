# 群聊实现计划（已完成）

> 状态：**已实现**。本文记录最终落地形态、与设计稿的差异，以及验证证据。
> 分支：`feat/group-chat`，基线 `f0c68d4f5`（master，schema 5）。

## 1. 目标（用户原话的七条）

1. 不升 schema version → 已守住，`AppDatabase.currentSchemaVersion == 5`。
2. 丢弃 v3 中间态，只按最终设计做。
3. UI / 数据结构重设计先走 clarity round（已完成 5 轮，见 §3）。
4. 一次做完整，不按“v1 只做 xxx”切功能。
5. 明确回答“一个群聊是否允许多个 conversation” → 允许，见 §2。
6. 输入框必须支持：助手 × n（折叠头像 → 成员清单 → 助手编辑）、附件/拍照/相册/粘贴、
   浏览器、上下文管理、迷你地图、上下文指示；架构要 DRY。
7. 桌面端与手机端同一套信息架构。

## 2. 最终结论（已获用户 accept）

- **一个群聊有多个会话（话题）**。群是拥有会话的实体；每个会话通过 `extras['groupChat.id']` 指向群。
- **群与助手混排在同一个侧栏列表**，共用一个拖拽顺序（`ChatOwnersProvider`）。
- **输入框左下角是一叠完全折叠的头像**，整叠一个按钮；点开是成员清单：成员 → 助手编辑、
  邀请助手、群聊设置。
- **导演模型只在群设置里出现**，作为“默认模型”的跳转入口。
- **不软删除**：群实体 + 全部会话放进同一个 `RecycleGroup`，走现有回收站；删除前先停掉该群所有
  在跑的整轮（与删助手同一条不变量：删除即停止）。
- **整轮占用**：用户消息 → 最后一个 speaker 结束，整轮持有 conversation claim；期间再次发送走现有单槽队列。
- **schema 仍为 5**：`extension_entity_rows(kind='groupChat')`、`conversation_rows.extras_json`、
  `message_rows.sender_id`。

## 3. 设计文件

| 文件 | 作用 |
| --- | --- |
| `architecture.md` | 完整架构：数据流、不变量、失败模式（初版） |
| `architecture-r2.md` | 定稿修订：`assistant_id` 对比、回收站统一、队列 |
| `variant-a-members.html` | 最终 UI：折叠头像 + 成员清单 + 导演跳转 |
| `variant-group-settings.html` | 群设置定稿：头像即入口、桌面/移动同一份菜单 |
| `topic-title-pipeline.md` | 话题标题流水线（模型链、触发点、失败模式、blast radius） |
| `variant-a*.html` / `variant-b.html` / `shot-*.png` | 中间稿，仅作记录 |

## 4. 落地清单

### 4.1 新增文件

| 文件 | 内容 |
| --- | --- |
| `lib/core/models/group_chat.dart` | 群模型：id/name/avatar/memberIds/maxSpeakerTurns(1..6)/时间戳，payload `v:1` |
| `lib/core/models/chat_owner.dart` | 侧栏行身份：`assistant:<id>` / `group:<id>` |
| `lib/core/providers/group_chat_provider.dart` | 群列表、`byId`、`forConversation`、create/update/delete（走回收站） |
| `lib/core/providers/chat_owners_provider.dart` | 混合顺序（存 `chat_owner_order_v1`），与来源对账 |
| `lib/features/group_chat/services/group_director.dart` | 导演：`select_speaker` / `end_turn` 工具调用，2 次尝试，20s 超时，失败返回 unavailable |
| `lib/features/group_chat/services/group_transcript.dart` | 压平转写（`[Name]` + 公开文本）、群说明、导演视角摘要 |
| `lib/features/group_chat/widgets/group_member_cluster.dart` | 折叠头像叠，整叠一个点击目标；>4 显示 `+N`；空群只有 ＋ |
| `lib/features/group_chat/widgets/group_member_list.dart` | 成员清单、成员选择器、新建表单、`GroupAvatar` |
| `lib/features/group_chat/widgets/group_settings_view.dart` | 设置主体：名字、成员增删、导演跳转、每轮上限、删除群 |
| `lib/features/group_chat/pages/group_settings_page.dart` | 移动端设置页 |
| `lib/features/group_chat/group_navigation.dart` | 打开清单/设置/邀请/新建（移动端 sheet，桌面 dialog） |
| `lib/features/group_chat/group_actions.dart` | `deleteGroupChat`：先停整轮再走回收站删除，两个入口共用 |

### 4.2 修改的关键位置

- `chat_message.dart` / `chat_database_repository.dart`：`senderId` 全链路（插入、更新、读取、复制会话）。
- `conversation.dart`：`groupChatId` 扩展读写；群会话 `assistantId` 恒为 null。
- `chat_service.dart`：`createConversation/createDraftConversation(groupChatId:)`、`beginUserMessage`、
  `beginAssistantGeneration/beginRegeneration(senderId:)`、`deleteConversationsForGroup`、
  `defaultConversationTitle`。
- `composer_draft_store.dart`：新会话草稿 owner 按 `group:<id>` 区分，避免群草稿串到全局会话。
- `business_data.dart` / `backup_content_filter.dart` / `business_settings_router.dart`：
  `BusinessEntityKind.groupChat`（`group_chats_v1`）、归入 `BackupCategory.chats`、payload 校验、
  `group_director_model_v1` + `chat_owner_order_v1` 进入偏好注册表。
- `business_repository.dart`：`deleteEntity(..., group:)` 公开回收站分组。
- `chat_actions.dart`：`sendGroupMessage` / `_runGroupRound` / `cancelGroupRound` /
  `runAssistantTurn`；`_setConversationLoading` 成为“整轮持锁 + 回合结算”的唯一收口。
- `home_view_model.dart`：群发送分支、首条消息命名话题、轮结束排空队列、群内停止走 `cancelGroupRound`。
- `chat_input_section.dart` / `chat_input_bar.dart`：`leading` 槽放折叠头像；群模式隐藏模型/搜索/
  推理/工具/快捷短语/学习模式，保留附件、浏览器、迷你地图、上下文管理与上下文环（两端一致）。
- `message_list_view.dart`：`resolveAssistant(message)` 按 `senderId` 解析作者；1:1 传 null 不变。
- `side_drawer.dart`：混合 owner 列表 + 同一拖拽顺序、群 tile（点击开最近话题/新建）、群话题过滤、
  “新建群聊”入口、群长按菜单（设置/删除）。
- `home_page.dart`：群模式标题不显示模型胶囊、composer 传群、消息列表传 resolver。
- `default_model_page.dart` + `settings_provider.dart`：全局导演模型（默认跟随默认模型，provider/model
  退役时清理）。
- `main.dart`：注册 `GroupChatProvider`、`ChatOwnersProvider`、LAN sync 重载。

### 4.3 与设计稿的差异（有意为之）

1. **导演失败提示是一次性 snackbar**，不是常驻提示条：群不会因为导演不可用而看起来坏掉，
   但也不会长期占位。
2. 群没有独立的标题提示词，也没有每群一个标题模型（见 `topic-title-pipeline.md`）。

### 4.4 收尾两轮（本轮）

| 需求 | 落地 |
| --- | --- |
| 群头像可编辑 | 头像即入口：`GroupAvatar` 走共享 `AvatarValue`（emoji / URL / 本地文件 / 兜底）；设置页点头像 → 共享 `showAvatarMenu`（桌面锚定菜单、移动端 sheet）；助手头像菜单与群共用同一份实现，五项动作、顺序、校验一致 |
| 话题标题走标题模型 | 触发点移到整轮结束（`onGroupRoundFinished`）；模型链抽成 `resolveTitleModel`（标题模型 → 导演模型 → 全局默认，群；1:1 链路不变）；`generateTitleSource` 增加逐行渲染器，群用 `[名字]: 公开文本`；删掉首条消息 24 字截断 |

随之删除重复实现：助手头像的两份菜单/三个对话框（`_showAvatarPicker`、`_openAssistantAvatarMenu`、
`_inputAvatarUrl`、`_inputQQAvatar`、`_pickEmoji`、`_pickLocalImage`）与 `_AssistantEmojiAvatar`，
合计约 700 行，改为 `lib/shared/widgets/avatar_menu.dart` + `avatar_value.dart` 各一份。

### 4.5 验收后的两轮

真机验收在 `dirty:499df492251c773b` 上判了三条问题，两条走了新的 clarity 轮：

| 问题 | 轮次 | 落地 |
| --- | --- | --- |
| 模型在回复前自发写 `[STEM Mentor v5]` | 伪代码轮（`topic-speaker-injection.md`，已接受） | 群转写不再把别人的话塞进 `assistant`：只有本人的轮留在 `assistant`，其余翻成 `user` 并套 `<group_message from="名字">`；`buildApiMessages` 给这类 user 轮打进程内标记且不发 revision id；「最后一条用户消息」（图片、搜索词、视频挂载）统一走 `lastHumanUserIndex` |
| 助手管理页没有群聊，两套拖拽顺序 | UI 轮（`variant-manage-page.html`，选 A） | 管理页与侧栏共用 `ChatOwnersProvider` 一份顺序；`AssistantProvider.reorderAssistants` / `reorderAssistantsWithin` 删除；侧栏标签段改走 `reorderWithin`；`+` 同时提供新建助手与新建群聊 |
| 桌面端「默认模型」看不到导演模型 | 无需决策 | `DesktopDefaultModelPane` 补上导演模型卡片（移动端 `DefaultModelPage` 早就有，桌面漏了） |

命名再走一轮（`variant-manage-page-naming.html`，选 B）：这一页叫「助手与群聊」，
`settingsPageChatOwners` 替换 `settingsPageAssistant`，`desktopAssistantsListTitle` 一并退场。

## 5. 验证
- `dart analyze --fatal-infos lib test integration_test` → **0 issue**。
- 新增测试（14 + 22 = 36 条，全绿）：
  - `test/core/database/group_chat_schema_test.dart`（schema 5、实体行、备份分类、payload 路由、
    `senderId` 写入/重写/复制、1:1 无作者）
  - `test/features/group_chat/group_transcript_test.dart`（压平、丢弃 reasoning/tool/image、
    作者名占位、群说明、导演转写折叠）
  - `test/features/group_chat/group_member_cluster_test.dart`（折叠叠一个点击目标、`+N`、空群、
    成员清单、新建表单校验）
- 全量 `flutter test`：**11 434 passed / 70 skipped / 70 failed**，失败全部落在已登记的
  平台集合与两条已记录的满负载 flake 上，没有一条与本改动相关：
  - 64 `browser_native_engine_test`、`storage_image_usage_test`、`browser_page_card_test`
    —— `docs/flaky-tests.md` 登记的 Windows/无 WebView2 集合；
  - `backup_encryption_test` 取消用例 —— teardown 删临时目录 `errno 32`，文件本次未改；
  - `search_request_logging_test`、`mcp_provider_remote_session_test` —— 满负载下偶发，
    单独跑分别通过（后者 22/22）。

## 6. 未做（明确排除）

- 不升 schema、不加列、不做 90 天软删扫描。
- 不持久化导演日志/消息。
- 群话题不参与 1:1 的 follow-up suggestions、proactive care（标题已改为走标题模型）。
- 侧栏用户头像那一份“链接 / QQ”对话框仍是独立实现，未并入共享菜单。
