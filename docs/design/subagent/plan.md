# 子代理实现计划（提案）

> ⚠️ **已过时，不要当作决策来源。** 决策在轮次产物里：UI 见 `m-all-ui-v2.html`，核心逻辑见 `n-core-pseudocode.md`，失败态见 `o-failure-states.html`。本文的 §9 只保留「哪一轮定了什么」的历史，§10 的实现状态表不再维护（现见 `n-core-pseudocode.md` §10）。
>
> 状态：**提案，待 clarity round**。分支 `feat/subagent-v4`，基线 `3c7e9b2b9`（master，含生图 job，#1096），schema 5。
>
> 本文只锁定**目标、范围、验收，以及已经影响决策的调研结论**。机制与 UI 是建议，不是决定；实现前在本 worktree 继续澄清（见 §9、§11）。
>
> 读完 §2–§4 就能开始澄清，不必重新调研。

---

## 1. 目标

让模型在正常对话里把一件自洽的任务**分派出去**，交给一个继承当前助手、当前工作区的子代理；子代理在自己的会话里跑完一整轮，父会话在调用点拿到结果。

不预设"被派遣的助手"：没有 handoff id、没有"可被委派"开关、没有目标助手配置。被派遣的是**本助手的一个分身**。

**看到效果 = 下面这一条端到端成立**：在一个普通 1:1 对话里，模型调用 `delegate` → 出现一个子会话并真的跑起来 → 父会话在工具调用处收到子代理的最终答复 → 子代理读写的是**父会话绑定的那个工作区**，不是助手默认工作区。不是"测试绿了"。

**本切片明确不做**：context injection / DSH prompt registry、Agent Teams / 任务板、workflow 引擎、外部后端（acp / codex / claude-code）、子代理之间的 `send_message` / `interrupt` / `list_agents`、子代理多轮续聊、群聊委派。

---

## 2. 这一轮真正要解决的问题

来自需求原话的四点，按重要性排：

1. **通用分派**：一个模型可以直接派任务，不需要事先把某个助手配置成"可被派遣"。
   → v3 的解法（`discoverable` + `handoffId` 目标助手）必须放弃。
2. **继承本助手**：子代理的模型、系统提示、工具集来自调用方，而不是另一个被选中的助手。
   → 目标侧配置面归零，只保留来源侧一个开关。
3. **工作区处置**：不能把任务扔到与当前会话无关的工作区。
   → 继承父会话的 `workspace.id` + `workspace.cwd` 快照；**不**走 `assistant.defaultWorkspaceId`。
4. **不升 schema**：`currentSchemaVersion` 仍是 5（`lib/core/database/app_database.dart:833`），`_validateRawSchema` 必须通过。

---

## 3. 现状（本地代码库已变，先读这一节）

master 已经合并生图 job（`3c7e9b2b9`）。它带来的不是"又一个功能"，而是**一套本仓库自己的 job 范式**，子代理应当沿用而不是另起一套。

### 3.1 已经存在、可以直接复用的

| 东西 | 位置 | 对子代理的意义 |
|---|---|---|
| job 契约：`id` 就是幂等键、状态最小、终态必写回 owner | `lib/features/image_job/models/image_job.dart:1-17`；`image_job_manager.dart:12-33` | "同一次工具调用永远同一个 job"这条不变量，子代理同样需要 |
| 幂等键组成（会话 + 消息 + toolCallId + 参数） | `image_job_coordinator.dart:230-243`、`:457-478` | 重渲染 / 重挂载不得再派一次、再花一次钱 |
| 模型两层解析（助手 → 全局），带"配对被删就回落" | `image_model_resolver.dart:1-110` | 文件头已经写明"同一规则服务所有 job kind（image today, delegate later）" |
| 局部工具按助手开关 + 工具箱三态 | `tool_handler_service.dart:700-748`；`local_tools_service.dart:795-834` | `delegate` 应沿用"局部工具"这一层，而不是全局开关 |
| 一轮生成的可复用接缝 | `chat_actions.dart:936-953`（`runAssistantTurn`） | 已经是"复用整条管线、只加作者与转写"的形状，但当前**绑死群聊参数** |
| 非当前会话的整轮 + 终态轮询 | `scheduled_task_runner.dart:101-186` | 程序化创建会话、启动一轮、按 generation run 判定终态的先例 |
| 工具级取消注册 | `ToolCallCancellation.current.onCancel`（`lib/core/services/api/tool_call_cancellation.dart:28-36`） | 父会话 Stop 必须级联取消子轮次 |
| 会话 extras 是既有扩展点 | `app_database.dart:88` 注释；`workspace_binding.dart` | 父子关系、工作区继承都放 extras，**不加列** |

### 3.2 已经存在、但需要小改的

