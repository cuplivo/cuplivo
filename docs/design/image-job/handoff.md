# 交接：生图 Job（feat/image-job）

> 目标：**在正常回复里配一张图**，端到端成立的那一刻就开 clarity test。
> 读完这一页就能接着写；设计和论点都在 `docs/design/image-job/`，这里只留"现在到哪、下一步写什么、什么不许动"。

## 1. 目标与"看到效果"的定义

一句话：文本模型在回复中途调用独立绘图模型，调用位置先占位，图完成后**原地替换**；文字不被阻塞；失败/中断有明确状态；重启不自动重跑；schema 仍是 5。

> **注意（2026-11-17 收口）**：本页 §7–§8 里出现的「编辑提示词」「重新生成」「取消」「重试」**都已从产品里删除**，只保留信息与复制。以 §9 为准，别照着旧段落实现。

**看到效果 = clarity test 的那个场景能跑通**：助手写一段话并配图 → 骨架出现 → 图原地替换 → 卡头能看到模型 → 杀掉重进未完成的显示"已中断"。不是"测试绿了"。

不做（本切片明确排除）：子代理实现、context injection、VLM 自检、先审后画、多候选/批量、跨 provider 全适配。

## 2. 已经锁定的决定（别重开）

| 轮次 | 结论 | 产物 |
|---|---|---|
| 4 `clarity-mwjbgrm3` | 面板：手机底部抽屉 / 桌面 `showDialog`；卡头 `生成插图 (12.6s) ⋯`；~~面板按钮左「编辑」右「取消/重新生成」~~ **已被 §9 推翻：面板不再有按钮** | `d-panel-dialog.html` |
| 11 `clarity-mwjeti9g` | 工具箱：主行只放开关（手机 `IosSwitch` / 桌面打勾），**开启后展开配置子行**；开而未配显示「未配置 · 去选择」 | `o-toolbox-expand.html` |
| 12 `clarity-mwk6stqh` | 工具契约与 job 伪代码：工具描述用你写的那段（英文）、返回只有 `{status, asset_id, uri}`、参考图可空、**无并发上限**、**超时 300s**、**占位不发回模型**、两个后端 adapter | `p-tool-contract.md` |

其余轮次均为修订；`plan.md` §5 是合并后的完整设计，§5.2（契约）/ §5.3（UI）/ §5.6（工具入口）都是定稿。

**不许漂移的硬边界**

- 不加并发上限；超时默认 300s，不写死成"120"。
- 不加 `visible_to_you`；不写"你看不到"以外的解释。
- 不提供"画质/比例"给用户设；比例只作为工具的 `aspect_ratio`（默认 auto），画质不给。
- 不引入对话级模型覆盖：只有 **助手 → 全局** 两层（`ImageModelResolver`）。
- 不加新表/新列；job 状态只镜像进 `message_part_rows.payload` 的 `jobId`/`state`。
- 不往 markdown 渲染器（`dependencies/markstream`）里加钩子。
- `state != null` 的图片块**永远不发出站**。

## 3. 现状（可编译、可测）

```
lib/features/image_job/models/image_job.dart          ImageJob / 状态机 / ImageJobOutcome
lib/features/image_job/services/image_job_manager.dart 幂等(id=key) / 取消 / 超时 / 中断 / ChangeNotifier
lib/features/image_job/services/image_model_resolver.dart  两层解析 + 半配置/空白不算
lib/features/image_job/widgets/image_job_card.dart    卡头、3:2 骨架、失败原因、⋯(onOpen)
lib/features/image_job/widgets/image_job_panel.dart   只读信息 + 复制
lib/core/models/message_part.dart                     ImagePart + jobId/state/prompt/model/failureReason/durationMs
lib/features/chat/widgets/chat_message_widget.dart     _imageJobPartFor + 图片块分支
lib/l10n/*.arb (7 语言) + gen-l10n                    imageJob* 一套
```

