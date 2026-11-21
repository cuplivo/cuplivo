# 子代理：核心逻辑伪代码

> 状态：**已过**（clarity round accept，无修改意见）。UI 已过（`m-all-ui-v2.html`），失败态已过（`o-failure-states.html`，选 A：失败也唤醒）。落地状态见文末 §10。
>
> 骨架不是新设计的：`scheduled_task_runner.dart:101-186` 已经在做「程序化建会话 → 跑一整轮 → 按 generation run 判终态 → 取最后一条回复」。异步要做的事只有一件——**把那个等待循环挪到后台**，而不是把整条管线重写。
>
> 这一页的注释与说明是中文；**落到生产代码里，标识符、注释、提交信息一律用英文**。

---

## 1. 一句话

`delegate` 建一个继承父会话工作区的子会话，起一轮生成，**立刻返回**；一个后台 watcher 盯那轮的 `GenerationRun`，终态时把结论写成父会话里一条 `user` 消息（id 幂等），再唤醒父会话续写一轮。

---

## 2. 数据：三样落库，一样不落

| 东西 | 存在哪 | 为什么 |
|---|---|---|
| 父子关系、深度、目标、工作区继承 | 子会话的 `extras`（`subagent.parent` / `subagent.root` / `subagent.depth` / `subagent.target` + `workspace.id` / `workspace.cwd`） | 既有扩展点，不加列（`app_database.dart:88`） |
| 结果 | 父会话里一条消息：`role: 'user'`、一个 `subagent_result` 类型的 part 带着简报；消息 id = **UUIDv5(命名空间, 子会话 id)**——一个和别的消息完全一样的 UUID，但同一个子会话永远算出同一个 | wire 上就是 user 轮次（模型读得到）；界面按 **part 类型**分流渲染 |
| 终态 | **`GenerationRun` 本身**，四种终态 `completed / failed / cancelled / interrupted`（`generation_run.dart:1-18`） | 仓库已有的事实来源，不再造第二个 job 状态机 |
| 运行态（谁在跑、跑到哪） | **只在内存 registry**，不落库 | 和生图同一条读法：没有落库的状态，就没有「重启后挂着」的假象 |

### 2.1 id 是 UUID，身份是 part

你说得对，前缀没必要：以后真要做「多个会话来回协作」，靠字符串前缀认类型只会越来越脆，而且它破坏了「消息 id 一律是 UUID」这条统一性。

所以：

- **消息 id = `Uuid().v5(Namespace.url.value, childConversationId)`**。它长得跟任何一条消息的 id 一样（标准 UUID），但**确定性**——同一次委派永远算出同一个 id，插入即去重，不需要先查再写。`uuid` 包的 v5 在这个仓库里已经用着（`markdown_media_sanitizer.dart:68` 用 v5 从规范化文本算摘要 id）。
- **身份 = part 类型**。渲染、序列化、「它不是用户自己的话」三件事都读 `SubagentResultPart`，不读 id。`MessagePart.fromRow` 本来就按 `kind` 分支构造（`message_part.dart:17-36`），老版本读到不认识的 kind 落进 `UnknownPart` 并原样写回——前向兼容是这套设计自带的。

代价是多一个 `sealed class` 子类和一行 `fromRow` 分支；收益是 id 被导入/同步重写时，结论不会变成一条来路不明的用户发言。

### 2.2 workspace 权限：不需要新概念，靠「不复制」

授权是**会话级**的：`tools.permission_mode`（`fullAccess` / `requestApproval`）与旧的 `workspace.allowAll` 都写在会话 extras 里（`tool_permission_mode.dart:5-15`）。`WorkspaceBinding.applyTo` 在换绑时就会把授权剥掉（`workspace_binding.dart:41-46`，且 `allowAll` 永远剥）。

所以子会话的 extras 只复制 `workspace.id` / `workspace.cwd` 两个键，**一个 grant 键都不写**：

