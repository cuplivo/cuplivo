# Cuplivo × DeepSeek Harness「遥控模式」集成地图

> 本文是一份**实现前置的地图**，不是设计评审稿。目标：让实现者不必重新读一遍仓库就能开工。
> 范围：为 Cuplivo 增加一种「远程助手」——它不对接某个 LLM API，而是连接一台运行 `dsh web` 的 DeepSeek Harness（下称 DSH）服务器，把 DSH 的会话、模型、权限、工作区、插件面板以 Cuplivo 原生 UI 呈现；会话数据不落 Cuplivo 本地库。
>
> 事实来源：本仓库当前 worktree（`cuplivo-feat-cuplivo-dsh`，基线含 4.x 特性）+ 本机安装的 `@deepseek-ai/dsh@0.2.2-rc.1`（`/usr/local/lib/node_modules/@deepseek-ai/dsh`）+ 需求简报 + `docs/cuplivo-dsh/reference/` 参考图（未跟踪，勿提交）。
> 标注约定：行号均按**写此文件时**的 worktree；`lib/features/harness/**`、`chat_owner*`、`side_drawer.dart` 等正在被实现的文件行号会漂移，**以符号名（函数/类）为准**。DSH 侧引用指包名/文件/函数名（其 `lib/*.js` 为构建产物，行号不稳定）。`[待验证]` = 推断未实测，实现时先用最小脚本打真机验证。
>
> **实现契约优先级**：本文件是“研究地图”。同目录下由团队在实现阶段产出的 `architecture.md`（架构契约）、`implementation-contract.md`（文件归属/流程）、`protocol.md`（DSH 协议实测）、`client-reference.md`（Dart 客户端设计）、`ui-spec.md`（UI 规格）、`e2e-infra.md`（验收基建）是**实现时的权威**；若本文件与它们不一致（尤其是认证模型、文件路径、owner 表示法），以那些文件为准，本文件对应段落已据此校正并标注“已按契约校正”。
>
> **本地构建/测试被明确禁止**（Lead 决议）：不得在本机跑 `flutter test`、`flutter build`、`flutter analyze` 作为验证手段；验证走 PR 的 GitHub Actions。允许的本地步骤只有格式化与代码生成（`dart format`、`flutter gen-l10n`、`python3 tool/l10n/translate.py sync`）以及纯只读的 `grep`/`read`。本文写作本身未运行任何构建/测试。

---

## 0. 结论摘要（先看这十条）

1. **不需要 Drift 迁移，不需要 `build_runner`/drift schema codegen。** 助手是纯 Dart 模型序列化成 JSON 存进 `assistant_rows.payload`；新增字段只改 `Assistant.toJson/fromJson`。
2. **远程不是“助手”，而是第三种 owner**：`ChatOwnerKind` 增加 `harness`（`lib/core/models/chat_owner.dart`），连接记录 `DshRemote` 存在 `dsh_remotes_v1`（`deviceLocal`），复用 `ChatOwnersProvider` 的统一排序/列表/设置页；**不改 `Assistant`、不加 Drift 表/列、不加 `BusinessEntityKind`**。理由与契约见 §1.4。
3. **DSH 会话一律不落库。** 只存“连接记录”（名称/baseUrl/authority/lastError 等，`dsh_remotes_v1`，`deviceLocal`）；**凭据是 v1 cookie，放 `flutter_secure_storage`**（key 按 remote id），启动令牌只在一次登录请求的内存里（见 §1.4/§8.2）。
4. **不复用 `ChatService` / `ChatController` / `HomeViewModel` / `StreamController` 的持久化与生成链路**；只复用它们的**渲染层与输入层**（`MessageListView`、`ChatMessageWidget`、`ChatInputBar`）。聊天数据由新的 `lib/features/dsh/` 域在内存中拼装。
5. **最大改造点是左侧栏**：`SideDrawer` 的会话列表硬编码读 `ChatService.getAllConversations()`（`side_drawer.dart:1591` 一带），必须抽成「可插拔数据源」，否则 DSH 会话无法进列表。
6. **右侧栏桌面端已有 docked/expanded 的几何与交互可抄，但目标要求「把聊天推到屏幕外、不堆叠」**，所以 DSH 右栏不用现有 `DesktopSidePanel` 的 tab 系统，只复用其几何与外观；**移动端没有右侧抽屉**，用 `InteractiveDrawer(side: DrawerSide.right)` 的“child 随进度位移”能力实现推入式（`grep DrawerSide.right` 目前无使用，是新增用法）。见 §5。
7. **DSH 模型绝不能写进 `SettingsProvider.providerConfigs`**（会污染本地聊天、备份与 LAN 同步）。DSH 模型目录来自 `session.modelCatalog()`，只在 DSH 作用域内使用；选择器需要把现有 `model_select_sheet.dart` 的 UI 抽成可复用部件或新写一个同视觉语言的 sheet。
8. **每个新增 preference key 必须注册 `BusinessKeyRegistry.rules`**：debug 构建有 assert（`business_preferences.dart:230` 附近），CI 有源码扫描测试（`test/core/database/business_key_registry_sync_test.dart`）。漏注册 = 红。
9. **每条新文案必须**：`app_en.arb` 加 key + `@key.description`、`app_zh.arb` 加译文，然后 `flutter gen-l10n`；其余 4 个 locale 与指纹必须由 `python3 tool/l10n/translate.py sync` 更新（需要网络+密钥，离线只能手写并自算 fingerprint，不推荐）。CI 会跑 `translate.py check`、`gen-l10n` diff、`dart analyze --fatal-infos`。
10. **协议客户端零新依赖**：`lib/core/dsh/**` 只用 SDK（`dart:io` 的 `HttpClient`/`WebSocket.connect(url, headers:)`），保持 Flutter-free 可单测；明文 LAN DSH 因此也不受 iOS ATS 影响（**不要**用 `cupertino_http`）。UI 层照常用 Cuplivo 的 dio。

---

## 1. 助手模型与 Drift 持久化（新 kind 是否要迁移/代码生成）

### 1.1 模型本身

- 定义：`lib/core/models/assistant.dart:19`（`class Assistant`，构造函数 `:121`）。
- 关键字段（节选）：`id`、`name`、`avatar`、`useAssistantAvatar`、`useAssistantName`、`chatModelProvider`/`chatModelId`、`temperature`、`topP`、`contextMessageSize`、`limitContextMessages`、`streamOutput`、`reasoning`（`ReasoningRequest?`）、`maxTokens`、`systemPrompt`、`allowConversationSystemPrompt/PromptInjection`、`messageTemplate`、`searchEnabled`、`suggestionsEnabled`、`mcpServerIds`、`allowConversationMcp`、`localToolIds`、`defaultWorkspaceId`、`defaultWorkspaceSetup`、`skillIds`、`healthDataTypeIds`、`background` 系列、`customHeaders/customBody`、记忆相关一组、`presetMessages`、`regexRules`、`proactiveCare*`。
- 序列化：`toJson()` 在 `:333`，`fromJson()` 在 `:402`（所有字段都带默认值/容错读取），列表编解码 `encodeList`/`decodeList` 在文件末尾（`:607` 起，`decodeList` 逐条 `fromJson`，坏一条不炸整表）。
- 相关模型：`lib/core/models/reasoning_request.dart`（`ReasoningRequest(level, {budgetTokens})`，`auto`/`off` 静态值）、`lib/core/models/model_spec.dart`（`ModelSpec`/`ReasoningLevel` 等，仅本地 provider 使用）。

### 1.2 持久化链路（为什么加字段不用迁移）

```
AssistantProvider (lib/core/providers/assistant_provider.dart:20)
  ├─ _assistantsKey = 'assistants_v1'                        (:21)
  ├─ _load(): preferences.getString('assistants_v1') → decodeList   (:63-120)
  └─ _persist(): preferences.setString('assistants_v1', encodeList) (:312-321)
        │
        ▼
BusinessPreferences (lib/core/database/business_preferences.dart)
  ├─ _entityKindForKey('assistants_v1') → BusinessEntityKind.assistant  (:289-296)
  └─ setMany → BusinessSettingsRouter.normalizeAndRoute(next) → repository.writeBatch(entities: …)
        │
        ▼
ChatDatabaseRepository → Drift 表 assistant_rows (id, sort_order, payload TEXT, updated_at)
  定义：lib/core/database/app_database.dart:421
  种类声明：lib/core/database/business_data.dart:9-14（sourceKey 'assistants_v1'，tableName 'assistant_rows'）
```

结论：**`assistant_rows.payload` 是 JSON 文本列**，一整份 `Assistant` JSON 存一行；新增字段根本不触碰 SQLite schema。反之，**只有新增 Drift 表/列**才需要 §1.6 的 codegen 流程。

其他持久化要点：
- `AssistantProvider` 还写 `current_assistant_id_v1`（`:326 setCurrentAssistant`）、`orphaned_conversations_assistant_id_v1`（孤儿会话归属）。
- 删除走 `_persist(group: …)` 的 removalGroup，使「列表里不再有它」这次写同时登记回收站条目（`:635 deleteAssistant` → `:659 _persist(group:)`）。远程助手同样享受这个删除语义，不必另写。
- 各 provider 的加载是**同步缓存 + 异步加载**语义：`loaded` Future、`_isLoaded`、`ensureDefaults(context)`（`:162`，需要 `AppLocalizations`，所以不能在建 provider 时创建默认助手）。

### 1.3 会被哪些现有机制读到（改成新 kind 时的风险面）

| 机制 | 位置 | 新 kind 的影响 |
|---|---|---|
| 备份合并 | `lib/core/database/business_settings_merger.dart:204-227` `_mergeAssistants`：按 id 合并 `{...local, ...incoming}`——incoming 覆盖同名字段，本地独有字段保留（`avatar`/`background` 另有显式保留） | 新增 `kind`/`dsh` 会随 incoming 覆盖；跨设备恢复后 DSH 助手存在但连接信息可能属于另一台设备 → UI 必须处理「未连接」态 |
| 备份分类 | `lib/core/database/backup_content_filter.dart:12-19`：`assistants_v1`（及 `current_assistant_id_v1`、`orphaned_…`、`assistant_tag*`）→ `BackupCategory.assistants` | DSH 助手会进入「助手」备份分类；若把 token 放在 payload 里，则会跨备份/跨 LAN 同步（与 provider API key 现状一致，见 §1.4） |
| LAN 同步 | `lib/core/services/sync/sync_family_registry.dart` 中 `assistants` 家族（`assistant_rows`，synced/business）；‑ ADR 见 `docs/adr/0003-lan-sync-architecture.md` | 同上：整行 JSON 同步到同账号其他设备 |
| 历史契约测试 | `test/core/database/assistant_upgrade_contract_test.dart` + `test/fixtures/assistants/historical_writers.json` | 新字段必须**可选**（缺省安全），旧 JSON 必须还能读；建议加一条 fixture 覆盖「没有 kind 字段」的旧数据 |
| 助手复制/级联删除/搜索等 | `test/core/providers/assistant_provider_*`、`test/core/models/assistant_*` | 复制 DSH 助手时应复制 kind 但**不复制连接凭据**（或明确复制，看产品决定）；搜索不索引远程内容 |
| 编辑页 | `lib/features/assistant/pages/assistant_settings_edit_page.dart:93` 的 `_AssistantEditTabSpec` / `:107` 的 `_assistantEditTabSpecs` | **不适用**：DSH 不是 Assistant（§1.4），天然不会进这个页面；其设置走 `lib/features/harness/pages/assistant/dsh_assistant_settings_page.dart` |

### 1.4 最终表示法（已按 `architecture.md` 契约校正）：第三种 owner + 连接记录

**结论：DSH 不是 `Assistant`，而是 `ChatOwner` 的第三种 kind。** 实现契约（`docs/cuplivo-dsh/architecture.md`、`implementation-contract.md`）已经把这条定死，研究阶段讨论过的 “`Assistant.kind = dshRemote` + `dsh` 子对象” 方案**被否决**。

**数据形状**
```dart
// lib/core/models/chat_owner.dart
enum ChatOwnerKind { assistant, group, harness }   // 新增 harness
const ChatOwner.harness(String id);                // key = 'harness:<id>'

// lib/features/harness/models/dsh_remote.dart —— 一条连接记录
DshRemote {
  String id;            // 同时是 ChatOwner id 与 secure-storage key 后缀
  String name;          // 用户可改，默认产品名
  String baseUrl;       // 源站，无 query：http://192.168.1.20:3080
  String authority;     // host[:port]，cookie 绑定用
  bool secure;          // https 与否（决定 cookie 是否 Secure）
  DateTime createdAt;
  DateTime? lastConnectedAt;
  String? lastError;    // DshFailure.name；UI 映射成本地化句子
}
```
- 存储：`dsh_remotes_v1`（`lib/features/harness/services/dsh_remote_store.dart:21`，`JsonBlobStore` 子类，写队列串行）——JSON blob，无 Drift 迁移、无 codegen。
- 凭据：**只存 v1 cookie，放 `flutter_secure_storage`**（`lib/features/harness/services/dsh_credential_store.dart`，key 前缀 `cuplivo.dsh.cookie.`）；**启动令牌不持久化**（登录用一次，之后丢弃）。
- 统一 owner 列表：`ChatOwnersProvider` 增加第三个窄数据源 `HarnessOwnerSource`（`lib/core` 不 import feature），`chat_owner_order_v1` 新增 `harness:<id>` 键参与同一套拖拽顺序。

**加入新 kind 时必须审计（已在 `chat_owner.dart` 的 doc comment 固化）**
| 站点 | 行为 |
|---|---|
| `ChatOwnersProvider` | 第三数据源；排序键 `harness:<id>` |
| `ChatOwnerSettingsPage` / `_DesktopAssistantsBody` | 行解析 harness owner、渲染远程卡片、创建菜单加第三项 |
| `SideDrawer` | 渲染远程行（鲸鱼图标/名称），铅笔 → DSH 助手设置页；行点击走既有 `onOpenOwner` seam |
| `HomePageController.openOwner` | 在做任何会话逻辑**之前**按 `isHarness` 分支（远程不拥有本地会话） |
| `_syncDefaultAssistant` | 不变（harness 永不拥有打开的本地会话） |
| `ownerOfConversation` / `ChatFrostedBackdrop` | 不变（harness 永不是会话 owner） |
| `assistant_select_sheet` / `group_member_list` | 不变（都基于 `Assistant` 构建，harness 不是 Assistant） |
| 标签分节 | 不变（标签只归 assistant，harness 排在未分组区） |

**为什么否决 `Assistant.kind`**（保留作为设计记录）
1. 每条 assistant 路径都假设“有模型/提示词/记忆/本地会话”：`resolveChatModel`、`isReasoningModel/isToolModel`、`AssistantSettingsEditPage`、会话迁移、群成员、标签……全部要加 `if (kind == dsh)`，且漏一处就产生“没有模型的助手”运行时错误。
2. 备份合并/LAN 同步会带走连接记录甚至凭据（`assistants_v1` 是 synced 实体），与 `architecture.md` 的 “connection record is local / credentials are not settings” 不变量冲突。
3. 侧栏同一行会存在两种表示（Assistant JSON vs 连接记录），排序/删除/编辑语义要维护两套。
4. 旧版本 Cuplivo 不识别新字段，恢复备份会丢 `kind`/`dsh`（见 §12.4 风险 10）。

> 若要“跨设备带连接列表”：只同步 `DshRemote`（无 cookie），另一台设备显示“未连接、需粘贴链接”。当前契约选择 `deviceLocal`（server 地址属于本设备网络路径），不随备份/同步走。

### 1.5 新 preference key 的硬性注册（CI 会拦）

- 规则表：`lib/core/database/business_settings_router.dart:122` 起 `BusinessKeyRegistry.rules`；`KeyPolicy`（`:15-38`）、`PolicyReason`（封闭枚举，`:40-83`）、`KeyRule(policy, reason, note)`（`:85-92`）。
- key 命名形如 `^[a-z][a-z0-9_]*_v\d+$`（`appKeyPattern`，`:113`）。
- 两个守卫：`business_preferences.dart:231` 的 debug assert（未注册 key 直接崩）；`test/core/database/business_key_registry_sync_test.dart:269` 的源码扫描（`test('every preference key the app writes has a row')`）。动态拼接 key 有白名单机制；实现时优先字面量。
- 本特性**唯一新增 key**：`dsh_remotes_v1` → `KeyPolicy.deviceLocal` + `PolicyReason.networkEnvironment`（说明：这台设备能到达的 DSH 地址属于网络环境，不随备份/同步走）。**v1 cookie 不是 preference key**（secure storage）；**启动令牌不落盘**；`dsh_view_v1` 之类的 UI 状态缓存与架构不变量 1（不缓存 DSH 数据）冲突，**不要加**。
- 既有 key：`chat_owner_order_v1`（synced companion）会新增 `harness:<id>` 值——规则本身不变，但 `test/core/database/business_key_registry_sync_test.dart` 的 pinning 测试如果需要枚举 owner 形态，记得覆盖。
- **不要**新增 synced/backupOnly 的 DSH key，除非架构契约修改。

### 1.6 唯一需要 codegen 的情形（明确「不要做」）

新增 Drift 表/列要 5 步（`lib/core/database/schema_migrations.dart:24-46` 原文）：
1. 改 `AppDatabase` DSL，**新列只能追加在表尾**（`ChatDatabaseRepository._validateRawSchema` 对列顺序精确校验）；
2. 升 `AppDatabase.currentSchemaVersion` 并把版本号加进 `publishedSchemaVersions`；
3. 依次跑并提交：`dart run build_runner build`、`drift_dev schema dump …`、`drift_dev schema generate …`、`drift_dev schema steps …`（已发布 `drift_schema_vN.json` 冻结，不能原地重 dump）；
4. 在 `AppDatabase.migration` 的 `stepByStep` 里加相邻版本回调（注意新索引不会自动建，要 `m.create(schema.idx…)`）；
5. 把新列名追加到 `ChatDatabaseRepository._validateRawSchema` 的对应列表。
CI **不跑** codegen（`.github/workflows/pr-check.yml` 无 build_runner/drift 步骤），生成物必须提交。→ 本特性**完全不需要**走这条。

---

## 2. 「助手与群聊」入口与新增弹窗

### 2.1 入口一览

