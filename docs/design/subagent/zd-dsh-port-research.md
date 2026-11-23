# DSH 移植调研：context injection 与 subagent communication

2026-11-23。三路只读调研的摘要，供「子会话的简报与留言」一轮（`zb` / `zc`）使用。读的是源码与落地提交，不是 README；每条结论带 `路径:行`。

## 0. 范围

- DSH 源码：`D:\Projects\deepseek-harness`，HEAD `2e39e70496`（2026-11-18，0.2.2-rc.5）。本机运行的 dsh 是 0.2.2-rc.1（`66491b05e3`），比 HEAD 旧：`27716078ef`「discover and message the entire Team」不是 rc.1 的祖先。两版只在寻址模型上不同（§2.2 D），其余机制一致。
- Cuplivo：`91125981f`（#1108），`feat/subagent-context-communication` 起点干净。
- DSH 路径缩写（均在 `packages/` 下）：S = `subagent/subagent/src`，T = `subagent/tool-subagent/src`，C = `subagent/tool-subagent-control/src`，A = `core/agent/src`，L = `core/agent-loop/src`，SP = `core/system-prompt/src/index.ts`，RC = `core/agent-loop/src/runtime-context.ts`。

## 1. DSH 的 context injection

### 1.1 地图

| 机制 | 位置 | 落地提交 |
|---|---|---|
| 两个注册表：`PromptSection`（系统提示）、`PromptContext`（运行上下文）；`SECTION_ORDERS` / `CONTEXT_ORDERS` | SP:53-90, 136-187, 622-697 | `d02e9f1bd6` |
| 每步钩子 `agent/pre-step` 瀑布 + 终端快照 | L/agent.ts:289-323, 441-484 | `d38c8bfaf3` |
| 快照投影：取景、相等去重、被遮后重发 | RC:74-180 | `d38c8bfaf3`、`ce85be0a44` |
| 投递模式 `inject` / `steer` / `followup` 与持久收件箱 | A/runtime-types.ts:245-271；L/inbox.ts:26-231 | `26a117f842`、`1101422362` |
| 消息来源的生产者 `form` | `llm/llm/src/message.ts:54-100` | `340c9ba576` |
| AGENTS.md 发现、渲染、对账 | `context/agent-instructions/src/{files,render,state}.ts` | `c8cc087e05` |
| 技能目录（digest 门控重发） | `skill/tool-skill/src/index.ts:218-256, 382-399` | `6292d52236` |
| 时间提醒（限频） | `context/time-context/src/index.ts:55-56, 209-214` | `a9d74932b1`、`760dd8f5de` |

### 1.2 它实际怎么做

1. **拼装**。系统提示 = `PromptSection{name, order, text|fn}` 按 `order` 再按名字排序，`\n\n` 拼接；层序固定（身份 −1000 … 工具指引 1000–3000 … 杂项 … 人设后缀 10200）。运行上下文 = `PromptContext` 求值成 `{name, text}` 节，顺序 WORKING_DIRECTORY 100 → SANDBOX 110 → APPROVAL 115 → SUBAGENT_DELEGATION 120 → …。agent 级条目按名覆盖全局条目。
2. **每一步**（`L/agent.ts:293-312`）：`claimed = inbox.claim()` → `assemble()` → `agent/pre-step` 瀑布；约 20 个监听者各自改 `decision.messages`，先注册的在外层；终端渲染各节并返回 `[...claimed, snapshot]`。入请求前的顺序：本轮输入 → 指令文件（插在最后一条输入之后）→ 运行时快照 → 技能目录 → 技能正文 → 时间（`prepend`，所以最后）。
3. **「快照取代旧快照」的真实含义**（RC:134-180）：**只追加、相等去重**。投影记住最新一条的 seq 与内容；`deepEqualJson` 相等就什么都不发；变了就**追加**一条带「It replaces earlier versions of this context, including any retained in conversation summaries.」导语的 `<system-reminder>`。旧的那条留在历史里，直到压缩把它遮住；被遮住后下一步重新发。清空时发一条 `CLEARED`。**没有通用的「按 id 替换上一条」**——只有收件箱里未投递消息的 `replace(id)` 和 system 节点的替换。
4. **归因**：消息 `source{kind, form, …}` 由生产者声明（`instructions|snapshot|catalog|notice|relay|recall`），UI 直接按 kind 画，不解析文本。
5. **去重没有框架**：每个生产者自己做（快照 deepEqual、目录 sha256、指令 digest）。
6. **AGENTS.md**：全局（`<DSH_HOME>/AGENTS.md`）→ 项目根（向上找 `.git`）→ cwd 逐层；每层 `AGENTS.md`、`CLAUDE.md`、`.local` 覆盖**都加载**；同组 trim 后 SHA-1 相同的丢弃；每链 64 KiB，超了先丢最宽的再截最具体的；工具改了文件就按 scope 对账（version 未变且 digest 等于已见 → 不读）。「More specific instructions take precedence…」只是散文，代码里的优先级 = 顺序 + 预算。
7. **技能目录**：每步评估；首次发，之后只在 digest 变化或被压缩驱逐时重发「This complete catalog replaces every earlier…」。
8. **预算**：快照与目录没有 token 上限，只有指令文件有字节上限。

