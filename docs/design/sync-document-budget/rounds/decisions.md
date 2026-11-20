# 决策记录：一次推送的字节预算

> 一轮一个决定，按轮次追加。目标书是输入，本文件是**已定的**结果。
> 目标书：`../plan.md`（基 `04c1e594e`）

| 轮 | 决定 | 结论 | 落下的东西 |
| --- | --- | --- | --- |
| 1 | 余量怎么来 | **A｜先量后分**（非 B 固定 15%） | 固定部分先量，会话吃剩下的；G0 变成等式；上限搬进 `sync_limits.dart` |

## 轮 1｜余量取 A（先量后分）

- 选项：A 先量不依赖"发哪几个会话"的部分（业务面、skill 哈希、workspace 表，资产清单按计划全集
  取上界），会话吃剩下的；B 固定留 15%，不量。
- 结论：**A**。
- 理由：G0 不可协商，而 A 是唯一能把"不会 413"变成一条算式的形状——
  `body = fixed + Σ bytes − 1`，`Σ bytes <= budget − fixed` ⇒ `body < 上限`。
  B 的 38 MB 余量与业务面大小之间没有任何联系，业务面或 workspace 表超过它时照样 413，
  而那一轮已经白发。
- 代价（已接受）：引擎读顺序提前（业务面 / workspace 快照与表 / 资产清单到准入前）、
  资产清单算两次（全集量、准入集发）、上限常量从 `sync_server.dart:906` 搬进 `sync_limits.dart`。
- 计划书没列、本轮补上的三项交付物：
  1. 报告字段要落**两处**——面板读的是持久化的 `SyncPeerReport`
     （`sync_report_breakdown.dart:25` ← `sync_store.dart:906`），只加 `SyncSessionReport` 面板看不见；
     `syncReportHasRow`（`sync_messages.dart:180`）也要算上它，否则"只有被跳过的会话"的一轮不出卡片。
  2. 一句新文案 × 7 个 ARB + `flutter gen-l10n`。
  3. `_syncMaxBodyBytes` 是 `sync_server.dart` 的私有常量，不搬进 `sync_limits.dart` 就谈不上"派生关系"与那条断言。
- 用户附加约束（本轮开工前必须满足）：**延迟发送不能把自己坑了**——不许因为"这轮不发"导致后续丢数据。
  先派子代理审计现有 deferral 路径（`skippedSends`、`peerDeferred`、fetch beat 的 `skipped`、
  `_advanceCheckpoint` 的各分支），审计结论进 §5 状态表；有坑先修，再谈准入。

## 轮 1 之后｜审计：延迟发送里的数据丢失（先修，再准入）

- 触发：轮 1 的附加约束——「延迟发送不要把自己坑了（导致后续丢数据）」。只读审计现有 deferral 路径
  （`skippedSends`、`peerDeferred`、fetch beat 的 `skipped`、`_advanceCheckpoint` 的各分支、删除 oracle）。
- **发现（数据丢失，已实证）**：`_advanceCheckpoint` 的两条发送臂只有一条检查"本机这一半到底发了没有"。
  `iSend` 有 `skippedSends` 守卫；`bothSend` 只判 `outcome.deferred`/`peerDeferred`，然后就用 apply 的结果
  建检查点。被跳过的 `bothSend` 会话在应用对端副本之后，检查点写成「双方已一致」——包含对端从未收到的本机行；
  下一轮计划读成 `peerSends`，拉到一份没有那行的副本，合并按「本地独有 + 时钟等于记录」把它删掉。
  今天的流式跳过侥幸不触发：`isStreaming` 同时让 apply 延期，`outcome.deferred` 保住了 prior。体积跳过不延期，
  于是每轮都触发——把「这轮没发」变成数据丢失。
- **发现（测试盲区）**：`iSend` 的安全是两条路都对（守卫 + `sent == null → prior`），只覆盖 iSend 的测试
  永远红不了；原来没有任何测试碰 `skippedSends` 分支。
- **修法（先于准入落地）**：两条臂问同一个问题——**这批 payload 过线了吗**——
  `sentSubtrees.containsKey(id) && sendsConfirmed`。`bothSend` 从 `peerSends` 里拆出来（后者不发送，不能加这条守卫）。
  `skippedSends`/`missingIncoming` 两个参数删除（后者本就是死参数），fetch beat 的 `bothSend` 一并修好。
