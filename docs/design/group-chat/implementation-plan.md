# 群聊实现计划（已完成）

> 状态：**已实现**。本文记录最终落地形态、与设计稿的差异，以及验证证据。
> 分支：`feat/group-chat`，基线 `f0c68d4f5`（master，schema 5）。

## 1. 目标（用户原话的七条）

1. 不升 schema version → 已守住，`AppDatabase.currentSchemaVersion == 5`。
2. 丢弃 v3 中间态，只按最终设计做。
3. UI / 数据结构重设计先走 clarity round（已完成 5 轮，见 §3）。
4. 一次做完整，不按“v1 只做 xxx”切功能。
5. 明确回答“一个群聊是否允许多个 conversation” → 允许，见 §2。
6. 输入框必须支持：助手 × n（折叠头像 → 成员清单 → 助手编辑）、附件/拍照/相册/粘贴、
   浏览器、上下文管理、迷你地图、上下文指示；架构要 DRY。
7. 桌面端与手机端同一套信息架构。

## 2. 最终结论（已获用户 accept）

- **一个群聊有多个会话（话题）**。群是拥有会话的实体；每个会话通过 `extras['groupChat.id']` 指向群。
- **群与助手混排在同一个侧栏列表**，共用一个拖拽顺序（`ChatOwnersProvider`）。
- **输入框左下角是一叠完全折叠的头像**，整叠一个按钮；点开是成员清单：成员 → 助手编辑、
  邀请助手、群聊设置。
- **导演模型只在群设置里出现**，作为“默认模型”的跳转入口。
- **不软删除**：群实体 + 全部会话放进同一个 `RecycleGroup`，走现有回收站；删除前先停掉该群所有
  在跑的整轮（与删助手同一条不变量：删除即停止）。
- **整轮占用**：用户消息 → 最后一个 speaker 结束，整轮持有 conversation claim；期间再次发送走现有单槽队列。
- **schema 仍为 5**：`extension_entity_rows(kind='groupChat')`、`conversation_rows.extras_json`、
  `message_rows.sender_id`。

## 3. 设计文件

| 文件 | 作用 |
| --- | --- |
| `architecture.md` | 完整架构：数据流、不变量、失败模式（初版） |
| `architecture-r2.md` | 定稿修订：`assistant_id` 对比、回收站统一、队列 |
| `variant-a-members.html` | 最终 UI：折叠头像 + 成员清单 + 导演跳转 |
| `variant-group-settings.html` | 群设置定稿：头像即入口、桌面/移动同一份菜单 |
| `topic-title-pipeline.md` | 话题标题流水线（模型链、触发点、失败模式、blast radius） |
| `variant-a*.html` / `variant-b.html` / `shot-*.png` | 中间稿，仅作记录 |

## 4. 落地清单

### 4.1 新增文件

| 文件 | 内容 |
| --- | --- |
| `lib/core/models/group_chat.dart` | 群模型：id/name/avatar/memberIds/maxSpeakerTurns(1..6)/时间戳，payload `v:1` |
| `lib/core/models/chat_owner.dart` | 侧栏行身份：`assistant:<id>` / `group:<id>` |
| `lib/core/providers/group_chat_provider.dart` | 群列表、`byId`、`forConversation`、create/update/delete（走回收站） |
| `lib/core/providers/chat_owners_provider.dart` | 混合顺序（存 `chat_owner_order_v1`），与来源对账 |
| `lib/features/group_chat/services/group_director.dart` | 导演：`select_speaker` / `end_turn` 工具调用，2 次尝试，20s 超时，失败返回 unavailable |
| `lib/features/group_chat/services/group_transcript.dart` | 压平转写（`[Name]` + 公开文本）、群说明、导演视角摘要 |
| `lib/features/group_chat/widgets/group_member_cluster.dart` | 折叠头像叠，整叠一个点击目标；>4 显示 `+N`；空群只有 ＋ |
| `lib/features/group_chat/widgets/group_member_list.dart` | 成员清单、成员选择器、新建表单、`GroupAvatar` |
| `lib/features/group_chat/widgets/group_settings_view.dart` | 设置主体：名字、成员增删、导演跳转、每轮上限、删除群 |
| `lib/features/group_chat/pages/group_settings_page.dart` | 移动端设置页 |
| `lib/features/group_chat/group_navigation.dart` | 打开清单/设置/邀请/新建（移动端 sheet，桌面 dialog） |
| `lib/features/group_chat/group_actions.dart` | `deleteGroupChat`：先停整轮再走回收站删除，两个入口共用 |

