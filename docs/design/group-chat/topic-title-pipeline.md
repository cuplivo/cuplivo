# 群话题标题 · 需要什么

现状：群话题的标题是首条用户消息截断到 24 字（`_sendGroupMessageToConversation`），
群发言人的每轮 `generateTitleOnFinish` 是 `false`，所以群从不调用标题模型。

目标：群话题的标题与 1:1 一样由标题模型生成——一轮结束后、用户还没手动命名时、一次话题一次。

## 结论：不新增任何存储或设置

| 需要的东西 | 现在有没有 | 结论 |
| --- | --- | --- |
| 标题存放 | `conversation_rows.title` | 已有，群话题共用 |
| 标题模型 | `title_model_v1`（`SettingsProvider.titleModel*`） | 已有，全局唯一 |
| 标题提示词 | `title_prompt_v1` + `{locale}`/`{content}` | 已有，不改 |
| 开关 | `isTitleGenerationEnabled` | 已有，群沿用 |
| 生成调用 | `ChatApiService.generateText` | 已有 |
| 源文本 | `ChatService.generateTitleSource` | 已有，加一个可空的逐行渲染器 |
| 触发点 | `ChatActions.onGroupRoundFinished` | 已有（群轮结束唯一出口） |
| 重新生成 | 侧栏「重新生成标题」 | 已有，只需换模型解析 |
| 新表 / 新列 / 新偏好 / 新文案 | — | **都不需要** |

改动只有四处：一个模型链函数、一个触发点、一处源文本渲染、删掉首条消息截断。

## 模型链：一个函数，三个调用者

现在两条路径各自手写 `settings.titleModelProvider ?? chatModel.providerKey`，
而 `chatModel` 来自 `resolveConversationAssistant(convo.assistantId)`——群话题的
`assistantId` 是 null，这个解析会返回**当前选中的助手**，于是群标题会用某个无关助手的模型。
所以先抽函数，再谈群。

```
resolveTitleModel(settings, conversation, assistant):
    if settings.titleModel != null:            # 全局标题模型优先，1:1 与群一致
        return settings.titleModel
    if conversation.isGroupConversation:        # 群没有“会话模型”，用群自己的模型
        if settings.directorModel != null: return settings.directorModel
        return settings.currentModel            # 最后才是全局默认
    return resolveChatModel(settings, conversation, assistant)   # 1:1 原链路，逐值不变

# 调用者
#   1. HomeViewModel._maybeGenerateTitleFor     （轮末自动）
#   2. SideDrawer._regenerateTitle              （用户点「重新生成标题」）
#   3. 群轮末入口                               （复用 1）
```

## 触发：轮结束，不是每个发言人结束

```
ChatActions.sendGroupMessage(...):
    ...
    round = _runGroupRound(...)
    round.whenComplete:
        _roundLoadingConversations.remove(id)
        _cancelledGroupRounds.remove(id)
        _setConversationLoading(id, false)     # 先放 loading
        onGroupRoundFinished(id)               # 已有回调

HomeViewModel.onGroupRoundFinished(id):
    notifyListeners()
    drainQueuedInput(id)                       # 已有
    _runBackgroundTask(title, _maybeGenerateTitleFor(id))   # 新增一行

# 每位发言人的 turn 仍保持 generateTitleOnFinish: false
# ——否则一轮 3 位发言人会各触发一次标题，前两位只看到半轮对话。
```

轮被用户停止、或某位发言人报错，也走同一个 `whenComplete`：只要有内容就命名，
用户停止不该留下一个「新对话」。若这轮一个字都没写出，`generateTitleSource` 只剩用户那句话，
生成的标题仍然成立（1:1 也是这样）。

## 生成：既有函数，加三样东西

```
_maybeGenerateTitleFor(id, {force = false}):
    convo = chatService.getConversation(id)
    if convo == null: return
    if !force and convo.title not in {'', localizedDefaultTitle}: return   # 一次话题一次标题
    if !settings.isTitleGenerationEnabled: return
    if not _titleInFlight.add(id): return                                  # ① 并发去重
    try:
        assistant = convo.isGroupConversation
            ? null                                                         # ② 群没有会话助手
            : assistantProvider.resolveConversationAssistant(convo.assistantId)
        model = resolveTitleModel(settings, convo, assistant)
        if model.providerKey == null or model.modelId == null: return
        line = convo.isGroupConversation ? groupTitleLine(assistantProvider) : null
        source = chatService.generateTitleSource(id, line: line)           # ③ 逐行渲染器
        prompt = settings.titlePrompt
                     .replaceAll('{locale}', locale)
                     .replaceAll('{content}', source)
        title = (ChatApiService.generateText(
                    config: settings.getProviderConfig(model.providerKey),
                    modelId: model.modelId,
                    prompt: prompt,
                    reasoning: settings.titleGenerationReasoningFor(assistant),
                    skipImageParsing: true)).trim()
        if title.isEmpty:
            onBackgroundTaskError(title, 'empty_response'); return
        chatService.renameConversation(id, title)      # 侧栏与话题头同时刷新
        if currentConversation?.id == id: updateCurrentConversation(...); notifyListeners()
    catch e:
        log; onBackgroundTaskError(title, e)
    finally:
        _titleInFlight.remove(id)

# ③ 逐行渲染器：core 不能反向依赖 feature，所以由调用方注入
groupTitleLine(assistantProvider) = (message) =>
    message.role == 'assistant'
        ? "[${GroupTranscript.speakerName(message.senderId, resolve)}]: "
          "${GroupTranscript.publicText(message)}"
        : "User: ${message.content}"

# 1:1 不传 line → 仍是 "Assistant: <content>" / "User: <content>"，输出逐字节不变
```