- `ChatService.createConversation` 没有 `extras` 参数（`chat_service.dart:2142-2167`），只有 `newConversationExtras` 回调，而它走的是**助手默认工作区**。
  → 子会话要继承父会话绑定，必须在**同一次写入**里带上 extras；"先建后改"会留下一个没有父链接、没有工作区的孤儿窗口。
- `runAssistantTurn` 要求 `GroupChat group / members / spokeThisRound`（`chat_actions.dart:945-953`），子代理用不上这些。
  → 要么把群聊专属部分剥出去，要么子代理先走 detached 路径（`scheduled` 那条），之后再合并。这是工程选择，不是产品决策。

### 3.3 明确不存在

- 没有任何 `subagent` / `delegate` / `handoff` 代码（全仓 grep 为空）。
- 没有 `parentConversationId` 列（v3 的 v12 列在这里不存在），父子关系只能走 extras。
- 没有"完成后把结果送回父会话"的通用机制；`GenerationRun` 只记录单条消息的生成状态。

### 3.4 硬约束

- `AppDatabase.currentSchemaVersion == 5`；不新增表 / 列 / 索引；`chat_database_repository.dart` 的严格列序校验必须过。
- 不 patch `dependencies/markstream`。
- 新增用户可见文案走 ARB + `flutter gen-l10n`；不要手写生成物。

---

## 4. 调研结论（够用即止）

### 4.1 DSH：通用委派，靠 provider 而不是目标助手

- 工具配置的是 **backend（provider）**，不是某个助手；子代理默认加入父级当前 preset，只有显式 `agentPreset` 才独立。
- `cwd` 可省略：省略即捕获父级**当前目录**；相对路径按父级解析；子会话保留父的 origin metadata 与 permission roots；之后父级改目录不影响子级（快照语义）。
- 结果不是同步返回：工具只回 `started subagent <name>`，最终答复走完成通知；需要等待的程序消费方直接调 subagent service。
- 深度默认 **1**，到上限时工具仍在但每次 start 会被 provider 拒绝。
- `spawn`（干净子会话）与 `fork`（带父会话已完成轮次）是两个 provider，不是一个布尔开关。

→ 对本文的直接结论：**"继承本助手"是 DSH 的默认形态，不是特例**；工作区是"继承 + 快照"，不是"重新选择"。

### 4.2 Cuplivo v3.x：wait-only 是对的，目标侧配置是错的

- `dd4354cae` fire-and-forget → `b37eadb85` wait-mode（handler 层 await + live panel）→ `d9574c838` 合并成一个 wait-only 工具（ADR-0056：拒绝"一个工具 + `wait` 布尔"）。
- `5fb6b7686` 允许自委派，硬上限 `maxDelegationDepth = 3`。
- 代价：目标必须 `discoverable` 且有唯一 `handoffId`；来源还要开局部工具；"该开的都开了"却什么都不发生。工作区按**目标助手**解析，于是子任务可能落在与调用方无关的工作区——这正是本轮要修的问题。
- 持久化用了新列（`parent_conversation_id`、`handoff_id`），这里**不能**照抄。

→ 直接结论：**一个工具、一个词、一次语义**；目标侧零配置；深度必须有硬上限；父子关系走 extras。

### 4.3 生图 job：本仓库的 job 范式

- 状态只有 `queued → running → completed | failed`；**没有** `cancelled` / `interrupted`——没有入口的状态，是下一个人会相信并等待的表。
- 没有取消（界面上没有入口），没有并发上限；300s 只是"永远不返回"的兜底，不是"慢"的截止。
- `interrupted` 由渲染层从"持久化 pending + 无活 job"**派生**，不落库、不自动续跑。
- 终态一定写回 part；出站序列化跳过没有字节的图块。
- 重启不做任何落库改写。

→ 直接结论：**能给子代理的状态，只有能被某个入口产生或读出来的那些**；"中断"是读法而不是写法。子代理与生图的差别只有一处：**父会话有 Stop，所以这里确实有取消入口**，级联取消是必须的，不是可选的。

### 4.4 调研边界

三个来源已经足够支撑决策（DSH 的形状、v3 的教训、本仓库的 job 范式）。**不再扩展竞品清单**；只有 §9 某个待定项直接缺依据时，才补一条。

---

## 5. 建议方案（待 clarity round）

> 以下全部是建议。任何一条都可能被澄清推翻。

### 5.1 工具形态

一个工具，名字建议 `delegate`（模型可见名；中文界面叫「子代理 / 委派」）：

```jsonc
{
  "name": "delegate",
  "parameters": {
    "task":       "完整、自洽的任务说明；子代理看不到本会话的历史",
    "label":      "3–8 个词，作为子会话标题；省略则从 task 截取",
    "cwd":        "可选；只能是指向本会话工作区内部的相对路径"
  },
  "required": ["task"]
}
```

- **不暴露** `assistant` / `handoff_id` / `workspace` / `wait`。
- 返回建议：`{ "status": "completed", "conversation_id": "...", "output": "..." }`；失败返回结构化错误，不抛异常中断父生成。
- 一次调用一个子代理；不做批量。