### 4.2 修改的关键位置

- `chat_message.dart` / `chat_database_repository.dart`：`senderId` 全链路（插入、更新、读取、复制会话）。
- `conversation.dart`：`groupChatId` 扩展读写；群会话 `assistantId` 恒为 null。
- `chat_service.dart`：`createConversation/createDraftConversation(groupChatId:)`、`beginUserMessage`、
  `beginAssistantGeneration/beginRegeneration(senderId:)`、`deleteConversationsForGroup`、
  `defaultConversationTitle`。
- `composer_draft_store.dart`：新会话草稿 owner 按 `group:<id>` 区分，避免群草稿串到全局会话。
- `business_data.dart` / `backup_content_filter.dart` / `business_settings_router.dart`：
  `BusinessEntityKind.groupChat`（`group_chats_v1`）、归入 `BackupCategory.chats`、payload 校验、
  `group_director_model_v1` + `chat_owner_order_v1` 进入偏好注册表。
- `business_repository.dart`：`deleteEntity(..., group:)` 公开回收站分组。
- `chat_actions.dart`：`sendGroupMessage` / `_runGroupRound` / `cancelGroupRound` /
  `runAssistantTurn`；`_setConversationLoading` 成为“整轮持锁 + 回合结算”的唯一收口。
- `home_view_model.dart`：群发送分支、首条消息命名话题、轮结束排空队列、群内停止走 `cancelGroupRound`。
- `chat_input_section.dart` / `chat_input_bar.dart`：`leading` 槽放折叠头像；群模式隐藏模型/搜索/
  推理/工具/快捷短语/学习模式，保留附件、浏览器、迷你地图、上下文管理与上下文环（两端一致）。
- `message_list_view.dart`：`resolveAssistant(message)` 按 `senderId` 解析作者；1:1 传 null 不变。
- `side_drawer.dart`：混合 owner 列表 + 同一拖拽顺序、群 tile（点击开最近话题/新建）、群话题过滤、
  “新建群聊”入口、群长按菜单（设置/删除）。
- `home_page.dart`：群模式标题不显示模型胶囊、composer 传群、消息列表传 resolver。
- `default_model_page.dart` + `settings_provider.dart`：全局导演模型（默认跟随默认模型，provider/model
  退役时清理）。
- `main.dart`：注册 `GroupChatProvider`、`ChatOwnersProvider`、LAN sync 重载。

### 4.3 与设计稿的差异（有意为之）

1. **导演失败提示是一次性 snackbar**，不是常驻提示条：群不会因为导演不可用而看起来坏掉，
   但也不会长期占位。
2. 群没有独立的标题提示词，也没有每群一个标题模型（见 `topic-title-pipeline.md`）。

### 4.4 收尾两轮（本轮）

| 需求 | 落地 |
| --- | --- |
| 群头像可编辑 | 头像即入口：`GroupAvatar` 走共享 `AvatarValue`（emoji / URL / 本地文件 / 兜底）；设置页点头像 → 共享 `showAvatarMenu`（桌面锚定菜单、移动端 sheet）；助手头像菜单与群共用同一份实现，五项动作、顺序、校验一致 |
| 话题标题走标题模型 | 触发点移到整轮结束（`onGroupRoundFinished`）；模型链抽成 `resolveTitleModel`（标题模型 → 导演模型 → 全局默认，群；1:1 链路不变）；`generateTitleSource` 增加逐行渲染器，群用 `[名字]: 公开文本`；删掉首条消息 24 字截断 |

随之删除重复实现：助手头像的两份菜单/三个对话框（`_showAvatarPicker`、`_openAssistantAvatarMenu`、
`_inputAvatarUrl`、`_inputQQAvatar`、`_pickEmoji`、`_pickLocalImage`）与 `_AssistantEmojiAvatar`，
合计约 700 行，改为 `lib/shared/widgets/avatar_menu.dart` + `avatar_value.dart` 各一份。