门禁：`test/features/image_job` **18 条绿**；`test/core/models/message_part_test.dart` 绿；改动范围 `dart analyze --fatal-infos` 干净；用 **Dart 3.13.0** 格式化；`pubspec.lock` 未动；`AppDatabase.currentSchemaVersion == 5`。

## 4. 下一步（按序，每步都能单独编译）

1. **adapter**：`image_backends.dart` —— `Future<Uint8List> generate(ImageGenerationRequest)`；两个实现：`/images/generations`（b64 / url）与 Gemini chat（取正文第一个 `![](url)` 再下载）。解析写成纯函数。
   *验收*：解析单测（b64、url、gemini 抽取、回复无图 → `no_image`），不联网。
2. **协调器**：`image_job_coordinator.dart` —— `allocateAsset(idemKey)` → `create` → `start` → 完成写回 `state: null` + 新 uri；失败/取消/中断写回对应 state。
   *验收*：用假 adapter 驱动，断言 part 的三种终态；取消后迟到结果不覆盖。
3. **工具注册**：`LocalToolNames.generate_image` + schema（照 `p-tool-contract.md` §1）+ 本地工具清单/标签；未配置模型 → 返回可执行错误，不建 job；参考图越界 → 拒绝。
   *验收*：schema 快照 + handler 单测。
4. **出站序列化**：拼请求时跳过 `state != null` 的图块。
   *验收*：单测断言 pending 图块不出现在 outbound parts 里。
5. **设置**：`默认模型` 加「绘图模型」（provider + model），接 `resolveModelBinding`。
   *验收*：读/写 + 解析回落。
6. **工具箱行 + 子行**：手机开关 / 桌面打勾；开启展开子行；点 `›` 进模型选择页。
   *验收*：三态（关 / 开已配 / 开未配）widget test。
7. **开 clarity test**（草稿见 §6）。

## 5. 外部前提与一个默认

- 需要两个真实模型：`/images/generations` 形状与 Gemini chat 形状；key 由用户在应用里配，代码不碰。
- **asset 路径默认复用现有 asset 存储**（`AppDirectories` 图片目录 + `asset_id` 命名）。若要求按会话分目录，先改这里再继续 —— 这是唯一一个尚未书面确认的点。

## 6. clarity test 草稿

- **前提**：配好绘图模型；助手开启「绘图」；一张图都没在画。
- **步骤**：① 让助手写一段并配图，观察文字是否继续；② 等骨架变图；③ 点卡头看模型名与提示词；④ 生成中杀掉应用，重进。
- **预期**：文字不被阻塞；骨架出现且高度不跳；图原地替换；卡头 `(N.Ns)` 与模型名正确；重进后未完成显示「已中断」，不带任何按钮。
- **失败特征**：骨架永不结束 / 正文被阻塞 / 重进后自动重画（二次计费）/ 控制台有未捕获异常。
- **回滚**：关掉助手的「绘图」开关；不涉及 schema，无数据迁移。

## 7. 一件事没做

计划文档里 `§8` 仍有四项未定（默认后端、模型配置粒度、VLM 自检、context injection）—— 除"默认后端"由实际配置决定外，其余都不阻塞本切片，**不要在实现里顺手扩**。

---

## 8. 进度（第 1 轮实现，2026-11-17）

**做完了 §4 的 1–5 步**（可编译、`dart analyze --fatal-infos lib test` 干净、`test/features/image_job` + `test/core/models` + `test/features/chat` 全绿 1259 条）：

