# 助手 ↔ 群聊切换：实现计划

> 输入：目标书 `refactor-plan.md`（要什么）。本文件是**怎么改**——六轮 clarity round 的结论
> 与逐文件的落地顺序。决策记录：`rounds/decisions.md`。
>
> 分支 `refactor/group-chat-switch`，基线 `c27805784`（`4.7.0+10` 之后）。

## 0. 六轮定下的事

| 轮 | 决定 | 结论 |
| --- | --- | --- |
| 1 | 范围 | **结构性（B）**，不是把 #1069 重放回来 |
| 2 | 管道落点 | `HomePageController.openOwner`，不拆 service |
| 2b | 选中 vs 落盘 | 选中由当前会话派生、不落盘；落盘的只是「默认助手」；群不写 |
| 3 | 「自动切换话题」 | 保留，左/右两种桌面布局都真的生效 |
| 4 | 开关开的语义 | 一律新建（矩阵 A 行 = 新），不改今天的行为 |
| 5 | 门禁 | 按层拆 T1–T4 四张表 + 5 条守卫注入 |
| 6 | rebase 记录 | 本轮登记为 unit，并注明取代 #1069 的三段 |

**不动的**：群的产品语义、schema、备份与 LAN sync 载荷、侧栏视觉、ARB（本轮没有新增文案，
所以不跑 `gen-l10n`）。

## 1. 最终形状

```
点 owner（抽屉 / 头像 / 热键）
   └─ HomePageController.openOwner(ChatOwner owner)
        1 flush 当前会话进度
        2 解析或创建：group → 最近话题 / 新话题；assistant → 新 1:1 或最近 1:1（按开关）
        3 提交切换（沿用 switchConversationAnimated 的 prepare/commit 与 _switchSerial）
        4 syncDefaultAssistant(已提交会话)：归属是助手才写，幂等
        5 revealTopics()：按布局与设置，把会话列表显出来
```

三个唯一落点，其余全是调用者：

| 落点 | 回答什么 | 谁在用 |
| --- | --- | --- |
| `ownerOfConversation(...)`（纯函数） | 这个会话属于谁 | 列表口径（I4）、owner 列表高亮、默认助手同步、群背景 |
| `openOwner(ChatOwner)` | 点了一个 owner，打开什么 | 抽屉的助手与群两种 tap |
| `revealTopics()` | 把话题列表显出来 | owner 点击、头像点击、热键 |

## 2. 逐文件改动

### 2.1 `lib/core/models/chat_owner.dart`（新增一个纯函数）

```dart
ChatOwner? ownerOfConversation(
  Conversation? conversation, {
  required bool Function(String groupId) isLiveGroup,
  required String? Function(String? assistantId) resolveAssistantId,
}) {
  if (conversation == null) return null;
  final groupId = conversation.groupChatId;
  if (groupId != null && isLiveGroup(groupId)) return ChatOwner.group(groupId);
  final assistantId = resolveAssistantId(conversation.assistantId);
  return assistantId == null ? null : ChatOwner.assistant(assistantId);
}
```

谓词用注入而不是直接读 Provider：控制器里有 `_groupChatExists`（reduced host 返回 null 的那套
保护）可以复用，测试里也不必造 Provider。**群已删 → 落到助手那半**，这就是 E 行的「按普通会话
处理」。

### 2.2 `lib/features/home/controllers/home_page_controller.dart`

- 新增 `Future<void> openOwner(ChatOwner owner)`：第 1 节那五步。`_switchSerial` 用于「最后一下
  点击赢」，创建复用 `reuseNewEntry: true`（连点不会堆空会话）。
- 新增 `void revealTopics()`：从 `home_desktop_layout._revealAssistantTopics` 提上来，
  两种布局一个判断：右布局 `DesktopSidePanelController.instance.open(kind: topics)`；
  左布局先 `toggleTabletSidebar()` 再 `DesktopSidebarTabBus.instance.switchToTopics()`；
  `desktopAutoSwitchTopics` 只在这里读一次。
- 新增 `void syncDefaultAssistant(Conversation? session)`：
  `ownerOfConversation(...)` 是助手才 `setCurrentAssistant`（幂等）。`currentAssistantId` 的 doc
  注释补一句「这是**默认助手**（新 1:1 与未绑定会话的 fallback），不是选中；选中由会话归属派生」。