### 4.5 验收后的两轮

真机验收在 `dirty:499df492251c773b` 上判了三条问题，两条走了新的 clarity 轮：

| 问题 | 轮次 | 落地 |
| --- | --- | --- |
| 模型在回复前自发写 `[STEM Mentor v5]` | 伪代码轮（`topic-speaker-injection.md`，已接受） | 群转写不再把别人的话塞进 `assistant`：只有本人的轮留在 `assistant`，其余翻成 `user` 并套 `<group_message from="名字">`；`buildApiMessages` 给这类 user 轮打进程内标记且不发 revision id；「最后一条用户消息」（图片、搜索词、视频挂载）统一走 `lastHumanUserIndex` |
| 助手管理页没有群聊，两套拖拽顺序 | UI 轮（`variant-manage-page.html`，选 A） | 管理页与侧栏共用 `ChatOwnersProvider` 一份顺序；`AssistantProvider.reorderAssistants` / `reorderAssistantsWithin` 删除；侧栏标签段改走 `reorderWithin`；`+` 同时提供新建助手与新建群聊 |
| 桌面端「默认模型」看不到导演模型 | 无需决策 | `DesktopDefaultModelPane` 补上导演模型卡片（移动端 `DefaultModelPage` 早就有，桌面漏了） |

命名再走一轮（`variant-manage-page-naming.html`，选 B）：这一页叫「助手与群聊」，
`settingsPageChatOwners` 替换 `settingsPageAssistant`，`desktopAssistantsListTitle` 一并退场。

### 4.6 复核后的修复

独立复核给出 10 条问题 + 3 条待确认，按「数据不变量 / 产品选择」分开处理。

| 问题 | 处置 | 落地 |
| --- | --- | --- |
| 群话题里按 ↻ 会写出**没有作者**的回复，模型用的是当前选中的助手 | 修 | 群里的重来以**一轮**为单位：用户消息的 ↻ 删掉这条之后的整轮回复并重跑 `_runGroupRound`（`ChatActions.restartGroupRound`，与发送共用 `_claimGroupRound` / `_startGroupRound`）；助手回复不再提供 ↻（`onRegenerateMessage` 在群里传 null，null 现在等于「不显示」而不是「点了没反应」） |
| 群的第一条话题永远叫「新话题」，标题模型从不接手 | 修 | 占位标题收口到 `ChatService.isPlaceholderTitle`（会话占位 + 话题占位），启动时 `setPlaceholderTitles` 一次注入；侧栏与 composer 两条新建路径都用 `groupTopicTitle`；`_maybeGenerateTitleFor` 只问这一个谓词 |
| 未分组段拖拽跨过一个打了标签的行会丢 | 修 | 两段合成一个 `buildReorderableSection`：索引一律是本段索引，全部走 `reorderWithin`；旧的「全局 index + 段内 delta」算法删除 |
| 提示词邀请导演重复选人，runner 又拒绝 | 修 | 提示词改为「每位成员每轮最多一次，全员发过言就 `end_turn`」；轮次上限按 `min(maxSpeakerTurns, 成员数)` 夹紧；`_decode` 的拒绝留作兜底 |
| 选人列表不再跟随用户的拖拽顺序 | 修 | `ChatOwnersProvider.inOwnerOrder`，共享「移动到」sheet 与定时任务编辑器 |
| 被删掉的成员回复显示成当前助手的头像与名字 | 修 | 只有消息**没有**作者时才回退到会话助手；有作者但解析不到 → `groupChatRemovedMember` |
| 群话题参与记忆整理 / 会话摘要 / follow-up suggestions | 修 | 四处入口按 `convo.isGroupConversation` 直接返回（proactive care 本来就已排除） |
| 群话题的「移动到」把 `assistantId` 写到群话题上 | 修 | 菜单项对群话题隐藏；`_moveConversationToAssistantInternal` 加不变量守卫：群话题永远不写 owner |
| 导演没有测试 | 修 | `test/features/group_chat/group_director_test.dart`（8 条）：选中、已发言者标记与剩余轮数、未知 id、重复选人（重试一次后放弃）、`end_turn`、`turn_limit`、无工具模型、无模型；用本地 HTTP 服务回 `tool_calls`，与标题测试同一套骨架 |
| 「默认模型」Proactive care 卡片上方双倍间距 | 修 | 删掉重复的 `SizedBox(height: 16)` |