### 5.2 子会话

- `createConversation(assistantId: 父会话的 assistantId, activate: false)`——同一个助手，不是"选一个目标"。
- extras 建议（全部 feature-prefixed，符合 `app_database.dart:88` 的约定）：
  - `workspace.id` / `workspace.cwd`：**从父会话复制**（见 §6）
  - `subagent.parent` / `subagent.root` / `subagent.depth`
  - 不复制 `tools.permission_mode`、不复制 `workspace.allowAll`
- 建议给 `createConversation` 加一个可选 `extras` 参数，让上面这些**一次写入**；不要"先建后改"。
- 子会话是普通会话：可打开、可继续、会进列表（是否加 badge 见 §9）。

### 5.3 一次子轮次

- 复用既有生成管线（工具、注入、checkpoint、取消、终态落库），不新建第二条。
- 子会话只额外获得两样东西：
  1. 一段很短的**委派指令**（"你是子代理；不要向用户提问；只返回最终结论；`/workspace` 与父会话共享，`/chat` 只属于你"）——这是每轮一次的短指令，不是 context injection 框架。
  2. 工具集的收紧（见 §5.7）。
- 结果取子会话最后一条非空 assistant 文本；父会话在工具调用处拿到它。

### 5.4 深度与并发

- 深度：`subagent.depth + 1`；默认上限 **1**（只允许直接子级），可配 0–3；到上限时**不把 `delegate` 放进子会话工具集**（省 token，也避免徒劳调用），若仍被调用则明确拒绝。
- 并发：建议 v1 **不设上限**，与生图 job 的理由一致——"莫名其妙被拒"比"模型连环调用"更伤；工具描述里写清楚"一次一个"。
  （若澄清选择设上限，也应是"能解释的错误"，不是静默排队。）

### 5.5 取消

- 父会话 Stop → 通过 `ToolCallCancellation.current.onCancel` 级联取消子轮次；父工具结果返回 cancelled，父模型可以继续。
- 子会话自己的 Stop 走既有 `cancelStreamingById`，不需要新机制。
- 与生图不同，这里**有入口**，所以取消是必须实现的；但仍然**不要**为此新增 `cancelled` 持久化状态——终态由 generation run 表达。

### 5.6 结果回传与呈现

- 父会话：工具卡显示运行中 / 完成 / 失败 + 打开子会话入口；wait-only 下这就是结果的位置。
- 子会话：普通聊天界面，流式输出。
- 不建议在父消息里再插一段摘要——那会变成"同一事实两处存放"。

### 5.7 权限与工具继承

- **不继承** `tools.permission_mode = fullAccess`，也不继承 `workspace.allowAll`（`WorkspaceBinding.applyTo` 已经会在换绑时剥掉，但复制时要显式说明）。
- 子代理默认**禁用**：`ask_user`（没人能答）、需要用户审批的工具（没人批准）、记忆写入（污染长期记忆）、`text_to_speech` / `phone_control` / 剪贴板写入（后台副作用）。
- 若子会话里仍有工具触发审批，建议直接返回可解释错误，而不是挂起——`scheduled_task_runner.dart:174-181` 已经为无人值守轮次定过这个调子（`user_interaction_required`）。

### 5.8 失败与重启

- 子轮次失败/超时：父工具返回结构化错误；子会话保留已生成内容。
- 进程被杀：子会话与已写消息都在；父侧工具调用没有结果 → 渲染层**派生**"已中断"，不自动重跑（沿用生图 job 的读法）。
- 同一 `toolCallId` 重入：内存 registry 直接返回既有子会话，不派第二次。

---

## 6. 工作区处置（这一节最不能错）

一句话：**子代理跑在父会话的工作区里，这是继承，不是选择。**

| 项目 | 子会话行为 |
|---|---|
| 默认 workspace | 复制父会话 extras 的 `workspace.id`；**绝不用** `assistant.defaultWorkspaceId` |
| 默认 cwd | 复制父会话的 `workspace.cwd`；为空则用 workspace 默认 cwd |
| 模型可选 workspace | **不允许**：工具没有 `workspace` 参数 |
| 模型可选 cwd | 只允许同一 workspace 内的相对路径；绝对路径、`..` 逃逸、符号链接逃逸拒绝 |
| full access | 不继承（同 §5.7） |
| 父级之后换工作区 | 不影响已创建的子会话（快照） |
| 父级未绑定工作区 | 子会话也不绑定；子代理没有工作区工具，工具描述要如实说明 |
| workspace 被删 / runtime 不 ready | 创建前早失败，返回可操作错误，不建"无工作区"的子会话 |
| `/workspace` | 父子共享；子代理写这里的文件父会话可见 |
| `/chat` | 每个会话独立（`WorkspaceToolsService.resolve` 用 `AppDirectories.sessionDir(conversationId)`）；子代理写 `/chat`，父会话看不到——必须在委派指令里讲清 |