`publicText` 顺带剥掉 thinking 块：别的成员的推理过程不该成为标题的输入。

## 删掉的旧行为

```
_sendGroupMessageToConversation(...):
-    if title is empty or default:
-        renameConversation(id, firstLine.truncated(24))
```

以及 `runAssistantTurn` 里那句「群话题由首条用户消息命名」的注释。

话题在轮次跑完前仍显示默认名（`新对话`/`New Chat`）——1:1 也是这样，
但群一轮通常几秒到十几秒，观感上就是「刚发完就拿到了标题」。

## 不变量

1. **一次话题一次标题。** 只要标题不是空、也不是本地化默认值，任何路径都不覆盖；
   唯一例外是用户点「重新生成标题」。
2. **并发只发一次。** `_titleInFlight` 按 conversationId 去重：连续两轮、或一轮刚结束
   用户立刻又发一条，都只会有一次请求。
3. **标题失败不影响对话。** 走 `_runBackgroundTask`，只进后台任务错误提示，不冒泡成聊天错误。
4. **不读私有上下文。** 源文本只取库里的公开 content；群助手消息的推理块被 `publicText` 剥掉，
   不引入其他成员的提示词、记忆、世界书。
5. **群被删。** `renameConversation` 对不在缓存里的 id 直接返回，没有残留写入。
6. **标题模型是全局的。** 群不引入「每个群一个标题模型」，也不改标题提示词的默认值。

## 失败模式

| 情形 | 结果 |
| --- | --- |
| 标题模型未配 / 已被删 | 模型解析为空 → 不发请求；话题保持默认名，用户可手动改名 |
| 模型返回空串 | `empty_response` 后台错误；标题不变 |
| 超时 / 网络错 | 日志 + 后台错误；轮次与消息不受影响 |
| 标题模型不支持 tools | 无关，标题只用纯文本 prompt |
| 生成过程中群被删 | rename no-op |
| 用户已手动改名 | 有真标题 → 永不覆盖 |
| 第 2 轮及以后 | 被真标题挡住，零请求 |
| 用户停止本轮 | 仍然命名（基于已落库的内容） |

## Blast radius

| 规则 / 函数 | 调用者 | 变化 |
| --- | --- | --- |
| `resolveTitleModel`（新） | `_maybeGenerateTitleFor`、`_regenerateTitle`、群轮末 | 1:1 两处结果与原 `titleModel ?? chatModel` 逐值相等；群从「当前助手的模型」变成「群模型链」 |
| `generateTitleSource` | 同上两处 | 新增可空 `line` 参数；1:1 不传 → 输出逐字节不变 |
| `_maybeGenerateTitleFor` | 轮末回调、测试入口 | 新增 `_titleInFlight` 门：1:1 的并发重复请求被合并（原来是两次请求） |
| `runAssistantTurn` | 群轮 | `generateTitleOnFinish` 仍为 `false`，只是注释改写 |
| `_sendGroupMessageToConversation` | 群发消息 | 删掉 24 字截断，其余不变 |
| `_regenerateTitle`（侧栏） | 用户点击 | 改调 `resolveTitleModel`；群话题从此可用 |

侧栏那条路径是显式点击，不进 `_titleInFlight`（每次点击都是用户意图）。

## 测试

1. `resolveTitleModel`：群三档（title → director → current）、1:1 三档（title → 会话 → 助手 → 全局）。
2. 群轮末：`onGroupRoundFinished` 触发一次 `renameConversation`；第二轮结束不再请求（假 API 计数为 1，且不再增长）。
3. 并发：两轮背靠背只发一次请求。
4. 失败：无模型 / 空响应 / 抛异常 → 不 rename、不冒泡。
5. 侧栏「重新生成标题」在群话题上用 director 模型（假 API 断言 provider + model）。
6. `generateTitleSource`：群助手消息以 `林深: ` 开头且推理块被剥掉；1:1 输出与改动前逐字节相同（golden 字符串）。

## 不做

- 不给每个群单独配标题模型，也不给每个成员配。
- 不在回合中间（某位发言人刚说完）调标题模型。
- 不改标题提示词的默认内容。
- 不做话题自动编号、不做从首条消息预填的临时名。

## 落地记录

| 位置 | 改动 |
| --- | --- |
| `lib/features/home/utils/model_display_helper.dart` | 新增 `resolveTitleModel`：唯一一条标题模型链 |
| `lib/core/services/chat/chat_service.dart` | `generateTitleSource(conversationId, {line})`；1:1 不传 → 输出不变。`addMessage` 增加可选 `senderId`，让测试与工具路径能播种带作者的群消息 |
| `lib/features/group_chat/services/group_transcript.dart` | `titleLine(resolve)`：`[名字]: 公开文本`，剥掉 thinking |
| `lib/features/home/controllers/home_view_model.dart` | 轮结束触发、`_titlesInFlight` 去重、群话题走群模型链、删掉 24 字截断 |
| `lib/features/home/widgets/side_drawer.dart` | 「重新生成标题」改走 `resolveTitleModel` + 群渲染器 |
| `lib/features/home/controllers/chat_actions.dart` | 只改注释：每位发言人仍为 `generateTitleOnFinish: false` |

测试：`model_display_helper_test.dart`（链路四档 × 群/1:1）、`chat_service_cache_lifecycle_test.dart`
（自定义渲染器）、`group_transcript_test.dart`（标题行）、`home_view_model_title_test.dart`
（导演兜底、标题模型优先、已有标题零请求、连发只请求一次）。

侧栏那条路径是显式点击，不进 `_titleInFlight`（每次点击都是用户意图），但它与轮末共用
`resolveTitleModel`，所以群话题从此可以用「重新生成标题」。
