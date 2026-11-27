# 生图 Job 实现计划

> 状态：**已定稿**（4 轮 clarity round，2026-11-16）。分支 `feat/image-job`，基线 schema 5。
>
> 机制与 UI 按轮次落定（§5）；每轮的产物与结论见 §11。仍未定的只剩 §8 的四项，不阻塞第一版。
>
> **修订（2026-11-19）**：本文是**计划与讨论记录**，前半部分（§2–§4、§6 早期草稿）里的 `cancel` / `cancelled` / `interrupted` 生命周期**已不存在于代码**。现状：job 只有 `queued → running → completed | failed`；`interrupted` 是渲染层派生，不落库。以 §5.3 收口说明、`handoff.md` §9 与 `p-tool-contract.md` 为准。

---

## 1. 目标

让文本模型在正常回复中按需调用**独立绘图模型**生成配图：

- 文字继续输出，不被生图阻塞；
- 图片位置先占位，完成后原地替换；
- 失败、中断有明确状态（写明原因，不提供重试入口 —— 见 §5.3 收口说明）；
- 不升级 database schema version（保持 5）。

一句话：**先让“回复里配一张图”端到端成立，再谈子代理、上下文注入和更复杂的检查/审批。**

---

## 2. 范围

### 做

- 一个最小的生图 job：创建、运行、取消、终态、结果引用。
- 一个文本模型可调用的生图入口：`generate_image` 返回 pending + 已分配的 asset 路径，需要结果时再 `await_image`（§5.2）。
- 占位与替换：调用位置先占位，图完成后替换；失败/取消有卡片。
- 重复渲染/重挂载不重复提交。
- 重启后未完成 job 标记中断，不自动续跑。
- 先接一个图像后端；现有宿主生图路径（OpenAI Responses / OpenRouter）保持可用。
- 测试：状态机、幂等、取消、重启、占位、schema 仍为 5。

### 不做（默认拒绝，除非 clarity round 明确纳入）

- 子代理
- DSH 式 context injection / prompt registry
- 通用 job 平台、队列、DAG、分布式 worker
- 新表、新列、新索引、schema bump
- 默认的 VLM 视觉检查、自动重画
- “先审后画”审批模式
- 多候选图、批量图、跨 provider 全适配

---

## 3. 调研结论（只保留影响决策的）

### 3.1 业界四类做法

| 做法 | 代表 | 文本是否继续 | 模型是否知道结果 | 主要代价 |
|---|---|---|---|---|
| 宿主内置图像工具 | OpenAI Responses、OpenRouter | 模型回合内等待；部分图可流预览 | 通常拿到 image/URL，可继续 | 回合被工具占住；部分图有额外 token 成本 |
| 客户端同步工具 | function tool / MCP | 否，工具返回前停住 | 是，可检查、可重试 | 延迟直接进入回复；多次检查会多次调用 |
| 非阻塞插画意图 | SuperAgent 提案 | 是，开标记占位、闭标记提交 | 否，默认不检查 | 占位存在一段时间；需要消息后更新、去重、重启策略 |
| 先提案后生成 | SimpleChat | 是，先出提案卡 | 用户批准后才生成 | 多一步交互；但成本可控、精确要求友好 |

补充两条：

- **原生图像输出**（Terva/Codex）把图作为 assistant message 的 `ImageBlock`，不是 tool result；后续可回放图片做编辑。适合模型本身支持原生图像输出/编辑的路线。
- **视觉检查要诚实**：模型看不到图时不能假装看到；ComfyUI MCP 的做法是“总是尝试投递，模型看不到就明确说明”，并用历史注记防止编造。

### 3.2 对 Cuplivo 的判断

1. **配图和“图就是答案”是两种语义。**
   - 配图：默认非阻塞；模型不需要检查；用户是最终判断者。
   - 图就是答案：允许阻塞/await；模型应拿到结果再回答。
