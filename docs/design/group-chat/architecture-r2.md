# 群聊架构 · 修订 2

回应三个问题：`assistant_id` 的归属方式、软删除与回收站、发送队列。未提到的部分沿用 `architecture.md`，这里只改这三处并给出结论。

## 0. 三个结论

1. **群会话的 `assistant_id` 保持 null，群归属只走 `extras['groupChat.id']`。** 这是影响面更小、语义更干净的一侧；`assistant_id = groupId` 看似少一个字段，实际要把 24 个助手解析点和 290+ 个 `assistantId` 读写点都改成“可能是助手、可能是群”，还要处理伪造助手/删除/备份，改动更大。
2. **不要软删除。** 群作为 `BusinessEntityKind.groupChat` 走现有业务实体通道；删除群 = 用同一个 `RecycleGroup` 把群实体和它所有会话一起 stage 进回收站，然后删 live 行。恢复走现有回收站，群和会话可以整组恢复。没有 90 天扫描，没有 `deletedAt`。
3. **群聊的一轮是会话级占用，队列沿用 1:1 的单槽队列。** 从用户消息到最后一个 speaker 结束，整个 round 持有 conversation claim；期间再次发送只入队，不插入轮次中间。round 结束或取消后，由同一个 `_drainQueuedInputIfReady` 排空。

## 1. `assistant_id` 方案对比（问题一）

| | A：null + `extras['groupChat.id']`（推荐） | B：`assistant_id = groupId` |
| --- | --- | --- |
| 现有 `resolveConversationAssistant`（24 处） | 群会话返回 null 时，只在“群聊分支”里不依赖它；解析函数本身不变 | 要么返回 null（24 处都要补群分支），要么返回伪造的 Assistant（模型/提示词/记忆全是假的） |
| 现有 `assistantId` 读写（290+ 处） | 群会话的 `assistantId` 是 null，删除助手、备份、按助手列会话都自然不命中 | 群 id 会进入按助手过滤、删除助手、草稿 owner、同 owner 比较等路径；每处都要排除群 id |
| 侧栏话题过滤 | 增加一个 `isGroupConversation` 分支；普通 `assistantId == null` 的全局会话语义原样保留 | 仍要改过滤（`resolve` 对群 id 返回 null，不匹配任何助手），且无法复用“全局会话”语义 |
| 删除助手 | 不会碰到群会话（`assistantId` 为 null） | 群 id 与助手 id 同命名空间；删除助手/备份恢复/草稿都要排除群 id |
| 备份/恢复 | `extras_json` 已经随会话走，不需要新字段 | 仍需 `extras` 识别群；`assistant_id` 里的群 id 还要防止被当成助手恢复 |
| 语义 | `assistant_id` 忠实表示“这条会话的单一助手”；群是另一个维度 | 把 `assistant_id` 当“owner id”用，但类型/解析/删除都仍按 Assistant 处理，名不副实 |
| 实际改动 | 1 个 `isGroupConversation` 谓词 + 约 10 个明确的分支点 | 24 个解析点 + 290+ 个读写点里筛出受影响的路径，或引入 owner 抽象（更大） |

结论：A 不是“少改一个字段”，而是“不把群伪装成助手”。B 的短处不是多写几行，而是把“助手”与“群”两个身份混进同一列，之后每个新功能都要再判断一次。选 A。

补充：`assistant_id == null` 在今天表示“全局/默认会话，出现在每个助手的话题里”。群会话也是 null，所以**每个读 null 的地方都要先问 `isGroupConversation`**；这是 A 的真实代价，但它集中在一个谓词，且不会污染助手解析。计划加一条测试：全局会话仍出现在每个助手的话题里，群会话不出现在任何助手的话题里。

## 2. 回收站，而不是软删除（问题二）

### 把群变成业务实体

```dart
enum BusinessEntityKind {
  // ...
  groupChat(
    sourceKey: 'group_chats_v1',
    tableName: 'extension_entity_rows',
    extensionKind: 'groupChat',
  );
}
```

这样群自动获得：

- `BusinessRepository` 的读/写/删除；
- 设置备份与恢复（`BackupContentFilter` 把 `group_chats_v1` 归到 `BackupCategory.chats`）；
- LAN sync 的业务实体通道；
- `RecycleService.stageEntityRow`（`extension_entity_rows` + `kind` 过滤已经支持）；
- 回收站列表里的“群聊”条目。

需要补的 switch：`BusinessSettingsRouter`、`BusinessSettingsMerger` 各加一个 `groupChat` 分支（payload 直接当 JSON 处理，和 workspace/skill 同型）。这是一次性的，不是每个群一份。

### 删除

```text
deleteGroup(group):
  rg = RecycleGroup(id: uuid8, label: group.name)
  chatService.deleteConversationsForGroup(group.id, group: rg)
      # 逐条走 deleteConversation 的同一捕获/ staging 路径；
      # 每条会话仍各自是一个 recycle entry，只是共享 group id
  businessRepository.deleteEntity(
      BusinessEntityKind.groupChat, group.id, group: rg)
      # stageEntityRow 先写群实体，再删 live 行
  群列表移除该群；当前会话若属于它，清空 current
```

