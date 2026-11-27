# 第 2 轮·核心伪代码（落点：`HomePageController.openOwner`）

> 这是**形状**，不是实现。三个规则各有一个唯一落点，其余全是调用者。
> 本轮要你确认的是：这条管道与它的失败模式，是否就是要买的东西。

## 1. 数据流

```
drawer / header / hotkey
        │  一个参数：ChatOwner（assistant id 或 group id），没有第三种形状
        ▼
HomePageController.openOwner(ChatOwner owner)
        │
        ├─ serial = ++_switchSerial         // 最后一下点击赢
        ├─ await flushCurrentConversation() // 与今天的切换前 flush 同一处
        │
        ├─ 2  resolveOwnerConversation(owner) → Conversation?
        │        group：该群最近话题，否则新建话题（reuseNewEntry）
        │        assistant：按 intent（见第 4 轮），否则新建 1:1
        │
        ├─ 3  switchConversationAnimated / commit 新草稿
        ├─ 4  persistSelectionForOwner(owner)   // 只对 assistant 生效，幂等
        └─ 5  revealOwnerTopics(owner)          // 只读视图，不建、不切会话
```

第 1、2 步今天分散在 `_handleSelectAssistant` / `_openGroup` / `createNewConversationAnimated`；
第 4 步今天是抽屉里的 `ap.setCurrentAssistant`（点击时）＋ `_assistantSwitchFor`（切换时）**两处**；
第 5 步今天是抽屉内联的 `_tabController.animateTo(1)` ＋ 头像是 `_revealAssistantTopics` **两处**。

## 2. 三个唯一落点

### 2.1 归属（I1）— 一个函数回答「这个会话属于谁」

```dart
// lib/core/models/chat_owner.dart 旁边，纯函数，不碰 Provider
ChatOwner? ownerOfConversation({
  required Conversation conversation,
  required bool Function(String groupId) isLiveGroup,
  required String? Function(String? assistantId) resolveAssistantId,
}) {
  final groupId = conversation.groupChatId;
  if (groupId != null && isLiveGroup(groupId)) return ChatOwner.group(groupId);
  final owner = resolveAssistantId(conversation.assistantId);
  return owner == null ? null : ChatOwner.assistant(owner);   // 群已删 → 普通会话
}
```

**这是侧栏列表口径的唯一来源（I4）。** 今天的 `_computeSidebarRows` 用
「`groupChatId` 参数 + 当前助手的 `resolveConversationAssistant`」两个来源算同一件事，
改成：取当前会话 → `ownerOfConversation(...)` → 用它过滤。

### 2.2 会话解析（目标书的 §4 矩阵）

| 点的是什么 | 打开什么 | 备注 |
| --- | --- | --- |
| 助手 A | A 的 1:1（最近 / 新建由第 4 轮定） | **绝不继承当前会话的群** |
| 群 G（有话题） | G 的最近话题 | 沿用 `getAllConversations()` 已按 updatedAt 降序 |
| 群 G（无话题） | G 的新话题 | `reuseNewEntry: true`（连点复用同一草稿） |
| 群 G（已删） | 什么都不开 | 见失败模式 1 |

新建一律**显式**指定 owner（`assistantId:` 或 `groupChatId:`）。
`createNewConversationAnimated` 的「继承当前群」只保留给「＋」按钮，per I6 不留两条同义规则。

### 2.3 reveal（I5 的载体）— 一个函数，两种布局

```dart
void revealTopics() {                    // 幂等；不改会话、不建东西、不抛
  if (topicsOnRight) {                   // 右布局：已有实现，热键路径正在用
    DesktopSidePanelController.instance.open(kind: SidePanelTabKind.topics);
    return;
  }
  if (!tabletSidebarOpen) openSidebar(); // 左布局：侧栏收起时先开
  DesktopSidebarTabBus.instance.switchToTopics();   // 抽屉自己在监听
}
```

已有 `home_desktop_layout._revealAssistantTopics` 就是这段逻辑（头像是它的调用者）。
本轮只是把它提成一个落点，让**头像、热键、owner 点击**三个调用者共用。

