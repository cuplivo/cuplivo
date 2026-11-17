# 方案 A｜窄修：把 4.6.0 的 #1069 还回来

> 本轮唯一的区别就是**范围**。两个方案解决的是同一批症状里的不同子集，
> 不变量 I1–I6 的验收强度不同。

## 用户会看到什么

| 今天的现象 | 窄修之后 |
| --- | --- |
| F1 群话题 → 点助手（开关开）→ 仍停在群里，该助手的历史消失 | 变成该助手的 1:1，侧栏列出该助手的会话 |
| F3 同上但助手无历史 → 同样卡在群里 | 变成该助手的新 1:1 |
| F2 开关关着 → 正常 | 不变（逐格相同） |
| F4 助手列表 → 点群卡片 → 聊天区切了、侧栏仍停在 owner 列表 | **仍然是坏的** |
| F5 话题位置设为「右侧」→ 点助手、点群都不切视图 | **仍然是坏的** |

## 实际要落的东西

`a984426fa`（4.6.0 的 #1069）在仓库里还找得到，diff 是 15 个文件：

- **8 个 lib 文件**：`side_drawer.dart`、`desktop_sidebar.dart`、`home_desktop_layout.dart`、
  `home_mobile_layout.dart`、`home_page.dart`、`home_page_controller.dart`，外加同一次提交里
  顺手修的群话题背景（`chat_assistant_background.dart`、`chat_frosted_backdrop.dart`）。
- **6 个测试文件**：其中 5 个是新的，包括 `group_chat_switch_assistant_test.dart` 与
  `home_desktop_assistant_switch_test.dart`。

修法的形状就一句话：把 `assistantId` 作为一个参数，从抽屉的回调一路传到
`createNewConversationAnimated(assistantId:)`，并在「具名 owner」时不再继承当前会话的群。

一侧**已经**验证过：当前树里 `createNewConversationAnimated` 没有 `assistantId` 参数，
`ChatBackdropSpec.resolve` 也没有群话题判断——整段确实没重放进 4.7.0。

## 代价

- **参数链就是脆的地方。** 同一个意图要经过 8 个文件的签名才能到 controller；漏一个文件就是
  编译错误（好事），但下一次 rebase 少重放一个 unit 就是今天这个事故（已经发生过一次）。
- **F4/F5 不在这个 diff 里**，它们是另一个缺口：右侧布局下「切到话题视图」根本没有实现
  （热键路径有，点 owner 路径没有）。要做只能再开一次范围类似的改动。
- **I3 不成立**：新增一类 owner 或新增一个步骤，仍然要逐个入口补。
- **I5 不成立**：「自动切换话题」在右侧布局里仍然显示着、永远不生效。
- 工作量小：一个 unit 的重放 + 适配新基线，不需要重排现有测试。

## 适合

只想让 4.7.0 的用户不再看到 F1/F3，把结构性问题排到 4.8。做完这次，事故的**成因**
（三个决定各自为政）原样留在代码里。

## 不做

不碰 reveal（tab bus / 右侧面板）、不动侧栏列表口径、不改设置项、不重排现有布局测试。