另有一条复核列在「待确认」、但按结构应当先修的：`runAssistantTurn` 的 waiter 原本注册在
`openAroundPersistedMessage`（一次 await 的读）之后，取消落在这个窗口里没有 waiter 可 settle，
`await waiter.future` 会一直挂着——注册提前到 `_activeAssistantMessages.put` 之后。

群设置里名字输入框的 400ms 防抖仍可能用旧的 `group` 覆盖 `maxSpeakerTurns`：需要一次
widget 测试才能确认，留待后续。

#### 4.6.1 留到后续

- **轮次循环本身的测试**：导演已经能单独测（本地 HTTP 服务回 `tool_calls`），但
  `_runGroupRound` 需要一个 fake 生成服务才能驱动整轮（流式回复、取消、fallback 的衔接）。
  这条路同样会覆盖 4.6 新增的「重来一轮」——它复用同一个循环，目前只有 analyzer 与手测。
- **群设置名字防抖**：输入名字后 400ms 内改「每轮最多发言」，旧 `group` 会把轮数写回去。
  需要一次 widget 测试才能确认，不盲改。

### 4.7 第二遍复核

第二轮复核给 9 条，全部复现；这一轮修 7 条，两条记录在 §4.7.1。

| 问题 | 处置 | 落地 |
| --- | --- | --- |
| 群话题出现在「某个助手的历史」里，且那里的「全部删除」删不掉它 | 修 | 两个列表的判据都补 `&& c.groupChatId == null`：无 `assistantId` 的**普通**会话才属于「全局」那一支，群话题属于它的群 |
| 一轮进行中按用户消息的 ↻ 会起第二轮 | 修 | `restartGroupRound` 认 `_roundLoadingConversations`：一轮的状态挂在 loading 标志上，`isSendInFlight` 看不见它；同时在跑就回 `in_flight`，不再起第二个循环 |
| 导出把每条群回复写成当前选中助手 | 修 | 导出的署名统一走 `_authorOfMessage`（`senderId` → 成员，否则当前助手），四处角色名与两处气泡头像同步 |
| 导演决定期间 Stop 不生效 | 修（部分） | `GroupDirector.decide` 收 `isCancelled`，决定落地后不再重试第二次；单次 20s 的请求本身没有取消键，这一半留待后续 |
| 批量「移动到」会选到群话题然后什么都不做 | 修 | 选择集合先滤掉带群的会话；全被滤掉就直接返回，不弹选人面板 |
| 成员的视觉正则从没作用到群回复 | 修 | `ChatMessageWidget` 新增 `author`，视觉正则用它；消息列表把已经解析好的作者传下去 |
| 删群时正在一轮中间，轮次停不下来 | 修 | 删群时对该群每个话题都 `cancelGroupRound`，不再只挑「此刻在生成」的 |
| 压缩群话题会把所有发言并成「Assistant」 | 未修（§4.7.1） | — |
| 恢复单个话题时群实体已被物理删除 → 没有任何 owner 列表收留它 | 未修（§4.7.1） | — |

#### 4.7.1 两条走向（已拍板并落地）

- **群话题的上下文压缩 → 补署名**：`GroupTranscript.compressionLabel` 作为
  `ChatService.compressionLabelOf` 注入，压缩源的行按 `[名字]: …` 写；1:1 保持 `Assistant/User`。
  预热对话框读同一个钩子，所以预览与实跑同源。
- **孤儿话题 → 显示层降级，不改数据**：群解析不到时，侧栏照常列出（按普通会话）、发送落到 1:1、
  重来自 1:1 路径；作者解析的门槛从「这是不是群」改成「这条消息有没有 `senderId`」。
  话题仍然声称属于那个群，群日后从回收站还原就自动变回群话题——没有不可逆的一步。
  `GroupChat.deletedAt` 与 90 天扫描（§7）仍未实现，作为后续；`architecture.md` §10 的
  「提示群已删除」也还没做。

### 4.8 第三遍复核