| 步 | 落地 | 文件 |
|---|---|---|
| 1 adapter | 两个 wire shape + 纯解析函数，16 条单测 | `services/image_backends.dart`、`test/.../image_backends_test.dart` |
| — manager | 去掉每会话上限、超时 300s | `services/image_job_manager.dart`（`ImageJobLimitException` 已删） |
| 2 协调器 | 幂等 key→asset→create→start→`ImagePart` 镜像；失败/完成/中断 | `services/image_job_coordinator.dart` |
| 3 工具 | `LocalToolNames.generateImage` + 契约 schema + handler（未配置/越界/空 prompt 都可执行错误） | `local_tools_service.dart`、`tool_handler_service.dart`、`local_tool_labels.dart` |
| 4 出站 | `ImagePart.hasBytes`，五处出站点全部走它 | `message_part.dart`、`message_builder_service.dart`、`context_assembly.dart` |
| 5 设置 | `默认模型 → 绘图模型`（全局），助手级在 `Assistant.imageModelProvider/imageModelId` | `settings_provider.dart`、`default_model_page.dart`、`desktop/setting/default_model_pane.dart`、`assistant.dart` |

顺带落的（不写会看不见图）：
- `chat_actions._imageJobParts`：流式回复的 part 列表append 协调器镜像的图块（流自己不知道这个 job）。
- `toolCreatesTimelineCard(generate_image) == false`：只有图卡，没有工具卡。
- `ImageJobCard.child`：完成后由调用方把普通图片渲染塞进来，卡头保住。
- 重启后 `pending` 且无活 job → 渲染层派生 `interrupted`（不落库、不用启动扫描）。
- `ImagePart.prompt`：面板要显示提示词、重启后重试也要它。

**还没做**
1. **协调器单测**：`ImageJobCoordinator` 直接吃 `SettingsProvider` / `ChatService` 两个具体类，假驱动要么抽 port、要么起真 DB。已覆盖的是：manager 状态机、两个后端解析、卡片、面板 body、工具箱三态。
2. 骨架固定 3:2：`auto` 比例返回非 3:2 时，完成那一刻高度会跳一次。**这是个需要你定的取景问题**，没有擅自决定。
3. 卡头 `(N.Ns)` 是**完成后的最终用时**，不是生成中跳动的计时器；面板里的「用时」同理。
4. 面板的用量只显示「1 张」：后端若返回 `usage` 没解析，所以没有 token 数可显示。

**第二轮补上的（2026-11-17，晚）**

| 件 | 落地 |
|---|---|
| 面板 | `widgets/image_job_panel.dart`：手机 `DraggableScrollableSheet` 0.4–0.9 / 桌面 `showDialog`+遮罩；模型、尺寸（文件存在则真像素，否则请求的比例）、用时、用量、提示词 + 复制。**（按钮部分已被 §9 删除。）** |
| ~~编辑提示词~~ | 已删除，见 §9。 |
| 工具箱子行 | 手机（`chat_tools_sheet.dart`）= `IosSwitch` + 下方 13px 内缩 42 的子行；桌面（`desktop/tools_popover.dart`）= 打勾 + 同样的子行（内缩 36、12px）。关掉即收起；开而未配显示「未配置 · 去选择」，点进模型选择器写回**助手级**模型。 |
| part 新字段 | `model`（`provider::model`），重启后面板仍能说出是谁画的。 |
| 门禁 | `dart analyze --fatal-infos lib test` 干净；`test/features/image_job` + `test/core/models` + `test/features/chat/widgets` **988 条绿**（新增面板 4 条、工具箱三态 2 条 × 两种壳）。 |

面板测试顺带抓到一个真 bug：卡头一行在英文长标题下溢出 58px —— 已用 `Flexible` + ellipsis 修掉，kv 行同样处理。

**第十三轮（`clarity-mwkenzfp`，采纳 A）：卡跟着 Markdown 占位走**