| 入口 | 文件:行 | 现在的行为 | DSH 需要的行为 |
|---|---|---|---|
| 设置 › 助手与群聊 | `lib/features/settings/pages/settings_page.dart:198-206`（`SectionCard` + `_iosNavRow`，`Navigator.push(ChatOwnerSettingsPage())`） | 打开统一列表 | 列表里出现 DSH 助手行；行内点击进 DSH 设置页 |
| 桌面设置 › 助手 | `lib/desktop/setting/assistants_pane.dart`（`_DesktopAssistantsBody`，`+` 按钮 `_AddOwnerButton` `:298`，菜单项 `:326-342`，桌面命名弹窗 `_showAddAssistantDesktopDialog` `:353`） | 与移动端同源的两项菜单 | 菜单加第三项；列表行同样分流 |
| 侧栏助手列表行的「编辑」笔 | `lib/features/home/widgets/side_drawer.dart`（`_buildAssistantsList` `:4056`，`onEditTap: () => _openAssistantSettings(a.id)` 在 `:4128`） | 打开 `AssistantSettingsEditPage` | 按 kind 分流 |
| AppBar 头像长按 | `lib/features/home/pages/home_mobile_layout.dart:336`（`AssistantEntryActions.openAssistantSettings`） | 同上 | 同上 |
| 助手条目菜单（长按） | `lib/features/home/widgets/assistant_entry_actions.dart:48`（`showAssistantItemMenu`） | 复制/删除/编辑等 | DSH 助手隐藏无意义项（记忆/提示词等） |
| 会话迁移选择器 | `lib/features/assistant/widgets/assistant_select_sheet.dart:26` `showAssistantMoveSelector` | 列出所有助手 | DSH 助手应排除（不能把本地会话迁给远程助手） |

分流点建议收敛在 **`AssistantEntryActions.openAssistantSettings`**（`assistant_entry_actions.dart:31-46`）+ 桌面 `showAssistantDesktopDialog`：两处判断 `assistant.kind`，DSH → push `DshAssistantSettingsPage`（移动）或桌面 dialog。`_buildAssistantsList` 的 `onEditTap` 最终也走这里（确认当前实现是直接 push，建议改为调用 `AssistantEntryActions` 统一）。

### 2.2 「+」菜单与新建流程（现状）

`lib/features/assistant/pages/assistant_settings_page.dart`：
- 页面 root：`ChatOwnerSettingsPage`（`:35` 附近，1056 行）。安卓/iOS 与桌面共用（桌面设置 pane 是另一份实现）。
- 「+」按钮：`:120` 挂 `_createMenuAnchor`；`_showCreateMenu`（`:201-219`）用 `showAdaptiveActionMenu(anchorKey:…)` 弹两项：
  - `Lucide.UserPlus` + `l10n.chatOwnerCreateAssistant` → `_createAssistant`（`:221-235`）
  - `Lucide.Users` + `l10n.groupChatCreate` → `_createGroup`（`:237-241`）
- `_createAssistant` 流程：`_showAddAssistantSheet`（`:725`，`CustomBottomSheet` + `IosFormTextField`，返回名字）→ `AssistantProvider.addAssistant(name:)` → `Navigator.push(AssistantSettingsEditPage(id))`。
- 列表：统一 `ChatOwnersProvider` 顺序（`lib/core/providers/chat_owners_provider.dart`，持久 key `chat_owner_order_v1`，除 agent 顺序外还有 `separateChatOwners` 开关）；行卡片 `_AssistantCard`/群卡片；拖拽用 `SliverReorderableList`（`_OwnerSliver` `:251-285`），`_ownerDragProxy` 有缩放动画；`flutter_slidable` 提供滑出删除。
- 桌面 pane 的 `+` 菜单与命名弹窗是**第二份实现**（`assistants_pane.dart:326-342`、`:353`）。按仓库「同一决策一个 choke point」的规矩（AGENTS.md「Blast radius」），新增第三项时**两处都要改**。

### 2.3 DSH 助手的新建/连接流程（两步，按目标原文）

目标原文的交互是**两步**，不是一步表单：

1. `+` 菜单点「DeepSeek Harness」→ 弹出「连接到一个新的 DeepSeek Harness」，给出**连接方式选择**；第一阶段只提供「直接连接」一个选项（未来可加“扫码/局域网发现/公网中转”等，UI 预留）。
2. 点「直接连接」→ 进入连接表单（参考图 `image-01a1f4ab`），并显示一行小字：**“适用于与 DeepSeek Harness 处于同一局域网，或 DeepSeek Harness 暴露在公网上”**。
   - 字段 1：助手名称（默认 `DeepSeek Harness`，`IosFormTextField`；设置页可改）
   - 字段 2：**WebUI 访问链接**（一整串，含 `?token=`）——DSH 启动时打印 `dsh web: http://127.0.0.1:3080/?token=…`（`dsh-web-app/lib/index.js` 的 `announceReady`），用户整串粘贴；占位符照参考图给例 `例如 127.0.0.1:3080/?token=PEaxKDfNOHzbHp…`
   - 主按钮「确认」：解析 URL → 去掉 `token` 得 `baseUrl`/`authority` → 用 `GET /?token=…` 换 v1 浏览器 cookie（§8.2；**不用** `/connect` 的 v2）→ 调 `session.list`/`GET /api/...` 探活（空列表也算成功）→ 成功才创建 **`DshRemote` 连接记录 + `ChatOwner.harness(id)`**（`DshRemoteStore.add`），随后 **push DSH 助手设置页**（目标图 4 的“连接成功后”）。失败在按钮上方显示具体错误（DNS/拒绝连接/401/证书），**不要创建半成品记录**。实际入口文件：`lib/features/harness/pages/connect/dsh_connect_mode_sheet.dart`、`lib/features/harness/pages/assistant/dsh_assistant_settings_page.dart`、`lib/features/harness/state/dsh_connections_provider.dart`。
3. 创建成功后，助手与群聊列表行（`ChatOwnerKind.harness`）显示品牌头像/鲸鱼标、名称和副标题 **“远程连接的 DeepSeek Harness”**（参考图 `image-01a1f451`；目标说明该行小字是 AI 生成、可能有错乱，以这句话为准）。

- **桌面端**：两步都用 `Dialog`（禁止桌面 bottom sheet，见 AGENTS.md UI 指南）；连接表单可直接复用 `assistants_pane.dart:353` 的弹窗壳，方法选择用 `showAdaptiveActionMenu` 或小 dialog。
- 输入解析要求：接受 `http(s)://host:port/[?token=…]`、裸 `host:port/?token=…`（参考图就是裸的，需补 scheme）、末尾带 `/`；拒绝带 path 前缀的情况 `[待验证]`（DSH 支持 `--public-url` 反代前缀，先按「含 path 前缀则提示暂不支持」处理，或保留 path 作为 base URL）。token 只允许出现一次。
- 连接成功后写 `DshRemote`（`dsh_remotes_v1`）+ owner，并让 `ChatOwnerSettingsPage`/`SideDrawer` 即时刷新（`HarnessOwnerSource`/`DshConnectionsProvider` notify）；同时把连接实例注册进连接状态机（避免首次打开会话才连接）。


## 3. 首页 / 侧栏 / 抽屉 / 会话列表 / 工作区：远程模式改哪里

### 3.1 两套布局与断点

- 断点：`lib/shared/responsive/breakpoints.dart` — `AppBreakpoints.mobile=600 / tablet=900 / desktop=1200 / wide=1600`；`ScreenType` 由 `screenTypeForWidth` 产出（注意：宽度 < 900 归为 mobile，900–1199 tablet，1200+ desktop）。辅助判断用 `lib/shared/responsive/screen_type_helper.dart` 的 `ResponsiveHelper.isMobile/isTablet/isDesktop`。
- `HomePage`：`lib/features/home/pages/home_page.dart:107`（class），`build` `:989` → `_buildPage` `:1016`，在其中二选一：
  - `_buildMobileLayout` `:1078` → `HomeMobileScaffold`（`home_mobile_layout.dart:29`，`build` `:96`，内部 `InteractiveDrawer` + `SideDrawer`），body `_buildMobileBody` `:1156`；
  - `_buildTabletLayout` `:1212` → `HomeDesktopScaffold`（`home_desktop_layout.dart:38`，`build` `:134`，appBar `:143`/`:316`，actions `:567`）；**桌面与平板共用**这一个脚手架，窄桌面用 `compact` 标志压缩。
- 远程模式必须同时活在两套脚手架里（目标包含移动端右栏，见 §5.2），所以不要为远程新建一套 AppBar/抽屉；改这两个布局的入参与动作。

### 3.2 左侧抽屉 `SideDrawer`（5592 行，最大改造点）

结构（按 build 顺序）：`build` `:1763`；顶部搜索框 + 历史/关闭；助手/群列表；会话列表（置顶 + 日期分组）；底部用户/工具/设置。
- 构造参数：`side_drawer.dart:79` 起，含 `onSelectConversation`、`onNewConversation`、`onOpenOwner`、`globalSearchMode/query`、`loadingConversationIds`、`useDesktopTabs`、`desktopAssistantsOnly/TopicsOnly`、`embedded` 等（远程模式新增参数见下）。
- 当前数据源全部在 `build` 内 `context.watch/read`：`AssistantProvider`、`ChatService`、`GroupChatProvider`、`ChatOwnersProvider`、`TagProvider`、`SettingsProvider`。
- 会话行计算：`_sidebarRowsFor` `:1529`（自带 memo：revision/query/scope/assistantIds/groupIds 做 key）→ `_computeSidebarRows` `:1569`：单次遍历 `chatService.getAllConversations()`（`:1313`），用 `_ownerOf` 过滤 owner，按标题 query 过滤，转 `ChatItem(id,title,created:updatedAt,isPinned)`（`:1591`），再分 pinned/rest。
- 行模型：`_SidebarHeaderKind {pinned,date}` `:4786`，`sealed _SidebarRow` `:4788`，`_SidebarTileRow(chat, indexInSection, kind, dateBucket)` `:4807`。
- 助手列表：`_buildAssistantsList` `:4056`（`ChatOwnersProvider.inOwnerOrder` 统一顺序、标签分节、群聊、拖拽仅桌面、行内编辑笔 `onEditTap: () => _openAssistantSettings(a.id)` `:4128`）。
- 会话列表：`_buildConversationsList` `:4521`。
- 「工具」菜单：`_openToolsMenu` `:4302`，遍历 `AppTool.values`（`lib/shared/navigation/app_tools.dart:14`，`{translate, storage, markdownImage}`，`push(context)` `:31`）。
- 全局搜索结果也在抽屉内分支渲染（`globalSearchMode/query` 参数一路传下去）。

**远程改造（推荐）：注入“会话数据源”，而不是在 5.5k 行里到处 if。**

1. 新增可选参数：`SideDrawer({ …, SidebarSource? source, ValueChanged<String>? onSelectRemoteSession, VoidCallback? onNewRemoteSession, WidgetBuilder? remoteSessionListBuilder })`。
2. `_computeSidebarRows` 改为从 `source.conversations()` 取行；`_ownerOf` 在远程 owner 下恒等于当前 DSH owner。
3. 远程 owner 下，`_buildConversationsList` 直接返回 `remoteSessionListBuilder(context)`（一个新的 `DshSessionList`，自带工作区分节），**不改** `_SidebarRow` 的 pinned/date 模型，避免把工作区分节塞进 5.5k 行的既有枚举（风险最高、收益最低）。
4. **owner 行不是“假 Assistant”**：`ChatOwnerKind.harness` 经 `ChatOwnersProvider` 的第三数据源（`HarnessOwnerSource`）进入 `_buildAssistantsList`，行渲染复用 `_ownerCard` 视觉，铅笔 → DSH 助手设置页；连接状态点可用 `lib/features/harness/widgets/dsh_link_status_dot.dart`（或复用 `ToolPermissionDot` 视觉）。
5. 远程模式下隐藏/降级的能力：会话拖拽排序（DSH 有 `workspace.insertSessionBefore`，phase 2）、本地标签（tags 只属于本地助手）、全局搜索走本地索引（DSH 会话内容搜索可用 `session.search`，phase 2）。
6. **DSH 侧栏另有「插件」「自动化任务」等入口**（目标 6-②要求“像 DSH 一样显示”，能原生就原生）：这些不是会话，应作为 `DshSessionList` 上方的独立入口块（或底部导航），**不要**塞进 `_SidebarRow` 的 pinned/date 模型。两处的数据来源本版本已确认：
   - **插件**：`pluginInventory/list`（`dsh-host-plugin-inventory`，Remote-only 只读快照：entry id、module specifier、enablement、phase、`meta` 标题/描述；可选 `agentPresets` 组合信息）。原生列表完全可行；点某个插件的“设置/面板”才转 WebView（§8）。
   - **自动化任务**：`dsh-schedule` 的 `ScheduleService` 是 Remote（`remoteList/remoteCreate/remoteEdit/remoteHistory` 等；页面名 “Automation tasks”），原生列表/详情也可行。
   - 入口行 Flutter 原生（图标 + 名称 + 数量/状态），数据来自上述 Remote，禁止写死。内部完整页面优先原生 list，插件设置/面板再 WebView。
7. 加载态：`loadingConversationIds` 继续用（远程会话 id 用 `dsh:<sessionId>`，不会与本地 uuid 冲突）。

### 3.3 打开会话 / 新会话 / 切换 owner 的控制流

- 移动端点击会话：`HomeMobileScaffold.onSelectConversation` → `HomePageController.switchConversationAnimated`（`home_page_controller.dart:2105`）。
- 新会话：`createNewConversationAnimated`（`:2214`，另有 `:1128/:2049/:3815/:3945/:4019/:4114` 等调用点）。**注意**：这个函数被很多本地流程复用（临时会话、分支、计划任务等），远程分支不能靠改它实现；应在「更外层」分流（见下）。
- 打开 owner：`openOwner`（`:2023`）——解析「最近会话或新建」，是点侧栏助手行的入口；DSH owner 在这里应改为：`session.list` 取最近会话 → 有则打开远程会话，无则 `session.create`。
- 当前模型解析：`resolveChatModel`（`lib/features/home/utils/model_display_helper.dart:54`）与 `HomePageController.isReasoningModel/isToolModel`（`:4404/:4408`，真值来自 `GenerationController`）——**这些只对本地模型有意义**，远程模式必须绕开（DSH 的模型能力来自 catalog）。
- 远程分流建议：新增一个 `DshHomeController`（或 `DshSessionController`）+ 在 `HomePage` 顶层根据「当前 owner 是否 DSH」选择 body 与回调集合。具体地：
  - `HomePage.build` 内已有 `_controller.currentAssistant` 概念；DSH 判定用 `AssistantProvider.getById(currentAssistantId)?.kind`。
  - 若 DSH：`_buildMobileLayout/_buildTabletLayout` 传入的 `onSelectConversation/onNewConversation/onSend/...` 换成 DSH 实现（同一批参数，不同闭包），并把聊天区换成 `DshChatView`；AppBar 标题/模型副标题来自 DSH 选择。
  - 不把 DSH 分支写进 `HomePageController` 的 `switchConversationAnimated`/`sendMessage` 等 4500 行文件的核心函数（它们与 `ChatService`、草稿、队列、压缩强耦合，分支会把本地行为置于风险中）。

### 3.4 “工作区”在 Cuplivo 与 DSH 中不是同一件事

| | Cuplivo Workspace | DSH Workspace |
|---|---|---|
| 定义 | `lib/core/models/workspace.dart:5` `Workspace{id,name,kind(managed/linked),hostPath,defaultCwd,disabledTools,…}` | 主机上「注册过的目录」；`workspace.*` RPC 管理；Session `cwd`/`workspaceId` 归属 |
| 存储 | `extension_entity_rows` 的 `kind='workspace'`（`lib/core/database/extension_entity_store.dart:23`），`WorkspaceProvider`（`lib/core/providers/workspace_provider.dart:13`） | DSH 主机侧，不落 Cuplivo |
| 会话绑定 | 会话 `extras` 里的 `WorkspaceBinding`（`lib/core/models/workspace_binding.dart:5`，key `workspace.id/cwd/tools_used`）+ 助手 `defaultWorkspaceId` | Session 自己带 `cwd`；workspace 只是分组/排序 |
| 权限 | `ToolPermissionMode`（`lib/core/models/tool_permission_mode.dart:1`，`requestApproval/fullAccess`，写会话 extras） | `permission-presets`：Read Only / Workspace Write / Full access（+ Auto review 实验） |
| 界面 | 会话内 workspace sheet / 工具权限条 | 侧栏工作区分区、`/permission` 选择器、右侧栏 |

**不要**让 DSH 复用 `WorkspaceProvider`/`extension_entity_rows`（语义不同，会污染本地工作区列表和同步）。新增只读索引：`DshWorkspaceIndex` ← `workspace.follow` 的 baseline/frames + `session.list` 的 `cwd/workspaceId` 归属（`SessionSummary.cwd`；workspace 归属可用 `session.projections` 或 workspace feed 的纪律 [待验证字段]）。

### 3.5 远程模式的差异清单（逐项决定，别默认沿用）

| 能力 | 本地 | DSH 远程 | 实现位置 |
|---|---|---|---|
| 会话来源 | Drift `conversation_rows` | `session.list`（分页 cursor） | `DshSessionController` |
| 会话标题 | `conversation.title` 可改 | `title` projection；改名 `session.rename` | 同上 |
| 新建会话 | `createNewConversationAnimated` | `session.create`（可带 `workspaceId`/`cwd`） | `openOwner`/新会话按钮 |
| 置顶 | `conversation.isPinned` | `workspace.pinSession/unpinSession`（属于工作区，不是会话字段） | 行菜单 phase 2 |
| 删除 | 回收站（可恢复） | DSH 无删除会话 RPC（只有 archive）；本地删除按钮隐藏 | 菜单 |
| 搜索 | 本地全文 + 全局搜索页 | `session.search`（标题/内容片段，限 20 条） | phase 2 |
| 流式回答 | SSE + `StreamController` | WS `/api/remote.mux` 的 session follow/observe | §4.2 |
| 模型/推理 | `SettingsProvider` + `ReasoningRequest` | `modelCatalog` + `ModelSelection.reasoningEffort` | §4.4 |
| 临时会话 | 有（temporary chat） | DSH 无对应概念 | 隐藏按钮 |
| 分支/版本 | 本地多版本 | `session.fork` 存在，但聊天 UI 无“版本”概念 | 隐藏版本控件 |
| 多选/找/小地图 | 本地时间线 | 依赖本地 `ChatController`，无 | 隐藏（顺带满足 goal 的“去小地图”） |
| 附件/图片 | 本地附件管线 | `session.prompt` 支持 image/file part；上传走 receipt | phase 2 |
| 草稿 | 本地 `draftStore` | 无（会话在服务器）；保留输入框内存草稿 | 输入框 |
| 权限 | `ToolPermissionMode` | permission presets + `permissions` projection | §4.4 |