改成总线之后，抽屉里那句内联的 `_tabController.animateTo(1)` 删除——它已经是同一个动作的
第二份实现，而且只有 `useDesktopTabs` 成立时才跑（这正是 F5）。

## 3. reveal 的状态表

| 布局 | 「自动切换话题」 | 侧栏 / 面板当前状态 | 点 owner 之后 |
| --- | --- | --- | --- |
| 桌面·话题在左 | 开 | 侧栏展开 | tab 切到「话题」 |
| 桌面·话题在左 | 开 | 侧栏收起 | 先展开侧栏，再切 tab |
| 桌面·话题在左 | 关 | 任意 | **不动** |
| 桌面·话题在右 | 开 | 面板关着 | 打开面板并停在「话题」页 |
| 桌面·话题在右 | 开 | 面板开着、停在文件页 | 切到「话题」页，面板不关 |
| 桌面·话题在右 | 关 | 任意 | **不动** |
| 移动 | 不适用 | 抽屉打开 | 关抽屉，不切任何 tab |

「关」这一列是**逐格与今天相同**的那条硬要求：左布局今天就是不动；右布局今天也不动
（坏在它不是「按设置不动」，而是永远不动）。第 3 轮定这个设置在右布局里是显示还是隐藏。

## 4. 失败模式

| # | 情况 | 行为 |
| --- | --- | --- |
| 1 | 目标群在点击的瞬间已删 | 不新建（绝不写入死群 id）、不切会话；owner 列表下一次重建时该行消失 |
| 2 | 目标助手已删 | 不切、不建；列表重算 |
| 3 | 连点 / 与既有切换竞态 | `_switchSerial` 后者胜；新建复用同一草稿，不会出现两个空话题 |
| 4 | 新建失败（DB 异常、provider 已卸载） | 返回 null：不 reveal、不持久化选择；错误走既有 `onError` |
| 5 | 当前会话正在流式输出 | 沿用现有 flush（`flushConversationProgress`），在管道入口做一次，不做两次 |
| 6 | reveal 早于列表重建 | 不可能：列表口径由「当前会话」派生，第 3 步提交后即正确；reveal 排在第 5 步 |
| 7 | 群话题里按「＋」 | 走既有匿名路径（新话题），不经管道——两者的意图不同，代码也是两条 |

## 5. 不变量 → 落点

| 不变量 | 唯一落点 | 今天的状态 |
| --- | --- | --- |
| I1 单一归属 | `ownerOfConversation` | 侧栏一套、渲染另一套、背景第三套 |
| I2 选择 ≠ 归属 | `persistSelectionForOwner`（提交后、由会话归属派生） | 点击时先持久化，与会话归属平行 |
| I3 一次点击一个意图 | `openOwner(ChatOwner)` | 助手一条路、群另一条路 |
| I4 列表跟随归属 | `openOwner` 提交后由 `ownerOfConversation` 过滤 | 两个过滤来源 |
| I5 设置只在能生效处生效 | `revealTopics` + 第 3 轮的设置归置 | 只有左布局的部分分支 |
| I6 一套实现 | 第 6 节删除清单 | 每个动作两份 |

## 6. 删除清单（I6，不留兼容层）

- 抽屉：`_handleSelectAssistant` 的 `forceNewChat` 分支、`ap.setCurrentAssistant` 调用、
  内联 `_tabController.animateTo(1)`、`_openGroup`（自己读 `ChatService`、自己建草稿）、
  `_handleSelectGroup`。
- 布局：`_revealAssistantTopics` 改调统一 reveal（头像入口保留）。
- 控制器：`createNewConversationAnimated` 保持匿名「＋」语义，不再长出 `assistantId` 参数链。
- 回调形状：`onNewConversation({closeDrawer, assistantId})` **不引入**（这是 A 方案要加的东西）。
  owner 点击改走一个回调：`onOpenOwner(ChatOwner owner, {bool closeDrawer})`。

## 7. 本轮要确认的只有一件事

**这条管道是不是要买的东西。** 若确认，第 3 轮定设置归置（I5），第 4 轮定「开关开」的语义，
第 5 轮定门禁形状，然后才写实现计划。