- `createNewConversationAnimated` 保持现状：「继承当前群」只服务匿名「＋」，**不**长出
  `assistantId` 参数。
- `initChat`：`Future.wait` 里加 `groups.loaded`（与 #1069 同一处，避免第一帧按旧助手画背景）；
  Provider 缺失时必须仍可用（reduced host），照 `_groupChatExists` 的写法 try/catch。

### 2.3 `lib/features/home/widgets/side_drawer.dart`

- 新回调 `onOpenOwner(ChatOwner owner)`（替代 owner 点击路径上的 `onNewConversation`）。
  `onNewConversation` 保留给「＋」等匿名入口。
- `_handleSelectAssistant` 缩成：按 `keepSidebarOpenOnAssistantTap` 决定是否关抽屉 →
  `await widget.onOpenOwner(ChatOwner.assistant(a.id))` → 关闭。
  删除：`ap.setCurrentAssistant`、`forceNewChat` 分支、内联 `_tabController.animateTo(1)`、
  自己扫 `getAllConversations()` 找最近会话的三段逻辑。
- `_handleSelectGroup` / `_openGroup` 缩成一次 `onOpenOwner(ChatOwner.group(g.id))`。
  删除：自己 `read<ChatService>`、自己 `createDraftConversation`。
- **列表口径（I4）**：`_sidebarRowsFor` / `_computeSidebarRows` 的两个参数
  （`assistantId` + `groupChatId`）换成一个 `ChatOwner? scope = ownerOfConversation(当前会话)`。
  记忆化的键相应换成 scope 的 `key` + 群列表版本。选择模式里 `_selectionAssistantId` 改名为
  `_selectionOwnerKey`（同一文件内的局部改名：名字不能继续说谎），比较对象同步换掉。
- **高亮（I2）**：owner 列表两种 tile 共用同一个 `selectedOwner`，
  删掉 `currentAssistantId == a.id && currentGroupId == null` 这条式子。

### 2.4 `lib/features/home/pages/home_desktop_layout.dart`

- 删 `_revealAssistantTopics`，改为 `onRevealTopics` 回调（`home_page.dart` 接到
  `_controller.revealTopics`）。头像点击入口不变。
- `useDesktopTabs` / `desktopAssistantsOnly` 的布局判断不动。

### 2.5 `lib/features/home/pages/home_mobile_layout.dart` / `home_page.dart`

- 透传 `onOpenOwner` / `onRevealTopics`。移动端不出现 reveal（抽屉里没有 tab）。

### 2.6 同一次事故的第四处消费者：群话题背景

`lib/features/chat/widgets/frosted/chat_frosted_backdrop.dart` 的 `ChatBackdropSpec.resolve`：
群话题（`ownerOfConversation` 的 group 分支）不画助手的壁纸与渐变。
`chat_assistant_background.dart` 的 overlay 副本改成读同一个 spec。

这是 #1069 一起丢的那段，也是 `ownerOfConversation` 的第四个消费者——不改它就是同一处事故
留一条尾巴。

## 3. 删除清单（I6）

| 位置 | 删什么 |
| --- | --- |
| `side_drawer.dart` | `forceNewChat` 分支、`ap.setCurrentAssistant` 调用、内联 tab 切换、`_openGroup` 的会话解析、`_handleSelectGroup` 的包装 |
| `home_desktop_layout.dart` | `_revealAssistantTopics`（逻辑上提到 controller） |
| 回调形状 | 不引入 `onNewConversation({closeDrawer, assistantId})`——那是 A 方案的参数链 |
| 旧 #1069 测试 | 5 个文件不逐字恢复（断言的是旧形状、没有 reveal 一列），由 T1/T3/T4 覆盖 |

## 4. 落地顺序（每步独立可跑、可回退）