### 3.6 参考图（`docs/cuplivo-dsh/reference/`，未跟踪，勿提交）

- 侧栏布局：助手列表 + 会话列表 + 底部用户/工具/设置，DSH 助手带品牌头像和编辑笔 —— 与 `SideDrawer` 现有结构一致，改造点只是「会话行内容与分组」。
- 会话页：AppBar 左侧为抽屉按钮，标题两行（会话标题 + `模型 (供应商)`），右侧动作依次是 DSH 相关按钮 + 新会话/更多；输入框左侧是模型胶囊，中间是工具/加号，右侧发送/停止 —— 与 `HomeMobileScaffold` + `ChatInputBar` 的现有视觉一一对应。
- 聊天内容渲染：用户头像+时间、助手品牌字母头像+名字+时间、思考折叠卡（带耗时）、工具步骤时间线、Markdown 正文 —— 全部由 `ChatMessageWidget` 负责，远程只需喂数据。

---

## 4. 聊天渲染管线、输入区、模型/推理选择器、加号菜单、发送/忙碌、AppBar 动作

### 4.1 本地管线（先理解要复用什么、要绕开什么）

```
ChatService            lib/core/services/chat/chat_service.dart:108   Drift 持久化、会话/消息缓存
  ↓
ChatController         lib/features/home/controllers/chat_controller.dart:37  窗口化时间线（fetchConversationWindow/loadMoreBefore/After/updateMessage…）
  ↓
MessageBuilderService  渲染模型：分组/版本/翻译…（MessageRenderModel, lib/features/home/controllers/message_render_model.dart）
  ↓
MessageListView        lib/features/home/widgets/message_list_view.dart:100  （参数化：messages/renderModels/reasoning/reasoningSegments/toolParts/contentSplits/translations/回调…）
  ↓
ChatMessageWidget      lib/features/chat/widgets/chat_message_widget.dart:1271  （Markdown、思考时间线、工具卡、图片、操作条）
```

- 生成链路（本地）：`HomeViewModel`（`home_view_model.dart:126`，`sendMessage` `:963` 含“忙则排队”语义）→ `ChatActions/MessageGenerationService`（`prepareApiMessagesWithInjections`、`createUserMessage`、`createAssistantPlaceholder`…）→ `GenerationController`（流编排）→ `StreamController`（`stream_controller.dart:33`）。
- 流式数据结构（渲染端真正消费的）：`StreamController.reasoning/reasoningSegments/contentSplits/toolParts`；`ReasoningSegmentData` `stream_controller.dart:1743`（`text/startAt/finishedAt/expanded/toolStartIndex`）、`ContentSplitData` `:1754`（`offsets/reasoningCounts/toolCounts`）、`ToolUIPart`（`chat_message_widget.dart:4754`：`id/toolName/arguments/content/loading`）。节流推送由 `StreamingContentNotifier`（`lib/features/home/controllers/streaming_content_notifier.dart:57`，每消息一个 `ValueNotifier` + 工具高度事件）承担。
- Markdown 渲染：`lib/shared/markdown/markdown_with_code_highlight.dart:17` → `MarkstreamView`（vendored path 包 `dependencies/markstream`），主题/解析选项/扩展在 `mapMarkdownTheme`、`markdownParserOptions`、`markdownExtensionsFor`、`KelivoCodeHighlighter/KelivoMathRenderer/KelivoImageBuilder/KelivoLinkHandler`。**远程消息不需要新渲染器**。
- 渲染开关（`SettingsProvider`）：`enableUserMarkdown/enableAssistantMarkdown/enableReasoningMarkdown`、`assistantBubbleSplitParagraphs`、`chatFontScale`、代码块样式/`collapsedCodeLines`/`wrapCodeBlocks`、`showThinkingCards/showToolCards/showProducedFiles/showToolResultSummary/hideToolResultImages/showBrowserPageCards`、`showModelIcon/showUserAvatar/showTokenStats`。这些对远程消息同样生效（因为走同一个 widget）。

### 4.2 远程数据 → 渲染结构的映射

DSH 侧来源（真实 API）：

| 需要的数据 | DSH RPC |
|---|---|
| 会话列表（分页） | `session.list {cursor?}` → `SessionSummary{sessionId, updatedAt, running, blank, cwd, parentSessionId, projections{kind,asOfSeq,values}}` |
| 会话标题/权限/模型等投影 | `session.projections {sessionId}` → `SessionProjectionBaseline{values}`（`title`、`permissions`、`modelSelection`、`sessionListMetadata`…；`null` 表示无） |
| 历史事件页 | `session.events`/`session.page`（`SessionPage`，含 `cursor`）；记录类型 `SessionHistoryRecord = SessionEventEntry{type:'event', event: SessionWireEvent}` |
| 提交用户消息 | `session.prompt {requestId, sessionId, mode:'queue'|'steer', content:[{type:'text',text}|{type:'image',…}|{type:'file',receiptId}], clientTimeZone?}` |
| 取消 | `session.cancel {sessionId}` |
| 忙碌/队列 | `session.state {sessionId}` 或 `session.observeState`（`SessionState{cursor,active,running,queue,pendingInput}`） |
| 实时跟随 | `session.follow {sessionId}`（`SessionFollowFrame`，stream 模式）；投影流 `session.observeProjections`；状态流 `session.observeState`；主机事件流 `observeEvent` |
| 打开/读取会话 | `session.wait {sessionId,timeoutMs?,afterSeq?,maxMessages?}` → `{reason, state, output.records}`（适合“打开会话时一次性拿 recent N 条”） |
| 模型目录 | `session.modelCatalog` → `ModelCatalog{default, routableProviders, groups[{id,name,models[{id,name,reasoning{efforts,defaultEffort},badge}]}], failures}` |
| 切模型 | `session.selectModel {sessionId, provider, model, reasoningEffort?}` |
| 工作区 | `workspace.create/rename/delete/insertBefore/insertSessionBefore/archiveSession/pinSession/unpinSession/follow/initializeDefault` |
| 设置 | `settings.describe/update/replace/mutate`（namespace=插件条目 id，如 `llm-deepseek`；带 `expectedRevision` 防并发覆盖） |

映射到 Cuplivo 渲染（不需要改 `MessageListView`）：

| DSH 事件/字段 | Cuplivo 结构 |
|---|---|
| 用户消息（prompt 提交 + 历史 user 事件） | `ChatMessage(role:'user', parts:[TextPart(text), ImagePart…], timestamp, id:'dsh:…')` |
| 助手正文增量 | 同一个 `ChatMessage(role:'assistant', parts:[TextPart])`，流式中 `isStreaming:true`；或直接维护 `String` 交给 `ChatMessage`（scope 允许） |
| 思考增量 | `ReasoningSegmentData(text, startAt, finishedAt)` 列表 → `MessageListView.reasoningSegments` |
| 工具步骤 | `ToolUIPart(id, toolName, arguments, content, loading)` → `MessageListView.toolParts`（`Map<String,List<ToolUIPart>>`，key 为消息 id） |
| 交错切分 | 若 DSH 事件带“段落/思考/工具”顺序，需要 `ContentSplitData(offsets, reasoningCounts, toolCounts)`；否则正文/思考/工具按出现顺序即可，`contentSplits` 传 null |
| 用量 | `ChatMessage.totalTokens/promptTokens/completionTokens`（若 DSH 事件提供） |
| 模型标识 | `ChatMessage.modelId/providerId`；`CurrentModelIcon`（`lib/features/home/widgets/model_icon.dart:12`）用 `BrandAssets` 按名字兜底，无 provider config 时会退到模型首字母，不会崩 |
| 消息操作 | `ChatMessageWidget` 的回调大多可空：远程 phase 1 传 null 隐藏“重新生成/编辑/版本/翻译”；保留复制、朗读（本地 TTS 仍可用） |

**实现第一步建议是一个 spike**：在本机用 `curl` + 一段 Dart/Node 小脚本打通登录、`session.list`、`session.wait`、`session.prompt`、`session.follow`，把真实 `SessionWireEvent`/`SessionFollowFrame`/assistant stream 帧 dump 成 JSON 样本放进测试 fixture。事件 schema 广、且各插件会扩展（`SessionWireEvent` 是 merge-extensible 的），**不要凭本文猜测字段**；本文只保证“渲染层需要哪些结构”这一侧确定。`[待验证]`

#### 4.2.1 `MessageListView` 的复用清单（已核对构造参数）

`MessageListView` 的必填参数全部可以手工构造（它不读 Provider，只读传入的 map/控制器）。DSH 侧的最小装配：

| 参数 | 类型 | DSH 侧取值 |
|---|---|---|
| `scrollController` | `ScrollController` | `ChatScrollController()`（`lib/features/home/controllers/scroll_controller.dart:232`，构造后取其 `scrollController`/`messageListController`），或裸 `ScrollController()` + `ListController()` |
| `listController` | `ListController`（`super_sliver_list` 包，**不是仓库类**） | `ListController()` |
| `messages` | `List<ChatMessage>` | DSH 回合展开后的消息列表（按 seq 排序，至少包含正在流式的那条） |
| `byGroup` | `Map<String, List<ChatMessage>>` | 由 `groupId ?? id` 分组；DSH 每条消息给唯一 `groupId`（或用默认自指）→ `{for (m in messages) (m.groupId ?? m.id): [m…]}` |
| `versionSelections` | `Map<String,int>` | `{}`（DSH 无版本概念；渲染不会显示版本切换） |
| `reasoning` | `Map<String, stream_ctrl.ReasoningData>` | 单段思考：`{msgId: ReasoningData()..text=…; ..startAt; ..finishedAt}`；也可改用 `ChatMessage.reasoningText/reasoningStartAt/reasoningFinishedAt` |
| `reasoningSegments` | `Map<String, List<stream_ctrl.ReasoningSegmentData>>` | 多段思考/工具交错时填；否则 `{}` |
| `contentSplits` | `Map<String, stream_ctrl.ContentSplitData>` | 交错切分；否则 `{}`（正文/思考/工具按 parts 顺序渲染） |
| `toolParts` | `Map<String, List<ToolUIPart>>` | DSH 工具步骤（`ToolUIPart` 在 `chat_message_widget.dart:4754`） |
| `translations` | `Map<String, TranslationUiState>` | `{}` |
| `selecting` / `selectedItems` | `bool` / `Set<String>` | `false` / `{}` |
| `dividerPadding` | `EdgeInsetsGeometry` | 与本地聊天页一致（从 `SettingsProvider`/布局取） |
| `processingFilesMessageId` | `ValueNotifier<String?>` | `ValueNotifier<String?>(null)` |

可选但强烈建议：
- `renderModels` 不传时，`MessageListView` 自己调 `MessageRenderModelProjector.project(...)`（`message_list_view.dart:442-451`）；DSH 首版不传即可。
- `streamingContentNotifier: StreamingContentNotifier()`（`lib/features/home/controllers/streaming_content_notifier.dart:57`，无参构造）：流式期间用 `updateContent(messageId, …)` 按消息粒度通知，**避免每帧 setState 重建长列表**；这是本地已有做法，DSH 直接照用。
- `assistant: Assistant` / `assistants: AssistantProvider`：影响复制/编辑/记忆等回调，远程可传当前 DSH `Assistant` 以便头像/名字/主题正确（`showModelIcon/showUserAvatar` 等开关仍生效）。
- 消息操作回调全部可空（`onRegenerateMessage` 等），DSH phase 1 传 null 即隐藏；`onSpeakMessage` 可保留本地 TTS。

`ChatMessage` 构造要点（`lib/core/models/chat_message.dart:171`）：必填 `role` 与 `conversationId`（DSH 用 `'dsh:<sessionId>'`）；`groupId` 缺省 = `id`，`version` 缺省 0；`parts` 传 `TextPart`/`ReasoningPart`/`ToolCallPart`/`ImagePart` 等；流式中 `isStreaming: true` 且 `id` 与 notifier 的 messageId 一致。


### 4.3 输入区（`ChatInputBar` 直接复用，`ChatInputSection` 不要用）

- `ChatInputSection`（`lib/features/home/widgets/chat_input_section.dart:51`）会解析本地 provider/workspace/skills/MCP/ASR 等上下文——远程模式**绕过它**，直接组装 `ChatInputBar`（`chat_input_bar.dart:714`）。
- 可用插槽/开关（`:721-…` 参数区）：
  - `leading` + `onTapLeading` + `leadingExtent/leadingTooltip`：**替换“模型选择”位置**（远程放 DSH 模型胶囊，点击开 DSH 模型选择器）。
  - `modelIcon`/`chatModelProviderKey/chatModelId`：若要显示 `CurrentModelIcon`；远程可传 DSH 的 provider/model id。
  - `onSelectModel`/`onLongPressSelectModel`：无 `leading` 时使用；与 `leading` 二选一。
  - `onMore`：加号菜单回调（`_buildResponsiveLeftActions` 里 `showToolsButton`/`onMore` 控制，`:3605` 一带）。
  - `supportsReasoning` + `reasoning`（`ReasoningRequest`）+ `reasoningActive`/`reasoningCustomBudget`/`onConfigureReasoning`：推理按钮（`:3528` 一带）。**DSH 的推理强度不是 `ReasoningRequest`**，见 §4.4——可传一个映射后的展示值，`onConfigureReasoning` 打开 DSH 推理选择器。
  - `loading`/`onStop`：发送中/停止；`hasQueuedInput/queued…`：排队展示。
  - `onSend` 返回 `Future<ChatInputSubmissionResult>`（`lib/core/models/chat_input_data.dart:46`：`sent/queued/rejected`）。`_handleSend`（`:2260` 起）在发送前清空输入框并缓存草稿，`rejected` 时**恢复**草稿并重开——远程实现利用这一点：只在 DSH `session.prompt` 成功受理后才返回 `sent`；网络错误返回 `rejected`（用户内容不丢）。
  - `showToolsButton`/`onOpenTools`/`onLongPressTools`、`showWorkspaceButton`/`onOpenWorkspace`、`onOpenSkills`、`onOpenSearch`、`showQuickPhraseButton`：按远程能力置 false/null（目标里这些“Cuplivo 原生组件要隐藏”）。
  - `mediaController`、`onOpenCamera/onPickImage` 等附件入口：phase 1 传 null（输入框不显示附件）；phase 2 接 `session.prompt` 的 image/file part + 上传 receipt。
  - ASR/语音：远程可保留本地 ASR（转成文字再当 prompt），非必须。
- 忙碌发送语义：DSH `session.prompt` 有 `mode:'queue'|'steer'`。建议 phase 1 一律 `queue`（与 Cuplivo “忙时排队”一致），phase 2 用“按住发送/长按”或设置项暴露 `steer`（打断当前回合）。
- 输入框高度/键盘/桌面快捷键等现有逻辑全部复用，不必重写（`chat_input_bar.dart` 内部已处理）。

### 4.4 模型选择器与推理/权限选择器

**本地现状**
- `showModelSelector`（`lib/features/model/widgets/model_select_sheet.dart:188`）→ 移动端 `_ModelSelectSheet`（`:340`），桌面端 `_showDesktopModelSelector`（`:1740`）→ `_DesktopModelSelectDialogBody`（`:1773`）。数据源硬编码 `SettingsProvider`（`_providerConfigsForPicker` `:398`/`:1825`），内部有 provider tab、搜索、收藏、pin（`togglePinModel`）、处理中状态等，共 2514 行。
- 调用点：`home_page.dart:1121/1273/1704`（模型胶囊）、`assistant_settings_edit_page.dart`（助手默认模型）、各处 provider 配置页。
- 推理：`showReasoningLevelSheet`（`lib/features/chat/widgets/reasoning_level_sheet.dart:27`）+ `ReasoningLevelPicker`；结果是 `ReasoningRequest(level)`；`EffortSlider`（`lib/shared/widgets/effort_slider.dart`）用于自定义 budget。

**DSH 侧**
- 模型目录 `session.modelCatalog`：`groups[].models[]` 自带 `reasoning.efforts[{id,name,description}]`、`defaultEffort`、`badge`。
- 选择：`session.selectModel {sessionId, provider, model, reasoningEffort}` —— 模型与推理强度是**一次选择**；当前值来自 `modelSelection` projection（`{provider, model, reasoningEffort?}`）。
- 权限：presets（`dsh-client-ui-permission-presets` 的 README 明确）Read Only / Workspace Write / Full access（实验 Auto review 带 EXP 徽标）；当前值来自 `permissions` projection `{currentValue}`；默认值改 `settings`；当前会话切换通过 `/permission <preset>` 命令。`[待验证]` 原生客户端如何提交命令：大概率是发送一条 prompt 文本，由 Host 的命令壳消费（不上屏为用户消息）——必须在 spike 里验证；若不可行，则只暴露“默认权限”设置，当前会话权限只读展示。

**复用策略（按成本从低到高）**
1. **抽出可复用视觉部件**：把 `model_select_sheet.dart` 里与数据源无关的私有件提为公开（建议新文件 `lib/features/model/widgets/model_picker_parts.dart`）：结果类型 `ModelSelection`、provider tab 胶囊、搜索框、模型行（图标/名称/描述/勾选/推理徽标）、分组头。然后写 `lib/features/dsh/widgets/dsh_model_sheet.dart`（移动 bottom sheet）与 `dsh_model_dialog.dart`（桌面 dialog），数据源 = `DshModelCatalog`。**不要**把 `SettingsProvider` 抽象成接口再塞 DSH（会把 2514 行的本地逻辑和 pin/收藏/处理中等状态一起拖进来）。
2. 图标：`CurrentModelIcon` 已能容忍无 `ProviderConfig`（`model_icon.dart:12`；`cfg == null` 时直接 `BrandAssets.assetForName(modelId)` 兜底），DSH 的 provider/model 名多为 `deepseek` 系列，能命中品牌资源；命中不了退首字母。**注意它要求 `providerKey != null && modelId != null`，否则返回 `SizedBox.shrink()`**——DSH 传 `providerKey = DSH provider id`、`modelId = catalog model id`（即使该 id 不在 `SettingsProvider.providerConfigs` 里也没关系）。
3. 权限选择器 UI：参考 `lib/features/chat/widgets/tool_permission_widgets.dart`（`ToolPermissionRow :129`、`SwitchToFullAccess :207`、`ToolPermissionDot :238`、`ToolPermissionBadge :286`）的视觉语言，新写 `DshPermissionRow`（三档 + 说明 + 风险确认），不要改本地权限模型。