- **证明**：注入「去掉 `!sentSubtrees.containsKey(id)`」→ `an omitted bothSend conversation keeps the edit it
  did not send` 变红（`conv-a-aonly` 被下一轮删掉）→ 按 SHA-256 还原。记录见 `guard-injections.md`。
- **未修，记为限制**（ADR-0003 追加）：fetch 响应没有上限（256 MB 只盖请求体），超大会话只能靠对端拉取到达；
  不分片仍在计划书的非目标里。`deferred` 计数是展示用，尺寸跳过也计入它（`conversationsOmittedForSize` 单独点明原因）。

## 轮 1 之后之二｜实现里撞到的两个细节（记录，不改决策）

1. **资产清单只在有会话被裁掉时重建。** 初版对"计划全集"量一次、对"准入集"再建一次；一个既有测试
   （`a blob whose pull failed is referenced before it lands`）立刻变红：它模拟文件在哈希之后消失，
   于是第二次构建把这条广告从真正发出的清单里抹掉了——接收方是靠**广告**登记引用的，广告没了，
   那条引用就成了垃圾回收的肉。改成：没有会话被裁掉时直接复用量的那一份（与改造前逐字节相同），
   只有确实裁掉了才重建。代价从"永远两次"变成"通常是零次额外"。
2. **单会话上限需要引擎级的一格。** 只有纯函数测试时，`maxConversationBytes` 是"从没被传过"的参数
   （`unused_element_parameter`）。补了 `a conversation past the per-conversation cap is left behind alone`：
   预算给到上限的十倍，超限的那条仍然不发，其余照发。

## 评审轮（PR 复审）｜六条意见，逐条核过

评审给了六条（按 Sev+Occ 排序），我逐条在代码里核过：**六条都成立，没有误报**。处理如下。

| # | 意见 | 处理 |
| --- | --- | --- |
| 1 | l10n `state` 指纹没写，CI 的 `translate.py check` 红 | 用工具自己的 `fingerprint()` 给 ru/ko/tr/zh_Hant 补了条目（`sync` 会让模型重翻译，而这几条译文是我按现有源手写的，指纹记的就是这份源）。`translate.py` 的 `check` 还要求 `tool/l10n` 的依赖在场，本地补齐后四个 locale 的 `pending` 都是 0 |
| 2 | 同一个会话在 `deferred` 和新行里各算一次 | `deferred` 回到"生成中 / 读不到"两个原因；`withheld` 补上尺寸计数——否则"up to date"会盖住它；加了一格 widget 测试断言两个数字不重复画 |
| 3 | 没有测试证明引擎真正发出的 body 在预算内 | 发送点加 `assert(assertPushFits(pushBatch, deltaByteBudget))`，量的是 `pushDelta` 收到的那一份；`assertPushFits` 单独成函数、可单测（恰好等于预算通过，少一字节抛错）；注入证明见 `guard-injections.md` 第 6 条 |
| 4 | `peerSends` 与 `bothSend` 两份逐字相同的 apply→检查点 | 两个 case 合成 `case SyncConvAction.peerSends \|\| SyncConvAction.bothSend`，守卫收成一句 `myHalfCrossed` |
| 5 | "retried next time" 对超过单会话上限的会话永远不成立 | 文案改成 `{count} conversations too large to sync (trim their history)`（五处 + 英文描述）：不承诺做不到的重试，给出用户能做的动作 |
| 6 | `kSyncDeltaHeadroomPercent` 存的是可用份额（60），不是余量（40） | 改名 `kSyncDeltaBudgetPercent`，注释点明"名字带另一侧会让『多留余量』把余量砍半" |

评审另外三条"未能验证"，处理：

- **注入记录的哈希对不上**（`907B8100…` → 评审看到的 `B2A4B232…`）：中间还有 `sizeOmitted.isEmpty` 的清单改动，
  那份记录确实证明的是一个已经不存在的文件。已在当前树重跑，记的是 `5D1A0149…`（193,925 字节），字节级还原。