- `ToolPermissionMode.fromExtras` 落回 `requestApproval` —— 这是默认值，不是"我们额外加了限制"。
- 用户在子会话里批准过一次，写进的是**子会话自己的** extras；父会话的授权不受影响，反之亦然。
- 深度 > 1 时孙会话再从不复制，同一条规则。

于是不变量 #6 有了机械的表述：**子会话 extras 的键集不含 `ToolPermissionMode.grantExtrasKeys`**，一条测试就够。

**结果消息的两个必须**：
- id 由 `childId` 确定性算出（UUIDv5）→ 同一子代理重复投递只会有一条（插入即去重）。
- 序列化时**不是「用户自己说的话」**：不给 `internalRevisionIdKey`、不接管附件与图片、不成为 `lastUserInputIndex`。这条靠既有的 `isUserInputMessage`（`request_image_context.dart:35-49`）+ 在 `message_builder_service.dart:653-665` 那个 `else if` 链上加一个分支，和群聊的 `_groupPeerSender` 并列。

---

## 3. 工具契约

```jsonc
// delegate —— 不阻塞
{ "name": "delegate",
  "parameters": {
    "task":  "完整、自洽的任务说明。子代理看不到本会话历史。",
    "label": "给这次委派起个短名字，用在卡片、进度条和会话标题上。用对话的语言，一个名词短语，不要整句。",
    "cwd":   "可选。只能是指向本会话工作区内部的相对路径。" },
  "required": ["task", "label"] }
// → { "status": "started", "conversation_id": "...", "job_id": "..." }
// → { "status": "rejected", "reason": "no_workspace" | "workspace_not_ready" | "depth_limit" }

// await_job —— 模型显式选择等待时才用
{ "name": "await_job", "parameters": { "job_id": "..." } }
// → { "status": "completed", "payload": {...} }      // 图：asset uri；子代理：最终文本 + conversation_id
// → { "status": "failed", "reason": "..." }
// → { "status": "still_running", "elapsed_ms": 184000 }   // 超时 ≠ 失败；带上已经等了多久
```

> **`label` 不写「N 个字」**：这条描述是英文的，而 label 是模型用对话语言起的——「字」对英文没有意义。描述只说「一个名词短语，不要整句」，长度交给兜底（超过 20 字符就截断加省略号）。中文模型自然会给出 4–8 字，英文给出 2–4 词，这比写死一个数可靠。

---

## 4. 伪代码

### 4.1 派遣

```
delegate(task, label, cwd?):
  key = (parentConversationId, parentMessageId, toolCallId)      # 幂等键，照生图
  if registry.has(key):
      return {status: started, conversation_id: registry[key].childId}   # 重渲染/重挂载不再派

  bind = parentConversation.extras 的 workspace.id / workspace.cwd
  if bind.id == null:                       return rejected('no_workspace')
  if !workspaceRuntime.ready(bind.id):      return rejected('workspace_not_ready')

  depth = parentConversation.extras['subagent.depth'] ?? 0
  if depth >= maxDepth:                     return rejected('depth_limit')   # 工具此时也不该在工具集里

  child = createConversation(
      title:  label,                                     # 主代理给，3–8 字
      assistantId: parentConversation.assistantId,        # 同一个助手，不是"选一个目标"
      activate: false,                                    # 不切走用户当前会话
      extras: workspaceExtras(bind) + {                   # 一次写入，绝不"先建后改"
          'subagent.parent': parentId,
          'subagent.root':   parentRoot,
          'subagent.depth':  depth + 1,
          'subagent.target': 'general' })

  registry.put(key, childId: child.id, state: queued)
  start(child, task, cwd)                                 # 不 await
  return {status: started, conversation_id: child.id, job_id: child.id}
```

### 4.2 起一轮（照抄 scheduled 那条，去掉任务参数）

```
start(child, task, cwd):
  # 委派指令不写进 user 消息：子会话要能正常阅读自己的历史。
  # 它按 extras 存在与否，每轮注入一小段（和 injectWorkspacePrompt 同一个位置）。
  turn = viewModel.sendProgrammaticTurn(
      input: ChatInputData(text: task),        # 任务就是子会话的第一条 user 消息
      conversation: child,
      assistant: assistantOf(child),
      onGenerationStarted: (msgId, runId) => registry.attachRun(key, msgId, runId))

  watch(turn)                                  # 后台，不等它
  return
```