### 4.5 加号菜单（+）

- 本地：`showChatToolsSheet`（`lib/features/chat/widgets/chat_tools_sheet.dart:42`，`ChatToolsSheet :78`，参数 `assistantId/conversationId/members/modelSupportsTools`）内部管理本地工具/MCP/工作区；桌面另有 popover（`showDesktopToolsPopover`，`lib/desktop/tools_popover.dart`）；行视觉在 `lib/features/chat/widgets/tools_sheet_row.dart`。是否显示受 `showToolsButton`/`onOpenTools` 控制。
- 远程：新写 `showDshPlusSheet`（移动 bottom sheet / 桌面 `showAdaptiveActionMenu` 或 dialog）。**条目必须与 DSH 的加号菜单一致**（目标：“点击后弹出的内容与 DeepSeek Harness 中一致”），建议顺序：
  - **指令（斜杠命令）**：DSH 的命令列表来自 Host 的命令注册表（`@deepseek-ai/dsh-commands` 的 `CommandRuntime`，desktop 客户端还有 `dsh-client-ui-commands` 的 SPA 投影）。首版可先不列（命令在输入框里手打 `/` 也能用），但**不要**把 Cuplivo 的本地快捷短语/工具塞进来。`[待验证]` 命令描述符的 Remote 读取路径（`CommandRuntime.list(agent)` 的参数是 Host 对象，可能需要经过 `session` 的投影或另一个门面）。
  - **技能**：DSH 侧技能目录有明确 Remote（`dsh-api-session-controller` 的 `SessionSkillCatalog`，命名空间 `skills`，session 地址化、可冷读）。列表/启用走该 Remote，**不要**用 Cuplivo 的 `skillIds`/本地技能。
  - **工作区**：当前会话的 workspace/cwd、切换/查看。
  - **权限**：当前 preset（§4.4）。
  - **模型详情**：provider 徽标 + 当前 `modelSelection`。
  - **插件面板 / 右栏**：打开 §5 的右栏。
  - **DSH 设置**：跳 DSH 助手设置页（§7）。
  - 行视觉复用 `tools_sheet_row.dart`；desktop 使用 `showAdaptiveActionMenu(anchorKey: …)`（`lib/shared/widgets/action_sheet.dart`）。
- 入口绑定：`ChatInputBar.onMore` / `showToolsButton + onOpenTools`。目标里的“原生输出框组件隐藏 + 加号菜单自绘”正是这一层。

### 4.6 AppBar 动作

**移动端**（`home_mobile_layout.dart:278-314`）：
```
actions: [
  IosIconButton(Lucide.Map)            // :279-285 小地图 → 删除（goal 明确去掉）
  IosIconButton(Lucide.MessageCirclePlus / 临时会话)  // :286-311 新会话 → 保留
  SizedBox(width:4)                     // :313
]
```
DSH 模式：删小地图；在“新会话”**右侧**加右栏按钮（`Lucide.panelRight`，开 §5 的右面板）；“更多/设置”入口保持在抽屉底部，不动。切页时 `appBarOverride` 逻辑（find 头、多选头 `ChatSelectionAppBar`）在远程模式下不适用，直接禁用多选/find。

**桌面端**（`home_desktop_layout.dart:567` 起 `_buildActions`）：
- 第一项：右栏切换（`DesktopSidePanelController.instance`：`isOpen`/`toggle`，图标 `Lucide.panelRight` `:588-593`）。远程模式复用同一个 controller 不现实（见 §5），改为 `DshPanelController` 的同视觉按钮。
- 第二项：新会话（`Lucide.MessageCirclePlus` / 临时会话切换 `:599-624`）。
- 标题区（`:316 _buildAppBar`）左侧抽屉/侧栏收起按钮、中间标题+模型胶囊 —— 远程模式把胶囊内容换成 DSH `modelSelection`，点击开 DSH 模型选择器。

### 4.7 发送 / 忙碌 / 停止 / 错误

- 发送：`ChatInputBar.onSend` → `DshChatController.send(text)` → `session.prompt(mode:'queue')`。成功受理（`{accepted:true}`）即返回 `sent`；本会话 `running` 时排队展示（`queuedInput` 语义可复用）。用户消息上屏时机：可用乐观上屏（本地 `ChatMessage` 立即插入，等 `session.follow` 的 user 事件到达后做 id 对齐/去重），或等事件到达（慢但简单）。**必须防重**：用 `requestId`（客户端 uuid）与事件里的关联 id 对齐。`[待验证]` 事件里是否回传 requestId。
- 忙碌指示：`loading = state.running || state.active`；输入框 `onStop` → `session.cancel`；取消成功返回 `cancel` 立即更新。
- 队列：`SessionState.queue`（`SessionQueuedItem{id, placement, content}`）→ 在输入框上方显示 “N 条待发送”；`session.updateQueue` 支持 edit/remove/steer（phase 2）。
- 错误：DSH 失败 envelope `{ok:false, error:{code, message, details}}`（`RemoteResult`/`RemoteFailure`）→ `showAppSnackBar`（`lib/shared/widgets/snackbar.dart`）+ 可重试；网络断开时保留输入、把连接状态打到助手行/顶部（参考 `sync` 的状态点做法）。认证失效（401）→ 引导重新粘贴 URL（`DshConnectionError.auth`）。

---

## 5. 右侧面板

### 5.1 现状（桌面已有，移动端没有）

- 控制器：`lib/features/side_panel/desktop_side_panel_controller.dart:15` `enum SidePanelPresentation { hidden, docked, overlay, expanded }`；单例 `:25`；尺寸常量 `defaultWidth=520`（`:26`）、`minWidth=360`（`:27`）、`dockThreshold=849`（`:28`）；偏好前缀 `desktop_side_panel_`（`:29`，键 `open_v1`/`width_v1`/`last_kind_v1`/`tabs_v1` 等）。
- 呈现决策：`presentationFor(availableWidth)` `:195`（展开 → expanded；宽度 ≥ 849 → docked；否则 overlay）；`maxWidthFor` `:203`（`min(900, availableWidth-489)`）；`widthFor` `:206`。
- 面板：`lib/features/side_panel/widgets/desktop_side_panel.dart:34`，`build` `:516`：docked 时 `Positioned(left:0,right:width)` 让聊天区变窄（“挤压”），overlay 时 `ModalBarrier` 遮罩 + 右侧滑入，expanded 时全宽；含拖拽调宽（`SidebarResizeHandle`）、add 菜单、tab bar、多 tab。
- 标签模型：`lib/features/side_panel/models/side_panel_tab.dart:4` `enum SidePanelTabKind { topics, files, web, preview }`；`PinnedTab`（topics/files，常驻不可关）、`WebTab(browserTabId, browser)`（浏览器 tab 的投影，`evicted` 表示引擎已回收）、`PreviewTab(path, source)`。
- 内容来源：`_body(width)` 内按 active kind 显示 `SidePanelBrowser`（`side_panel_browser.dart:8`，内部 `BrowserPage(embedded:true)`）或 `SidePanelFilePreview`；topics 复用会话列表/topics 组件。
- 入口：桌面 body 在 `home_desktop_layout.dart:176` 包裹聊天；按钮在 `_buildActions`（`:567`）第一项。另有 `BrowserPanelController`（`lib/features/browser/browser_panel_controller.dart`）把“打开浏览器”映射到 web tab。
- **移动端完全没有右侧面板**；目标要求移动端也有右栏按钮 → 需要新建。

### 5.2 目标与方案（目标原文：**把聊天推到屏幕外，不堆叠**）

目标原文对右栏的要求很明确：
- 展开后 **“将 Cuplivo 对话框推到屏幕外（不堆叠）”** —— 即面板占据主要宽度、聊天被推到一旁；**不是** overlay 叠加。
- 面板风格本地化（用 Cuplivo 主题/组件），渲染方式与左栏插件入口一致（原生入口 + 插件内面板 WebView）。
- 参考图 `image-01a1f490`：右栏顶部是「开始」（Start）页：面板切换/全屏图标、工作区文件（Ctrl+P）、新建终端（Ctrl+`）、浏览器（Ctrl+T）、更多工具四张入口卡；聊天被推到左侧屏幕外。

方案（推荐）：
1. **几何与呈现逻辑抽公共件**：把 `SidePanelPresentation`、`presentationFor/maxWidthFor/widthFor`、dock 阈值/宽度常量与 prefs 前缀提取为 `lib/features/side_panel/widgets/side_panel_geometry.dart`（纯函数 + 常量），`DesktopSidePanelController` 改为调用它；新 `DshPanelController` 也调用它。这样“一个决策一处实现”（AGENTS.md 要求），且可单测几何。
2. **桌面（宽屏）**：新 `DshSidePanelHost`（`lib/features/dsh/widgets/dsh_side_panel_host.dart`）**不**复用 `DesktopSidePanel` 的 tab 系统（它绑死 BrowserService/文件预览/本地会话 id）。容器外观：面板打开时聊天区被挤压（`Positioned(left:0,right:width)`，与现有 docked 一致）；点“展开/全屏” → 面板占满可用宽度、聊天彻底移出屏幕（对应目标“推到屏幕外”）；**不要**做半透明遮罩式 overlay（目标明确不堆叠）。
3. **移动端**：同一份 `InteractiveDrawer` 正好是“推入式”：其注释写明 *“The main content; it will translate horizontally with the drawer progress”*，即 child 随抽屉进度整体位移（不是叠加）；默认 `drawerWidth = min(360, 屏宽*0.86)`，DSH 右栏传接近满宽（如 `屏宽*0.94`）即可实现“聊天推到屏幕外”。`side: DrawerSide.right` 目前仓库无人使用（`grep DrawerSide.right` 为空），是新增用法但组件已支持；`maxScrimOpacity`/`barrierDismissible` 按目标调低或关闭（不遮挡内容）。与左抽屉互斥：同一时刻只开一个（控制器层判断）。
4. **面板内容（首版 = “开始”页，对照 `image-01a1f490`）**：
   - **工作区文件**：原生。数据来源 `dsh-api-workspace-files` / `workspace` 相关 Remote（`[待验证]` 具体方法）。
   - **新建终端**：DSH 的终端面板是 SPA 里的 web 终端；原生实现需要 `terminal` Remote（`dsh-api-terminal-controller`）+ 一个终端渲染组件（xterm 等价物）。首版可以只做“入口 → WebView/浏览器打开 DSH Web UI 的终端页”，或**先不显示该卡**（避免“遥控器有按钮、电视没功能”的反向问题）。
   - **浏览器**：可直接打开 Cuplivo 内置浏览器（`BrowserService`/`BrowserPage`），不需要 WebView 内嵌 DSH。
   - **更多工具**：DSH 的工具/插件入口列表；原生能列的列，其余走 WebView。
   - **插件面板**：DSH 的右侧栏贡献是 SPA 内的 React 插槽（`@deepseek-ai/dsh-client-ui-slots`），不是独立 URL。因此 WebView 只能加载**整个 Web UI**（`http(s)://host:port/?token=…`），无法只渲染某一块。两个可行落地：
     a. 面板里用 WebView 打开 DSH Web UI 顶部（用户自己在 WebView 内点到右栏）；体验差但“能看到插件”。
     b. 面板里列出插件/入口，点击后在 Cuplivo 内置浏览器（`SidePanelBrowser`/`BrowserPage`）打开完整 DSH Web UI；原生侧只做“已知面板”（开始/工作区文件/终端输出等）。
   - 结论：**首版做原生“开始”页 + 插件入口（打开 WebView/浏览器）；真正的“嵌入单个插件面板”需要 DSH 侧提供独立路由**（当前无，`[待验证]` 未来版本）。这一点必须在实现前与产品确认，避免做出“WebView 里塞整个 SPA”的劣质体验。
5. **右栏头部**：标题「开始」（本地化）+ 面板列表/全屏按钮（参考图右上两个图标）；全屏按钮切换“推挤 ↔ 全屏推入”两种呈现（复用几何 helper 的 docked/expanded 概念）。

### 5.3 与主题/输入框的边界

- 面板打开时聊天/输入框的处理随呈现方式：**docked（宽屏）下聊天被挤压但仍可用**；**全屏推入（含移动端）下聊天被完全推到屏幕外**——此时右栏是唯一可交互区域，关闭后恢复。不要用“半透明遮罩 + 点击外部关闭”的 overlay（目标明确不堆叠）。
- 面板内部是独立滚动区（列表/WebView 各自滚动），手势不与聊天列表争抢；移动端右栏从右边缘右滑打开、左滑/返回关闭（`InteractiveDrawer` 已处理手势），打开期间禁止左抽屉同时展开。
- 键盘弹起时移动端右抽屉应关闭（与左抽屉一致的行为）；桌面 docked 面板不受影响。
- 主题：面板背景 `context.appColors.surfaceCard`/`background`，圆角与阴影沿用侧栏/面板现有 token；不要用纯白/纯黑硬编码。

---

## 6. 供应商 / 模型管理的复用与隔离

### 6.1 Cuplivo 现状（本地 provider 体系）

- 配置模型：`ProviderConfig`（`lib/core/providers/settings_provider.dart:6824`）——`id/enabled/name/apiKey/oauth/baseUrl/providerType/models[]/disabledModels/modelOverrides/requestBudget/customHeaders/customBody/proxy/avatar/multiKey/balance/claudePromptCaching`。
- 存储：`provider_rows`（`BusinessEntityKind.provider`，`business_data.dart:10`；`idColumn='provider_key'`）+ 顺序键 `providers_order_v1`（`settings_provider.dart:84` 注释）。
- 读取：`providersOrder` `:508`、`providerConfigs` `:616`、`getProviderConfig` `:623`。
- 界面：`ProvidersPage`（`lib/features/provider/pages/providers_page.dart:32`，添加 `_handleAddProvider :89`，行/分组/搜索在 `:1236` 一带）；添加弹窗 `showAddProviderSheet`（`lib/features/provider/widgets/add_provider_sheet.dart:22`，内置 `_SegTabBar`）；详情 `ProviderDetailPage`（`lib/features/provider/pages/provider_detail_page.dart:52`，`_save :1920`，模型选择 `_showModelPicker :3051`，模型卡片 `_ModelCard :3708`）；模型目录面板 `lib/features/provider/widgets/model_catalog_panel.dart`。
- 解析：`ModelSpec`（`lib/core/models/model_spec.dart`）与 `ModelSpecResolver` 把 provider+model 解析成能力/上下文/价格等；聊天的 `resolveChatModel`（`model_display_helper.dart:54`）决定实际调用哪个 provider/model。
- 推理：`ReasoningRequest`（`lib/core/models/reasoning_request.dart`）是 Cuplivo 自己的“推理强度”模型。

### 6.2 DSH 现状（模型目录与选择）

- 目录：`session.modelCatalog` → `ModelCatalog{default: ModelSelection, routableProviders, groups: ModelProviderGroup[]（id/name/models）, failures}`；`ModelCatalogModel{id,name,description?,reasoning?:{efforts,defaultEffort},badge?}`。
- 当前选择：`modelSelection` projection（`{provider, model, reasoningEffort?}`）；改：`session.selectModel`。
- 供应商配置：DSH 的 provider 是**插件条目**（如 `llm-deepseek`），配置走 `settings.describe/update/replace/mutate`（`SettingsNamespaceView{ns, schema, value, user, revision, secrets, applies:'live', autoGenerate}`）。schema 是 schemastery 的 JSON 信封，可用 `new Schema(json)` 重建——**理论上可以通用表单驱动**，但这是一大块工作。
- 权限：见 §4.4。

### 6.3 隔离原则（硬约束）

1. **DSH 模型/供应商绝不进入 `SettingsProvider.providerConfigs` 或 `provider_rows`**：否则它们会出现在本地聊天的模型选择器里、随备份/LAN 同步、并可被本地请求使用——这正是目标里“模型仅在 DSH 内部可用”的反面。
2. **不复用 `ProviderConfig` 作为 DSH provider 的存储类型**（字段语义不同：DSH 的 provider 配置是插件 schema）。可以在 UI 层复用布局/表单组件，但数据用 `DshProviderView{ns, title, enabled, configured, revision, schema, value}`。
3. DSH 选择状态只在内存/会话投影里；**不落盘**（`architecture.md` 不变量 1：不缓存 DSH 的模型选择/会话/设置）。连接记录里的 `lastConnectedAt/lastError` 是唯一例外。
4. 本地模型选择器（`showModelSelector`/`showModelSelectSheet`）不改行为；远程用独立 sheet（§4.4）。

### 6.4 DSH 设置页「模型」tab 的设计细节

完整、可执行的方案见 **§6.6**（那里把 `llm`/`settings`/`credentials` 三组 Remote 与页面结构对齐了）。这里只补三条与目标原文对应的设计要点：

- **「显示的模型是 DSH 已添加的模型」**：provider 行来自 `llm.listConfigurableProviders()`（目录）∪ `llm.listProviders()`（已注册路由）；模型列表来自该 provider 的 settings profile（`settings.describe(ns)` 的 `value`/`user`）或 `session.modelCatalog()`。不要用 Cuplivo 的 `ProviderConfig`/`ModelSpec`。
- **「界面按 Cuplivo 本来就有的提供商界面做」**：`ProvidersPage` 的分组搜索、provider 行、详情页的模型卡片（id/name/上下文/最大输出/输入类型）全部照抄视觉；**首次配置 provider 时模型目录隐藏**（只显示凭据/连接卡片），保存成功后再展开。
- **「自定义提供商每个模型可选择思考强度」**：自定义路由走 `llm-pi-ai` 的 profile；其模型行额外有 `reasoningEfforts`（level → 供应商 API value），UI 用 chip/多选（可用 `SegmentedTabs` 或自定义行），保存进同一个 settings profile。

实现顺序与工作量见 §12.2 的 **P6**（P1–P5 不依赖它；P6 是独立大块，不要提前塞进 P1）。

### 6.5 具体复用清单