2. **默认不做模型自检。** 自检会把“画图”变成“画图 + 看图 + 可能重画”，成本和延迟都上去；需要时用显式 `await_image`，并限一次检查、一次重画。
3. **现有宿主生图路径保留。** 它已经能流部分图、拿最终图；缺的是跨供应商的“文本模型 + 指定绘图模型”和统一占位/失败体验。
4. **不要把 job 做成平台。** Job 是消息/工具调用拥有的外部工作单元；不是队列、不是 DAG、不是后台任务系统。

### 3.3 调研边界（避免继续扩张）

已经足够支撑决策，不再扩展竞品清单：

- 已确认四类模式及各自代价；
- 已确认 `partial_images` 1–3、部分图有额外成本；
- 已确认“非阻塞 + 占位 + 重试/重启放弃”是成熟做法；
- 已确认“模型看不到图时必须诚实降级”。

后续只有在**直接影响 clarity round 的待定项**时才补资料，不做泛化调研。

---

## 4. 现状（代码事实）

| 现状 | 位置 | 差距 |
|---|---|---|
| OpenAI Responses 可启用 `image_generation` 工具，并可指定图像模型/complexity | `lib/core/services/api/builtin_tools.dart` 422–428 | 只对 OpenAI Responses；没有 `partialImages` 配置 |
| OpenRouter 有 `openrouter:image_generation` 服务端工具 | `lib/core/services/api/builtin_tools.dart` 407–419 | 只对 OpenRouter；参数不可配 |
| 部分图事件解析为 `ImageSnapshot` | `lib/core/services/api/providers/openai/responses_decoder.dart` 272–287 | `ImageStart` 不创建占位，未流部分图时消息里什么都没有 |
| `ImageStart/Delta/Snapshot/End` 转成 `ImagePart` | `lib/core/services/api/stream/stream_chunk_handler.dart` 268–297 | 没有 job/状态/取消/重试概念 |
| `ImagePart` 只有 uri/mime/assetId | `lib/core/models/message_part.dart` 232–286 | 没有 prompt/status/jobId；不能直接承载占位状态 |
| 图像模型可作为聊天模型 | `lib/core/services/api/providers/openai_images.dart` 22–25 | 是“回复就是图”，不是“文本回复里配图” |
| 当前 schema 5，严格校验列/顺序 | `lib/core/database/app_database.dart` 818–826；`chat_database_repository.dart` 983–994 | 不能加列/表/索引 |
| 工具执行目前是同步 await | `lib/features/home/services/tool_handler_service.dart` 440–468 | `generate_image` 立即返回 pending 需要 job 机制与消息后更新 |

结论：**宿主路径已经证明生图能进消息；缺的是通用 job 生命周期和跨供应商路径。**

---

## 5. 已定方案

按轮次落定的机制；每轮问的问题与产物见 §11。

### 5.1 Job 最小契约

- 字段：`id / kind / owner / state / idempotencyKey / resultRef`，加 `cancel()`。
- 状态：`queued → running → waitingInput → completed / failed / cancelled / interrupted`。
- owner：会话 + 消息 + tool call；job 不独立于消息存在。
- 持久化：只在状态转换/终态写 `message_rows.extras_json` 或 tool call metadata；进度留在内存。
- 重启：非终态 → `interrupted`，不自动重新提交。
- 并发：**不设上限**（第十二轮改）；见 §5.2 与 `p-tool-contract.md` §4。
- 幂等：重复渲染/重挂载返回同一 job；工具再次调用才生成新 key。

不建议新建 `jobs` 表；只有在确实需要跨会话 Jobs 页面时才考虑 `extension_entity_rows(kind='job')`。

### 5.2 工具形态（已定：第二轮）

- `generate_image(prompt, label?, aspect_ratio?, quality?, reference_image_ids?)`
  - 立即返回 `{status: "pending", assetId, uri, placeholder: true}` —— **uri 已经分配，字节还没写**；
  - 消息里立刻出现一个图片块（`ImagePart`），**不是工具卡**；
  - 文本继续。