### 4.3 盯终态（就是 scheduled 那个循环，挪到后台、去掉超时抛错）

```
watch(turn):
  loop:
    run = getGenerationRun(turn.runId)
    if run.state.isTerminal:
        outcome = collectOutcome(child)                # ← 唯一的接缝，见下
        writeResult(parentId, child.id, outcome)       # 见 4.4
        registry.finish(key, run.state)
        wake(parentId, child.id)                       # 见 4.5
        return
    if child 有 pending approval / ask_user:
        registry.mark(key, 'waiting_for_input')        # 不退出，也不当失败
    sleep 500ms
  # 进程被杀：watcher 消失，registry 消失，什么都没落库 —— 见 4.6

# 结果从哪来：这一版是「最后一轮的非空 assistant 正文」。
# 但抽取只在这个函数里，别处一律读 SubagentOutcome，不读消息：
#
#   SubagentOutcome {
#     String  text;            // 这一版：最后一轮正文；以后可能是工具返回值
#     String? conversationId;
#     Duration elapsed;
#     List<String> changedPaths;   // 这一版空着
#     Map<String, dynamic>? data;  // 工具结果 / 结构化返回值，这一版空着
#   }
#
# 预留的两个方向（这一版不实现，只留接口形状）：
#   ① 子代理用工具「交回」结果 —— 换的是 collectOutcome 的实现，调用方不动；
#   ② 主代理用工具追加消息（而不是落一条 user 消息）—— 换的是 writeResult 的落点，简报拼装不动。
```

### 4.4 写结果（幂等靠 id，身份靠 part）

```
writeResult(parentId, childId, outcome):
  id = Uuid().v5(Namespace.url.value, childId)          # 确定性 UUID：同一次委派永远是同一个
  if messageExists(id): return                          # 插入即去重，重复投递只会有一条
  insert(ChatMessage(
      id: id, conversationId: parentId, role: 'user',
      parts: [SubagentResultPart(
          childConversationId: childId,                 # 身份在这里，不在 id 里
          summary: brief(outcome))],                    # 结论 + 改动文件 + 子会话 id
      timestamp: now))
  # content 由 part 派生（和 ImagePart 同一套），所以别处读 content 也拿得到简报全文
```

### 4.5 唤醒

```
wake(parentId, childId):
  if !appForeground:                 return    # 结果已落库，下次进来就在历史里
  if conversationBusy(parentId):     return    # 父的回合还在跑 → 结果已在下一个 step 边界进上下文
  if hasDraft(parentId):             return    # 用户在打字，别抢

  # 结果是最后一条 user 消息，且它还没有对应的 assistant 回复 —— 
  # 「重新生成」这条入口正好是这个语义：
  regenerate(message: resultMessage, conversation: parent, assistant: ...)
```

> **待验证的假设 A**：`regenerateScheduledMessage` 对「一条还没有任何回复的 user 消息」是否成立（会不会要求先有一条 assistant 消息做版本锚）。若不成立，就加一个 `generateForLastUserMessage()` 入口——`sendScheduledMessage` 只差「不追加新 user 消息」这一个分支。

### 4.6 取消与重启

```
# 父会话 Stop
ToolCallCancellation.current.onCancel(() => cancelGeneration(child, expectedMessageId))
  → 子会话那一轮走既有 cancelStreamingById；run 落 cancelled（这个状态本来就存在）
  → watcher 照常收到终态 → 写结果（内容为「已取消」）→ 不唤醒

# 子会话自己的 Stop
既有入口，不需要新机制。

# 中途强杀（进程被杀，子轮次跑到一半）
启动时 chat_service.dart:585 的 _resetStaleStreamingState() 已经把上一进程遗留的
preparing / requesting / streaming / waiting_tool 原子地改成 interrupted
（errorCode = 'app_restart'，chat_database_repository.dart:8612-8644）。

所以重启后不需要「派生中断」：
  - run 行本身就是 interrupted —— 这是一个**落库的事实**，不是"读不到就是中断"。
  - 父会话没有结果消息，registry 空，条不出现。
  - 渲染层读「子会话最新一条 run 是 interrupted + 父侧无结果消息」显示「已中断」。
  - 不补写结果消息、不重跑。要重来就是用户再说一句「再试一次」。
```

