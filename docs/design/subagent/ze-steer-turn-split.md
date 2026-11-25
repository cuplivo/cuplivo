# 留言在这一步结束这一轮，用它开下一轮（手递手）

> 变体 a（推荐）。第三版：仍然是「一个收件箱、一条规则、人与代理同一条路」，但把切口做在**轮**的层面——留言到达可投的步骤边界时，当前这一轮在那里结束，留言作为下一轮的第一条用户消息。与变体 b（`zf-same-run-multi-row.md`）只差一处：切不切一个新 run。调研见 `zd-dsh-port-research.md`。

## 1. 一句话

每个对话一个收件箱。一条规则：**发送即写行；对话能生成且手里有留言，就开一轮；对话正在生成，就在下一个步骤边界结束这一轮、用留言开下一轮。** 人、父对话给子会话的留言、子会话给父对话的进度，全走这条路。新的一轮从历史重新装配请求，所以留言得到和人写的消息一模一样的待遇——模板、正则、时间、记忆、附件、压缩、冻结行，没有例外。

## 2. 术语

- **轮（turn）**：一条用户消息，到它的回复结束。
- **步（step）**：一次请求 / 响应；调了工具就有下一步。
- **run**：`generation_run_rows` 的一行，`GenerationRun`（`core/database/generation_run.dart:1-52`）。一次生成的生命周期，状态 `preparing → requesting → streaming → completed / failed / cancelled / interrupted`（:1-26）。**本文里 run 是「段」**：一轮可以是一段（没有留言），也可以是多段（每段之间夹着一条留言）。
- **段（segment）**：一个 run 对应的一条 assistant 行。run ↔ assistant 行保持 1:1——这是本文相对上一版的核心变化。
- **收件箱**：每对话一份，内存，放「已落盘、等着开下一轮」的消息。
- **留言**：代理写的 user 消息，带 `SubagentMailPart`。
- **简报**：子会话系统提示里那段 `<subagent_context>`。

## 3. 为什么切一个新 run 更干净

上一版把留言塞进**在飞请求**（7 处 adapter 的 `append` 之后追加一条 `user`）。那要求每个 provider 接受「工具结果之后紧跟一条 user」，而 Gemini 的相邻 content、Claude 的 `tool_result` 轮、Responses 的 item 顺序各不相同；还要求在同一个 run 里写第二个 assistant 行，于是记忆载体、图片归属、冻结行都得特殊处理（上一版 N10）。

切一个新 run 之后，这三样全部消失：

- **不需要碰 adapter**：新 run 的请求由 `assembleUnprocessedRequestContext` 从历史装配，和每一轮开始时走同一条路。
- **不需要特殊处理**：留言就是最新的一条用户消息，模板、正则、`<current_time>`、记忆、附件、压缩、冻结行全按正常路径。
- **run ↔ assistant 行仍然 1:1**：检查点、`activeStreamingMessageId`、`_historyContexts[messageId]`、后台任务 id 的假设一条都不用改。
- 模型看到的历史与「插入」完全一致：`assistant(tool_calls) → tool results → user(留言)`，只是它被写成了两段。

代价只有一个新概念：**一轮 = 一串 run**。加载状态、队列排空、子代理的「做完没有」都要按轮看，而不是按 run 看（§9）。

## 4. 数据流

**人发送，对话空闲**：与今天一样（`beginSendGeneration` 一个事务写 user 行 + assistant 占位 + run，`chat_database_repository.dart:5122-5174`）。

**人发送，对话在生成中**

1. 写一行 user 消息（group turn 的现成办法：`chat_database_repository.dart:5183-5216` `beginUserMessage`），无占位、无 run。
2. 登记进收件箱（内存）。
3. UI：消息立刻出现在对话里，带「待读」标记；composer 不锁，可以继续发。
4. **边界**：runner 在 `append(executed)` 之后问 `RequestHistoryContext.current?.takeHandoff()`。
   - 没有可投留言 → 照旧 `sendFollowUp()`。
   - 有 → `yield* finish()` 结束这一段的流，返回（不发下一次请求）。
