# 群聊架构（v4，schema 5，不升版本）

这份文档是实现前的核心伪代码：数据形状、发送一轮的数据流、共享 composer 的接入点、必须始终成立的不变量、以及失败时怎么收场。UI 以 `variant-a-members.html` 为准：混合侧栏、折叠头像、成员清单、导演模型只做跳转。

## 1. 存储：只用 schema 5 已有的扩展点

不新增表、不新增列、不动 `currentSchemaVersion`。

| 需要保存的东西 | 落在哪里 | 为什么不用新表/新列 |
| --- | --- | --- |
| 群聊实体：名字、头像、成员、每轮上限、删除标记 | `extension_entity_rows(kind = 'groupChat')` 的 JSON payload | schema 3 就是为“新实体种类不建表”准备的；`ExtensionEntityStore` 已有 upsert/list/delete |
| 会话属于哪个群 | `conversation_rows.extras_json` 的 `groupChat.id` | schema 3 的 `extras_json` 注释明确把 group-chat participants 列为用例 |
| 助手消息的发言者 | `message_rows.sender_id` | schema 3 已加 `sender_id`，注释写明“group chat 等角色不唯一时记录作者”；当前代码只是没写它 |
| 全局导演模型 | `PreferenceRows` / `SettingsProvider` 的默认模型设置 | 导演模型是应用级成本策略，不随每个群复制；群设置那行只做跳转 |
| 侧栏混合顺序 | `PreferenceRows` 的 `sidebar.ownerOrder.v1`（`assistant:<id>` / `group:<id>` 列表） | 排序是 UI 状态，不进 schema |

### 模型

```dart
class GroupChat {
  final String id;              // uuid
  String name;
  String? avatar;               // 与 Assistant.avatar 同一种引用
  final List<String> memberIds; // 有序；至少 1 个，最多 20
  int maxSpeakerTurns;          // 1..6，默认 3；每轮助手消息上限
  final DateTime createdAt;
  DateTime updatedAt;
  DateTime? deletedAt;          // 软删除，见 §6

  // JSON payload 里带 "v": 1，未来可迁移。
}
```

```dart
// Conversation 扩展
String? groupChatIdOf(Conversation c) =>
    c.extras['groupChat.id'] is String ? c.extras['groupChat.id'] as String : null;

Conversation withGroupChatId(Conversation c, String? id) {
  final next = Map<String, dynamic>.of(c.extras);
  if (id == null) next.remove('groupChat.id');
  else next['groupChat.id'] = id;
  return c.copyWith(extras: next);
}
```

群的会话 `assistant_id` 保持 **null**。不要把它设成群 id：`assistant_id` 被助手解析、备份、删除和侧栏过滤共同拥有，塞进非助手 id 会污染每一条现有路径。群归属只看 `extras['groupChat.id']`。

### 消息作者

`ChatMessage` 增加 `String? senderId`：

- 1:1 助手消息：`null`，沿用“会话的 assistantId 或当前助手”。
- 群聊助手消息：`senderId = assistant.id`，必填。
- 用户消息：`null`。

持久化只加三处映射，列已经存在：

```text
_messageCompanion:  senderId: Value(message.senderId)
_messageUpdate:     senderId: Value(message.senderId)   // 仅在变化时
_messageFromRow:    senderId: row.senderId
ChatMessage.toJson / fromJson: 'senderId'
```

`_messageCompanion` 的插入是唯一创建路径；`beginAssistantGeneration` 必须把 `senderId` 带到占位消息上，不能先插入再补写（补写会多一次 `updated_at` 变化，也会让首帧渲染成无作者）。

### 侧栏 owner

```text
ownerKey(c) =
  groupChatIdOf(c) != null ? "group:" + groupChatIdOf(c)
                           : "assistant:" + (c.assistantId ?? "")

// 现有语义必须保留：assistantId == null 且不是群聊的会话，出现在每个助手的
// 话题列表里（全局会话）。群聊会话必须从这些列表里排除。
visibleInTopics(c, owner) =
  groupChatIdOf(c) != null
    ? ownerKey(c) == owner.key
    : (c.assistantId == null || resolveAssistant(c.assistantId)?.id == owner.assistantId)
```