### 1.3 可移植 / 不可移植

**可移植（想法 → Cuplivo 落点）**

- 静态契约进系统提示，动态事件进对话记录：DSH 给子代理的身份与回报规则是一个 system 节（S/child-agent.ts:171-208），任务、转向、进度、结果全是 user 角色消息。「变化才追加」对 Cuplivo 的含义是：**子会话里会变的只有事件，而事件本来就是消息行**——不需要快照机制。
- 生产者声明的消息种类：Cuplivo 的对应物是 `MessagePart` 的 kind（`subagent_result`，以及要加的留言 kind）；`isUserInputMessage` 已按 part 判定。
- 「发消息 ≠ 回答」：`send_message` 只回 `{messageId}`。
- 「digest 变了才重发」的节：Cuplivo 已有 `injectSkillsPrompt`，不在本轮。

**不可移植（聊天客户端里的死重）**

- cwd / 工作目录、沙箱策略、审批策略、委派深度作为运行上下文节；每工具指引；MCP 清单；`{{cwd}}` 变量；`complete` 节。
- 事件溯源的 surface / 压缩遮蔽 / 重发机制：Drift 历史只需要追加。
- AGENTS.md 的目录层级：Cuplivo 没有「项目根」；助手的 system prompt 与 `injectInstructionPrompts` 已是它的指令来源。

## 2. DSH 的 subagent communication

### 2.1 地图

| 机制 | 位置 | 落地 |
|---|---|---|
| `subagent` 工具（`subagent_fork` = 同一工具绑到 fork provider） | T/index.ts:208-338 | `99a778d63f`；默认后台措辞 `8344d64363` |
| fork 切片 / spawn | `subagent/subagent-fork-in-process/src/index.ts:46-79`；`subagent-spawn-in-process/src/index.ts:38-55` | `7aabd2a3df` |
| 服务 `ctx.subagents`；manager（树、创建、投递、结算、通知） | S/index.ts:194-602；S/manager.ts:139-1371 | `26a117f842` |
| 子会话头、组合继承、`subagent:delegation` 节 | S/child-agent.ts:49-58, 98-119, 143-208 | `26a117f842` |
| 收件箱消息形状（任务、结算、停止通知） | S/continuation-messages.ts:64-176 | `99a778d63f`、`76cf6cbd0b` |
| `send_message` / `interrupt_agent` | C/index.ts:44-85, 125-163；S/manager.ts:198-232 | `99a778d63f`、`d769d3cbb7` |
| `list_agents` / `wait_agent` | C/list-agents.ts:12-93；C/wait-agent.ts:26-117 | `4240c7dd7b`、`aa6a4249b8` |
| 收件箱队列 nextTurn / nextStep 与排空 | A/runtime-types.ts:75-136；L/agent.ts:157-257, 333-439 | — |
| 设计记录 | `docs/subsystems/subagent.md`；`.agents/notes/implemented/feature/2026-07-28-continuable-subagent-conversations.md` | — |

演进顺序值得记：06-22 spawn/fork → 07-23 可续聊 + `send_message` + 冷恢复 → 07-26 目录 + `list_agents` → **07-30 「Agent inbox is the only turn FIFO」** → 08-06 祖先可中断 → 08-11 默认后台 + 「最终报告是返回契约」→ 10/11 团队、命名。

### 2.2 怎么工作