---

## 5. 不变量（每条都要能被一个测试钉住）

| # | 不变量 | 怎么钉 |
|---|---|---|
| 1 | 同一个 `toolCallId` 只产生一个子会话 | 连续调用两次 `delegate`，断言 `createConversation` 只被调一次、返回同一个 `conversation_id` |
| 2 | 子会话的 `workspace.id` == 父会话的 `workspace.id` | 父会话手动切过工作区后派遣；断言 extras 相等，且 `assistant.defaultWorkspaceId` **不参与** |
| 3 | 结果消息只有一条 | `writeResult` 连调两次；断言该 id 只有一行 |
| 4 | 结果消息不是「用户自己的话」 | `isUserInputMessage` 为 false；`internalRevisionIdKey` 不出现；`lastUserInputIndex` 指向真正的用户消息；**识别读 part 类型，不读 id**（把 id 改成随便什么，断言仍然成立） |
| 5 | 到深度上限时，`delegate` **不出现在子会话的工具定义里** | 这里的「工具集」是每轮现算的 `buildToolDefinitions`；`subagent.depth == maxDepth` 时干脆不注册 `delegate`，模型看不见它就不会白白调用一次。若模型从历史里学到这个名字硬调，handler 也返回 `depth_limit`。测试：depth == maxDepth 的子会话，断言工具定义里没有 `delegate` |
| 6 | 子会话不带任何授权 | 父会话 fullAccess 时派遣，断言子会话 extras 的键集与 `ToolPermissionMode.grantExtrasKeys` **不相交** |
| 7 | 终态一定写回，且中途强杀也落在终态 | 两条：① 让子轮次失败，断言 registry 条目不是永久 running；② 进程在子轮次中途被杀，重启后该 run 的状态是 `interrupted`（启动清理保证），父会话没有结果消息 |
| 8 | 唤醒不落在忙碌/草稿的会话上 | busy 与 hasDraft 两格各一条 |
| 9 | schema 仍是 5 | `currentSchemaVersion == 5` + `_validateRawSchema` |
| 10 | 父会话 Stop 会传到子轮次 | 记录 `cancelGeneration` 的调用 |

---

## 6. 失败模式

> 这一页只写「系统做什么」；这六种情况在卡 / 条 / 分隔线 / 面板上长什么样，是下一轮的事。

| 什么坏了 | 用户看到 | 系统做什么 |
|---|---|---|
| 子轮次 API 失败 | 结果分隔线出现，文案是失败原因 | 终态 failed → 写结果 → **不唤醒**（唤醒只会让它解释一次自己的失败） |
| 子轮次被父 Stop 取消 | 同上，写明「已取消」 | 终态 failed(cancelled) |
| 子会话在等审批/提问 | 条上是「1 个在等你回答」；子会话里是那张卡 | watcher 标 `waiting_for_input`，不判失败、不超时 |
| 进程被杀 | 父会话没有结果消息；子会话内容都在；面板里那条是「已中断」 | 启动清理已把 run 改成 `interrupted`（`app_restart`）；**不补写、不重跑** |
| 工作区被删 / runtime 挂了 | 派遣当场失败，父模型拿到可执行错误 | 在 `delegate` 里早失败，不留「没有工作区的子会话」 |
| 父会话在结果到达时正忙 | 结果照常落库；当前这一轮的下一请求就能读到 | 不唤醒，不插队 |
| 模型不给 `label` | 卡与条上是截断后的任务首句 | 兜底截 12 字 |
| 模型连续派 5 个 | 条上「5 个子代理」；并发不设上限 | 一次调用一个；不排队、不拒绝 |

