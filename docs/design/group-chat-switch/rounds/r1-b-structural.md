# 方案 B｜结构性：把「归属」和「开一个谁的新会话」各收成一处

> 本轮唯一的区别就是**范围**。B 覆盖 A 的全部结果，另外把 F4/F5 和 I1–I6 一起变成可验收的。

## 用户会看到什么

| 今天的现象 | 结构性之后 |
| --- | --- |
| F1 群话题 → 点助手（开关开）→ 仍停在群里，该助手的历史消失 | 变成该助手的 1:1，侧栏列出该助手的会话 |
| F3 同上但助手无历史 | 变成该助手的新 1:1 |
| F2 开关关着 → 正常 | 不变（逐格相同，硬要求） |
| F4 助手列表 → 点群卡片 → 侧栏仍停在 owner 列表 | 侧栏跟着切到该群的话题 |
| F5 话题位置设为「右侧」→ 点助手、点群都不切视图 | 「自动切换话题」开着时，右侧面板打开话题页；关着时不动 |

## 实际要落的东西

一次 owner 点击 = **一个意图**，在 controller 里顺序做完三件事，drawer 里两种 tap 只剩调用它：

```
ownerTapped(ChatOwner owner)          // assistant 或 group，一种参数
  ├─ 1 归属：assistant → 持久化选中；group → 不持久化（群不是设备级选择）
  ├─ 2 会话：assistant → 新会话或最近 1:1（都由 intent 决定，绝不继承当前群）
  │          group     → 该群最近话题，没有就新建话题
  └─ 3 reveal：按布局与设置，把话题视图显出来
             左布局 = 侧栏 tab；右布局 = 右侧面板 topics 页；移动端 = 不动
```

三件事今天分散在 `_handleSelectAssistant`、`_handleSelectGroup`/`_openGroup`，以及热键路径
`_setupDesktopFeatures` 里的 reveal 判断里。B 把它们合成一处，**第三步不是新写的**：
右侧布局的 reveal 在热键路径上已有实现（`DesktopSidePanelController.instance.open(kind: topics)`），
现在只是让 owner 点击也走它。

两个现成的地基可以少发明东西：`lib/core/models/chat_owner.dart` 已经是
`ChatOwner.assistant(id)` / `ChatOwner.group(id)` 的稳定身份；侧栏的 owner 列表也已经用它排序。

## 本方案顺带给出的答案

- **I1 单一归属**：「这个会话属于谁」只有一个函数回答，群行已删时回答「普通会话」。
  今天侧栏列表用 `groupChatId` 参数 + 当前助手两个来源算口径，收成一个。
- **I2 选择 ≠ 归属**：`setCurrentAssistant` 仍然只是视图状态；它不再顺带决定新会话归属。
- **I5 设置只在其能生效的地方生效**：「自动切换话题」在两种桌面布局里都真的生效，
  移动端不出现（或按第 3 轮的决定处理）。
- **I6 一套实现**：旧的 `onNewConversation(assistantId:)` 参数链不保留，
  被替换的入口删掉。

## 代价

- 改动面覆盖抽屉、两种布局、页面与控制器，外加 reveal 的两种布局分支。
- 现有 `side_drawer_conversation_list_test` / `side_drawer_owner_sections_test` /
  `side_drawer_selection_test` 与布局测试需要重排；新增的是**表驱动**的一组入口等价测试。
- 下一次 rebase 的冲突面**一次**变大（这次多一个 unit 要和上游的 sidebar/layout 改动重放），
  换来之后每个新入口不需要再补步骤。
- 风险集中在 reveal：它要同时碰侧栏 tab 与右侧面板，是本轮唯一会碰到桌面布局状态的改动。
  用「开关关闭时行为与今天逐格相同」这条横切验收把它钉住。

## 适合

认为「新增入口不必记得补步骤」本身就是要买的东西，而不只是这次事故的补丁。
选 B 之后，按仓库的非平凡系统规则，下一个轮次是**伪代码轮**（数据流、不变量、失败模式），
不是直接开工。
