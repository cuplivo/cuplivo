# ADR-0050: Preset-Only Conversation Recycle
<!-- - summary: 纯预设会话在用户切走时回收,判定走 repo SQL,不加启动清扫 -->
<!-- - status: accepted -->

Issue #578: 一个带预设消息的助手,每次"普通对话 → 新对话 → 纯预设垃圾对话 → 回到普通对话 → 新对话"循环都会持久化一条从未被使用的纯预设会话,最终堆积大量垃圾对话。现有守卫 (`_shouldBlockNewConversation`, 只挡"当前会话已是纯预设"时的再次创建) 无法阻断这个由普通对话出发的循环。

## Decision

**纯预设会话 (preset-only conversation)** = 持久化消息全部 `isPreset = true` 且至少一条。对它:

1. **回收只发生在"切走"**:`HomeViewModel.switchConversation` 切换完成后,先存下旧会话 id,再 `await deleteConversation(oldId)`(全路径:回收站 bundle + LAN-sync 删除标记)。失败仅日志。
2. **判定走 repo 层 SQL**,不用 ChatController 加载窗口(360 条截断会 fail-open)。
3. **+ 入口保持拦截**(snackbar `homePagePresetConversationBlocked`),不改为 delete-and-create。
4. **不做启动清扫**。
5. **关联修复**:排队发送 `_queuedInput` 从全局单槽改为 per-conversation `PendingSendQueue`(每会话一个槽):A 的队列不再拒绝/遮挡 B 的发送,不切走清队列(入队时草稿已清,清队列=丢用户文字);队列仅在目标会话为当前且 streaming 结束时补发。b10 静默 `rejected` 改为 debugPrint 可见。Multi-AI 路由(`HomePageController.sendMessage` 多 AI 分支)与单模型路径共用同一 busy gate,多 AI 轮内发送不再并行叠轮。

## Why this shape

- **切走回收 ⇒ 循环的每个出口都自洁**:循环的每一步都包含"用户离开纯预设会话"(回到普通对话),回收恰好挂在这个唯一切点上,无需理解全部创建路径。
- **+ 保留拦截而非回收重建**:delete-and-create 会在回收站制造"删除→恢复→又删除"的循环记录,且每次点 + 都付出一次 DB 删除 + trash 写入;纯预设会话被拦时提示用户"先发送消息",引导用户基于它生成真实内容(这是预设消息的本意)。若用户真想要另一个会话,先切走再 +,切走时旧会话已被回收。
- **repo SQL 判定**:`is_preset = 0` 计数为 0 是精确谓词;窗口判定在长会话上失真,守卫的 fail-open 正是 #578 循环的暴露面之一。
- **不做启动清扫**:启动清扫会删除"用户从未离开"的会话——某些用户可能正在用"只写预设、慢慢补消息"的方式工作;回收是"离开"后的动作,天然尊重用户正在使用中的会话。残留(gc 无法触达的)文档标注,用户可手动删除。新增"启动时回收"的代价是误删在对话进行中的会话,权衡后拒绝。
- **全路径 deleteConversation**:垃圾会话无恢复价值,但"回收站里删掉的会再生"比"神秘消失"更可预期;更关键的是删除标记让 LAN 对端/备份对端同步清理,避免对端残留。旁路直删会在多端一致性上开洞,不值。

## Considered and rejected

- **启动清扫**(扫全库纯预设会话并删除):误删用户正在使用的会话;且不与"切走回收"的语义正交,后面看其实想复用同一个谓词但时机不同。
- **delete-and-create 接替 + 入口守卫**:回收站污染 + 每次 + 一次 DB 写。已拒绝(见上)。
- **预设注入不落库**(改为 draft,真实消息才持久化):最彻底,但颠覆 e995b84f 的折叠 UI + 持久化语义;本次是 bug 修复,不重写特性。
- **窗口判定**:窗口截断时"预设之外的真实消息"可能没被加载,判定失真。已拒绝。
- **回收站旁路硬删**:丢失 LAN/备份删除传播。已拒绝。

## Consequences

- 纯预设会话在用户切走后不可见(删除),其未发送的文字仍在全局 `chat_draft_v1`(草稿不跟会话走,切回其他会话输入框保留),但无法回到被回收的会话继续写——接受。
- 回收在切换后执行,await 之间当前会话已切换,不存在删除当前会话的竞态(deleteConversation 会在 `_currentConversationId == id` 时清空它,而那时 current 已是新会话,判定不会命中)。**残余窗口(接受)**:切换无锁,用户可在回收在途时快速点回旧会话;回收前会重检 `currentConversation?.id == conversationId`(命中则跳过),窗口缩窄到"重检后 → deleteConversation 首个 await 前",正常交互下攻击不了,如实记录。
- 排队发送(`_pendingSends`)现在是 per-conversation 槽:跨会话不再互相拒绝,普通排队不误清;队列只在目标会话为当前且空闲时补发(从另一个会话切回时自然补发)。
