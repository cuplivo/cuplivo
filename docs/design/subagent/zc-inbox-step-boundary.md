# 子会话的简报与留言：送到步骤边界

> 变体 b。a（`zb-inbox-turn-boundary.md`）的全部内容都在这里，再加一件：运行中的子会话在**下一步之前**读到父对话的留言（DSH 的 `steer` = nextStep）。本文只写多出来的部分；不变量与失败模式的编号沿用 a。调研见 `zd-dsh-port-research.md`。

## 1. 多出来的是什么

DSH 的整句「A working agent receives it at its next step; an idle agent starts a new turn with it.」子会话正在生成时，父对话的 `send_message` 不再排在队列里等这一轮结束，而是在子会话**当前这批工具调用执行完、下一次请求发出之前**进入它的上下文。

## 2. 多出的移植

| DSH | 搬成什么 | 落点 |
|---|---|---|
| `steer` = `send(msg,'next-step', wakeup=true)`；一步结束后 `nextStep` 非空就再开一步 | 协调器持有每个子会话的待投留言（内存，与 `waiters` 同级）；生成循环每一轮结束取一次 | `subagent_coordinator.dart`：`pendingSteer(childId)`；`tool_loop_runner.dart` 两个入口各加一个 `takeSteer` 回调（:100-145、:150-193） |
| 「取消期间到达的唤醒输入改道 next-turn」 | 取消中到达的留言留在队列，下一轮领走 | `tool_loop_runner.dart` / host 的取消路径 |
| 结算时父在工作 → steer | 不搬（N4：子→父永远走队列） | — |

## 3. 数据流（只写差异）

父 → 子，子会话**在跑**：

1. 写行、入队（同 a）——行先落，UI 立刻能看到。
2. 协调器把该行登记为子会话的待投留言。
3. 子会话的循环：一轮工具结果 `append` 之后，`takeSteer()` 取走待投留言 → host 把它作为一条 `user` 消息**合法地**放进 follow-up 请求（OpenAI 风格：tool 结果之后、下一次 assistant 调用之前；Claude / Gemini：`tool_result` 块之后）→ `sendFollowUp`。
4. 子会话这一轮结束时若仍有未投的（模型没再调工具，循环已退出），它们留在队列，`_finish` 后按 a 的路排空。
5. 返回 `{status:'delivered', delivery:'next_step'}`；循环已退出时 `'queued_behind_turn'`。

**边界**：步骤边界只在模型调了工具时存在。子会话在写一段没有工具调用的长回复时，b 和 a 一样要等。

## 4. 文案差异

`send_message`（父会话）第三句改为：「A subagent that has finished or was stopped by `interrupt` starts a new turn for your message; one that is still working reads it before its next step.」

简报「Messages that begin with…」后加：「They can arrive between your tool calls; apply one before you continue.」

## 5. 多出的不变量

- **N7 改**：生成循环为子会话开一个步骤边界；**人**的消息仍然不进（没有 UI 语义）——于是同一个正在生成的对话，代理的留言能中途进，人的不能。
- **N8**：一条留言只投一次：进了 follow-up 请求就从队列移除，不会在轮末再投一遍。

## 6. 多出的失败模式

| 情形 | 行为 |
|---|---|
| host 把留言放错位置（tool 结果之前、两条 user 连发等） | provider 返回 4xx；整轮重试（`retryRound`）会再放一次——必须幂等 |
| 取消与取信交错 | 取消中取走的留言回队列（DSH 的改道规则） |
| 流式中插入 | UI 在工具卡片之间多出一张留言卡；`RequestHistoryContext.roundCompleted()` 的计数要把它算作一步 |
| 导出 / PDF 重建对话 | follow-up 里的留言不在 Drift 行序的「轮内」位置——按行序导出会把它画在轮末 |
| 子会话的模型本轮不再调工具 | 留言已在记录里，但没进过任何请求；按 a 的路在轮末开新一轮 |

## 7. 多出的测试

- 两个循环入口各有：有待投 → follow-up 请求里出现该 user 消息且位置合法；无待投 → 请求不变。
- 取消回队；只投一次；导出顺序。

## 8. 代价（相对 a）

- `tool_loop_runner.dart` 是所有对话共用的；两个入口、每个 host 的 follow-up 构造都要改，`chat_send_race_test.dart` 等竞态用例要重跑。
- 人与代理对「运行中的对话」行为不一致，除非再开一轮把 nextStep 也给人用——流式中插入消息的 UI 语义是那一轮的题目。
- a 的全部代价。