5. 编排：run A 正常收尾为 `completed`，assistant 行 A 保留（以工具调用结尾，和今天「工具后中断」的形状一样）。
6. **手递手**：在同一个同步段里，用最后一条留言开新的一轮——新占位行 + 新 run（`regenerateScheduledMessage` 的形状，`preserveFollowingMessages: true`；内部入口跳过忙检查，因为此刻 loading 还没清）。中间不发布 idle，队列不排空（否则会插队）。
7. 新 run 的装配走正常轮次开始：`assembleUnprocessedRequestContext` → `processUserMessagesForApi`，留言得到与普通消息相同的处理，冻结行在此时写。
8. UI：气泡 A 收口 → 留言 → 气泡 B 开始。所见 = 记录 = 发给模型的顺序。
9. 若边界上没有留言、这一轮自然结束：照旧走排空；收件箱里的留言在排空时开一轮（和今天 `QueuedSubagentResult` 一样的位置）。
10. 若这一步之后模型不再调工具、循环退出：留言留在收件箱，轮末排空开新一轮。

**父 → 子**（`send_message{job_id, text}`，深度 0）：行带上 `SubagentMailPart`，文本前缀「The delegator sent a message: 」，写进子会话 → 子会话按同一条规则（在跑就下一段，空闲就新一轮）→ 每段结束产生一条结果行。`cancelled` → `not_continuable`；不是本会话的子会话 → `not_found`；重启后无 entry 但 `subagent.parent` 是本会话 → 冷恢复。

**子 → 父**（`send_message{text}`，深度 ≥ 1）：写进父会话，带 `SubagentMailPart`，前缀「Subagent <label> sent a message: 」。同一条规则。

**中断**（`interrupt{job_id}`）：取消子会话当前的 run → 该段 `cancelled`，阶段 `stopped`，父会话写一条 outcome `stopped` 的结果行，不入队。待投的留言留在收件箱（N11），之后 `send_message` 可续。

**简报**：替换 `_subagentPrompt`，每次装配请求时渲染，不落行。

## 5. 移植清单

| DSH | 搬成什么 | 落点 |
|---|---|---|
| 收件箱 + 两种投递 | 每对话收件箱；能生成 → 开一轮；在生成 → 边界结束这一段、开下一轮 | `home_view_model.dart:1002-1011`（忙分支改写）、`:1251-1325`（排空）；`QueuedUserInput` 退场，`QueuedSubagentResult` 不变 |
| `steer` 的边界 | `takeHandoff` 回调；runner 两个入口各问一次；有则 `finish()` 并返回 | `tool_loop_runner.dart:136-137`、`:191`；`request_history_context.dart` 加字段；`chat_actions.dart:3035-3044` 挂上 |
| 手递手 | run A `completed` → 同一同步段内用留言开新一轮（跳过忙检查、不发布 idle、不排空） | `chat_actions.dart` 收尾（:2789-2938 一带）与 `_runSendGeneration` 尾部；`home_view_model.dart:949-973` 的内部变体 |
| 轮的边界 | 「这一轮还在进行」= 这一串 run 里最后一段未终态 | `home_view_model.dart:247-250`（`_isConversationBusy` 已是会话级）、loading 发布点 |
| `subagent:delegation` 节 | 简报 | `message_builder_service.dart:2250-2259`；仍归 `ContextSource.systemPrompt` |
| 留言的消息形状 | `SubagentMailPart`（kind `subagent_mail`）：`fromRole`、`senderConversationId` | `core/models/message_part.dart`；`isUserInputMessage` 加一支 |
| 结算按 run | `messageIdFor(childId, runId)`；面板最新优先 | `message_part.dart:193`；`subagent_panel.dart:205-219` |
| `interrupt` 保留收件箱 | `stopped` 阶段，写行不唤醒 | `subagent_coordinator.dart` |
| 子代理监视「轮」 | `_watch` 从「盯一个 run」改为「盯这一串 run 的最后一段」；会话空闲时读最后一段的终态 | `subagent_coordinator.dart:526-568`、`:585-661` |
| 不搬 | `list_agents`、命名 / 目录、fork、深度 > 1、全树、`omitClosingText`、快照 / 压缩、外部后端 | — |

**没有的地方**：7 处 `append` 闭包、每个 provider 的落位规则、Gemini 相邻 content 验证——都不需要，因为请求是从历史重新装配的。

## 6. 最终文案

**简报**（替换 `_subagentPrompt`；英文，与现块一致）