为什么必须这样：

- `main.dart:275-283` 的 `newConversationExtras` → `workspaceExtrasForNewConversation` 走的是 `assistant.defaultWorkspaceId`。父会话手动切过工作区时，直接 `createConversation` 会让子会话回到助手默认工作区——**这正是"分派到无关工作区"的根因**。
- v3 的 `HandoffToolService` 用**目标助手 + 子会话**解析工作区，目标助手的默认工作区可能与调用方不同；v4 没有"目标助手"，继承的是调用方，这个问题从根上消失——但前提是 extras 真的复制了父绑定。

---

## 7. 验收

### 用户可见

1. 普通 1:1 对话里，模型调用一次 `delegate` 就能派活；**没有任何目标助手需要事先配置**。
2. 子会话真的跑起来并产出答复；父会话在工具调用处拿到它。
3. 子代理读写的文件出现在**父会话绑定的工作区**里（同一个 `workspace.id`），不是助手默认工作区。
4. 父会话 Stop 会停掉子轮次；不会留下一个还在烧钱的子代理。
5. 杀掉应用重进：子会话与已写内容都在；父侧工具卡显示"已中断"，不自动重跑。
6. 重复渲染 / 重新打开会话不会派第二次。

### 工程

- `AppDatabase.currentSchemaVersion == 5`；无新表 / 列 / 索引；`_validateRawSchema` 通过。
- 幂等、深度上限、工作区继承、无 fullAccess 继承、级联取消各有测试。
- `dart analyze --fatal-infos lib test` 干净；改动范围测试绿；用仓库固定版本的 Dart 格式化。
- 不改变生图 job 与既有工具行为。

---

## 8. 风险

| 风险 | 缓解 |
|---|---|
| 递归委派烧 token | 深度上限默认 1；到上限不注册工具；子会话工具集收紧 |
| 派到错误工作区 | 只复制父绑定；无 `workspace` 参数；创建前校验 runtime ready |
| 子代理写坏共享工作区 | 默认不继承 fullAccess；审批类工具在子会话禁用；工作区文件变更父会话可见 |
| 父会话等结果时"卡住" | 这是 wait-only 的固有代价，必须在工具描述里说清；异步通知是后续切片，不是 v1 |
| 子代理提问/审批无人应答 | 子会话禁用 `ask_user` 与审批类工具，返回可解释错误 |
| 重启后父工具调用悬空 | 渲染层派生"已中断"；不自动重跑；子会话内容仍可读 |
| 重复派活 | 幂等键 = 父会话 + 消息 + toolCallId（沿用生图 job 的规则） |
| 子会话污染会话列表 | 是否 badge / 是否折叠，见 §9；v1 建议可见 + badge |

---

## 9. 已锁定的决定（clarity round 五轮，2026-11-21）

产物在 `docs/design/subagent/`，按轮次 `a-*.html` … `i-*.html`。每轮只定一件事；下面是被你否掉又被你改对的那些，按最终结论记。

| 轮次 | 结论 | 产物 |
|---|---|---|
| 1 | **异步**：工具立即返回 `started`，父会话继续调它自己的工具、继续写。wait-only 被否——它的前提是"父会话被挡着"，而这个前提本身就不该有。 | `a-wait-only.html`、`b-async.html` |
| 2 | 结果**落成一条消息**，不留在卡里。 | `c-card-and-brief.html`、`d-result-message.html` |
| 3 | 消息身份 = `role: 'user'` + **`SubagentResultPart`**（身份在 part，不在 id；id 只是由子会话 id 算出的确定性 UUID，用于去重）；时间线上**画成分隔线**，不画成一条回复。 | `e-result-divider.html`、`f-result-as-reply.html`、`n-core-pseudocode.md` |
| 4 | 输入框上方**一条汇总**，不是一个一行。 | `g-strip-summary.html`、`h-strip-rows.html` |
| 5 | 结果传播到主对话之后，**由事件唤醒**：用户发消息、或子代理 job 完成，都会续写一轮。顺序是 `assistant → 子代理完成（分隔线）→ assistant`，**不是** `assistant → user → 完成 → assistant`。（第 5 轮先记成「不唤醒」，第 7 轮更正。） | `i-wake-or-not.html`、`l-still-waiting.html` |

### 9.1 这五轮顺带定下的（不再作为建议）