- `await_image(job_id, inspect?)`：只在「图就是答案」时用；默认只返回图/`revised_prompt`/尺寸/状态，`inspect` 默认关闭。
- 不使用 `generate_image(wait: bool)`：两个语义分开，避免模型选错。

契约细节（第十二轮定稿，见 `p-tool-contract.md`）：

- 工具描述用「生成一张图辅助回复 + 非阻塞 + 立刻拿到 uri 可写进正文 + 不要声称看过」那段，英文；不写"你看不到"以外的解释。
- 返回只有 `{status, asset_id, uri}`；**没有 `visible_to_you`**。
- 参数：`prompt`（必填）、`aspect_ratio`（默认 auto，只在构图重要时给）、`reference_image_ids`（可选，仅限本对话；空=文生图，非空=图生图）。**不给画质**：比例是构图决策，画质是成本决策。
- **不加并发上限**；超时默认 300s，可由 provider 既有超时覆盖。**没有取消，也没有取消入口**（300s 兜底）—— `ImageJobManager.cancel` 与 `ImageJobState.cancelled` 已删除，不留给内部也不留给测试。
- **占位不发回模型**：出站序列化跳过 `state != null` 的图片块；完成后是普通 `ImagePart`。
- 模型要看图，只走已有的看图工具；不强制、不特殊声明。
- 两个后端 adapter：`/images/generations` 形状与 Gemini chat 形状（从正文取第一个 markdown 图片链接再下载）。

为什么是工具而不是正文标记（第二轮否掉的方案）：工具结果回灌后多一次模型续写，但 part 由工具结果造出来，「这条路径是承诺的吗」有结构性答案；正文标记省掉那次续写，代价是 prompt 要塞进标记、流式要吞掉半个标记、导出/复制要剥标记。

### 5.3 UI（已定：第三、四轮；**面板动作已于 2026-11-17 收口删除**）

> 收口后的口径：面板是**只读**的 —— 模型 / 尺寸 / 用时 / 用量 / 提示词 + 复制，没有任何按钮；卡片没有重试、取消或重新生成。理由与删除清单见 `handoff.md` §9。

- **卡头一行**：`生成插图 (12.6s)` + `⋯`。字重、间距、`(12.6s)` 的写法都复用「深度思考 (11.8s)」那一行。
- 卡上不出现提示词；主体是骨架 / 部分图 / 成图，比例固定，完成前后高度不变。
- 点卡头或 `⋯` 开面板：模型、尺寸、用时、用量、提示词 + 复制。
  - 用量放在「用时」下面一行（标题行放不下会变形的值）：按 token 计费显示 `1,536 tokens`，按张计费显示 `1 张`。
- **手机**：底部抽屉（`DraggableScrollableSheet` 0.4–0.9，键盘安全），上一截还留着图。
- **桌面**：居中对话框 + 遮罩（`showDialog`，和工具详情同一套）；不用 bottom sheet。
- 失败 / 中断：卡头照常，主体换成失败卡写明原因；中断是终态，不自动续跑，也没有重试入口。
- 完成后原地替换，不新开图片消息。

### 5.4 数据与结果

- 图片最终仍写现有 asset 存储 + `ImagePart`；job 只存引用。
- 不把 base64、完整 prompt、子会话全文写进 job 状态。
- 删除消息/会话时取消 job；资产走现有 GC。
- 承诺占位复用现有约定：正文里的 `![alt](generated)` 今天被认作占位却被吞掉（`_ImageLineKind.placeholder`）；本轮把它渲染成图片块并绑上 job。
- 用量只记在这一张卡片上（tokens 或张数）：不进消息的 token 统计，也不进统计页 —— kelivo#1492 要新增 `usage_events` 账本表，那是 schema 6 的事。
- Gemini Image 这类走 chat 接口、返回 markdown 链接的：宿主路径，渲染层已有 markdown 图片与独立图片行识别，不进 job，第一版不动。

### 5.5 明确延后