第三轮复核给 10 条，全部复现并修掉；另有 2 条“未验证但形状如此”的挂起路径一并封了口。

| 问题 | 修法 |
| --- | --- |
| 内联 `resolveAssistant` 闭包让消息列表每次重建都走全量重测 | 列表不再收回调，直接收 `AssistantProvider`：同一实例跨帧稳定，度量守卫按身份比较。宿主 build 里新建的闭包天生不 `identical`，把正确性做进参数类型，而不是靠调用方自觉 |
| 侧栏删群后页面停在空会话，下一次按键落到新建的 1:1 | 删前取该群的话题 id 与下一个会话，删后 toast + 走 `_handlePostDeleteNavigation` |
| 最后一个成员能被移除 | 只剩一人时设置页不渲染 ✕，`_removeMember` 同时拒绝（不只靠 UI） |
| 补答旧 ask-user 卡片会顶掉轮次里正在生成的回合 | 卡片入口认 `isGroupRoundLoading`；`continueAssistantMessageAfterToolAnswer` 同样加判据——轮次把 claim 交给了 loading 标志，只看 `isSendInFlight` 看不见它 |
| 群话题列表里批量“移动到”什么都不做 | 选择里没有可移动会话时，批量条不渲染“移动到”（单条菜单早已隐藏） |
| Stop 落在 speaker 准备阶段仍会生成整条回复 | `beginAssistantGeneration` 之前再查一次 `isGroupRoundCancelled`；此时还没有占位行，直接返回 null |
| 用户离开话题后导演看不到前面发言的正文 | 回合结束后 `_messages` 里找不到就回库读（`loadMessagesByIds`），不再把空占位当发言 |
| 孤儿话题里按“+”又造一个挂着死群的新话题 | 继承来的 `groupChatId` 先确认群还在；显式传入的不受影响 |
| 删群再从回收站还原，侧栏位置跑到最后 | 顺序表保留“暂时不存在”的 key（墓碑），只从 `_owners` 里隐藏；显式拖动才压缩掉墓碑 |
| 杂物：重复注释、无引用的 `assistantSettingsPageTitle`、无引用的 `GroupChat.isEmpty`、r2 文档的孤儿话题承诺 | 注释去重；ARB 键四处删除并重生成；`isEmpty` 删除；`architecture-r2.md` 改成与实际一致的“按普通会话继续用” |

另外两条挂起路径：`generate()` 里所有会抛的语句移进 `try`（`unawaited` 会让 waiter 永久挂起）；
`sendGroupMessage` 落库失败会归还轮次 claim（否则 loading 一直举着，Stop 也清不掉）。

已知未改，记录在案：`_openGroup` 取最新**已落库**话题、忽略未发送草稿；群删除时草稿话题按设计
丢弃、不进回收站（`architecture-r2.md` 已写明）。

### 4.9 第四遍复核

第四轮给 6 条，全部复现并修掉；复核自己标了「未验证」的 4 条里，3 条确认成立，一并修了。

| 问题 | 修法 |
| --- | --- |
| 删掉的群在回收站里被归到「设置」、标签是「配置」 | 回收站补 `groupChat` 这一 kind：标签「群聊」、图标、独立的「群聊」筛选页；「设置」页显式排除它。详情页那份重复的 switch 一起补 |
| 导演决定期间按 Stop，loading 要等到模型回答（最多 20s） | 导演请求用会话 id 注册 `requestId`：Stop 走 `cancelStreamingById` → `ChatApiService.cancelRequest(cid)` 直接掐断请求；catch 里认取消并立刻返回 `cancelled` |
| 编辑群成员的回复会写出一条 `sender_id = NULL` 的新版本 | `_appendMessageVersion` 带上原作者 `senderId`；`_messageUpdate` 改成「快照没有作者就不写这一列」，让擦除在结构上不可能 |
| 群删除对话框承诺回收站，未发送的草稿话题却被直接丢掉 | 对话框补上 1:1 已有的 `composerDraftDeleteNotice`——草稿只存在于 composer，无法入回收站，所以是改承诺而不是改行为；两个入口都补 |
| 导演重试发的是逐字节相同的请求 | 第二次尝试追加一轮 user 提醒（只许用工具、可用 id 列表），与设计稿 `architecture.md` §5 一致；`temperature: 0` 下这才算第二次机会 |
| `MessageListView.assistants` 上叠了两段文档注释 | 删掉描述已被移除的回调的那一段 |