- **工具卡不显示任何状态**：没有转圈、没有时长、没有勾，就是 `派遣子代理：<label>` 一行。**状态只有一处**——输入框上方那条。
- **两种事件都会唤醒续写**：用户发消息、子代理 job 完成。都不是"主代理自己想起来"，是事件把它叫醒。
- **条上不用扫光渐变**：`子代理运行中 (13.3s) 修复 test/auth`——括号里是已跑时长，照生图卡头 `生成插图 (12.6s)` 的写法；静止文字，不动画。
- **面板排序按 `createdAt` 从新到旧**，每行显示 **duration** 而不是调用时刻（用户不关心子代理是几点被叫起来的）。
- **四种状态**：等你回答 / 等待批准 / 正在运行 / 已完成。前两种是「要你做点什么」，颜色**从主题派生**，不写死琥珀色（用户主题可能不是蓝的）。
- **子会话标题栏不改**：手机与桌面的第二行已经是「模型 (provider)」（`home_mobile_layout.dart:218-238`），没有地方再塞一行副标题；`子代理` 标签只出现在侧边栏行和面板里。
- **「子代理完成」与「用户同时在说话」不做抢占规则**：两者同时发生很少见，真碰上就各自按既有规则走。
- **插入时机**：父回合在跑时，结果排队到当前 tool call 结束、在下一个 step 的边界插入（不打断）。
- **工具卡不覆写渲染**：`delegate` 就是 `_ToolCallItem` 的一行，标题 `派遣子代理：<label>`，不加计时。覆写先例（`_AskUserToolCard`、`WorkspaceToolCardBody`、详情页的 weather/screenTime）都是"卡还是那张卡，只换里面"，这里连里面都不用换。
- **`label` 由主代理传入**，3–8 字；工具描述里写死这条；没给时截 `task` 首句、最多 12 字。
- **运行态在输入框上方**，位置与数值照 `ContextTaskBar`；文案 `N 个子代理（M 个正在运行）`，只有一个时直接写 `label`。
- **侧边栏**：单行、不缩进、不画时间（`_ChatTile` 本来就没有时间），`子代理` 三个字放 `composerDraftLabel` 的位置。跳转放在面板里，不建父子链。
- **配置**：工具箱里一行 + 概要，点进去一个弹窗，只有 **深度** 与 **模型**；「完成后」不设——它就是"落一条消息"，没有第二种选择。
- **模型 v1 不持久化**（继承父助手）。预留位不是新表新列：`Assistant` 是 JSON，加同级字段 + 全局默认，复用 `ImageModelResolver` 的两层解析，schema 仍是 5。
- **`ask_user` 与审批类工具不禁用。** 异步之后子会话是能交互的真会话，`ask_user` 在那里就是一张普通提问卡；父侧只显示"它在等你回答"，**不做透传**（透传要在父会话再造一张卡，还要回答"父回合已经结束了，这张卡算谁的"）。
- **没有"简报注入"这一层。** 结果既然是一条 `user` 消息，它本来就在历史里，模型下一轮自然读到——注入一次再清掉的那套机制不需要了。

### 9.2 仍然待定（不阻塞 v1）

- 并发上限（建议无上限，与生图 job 同理）。
- 子代理允许的工具集：黑名单还是白名单（建议黑名单）。
- 子会话是否参与 LAN sync 与备份（它们是普通会话，默认会）。
- 面板的内容与排序（已定按 `createdAt` 倒序，见 9.4）。
- 深度 > 1 时的嵌套表现。

### 9.4 失败态（第 8 轮，非阻塞轮 `clarity-mwq7dfg2-69dc70`，已过）

- **失败也唤醒**：分隔线之后主代理说一句「它没做成，原因是…」；工具描述里写死「失败就直说失败，别替它圆场」。
- **条只留「需要你」的**（等你回答 / 等待批准）；失败、取消、中断一律从条上消失，终态归分隔线。
- **分隔线四种形态同一行**：完成 / 失败 / 取消 / 中断，只换图标和动词；**只有失败用红**，取消与中断保持中性（不是错误，是用户或系统让它停的）。
- **不给重试按钮**：重来是模型的决定——在父对话里再说一句就是。
- **「已中断」读落库的事实**：启动清理已把那条 run 落成 `interrupted`（`errorCode = app_restart`），不是「读不到就算中断」。

### 9.3 流程上的两条

- **动工前要把所有涉及的 UI 放一页里过目**（输入框与条、工具卡与分隔线、侧边栏、配置弹窗、面板、子会话自身）。这是你提出来的，别再拆散了看。
- 澄清就在本 worktree 继续：每轮一个决策、一个产物文件、一行结论；未锁定不进实现。

---

## 10. 实现状态（2026-11-21 起）

伪代码轮通过后开始落地，按「每步能单独编译」的顺序：