- **context injection**：只有出现“跨 turn 的 active job，模型因不知道状态而重复提交/无法继续”时才做；只注入 active + 未确认 terminal，放当前 user turn 的 API-only 后缀，不进 system prompt。
- **子代理**：真做子代理时再决定是否复用 Job；wait-only 子代理不需要独立 job。
- **DSH prompt registry**：原则可记入 ADR，实现不做。
- **VLM 检查 / 先审后画**：等生图主路径稳定后再单独决策。
- ~~**重新生成是否保留旧图为版本**~~：**已定：不提供重新生成。** 配图是辅助功能，不是多版本产出；想换个画法就让模型重新说一句、再调一次工具。见 `handoff.md` §9。

---

### 5.6 工具入口（第五–十一轮）

- **本地工具**：绘图与子代理都进助手的本地工具清单，默认关闭 —— 关着就不进模型上下文。
- **日常入口在工具箱**：composer 底部那排按钮里的工具箱打开后，两者各占一行（沿用 `ToolsSheetRow`：48 高、半径 14、裸 20 图标、15/medium 名称）。
- **手机用开关、桌面用打勾**（同一份数据、两种壳）；打勾/开关只负责开关。
- **配置是展开出来的子行**：开启后主行下面长出一行，13px、内缩 42px、右侧 `›` —— 绘图是「模型 · gpt-image-1」，子代理是「委托目标 · Haiku 4.5」。关掉即收起。
- **开而未配**：子行写「未配置 · 去选择」，点它进模型选择页；不静默开一个画不了图的工具。
- **绘图模型不由对话模型选**：文本模型只写 prompt；比例、画质走 auto，不给用户在工具大纲里设。
- **模型归属**：两层解析（助手 → 全局默认），不加对话层；委托换的是写字的人，画笔不跟着换。
- **job 基建按 `kind + model`**：kind = image / delegate，绘图与后续子代理共用同一套状态机。

## 6. 验收

### 用户可见

1. 文本回复过程中能调用生图，文字继续输出。
2. 占位出现在调用位置，图完成后原地替换。
3. 失败/中断有明确卡片并写明原因，不提供任何动作按钮。
4. 杀掉应用重进，未完成 job 显示中断，不自动重跑。
5. 重复渲染/重挂载不会重复扣费。

### 工程

- `AppDatabase.currentSchemaVersion == 5`；无新表/列/索引；`_validateRawSchema` 通过。
- Job 状态机、幂等、中断、超时有测试。
- 卡片 / 面板在手机与桌面两种形态下都成立；面板只有一处可点的东西（复制）。
- 一个图像后端端到端；另一个后端保持现状或后续适配。
- 不改变现有 OpenAI Responses / OpenRouter 生图行为（除非明确修占位/失败体验）。

---

## 7. 风险

| 风险 | 缓解 |
|---|---|
| 重复提交/重复计费 | idempotencyKey；重挂载复用 job |
| 占位造成布局跳动 | 固定比例占位；完成前不改变高度 |
| 图失败但正文已说“图在下面” | 工具返回 pending 时引导模型说“正在生成”；失败卡显式写明原因 |
| 模型声称看到了图 | 文本模型返回 `visible_to_you: false`；提示词明确不要假装 |
| 重启后 job 悬挂 | 非终态标记 interrupted；不自动续跑 |
| 生图超时 | 单 job 超时 300s；失败卡停在原地，不无限 spinner |
| 跨 provider 差异 | 先接一个后端；用 adapter 隔离；不把全适配放进第一版 |
| schema 被顺手改掉 | 验收硬门：版本仍 5，严格 schema 校验通过 |

---

## 8. 仍需决定（不阻塞第一版）

1. **默认图像后端**：OpenAI Images、OpenRouter，还是先补宿主内置路径的体验。
2. **图像模型配置粒度**：全局默认，还是每个助手 / 每个文本模型单独配。
3. **模型自检**：默认关闭已定；开启时是否允许一次 VLM 检查、一次重画。
4. **context injection**：本轮不做，只留触发条件（跨 turn 的 active job 让模型重复提交时）。