---

## 7. 要动的接缝（文件级，不含 UI）

| 文件 | 改什么 |
|---|---|
| `chat_service.dart` `createConversation` | 加一个可选 `extras` 参数；不传时行为不变（仍走 `_extrasForNewConversation`） |
| `scheduled_task_runner.dart` 那套 | 抽出「程序化跑一轮 + 等终态」，让 scheduled 与 subagent 共用；scheduled 保留超时抛错，subagent 不抛 |
| `tool_handler_service.dart` / `local_tools_service.dart` | 注册 `delegate` 与 `await_job`，按助手开关（和 `generate_image` 同一层） |
| `message_builder_service.dart:653-665` | 那个 `else if` 链加一个分支：带 `subagent_result` part → 打标记、不给 revision id |
| `message_part.dart` | 新增 `SubagentResultPart`（sealed 子类 + `fromRow` 一行分支 + `content` 里并入简报文本），老版本靠 `UnknownPart` 原样写回 |
| `request_image_context.dart` `isUserInputMessage` | 认得新标记（和 `_groupPeerSender` 并列一行） |
| 子会话的注入点 | `injectWorkspacePrompt` 旁边加 `injectSubagentPrompt`：extras 有 `subagent.depth` 时注入那几行「你是子代理，不要向用户提问…」 |
| 渲染层 | 结果消息按 id 前缀渲染成分隔线；`delegate` 走普通工具卡；条读 registry |
| 新文件 | `lib/features/subagent/`：registry、watcher、brief 拼装、`label` 兜底 |

---

## 8. 明确不做

- 不做 `cancelled` / `interrupted` 的持久化状态；「中断」是渲染层的读法。
- 不加 `parent_conversation_id` 列、不加 job 表。
- 不 patch `dependencies/markstream`。
- 不做子代理之间通信、不做批量委派、不做目标助手（第二片）。
- 结果消息**不可编辑、不可重试**（它不是用户写的）。

---

## 9. 一个已经查清的问题，一件留给下一轮的事

- **~~假设 B（并发写）~~ 查清了，比担心的窄。** `message_builder_service.dart:229` 那个 `in_flight` 守卫只在 `buildDetachedTextContext` 里，而它全仓只有一个调用方——`scheduled_task_preparation_binding.dart:91`，也就是定时任务的**准备**阶段；子代理走的是正常生成路径，根本不经过它。就算经过，它读的是**本会话**的历史（`:224-228` 按 `conversation.id` 取），看不到子会话的流。另外「不同会话同时生成」本来就是既有能力——定时任务就是在用户聊天时跑一轮。所以这条从风险降为「实现时顺手确认一句」。

- **失败态的 UI**：这一页没画。取消、失败、重启中断、等审批，四种情况在卡 / 条 / 分隔线 / 面板上的具体样子，实现完再开一轮过目（你点的）——**已开并已过**，见 `o-failure-states.html`：失败也唤醒、条只留「需要你」、终态归分隔线、不做重试、中断读落库事实。

---

## 10. 落地状态