- **A 树**：没有节点类，身份就是 `SessionId`；子会话头带 `parentSession`、`delegationDepth`、`origin:'subagent'`。持久树 = 父日志上的 `subagent/catalog` 事件 + 子日志上的 `subagent/descriptor`。活动状态只在进程里（`resident: Map<SessionId, Activation>`，「never durable」）。「resident continuable child」= 有 Activation 的子会话；冷的子会话只剩持久 Session，按需恢复（HEAD 允许，rc.1 只允许 resident 的子向父发消息）。
- **B 创建**：同进程新 Session。工具返回 `{kind:'activation', name}`——在子收件箱**接受**任务之后；永远是后台，没有 `background` 参数。子会话得到：任务（user 消息，署名父代理 + 指引）、父的**组合**（同一套 system 节 / 工具 / 技能）外加 `subagent:delegation` 节、父的模型（除非覆盖）、沙箱与权限预设。fork = 切到最后一个 `turn/end` 的全部事件（没有完成的轮次则为空），只切一次。孙辈：`parent.depth+1 <= maxDepth`，默认 1。**深度不撤工具**——提示里写「Do not call `subagent` at this depth」，调用抛 `DEPTH_EXCEEDED`。
- **C 结果**：工具结果只是「已启动」。完成 = `notifySettlement`（S/manager.ts:1124-1146）把一条 **user 角色消息插进父收件箱**，`source.kind:'subagent-settled'`：父空闲 → `followup`（开新一轮）；父在工作 → `steer`（下一步）；树在排空 → `inject`（不唤醒）。正文「Background subagent X finished and will do no further work unless you send it more.」+「Its closing message:」+ 纯文本输出。结果 = 最后一条非空 assistant 消息，否则累计流文本。另有 `subagent/end` 事件给 UI/SDK，不是工具结果。
- **D `send_message(agent, message)`**：地址 = `lead` / 斜杠路径 / SessionId。包装成「Agent <sender> sent a message: 」+ 内容，`source.kind:'agent-message'`，投递 `steer`。发送者拿回 `{messageId}`，无幂等。**排空规则**：`steer` = `send(msg,'next-step', wakeup=true)`；工作中的目标在**下一步边界**排空——一步结束后模型想收尾但 `nextStep` 非空，就再开一步（L/agent.ts:401-406）；空闲目标被唤醒，第一步领走它（:235-257）。取消期间到达的唤醒输入改道到 next-turn。**配对**：HEAD = 一棵树内任意成员 ↔ 任意成员；rc.1 = 父→直接子，子→直接父（且发送者须是 resident）。子→父的留言会把结算通知的 closing text 省掉（`omitClosingText`）。
- **E `interrupt_agent`**：`{accepted:true}` 立即返回。本地子：`agent.cancel(keepInbox:true)`——中断当前轮，两条队列都留着，状态回 idle，以后一条 steer 就能唤醒。外部后端：永久。后代不受影响。通知「Background subagent X was stopped before it finished.」，stopReason `aborted`。
- **F `list_agents`**：HEAD 列全树可达的可续后代（前序），状态 `running|inactive|corrupt|unsupported|unavailable`；一次性 / 外部的省略。
- **G 生命周期**：`AgentStatus = idle|running`；`SubagentStopReason = completed|aborted|error|max-tokens|refusal`。结果存活于父 transcript 的结算消息、子的持久 Session 和 `subagent/end` 载荷。

### 2.3 提示契约（原文，移植时照抄改写）

- 「The subagent returns its result, not its intermediate steps.」
- 「This tool starts an independently managed subagent and immediately returns its name. If you are still online when it finishes, the runtime automatically delivers its completion notice. The notice includes the final answer unless the child sent you a message just before finishing.」「Use `send_message` to steer it while running or continue its conversation after it finishes.」
- 「When only waiting for their results remains, end your turn instead of sleeping or polling; the next result starts a new turn.」
- 子会话看到：「When you finish, use send_message to send a self-contained result to the agent that delegated you. Message any agent as soon as a finding changes what it should do next; sending a message does not end your turn.」「Your final answer is delivered automatically if your parent is still online. Include the result and relevant evidence in that answer; the parent does not receive your full transcript, tool output, or reasoning.」
- 「Messages from other agents begin with "Agent <name> sent a message:". Other user messages come from the human user, who reads this conversation directly.」
- 「Send a message to an agent. A working agent receives it at its next step; an idle agent starts a new turn with it.」
- 「Ask a subagent to stop its current work. This call returns without waiting for it to stop. You can continue a local subagent's conversation later with send_message. … Subagents it started will keep running.」

### 2.4 可移植 / 不可移植

**可移植**