## 2. 一轮群聊：数据流

```text
用户点发送
  │
  ├─ 单飞 claim：同一 conversation 只允许一轮
  ├─ 创建 user message（不创建 assistant 占位）
  ├─ 追加到 timeline；若标题仍是默认标题，用首行文本截断作标题
  │
  ├─ loop speakerTurns < group.maxSpeakerTurns:
  │    ├─ 取消/离开？→ 退出 loop
  │    ├─ Director.decide(群、公开转写、成员名、上限)
  │    │    ├─ end_turn(reason)        → 退出 loop
  │    │    └─ select_speaker(id)      → speaker = roster[id]
  │    ├─ speaker 不存在/没有模型？    → 记一次软错误，退出 loop
  │    ├─ ChatActions.runAssistantTurn(
  │    │      conversation, anchor, speaker, append: true, senderId: speaker.id)
  │    │    ├─ beginAssistantGeneration(anchor.groupId, senderId)
  │    │    ├─ 复用 prepareApiMessagesWithInjections(assistant: speaker)
  │    │    ├─ 复用流式、工具、重试、checkpoint、取消
  │    │    └─ 结束后返回 assistantMessage
  │    ├─ anchor = assistantMessage
  │    └─ speakerTurns++
  │
  └─ 释放 claim；触发一次列表刷新/滚动
```

`runAssistantTurn` 是 `ChatActions` 现有的 `_regenerateAtMessageClaimed` 的收口版：

```text
runAssistantTurn({conversation, anchor, speaker, append, senderId}):
  # append=true 时走 beginAssistantGeneration；这正是“在 anchor 之后新增一条
  # 助手消息”，不是替换版本。
  begin = messageGenerationService.beginAssistantGeneration(
    conversationId: conversation.id,
    modelId: speaker.modelId,
    providerKey: speaker.providerKey,
    anchorGroupId: anchor.groupId ?? anchor.id,
    senderId: speaker.id,
  )
  # 以下与现有 regenerate 路径逐行相同：context read、prepare、tool defs、
  # stream controller、checkpoint、finalize、错误收场。
```

**不要**复制一份生成管线。群聊只新增“谁来说”和“在谁的锚点后追加”两个参数，流式/工具/取消/失败全部沿用现有 `ChatActions`。

### 每轮上限与锚点

- `maxSpeakerTurns` 是**用户一条消息触发的助手消息数**，不是全群上限。
- `speakerTurns` 只在成功创建一个助手占位后自增，避免 director 连续返回同一个无效 id 时无限循环。
- 同一轮里 director 可以选同一个助手两次，但不鼓励；不强制，保持 v3 的灵活性。
- `anchor` 初始为用户消息；后续为上一名助手的消息。若该消息没有 `groupId`（不会发生，消息构造器总会填），用 `id`。

## 3. Director

```text
decide(group, transcript, members):
  provider/model = settings.groupDirectorModel ?? settings.currentModel
  if missing or !isToolModel(provider, model):
      return fallbackFirstSpeaker(reason: noDirector)

  messages = [
    system(directorPrompt(group, members)),   # 只含名字与轮次上限
    ...flattenPublicTranscript(transcript),   # 最近 N 条，压掉工具卡/推理
  ]
  tools = [
    select_speaker(assistant_id enum, reason?),
    end_turn(reason?),
  ]

  for attempt in 1..2:
      decision = callOnce(messages, tools, temperature: .2, maxTokens: 400)
      if decision != null: return decision
      messages += user("必须只用工具回答；有效 id: ...")

  return fallbackFirstSpeaker(reason: directorError)
```

规则：