| # | 步 | 状态 | 落点 |
|---|---|---|---|
| 1 | 结果消息的 part 类型与确定性 id | **完成** | `lib/core/models/message_part.dart`（`SubagentResultPart` + `messageIdFor`）；`test/core/models/message_part_test.dart` 两条新用例 |
| 2 | `createConversation` 能在同一次写入里带 extras | **完成** | `lib/core/services/chat/chat_service.dart`（`extras` 参数；`ToolPermissionMode.withoutGrant` 做唯一收口） |
| 3 | 纯规则：extras / 深度 / 标题 / 简报 | **完成** | `lib/features/subagent/services/subagent_rules.dart`；`test/features/subagent/subagent_rules_test.dart` 12 条 |
| 4 | 协调器：幂等 begin / 盯 `GenerationRun` / 写结果 / 唤醒 | **完成**（未接线） | `lib/features/subagent/services/subagent_coordinator.dart` |
| 5 | 把协调器接上宿主 | **完成** | `main.dart` 提供 `SubagentCoordinator`；`HomePage.initState` `attachHost(_controller.buildSubagentHost())`，`dispose` 摘掉；三个适配器在 `HomePageController`（`startSubagentTurn` / `wakeAfterSubagent` / `buildSubagentHost`） |
| 6 | `delegate` 工具：名称、schema、handler、l10n | **完成** | `local_tools_service.dart`（`delegate` + `delegateDefinition`）、`local_tool_labels.dart`、`tool_handler_service.dart`（照 `generate_image` 那一段）、`chat_message_widget.dart` 的工具卡标题；ARB 两个键 + `chatMessageWidgetDelegate` |
| 7 | 渲染：结果分隔线 + 输入框上方的条 | **完成** | `lib/features/subagent/widgets/subagent_result_divider.dart`（28px，只换图标与动词，只有失败用 `cs.error`）、`subagent_task_strip.dart`（接在 `chat_input_section.dart` 的 `ContextTaskBar` 之后）、`message_part.dart` 的 part 增加 `label` / `outcome` |
| 8 | 序列化：`message_builder` 与 `isUserInputMessage` 认得新标记 | 待做 | `message_builder_service.dart:653-665`、`request_image_context.dart:35-49` |
| 9 | 面板（点条/分隔线打开）与「等你回答」状态 | 待做 | 分隔线现在**没有** chevron、也不能点——「看起来能点却点不动」比一条纯线更糟；面板落地时一起接 |
| 10 | 助手编辑器里的「子代理」配置弹窗（深度 / 模型） | 待做 | 工具箱行已经出现（`all` 集合驱动），但只有开关 |
| 11 | 剩余不变量测试（幂等、深度、无授权、终态写回）+ 分隔线的 widget 测试 | 待做 | — |

门禁（每步都跑）：`dart analyze --fatal-infos`（本地 Dart 与 CI 同为 3.13.0），改动范围的 `flutter test`。

**一条安全事实**：`Assistant.localToolIds` 默认是空列表（`assistant.dart:151`），所以 `delegate` 默认关闭——在分隔线渲染出来之前，用户不会突然看到一条英文 `user` 气泡。

### 10.3 part 为什么带 `label` 与 `outcome`

结果消息的正文是给模型看的英文简报，不是给界面看的：如果分隔线从简报里解析「子代理完成 · label」，改动一句措辞就会让渲染断掉。所以身份和展示数据都在 part 上——`childConversationId`（身份）、`label`（三处一致的短名）、`outcome`（`completed|failed|cancelled|interrupted`）、`elapsedMs`（面板用）。未知的 `outcome` 一律渲染成「完成」的中性样式，不允许把一个陈旧值渲染成错误。

顺带：`messageIdFor(childConversationId)` 用 UUIDv5，所以同一个子会话的结果消息**只会有一行**；这不是分支逻辑，只是去重。

### 10.1 接线时踩到的第一条硬事实

**`HomeViewModel` 不是 provider**——它由 `HomePageController` 在 `HomePage.initState` 里 `new` 出来（`home_page.dart:539`、`home_page_controller.dart:914`），`context.read<HomeViewModel>()` 拿不到。所以协调器不能在 `main.dart` 里就把「怎么起一轮」接上。

结论：**协调器由 `HomePage` 提供**，不是 main。它构造时就要求两个适配器（`turnStarter` / `parentWaker`，都是必填，没有「未接上」这个中间态），而 HomePage 手里正好有 `_controller`：

- `turnStarter` = `_viewModel.sendScheduledMessage(...)`，取 `ChatActionResult.generationRunId` 包成 `SubagentTurnStart.started`；`inFlight` 之类拒绝包成 `.refused`。
- `parentWaker` = `_viewModel.regenerateScheduledMessage(message: 结果消息, ...)`——结果消息是一条还没有回复的 `user` 消息，所以这一步就是它的第一版回复。
- `canWake` = 该会话不忙且无草稿。注意 `HomePageController` 现在只有 `isCurrentConversationLoading`，要加一个按 id 的版本。

工具 handler 的 `contextProvider` 在 HomePage 之下，所以 `context.read<SubagentCoordinator>()` 拿得到——和 `imageJobCoordinatorOf` 完全同一种用法，但提供点在 `main.dart`、适配器由 `HomePage` 挂上（提供点必须在 HomePage 之上，否则从 `_context` 读不到）。