复核标「未验证」的三条也修了：导演的泛化 `catch` 不再吞掉已经捕获的决定（原来的 `break` 会跳过处理块）；
`_messageUpdate` 的 `senderId` 归一；设置页「+」在桌面端什么都不弹——补 `anchorKey`
（桌面布局也推这个页面，所以按钮是可达的死按钮）。剩一条「首启时顺序先写空」会自愈，不动。

### 4.10 第五遍复核

第五轮 6 条：4 条真缺陷（1、2、4、5），1 条是数字算错（3），1 条是陈旧列表 + 死代码（6）。全部修掉。

| 问题 | 修法 |
| --- | --- |
| 切换语言后新建的 1:1 不再自动命名 | 占位标题从「启动时抓的两个字符串」换成「所有语言的所有占位标题集合」（`localizedPlaceholderTitles()`），判据变成「这个标题是某个已知占位」；群话题的创建标题也改读当前 l10n，不再用冻结值 |
| 通知栏取消只停一个 speaker，群继续说话 | 后台任务取消时，轮次持有 loading 就走 `cancelGroupRound`，否则只停流 |
| 群话题里上下文占用按「选中助手」的模型算 | 群话题隐藏该入口，与同一个 composer 里 reasoning / search 的处理一致：一个话题没有单一模型可测 |
| 删单个群话题不停止轮次（还会弹 `conversation_missing`） | `cancelActiveGenerationFor` 先看轮次占用，有就 `cancelGroupRound` 再返回 |
| `sendGroupMessage` 不读轮次占用 | 补上判据，与 `restartGroupRound`、`continueAssistantMessageAfterToolAnswer` 一致 |
| 成员面板显示快照；三个公开成员没人引用 | 面板改成 `Consumer2` 读活的群与成员；删掉 `GroupTranscript.isBlankAssistantTurn`、`ChatOwner.tryParse`、`ChatOwnersProvider.groupOwners` |

未验证项里修了一条：`main.dart` 把占位标题与压缩署名拆成两个 `try`——原来任一处抛异常，另一个就整个进程都空着。
其余三条记录在案、未改：第二个写者与 dispose 挂起都依赖「同一对话两个轮次」（第 5 条已把入口补齐），
`_titlesInFlight` 丢一次命名会在下一次轮次结束补上。

## 5. 验证
- `dart analyze --fatal-infos lib test integration_test` → **0 issue**。
- 新增测试（14 + 22 = 36 条，全绿）：
  - `test/core/database/group_chat_schema_test.dart`（schema 5、实体行、备份分类、payload 路由、
    `senderId` 写入/重写/复制、1:1 无作者）
  - `test/features/group_chat/group_transcript_test.dart`（压平、丢弃 reasoning/tool/image、
    作者名占位、群说明、导演转写折叠）
  - `test/features/group_chat/group_member_cluster_test.dart`（折叠叠一个点击目标、`+N`、空群、
    成员清单、新建表单校验）
- 全量 `flutter test`：**11 434 passed / 70 skipped / 70 failed**，失败全部落在已登记的
  平台集合与两条已记录的满负载 flake 上，没有一条与本改动相关：
  - 64 `browser_native_engine_test`、`storage_image_usage_test`、`browser_page_card_test`
    —— `docs/flaky-tests.md` 登记的 Windows/无 WebView2 集合；
  - `backup_encryption_test` 取消用例 —— teardown 删临时目录 `errno 32`，文件本次未改；
  - `search_request_logging_test`、`mcp_provider_remote_session_test` —— 满负载下偶发，
    单独跑分别通过（后者 22/22）。

## 6. 未做（明确排除）

- 不升 schema、不加列、不做 90 天软删扫描。
- 不持久化导演日志/消息。
- 群话题不参与 1:1 的 follow-up suggestions、proactive care（标题已改为走标题模型）。
- 侧栏用户头像那一份“链接 / QQ”对话框仍是独立实现，未并入共享菜单。