- **只做主选择，不写正文。** Director 的自由文本被丢弃；只接受工具调用。
- 第一次有效工具调用立即产生决定并取消流，避免模型继续生成下一轮工具调用。
- Director 的上下文只来自公开转写 + 成员名字，不读任何助手的 system prompt、memory、world book。这是隐私边界，也是成本边界。
- Director 请求固定 `stream=false` 或“流式但只取第一个工具调用”，`maxTokens` 小，`temperature` 低。
- **没有 director 也要能用**：缺模型/模型不支持工具/两次调用失败 → 本轮由成员列表第一个（或“上一个发言者之外的下一个”）回复一次，并在 composer 上方给一次可关闭的提示，链接到默认模型设置。绝不静默让群聊不回复。
- Director 的选择不落库。它不是一个对话参与者，不产生消息行；不做“导演日志”持久化（v3 的日志是运行时投影，v4 先不做，避免第二份状态）。
- 每轮最多调用 `maxSpeakerTurns + 1` 次 director；到上限直接结束，不再调用。

### 转写压平

```text
flattenPublicTranscript(messages):
  for m in last(N):
    if m.role == 'user': emit user(m.text + 附件说明)
    if m.role == 'assistant':
      emit assistant("[{speakerName(m)}]\n" + m.text)
  # 丢弃：reasoning、ToolCallPart、tool result、空消息、翻译
```

Speaker 侧的上下文也走同一个压平：

- 不要把别的助手的工具调用/工具结果回放给当前模型。不同 provider 的工具 id 和协议不兼容，回放会制造“不存在的 tool_call_id”错误。
- 当前助手的 system prompt、memory、world book、skills、MCP 工具仍由现有 `prepareApiMessagesWithInjections` 按 speaker 注入。
- 在 system prompt 末尾追加一段群聊说明：群名、成员名、当前发言者。**只给名字**，不给别人的设定。
- 图片/文件仍按 speaker 的模型能力过滤，现有 `buildUserImagePaths` 不动。

## 4. Composer 接入（DRY 的关键）

不新写一套输入框。`ChatInputSection` 增加一个可选的 `GroupChat? group`：

```text
ChatInputSection(group: g)
  leading = GroupMemberCluster(group: g)     // 替换 modelIcon
  chatModelProviderKey = null
  chatModelId = null
  supportsReasoning = false
  showToolsButton = false
  onOpenSearch = null
  onSelectModel = null
  onConfigureReasoning = null
  showMiniMapButton = true                   // 群聊两端都要
  onOpenMiniMap = ...
  onOpenBrowser = ...                        // 群聊两端都要
  onPickCamera/Photos/UploadFiles = ...      // 移动端入口，桌面端由 overflow 处理
  onOpenContextUsage = ...                   // 上下文环
  onClearContext/onCompressContext = ...     // 上下文管理
  onSend = groupRound.send
  onStop = groupRound.cancel
```

`GroupMemberCluster`：

```text
Stack(width: ~52)
  for each member (max 4 visible): avatar, marginLeft: -15
  if members > 4: last circle shows "+N"
  plus circle (invite/entry affordance) at the end
  whole cluster = one InkWell → showGroupMembers()
```

- 单个头像不是点击目标。整叠是一个按钮，符合“占尽可能少的空间、作为整体被点击”。
- 成员超过 4 个时，第 4 个显示 `+N`；点击仍然打开完整清单。
- 空群/加载中：只显示一个 `+` 圆，点击打开成员清单（清单里可以邀请）。

`showGroupMembers`：

```text
mobile:  CustomBottomSheet(GroupMemberList)
desktop: showDialog(GroupMemberList)          // 不用 bottom sheet
```

`GroupMemberList` 的 entry 固定为：

```text
[group avatar] 群成员
  每个 member 一行：avatar + name + chevron
      onTap → AssistantEntryActions.openAssistantSettings(assistantId)
  ＋ 邀请助手
      onTap → assistant picker，排除已在群里的 id
  ⚙ 群聊设置
      onTap → showGroupSettings(group)
```

没有第二层快速编辑，没有“移出群聊”快捷按钮；移除在群设置的成员区做。

## 5. 群设置与导演模型

`GroupSettingsView` 只写一份，移动端用页面、桌面端用对话框（`ResponsiveHelper` 分支），信息架构一致：