### 10.2 工具契约里写死的三句话

`delegateDefinition` 的 description 只强调三件事，因为模型在这三件事上都会错：子代理看不到本对话（task 必须自足）、调用立刻返回而**不是**结果（不许说「已完成」）、一个任务只派一次（不许重复调用）。参数只有 `task` 与 `label`，`label` 是必填——它同时是卡片标题、条上的文字和新会话的标题，三处必须一致，所以由 `childTitle()` 一处生成（`chat_message_widget.dart` 的卡片标题也走同一个函数）。

`cwd` 参数推迟了：v1 只做「继承父会话的 workspace」，不做「在工作区里再选一个子目录」——后者要先把路径安全做对（相对路径、不许 `..` 逃逸、符号链接），不值得挡在第一版前面。

---

## 10. 资料

外部（已读过，够用）：

- DSH 子代理子系统：`deepseek-harness/docs/subsystems/subagent.md`；工具契约 `packages/subagent/tool-subagent/README.md`（`cwd` 继承、`maxDepth` 默认 1、`spawn`/`fork`）
- DSH 运行上下文原则：`docs/subsystems/system-prompt.md`（动态上下文是 user-role snapshot，变化才追加；本轮**只记原则，不实现**）
- Cuplivo v3：`v3.2.1:docs/adr/0026-wait-mode-handoff.md`（wait-mode、级联取消、双可见审批）、`0056-subagent-wait-only-unification.md`（单工具、统一措辞、不做迁移）
- v3 深度上限：`v3.2.1:lib/features/home/services/handoff_tool_service.dart`（`maxDelegationDepth = 3`）

本仓库（实现时直接读）：

- `lib/features/image_job/`（job 范式）
- `lib/features/home/controllers/chat_actions.dart:936-953`（一轮生成的可复用接缝）
- `lib/features/scheduled_tasks/scheduled_task_runner.dart`（程序化建会话 + 整轮 + 终态）
- `lib/core/models/workspace_binding.dart`、`lib/core/services/workspace/workspace_tools_service.dart`（工作区解析）
- `lib/features/home/services/tool_handler_service.dart:700-748`（局部工具的接线方式）
- `lib/core/database/app_database.dart:88`、`:833`（extras 约定、schema 5）

---

## 11. 变更控制

- 本计划只承诺**一个垂直切片**：在普通对话里派一次活、子代理在父工作区跑完、父拿到结果。任何新增范围默认拒绝，除非 clarity round 明确纳入。
- 澄清就在**本 worktree**继续：每轮一个决策、一个产物文件、一行"已锁定决定"；未锁定的项不进实现。
- 调研已到"够用"边界：新资料只有直接影响 §9 待定项时才引入。
- 若实现中发现 extras 放不下父子关系或工作区继承，先回到 clarity round，**不在实现中顺手加列**。

---

## 12. 已锁定决定：子会话的简报与留言（2026-11-23）

本轮把 `plan.md:21` 推迟的两件事纳入：子会话的**简报**（`subagent:delegation` 节的移植）与 `send_message` / `interrupt`。`list_agents`、fork、深度 > 1 仍不做。三次 clarity round 的结论：

1. **队列本身变成 steer，人与代理同一条规则。** 发送即写行；对话能生成就开一轮，正在生成就在下一个步骤边界结束这一段、用留言开下一段。设计见 `ze-steer-turn-split.md`。
2. **手递手切一个新 run。** 段 A 收口为 `completed`，段 B 是新 run、从历史重新装配请求；`run ↔ assistant 行` 保持 1:1，7 处 adapter 插入与 provider 相邻规则都不需要。代价是「一轮 = 一串 run」：loading 连续、排空判断、子代理监视、终态读取都按轮看。被否的备选见 `zf-same-run-multi-row.md`。
3. **压缩与生成的统一不在本切片**（`ze` §10）：它会把 `blocksSending`、`_pausedQueuedInputs`、composer 暂停锁与侧栏徽标一起删掉，但属于下一片。
4. 结果行改为**每一段一条**（`messageIdFor(childId, runId)`）；面板最新优先；导出与 PDF 本来就按行处理，只有面板的 `known` 去重需要改。
5. 子会话**不能**再委派（深度 1 不变）；它拿到 `send_message`，仍没有 `delegate` / `await_job`。

调研：`zd-dsh-port-research.md`（DSH rc.5 源码：context injection 与 subagent communication 两套机制、可移植 / 不可移植清单、Cuplivo 管线与步骤边界、实现 steer 的八个隐患）。

实现顺序（按层，每层可独立合入，编译与测试每层都要绿）：