- 没有 `deletedAt`、没有扫描、没有“群还在但看不见”的状态。
- 回收站里这是一组：`群聊「读书会」` + 它的每个会话。`restoreRecycleGroup` 一次恢复整组。
- 单独恢复某个会话、却没有恢复群实体时：会话仍可读，`GroupChatProvider.byId` 返回 null；HomePage 显示一条只读提示“群聊设置已在回收站”，composer 禁用，并提供“去回收站恢复群聊”的入口。这是**降级但可恢复**的状态，不是数据丢失。
- 单独恢复群实体、没有会话：群 tile 出现，话题为空，可以直接开新话题。
- 备份/恢复：群实体和会话的 extras 一起走；恢复后群、会话、作者都在。若旧备份只有会话没有群实体，按上面的“群设置缺失”降级处理。

### 为什么不是软删除

软删除要自己维护“隐藏但未删”的 live 行、恢复时反隐藏、90 天清理，还要决定备份是否带上 `deletedAt`；它和现有回收站是两套生命周期。群作为业务实体 + `RecycleGroup` 后，删除/恢复/保留期都只有回收站一套规则，代码更少，用户也只有一处能找到删掉的东西。

## 3. 队列（问题三）

### 状态

```text
conversation 的 busy =
  chatController.isConversationLoading(id)
  || chatActions.isSendInFlight(id)          // 整个 round 的 claim
  || chatActions.activeStreamingMessageId(id) != null
```

`sendGroupMessage` 在**同步段**拿 claim、创建用户消息、把 loading 置 true，然后启动后台 round；它立刻返回，和 1:1 的 send 一样不阻塞 composer。

```text
sendGroupMessage(input, conversation, group):
  if isSendInFlight(conversation.id) or compression.blocksSending:
      return inFlight
  claim = takeClaim(conversation.id)          // 整个 round 持有
  user = createUserMessage(...)
  append(user)
  setLoading(conversation.id, true)
  unawaited(
    runRound(conversation, group, anchor: user)
      .whenComplete(() {
        releaseClaim(conversation.id, claim)
        setLoading(conversation.id, false)
        onGroupRoundFinished(conversation.id)   // → _drainQueuedInputIfReady
      })
  )
  return success
```

`runRound` 内部对每个 speaker 调用 `runAssistantTurn(..., keepLoading: true)`：

- 单个 speaker 的 `_executeGeneration` 结束时**不**把 conversation loading 置 false；
- 只有整个 round 的 `whenComplete` 才置 false；
- 因此 speaker 之间的短暂空档不会让 composer 误以为空闲，也不会让第二次发送插进轮次中间。

### 用户再次发送

现有 `HomeViewModel.sendMessage` 已经是：

```text
if (_isConversationBusy(id) || compression.blocksSending(id)) {
  _queuedInputs[id] = QueuedChatInput(input);
  return queued;
}
```

群聊不改这段。区别只在 busy 的持续时间：1:1 是“当前回复流”，群聊是“整轮”。因此：

- 轮次进行中发送 → 入队，composer 显示排队条；不会出现“第三条回复还没说完，用户的新消息已经插进去”的错序。
- 排队的是完整的 `ChatInputData`（文字、图片、文件、引用），取消排队仍回到 composer。
- round 结束（正常、上限、fallback、取消）→ `onGroupRoundFinished` → `_drainQueuedInputIfReady` → 下一条作为新的一轮开始。
- 用户切换会话：round 继续，队列仍按 conversation id 保留；回到该会话时 busy 状态还在，队列不会被误排空。
- 用户停止：`cancelGroupRound` 先置 `roundCancelled`，再取消当前 speaker 的流；loop 退出，`whenComplete` 释放 claim 并触发排空。排队中的下一条会开始，和 1:1 停止后继续队列一致。
- 群被删除：先 `cancelGroupRound`，再走 §2 的删除，避免 round 继续写已删除的行。

### 与压缩的交互

- `compression.blocksSending(id)` 已经是发送闸门；群聊轮次同样遵守。
- 轮次进行中触发上下文压缩：现有 `ContextCompressionTask` 等待流结束；群聊的流在 speaker 之间有间隔，但 loading 仍为 true，压缩不会误判为空闲。
- 排队状态在压缩期间显示现有“压缩后发送”副标题。

## 4. 改动后的不变量

1. schema 仍为 5；群实体只进 `extension_entity_rows(kind='groupChat')`。
2. 群会话 `assistant_id` 永远 null；`isGroupConversation` 是唯一判据。
3. 群实体是 `BusinessEntityKind.groupChat`；备份、同步、回收站走同一条业务实体通道。
4. 删除群 = 一个 `RecycleGroup` 内的群实体 + 全部会话；没有软删除字段。
5. 整个 round 持有一个 conversation claim；loading 在 round 期间保持 true；队列只在 round 结束后排空。
6. director 不产生消息行；每轮最多 `maxSpeakerTurns` 个助手消息。
7. 群聊助手消息的 `senderId` 非空；插入时写入。
8. 跨助手的工具卡不回放；群上下文只保留文本和用户附件。

## 5. 验证补充

- 删除群 → 回收站出现一组（群 + N 个会话）→ 整组恢复 → 群、会话、作者都在。
- 单独恢复一个会话 → 只读提示、composer 禁用、回收站入口可用；恢复群实体后恢复发送。
- 删除群时正在生成 → round 取消，未完成的 assistant 消息按现有取消路径收尾。
- 队列：round 中连发两条 → 两条都排队，按顺序在新一轮开始；停止 round 后队列继续；取消排队恢复文字/图片。
- 切走再切回：round 仍在跑，队列未被提前排空。
- 备份只选 chats：群实体与会话一起导出/恢复；不选 chats：本地群实体保留。
- `assistant_id` 回归：普通全局会话仍出现在每个助手的话题里；群会话不出现在任何助手的话题里。