- **`gen-l10n` 的字节一致性没有复核**：ARB 改完后重跑过一次，`git diff -- lib/l10n` 只剩预期内的生成差异；
  `dart format` 对生成文件 0 改动。
- **空批次的算术边界（`envelope > budget`）**：ADR 里补了一段——固定部分不受准入约束，这是本 PR 的已知边界。

一条自查：**`translate.py check` 的 Dart 校验器**（`validate.dart`）在沙箱里跑不起来（子进程管道被拒）。
能本地复核的部分都复核了：四个 locale `pending=0`、key 集合与 en 一致、`zh_Hans == zh`、占位符只剩 `{count}`、
ru/ko/tr 无残留汉字、换行数与 URL 未变；ICU 语法由 `flutter gen-l10n` 全量解析通过证明。

## 评审轮之二｜三条意见，全部成立

| # | 意见 | 处理 |
| --- | --- | --- |
| 1 | 接收臂（`peerSends` / `bothSend`）的检查点条目来自合并快照，会话窗口里写的行被记成"对端已有"，下一轮删掉 | **修**：`peerSends` 按收到的 payload 建条目（与对端 `iSend` 对同一 payload 建出的条目逐字节相同）；`bothSend` 是两份 payload 的合并、单一 payload 描述不了，于是只要快照里有"两份 payload 与上次约定都不认识"的消息行，这一轮不推进、留 `prior`，下一轮连那行一起发出去。响应方 push beat 的 payload 存进 `_ResponderSession.receivedSubtrees`，fetch beat 用它建条目 |
| 2 | 卡片说"太大，无法同步（可精简历史）"，但多数只是"本轮没塞下"，下一轮自己就发了 | 文案改中性：`{count} conversations did not fit in this push`（五处 + 描述）；不再给错误建议 |
| 3 | 一个会话既被体积跳过、又被对端拒发时，两个计数各算一次 | 计数按**集合**切分：`deferred = {skippedSends ∪ missingIncoming} \ sizeOmitted`；响应方的 `skipped` / `missing` 同理去重 |

评审留下的三个文件都处理了：`probe_bothsend_unsent_row_test.dart` 与 `probe_bothsend_midapply_snippet.txt` 删除
（它证明的场景已由两格正式集成测试覆盖），`probe_envelope_over_budget_test.dart` 收编成正式断言
（它暴露的是真的：发送点断言会把 ADR 承认的边界变成 debug 下的失败，现在放过该边界）。

**残留（写进 ADR）**：`bothSend` 的脏快照检测只看消息行（检查点不索引别的族），窗口里多写一条 artifact
会让那一轮白同步一次，不删数据。

## 评审轮之三｜第三条写者，与四处过期的说法

| # | 意见 | 处理 |
| --- | --- | --- |
| 1 | `none` 臂的条目来自 advance 时刻的实时读，会话窗口里写的行被记成"对端已有"，下一轮删掉 | **修**：在 `buildManifest()` **之前**取时间戳（发起方、响应方各一处，响应方存进会话）；`checkpointFromLocal` 之后，条目里只要有行的时钟晚于这个戳，这一轮**不刷新**（保留 prior；没有 prior 就不写——没有条目意味着不推断任何删除，是安全的）。下一轮该行在两侧 manifest 里，条目自然刷新或该行被发出去。新增集成格：`a none heal does not record a row written during the session` |
| 2 | 四处注释/文档仍写着"办法是用户精简历史" | 改掉：`sync_engine.dart`（字段文档）、`sync_models.dart`（字段文档）、`sync_report_breakdown.dart`（行内注释）、`CONTEXT.md`。改成"多数是计划尾巴、下一轮自己会发；只有超过单会话上限的那条要靠对端拉取" |

**为什么第一版测试是假绿**：删除只发生在**取回**一份不含该行的副本的那一侧；响应方是把自己的副本发出去，
不会删。第一版把第三轮交给响应方发起，注入下仍然绿；改成本机发起后才红（教训记进 guard-injections 第 10 条）。