- 一个收件箱、两种投递：nextTurn（一轮一条，唤醒空闲者）/ nextStep（下一步边界排空）；「工作中 → 下一步，空闲 → 新一轮」。
- 发送回执 ≠ 回答。
- 结算 = 运行时署名的消息进父收件箱，按父状态选投递方式。**Cuplivo 已经是这条路的 nextTurn 版**（结果行 + `QueuedSubagentResult`）。
- 中断保留收件箱 → 可续。
- 结果 = 最后一条非空回复；停止词汇 completed|aborted|error|max-tokens|refusal（Cuplivo 的 `GenerationRunState` 已一一对应）。
- 深度在起点拒绝 + 提示里说，不靠撤工具。

**不可移植**

- ActivationPool、ChildLock、runMaintenance、whenIdle 监视；外部 provider（ACP / Codex / Claude-Code / SDK）；Cordis 事件；沙箱 / 审批钉死；会话持久化与冷恢复的日志机制；`job_output` / lane 词汇（HEAD 已不用）。
- 命名（`lead`、斜杠路径）与目录：只在深度 > 1 时有意义；Cuplivo 的 `extras` 已带 parent / root / depth，`job_id` 就是地址。
- 全树寻址、兄弟互发：深度 1 下没有兄弟。

## 3. Cuplivo 今天（`91125981f`）

路径在 `lib/` 下。

- **数据**：委派记录只在内存（`features/subagent/services/subagent_coordinator.dart:83-123`，`SubagentEntry`）；子会话是普通会话行，`extras` 带 `subagent.parent|root|depth|target|escalation|escalation.cap` 与继承的 `workspace.id|cwd`（`subagent_rules.dart:17-46`、`:72-96`），不隐藏，列表里有「子代理」标签。结果行 = 父会话里的 `user` 消息 `[SubagentResultPart, TextPart(brief)]`，id 是 `UUIDv5(childId)`——**每个子会话一条**（`core/models/message_part.dart:139-220`）；`isUserInputMessage` 为 false。阶段 `running|waitingForInput|completed|failed|cancelled|interrupted`。
- **生命周期**：`begin`（:312-439，按 `"$parent/$toolCallId"` 幂等）→ `_watch` 每 500 ms 轮询 `GenerationRun`（:526-568）→ `_finish`（:585-661）先算 brief 再翻阶段；有 `await_job` 等待者则不写通知；否则 `addMessageDirectly` 写行 + `enqueueResult(followUp)`。取消 / 中断：写行、不唤醒。
- **工具**：`delegate{task,label}`（`features/home/services/local_tools_service.dart:878-912`）回 `{status:'started', conversation_id, job_id}`；`await_job{job_id}`（:921-945）。子会话（深度 1）拿不到这两个（`subagent_rules.dart:52, 105-106`）；`ask_user` 与审批工具**不**撤（`plan.md:275`）。
- **子会话的上下文**：第一条请求只有 `ChatInputData(text: task)`（`features/home/controllers/home_page_controller.dart:822-831`）；助手、系统提示、MCP、记忆、技能、工具全来自父会话的助手对象；workspace 继承；对话级系统提示覆盖为空。它对自己的了解只有一块**静态**的 `<subagent_context>`（`features/home/services/message_builder_service.dart:2250-2259`），写明「不要问父对话、不要等澄清、不要对不在这里的用户说话」——不知道自己的 label、深度、父会话，也没有回报规则；结果就是它最后一条非空回复（`subagent_coordinator.dart:708-725`。归入 `ContextSource.systemPrompt` 是**有意的**（:2241-2245 的注释）。
- **通信**：无中途转向、无子→父进度、无模型可调的中断与列表、无程序化续聊（`begin` 永远新建子会话）；只有父侧续写（`_deliverSubagentResult`，`home_view_model.dart:1330-1354`）和父 Stop 级联取消。
- **队列**：每会话 FIFO（`home_view_model.dart:227`），只在**前台且不忙**时排空头（:1251-1325），密封 `switch` 分 `QueuedUserInput` / `QueuedSubagentResult`；只有用户输入能暂停队列。调研未发现任何消息在轮次中途进入一个正在生成的会话的路径——人也不能。
- **咽喉点**：`assembleUnprocessedRequestContext`（`features/home/services/message_generation_service.dart:174-407`）是所有 provider 共用的请求装配；`injectSubagentPrompt` 在 :361-364 调用。生成循环有两个入口（`core/services/api/generation/tool_loop_runner.dart:100-145` OpenAI 风格；`:150-193` Claude / Gemini），`append(executed)` 由各 host 实现——「The host owns protocol-specific HTTP and transcript shape」。
- **同步**：`extras_json` 是同步列，`subagent.*` 全部随行；`generation_run_rows` 是设备本地（`sync_family_registry.dart:436-444`）→ 对端看得到子会话与结果行，看不到运行。
- **已写明的设计**：`plan.md:21` 把「context injection / DSH prompt registry、子代理之间的 `send_message` / `interrupt` / `list_agents`、子代理多轮续聊」列为该轮之外；`plan.md:354`「动态上下文是 user-role snapshot，变化才追加；本轮只记原则，不实现」；`plan.md:343` 工具契约写死三句话（任务自足、调用不是结果、一个任务只派一次）。不变量 `n-core-pseudocode.md:217-229` #1–#10，其中 #3「一条结果行」、#4「结果不是用户输入」、#7「终态必写行」、#8「忙 / 草稿时不唤醒」、#9「schema 5」、#10「父 Stop 级联」与本轮直接相关。
- **测试即规格**：`test/features/subagent/*`（coordinator 746 行、rules、await_job、serialization）钉住了上面每一条。