```
<subagent_context>
You are a subagent: this conversation was started by another conversation, the delegator, to carry out one task. The delegator's model cannot see this conversation. It receives only what you send it with `send_message` and, when your turn ends, your final reply. The human user can open this conversation and may write in it directly.

You are "{label}", delegated by "{parent title}", at depth {depth}.

- Do not wait for the delegator to answer a question. Use `send_message` to say what you found and what you need, then keep going with what you have; sending a message does not end your turn. Write only when a finding changes what the delegator should do next.
- A message from the delegator arrives as a new message in this conversation, after the round you were in. It may end the round you were in and start the next one; apply it before you continue.
- When you are done, finish with a short, self-contained conclusion: what you did, what you found, what is still open. That conclusion is the result; the delegator does not receive your transcript, tool output or reasoning.
- You cannot delegate further.
</subagent_context>
```

**工具说明**（父会话）

```
send_message(job_id, text):
Send a message to a subagent you started with `delegate`: to correct it, answer a question it asked, or give it a new task after it finished. This returns when the message is delivered, NOT with the subagent's reply — its answer arrives later as a notice and you will be asked to continue. A subagent that has finished or was stopped by `interrupt` starts a new turn with your message; one that is still working finishes the round it is in and reads your message at the start of the next. A subagent the user stopped cannot be continued.

interrupt(job_id):
Ask a subagent you started with `delegate` to stop what it is doing. This returns immediately, NOT when it has stopped. What it concluded so far arrives as a notice marked stopped; you can then `send_message` to continue it with a correction, or leave it.
```

**工具说明**（子会话）

```
send_message(text):
Send a message to the conversation that delegated your task: a finding that changes what it should do next, or a question you cannot answer yourself. This returns when the message is delivered, NOT with an answer — do not wait for one, keep working with what you have. Sending a message does not end your turn; your final reply is still delivered as the result.
```

**留言行**：模型可见文本 `The delegator sent a message: …` / `Subagent <label> sent a message: …`；卡片标题走 l10n。**待读标记**：一个图标，不加文字。

## 7. 不变量

沿用 `n-core-pseudocode.md` #1 #2 #4 #5 #6 #9 #10，改三条：

- **#3 改**：每一段（每个 run）一条结果行。
- **#7 改**：`stopped` 也写行，只是不唤醒。
- **#8 改**：留言在父对话忙时于段边界开下一段，不新开一轮；轮末才开新一轮的仍遵守「忙 / 草稿不开」。

新增：

- **N1** 回执 ≠ 回答：三个工具只返回投递结果。
- **N2** 发送即写行：人、代理同一条规则。
- **N3** 代理写的行不是用户输入（按 part）；人写的是。
- **N5** 只有 `cancelled` 是终局；`completed`、`failed`、`stopped`、`interrupted` 都可用一条留言再开一轮（或再开一段）。
- **N6** 简报只在系统提示里，永远不落行。
- **N7** 一个收件箱、一条规则：能生成就开一轮，在生成就在段边界结束这一段、开下一段。
- **N8** 只投一次：开出一段即出箱、去标记。
- **N9** 边界只在有工具调用的步骤之后；纯文本回复不打断，留言等轮末开新一轮。
- **N10** 留言走正常轮次开始路径（模板、正则、时间、记忆、附件、压缩、冻结行），没有例外。
- **N11** Stop 不丢信：待投的留到下一轮 / 下一段；已投的留在记录里。
- **N12** run ↔ assistant 行 1:1；一轮 = 一串 run。

## 8. 失败模式

