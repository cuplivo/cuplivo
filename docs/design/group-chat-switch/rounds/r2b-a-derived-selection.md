# 第 2 轮·修正版 A｜选中是派生的，落盘的只是「默认助手」（不改名）

> 修正的是第 2 轮 A 变体的第 4 步。你指出的不统一是真的：今天「哪个 owner 被选中」有两种来源
> ——群这一半读当前会话，助手那一半读持久化字段。管道不该把这件事做第二遍。

## 1. 先把两件事分开

| 概念 | 是什么 | 从哪来 | 存哪 |
| --- | --- | --- | --- |
| **选中**（owner 列表高亮哪一行） | 视图状态 | `ownerOf(当前会话)`，两种 kind 同一句 | 不存 |
| **默认助手** | 新开一个 1:1 时它归谁 | 最后一次**打开过的 1:1** | `current_assistant_id_v1` |

今天 `currentAssistantId` 被当成两者用，而它的每一个读点其实都在问第二件事：
`resolveConversationAssistant(null)`、未绑定会话的 `ensureConversationId`、临时会话、
新会话的 fallback、模型解析。**一个群不能当其中任何一件的 fallback**——所以群不写这一格，
不是因为群不重要，而是因为这个字段的语义是「下一个 1:1 用谁」。

## 2. 修正后的管道第 4 步

```dart
// 提交之后、reveal 之前；由已提交会话的归属派生，不来自点击
void syncDefaultAssistant(Conversation? session) {
  final owner = ownerOfConversation(session, ...);   // 与 I1 同一个函数
  if (owner?.kind != ChatOwnerKind.assistant) return; // 群 / 空会话：不写
  assistantProvider.setCurrentAssistant(owner!.id);   // 幂等：相同则早返回
}
```

第 3 步（会话解析）内部仍然**显式**把 owner 传给创建原语，绝不靠「先把选中改掉」去间接生效——
这正是今天 F1 的成因（点助手先把选中改了，再让新建去读这个选中，结果读到了当前群）。

## 3. owner 列表高亮（原来的一半读会话、一半读持久化）

```dart
// side_drawer.dart 现在：
selected: ap2.currentAssistantId == a.id && currentGroupId == null   // 助手：持久化字段
selected: currentGroupId == group.id                                 // 群：当前会话
// 改成（两种 kind 同一句）：
final selectedOwner = ownerOfConversation(currentSession, ...);
selected: selectedOwner == ChatOwner.assistant(a.id);
selected: selectedOwner == ChatOwner.group(group.id);
```

这一步顺带让 F1 的一个次生症状消失：今天在一个群话题里，助手列表高亮的是「上一次选中的助手」，
而它的会话一条都看不到；改完之后，高亮的行和列出的列表永远是同一个 owner。

## 4. 名字仍然在说谎——这是本变体唯一接受的不完美

`currentAssistantId` / `currentAssistant` 表达的是「默认」，名字说的是「当前」。
本变体的处理是**把契约写进文档与测试**，不改名：

- `AssistantProvider.currentAssistant` 的 doc 明确写：它是**默认助手**（fallback），
  选中由会话归属派生；本类的名字保留是因为 40 余处调用点都在上游最常改的文件里。
- 加一条守卫测试：**打开群话题后 `currentAssistantId` 不变**，而高亮落在群上。
  这条测试在「管道顺手把选中改成 fallback」时会红。

## 5. 代价

- 名字不说谎这件事**没有**兑现；下一个读代码的人还得分清「选中」与「默认」。
- 但 40 余处调用点、`side_drawer.dart` / `home_page.dart` / `home_view_model.dart` 三个
  上游最常改的文件**一行都不动**，rebase 冲突面维持在第 2 轮 A 变体承诺的水平。
- 若之后要改名，它是一次独立的机械提交（见 B 变体），不和本轮混在一起。

## 6. 其余不变

数据流、会话解析表、reveal 状态表、失败模式、删除清单、不变量落点，全部沿用第 2 轮 A 变体
（`rounds/r2-core-a-controller.md`），只替换本文件的第 2、3 节。