## 4. 对照

| DSH 概念 | Cuplivo 今天 | 缺口 |
|---|---|---|
| `subagent:delegation` system 节：身份 + 来源规则 + 回报契约 | 静态一段，无身份、无回报规则，且说「不要提问」 | 简报内容 |
| 动态上下文 = 变化才追加的 user 快照 | 无动态上下文 | 不需要——子会话里会变的只有事件 |
| 任务 = user 消息进收件箱 | `sendScheduledMessage` | 已等价 |
| 结算 = 运行时署名的 user 消息进父收件箱，按父状态选投递 | 结果行 + `QueuedSubagentResult`，仅 nextTurn | 已等价（nextTurn 版） |
| `send_message` 父→子：steer / followup | 无 | 留言行 + `QueuedSubagentMail`；nextStep 另算 |
| `send_message` 子→父：进度 | 无 | 子侧工具 + 父队列 |
| 结果行每个结算一条 | 每个子会话一条 | `messageIdFor(childId, runId)` |
| `interrupt` 保留收件箱 → 可续 | 取消是终局 | 新阶段 + 不唤醒 |
| 人停 vs 模型停 | 不分 | 「人停的才是终局」 |
| `omitClosingText` | 无 | 不移植 |
| `list_agents`、命名、目录 | UI 面板有，模型无 | 不移植（深度 1 用不上） |
| fork、深度 > 1、全树、外部后端 | 无 | 不移植 |

## 5. 调研未决项

- DSH 两次 `git log -S` 因沙箱的信号管道错误中断，更早的落地提交可能漏掉；不影响机制的读法。
- DSH 外部后端的 `run.ts`（acp / codex / claude-code / dsh-sdk）未读，行为取自 `SubagentProvider.start` 契约。
- rc.1 与 HEAD 除 `sendMessage` 和工具文案外的内部差异未逐项 diff。
- Cuplivo 侧「运行中的会话没有中途接收消息的路径」是按搜索词 `steer|sendMessageToChild|messageChild|send_message` 与队列排空代码得出的，未穷举 `chat_actions.dart` 的每条发送分支。

## 6. 生成管线与步骤边界

上一轮（`zb` / `zc`）选了步骤边界，并要求队列本身变成 steer；本节为此补的调研。路径在 `lib/` 下。

