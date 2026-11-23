# 子会话的简报与留言：送到轮次边界

> 变体 a（推荐）。与变体 b（`zc-inbox-step-boundary.md`）只差一处：运行中的子会话什么时候读到父对话的留言——这里答「它当前这一轮结束时」，b 答「下一步之前」。其余相同。调研见 `zd-dsh-port-research.md`。

## 1. 这是什么

把 DSH 子代理的两样东西搬进 Cuplivo：

- **简报**：子会话对自己的身份与回报规则的了解，一个 system 节，替换今天那段「不要提问、不要等澄清」的静态文字。
- **留言**：父 ↔ 子之间的 `send_message`。每条留言都是**接收方对话里的一行 `user` 消息**，按 part 而不是按角色识别为非用户输入——和今天的结果行同一套办法。

再配两个让留言成立的小件：

- **可续**：发完、停完的子会话可以用一条留言再开一轮；每一轮一条结果行。
- **可续的中断**：父对话能让子会话停下，再改口。

**不动生成循环**。子会话正在生成时，留言排在它的队列里，等这一轮结束——和今天 Cuplivo 里**人**给一个正在生成的对话发消息完全一样。

## 2. 移植清单

| DSH | 搬成什么 | 落点 |
|---|---|---|
| `subagent:delegation` 节 | 简报：身份、来源规则、回报契约（§4 原文） | `message_builder_service.dart:2250-2259` 换掉 `_subagentPrompt`；仍归 `ContextSource.systemPrompt`（:2241-2245 的理由不变） |
| 「动态上下文变化才追加」 | 不搬快照机制：子会话里会变的只有事件，事件就是消息行 | — |
| 留言的形状「Agent X sent a message:」+ 自己的 source kind | `SubagentMailPart`（kind `subagent_mail`）：`fromRole: delegator\|subagent`、`senderConversationId`、`messageId` | `core/models/message_part.dart`；`isUserInputMessage` 加一支 |
| `send_message` 父→子 followup | 工具 `send_message{job_id, text}`：先写行再入子会话队列（`QueuedSubagentMail`），空闲就开新一轮 | `local_tools_service.dart` 新定义；`tool_handler_service.dart` 新 case；`subagent_coordinator.dart` 新 `sendMessage`；`home_view_model.dart:1281` 的 `switch` 加一支，照 `QueuedSubagentResult` 那支写（总是出队） |
| `send_message` 子→父（进度） | 子会话（深度 ≥ 1）的工具 `send_message{text}`：写行进父会话 + `QueuedSubagentMail` 入父队列；父忙则在队列里等（不变量 #8） | 同上；`subagent_rules.dart:105-106` 的撤下名单只给子会话加这一个 |
| 结算按 run 计 | `messageIdFor(childId, runId)`；`_finish` 用 entry 的 `runId` | `message_part.dart:193-196`；读 result part 的地方接受多条：`export_document.dart`、`message_export_sheet.dart`、`pdf_export_dialog.dart`、`subagent_panel.dart`、`chat_message_widget.dart` |
| `interrupt` 保留收件箱 | 工具 `interrupt{job_id}`：取消当前 run，阶段 `stopped`，写一条 outcome `stopped` 的结果行，**不**唤醒父对话；之后 `send_message` 可续 | `subagent_coordinator.dart`：`SubagentPhase.stopped`，`cancelChild` 旁加 `stopChild` |
| 人停 / 模型停分开 | 只有 `cancelled`（人按 Stop：父级联或子会话自己）是终局 | 不变量 N5 |
| 发送回执 ≠ 回答 | 三个工具都只回投递结果 | 工具返回值 |
| 不搬 | `list_agents`、命名 / 目录、fork、深度 > 1、全树寻址、`omitClosingText`、快照 / 压缩、外部后端、nextStep | — |

## 3. 数据流

**父 → 子**（`send_message`，深度 0）

1. 模型调 `send_message(job_id, text)`。协调器找 entry；没有就按会话 `extras['subagent.parent'] == 本会话` 冷恢复一个；不是自己的子会话 → `not_found`；阶段 `cancelled` → `not_continuable`。
2. 在子会话写一行 `user` 消息：`[SubagentMailPart(delegator), TextPart("The delegator sent a message: " + text)]`，行 id `UUIDv5("cuplivo/subagent-mail/<parent>/<toolCallId>")`（与 `begin` 的幂等键同一套）。
3. 入子会话队列 `QueuedSubagentMail`。
4. 子会话空闲（无活 run）→ `_drainQueuedInputIfReady` 立刻排空 → 以这一行为最后一条用户消息开新一轮 → 结算时按 run 出一条新结果行给父对话。子会话在跑 → 留在队列头，这一轮 `_finish` 之后排空（子会话是普通会话，走同一个空闲钩子）。
5. 返回 `{status:'delivered', message_id, delivery: 'turn_started' | 'queued_behind_turn'}`。

**子 → 父**（`send_message`，深度 ≥ 1）

1. 子会话的模型调 `send_message(text)`。
2. 在父会话写一行 `user` 消息：`[SubagentMailPart(subagent, sender: 子会话 id), TextPart("Subagent <label> sent a message: " + text)]`。
3. 入父队列 `QueuedSubagentMail`；父空闲且在前台 → 跟一轮；父忙 / 草稿 → 等（与结果行同一条路）。
4. 返回 `{status:'delivered', message_id}`。子的这一轮不结束。

**中断**（`interrupt`，深度 0）：取消子的 run → 阶段 `stopped` → 父会话写结果行（outcome `stopped`，brief = 停下前最后一句，没有就「stopped before it finished」）→ 不入队。之后 `send_message` 到它 = 开新一轮。

