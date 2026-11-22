# 结果入队：核心伪代码

一句话：**子代理结束只做一件事——把「整条结果」放进该会话的 FIFO 队列**，什么时候落进时间线、什么时候续写，全部由队列决定。完成时不再判断「现在能不能打扰」。

## 1. 队列里的东西

```dart
/// 一个会话里排队等待落地的一轮工作。
sealed class QueuedTurn {
  const QueuedTurn(this.conversationId);
  final String conversationId;
}

/// 用户自己排进来的消息：行为与今天完全一致。
final class QueuedUserInput extends QueuedTurn {
  const QueuedUserInput(super.conversationId, this.input);
  final ChatInputData input;
}

/// 一个已完成子代理的结果：先写结果行，再续写一轮。
final class QueuedSubagentResult extends QueuedTurn {
  const QueuedSubagentResult(super.conversationId, this.notice, this.assistant);
  final ChatMessage notice;      // 已构造好的 SubagentResultPart + 简报
  final Assistant assistant;     // 发起委托的那个助手
}
```

状态：`Map<String, List<QueuedTurn>> _queue`（每个会话一条 FIFO）、`_draining`、`_paused`。

## 2. 入队与出队

```dart
void enqueue(QueuedTurn turn) {
  (_queue[turn.conversationId] ??= <QueuedTurn>[]).add(turn);
  notifyListeners();
  unawaited(_drainQueued(turn.conversationId));   // 不等，不阻塞调用者
}

Future<void> _drainQueued(String conversationId) async {
  if (_draining.contains(conversationId)) return;                 // 已在落
  if (_paused.contains(conversationId)) return;                   // 上次失败，等用户
  if (_chatService.contextCompression.blocksSending(conversationId)) return;
  final queue = _queue[conversationId];
  final conversation = _chatService.getConversation(conversationId);
  if (queue == null || queue.isEmpty || conversation == null) return;
  if (_isConversationBusy(conversationId)) return;                // 生成中，等这一轮结束再喊

  final turn = queue.first;                                       // 只取队首
  _draining.add(conversationId);
  notifyListeners();
  try {
    final ok = switch (turn) {
      QueuedUserInput() => await _sendMessageToConversation(turn.input, conversation),
      QueuedSubagentResult() => await _deliverSubagentResult(turn),
    };
    if (ok) {
      queue.removeAt(0);                                          // 成功才出队
    } else {
      _paused.add(conversationId);                                // 失败留在队首，不丢
    }
  } finally {
    _draining.remove(conversationId);
    _chatService.contextCompression.refreshInputStatus();
    notifyListeners();
  }
}

/// 一个已完成子代理的落地：结果行 + 续写。顺序与今天一致（先写行，再续写）。
Future<bool> _deliverSubagentResult(QueuedSubagentResult turn) async {
  await _chatService.addMessageDirectly(turn.notice);
  await refreshTimelineAfterExternalWrite(turn.conversation.id);
  final outcome = await regenerateScheduledMessage(
    message: turn.notice,
    conversation: turn.conversation,
    assistant: turn.assistant,
  );
  return outcome.success;
}
```

## 3. 谁来喊 drain

| 时机 | 为什么 |
| --- | --- |
| `enqueue` 之后 | 队列空、会话空闲时立即落地 |
| 每一轮生成结束（`handleStreamDone` / 取消 / 失败）之后 | 队首还等着，这是最常见的放行点 |
| 用户点「继续」解除 `_paused` | 上次失败后由用户决定重试 |
| 应用回到前台 | 后台期间队列不丢，回来立刻放行 |

## 4. 不做的事

- **不判断「现在能不能打扰」**：应用在后台、用户正在打字，都照样入队、照样调度。
- **不碰草稿**：入队、落地、清空都不读也不写 `composerDrafts` 的文本。用户排入的消息按今天的规则提交自己的草稿快照，其余一律不碰。
- **不合并**：两条结果就是两轮，先完成先落。

## 5. 协调器这一侧

```dart
// _finish，终态、且没人在 await_job 等的时候：
final notice = _buildNotice(entry, phase, reason);   // 只构造，不写库
entry.brief = notice.content;
host.enqueueSubagentResult(
  parentConversationId: entry.parentConversationId,
  notice: notice,
  assistant: entry.assistant,
);
return;                       // 不再 write、不再 refresh、不再重试唤醒
```

原先的 `canWake` 三道闸与 15×2s 重试循环**整段删除**。

## 6. 已知代价（接受）

- 结果行在落地那一刻才写进数据库：应用被杀死时，排队中的结果只存在于子会话里，父会话看不到它。
- 面板与条在「已完成」与「时间线出现」之间有一段时间不一致，双方都以队列为准展示（排队中的条目在面板里仍算「已完成」）。