| 这里的不变量 / 契约 | 落地 | 钉住它的测试 |
|---|---|---|
| #1 同一个 `toolCallId` 一个子会话 | `SubagentCoordinator.begin` 的 `_byKey` 幂等 | `subagent_coordinator_test.dart` "the same tool call delegates once" |
| #2 子会话 workspace == 父会话 | `buildChildSpec` 只复制 `workspace.id` / `workspace.cwd` | 同上 "inherits the parent workspace and no grant"；`subagent_rules_test.dart` |
| #3 结果消息只有一条 | `UUIDv5(childId)` + `addMessageDirectly` 按 id 去重 | `message_part_test.dart`（确定性 id）；协调器测试断言 id |
| #4 结果不是用户自己的话 | `message_builder_service` 打 `_subagentResult`、不给 revision id；`isUserInputMessage` 认它 | `subagent_serialization_test.dart` |
| #5 到上限时工具不注册 | `LocalToolsService.buildToolDefinitions(allowDelegation:)` | 同上 "a conversation at the limit does not" |
| #6 子会话不带授权 | `createConversation(extras:)` 收口 + `buildChildSpec` 不复制 | 协调器测试断言键集与 `grantExtrasKeys` 不相交 |
| #7 终态一定写回 | watcher 盯 `GenerationRun` | 协调器三条（completed / failed / cancelled） |
| #8 唤醒不落在忙碌/草稿上 | `canWake` 由页面给 | "a busy parent is not woken" |
| #10 父 Stop 传到子轮次 | `ToolCallCancellation.current.onCancel` → `cancelChild` | "stopping the parent stops the child, and only a live one" |
| §3 `delegate` 契约 | `delegateDefinition`（`task` + `label`，`rejected` 带 `reason`） | `subagent_serialization_test.dart` |
| §3 `await_job` 契约 | `awaitJobDefinition` + `SubagentCoordinator.awaitJob` | 同上 |
| §4.3 `waiting_for_input` | 页面给 `waitReasonFor`，条与面板分别说「等你回答」「等你批准」 | "a child parked on a question reads as waiting, not running" |
| §4.2 子代理身份注入 | `MessageBuilderService.injectSubagentPrompt`（`ContextSource.subagent`） | — |

**两处与伪代码不同的地方，都是有意的**：

1. **`SubagentResultPart` 不带 `summary`**。伪代码写的是「part 带简报、`content` 由 part 派生」；实现里简报是同一消息的一个 `TextPart`（`content` 本来就由 TextPart 拼），part 只带身份与展示字段（`childConversationId` / `label` / `outcome` / `elapsedMs`）。这样 `content` 照样拿得到全文，而渲染永远不需要解析散文。
2. **`no_workspace` 是拒绝，不是「继承一个空工作区」**。§4.1 已经这么写，但早期 plan 的 §6 写的是「父未绑定则子也未绑定」；以 §4.1 为准。

**还没有做的两件**（都不阻塞上面任何一条不变量）：

- 助手编辑器里「子代理」那一行的配置弹窗（深度 / 模型）。工具箱里的行与开关已经在了；弹窗要展示的两个值在这一版都只有一个可能值（深度固定 1、模型继承父助手），现在做等于造一个没有选项的控件。
- **重启中断的渲染**（§4.6 那句「渲染层读子会话最新一条 run 是 interrupted + 父侧无结果消息」）。现在 `interrupted` 只在 watcher 活着时产生（终态、或 run 行消失）；进程被杀之后，父会话没有结果消息，面板也不会自己去找。面板已经会列出**已落库**的结果（所以重启后能看见已完成的），缺的只是「那条子会话跑到一半、被启动清理落成 interrupted」这一种行的来源。
- `workspace_not_ready` 目前只覆盖「工作区行被删」，没有覆盖「runtime / host root 没起来」——后者要异步探一次 `WorkspaceToolsService.resolve`，等第一版真机上遇到再补。

### 10.4 一次评审改掉了什么（子代理评审本切片时抓到的）

- **结果写库不等于出现在屏幕上**：时间线只在 chat flow 自己写库时刷新（`externalWriteRevision`），所以 `addMessageDirectly` 之后要显式 `refreshTimeline`——和定时任务发布走同一条路（`scheduled_task_preparation_binding.dart:62-71`）。
- **`await_job` 曾在「已完成但还没写完」的窗口里返回空结论**：现在先写结果再翻状态；回归测试 `subagent_await_job_test.dart` 用 Completer 把那个窗口钉住。
- 群里不派：群会话没有单一 `assistantId`，子会话会退化成「当前选中的助手」。
- 侧边栏的 `子代理` 标签补上了（`_ChatTile`，草稿标签那个位置，中性色而不是主色）。
- 工具卡给 `delegate` / `await_job` 补了图标与标题（之前 `await_job` 会掉成 `Tool Call: await_job`）。