**第二处遗漏的来源**：第二 commit 改的是"卡片文案"和"ADR 段落"，但字段文档、行内注释和 `CONTEXT.md` 是
第三批读者，没有被同一次编辑覆盖。这一轮的规则记下来：**改一句话的断言时，把所有写着这句话的地方一起改**
（grep 文案里的关键名词，而不是只改渲染它的那一处）。

**残留（写进 ADR）**：戳看不到窗口里的**重命名**——会话行的时钟与 digest 变了，但没有被索引的行变，
所以条目会声称一个对端没见过的标题；下一轮合并没有损失（本地行时钟更新，赢），只是多一轮。

## 评审轮之四｜两个时钟，和一个对不上的哈希

| # | 意见 | 处理 |
| --- | --- | --- |
| 1 | `none` 的边界只看消息时钟，而条目自己的时钟是会话行的——改名/置顶/选版本只移动它；记成"已约定"之后，下一轮按被污染的时钟判 `iDelete` 删掉本地副本 | **机制成立，后果没有复现**。实测：窗口里改名后条目时钟比约定晚 359 µs（红在 `Actual: <1795176986870311>`）。但评审说的删除没有发生：把同一格的不变量断言临时去掉、在未修的树上跑，副本仍在——对端的删除公告带的是**它自己**的诚实时钟，`_announcementKills` / `_conversationDeletionStillStands` 的公告分支把它挡住了。修法仍然采纳：`entry.updatedAtUs > mine.updatedAtUs` 纳入边界，条目不再依赖隔着一千行的机制才不说谎 |
| 2 | 2–5 四条守卫记录钉在 `04A22122…`，对不上任何提交 | **成立**：那是**注入当时**的工作树状态，之后 `sync_budget.dart` 又改过（`assertPushFits` 的 `envelopeBytes`），所以没有提交带这个哈希。已在当前树（`429D0A5A…`，6,036 字节）重跑同一组注入，6 红 / 4 绿，结果与当时一致 |

**ADR 里那句是错的**，已改：会话行的改名**不**移动 digest（`syncConversationDigest` 不含 root 族），
所以"digest 变了、下一轮本地时钟赢、只多一轮"这个推论从第一步就不成立。正确的是：这条写只有行时钟承载，
而计划里的删除分支正是读它——所以边界必须盯两个时钟。

**教训**：`assertPushFits` 那次修补是在记录之后改的文件，而记录写的是"注入当时"的哈希；以后任何"字节级
还原"的记录都要在**最终树**上重跑一次再写，或者写明它对应哪个提交。第 1、7、8、10 条是这么做的，2–5 条不是。

## 评审轮之五｜`bothSend` 的守卫要比时钟，不是比 id

| # | 意见 | 处理 |
| --- | --- | --- |
| 1 | `bothSend` 的快照守卫只比 id；**编辑**一个已有消息保留 id、只移动时钟，于是编辑的时钟被记成"已约定"，对端后来删这一行时按"本地没动过"删掉 | **成立，已修**。守卫改成"快照里每一行的时钟必须等于对端副本在同一 id 上的时钟"。对端副本是理想证人：它在响应方应用完本次推送之后才读出。注入（退回只比 id）得到 `Expected: 'edited while syncing'` / `Actual: <null>`，还原后哈希 `F76F1CAE…`。新增集成格 `an edit during a bothSend session is not recorded as the agreement`；记录见 `guard-injections.md` 第 12 条 |
| 2 | ADR 的"超过单会话上限是用户必须动手的那一种"与本 PR 自己的卡片/后文矛盾 | 改成"只在**对端拉取**时才到达"，与下面那段和 `CONTEXT.md` 一致 |

**写这一格时踩的坑**：第一版用 `syncReadMessageRows` 读 `content`，拿到 `null` 就断言"行丢了"——其实会话正文
不走账本行（作为 document 走，投影里没有 `content` 列），改用 `repository.getMessage` 才读到。测试的读法
也要和被测语义对齐，否则"红"证明的不是缺陷。

**评审的未验证项**（`COALESCE(updated_at, timestamp)` 下，一条被**回填时间**的插入可能落在戳之下）已按它建议
的写法把边界写进 ADR：正常写路径同时移动会话行（第二半戳住），会漏的是"原始导入、不改会话行、写进已settle
的会话"这一形状——今天没有已知的这样的路径。
