# 留言留在同一个 run 里，多写一个 assistant 行

> 变体 b。与 a（`ze-steer-turn-split.md`）共享全部设计——一个收件箱、一条规则、发送即写行、留言在段边界结束当前这一段并从历史重新装配下一段、简报、三个工具。只差一处：下一段**不切新 run**，同一个 run 里多写一个 assistant 行。本文只写差异；术语与不变量编号沿用 a。

## 1. 差异

边界上仍然不再发 follow-up，而是从历史重新装配一个请求；但新的 assistant 行挂在**同一个 run** 上，run 保持 `streaming` 直到这一轮真正结束。

- **保住**：一轮 = 一个 run。终态（`cancelled` / `interrupted`）覆盖整轮；子代理的 `_watch` 不用改（它盯的就是这个 run）；loading 与队列排空不用新概念。
- **打破**：run ↔ assistant 行 1:1。一个 run 先后拥有两条 assistant 行。

## 2. 要改的四处

1. **检查点**：`updateStreamingCheckpointSilent(checkpoint.message, …, generationRunId, checkpointSeq)` 以「一条消息 + 一个 run」为单位；同一个 run 的两条消息各自检查点，`checkpoint_seq` 要在 run 内单调，恢复时要知道哪条是当前段。
2. **`activeStreamingMessageId(conversationId)`**：今天返回唯一在流的那条；改为返回最后一段。
3. **收尾**：`_finalizeStreamingCheckpoint` / `_clearGenerationRuntimeState` 只处理一条消息；一个 run 两条时要都落定，且只有最后一段按 run 终态收尾。
4. **子代理取 closing text**：`_childClosingText` 取「本 run 最后一条非空 assistant 文本」——今天 run 只有一条消息，天然成立；改后要看最后一段。

## 3. 多出的失败模式

| 情形 | 行为 |
|---|---|
| 重启时一个 run 两条消息 | 启动扫描按 run 标 `interrupted`，两条都停在流式中；恢复要判断哪条是当前段，否则会出现两条「未完成」的回复 |
| 段 A 已经写完、段 B 正在写，Stop | 整轮一个 `cancelled`：段 A 的完成内容也会被当作取消的一部分，界面上看不出哪一段是留言前写完的 |
| 检查点与段不对应 | `checkpoint_seq` 在两条消息之间交叉，崩溃恢复可能把段 B 的内容写回段 A |
| 后台任务 id | 以 run / 消息为单位之一的代码要重新确认（`_backgroundTaskId(ctx)`） |

## 4. 少掉的代价

a 的 §9 第一条（「一轮 = 一串 run」四处）不存在；子代理监视、loading 连续性、队列排空判断都不用动。其余代价与 a 相同。

## 5. 代价（相对 a）

- **省**：不用引入「轮 = run 链」，子代理监视与取消语义保持今天的形状。
- **付**：run ↔ assistant 行的 1:1 被打破，上面四处要逐个改；崩溃恢复多一个「哪条是当前段」的问题；取消与「段已完成」的区分丢失。
- a 的其余代价照旧。