| 情形 | 行为 |
|---|---|
| 边界上没有可投留言 | 正常 `sendFollowUp`，这一轮继续 |
| 模型这一步不再调工具、循环退出 | 留言留在收件箱，轮末排空开新一轮 |
| 连发多条留言 | 收件箱按序；边界一次取走全部已落盘的，一轮以第一条留言开始？不——**每条留言一段**：边界只取一条，剩下的留到下一段边界或轮末。行序即段序 |
| 手递手启动失败（provider 拒绝） | 段 A 已 `completed`，留言行已落盘、仍在收件箱；标「未开始」，用户可重试；不丢行 |
| Stop 在段 B 中 | 段 B `cancelled`，段 A `completed`；待投留言留在收件箱；`cancelStreaming` 后的排空开新一轮 |
| Stop 在段边界之前 | 段 A `cancelled`，留言留在收件箱 |
| 写行后、开段前进程死亡 | 行是普通行；重启后 `interrupted` 的假设不适用（没有 run），留言行留在收件箱外可由下一轮开始——收件箱是内存的，重启后不自动投，用户可以接着发 |
| 压缩审查中收到留言 | 行落盘；`blocksSending` 结束前不开新一轮（§10） |
| 对端设备同步 | 留言行照常同步；待读标记与收件箱是内存的 |
| 带图留言 | 走正常轮次开始，图片按现有规则归属 |
| 子会话在另一台设备被留言 | 在那台设备开段（`generation_run_rows` 设备本地） |
| 子会话 `cancelled` 后被留言 | `not_continuable` |
| 子会话连发进度 | 每条是父对话的一段；只有简报一句话约束 |
| 段 A 以工具调用结尾 | replay 的既有能力（`assistant_tool_history_test.dart`：「unfinished batch keeps earlier rounds」） |

## 9. 代价

- **一轮 = 一串 run**。这是唯一的新概念，落点四处：
  1. **loading 连续性**：段 A 收尾与段 B 启动在同一同步段，中间不发布 idle（否则 UI 闪一下，且 `_onLoadingChanged(false)` 会触发排空、让别的消息插队）。
  2. **队列排空**：排空前必须判断「这一串 run 还有没有下一段」，否则留言还没开段，队列头先跑掉。
  3. **子代理监视**：`_watch` 现在盯一个 run；改为盯最后一段——段 A `completed` 不能当成「子代理做完」，否则父会话收到一条过早的结果。终态取最后一段的。
  4. **run 终态语义**：段的 `completed` 不等于轮结束；任何按 run 判断「这一轮成功没有」的地方改看最后一段。
- **每段一次完整装配**：一条留言＝一次轮次开始（系统提示、记忆、世界书、上下文上限）。留言不频繁，可接受。
- **结果 id 按 run**；面板最新优先。
- **3 个工具说明进系统提示**；简报；留言 part；待读标记；l10n 条目。
- **竞态用例重跑**：`chat_send_race_test.dart`、`request_history_context_test.dart`、`tool_loop_runner_test.dart`。

相比上一版**省掉**：7 处 adapter 落位、每个 provider 的相邻规则、Gemini 真请求验证、记忆载体与图片归属的特殊处理、在飞表与压缩 / 重试的交互。

## 10. 压缩与生成的统一（两个追问里的第二问）

问题：把压缩也和生成统一起来，切口是否更干净、能否删掉一些 UI 复杂性？

**会删掉的东西**：`blocksSending` 这个前置闸（`context_compression_service.dart:559-561`）、`_pausedQueuedInputs` 的最后一种含义、composer 的 `isInputPaused` 锁（`chat_input_bar.dart:459`）、侧栏徽标（`side_drawer.dart:4887`）、`compression_incomplete` 这条错误路径。做法是让每一轮一开始就有占位行和 run，压缩成为 run 的一个阶段（像 `ask_user` 那样「等用户」，`GenerationRunState` 加一个 `compressing`），用户审查时这一轮在界面上是正常的「等你处理」，不是一个把输入锁死的外部状态。

**但本轮不做**：压缩有自己的服务、任务持久化、审查 UI 与安全点规则，和本轮的切口是正交的两件事；把它并进来会把爆炸半径翻倍，而本轮的切法不依赖它——留言在压缩期间只是「行已落盘，等压缩结束再开段」。

**它在本文里的位置**：本文已经把 `_pausedQueuedInputs` 的含义压缩到只剩压缩审查（排队失败那一半随 `QueuedUserInput` 退场消失）。统一压缩是紧接着的下一片，删掉的正是剩下的这一半——它值得自己的一轮。

## 11. 测试要钉住的

- 两个循环入口：边界有留言 → 这一段的流以 `finish` 结束、**没有**下一次 `sendFollowUp`；无留言 → 不变。
- 手递手：段 A `completed`、段 B 新 run、中间不发布 idle、队列不排空。
- 轮末：留言在收件箱，排空开新一轮；带图 / 带文档的留言走正常处理，有冻结行。
- Stop：段 B 取消、段 A 保留；待投留言留到下一段。
- 子代理：段 A 结束不被当作完成；终态取最后一段。
- 留言行 `isUserInputMessage`：人的 true、代理的 false（扩 `subagent_serialization_test.dart`）。
- 结果行每段一条；面板最新优先；导出 / PDF 多条正常。
- `chat_send_race_test.dart` 的排队用例改写：忙时发送 → 行立刻落盘、可连发、段边界接力。