| 步 | 做什么 | 完成判据 |
| --- | --- | --- |
| 0 | `ownerOfConversation` + T2 | 纯函数测试绿；`dart analyze` 干净 |
| 1 | controller：`openOwner` / `revealTopics` / `syncDefaultAssistant` | T1 的 12 格绿 |
| 2 | 抽屉改接 `onOpenOwner`，口径与高亮换成 scope，删旧路径 | 现有 3 个 `side_drawer_*` 测试按新口径绿 |
| 3 | 布局透传 reveal，`home_page` 接线 | T3 的 6 格绿 |
| 4 | T4 三条 smoke（三布局各一条） | 绿 |
| 5 | 群背景消费者（2.6） | 背景 spec 的既有测试绿 + 新增一格 |
| 6 | 守卫注入 5 条，逐条还原并记哈希 | 注入红、还原后哈希相等 |
| 7 | 文档四处 + 回填 unit 的 sha | 见 §6 |

顺序就是「先长出最小的能跑的东西」：先纯函数，再管道，再接线，最后背景与记录。

## 5. 验收

### 5.1 T1｜controller：矩阵 6 行 × 开关两态

| 行 | 开关 | 打开的会话 |
| --- | --- | --- |
| A 群话题 → 助手 A（有历史） | 开 | A 的**新** 1:1（≠ A 最近会话） |
| A′ 同上 | 关 | A **最近**的 1:1 |
| B 群话题 → 助手 A（有历史） | 关 | A 最近的 1:1 |
| B′ 同上 | 开 | A 的新 1:1 |
| C 群话题 → 助手 A（无历史） | 开/关 | A 的新 1:1 |
| D 助手会话 → 群 G（有话题） | 开 | G 的新话题；关 | G 的最近话题 |
| D′ 助手会话 → 群 G（无话题） | 开/关 | G 的新话题（`groupChatId == G`） |
| E 当前群已删 → 助手 A | 开 | A 的新 1:1；新会话不带死群 id |
| E′ 当前群已删 → 死群 G | — | 不切、不建 |
| F 1:1 X → 1:1 A | 开 | A 的新 1:1 |
| F′ 同上 | 关 | A 的最近 1:1 |

### 5.2 T2｜纯函数：4 格

群存活 → group；群已删 + 有助手 → assistant；群已删 + 无助手可解析 → null；
无群 + 无助手 → null。

### 5.3 T3｜reveal：6 格（第 2 轮 2.3 那张表）

左布局（开/开·侧栏收起/关）、右布局（开·面板关/开·面板开在文件页/关）。
断言：tab 索引 / 面板 `activeTab.kind == topics` / 抽屉关闭。

### 5.4 T4｜三条 smoke

每布局一条：点群 → 会话、列表口径、视图三件事同时成立；点助手同样；无历史助手 → 新会话。

### 5.5 守卫注入（每条留注入前/还原后的哈希）

| 注入 | 应红 | 不变量 |
| --- | --- | --- |
| 管道改回「先改选中、让新建去读它」 | T1 的 A/A′ | I3 |
| reveal 删掉 `topicsOnRight` 分支 | T3 右布局两格 | I5 |
| 列表口径改回两个来源 | T2 + T4 | I4 |
| 高亮改回 `currentAssistantId` | 2b 守卫测试 | I2 |
| 群背景不判断群话题 | 背景那格 | I1 |

两条**永久守卫**（不是一次性注入）：「＋」仍是群的新话题、`openOwner(助手)` 一定不是群的新话题；
群话题打开时 `currentAssistantId` 不变而高亮落在群上。

### 5.6 真机点验

三列布局 × 开关两态，逐格过 §5.1 的三列（会话 / 列表 / 视图）。右布局那两格要确认观感：
面板以 docked 还是 overlay 出现（阈值 849），以及聊天区变窄是否可接受。

## 6. 文档收尾

1. `CHANGELOG.md` + `CHANGELOG_CN.md`：下一版 `Fixed` 新增一条（用户语言：群话题点助手会离开群、
   点群卡片侧栏跟着切、话题在右也生效），引用 #1092，并写明这是**取代** #1069 的另一种修法。
   4.6.0 的 #1069 条目补一句「该修复未在 4.7.0 生效，见 #1092」。