| 要复用的东西 | 位置 | 复用方式 |
|---|---|---|
| provider 行视觉（图标/名称/启用徽标/箭头） | `providers_page.dart` 的 `_ProviderRow`（:1236 起） | 抽 `lib/features/provider/widgets/provider_row_view.dart` 或照抄结构到 `dsh_provider_row.dart` |
| 添加 provider 的分段选择器 | `add_provider_sheet.dart:22` 的 `_SegTabBar` | 已在 `SegmentedTabs` 共享件里（`lib/shared/widgets/segmented_tabs.dart`），直接用 |
| 表单字段 | `lib/shared/widgets/ios_form_text_field.dart`（`IosFormTextField`）、`ios_settings_rows.dart`（`IosNavRow/IosSwitchRow/IosSectionHeader/IosSectionFooter`）、`SectionCard` | 直接使用 |
| 模型行/搜索/分组 | `model_select_sheet.dart` 内部件、`provider_detail_page.dart:_ModelCard`（:3708） | 抽公共件（§4.4），DSH 模型 tab 与聊天选择器共用 |
| 密钥/秘密字段 | `IosFormTextField(obscureText:true)` + “已配置”占位（DSH `secrets` 只返回 `configured` 状态） | 手写 |
| 危险操作确认 | `showAdaptiveActionMenu`/`CustomBottomSheet`/桌面 dialog | 直接使用 |



### 6.6 「模型」设置页完整方案（对齐目标⑨③与参考图 `image-01a1f4c4` / `image-01a1f4c7`）

目标要求「模型」页完整复刻 Cuplivo 的“提供商”管理界面，但数据全部来自 DSH。DSH 侧提供三组 Remote，正好对应 Cuplivo 的三层：

| DSH Remote | 方法 | 作用 |
|---|---|---|
| `llm`（`LlmRuntime extends TypertRemoteService`） | `listProviders()`、`listConfigurableProviders()`、`discoverModels(settingsNs, request)` | 已注册路由 / 可配置 provider 目录（含 `provider, displayName, settingsNs, settingsPath, declared, defaultBaseURL, baseURLEnv, nativeAuth{env,oauth}, error`）/ 端点探测模型列表 |
| `settings` | `describe()`、`update/replace/mutate(ns, …, expectedRevision)` | 每个 provider 的配置（`llm-deepseek`、`llm-pi-ai` … 的 `SettingsNamespaceView{schema,value,user,revision,secrets}`） |
| `credentials` | `describe(refs[])`、`set(ref, value)`、`unset(ref)` | API key 只写不读：`describe` 只返回是否已配置等信息 |

**页面结构（与 Cuplivo `ProvidersPage` 对齐）**
1. 顶部搜索框 + `+`（复用 `_ProviderRow` 视觉；参考图 `image-01a1f4bc`）。
2. 行 = provider：品牌图标（`BrandAssets`/首字母）、名称、右侧启用状态（绿点/「启用」徽标）、`>`。数据 = `listConfigurableProviders()`（目录）+ `listProviders()`（live）合并；未配置的目录项也显示（进入即“首次配置”卡片态）。
3. 点击 `+` → 参考图 `image-01a1f4c4` 的**字母分组 provider 目录**：数据来自 `listConfigurableProviders()` 中尚未配置/可激活的项；最上方加「自定义提供商」（对应 DSH 的“自定义模型 API”模式）。
4. Provider 详情（参考图 `image-01a1f4c7`）：
   - **API 密钥**：`IosFormTextField(obscureText:true)`，占位「留空使用已保存凭据」；状态点由 `credentials.describe([ref])` 决定；写入 `credentials.set(ref, value)`（DSH 侧按 `<ROUTE>_API_KEY` 派生引用，Cuplivo 不猜引用名，`describe`/`llm` 目录会给出环境变量提示 `baseURLEnv/nativeAuth.env`）。
   - **自定义设置（折叠）**：`baseURL`（占位=目录的 `defaultBaseURL` 或 profile 解析值）+ 该 provider 的模型目录。
   - **模型目录**：每行 `id`、显示名（可空）、上下文窗口、最大输出 token、输入类型（文本/图片 checkbox）；拖拽排序；删除；「+ 添加模型」；「恢复默认模型」。
   - **自定义 provider（pi-ai 手写路由）额外**：Provider ID（唯一且不可改）、endpoint、协议（OpenAI Chat Completions / OpenAI Responses / Anthropic Messages）、以及**每个模型的思考强度列表**（`reasoningEfforts`：level→API value，参考目标里的「自定义提供商每个模型可选择可用思考强度」）。
   - 保存：`settings.mutate(ns, [{op:'set'|'unset', path:[…], value}], expectedRevision)`；`settings/conflict` 视为并发冲突（提示重读）；密钥单独 `credentials.set`，两步之间冲突需先重读再写。
5. 数据刷新：DSH 的 SPA 侧依赖设置/凭据/`llm` 的变更事件（`llm/adapters-updated` 已在 `dsh-llm/lib/types/types.d.ts` 确认；settings/credentials 的事件名以 `dsh-api-settings-controller` 与 `dsh-client-ui-settings-*` 为准 `[待验证]`）。原生端优先用 `session.control`/`observeEvent` 订阅；**保底且一定能工作的方案**：页面打开/下拉刷新/保存返回后重读 `settings.describe` + `llm.listConfigurableProviders` + `credentials.describe`，不依赖事件。
6. **首次配置不显示模型**：与目标一致——provider 未配置密钥时只显示“连接/凭据”卡片；密钥保存成功后才展开模型目录（DSH Web 用的是“先 key 后模型”的卡片态，可直接照搬）。
7. 失败诊断：`listConfigurableProviders()` 的 `error` 字段、`modelCatalog.failures`（聊天页模型目录）都要显示（例如“目录加载失败：无效密钥”），不要静默。

**实现取舍**：不要做通用 schema 渲染器。DSH 的 provider 配置 schema 是 schemastery 信封，逐字段渲染工作量大且易错；上面列出的字段集（key/baseURL/models/reasoningEfforts）正是 DSH Web 自己在“模型”页暴露的全部可编辑项（见 `dsh-client-ui-settings-models` README），手写表单 + 对 `llm-pi-ai` 少量字段即可覆盖。剩余 schema 字段（headers 等）明确标注“需在 DSH 配置文件修改”，不暴露按钮——符合目标里“遥控器不要有电视机没有的按钮，也不要把电视机能力藏起来”。

---

## 7. 设置框架与 DSH 助手设置页（4 个 tab）的落点

### 7.1 Cuplivo 设置框架

- 移动端：`lib/features/settings/pages/settings_page.dart`（`SettingsPage`）——`Scaffold` + 顶部搜索入口 + 若干 `SectionCard(children: [ _iosNavRow(...) ])`；点行 `Navigator.push` 到子页。`助手与群聊` 行 `:198-206`、`提供商` 行 `:225-234`。
- 桌面端：`lib/desktop/desktop_settings_page.dart`（`_SettingsMenuItem` 枚举 `:139`，搜索目标 `:184-206`），各 pane 在 `lib/desktop/setting/*.dart`（如 `assistants_pane.dart`、`providers_pane.dart`）；跨 pane 导航用 `lib/desktop/desktop_settings_navigation_bus.dart`（`DesktopSettingsNavigationTarget { backup, mcp, topicPosition }`）。
- 设置搜索：`lib/features/settings/search/settings_search_index.dart`（`SettingsSearchDestination` 枚举 `:9-46`，标题映射 `:48+`）、`settings_search_navigation.dart`（destination → 页面，`:55` 是 `assistant => ChatOwnerSettingsPage()`，`:57` providers）。
- 新页面不是必须进搜索索引（可选）；若进，需要改枚举 + 标题映射 + navigation switch 三处。

### 7.2 DSH 助手设置页（对应参考图 `image-01a1f4ab` / `image-01a1f4bc`）

入口：`AssistantEntryActions.openAssistantSettings` 分流；页面标题 = 助手名；四个 tab 用分段控件（参考图是横向药丸分段，正好是 `lib/shared/widgets/segmented_tabs.dart` 的 `SegmentedTabs`，`expand:false` + 横向滚动）：

| Tab | 内容 | 数据/实现 |
|---|---|---|
| **连接设置** | 助手名称 + 头像（`IosFormTextField` + `AssistantAvatar`/`AvatarMenu`）；「WebUI 访问链接」输入 + 「确认」按钮；连接状态（已连接/令牌失效/无法连通）与「断开」；参考图里只有名称、链接、确认三个元素 | 重新解析 URL → `/connect` 换 cookie → `session.list` 探活；成功后更新 `Assistant.dsh`；失败显示具体原因（DNS/拒绝连接/401/证书），不要只显示“失败” |
| **通用设置** | **只显示两项**：①「选择新会话的默认权限限制」（`permission-presets` 的 `defaultPreset`，选择器，选项来自 Host 的 permission catalog）；②「在使用官方模型 API 时上传 Session Log」（`session-log-deepseek` 插件的 `enabled` 开关，DSH Web 的 General 设置里由 `dsh-client-ui-settings-session-log` 贡献，且只在 Host 暴露该值时出现）。其余官方设置（语言/外观/字号/工作步骤展示、收起时机、回复显示、代码工作视图、快捷键、繁忙时发送行为、性能与用量）**一律隐藏** | 读写 `settings` Remote（`describe` 找对应 namespace/字段；`update`/`mutate` 带 `expectedRevision`）。`defaultPreset` 是 `Volatile<string \| undefined>`（Host 配置项）：先用 `describe` 确认可写，只读时展示为只读 + 说明“由 DSH 配置文件设置” `[待验证]`；Host 未暴露 namespace 的行不渲染 |
| **模型** | 见 §6.6（provider 列表 / 添加 / 详情 / 模型目录） | `llm` + `settings` + `credentials` |
| **插件内容** | 插件提供的设置页：**入口/tab 头是 Flutter，页面内部是 WebView**（目标明确）。插件清单用 `pluginInventory/list`（Remote；见 §3.2-6）原生渲染成行；点某插件 → 首选 WebView 打开该插件设置页，若 DSH 无独立深链则打开 DSH Web UI 的设置页并提示用户手动进入。插件若额外贡献 settings tab（`dsh-client-ui-settings-*`），同样只把入口 Flutter 化、内部 WebView | `pluginInventory/list` 已确认；`[待验证]` 插件设置深链；WebView 方案见 §8 |

- **桌面端**：遵守“桌面不用 bottom sheet”；设置页用 `Dialog`（参考 `_showAddAssistantDesktopDialog`，`assistants_pane.dart:353`）或设置窗口的 pane。tab 布局在桌面用左侧竖向 tab rail（可参考 `assistant_settings_edit_page.dart` 的桌面分栏 `DesktopAdaptivePanes`）。
- **样式**：块状内容一律 `SectionCard`；行内控件用 `IosFormTextField`/`IosSwitch`/`IosNavRow`；按钮用现有主按钮样式；参考图的黑底卡片/圆角/字重与 Cuplivo 主题一致（用 `context.appColors.surfaceCard`、`AppFontWeights`，不要硬编码颜色）。
- **注意**：DSH 助手**不能**进入本地 `AssistantSettingsEditPage`（其 tab 全部面向本地模型/提示词/记忆/工作区/MCP）；`Assistant.edit` 页的 tab id 常量在 `lib/features/assistant/utils/assistant_edit_tab_layout.dart`（`assistantEditTabBasic` 等常量 + 默认顺序列表），不要在那边加 DSH tab。

---

## 8. WebView 基础设施、明文/证书规则、cookie/token 认证

### 8.1 现有 WebView 能力

- 依赖（`pubspec.yaml`）：`webview_flutter ^4.13.1`（:116）、`webview_flutter_android ^4.14.1`（:117）、`flutter_inappwebview ^6.1.5`（:118）、`webview_flutter_wkwebview ^3.25.1`（:121）、`webview_windows`（:122，path dep）；inappwebview 的 android/ios/macos/windows 实现是仓库内 path forks（`pubspec.yaml:204-213`，`dependencies/flutter_inappwebview_*`）。**加 DSH WebView 不需要新依赖。**
- 浏览器引擎抽象：`lib/core/services/browser/browser_engine.dart`（`BrowserEngine`/`BrowserEngineFactory`/`BrowserPageState`）；原生实现 `lib/core/services/browser/browser_native_engine.dart`（`InAppWebView`、`HeadlessInAppWebView`、`CookieManager`）；服务 `lib/core/services/browser/browser_service.dart`（多 tab、历史、书签、下载、预览、agent tab 上限、live view 上限等）；cookie 辅助 `lib/core/services/browser/browser_download_cookies.dart`。
- 轻量页面模板（正是 DSH 面板/插件设置页该用的形态）：
  - `lib/features/chat/pages/html_preview_page.dart`（移动，`WebViewController` + `webview_flutter_android`/`webview_flutter_wkwebview` 平台参数）
  - `lib/desktop/html_preview_dialog.dart`（桌面 dialog 版）
  - `lib/features/intelligent_ui/host/ui_web_controller.dart`（另一处 WebView 封装）
- 侧栏内嵌浏览器：`lib/features/side_panel/widgets/side_panel_browser.dart`（`BrowserPage(embedded:true)`），由 `SidePanelTabKind.web` + `WebTab` 驱动。

### 8.2 DSH 认证模型（**已按 `lib/core/dsh/dsh_transport.dart` / `architecture.md` 校正**）

从 `dsh-client-connection` / `dsh-web-app`（0.2.2-rc.1）确认，并与已实现客户端 `lib/core/dsh/**` 对齐：

1. **启动令牌是进程级**：`dsh web` 打印 `dsh web: http(s)://<authority>/?token=<launch-token>`（`dsh-web-app/lib/index.js` 的 `announceReady`）。**进程重启令牌即变**；令牌只用于一次登录，客户端用完即弃，不落盘。
2. **登录 = 用令牌换 v1 浏览器 cookie**：`GET <base>/?token=…` → `303 Location: ./` + `Set-Cookie: dsh-auth-<base64url(sha256(authority))>=v1.<payload>.<hmac>; Max-Age=…; Path=/; HttpOnly; SameSite=Strict[; Secure]`。`Secure` 仅由该 TLS 监听器决定；有效期 `cookieMaxAgeDays`（默认 30 天）；**cookie 绑定 authority**：HTTP 用 `Host`（`host:port`），HTTPS 用 `origin`。换 authority（`127.0.0.1` ↔ 局域网 IP）即另一枚 cookie。
3. **v1 cookie 同时用于 API 与 WebView**（关键，很容易搞错）：
   - `HostConnectionService.admit()`（`dsh-client-connection/lib/index.js:740-752`）先 `browserAuth.isAuthenticated(request)`（v1 → 共享的 `browserPeer`），再 `authenticateApi`（v2 → 独立 operator peer）。所以 **v1 cookie 可以调用 `/api/<ns>/<method>`、也能建立 `/api/remote.mux` WS**。
   - `/connect?token=…` 换的是 **v2 operator cookie**：它只服务一个 mux 连接（`admitConnection` 对第二个 socket 返回 409）、浏览器页面不认它（`isAuthenticated` 只接受 v1）、且 **本特性不使用**（`architecture.md` 不变量 2）。
   - WebView 复用同一枚 v1 cookie 即可：用内置浏览器的 CookieManager 按 `authority` 写入 `dsh-auth-…`，或让 WebView 直接打开带 `?token=` 的 URL 让 DSH 自己 303。
4. **`/api` 请求的 Host/Origin 围栏**：`Host` 必须是 loopback、监听器 bind 字面量，或在 `--trusted-host` 声明内；带 `Origin` 时必须与 Host 同源；`Sec-Fetch-Site: cross-site` 拒绝。原生客户端不发 `Origin` 即可。
5. **非 loopback 访问**：`dsh web --host <本机LAN IP>` 后用该 IP 字面量访问会被 fence 接受（bind literal 自动信任）；用域名访问需要 `--trusted-host <host[:port]>`。`--public-url` 只影响打印/公告，不授予信任。
6. **TLS**：`--tls-cert/--tls-key`。自签名证书在 WebView 与 `dart:io` `HttpClient` 默认都被拒绝。首版只支持 **HTTP（局域网）**；HTTPS 需用户把 CA 装进系统信任库，或后续在传输层加证书处理（`[待验证]` 是否需要）。
7. **401 的语义**：cookie 丢失/过期/authority 不匹配/进程重启 → `401`（`writeUnauthorized` 文本：“…reopen the URL printed by dsh web.”）。连接设置必须能“只重新粘贴链接”（不需要改 baseUrl），并把 401 显示为“令牌/会话已失效，请重新粘贴 `dsh web` 打印的链接”。

**客户端实现约束（`lib/core/dsh/**`，已实现）**
- `dsh_transport.dart`：登录请求 → 解析 `Set-Cookie` → 内存 cookie jar（一条连接一枚 cookie）→ 每个请求带 `Cookie` 与正确 `Host`；Flutter-free，只依赖 `dart:io`。
- `dsh_endpoint.dart`：解析粘贴的链接（带/不带 scheme、带 token、带 path 前缀、IPv6），把 token 从 `baseUri` 去掉；恢复连接时可无 token（用已存 cookie）。
- 连接记录（`DshRemote`）只存 `baseUrl/authority/secure`，**不存 cookie、不存 token**；cookie 在 `flutter_secure_storage`（§1.4）。

### 8.3 平台明文/权限现状与需要补的

| 平台 | 现状 | DSH 需要的动作 |
|---|---|---|
| Android | `AndroidManifest.xml:46 android:usesCleartextTraffic="true"`，`:5 INTERNET` | 已满足明文 LAN；dart:io 与系统 WebView 均可用 |
| iOS | `ios/Runner/Info.plist:54 NSAllowsArbitraryLoadsInWebContent=true`（仅 WebView 内容），`NSLocalNetworkUsageDescription` 在 `:69`（文案只提“设备间同步对话”） | dart:io 的 `HttpClient`/`WebSocket` 不受 ATS 约束（不用 `cupertino_http` 即可），HTTP 可用；WebView 也可用。**要更新 `NSLocalNetworkUsageDescription` 文案**（加入“连接你局域网内的 DeepSeek Harness”）——它是 native 权限文案，`tool/l10n/translate.py` 的 `native_messages()` 从 `Info.plist` 读 `*UsageDescription`（按 `中文 / English` 格式拆分），改文案会改变 native 指纹，**必须跑 `translate.py sync` 重生成 4 个 locale 的 `InfoPlist.strings`**，否则 CI 的 `translate.py check` 报 native stale |
| macOS | `macos/Runner/Info.plist:16 NSAllowsArbitraryLoadsInWebContent=true`；`com.apple.security.network.client` 在 DebugProfile/Release/RestoreHarness entitlements 都有 | dart:io 可用；macOS 15+ 的本地网络隐私提示需要 `NSLocalNetworkUsageDescription`（当前 macOS Info.plist 没有）—— **待真机验证**；若被拦，补文案（同样要 native l10n sync） |
| Windows/Linux | 无明文策略 | 无需动作 |