```text
基本信息：名字、头像
成员：列表 + 邀请 + 移除（确认）
编排：
  导演模型   [当前值] >        // 跳转到“默认模型”里的导演模型设置
            选择下一个谁来发言的模型，建议选择快速且低成本的模型
  每轮最多发言  [− 3 ＋]       // 1..6
删除群聊（确认）
```

导演模型放在全局“默认模型”里，群设置只做跳转：

- 所有群共用一个导演模型，成本策略集中在一处，不会出现“某个群偷偷用了贵模型”。
- 群设置的值只读显示当前全局值；点击打开默认模型设置。
- 不在群 payload 里存 director provider/model。
- 初始化默认值：`groupDirectorModel = null` 时跟随全局默认模型；默认模型不支持工具时，运行时走 §3 的 fallback，设置页显示一行状态。

## 6. 不变量

1. **schema 版本不变**：`AppDatabase.currentSchemaVersion == 5`；群聊只用 `extension_entity_rows`、`conversation_rows.extras_json`、`message_rows.sender_id`。
2. **群会话的 `assistant_id` 永远是 null**；群归属只由 `extras['groupChat.id']` 决定。
3. **群聊助手消息的 `senderId` 永远非空**；插入时写入，更新不丢。读取时 `senderId` 解析不到助手 → 显示“已离开的助手”，不崩溃、不 fallback 到当前助手。
4. **一个群至少有 1 个成员**；删除最后一个成员要么拒绝，要么同时删除群。选择拒绝（与“至少一个助手”一致）。
5. **Director 不产生消息行**，不写 conversation extras，不参与备份。
6. **群聊会话不出现在任何助手的话题列表**；`assistantId == null` 的普通全局会话行为不变。
7. **一轮只有一个写者**：发送/重发/重新生成都走同一个 conversation claim；director 循环里不会并发两个 speaker。
8. **取消是整轮取消**：`onStop` 先置 `roundCancelled`，再取消当前 speaker 的流；循环不再调用 director。
9. **工具不跨助手回放**：群聊上下文只保留文本和用户附件，其他助手的 ToolCallPart 全部压平。
10. **删除群不留下孤儿**：见 §7。

## 7. 删除、回收与备份

```text
deleteGroup(group):
  for c in conversationsOf(group):
      deleteConversation(c)          // 走现有回收站/删除路径，extras 一起走
  group.deletedAt = now
  store.upsert(group)

groupList():
  groups where deletedAt == null
    or conversationsOf(group).isNotEmpty   // 恢复的会话仍能找到群

sweep():
  deletedAt != null
    and deletedAt < now - 90d
    and conversationsOf(group).isEmpty
    → store.delete(group)
```

- 会话删除/恢复沿用现有回收站；因为 `groupChat.id` 在 extras 里，恢复后仍指向群。
- 群实体软删除，避免“恢复了会话但群配置已经没了”。90 天清理与现有 tombstone/回收站节奏一致。
- 备份：`extension_entity_rows` 与 `conversation_rows.extras_json`、`message_rows.sender_id` 已在备份范围内；加一条测试防止未来被过滤掉。恢复后群实体、会话、作者都应回来。
- LAN sync：同样依赖上述三处已有列/表；不需要新协议字段。

## 8. 消息渲染

```text
resolveSpeaker(message):
  if message.senderId != null:
      return assistantProvider.getById(message.senderId)   // 可能 null
  if conversation.assistantId != null:
      return assistantProvider.getById(conversation.assistantId)
  return assistantProvider.currentAssistant
```

- `MessageListView` 增加 `Assistant? Function(ChatMessage)? resolveAssistant`；群聊传入上面的函数，1:1 传 null。
- 头像、名字、模型图标、正则、`useAssistantAvatar/Name` 都按解析结果走。
- 解析不到（助手被删）时显示中性头像 + 名字占位，不把消息当成当前助手。
- 用户消息不变。

## 9. 导航