- `MarkdownWithCodeHighlight.jobImageBuilder` → `KelivoImageBuilder` 在画到某个 markdown 图时先问应用：这个 destination 是不是某个 job 的？是就把**整张卡**画在那里（卡头、骨架、成图、⋯ 一起），不是就画普通图。
- 于是位置 = 模型写 `![](uri)` 的那一行，不再固定落在正文末尾。part 仍然存在（持久化、重启中断、出站跳过都靠它），只是当正文已经放置了这张图时它不再另起一个块（否则同图两遍）。
- 模型没写占位时**兜底**：part 仍按老路在末尾出块。
- 卡片自己订阅 `ImageJobCoordinator`（`ListenableBuilder`），完成那一刻就地换图，不再等外层重建 —— 这是"计时停了但图不刷新"的根因。
- 卡头 `⋯` 改为吃满剩余宽度后贴右（原来 `Flexible`+`Spacer` 平分了空档，所以浮在中间）。
- 工具调用恢复成**普通工具卡**（`toolCreatesTimelineCard` 不再特判 `generate_image`），失败卡现在显示后端给的原因（`ImageJob.error` 存句子、`errorCode` 存类别，`ImagePart.failureReason` 落盘）。
- 门禁：`dart analyze --fatal-infos lib test` 干净；`test/features/image_job` + `test/core/models` + `test/features/chat/widgets` **988 条绿**。
- **已知取舍**：位置由模型决定，它写在最后就仍在最后；"模型没写占位也自动放到中间"做不到。

## 9. 收口（2026-11-17 晚）：把「重新生成」整套砍掉

起点是你的一句反问 —— 这是**辅助配图**，不是产出多版本图的地方。大部分有配图能力的 App 也没有"把这张图重画一遍"这个东西。于是把为它长出的一整套分支全删了。

**留下的面**

- **卡片**：图 + 卡头（生成插图 · 用时 · ⋯）。生成中骨架 + 计时；完成就地换图；失败只写原因；中断只写「已中断」。**零按钮。**
- **面板**（点 ⋯）：标题 · ✕ / 模型 / 尺寸 / 用时 / 用量 / 提示词 + 复制 / 正文。复制走 `copyTextWithConfirmation` → 应用统一的顶部 toast（`AppSnackBarOverlay`），深浅色自适应，不是 Material 底部 snackbar。
- **用量**放在「用时」下面而不是标题行：今天是「1 张」，将来可以是 token，标题行放不下会变形的值。

**删掉的**

编辑提示词 sheet（`showImageJobPromptEditor` / `ImageJobPromptEditAction`）、面板内联编辑态、面板的编辑/取消/重新生成、卡片重试与 `_retryImageJob`、`retryPart` / `updatePrompt` / `regenerateWithPrompt` / `_messageOwningPart` / `ImagePart.withPrompt`、协调器的 `cancel()` 与 `retry()`、7 个 ARB 里 5 个只为这些入口存在的键（`imageJobPanelEdit/Cancel/Regenerate/EditTitle/SaveOnly`），新增 `imageJobPanelUsageLabel`。

**为什么连「取消」也不留**：它和重试是同一类"和正在进行的请求较劲"；300s 超时兜底。`ImageJobManager.cancel` 仍在（有单测），只是界面不再暴露。

**顺带补的两件**

- `ImagePart.durationMs` 落盘（payload 加字段，schema 仍是 5），重启后卡头仍写 `(14.5s)`。
- 卡片判"完成"以**活着的 job** 为准（`job.state == completed` → 按 `resultUri` 渲染）：part 是回复排版那一刻的快照，字节落盘只写 DB、不会重建消息 —— 这是"一直转圈、切会话才出图"的根因。
- `imageJobCoordinatorOf(context)` 用非空类型查找再兜 null。原来 `read<ImageJobCoordinator?>()` 查的是可空类型，provider 里没有，静默返回 null，于是卡片拿不到 job：不计时、不刷新、动作全部无声失败。

**门禁**：`dart analyze --fatal-infos lib test` 干净；`test/features/image_job` + `test/core/models` + `test/features/chat/widgets` **990 条绿**；clarity test #7 通过（`clarity-test-mwkq4bop-66e923`）。