### 8.4 WebView 在 DSH 特性里的用法（按目标）

1. **右栏插件面板**（§5）：DSH 右栏内容是 SPA 贡献，无独立 URL → 只能加载整个 Web UI（体验上限低）。首版建议“原生概览 + 用内置浏览器/WebView 打开 DSH Web UI”。
2. **设置页的「插件内容」tab**（§7.2）：入口（插件清单）来自 `pluginInventory/list`，Flutter 原生；内部页面 WebView。
3. **（可选）DSH 的“浏览器”工具面板**：DSH 自己内嵌浏览器；Cuplivo 侧要么原生路由到 `browser` RPC（若存在），要么 WebView。
4. **明确可以原生、无需 WebView 的**：插件清单（`pluginInventory/list`）、自动化任务列表（`schedule` Remote）、会话/工作区/模型/权限（前面各节）。WebView 只保留给“插件自己画的 UI”。
- 三个用法共用一个 `DshWebPanel` 组件（`lib/features/dsh/widgets/dsh_web_panel.dart`）：输入 URL、共享 cookie/UA、错误页（401/证书错误/连接失败）、返回/刷新、加载指示；移动用全屏页面，桌面用 dialog 或右栏。注意 `WebViewController` 生命周期与 `PageStorage`/热重启；Android 需要 `WebViewPlatform` 初始化（现有 `html_preview_page` 已处理，抄它）。

---

## 9. 共享组件（含 import 路径与最小示例）

原则（AGENTS.md UI guidelines）：优先用 `lib/shared/widgets/` 与 `lib/shared/dialogs/`；桌面不得用 bottom sheet；图标用 `lucide_icons_flutter` 适配层 `Lucide.*`（`lib/icons/lucide_adapter.dart`），不用 `Icons.*`；动效用 `flutter_animate`/`animations`。

| 组件 | 路径 | 关键 API | DSH 页面用法 |
|---|---|---|---|
| `SectionCard` | `lib/shared/widgets/section_card.dart` | `SectionCard({children \| child, padding, radius, variant, shadow, dividers, crossAxisAlignment})` + `sheetTileColor`/`showSheetTileDividers` | 连接设置块、通用设置块、模型页分区 |
| `CustomBottomSheet` / `showCustomBottomSheet` | `lib/shared/widgets/custom_bottom_sheet.dart` | `showCustomBottomSheet(context, title: …, builder: …)` | 移动端「连接到一个新的 DSH」「直接连接」表单、DSH 模型 sheet、加号 sheet |
| `IosFormTextField` | `lib/shared/widgets/ios_form_text_field.dart` | `IosFormTextField(label, controller, hintText, suffix/prefix, maxLines, obscureText, onChanged, …)` | 助手名、WebUI 链接、API key、baseURL、模型字段 |
| `IosCheckbox` | `lib/shared/widgets/ios_checkbox.dart` | `IosCheckbox(value, onChanged, size, activeColor, semanticLabel)` | 模型输入类型（文本/图片） |
| `IosSwitch` / `IosNavRow` / `IosSwitchRow` / `IosSectionHeader` / `IosSectionFooter` / `IosRowDivider` | `lib/shared/widgets/ios_switch.dart`、`lib/shared/widgets/ios_settings_rows.dart` | 导航行、开关行、分组头/脚 | 通用设置两项、模型行、provider 行 |
| `IosCardPress` / `IosIconButton` / `IosTactile` | `lib/shared/widgets/ios_tactile.dart` | 可按压卡片/图标按钮/触感 | 所有可点行、AppBar 按钮 |
| `InteractiveDrawer` | `lib/shared/widgets/interactive_drawer.dart` | `InteractiveDrawerController`（open/close/toggle/animateTo/jumpTo/handleBack）、`InteractiveDrawer(child, drawer, controller, side, drawerWidth, scrimColor, maxScrimOpacity, barrierDismissible)` | 移动端右栏（`DrawerSide.right`） |
| `showAdaptiveActionMenu` / `ActionSheetItem` | `lib/shared/widgets/action_sheet.dart` | `showAdaptiveActionMenu(context, {anchor, anchorKey, title, items})`；桌面自动转 `DesktopContextMenu` | 「+」菜单、行菜单、权限选择 |
| `showAppSnackBar` | `lib/shared/widgets/snackbar.dart` | `showAppSnackBar(context, message:, type: NotificationType.error, actionLabel:, onAction:)` | 连接失败、保存失败、令牌失效 |
| `SegmentedTabs` | `lib/shared/widgets/segmented_tabs.dart` | `SegmentedTabs(tabs:[SegmentedTab(label,icon)], index, onChanged, expand:false, height:…)` | DSH 设置页 4 tab、添加 provider 的模式切换（第三方/自定义） |
| `EffortSlider` | `lib/shared/widgets/effort_slider.dart` | 推理强度滑块 | 可选：DSH 推理强度若为“连续值”再用；DSH 是离散 efforts，优先 chip/分段 |
| `AssistantAvatar` / `ConfigurableAvatar` | `lib/features/home/widgets/assistant_avatar.dart`、`lib/shared/widgets/configurable_avatar.dart` | 头像+品牌 fallback | DSH 助手行、AppBar、设置页 |
| `CurrentModelIcon` | `lib/features/home/widgets/model_icon.dart:12` | `providerKey/modelId/size/withBackground` | DSH 模型胶囊/行图标（无 ProviderConfig 时按品牌名兜底） |
| `ConfigurableAvatar` | 同上 | — | provider 图标（品牌资产 `lib/utils/brand_assets.dart`） |
| 主题 | `lib/theme/app_semantic_colors.dart`、`lib/theme/app_font_weights.dart`、`lib/theme/design_tokens.dart` | `context.appColors.*`、`AppFontWeights.*`、`DesignTokens` | 颜色/字重/间距一律取主题 |
| 触感 | `lib/core/services/haptics.dart` | `Haptics.light()` 等 | 点按/切换反馈 |

最小示例（连接表单，移动端）：

```dart
showCustomBottomSheet(
  context: context,                 // 注意：真实签名是命名参数
  title: l10n.dshConnectTitle,
  builder: (ctx) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
    child: Column(mainAxisSize: MainAxisSize.min, children: [
      IosFormTextField(
        label: l10n.dshAssistantNameLabel,
        controller: nameController,
        hintText: 'DeepSeek Harness',
      ),
      const SizedBox(height: 12),
      IosFormTextField(
        label: l10n.dshWebUiUrlLabel,
        controller: urlController,
        hintText: l10n.dshWebUiUrlHint, // 例如 127.0.0.1:3080/?token=…
        maxLines: 2,
      ),
      const SizedBox(height: 8),
      Text(l10n.dshConnectLanHint, style: TextStyle(color: cs.onSurface.withValues(alpha: .6), fontSize: 12)),
      const SizedBox(height: 16),
      SizedBox(width: double.infinity, child: FilledButton(onPressed: submit, child: Text(l10n.dshConfirm))),
    ]),
  ),
);
```

---

## 10. l10n 契约（新增文案的完整流程）

### 10.1 结构

- 配置：`l10n.yaml`（`arb-dir: lib/l10n`、template `app_en.arb`、输出 `app_localizations.dart`、`untranslated-messages-file: desiredFileName.txt`）。
- ARB：`lib/l10n/app_en.arb`（模板/唯一权威 key + `@key.description`）、`app_zh.arb`（语义源，key 集必须与 en 完全一致）、`app_zh_Hans.arb`（zh 的别名，`check` 要求与 zh 逐字节一致）、`app_ru.arb`、`app_ko.arb`、`app_tr.arb`、`app_zh_Hant.arb`（机器翻译，`tool/l10n/state/*.json` 存指纹）。生成物：`lib/l10n/app_localizations*.dart`。
- 语言枚举：`lib/l10n/app_language.dart`（6 种，含 zh_Hant 识别规则）。

### 10.2 新增一条文案的步骤（必须全做）

1. `lib/l10n/app_en.arb` 加 key + 值 + `@key` 的 `description`（说明用途/上下文；带占位符的按 ARB 格式写 `placeholders`）。
2. `lib/l10n/app_zh.arb` 加同 key 中文。
3. 若改动了 `ios/Runner/Info.plist` 的 `*UsageDescription` 或 Android `phone_control.xml` 等 **native** 文案：改完 Info.plist 后必须跑 sync（见 4），否则 `translate.py check` 报 native stale。
4. 运行 `python3 tool/l10n/translate.py sync`（或 `describe` 后再 sync）。它会：为 ru/ko/tr/zh_Hant 调模型补翻译并校验 → 写 ARB 与 `tool/l10n/state/<locale>.json` 指纹 → 同步 native 资源（iOS `*.lproj/InfoPlist.strings`、ShareExtension `Localizable.strings`、Android `values-<locale>/phone_control.xml`）→ 写 `app_zh_Hans.arb` → 最后执行 `flutter gen-l10n`。
   - 需要网络 + 翻译模型密钥（`Client` 配置）；**离线时无法用 sync**。手工补齐 4 个 ARB 并手算指纹理论上可行（fingerprint = sha256(json([en, zh, @en, locale, GLOSSARY[locale], PROMPT_VERSION], sort_keys=True))），但不推荐，易错且 CI 一跑就现形。
5. 提交：所有改动 ARB + `tool/l10n/state/*.json` + `lib/l10n/app_localizations*.dart`（生成物按生成器格式提交，禁止手工格式化）。
6. 本地校验（CI 也会跑）：`flutter gen-l10n` 后 `git diff --exit-code -- lib/l10n` 必须干净；`python3 tool/l10n/translate.py check` 必须通过（它检查 en/zh key 集一致、每条有 description、每个 locale 无 stale、`app_zh_Hans.arb == app_zh.arb`、native 资源非 stale，并调用 `tool/l10n/validate.dart` 校验 ICU 占位符等，另加“中文残留/URL 保持/换行数一致”规则——见 `translate.py:135 validate()`）。

### 10.3 命名与文风

- key 用 camelCase 前缀分组，本次建议前缀 `dsh`（如 `dshAssistantSectionTitle`、`dshConnectTitle`、`dshConnectDirect`、`dshWebUiUrlLabel`、`dshConnectLanHint`、`dshConnectionFailed`、`dshTokenExpired`、`dshPermissionTitle`、`dshPermissionReadOnly`、`dshPermissionWorkspaceWrite`、`dshPermissionFullAccess`、`dshModelSheetTitle`、`dshProviderAddTitle`、`dshPluginSettingsTitle`…）。
- **权限档位名称不要自造**：DSH 的 catalog 提供显示名（内置中文是“仅可查看 / 工作区内修改 / 完全权限”，英文 Read Only / Workspace Write / Full access）。UI 优先用 catalog 里的 `name`/`description`（Host 可配置），只有 catalog 缺失时用本地 l10n 默认文案兜底。
- 英文是语义权威；中文提供语义上下文；不要写“DeepSeek Harness”进翻译（品牌名原样）。

### 10.4 风险

- 一次 PR 加几十条文案会让 sync 慢且贵；尽量复用既有 key（如“确认/取消/重试”已有）。
- CI 的 `dart format` 只检查**改动文件**（`git diff --name-only` 过滤 `lib|test|integration_test|tool|dependencies/markstream/(lib|test)`），新增文件记得格式化。
- 生成物 `app_localizations*.dart` 由 `flutter gen-l10n` 写出，**不要**用 `dart format` 重新格式化（AGENTS.md 明确；CI 会对比）。

---

## 11. 测试 / CI / e2e 约定

### 11.1 CI（`.github/workflows/pr-check.yml`）

- 固定 `FLUTTER_VERSION: '3.47.6'`（Dart 3.13.0）；`flutter pub get --enforce-lockfile`（root、`dependencies/markstream`、`tool/l10n`）——**不要改 `pubspec.lock` 除非改依赖且一次 `flutter pub get` 后提交**。
- 步骤（按 workflow 顺序）：`dart format --output=none --set-exit-if-changed`（只检查改动 Dart 文件）→ `flutter gen-l10n` + `git diff --exit-code -- lib/l10n` → `python3 tool/l10n/translate.py check` → l10n 工具单测 → `Identity sweep (forward)`（品牌名/敏感串扫描）→ identity 工具测试 → e2e report 工具测试 → `dart analyze --fatal-infos lib test integration_test tool` → `flutter test` → markstream `dart analyze --fatal-infos` + `flutter test`。
- **禁止本地跑上述任何 Flutter 测试/构建/analyze**（Lead 决议 + goal-brief 执行准则①）。本地只允许：`dart format`（固定 SDK）、`flutter gen-l10n`、`translate.py sync`、以及只读命令。验证靠 PR 的 Actions，因此**提交要小步**，每次失败按 CI 日志修。
- 注意 `--fatal-infos`：新增代码不能有 `unused_import`/`deprecated`/`prefer_const` 之类 info。

### 11.2 必须新增/扩展的测试（按改动面）

| 改动 | 测试 |
|---|---|
| `Assistant` JSON 新字段 | `test/core/models/assistant_*`（新增 `assistant_dsh_kind_test.dart`：toJson/fromJson 往返、缺省 → local、未知 kind 降级）；`test/core/database/assistant_upgrade_contract_test.dart` + fixture 旧 JSON 仍可读 |
| 新 preference key | `test/core/database/business_key_registry_sync_test.dart`（CI 自动扫）；`business_settings_router_test.dart` 的 synced/deviceLocal 面 pinning；`backup_portability_test.dart`（deviceLocal 从出行备份剥离） |
| 备份合并新字段 | `business_settings_merger_test.dart`：两台设备合并 DSH 助手时 `dsh` 字段归属（incoming 覆盖 vs 本地保留） |
| 协议层 | 新 `test/features/dsh/dsh_rpc_client_test.dart`（wire：`POST /api/<ns>/<method>`、`{args:{}}`、`{ok:true|false}` 信封、401/超时）；`dsh_stream_channel_test.dart`（open/item/end/cancel 帧、error 帧、重连）；用 spike 抓的真实 JSON 做 fixture |
| URL/token 解析 | `test/features/dsh/dsh_connection_url_test.dart`：裸 host:port、带 scheme、带路径、缺 token、多 token、IPv6、端口缺省、尾斜杠 |
| 侧栏数据源注入 | `test/features/home/widgets/side_drawer_*`（若存在）+ 新增 `side_drawer_remote_source_test.dart`：本地模式下行集合不变（回归）；远程模式走注入源 |
| 右栏面板 | `test/features/side_panel/`（几何纯函数）+ 新增 `dsh_side_panel_test.dart`（docked 挤压/展开全宽/移动端抽屉） |
| 模型/权限选择器 | `test/features/dsh/dsh_model_sheet_test.dart`、`dsh_permission_selector_test.dart`（catalog 缺省兜底、当前值映射、写回失败提示） |
| 聊天渲染映射 | `test/features/dsh/dsh_turn_assembler_test.dart`：DSH 事件样本 → `ChatMessage`/`ReasoningSegmentData`/`ToolUIPart`/`ContentSplitData`；流式追加/结束/错误 |
| 页面 | `test/features/dsh/dsh_assistant_settings_page_test.dart`（4 tab、只读态、保存失败）；widget 测试必须提供 Provider 依赖（参考现有 `test/features/assistant/**` 的 test harness 写法） |

测试基础设施注意：`test/flutter_test_config.dart` 目前只是执行 `testExecutable`，无全局 mock；需要自建 fake（`FakeDshClient` 接口化，协议层用抽象 `DshTransport`）。

### 11.3 e2e（Android，PR 评论 `/e2e` 或 `run-e2e` label）

- 工作流 `.github/workflows/e2e-android.yml`；文档 `docs/e2e-android.md`；约定：**一个 PR 只能改一个** `integration_test/e2e/<name>_test.dart`，从 `integration_test/e2e/acceptance_support.dart` 的 `bootSeededApp` 启动，fixture 在 `test/support/e2e_app_seed.dart`（生产入口 + 临时目录 + Drift 种子），截图 1–3 张，driver `test_driver/e2e_review.dart` 上传 APK/截图/录屏；示例 `integration_test/e2e/example_acceptance_test.dart`（打开设置页并截图）。
- DSH 的 e2e 特殊点：**不能依赖真实 DSH 服务器**（CI 环境无，且不许硬编码 IP/key）。两种做法：
  1. 在 e2e fixture 里起一个**本地 mock DSH**（Dart 起 `HttpServer`，实现 `/connect`、`session.list`、`session.projections`、最小 follow 流）——推荐，稳定且能覆盖 UI；e2e fixture 已有“替换 path_provider 后跑生产 app”的先例，加本地 HTTP server 只是多一个后台任务。
  2. 连接真实 us-vps 上的 DSH：需要 repo secrets（URL/token），且 token 进程重启即失效 → 不适合 CI。仅手动验证时使用，**绝不能把 key/IP 写进代码**（identity sweep 会扫）。
- e2e 只验证**新增 UI 是否符合参考图**（目标明确：不负责回归）；建议场景：设置›助手与群聊›+›DeepSeek Harness›直接连接（输入 mock URL）→ 连接成功行出现 → 选中助手 → 会话页出现模型胶囊/权限选择器 → 打开右栏截图。
- PR 正文用中文，附截图（目标要求）。

### 11.4 提交纪律

- 只改必要文件；`git status` 确认没有把 `docs/cuplivo-dsh/reference/**`（未跟踪参考图）、`/tmp` 内容、目标简报 `moodiary-*.md` 加进仓库。
- 文档（本文件）不参与 analyze/test（`dart analyze` 只扫 `lib test integration_test tool`）。
- 每阶段结束把“已完成/未完成/风险”写回 PR 描述或任务卡，便于 Lead 复核。

---

## 12. 文件级实施计划与风险清单

### 12.1 实际代码布局（以 `implementation-contract.md` 的文件归属为准）

研究阶段拟的 `lib/features/dsh/**` 单域已被契约拆成两层（**协议层 Flutter-free** + **feature 层**）。实现时按下面这张表找文件，**不要**再新建 `lib/features/dsh/`：