- **发送 → run**：`sendMessage`（`features/home/controllers/chat_actions.dart:1819-1860`）→ `_sendMessageClaimed`（:1862-1988）→ `beginSendGeneration` 一个事务写 user 行 + assistant 占位 + run 行（`core/database/chat_database_repository.dart:5122-5174`），**先落盘再生成**；`_runSendGeneration`（:1990-2104）→ `_executeGeneration`（:3332）→ `ChatApiService.sendMessageStream`（`core/services/api/chat_api_service.dart:398-565`）。
- **处理只在轮次开始做一次**：`prepareApiMessagesWithInjections`（`features/home/services/message_generation_service.dart:689-880`）→ `processUserMessagesForApi`（`features/home/services/message_builder_service.dart:1112-1649`）：OCR、文档、正则、`resolvePromptContent`（:1825-1893，写冻结行 `message_prompt_rows`）。每次请求只跑 `RequestImageContext.encodeBody → history.prepare`。`resolvePromptContent` 是单条、自冻结的，可复用；OCR / 文档块依赖请求级状态（`frozenPrompts`、`memoryPlan`、`ocrSession`、`lastUserIdx`），不可直接复用。
- **在飞的消息表**是各 adapter 闭包里的局部副本，runner 不持有；`append(executed)` 重建它。7 处：`core/services/api/providers/openai/chat_completions_api.dart:912-925`、`:1102-1119`；`…/openai/responses_api.dart:248-267`；`…/claude/claude_official.dart:712-741`；`…/google/google_vertex.dart:523-552`；`…/google/google_common.dart:803-824`、`:1353-1369`。边界 = `core/services/api/generation/tool_loop_runner.dart:136-137`（OpenAI 风格）、`:191`（Claude / Gemini）。
- **provider 合法性（按 adapter 自己的代码）**：OpenAI chat 不合并不拒绝，`flushToolImages` 已有 tool 批之后插独立 `user` 的先例（`chat_completions_api.dart:301-309`）；Claude 的 `tool_result` 在 `user` 里，builder 本来就发相邻 `user` 并靠 API 合并（`…/claude/claude_history.dart:318-323`）；Gemini 把并行 `functionResponse` 合进一个 `user` content（`google_common.dart:170-185`），代码从不把文本放在 `functionResponse` 之后、也没断言相邻 `user` 是否被接受；Responses 没有中途插 `user` 的先例。
- **`roundCompleted()` 不是计数器**：把上一次请求里的工具结果 id 记为「已读」，只供 `replaceConsumedTools` 的引用投影用（`core/services/api/request_history_context.dart:344-346`、`:311`）。
- **取消 / 重试 / 后台**：Stop 丢掉 adapter 局部表、不动队列，随后 `cancelStreaming` 排空队列开新一轮（`home_view_model.dart:1464-1480`）；重试重发同一张表；`_queue` 纯内存，进程死亡即丢；重启把未结束的 run 标 `interrupted`，中途写的 user 行原样保留（`chat_database_repository.dart:8744-8789`）。`waitingTool` 从未被写入，run 全程 `streaming`。
- **今天的排队输入**：忙 → `QueuedUserInput` 入内存队列（`home_view_model.dart:1002-1011`）；排空只取头、只在前台且不忙（:1251-1325）；draft 提交生命周期（`submitting` / `wasSubmitted` / `finishSubmission`）；失败则 `_pausedQueuedInputs` 等人处理；composer 显示排队 chip、可取消、锁输入（`features/home/widgets/chat_input_bar.dart:992-994`、`features/home/pages/home_page.dart:1859-1870`）。
- **钉住这一带的测试**：`test/core/services/api/generation/tool_loop_runner_test.dart`、`request_history_context_test.dart`、`chat_api_auto_retry_test.dart`、`…/claude/claude_history_replay_test.dart`、`test/features/home/controllers/chat_send_race_test.dart`、`…/widgets/chat_input_bar_queue_test.dart`、`…/chat_controller_external_reload_test.dart`。

**实现 steer 必须面对的隐患**

1. 记录顺序 `user → assistant(整轮) → 留言` 与线上顺序 `… tool → 留言 → assistant` 不同，重放无法复现。
2. 带 `imageContextOwnerKey` 会劫持图片上下文，不带又被 `prepareMessages` 跳过（`core/services/api/request_image_context.dart:54-59`、`:465-466`）。
3. 压缩替换只重发有 source 的项，带 source 的留言会消失；不带 source 的靠行重放。
4. `resolveMemoryPlan` 以 `lastUserIdx` 为载体（`message_builder_service.dart:1746-1750`），留言会把载体挪走。
5. 不经 `resolvePromptContent` 就没有冻结行，下一轮字节不同。
6. Gemini 相邻 content 规则（见上）。
7. Claude 流式在 `sendRound` 里执行工具，`pauseTurn` 不追加 user；`uploadDataFiles` 假定 `convo.last` 是 user 轮，但只在首个请求前跑。
8. 忙闸是总闸：`_isConversationBusy` 跨全部轮次为真，`sendMessage` 回 `inFlight`，`sendScheduledMessage` 忙时不排队直接拒。

**如果手递手切一个新 run 并从历史重新装配**（`ze` 的做法），上面八条里 1、2、4、5、6、7 都不存在——留言走正常轮次开始路径，不进入在飞表；剩下的是 3（压缩替换）与 8（忙闸），以及一个新问题：一轮变成一串 run，加载连续性、队列排空判断、子代理监视都要按轮看。