1. 留言 part（`SubagentMailPart`、`isUserInputMessage` 分支）与简报文案（`message_builder_service.dart:2250-2259`）。
2. 三个工具与协调器：`send_message`（父 / 子两种说明）、`interrupt`、`stopped` 阶段、续聊、按段的结果行、按轮监视。
3. 收件箱与手递手：`RequestHistoryContext` 的 `takeHandoff` 回调、`tool_loop_runner` 两个边界、`chat_actions` 收尾与段启动、`home_view_model` 忙分支与排空。

未锁定的项不进实现：`waitingTool` 的写入、压缩统一、打断纯文本回复、fork、深度 > 1、`list_agents`、命名与目录。

### 12.1 实现记录（2026-11-23）

已落地，`dart analyze --fatal-infos lib test integration_test` 干净，相关测试 246 条通过：

- **简报**：`message_builder_service.dart` 的 `_subagentPrompt` 换成 `_subagentBrief`（身份、来源规则、回报契约、不可再委派），仍归 `ContextSource.systemPrompt`。
- **留言消息**：`SubagentMailPart`（`from`、`senderConversationId`、按 sender + toolCallId 派生的行 id）、`subagentMailKey`、`isUserInputMessage` 排除、OpenAI 序列化前剔除。
- **工具**：`send_message` 两套 schema（父带 `job_id`，子只带 `text`）、`interrupt`；子会话拿到 `send_message`，仍没有 `delegate` / `await_job`；三者随 `delegate` 一格开关，不进 Local tools 标签页。
- **协调器**：`sendToChild` / `sendToParent` / `interruptChild`；`stopped` 阶段（模型的 interrupt 可续，用户的 Stop 仍是终局）；按轮串监视（`latestGenerationRun` + `isTurnRunning` + `hasPendingMail`）；每段一条结果行（`messageIdFor(child, runId:)`）；面板最新优先。
- **手递手**：`RequestHistoryContext.takeHandoff` + `handoffRequested`；`tool_loop_runner` 两个入口在 `append` 之后结束这一段并 `finish()`；`chat_actions` 收尾时启动下一段且不发布 idle；`home_view_model` 的 `takeHandoff` / `onHandoffRequested` 与 mail 收件箱、排空优先。

**与设计的偏差（要做完的下一片）**：

1. **人的消息还不是「发送即写行」**：忙时仍入 `_queue`（`QueuedUserInput`），只是投递时机从轮末提前到步骤边界。行在开段时才写，所以 composer 仍会在排队时锁定、仍显示排队 chip。要删掉这两处 UI，需要一条「把 `ChatInputData` 构造成持久行」的路径（复用 `beginUserMessage`，处理附件 / 引用 / 版本）。
2. **`stopped` 没有自己的文案**：面板与分隔线暂用 `subagentPanelCancelled` / `subagentResultCancelled`，因为新增 l10n 键要走翻译管线与指纹门禁；补两个键是独立的小改动。
3. `_pausedQueuedInputs` 仍有「排队失败」与「压缩审查」两个来源；压缩统一是下一片。

**review 后的修正（同日）**：

- 留言行在 `userTurnsFor` 与 `latestUserId` 两处也被排除——此前它们只排除 result part，导致留言行成为「用户最后一轮」，人先前附的图片会被预算驱逐（新增回归测试）。
- 续聊的 20 秒 `turn_not_started` 不再在留言仍排队时触发：排队（后台、压缩审查）不是失败，等在队列里才是答案；只有留言已被取走却没有 run 时才报失败。
- 面板：`stopped` 有自己的阶段映射；同一子会话多段结果取**最新**一条，不再被最旧的一条占位。
- 留言行只存正文，模型看到的「The delegator sent a message:」在装配请求时加；界面用独立卡片（发送方标题 + 正文），导出不再带英文前缀，也不需要新的 l10n 键。
- `interrupt` 增加与 `send_message` 相同的父子校验（处理器传 `parentConversationId`）。
- 删除 review 留下的 `probes/` 目录。

**结果行与留言行的最终形态（第二轮 clarity）**：

- 结果行只在**模型没有通过工具调用拿到结果**时出现：`await_job` 由 `waiters` 抑制；模型 `interrupt` 成功也不写行、不唤醒——它只回 `accepted`，不回传内容，打断就是说到哪算哪，想要结论用 `await_job`，想让子代理尽快收口用 `send_message`。
- 用户停止子代理：写分隔线，不唤醒父对话（用户刚按了 Stop，再生成一轮与意图相反；线已在历史里，下次发言时模型读得到）。父对话自己的 Stop 级联同样不唤醒。
- 留言行不再是独立卡片：与结果行共用同一条 28px 分隔线（`subagentMailLabel` + 发送方标题），正文跟在下面；点分隔线打开 dialog（桌面）/ sheet（移动）看完整消息。导出与 PNG 走已有的分隔线分支，因此不再出现"导出里认不出留言"的问题。
- 新增 l10n 键 `subagentMailLabel`（6 个 ARB + 指纹 + `gen-l10n`，`translate.py check` 通过）。


