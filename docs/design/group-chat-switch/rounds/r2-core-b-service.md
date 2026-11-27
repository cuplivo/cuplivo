# 第 2 轮·另一种落点：管道放进独立文件，controller 只做转发

> 同样的数据流、同样的状态表、同样的失败模式。差别**只在代码住哪**——
> 而这正是本仓库最贵的一个变量：`home_page_controller.dart` 是 4500 行的 rebase 冲突区。

## 1. 数据流（形状与 A 相同）

```
drawer / header / hotkey
        ▼
OwnerOpener.open(ChatOwner owner)          // lib/features/home/services/owner_opener.dart
        ├─ 1 flush        ─┐ 由 controller 注入
        ├─ 2 解析/新建会话  │ 由 controller 注入（含 _switchSerial 语义）
        ├─ 3 提交切换      ─┘
        ├─ 4 persistSelectionForOwner(owner)   // 纯：读会话归属 → setCurrentAssistant，幂等
        └─ 5 revealTopics()                     // 纯：总线 / 右侧面板，两种布局
```

接线：

```dart
// home_page_controller.dart——只多一个 getter + 一段构造，不搬逻辑进来
late final OwnerOpener ownerOpener = OwnerOpener(
  flush: _flushProgressSilently,
  resolve: _resolveOwnerConversation,      // 复用现成的创建/切换原语
  commit: (conversation) => switchConversationAnimated(conversation.id),
  selection: _context.read<AssistantProvider>(),
  reveal: TopicsReveal(
    settings: _context.read<SettingsProvider>(),
    sidebar: () => tabletSidebarOpen,
    openSidebar: toggleTabletSidebar,
  ),
);
```

## 2. 三个规则仍然各是一处

- **归属**：`ownerOfConversation(...)` 纯函数，和 A 完全一样（放 `core/models/`）。
- **会话解析**：`OwnerOpener.resolve` 一处；群已删 → 返回 null，绝不写死群 id。
- **reveal**：`TopicsReveal.topics()` 一处；右布局开面板到话题页，左布局开侧栏 + 总线切 tab，
  移动端不动。

状态表（与 A 逐格相同，仅列判定列）：

| 布局 | 设置 | 现状 | 结果 |
| --- | --- | --- | --- |
| 桌面·左 | 开 | 侧栏展开 / 收起 | 切 tab / 先开侧栏再切 |
| 桌面·左 | 关 | — | 不动 |
| 桌面·右 | 开 | 面板关 / 开在文件页 | 打开面板到话题页 / 切到话题页 |
| 桌面·右 | 关 | — | 不动 |
| 移动 | 不适用 | 抽屉打开 | 关抽屉 |

失败模式（与 A 相同）：死群不建、死助手不切、连点复用同一草稿、新建失败不 reveal 不持久化、
流式沿用一次 flush、reveal 在提交之后、群内「＋」走匿名路径。

## 3. 代价

- **好处**：`home_page_controller.dart` 的 diff 只有接线（约 20 行），
  rebase 冲突面主要落在新文件与 `side_drawer.dart`。
- **坏处**：一条规则被切成两半。`flush`、`switch`、`serial` 仍是 controller 的语义，
  service 要靠 5 个回调把控制权要回来；读代码的人要在两个文件之间来回跳。
  按「blast radius」的要求，这条规则的**状态表**也就横跨两个文件，注入验证要两边都跑。
- **测试**：service 的单测很便宜（不需要 widget 树），但「点击 → 真实切换」的端到端
  仍然要在 widget 层验一遍，等于两套。
- **与 AGENTS.md「最简实现」的冲突**：为一个纯函数 + 一段总线调用引入一层对象，
  下一次 rebase 之后是否还有人知道这层的存在，是个真实的成本。

## 4. 适合

只接受把改动关在新文件与抽屉里、完全不动 controller 的那一半风险偏好。
如果同意「管道本就属于页面控制器的一部分」，选 A。