```text
SideDrawer owner list = ChatOwnersProvider.owners
  owner = assistant:<id> | group:<id>
  排序 = PreferenceRows['sidebar.ownerOrder.v1']
  未知 owner 追加；已删除 owner 丢弃

选中 owner:
  assistant → AssistantProvider.setCurrentAssistant(id)
  group     → GroupChatProvider.select(id)
  topics 过滤 = visibleInTopics(c, owner)

新建会话:
  owner 是 group → createDraftConversation(groupChatId: id, assistantId: null)
  owner 是 assistant → 现有路径
```

- 群聊和助手在同一个列表里，共用一套拖拽顺序；标签分组仍只作用于助手，群聊落在未分组区。
- 群聊 tile 的上下文菜单：群设置、删除群聊；不提供“复制群聊”（多会话已经取代了复制配置）。
- 搜索 owner 时匹配群名；搜索话题时匹配会话标题。

## 10. 失败模式与收场

| 场景 | 行为 |
| --- | --- |
| 群没有成员 | 发送被拒绝；composer 提示去成员清单邀请助手 |
| 某助手没有模型 | 该轮跳过该 speaker；若 director 连续选它，记一次软错误并结束本轮；用户消息保留 |
| Director 没配置 / 不支持工具 | fallback：成员列表第一个回复一次；composer 上方一次性提示，链接到默认模型 |
| Director 超时/报错/返回无效 id | 重试一次；仍失败 → 同上 fallback；不把错误写进消息 |
| 当前 speaker 的模型不支持用户附件 | 现有能力过滤处理；若附件全部被过滤，该 speaker 仍回复文本 |
| 用户中途停止 | 取消当前 speaker 的流；已产生的部分消息按现有取消路径 finalize；不再调用 director |
| 用户离开群聊页 | 当前轮继续（与 1:1 一致）；群聊页重新进入时从 timeline 恢复 |
| 删除正在发言的助手 | 先取消该会话的生成，再从群成员移除；历史消息的 senderId 保留，显示为“已离开” |
| 群成员在轮次中被移除 | 本轮已开始的 speaker 继续完成；下一次 director 决策前重新读取成员表 |
| 恢复一个群会话但群实体已清理 | 仍显示消息；群归属解析失败 → 会话按普通会话展示，并提示群已删除 |
| 备份/恢复 | 群实体、会话链接、senderId 一起回来；缺群实体的会话不阻塞恢复 |
| 上下文压缩进行中 | 沿用现有 `blocksSending`；群聊轮次也受同一闸门约束 |
| 临时会话 | 群聊不参与临时会话；群会话永远持久化（避免“临时群”没有群实体） |

## 11. 实施切分（一次做完，但按依赖落地）

1. **数据层**：`GroupChat` + `GroupChatStore` + `GroupChatProvider`；`Conversation` extras 助手；`senderId` 全链路；`ChatOwnersProvider` + owner order。
2. **生成层**：`ChatActions.runAssistantTurn` 抽取；`GroupDirector`；`GroupRoundRunner`；senderId 进入占位消息；群聊上下文压平 + 群说明注入。
3. **UI 层**：`GroupMemberCluster` → `GroupMemberList`；`GroupSettingsView`；`ChatInputSection(group:)`；`MessageListView.resolveAssistant`；侧栏混合 owner。
4. **收尾**：l10n（中英）、测试、备份/恢复覆盖、`dart analyze`、`flutter test` 相关用例。

## 12. 验证

- 数据：群 JSON round-trip；`senderId` 写入/读取/备份；owner 过滤保留全局会话语义；schema 仍为 5。
- Director：工具解析、无效 id、重试、fallback、end_turn、上限。
- 轮次：0 成员拒绝；1 成员；3 成员；上限 2 时 director 多选也只产生 2 条；取消在第 2 条前停止；speaker 无模型。
- Composer/消息：折叠头像整叠打开清单；每个成员行进入助手编辑；消息按 senderId 显示头像/名字；解析不到时不崩。
- 回归：1:1 发送、重新生成、分支、附件、浏览器、上下文管理、迷你地图、备份恢复。
- 硬门槛：`AppDatabase.currentSchemaVersion == 5` 的断言不变；`dart analyze --fatal-infos lib test integration_test` 通过。