已定：默认语义（模型直接生成）、图位机制（工具 + 承诺占位）、卡片与面板（只读）、手机抽屉 / 桌面对话框、统计口径 —— 见 §5 与 §11。**已否决：编辑提示词、重新生成、取消入口**（见 `handoff.md` §9）。

---

## 9. 资料

- [SuperAgent：回复内插画，非阻塞、占位、重试、并发/超时、重启放弃](https://github.com/drolu/superagent/blob/27ef19f256be6bf6238aa3d72a9b73d5d35aade6/.agents/notes/proposed/feature/2026-11-03-reply-illustrations.md)
- [OpenRouter：服务端生图工具，结果以 imageUrl 返回给模型](https://openrouter.ai/docs/guides/features/server-tools/image-generation)
- [AG2：OpenAI Responses ImageGenerationTool，partial_images 1–3](https://docs.ag2.ai/0.11.4/docs/api-reference/autogen/beta/tools/builtin/image_generation/ImageGenerationTool/)
- [Dartantic：OpenAI Responses 生图，部分预览 + 最终图](https://github.com/csells/dartantic/blob/70422e4fc4c15d2950765bb67ec8211354daf8a7/docs/server-side-tools/openai-image-generation.mdx?plain=1)
- [Everruns：同步工具的生图进度、partial_images 成本、批量不流预览](https://github.com/everruns/everruns/commit/1ba2dbb03bf6d4a39e6ffc5591c36f827d4d41b3)
- [SimpleChat：先提案、用户批准再生成](https://github.com/microsoft/simplechat/blob/fdce7547e42a34b7e6d2bf72ec9947e8037e3619/docs/explanation/features/IMAGE_PROPOSAL_PIPELINE.md)
- [Terva：原生图像输出 + 后续编辑回放](https://github.com/terva-sh/terva/commit/b30344e6744611f02fffb6848b36acc8365556cb)
- [ComfyUI MCP：模型看不到图时诚实降级，不能让模型编造](https://github.com/artokun/comfyui-mcp/blob/5b84d82080e4354674fdd1cb26040912254a855a/docs/blog/vision-per-model.mdx)
- DSH 的 context injection 参考：`docs/subsystems/system-prompt.md` 的 `PromptContext`（动态 user-role snapshot、变化才追加、required/optional、admission refresh）；本轮只记录原则，不实现。

---

## 10. 变更控制

- 本计划只承诺一个垂直切片；任何新增范围默认拒绝，除非 clarity round 明确纳入。
- 调研已到“够用”边界；新资料只有在直接影响 §8 的待定项时才引入。
- 如果实现中发现 job 契约需要扩大（例如必须支持跨消息列表），先回到 clarity round，不在实现中顺手扩。

---

## 11. 轮次记录

每轮一个决定，产物是当轮的快照，不随实现漂移。

| 轮 | 问的问题 | 结论 | 产物 |
|---|---|---|---|
| 1 | 默认由谁按下「开始画」 | 模型直接生成（先提案未采纳） | `a-auto-generate.html` / `b-propose-first.html` |
| 2 | 图位由协议还是文本产生 | 工具调用 + 承诺占位（正文标记未采纳） | `a-tool-promise.html` / `b-inline-marker.html` |
| 3 | 面板与「编辑」的交互 | 用量复用 token 统计样式；编辑一个入口，出口是仅保存 / 重新生成（当轮要求修订）—— **该结论已作废，见 §5.3 收口** | `c-panel-edit.html` |
| 4 | 桌面端如何弹出面板 | 居中对话框（贴卡片浮层未采纳）；~~面板底部左右两个按钮~~ —— **按钮已删除** | `d-panel-dialog.html` / `e-panel-popover.html` |

| 5–11 | 绘图模型归属、委托、工具入口 | 内置写本地工具（默认关）；两层解析（助手 → 全局）；入口在 composer 工具箱，开启后展开配置子行 | `h-model-two-levels.md` … `o-toolbox-expand.html` |

实现按 §5 落地；§8 的四项在实现中遇到再单独开轮。