```
lib/core/dsh/                     # 协议客户端（只 import SDK + 同层文件；Flutter-free、可单测）
  dsh_endpoint.dart               # 粘贴链接解析/规范化、baseUri+token、登录/恢复 URL
  dsh_transport.dart              # v1 cookie 登录、HTTP 调试/UNAUTH 分类、WS 连接、cookie jar
  dsh_rpc.dart                    # POST /api/<ns>/<method> 信封 {args:{}} → {ok,value|error}
  dsh_mux.dart                    # /api/remote.mux 帧协议（open/item/end/cancel）
  dsh_events.dart                 # stream/事件帧模型
  dsh_models.dart                 # SessionSummary/ModelCatalog/SessionState/投影 等 DTO
  dsh_errors.dart                 # DshFailure 分类（auth/network/protocol/…）
lib/features/harness/
  models/    dsh_remote.dart, dsh_web_ui_link.dart
  services/  dsh_remote_store.dart（dsh_remotes_v1）, dsh_credential_store.dart（secure storage）
  state/     dsh_connections_provider.dart, dsh_gateway.dart
  controllers/ dsh_chat_session.dart, dsh_composer_submission.dart, dsh_transcript_fold.dart,
               dsh_chat_controllers_provider.dart
  pages/connect/dsh_connect_mode_sheet.dart
  pages/assistant/dsh_assistant_settings_page.dart
  pages/home/**                  # 首页/侧栏/右栏的 harness 模式
  pages/chat/**                  # 会话体 + composer + 选择器（切片中）
  widgets/   dsh_owner_card.dart, dsh_link_status_dot.dart, dsh_whale_mark.dart,
             dsh_filled_button.dart, dsh_failure_text.dart, chat/dsh_model_picker.dart,
             chat/dsh_picker_scaffold.dart
  test: test/core/dsh/**, test/features/harness/**
```
- 归属/写权限见 `implementation-contract.md` 的 ownership 表（协议层 `dsh-client-core`；owner/持久化/连接页 `harness-foundation`；首页/侧栏/右栏 `harness-home`；会话体/输入区/选择器/插件页 `harness-chat`；ARB 串行）。
- 下面 §12.2 的阶段划分仍按“用户可见能力”描述，文件落点以上表为准。

### 12.2 分阶段（每阶段可独立合并、可独立 e2e）

> 表中的 `dsh_*` 文件名是**能力占位**（便于排期），实际落点见 §12.1 与 `implementation-contract.md` 的 ownership 表。

| 阶段 | 内容 | 主要文件 | 验收 |
|---|---|---|---|
| **P0 spike**（不合并代码，只合并脱敏 fixture） | 打通 `/connect`、`session.list`、`session.wait`、`session.prompt`、`session.follow`；dump 样本 JSON；确认权限 catalog 读取路径、事件 schema、`requestId` 回传、插件设置深链 | 一次性脚本放**仓库外**（如 `/root/research/…`）或使用后删除；只把脱敏 JSON 放 `test/fixtures/dsh/*.json`（不含 token/IP/真实内容） | 得到 `test/fixtures/dsh/*.json` |
| **P1 连接与 owner** | `ChatOwnerKind.harness` + `DshRemote`；`+` 菜单第三项；动态连接（方法 sheet + 直接连接）；v1 cookie 登录/恢复；连接状态/失败；DSH 设置页「连接设置」；侧栏/设置页行副标题“远程连接的 DeepSeek Harness” | `lib/core/models/chat_owner.dart`、`lib/core/providers/chat_owners_provider.dart`、`lib/features/harness/{models,services,state,pages/connect,pages/assistant,widgets}`、`assistant_settings_page.dart`/`assistants_pane.dart` 的菜单、`business_settings_router.dart`、`main.dart`、l10n | 真机连接成功/失败/401 重贴链接；e2e 场景 1（连接表单 + 成功行） |
| **P2 会话浏览与只读聊天** | harness owner 下的侧栏/右栏（`lib/features/harness/pages/home/**`、`widgets/dsh_side_bar.dart`）；工作区分组；打开会话（`session.wait` 拉历史 + `dsh_transcript_fold.dart` 折叠成 `ChatMessage`）→ `MessageListView` 渲染；AppBar 标题/模型胶囊；`session.create` 新建 | `side_drawer.dart`+两套 home layout 的 harness 分支、`lib/features/harness/controllers/{dsh_chat_session,dsh_transcript_fold,dsh_chat_controllers_provider}.dart`、`lib/features/harness/pages/chat/**` | 打开真实/mock 会话渲染与参考图一致；e2e 场景 2（会话页截图） |
| **P3 发送与流式** | `ChatInputBar` 装配；`session.prompt`/`cancel`/排队；`session.follow` 流式渲染（思考/工具/正文增量）；错误与重试；停止 | `dsh_chat_controller.dart`、`dsh_event_adapter.dart`、`dsh_chat_view.dart`、input bar 参数 | 真机/ mock 发送、流式、取消；e2e 场景 3 |
| **P4 模型与权限** | DSH 模型 sheet（catalog/efforts/selectModel）；权限选择器（catalog + projection + 默认权限设置）；`通用设置` 两项 | `dsh_model_controller.dart`、`dsh_model_sheet.dart`、`dsh_permission_selector.dart`、`dsh_assistant_settings_page.dart`、settings RPC 封装 | 切模型/切推理/切权限生效（用 DSH Web 对照） |
| **P5 右栏 + WebView** | 右栏容器（桌面挤压/移动全屏推入）；原生“开始”面板（工作区文件/终端/浏览器/更多工具入口，能原生则原生）；插件入口 + `DshWebPanel`；设置页「插件内容」tab | `dsh_side_panel_host.dart`、`dsh_web_panel.dart`、`home_mobile_layout.dart`、`home_desktop_layout.dart`、`side_panel_geometry.dart`（抽公共） | 右栏打开截图与参考图一致；WebView 登录成功 |
| **P6 provider/模型管理** | 模型 tab 的 provider 列表/添加/详情/模型编辑（§6.6）；credentials 写入；冲突处理 | `dsh_provider_pages.dart`、`dsh_provider_view.dart`、`dsh_api.dart` | 新增自定义 provider、保存密钥、拉模型、启用/禁用、改思考强度 |
| **P7 收尾** | 视觉打磨（对照所有参考图）、错误文案、性能（流式节流）、i18n、e2e 截图、PR 正文 | 全体 | PR 检查全绿 + e2e 截图与参考图一致 |

> 依赖顺序：P1 依赖 P0 的 URL/cookie 结论；P2/P3 依赖 P0 的事件 schema；P4 依赖 P2/P3 的聊天壳；P5/P6 可并行（不同文件）；P6 的 provider 目录依赖 `llm` Remote 的可用性（P0 验证）。

### 12.3 必须修改的现有文件（汇总）

| 文件 | 改动 | 归属 |
|---|---|---|
| `lib/core/models/chat_owner.dart` | 新增 `ChatOwnerKind.harness`、`ChatOwner.harness`、`isHarness`、key `harness:<id>`；审计注释 | harness-foundation（已改） |
| `lib/core/providers/chat_owners_provider.dart` | 第三数据源 `HarnessOwnerSource`，`inOwnerOrder` 纳入 harness，编辑/删除分流 | harness-foundation（已改） |
| `lib/features/assistant/pages/assistant_settings_page.dart` | 「+」菜单第三项（动态连接）；harness 行解析/铅笔分流 | harness-foundation |
| `lib/desktop/setting/assistants_pane.dart` | 桌面菜单第三项 + 行渲染 | harness-foundation |
| `lib/features/home/widgets/side_drawer.dart` | 渲染 harness 行、铅笔跳 DSH 设置页；会话列表在 harness owner 下用远程会话列表（§3.2） | harness-home |
| `lib/features/home/controllers/home_page_controller.dart` | `openOwner` 在会话逻辑**之前**按 `isHarness` 分支（远程不拥有本地会话）；不改 `switchConversationAnimated`/`sendMessage` 核心 | harness-home |
| `lib/features/home/pages/home_page.dart` + `home_mobile_layout.dart` / `home_desktop_layout.dart` | harness owner 的 body/回调和 AppBar 动作（去 minimap、新会话右侧加右栏、DSH 模型胶囊/标题） | harness-home |
| `lib/features/side_panel/widgets/side_panel_geometry.dart`（已建）+ `desktop_side_panel_controller.dart` | 抽几何常量/纯函数供 DSH 右栏复用 | harness-home |
| `lib/main.dart` | 注册 `DshRemoteStore`/`DshCredentialStore`/`DshConnectionsProvider` 等 | harness-foundation |
| `lib/core/database/business_settings_router.dart` | 注册 `dsh_remotes_v1`（deviceLocal/networkEnvironment） | harness-foundation |
| `lib/l10n/*` + `tool/l10n/state/*` | 新 key、生成物、native 资源 | 串行（announce） |
| `ios/Runner/Info.plist` + native 资源 | 若改 `NSLocalNetworkUsageDescription` 文案（sync 生成） | 串行（announce） |
| `pubspec.yaml`/lock | **无新增依赖**（`dart:io`；`flutter_secure_storage` 仓库已有） | — |

### 12.4 风险清单（按优先级）

1. **DSH 是移动靶（0.2.2-rc.1）**：事件 schema / Remote 方法可能变。缓解：协议集中在一个 `dsh_event_adapter.dart` + 夹具；错误可诊断（显示 code/message）；不把 DSH wire 类型泄漏到 UI。
2. **事件 schema 未知**（最重要）：`SessionWireEvent`/assistant stream/tool 步骤/思考的实际字段必须先 spike dump，再写映射；本文只锁定 Cuplivo 侧需要的结构。
3. **令牌进程级失效**：DSH 重启后旧 URL 失效，用户必须重新粘贴；连接设置必须能“只换 token”；错误文案要解释“请用 dsh web 启动时打印的新链接”。`dsh web` 的 token 不持久化（进程级），这是产品级 UX 约束。
4. **authority 绑定 cookie**：换 IP/主机名（局域网 vs 回环）会重新登录；连接时就把 `authority` 固化并用于所有请求；不要在连接后改用另一地址。
5. **`--trusted-host` 需求**：用域名/反代访问 LAN DSH 时，Host 不在 bind literal/loopback 中 → 用户需用 `--host` 或 `--trusted-host` 启动，否则 403/401。连接失败文案要给出可操作建议。
6. **自签名 TLS**：WebView/原生都拒绝；首版限制 HTTP + 明确提示。真机测试要覆盖。
7. **iOS/macOS 本地网络权限**：iOS 已有 `NSLocalNetworkUsageDescription`（文案需更新）；macOS 15+ 可能弹窗且缺 key → 真机验证。改 native 文案必须跑 `translate.py sync`（否则 CI native stale）。
8. **SideDrawer 5.5k 行改造**：只做“数据源注入 + 远程列表 widget”最小改动，默认路径行为必须不变（加回归测试）；不要重写行模型。
9. **HomePage 双状态风险**：远程/本地切换时 `currentAssistant`/`ChatOwnersProvider`/`ChatService` 可能残留状态（例如本地正在流式 → 切到 DSH）。缓解：切换 owner 时显式取消/忽略本地流，DSH 自己的 controller 只认自己的会话；UI 上禁止“远程会话多选/本地草稿”混用。
10. **跨版本备份丢连接记录**：`dsh_remotes_v1` 是 `deviceLocal`，正常备份/同步**本来就不带它**（这是设计），换机/恢复后需要重新连接——不是缺陷，但要在发布说明/PR 里写清楚；旧版本 Cuplivo 也不会认识这个 key。
11. **凭据边界**：v1 cookie 在 `flutter_secure_storage`，不随备份/恢复/同步；启动令牌只在内存。风险变成“设备被解锁即可用 cookie 连 DSH”，与 provider API key 的信任边界一致；删除 remote 时必须同时删 cookie（已实现 best-effort 删除）。
12. **模型/权限 catalog 读取路径未定**：`permissionCatalog` 是否 Remote 可读需 spike；不可读时退化为“默认权限设置 + 当前值只读”（不能假装能切）；这会影响目标⑦的完整度，需尽早确认。
13. **provider 管理表单工作量大**：DSH 的 schema 表单、pi-ai 自定义路由、模型编辑/排序/恢复默认、credentials 两步写入都要做；建议 P6 单独排期，不要塞进 P1。
14. **WebView 无法只渲染插件面板**：目标允许“插件内面板只能 WebView”，但 DSH 无独立 URL；先做“入口 Flutter + 整个 Web UI WebView/浏览器”的诚实方案，并把限制写进 PR；若产品不能接受，需要 DSH 侧先提供面板路由。
15. **l10n 成本**：文案多、sync 需要网络；每次加 key 都要跑；CI `translate.py check` 会挡。
16. **CI 反馈周期**：本地不能跑测试 → 每个 PR 要小、要能快速定位；`--fatal-infos` 会让小疏忽变红。
17. **性能**：DSH 事件频率可能高于本地 SSE；`MessageListView` 全量重建会卡。缓解：按 `StreamController` 的节流/分片做法，正文与工具/思考分 notifier 推送；长会话用分页。
18. **附件/文件/终端/浏览器等 DSH 能力**：UI 上不要出现“遥控器有按钮但电视没有”的功能（例如本地“翻译/语音”按钮直接可用没问题；DSH 无的能力不要画）。列出能力矩阵并与 DSH Web 对照。

---

## 13. 现有 DSH 指针与可借鉴的既有实现

### 13.1 本机 DSH 事实（0.2.2-rc.1）

- 安装位置：`/usr/local/lib/node_modules/@deepseek-ai/dsh`；CLI：`dsh web --help` → `dsh --profile web`，flags：`--host`（单个具体 IPv4/IPv6 字面量，拒绝通配）、`--port`（0 = 随机）、`--public-url`、`--trusted-host`（可重复，host 或 host:port）、`--tls-cert/--tls-key`、`--no-open`。
- 启动输出：`dsh web: http(s)://<authority>/?token=<launch-token>`（`dsh-web-app/lib/index.js` `announceReady`）。
- 认证：见 §8.2（token → 303 + v1 浏览器 cookie；`/connect` → 302 `/api/remote.mux` + v2 API cookie；cookie `dsh-auth-<base64url(sha256(authority))>`，HttpOnly/SameSite=Strict/30 天/按 TLS 加 Secure；authority 绑定；`/api` Host/Origin 围栏；非 loopback 需 bind literal 或 `--trusted-host`）。
- 传输：unary `POST /api/<namespace>/<method>`，`Content-Type: application/json`，body `{"args": {…named…}}`，响应 `{"ok":true,"value":…}` / `{"ok":false,"error":{code,message,details?}}`；流式 `WebSocket /api/remote.mux`，帧：上行 `open{streamId,endpoint,payload}` / `item{streamId,value?}` / `end` / `cancel`，下行 `item` / `error{code,message,details}` / `end`（`@deepseek-ai/dsh-api-gateway/lib/types/stream-protocol.d.ts`）。payload 与 unary 一样是 `{"args":{…}}`。
- Remote 命名空间（本版本安装包中确认）：
  - `session`（`dsh-api-session-controller`）：`list/search/create/selectModel/initializeDefaultModel/modelCatalog/canOpenWorkspacePath/workspaceDesktop/openWorkspacePath/workspacePathApplications/rename/fork/prompt/attachment/updateQueue/cancel/page/events/observeEvent/observeProjections/state/observeState/wait/follow/projections/control`。
  - `workspace`（`dsh-api-workspace-controller`）：`create/initializeDefault/rename/delete/insertBefore/insertSessionBefore/archiveSession/unarchiveSession/pinSession/unpinSession/follow`。
  - `settings`（`dsh-api-settings-controller`）：`describe/update/replace/mutate/openSettingsDocument`；`credentials`：`describe/set/unset`。
  - `llm`（`dsh-llm` `LlmRuntime`）：`listProviders/listConfigurableProviders/discoverModels`（事件 `llm/adapters-updated`）。
  - `pluginInventory`（`dsh-host-plugin-inventory`）：`list` → Host 当前插件快照（entry id/module/enablement/phase/`meta`，可选 `agentPresets` 组合）。
  - `schedule`（`dsh-schedule`，页面“Automation tasks”）：`remoteList/remoteCreate/remoteEdit/remoteHistory` 等；`job`（`dsh-api-job-controller`，stream）：`job.list {sessionId}` 会话任务名册、`job.follow {sessionId?,jobId,from?}` 输出流、`job.kill {sessionId,jobId}`；`terminal`（`dsh-api-terminal-controller`）按右栏终端面板需要再查。
- 类型定义就在安装包里（比文档更权威）：`node_modules/@deepseek-ai/dsh-api-session-controller/lib/types/types.d.ts`（`SessionSummary/ModelCatalog/SessionPromptRequest/SessionState/SessionProjectionsValue/…`）、`dsh-api-gateway/lib/types/stream-protocol.d.ts`、`dsh-client-connection/lib/types/*`、`dsh-llm/lib/types/types.d.ts`（`LlmConfigurableProvider` 等）、`dsh-settings/lib/types/types.d.ts`（settings 视图）。
- 读 README 比读 dist 快：每个包都有 `README.md` + `README.zh.md`（如 `dsh-client-ui-settings-models`、`dsh-client-ui-permission-presets`、`dsh-client-ui-settings-session-log`），它们描述 UI 行为与数据来源，是复刻原生 UI 的最佳规格说明。

### 13.2 目标里提到的 DSH-GO 调研（待办）

- 目标建议参考 DSH-GO 的实现（插件面板/WebView 嵌入方式）。仓库内**没有** DSH-GO 代码；本机也未安装。调研任务：找到 DSH-GO 的源码/文档，回答三个问题：①它如何嵌入插件面板（WebView + 深链？截图式？）；②它如何做设置页（原生/WebView 混合）；③它如何管理连接与 token。把结论写回本文件或 PR 描述。`[待验证]`

### 13.3 Cuplivo 内部可借鉴的既有实现