**简报**：每次装配请求时渲染，内容只依赖 `extras['subagent.depth']`、子会话自己的标题（就是 label）与父会话的标题；不进对话记录。

## 4. 最终文案

**简报**（替换 `_subagentPrompt`；英文，与现块一致）

```
<subagent_context>
You are a subagent: this conversation was started by another conversation, the delegator, to carry out one task. The delegator's model cannot see this conversation. It receives only what you send it with `send_message` and, when your turn ends, your final reply. The human user can open this conversation and may write in it directly.

You are "{label}", delegated by "{parent title}", at depth {depth}.

- Do not wait for the delegator to answer a question. Use `send_message` to say what you found and what you need, then keep going with what you have; sending a message does not end your turn. Write only when a finding changes what the delegator should do next.
- Messages that begin with "The delegator sent a message:" come from the delegator. Other user messages come from the human.
- When you are done, finish with a short, self-contained conclusion: what you did, what you found, what is still open. That conclusion is the result; the delegator does not receive your transcript, tool output or reasoning.
- You cannot delegate further.
</subagent_context>
```

**工具说明**（父会话）

```
send_message(job_id, text):
Send a message to a subagent you started with `delegate`: to correct it, answer a question it asked, or give it a new task after it finished. This returns when the message is delivered, NOT with the subagent's reply — its answer arrives later as a notice and you will be asked to continue. A subagent that has finished or was stopped by `interrupt` starts a new turn for your message; one that is still working reads it when its current turn ends. A subagent the user stopped cannot be continued.

interrupt(job_id):
Ask a subagent you started with `delegate` to stop what it is doing. This returns immediately, NOT when it has stopped. What it concluded so far arrives as a notice marked stopped; you can then `send_message` to continue it with a correction, or leave it.
```

**工具说明**（子会话）

```
send_message(text):
Send a message to the conversation that delegated your task: a finding that changes what it should do next, or a question you cannot answer yourself. This returns when the message is delivered, NOT with an answer — do not wait for one, keep working with what you have. Sending a message does not end your turn; your final reply is still delivered as the result.
```

**留言行**：模型可见文本 `The delegator sent a message: …` / `Subagent <label> sent a message: …`；卡片标题走 l10n。

## 5. 不变量

沿用 `n-core-pseudocode.md` #1 #2 #4 #5 #6 #8 #9 #10，改两条：

- **#3 改**：每一轮（每个 run）一条结果行，不再是一个子会话一条。
- **#7 改**：终态必写行——`stopped` 也写，只是不唤醒。

新增：

- **N1** 回执 ≠ 回答：三个工具只返回投递结果。
- **N2** 先写行再入队：子会话读到留言之前，它已经在子会话的对话记录里（可同步、可在 UI 看到）。
- **N3** 代理写的行永远不是用户输入（按 part）。
- **N4** 子 → 父的留言永远不在父对话忙或草稿时唤醒它（沿用 #8；DSH 会 steer 一个工作中的父，这里不）。
- **N5** 只有 `cancelled` 是终局；`completed`、`failed`、`stopped`、`interrupted` 都可以用一条留言再开一轮。
- **N6** 简报只在系统提示里，永远不落行。
- **N7** 生成循环不改：任何对话（人的或子会话的）运行中都没有消息能中途进入。

## 6. 失败模式

| 情形 | 行为 |
|---|---|
| `job_id` 不是本会话的子会话 / 不存在 | `{status:'rejected', reason:'not_found'}` |
| 子会话阶段 `cancelled`（人停的） | `{status:'rejected', reason:'not_continuable'}` |
| 协调器里没有 entry，但会话还在且 `subagent.parent` 是本会话（重启后） | 冷恢复 entry，按空闲投递 |
| 留言写入成功、续写一轮没起来 | 行已写，出队，`subagent_follow_up_failed`（与结果行同一条路，`home_view_model.dart:1348-1352`） |
| 子会话给不是它父会话的会话发消息 | 工具没有地址参数，不可能；深度 1 也不给 `delegate` |
| 模型重试同一次 `send_message` | 同一个 `toolCallId` → 同一个行 id，写行幂等 |
| 子会话连发进度 | 每条是父对话的一轮；只有简报里的一句话约束，无上限 |
| 对端设备收到同步的留言行 | 看得到行，没有 run，面板只按 result part 重建（与今天一致） |
| 子会话在另一台设备上被留言 | 在收到留言的设备上开 run（`generation_run_rows` 设备本地） |

## 7. 测试要钉住的

- 留言行 `isUserInputMessage` 为 false，`lastUserInputIndex` 仍在人身上（扩 `subagent_serialization_test.dart`）。
- 空闲子会话收到留言 → 新一轮 → 第二条结果行，id 不同于第一条（扩 `subagent_coordinator_test.dart`）。
- 运行中子会话收到留言 → 行已写、队列头是它、`_finish` 后排空。
- `cancelled` 的子会话 → `not_continuable`；`stopped` → 可续。
- 父对话忙时子 → 父留言不唤醒（沿用 #8 的用例形状）。
- 冷恢复：无 entry、有 extras → 投递成功。
- 子会话工具表：有 `send_message`，仍没有 `delegate` / `await_job`（扩 `subagent_rules_test.dart`）。
- `SubagentMailPart` round-trip 与同步 wire。

## 8. 本轮不做

`list_agents`、命名与目录、fork（继承父历史）、深度 > 1、全树寻址、`omitClosingText`、快照 / 压缩机制、外部后端；以及 **nextStep**——见变体 b。