2. `CONTEXT.md`：§Release & upstream policy 里「group chat 是未随行的 3.x 功能」改为 4.6.0 起已回来。
3. `docs/rebase-v1.3.6.md:140`：group-chat unit 行补 `#1069`；新增一行本轮 unit
   （成员写「#1092，取代 #1069 的 side_drawer / home_page_controller / 群背景三段」，sha 回填）。
4. `docs/rebase-runbook.md:818`：family 表 group-chat 一行 →
   `#1052 topics, #1092 owner switch（取代 #1069 group exit）, #1072 phone composer`。

## 7. 风险

| 风险 | 处置 |
| --- | --- |
| 右布局 reveal 会占宽度、布局跳一下 | 设置开着才发生，且可关；真机点验那一格（§5.6） |
| 抽屉列表记忆化的键改了，可能读到旧行 | 记忆化键换成 scope `key` + 群列表版本；T4 覆盖 |
| `ownerOfConversation` 需要群存活的谓词，reduced host 没有 GroupChatProvider | 谓词注入 + 沿用 `_groupChatExists` 的 null（未知）语义 |
| 进程级单例（tab 总线、右侧面板）在测试间泄漏 | T3/T4 一律 `addTearDown` 重置 tab 索引与面板状态 |
| 本轮与 #1069 的文件重叠，下次 rebase 冲突 | §6 的 unit 登记写明取代关系，冲突只有唯一解 |

## 8. 完成定义（对应目标书 §8）

- §5.1–5.4 全绿；`dart analyze --fatal-infos lib test integration_test` 干净。
- 5 条守卫注入都有记录（注入红、还原哈希相等）。
- 真机三列 × 开关两态点验通过（§5.6）。
- §6 四处文档对齐，unit 表的 sha 已回填，CHANGELOG 与实际落地一致。
- 没有留下兼容层：§3 的删除清单全部执行。

---

## 9. 落地状态（2026-11-16）

已实现；第一次真机点验后加了两处（见决策记录「追加轮」）：开关对两种 owner 都生效，
reveal 改成 post-frame 回调（修掉切到群时 tab 先闪上一个助手列表）。

| 项 | 状态 |
| --- | --- |
| `ownerOfConversation` / `ownerOfChat`（纯函数） | ✅ `lib/core/models/chat_owner.dart` |
| `HomePageController.openOwner` / `revealTopics` / 默认助手同步 | ✅（开关对助手与群一致生效） |
| 抽屉：一个 `onOpenOwner`、列表口径与高亮的派生 | ✅ 勾选、选择模式随之换成 owner key |
| 两种布局：`onOpenOwner` + `onRevealTopics` 接线 | ✅ |
| 群话题背景（第四个消费者） | ✅ |
| `createNewConversationAnimated(owner:)` 取代 `groupChatId:` | ✅（全仓无调用点用过 `groupChatId`） |
| 删除 `lib/desktop/desktop_sidebar.dart`（无 import 的旁路入口） | ✅ |
| T1/T2/T3/T4 门禁 + 两条永久守卫 | ✅（含「开关给群一个新话题」「点一下在下一帧揭示」两格） |
| 5 条守卫注入 | ✅ 记录见 `rounds/guard-injections.md` |
| `dart analyze --fatal-infos lib test integration_test` | ✅ No issues found |
| `flutter test test/features/ test/desktop/ test/core/` | ✅ 11952 passed, 86 skipped（追加轮之前） |
| Windows 调试构建 | ✅ `build\windows\x64\runner\Debug\cuplivo.exe`（追加轮后重新构建） |
| 真机三列 × 开关两态点验（§5.6） | ⏳ 第二次闸门 |
| §6 文档：CONTEXT / 两份 CHANGELOG 的 4.6.0 注记 / 两份 rebase 文档 | ✅（新版本的 Fixed 条目在版本号提交时写入，见决策 6） |

### 与计划的偏差

1. `ownerOfChat`（按字段）是新增的纯函数：provider 的 `Selector` 在父级重建时失效重算，
   把整个 `Conversation` 放进 select 会让每次切换都重建列表。
2. 「新建会话」的参数从 `String? groupChatId` 换成 `ChatOwner? owner`。
3. `side_drawer_conversation_list_test` 的 orphan 用例改为从「没有打开任何会话」出发——
   那是选中助手决定列表口径的唯一场合。