| 要解决的问题 | 现成先例 | 可借鉴点 |
|---|---|---|
| 远程服务连接配置（URL/headers/oauth，JSON 持久化，UI 表单） | MCP：`lib/core/providers/mcp_provider.dart`（`McpServerConfig` 含 transport/url/headers/oauth）、`lib/features/mcp/**`、`lib/core/services/mcp/mcp_oauth_http_client_io.dart`（`CupertinoClient` 会话）、`docs/mcp-oauth.md` | 配置模型、连接状态、错误展示、OAuth 刷新模式 |
| WebView 生命周期/多 tab/下载/预览 | `lib/core/services/browser/**`、`lib/features/browser/**`、`lib/features/side_panel/widgets/side_panel_browser.dart` | 引擎封装、cookie、后台回收、嵌入式（`embedded:true`）用法 |
| 远程状态 + 断线重连 + 状态点 | LAN sync：`lib/core/services/sync/**`、`docs/adr/0003-lan-sync-architecture.md`、`lib/features/settings/pages/lan_sync_page.dart` | “连接代/探活/错误分型/状态 UI”的既有词汇与测试习惯 |
| 右侧面板 docked/overlay/expanded | `lib/features/side_panel/**`（§5） | 呈现几何、拖宽、持久化、键盘焦点 |
| 助手列表/群聊/拖拽/标签 | `lib/features/assistant/**`、`lib/core/providers/chat_owners_provider.dart` | 统一 owner 顺序、行卡片视觉、桌面 pane |
| 工作区/技能等扩展实体 | `lib/core/database/extension_entity_store.dart`、`lib/features/workspace/**`、`lib/features/skills/**` | 只有当 DSH 需要**本地**缓存时再考虑；默认不要落库 |
| 设置页 + 搜索 + 桌面 pane | `lib/features/settings/**`、`lib/desktop/**` | 复用组件与导航模式 |
| 流式渲染/节流/工具时间线 | `lib/features/home/controllers/stream_controller.dart`、`lib/features/chat/widgets/chat_message_widget.dart` | 分 notifier 更新、`ToolUIPart`/`ReasoningSegmentData` 结构、`ContentSplitData` 交错规则 |
| 模型/推理 UI | `lib/features/model/widgets/model_select_sheet.dart`、`lib/features/chat/widgets/reasoning_level_sheet.dart`、`lib/features/provider/**` | 视觉语言与交互（picker/搜索/分组/徽标），实现独立 DSH 版 |
| 权限 UI | `lib/features/chat/widgets/tool_permission_widgets.dart`、`lib/core/models/tool_permission_mode.dart` | 三档/确认/圆点语义参考 |
| e2e | `integration_test/e2e/example_acceptance_test.dart`、`docs/e2e-android.md`、`test/support/e2e_app_seed.dart` | 一个 PR 一个 e2e 文件、截图、`/e2e` 触发 |

---

## 14. 实现落点速查（seam 表）与 `ChatOwnerKind.harness` 的破坏面

### 14.1 必须命中的现有 seam（行号按当前 worktree）

| 要做的事 | 文件:行 |
|---|---|
| 「+」菜单（移动） | `lib/features/assistant/pages/assistant_settings_page.dart:120`（按钮）、`:201-219`（`_showCreateMenu`，加第三项）、`:221`/`:237`（两个 create 回调）、`:355` 一带 `_OwnerSliver`（行构建/拖拽） |
| 「+」菜单（桌面） | `lib/desktop/setting/assistants_pane.dart:298`（`_AddOwnerButton`）、`:326-342`（菜单项）、`:353`（命名对话框可复用） |
| owner 行解析/编辑分流 | `lib/features/home/widgets/side_drawer.dart:4056`（`_buildAssistantsList`）、`:4128`（铅笔 `onEditTap`）、`lib/features/home/widgets/assistant_entry_actions.dart:31-46`（`openAssistantSettings`，长按菜单 `:48`） |
| owner 排序/统一列表 | `lib/core/providers/chat_owners_provider.dart:81`（`inOwnerOrder`）、`:175`（`reorderWithin`）；`lib/core/models/chat_owner.dart:10-67`（enum/类，`harness` 已加） |
| owner 归属/当前 owner | `lib/features/home/widgets/side_drawer.dart:1586`（`_ownerOf` 目前只认 assistant/group）、`:926`、`lib/features/home/controllers/home_page_controller.dart:2023`（`openOwner`，必须在会话逻辑前加 `isHarness` 分支） |
| 新会话/切换会话 | `home_page_controller.dart:2105`（`switchConversationAnimated`）、`:2214`（`createNewConversationAnimated`）；DSH 用 `session.create`，不要复改这两个核心 |
| 首页布局/body | `lib/features/home/pages/home_page.dart:1016`（`_buildPage`）、`:1078`（mobile）、`:1212`（tablet/desktop 共用）、`:1445`（`_buildMessageListView`）、`:1667`（`_buildChatInputBar`） |
| 移动 AppBar 动作 | `lib/features/home/pages/home_mobile_layout.dart:278-314`（删 minimap `:279-285`，新会话 `:286-311` 右侧插右栏按钮，`:313` spacing） |
| 桌面 AppBar 动作 | `lib/features/home/pages/home_desktop_layout.dart:316`（`_buildAppBar`）、`:567`（`_buildActions`，右栏按钮 `:572-593`、新会话 `:599-624`）、`:176`（`DesktopSidePanel` 包裹处） |
| 抽屉会话行数据源 | `side_drawer.dart:1529`（`_sidebarRowsFor`）、`:1569`（`_computeSidebarRows`）、`:1591`（读 `ChatService.getAllConversations`，**必须改为可注入**）、`:4521`（`_buildConversationsList`）、`:4786-4807`（`_SidebarHeaderKind`/`_SidebarRow`/`_SidebarTileRow`） |
| 右侧面板几何 | `lib/features/side_panel/widgets/side_panel_geometry.dart`（已抽）、`desktop_side_panel_controller.dart:15`（enum）、`:25`（单例）、`:26-29`（宽/阈值/前缀）、`:195`（`presentationFor`）、`:203`（`maxWidthFor`）、`desktop_side_panel.dart:34`/`:516`（现容器） |
| 右栏移动端推入 | `lib/shared/widgets/interactive_drawer.dart:103`（`child` 随抽屉位移）、`:124`（`drawerWidth` 默认 `min(360, 屏宽*0.86)`）、`DrawerSide.right`（组件已支持、仓库暂无人用） |
| 聊天渲染 | `lib/features/home/widgets/message_list_view.dart:100`（类）、`:178-220`（必填参数表，见 §4.2.1）、`:442-451`（`renderModels` 可省略）、`lib/features/chat/widgets/chat_message_widget.dart:1271`（消息体）、`:4754`（`ToolUIPart`）、`lib/features/home/controllers/streaming_content_notifier.dart:57`（流式节流）、`lib/core/models/chat_message.dart:171`（构造函数：`role`+`conversationId` 必填） |
| 输入框 | `lib/features/home/widgets/chat_input_bar.dart:714`（类）、`:721-865`（参数：`leading`/`onMore`/`onSelectModel`/`onConfigureReasoning`/`loading`/`onSend`/`showToolsButton`…）、`:2260`（`_handleSend`，`rejected` 恢复草稿）、`:3528`/`:3605`（推理/工具按钮位置）；**不要**用 `chat_input_section.dart:51`（会解析本地 provider/workspace/MCP） |
| 模型/推理/权限选择器 | `lib/features/model/widgets/model_select_sheet.dart:188`/`:340`/`:1740`（本地参考）、`lib/features/chat/widgets/reasoning_level_sheet.dart:27`、`lib/features/chat/widgets/tool_permission_widgets.dart:129`；DSH 版新写（§4.4） |
| 设置框架 | `lib/features/settings/pages/settings_page.dart:198-206`（助手与群聊行）、`:225-234`（提供商行）；搜索 `settings/search/settings_search_index.dart:9-46` + `settings_search_navigation.dart:55/57`；桌面 `lib/desktop/desktop_settings_page.dart:139` |
| 共享组件 | `lib/shared/widgets/section_card.dart`、`custom_bottom_sheet.dart:15`（命名参数！）、`ios_form_text_field.dart`、`ios_switch.dart:11`、`ios_settings_rows.dart:166/256`、`ios_tactile.dart:10/227`、`action_sheet.dart:70`、`segmented_tabs.dart`、`snackbar.dart`、`effort_slider.dart`、`lib/icons/lucide_adapter.dart` |
| 持久化/注册 | `lib/core/models/chat_owner.dart`、`lib/core/providers/chat_owners_provider.dart`、`lib/core/database/business_settings_router.dart:15/40/85/113/122`、`business_preferences.dart:231`（assert）、`business_data.dart:8-14`、`app_database.dart:421`（若确实要加表才看 §1.6） |
| l10n | `lib/l10n/app_en.arb`/`app_zh.arb`、`tool/l10n/translate.py:135`（validate）/`:446`（写 `app_zh_Hans.arb`） |
| 测试守卫 | `test/core/database/business_key_registry_sync_test.dart:269`（preference key 扫描）、`test/core/services/sync/sync_family_registry_test.dart:38`（extension kind 扫描）、`test/core/database/assistant_upgrade_contract_test.dart`（历史 JSON 契约；本特性不碰 Assistant）、`test/core/database/backup_portability_test.dart`（deviceLocal 剥离） |
| e2e | `integration_test/e2e/example_acceptance_test.dart`、`integration_test/e2e/acceptance_support.dart`（`bootSeededApp`）、`test/support/e2e_app_seed.dart`、`test_driver/e2e_review.dart`、`docs/e2e-android.md` |

### 14.2 `ChatOwnerKind.harness` 决策的破坏面（比“远程 Assistant”方案更容易踩的点）

1. **所有“owner → Assistant”的隐式假设**：`side_drawer.dart:1586 _ownerOf`、`:926` 的 open/fallback 逻辑、`home_page_controller.dart:2023 openOwner`、`AssistantProvider.resolveConversationAssistant` 都假设 owner id 是 assistant id。harness 的 id 不是 assistant id，必须在这些入口**先按 kind 分支**，再碰 assistant/会话逻辑；漏一处会得到“找不到助手/空会话”。
2. **`currentAssistantId` 残留**：`HomePage` 的聊天壳从 `AssistantProvider.currentAssistantId` 派生（`home_page.dart:1100` 一带）。选择 harness owner 时必须避免“继承上一个本地助手”的模型/提示词/输入框配置；以 owner 的 `isHarness` 为唯一开关，不要读 `currentAssistant` 来渲染 harness 会话。
3. **会话归属过滤**：`_ownerOf(conversation)` 必须继续只匹配 assistant/group；harness owner 不能“认领”任何本地会话（`ownerOfConversation`/`ChatFrostedBackdrop` 不变，但要确认 harness 分支不会把 `dsh:` 会话 id 当成本地 id）。
4. **排序 key 跨设备悬空**：`chat_owner_order_v1` 是 synced，`harness:<id>` 指向的 `dsh_remotes_v1` 是 deviceLocal → 恢复/配对后 order 里存在没有对应记录的 key。`ChatOwnersProvider.inOwnerOrder` 必须像现有实现那样容忍缺失 key（按“未知项跳过/排尾”处理），否则侧栏少行或崩溃；删除 remote 时同时清掉 order 里的 `harness:<id>`。
5. **`reorderWithin`/分节**：标签分节只对 assistant 生效；harness 必须落在未分组区（`chat_owner.dart` 已声明），但 `_computeSidebarRows`/`_buildAssistantsList` 的分节代码要显式跳过 harness 的标签查找，否则按标签分组时 harness 行消失。
6. **删除语义**：本地 owner 删除走回收站；harness 删除是“删连接记录 + secure-storage cookie”，不产生回收站条目。别复用 `AssistantProvider.deleteAssistant` 的分组/回收站路径；`DshRemoteStore.remove` + `DshCredentialStore.deleteCookie` 是唯一实现（已存在）。
7. **设置页行类型**：`ChatOwnerSettingsPage` 的 `_OwnerSliver`/`_AssistantCard` 只吃 `Assistant`/`GroupChat` 数据；harness 行要用 `DshRemote` 渲染（`lib/features/harness/widgets/dsh_owner_card.dart` 已有），不要伪造 `Assistant` 实例（会再次引入模型/提示词字段和备份语义）。
8. **两处创建菜单 + 两处行渲染**：移动 `assistant_settings_page.dart` 与桌面 `assistants_pane.dart` 是两份实现（AGENTS.md「Blast radius」），第三项/远程卡片必须两处都改，否则“遥控器上有一个按钮、另一个入口没有”。
9. **走的是 `HarnessOwnerSource` 而非 `AssistantProvider`**：所有 owner 列表刷新/监听要同时监听 `DshConnectionsProvider`（连接状态、lastError 变化），否则连接成功后抽屉行不更新。
10. **不要给 harness 加 `Assistant` 的通用能力**：`AssistantEntryActions.showAssistantItemMenu` 的复制/记忆/提示词项对 harness 无意义；harness 的菜单只有“编辑（设置）/删除/重新连接”。
11. **登录态与 owner 列表解耦**：cookie 失效时 owner 记录仍在（`lastError=auth`），列表行显示“需重新连接”，**不要**因为 401 删除 owner——这与本地 assistant 的失败语义不同。

## 附录 A. 参考图对照（`docs/cuplivo-dsh/reference/`，未跟踪，勿提交）

| 文件 | 内容 | 对应实现 |
|---|---|---|
| `image-01a1f435-*.png` | 设置›助手与群聊（列表含 DSH 行） | §2/§7：`ChatOwnerSettingsPage` 加行 |
| `image-01a1f451-*.jpg` | 助手与群聊列表：默认助手/示例助手/DeepSeek Harness（副标题“远程连接的 DeepSeek H…”） | §2.3：DSH 助手行副标题、品牌头像、编辑笔 |
| `image-01a1f4ab-*.jpg` | DSH 设置页「连接设置」：标题「DeepSeek Harness」、4 个 tab（连接设置/通用设置/模型/内…）、助手名称、WebUI 访问链接（例 `127.0.0.1:3080/?token=…`）、确认按钮 | §7.2 连接设置 tab |
| `image-01a1f4bc-*.jpg` | 「模型」tab：搜索框 + `+`、DeepSeek provider 行（品牌图标、启用绿标、`>`） | §6.6 provider 列表 |
| `image-01a1f4c4-*.jpg` | 添加 provider 的字母分组列表（ant-ling/Anthropic/Azure/…/Groq） | §6.6 添加 provider 目录 |
| `image-01a1f4c7-*.jpg` | provider 详情：API 密钥、自定义设置（API 地址）、模型目录（模型 id/显示名/上下文/最大输出/输入类型/添加模型） | §6.6 provider 详情 |
| `image-01a1f467-*.jpg` | 左侧抽屉：搜索、默认助手/示例助手/DeepSeek Harness、底部用户/工具/设置 | §3：`SideDrawer` 现有结构，DSH 行 + 主题一致 |
| `image-01a1f47a-*.jpg` | 选中 DSH 后的侧栏（工作区分话题、插件/自动化任务入口） | §3/§5：DSH 会话列表 + 原生入口 |
| `image-01a1f48c-*.jpg` | 聊天页：Cuplivo 原生渲染（用户/助手头像、时间、思考折叠卡、工具步骤、Markdown）、输入框模型胶囊/工具/发送 | §4：复用 `ChatMessageWidget`/`ChatInputBar` |
| `image-01a1f490-*.jpg` | 展开右栏：聊天被推到屏幕外（不堆叠）、右栏顶部「开始」+ 面板/全屏图标、工作区文件/新建终端/浏览器/更多工具 | §5：右栏容器 + “开始”面板入口 |
| `goal-brief.md` | 目标原文（含执行准则） | 全文依据；**不要复制进仓库其它位置/PR** |

## 附录 B. 待验证问题（spike 清单，按优先级）

1. `session.follow` / `observeEvent` / assistant stream 的真实事件形状（正文/思考/工具开始-结束-结果/错误/用量/结束）；`SessionWireEvent` 的事件名与 payload。
2. `session.prompt` 的 `requestId` 是否在事件中回传（乐观消息去重）；用户消息事件 id 与 seq 的关系。
3. 权限 catalog 的 Remote 读取路径；`/permission` 命令能否由原生客户端以 prompt 文本提交；`permissions` 投影的 `currentValue` 与 catalog 的对应关系。
4. 插件设置页/右栏面板是否有可深链 URL（WebView 能否只显示插件面板）。（插件清单本身已确认可原生：`pluginInventory/list`。）
5. 会话标题在 `session.list` 的 projection hints 中是否可用（避免为每行再发 `projections`）；冷会话（未 attach）读取成本。
6. `workspace.follow` 的 baseline/frames 形状；session 与 workspace 的归属字段。
7. DSH 重启/令牌失效后的错误码（401 文本？Remote 错误？WS close code？），用于连接状态分类与重连提示。
8. iOS/macOS 上 dart:io 明文 HTTP/WS 到 LAN 的真实可用性（Android 已确认 manifest 允许）；macOS 15 本地网络隐私弹窗行为。
9. 附件/图片 prompt（`PromptContentPart` image/base64 上限 `imageLimits` 投影）与文件上传 receipt 流程（phase 2）。
10. `settings` / `credentials` 在本版本具体暴露了哪些 namespace（`settings.describe().namespaces` 实跑打印），provider 目录（`llm.listConfigurableProviders()`）实际条目与 `llm-deepseek` / `llm-pi-ai` 的 schema 字段。

## 附录 C. 决策记录（已定 / 待确认）

**已定（与 `architecture.md` 一致，不再讨论）**
1. 第三种 owner：`ChatOwnerKind.harness` + `DshRemote` 记录（`dsh_remotes_v1` deviceLocal）；**不改 `Assistant`**。
2. 凭据：v1 浏览器 cookie（`GET /?token=` 换取）放 `flutter_secure_storage`；v2 `/connect` 的 operator cookie **不用**；启动令牌只用于一次登录、不落盘。
3. 协议层 `lib/core/dsh/**` Flutter-free；feature 层 `lib/features/harness/**`。
4. 运行时复用：`MessageListView`/`ChatMessageWidget`/`ChatInputBar`（§4），DSH 数据只在内存；右栏“推入不堆叠”（§5）；官方 UI 原生，插件 UI WebView（§7/§8）。
5. 右栏移动端用 `InteractiveDrawer(side: DrawerSide.right)` 推入；桌面 ≥849 docked，全屏=expanded 推入。
6. WebView 只用于插件设置/插件面板；插件清单、自动化任务、会话/工作区/模型/权限均原生（`pluginInventory/list`、`schedule`、`session.*`、`llm`）。
7. 不改动本地 provider 体系：DSH 模型/供应商不写 `SettingsProvider`/`provider_rows`（§6）。

**仍需产品/实现确认（不阻塞 P1/P2）**
1. 插件设置页/右栏面板的可深链能力（若 DSH 无独立 URL，WebView 只能打开整个 Web UI；§8.4）。
2. `/permission` 命令能否由原生端以 prompt 文本提交（不能则当前会话权限只读，默认权限仍可写；§4.4）。
3. `schedule`/`pluginInventory` 的 UI 首版深度：入口行 + 列表，还是完整编辑页。
4. 移动端右栏宽度/手势细节是否与 DSH Web 完全一致（e2e 截图对照后再定）。
5. `dsh_remotes_v1` 是否需要在“导出/恢复”时给用户一个可选提示（当前按 deviceLocal 静默丢弃）。