## 12. 本轮不做

压缩与生成的统一（§10，下一轮）；打断没有工具调用的纯文本回复；把 `waitingTool` 真正写进 run；`list_agents`、命名、fork、深度 > 1、全树寻址、`omitClosingText`；快照 / 压缩机制；外部后端。

---

## 13. 实现记录（2026-11-23）

按 §5 落地：简报、`SubagentMailPart`、三个工具、协调器的 `stopped` / 续聊 / 中断 / 按轮串监视 / 每段结果行、边界手递手（`RequestHistoryContext.takeHandoff` + `tool_loop_runner` 两个入口 + `chat_actions` 收尾 + `home_view_model` 的收件箱与排空）。`plan.md` §12.1 有逐项清单与三处偏差：

1. 人的消息仍是排队（只是投递提前到步骤边界），**不是** §4 第 1 步的「发送即写行」；composer 的排队锁与 chip 还在。
2. `stopped` 的界面文案暂借 `cancelled`，缺两个 l10n 键。
3. `_pausedQueuedInputs` 仍有「排队失败」来源，要等压缩统一那一轮才删得掉。

界面上还缺 §6 的「待读标记」：留言行在收件箱里时不带标记，因为人的消息还没先落盘，只给代理留言加标记会造成两种消息两种外观。

### 13.1 第二轮 clarity 之后（2026-11-24）

- **结果行只在模型没通过工具调用拿到结果时出现**：`await_job` 由 `waiters` 抑制；模型 `interrupt` 成功也不写行、不唤醒（只回 `accepted`，不回传内容——打断就是说到哪算哪；想要结论用 `await_job`，想让子代理尽快收口用 `send_message`）。用户停止子代理写行但不唤醒；父对话自己的 Stop 级联同样不唤醒。
- **留言行改用结果行那条 28px 分隔线**：`subagentMailLabel · 发送方标题`，正文跟在下面，不再是独立卡片；点分隔线打开 dialog（桌面）/ sheet（移动）看完整消息。导出与 PNG 走已有分隔线分支。
- 新增 `subagentMailLabel`（6 个 ARB、指纹、`gen-l10n`、`translate.py check` 全过），实现里不再需要「已停止」文案——停止不产生结果行。

### 13.2 review 修正（2026-11-25）

- `interrupt` 说明改成「静默停止」；`stopped` 的结果行分支（divider/面板）删除，因为存储里不会有这个 outcome。
- 手递手不再等旧订阅的 barrier cancel：`_finishStreaming` 在启动下一段前把旧订阅从 `_conversationStreams` 移除，避开「在 drain 里等 drain」的 3 秒超时。
- 留言标签按方向取词：子对话里读「委派方消息」（`subagentMailDelegatorLabel`），导出共用 `subagentMailLabelText`。
- l10n state 文件保持 LF；watcher 带 generation；`stoppedByModel` 每段结算清空；暂停队列不参与手递手。

### 13.3 第三轮 review（2026-11-25）

- Gemini 交替约束：评审说连续两条 `user` 会 400，但仓库既有的工具续聊形状（`user(functionResponse)` 紧跟 `user(text)`）就是这样，四个测试锁定它。合并相邻同角色回合的改动已回滚，等真有 400 再按窄条件处理。
- 命名目标的子代理无条件获得 `send_message`；`interrupt` 仍只属于委派方。
- 两个新工具卡标题键；续聊重置 `startedAt`；手递手就绪判断加 `blocksSending`。

### 13.4 rebase 到深度 1–3（2026-11-26）

- 简报的「不能继续委派」改为读该会话的 `levels`；深度不再写死为 1。
- 已知缺口：可继续委派的子代理仍只有向上回复的 `send_message`，没有 `interrupt`，无法管理自己的下一层——记为下一片。
- 面板保留 master 的 `descendants` 计数，同时保持「同一子会话取最新结果行」。

