# ADR-0020：局域网同步按页传输——游标是唯一真相源

- 状态：**已接受，已落地**（2026-11 决定并实现）

## 落地记录（与设计的差异，按发现顺序）

实现时有四处设计与代码不符或设计漏掉的东西，记在这里，因为它们比结论本身更容易忘：

1. **一条消息的正文不在它的行里。** `message_rows` 的行只是元数据，正文与片段存放在
   `message_part_rows`。所以「按行累计字节」量出来的页远小于真实体积——第一版页面
   全部超预算。页读取现在是两段：先装行、再装该范围的 parts、最后按整页字节**修剪**
   尾部（修剪会把「末页」降级成普通页，下一页再当末页）。
2. **不可切分的行要能溢出。** 一条消息加上它的 parts 可能大于一整页；它仍然独占一页。
   `readSubtreePage` 因此返回 `overflow`，发送端的调试断言用它放宽边界——否则 release
   能发的东西 debug 会抛异常。
3. **页的摘要必须包含 parts 的身份。** 发送端合成 checkpoint 条目时若只累计消息行，
   digest 与接收端按自己状态算出的那个永远不等，于是下一轮把对端读成「改过」，开始
   反复双向推送。`_TransferProgress` 因此还累计每个 part 的 `(revision_id, ordinal,
   clock)`——只累计身份，不累计正文，几十万行也只是几 MB。
4. **空计划的那一次 push 也要带资产清单。** 技能正文是 blob，接收端从广告里登记引用；
   只带 business 不带 assets 时，记录到了、正文永远不被计划。这个洞是「技能正文谁都
   取不到」那条测试抓到的。

另外两处行为随之改变，都记进了测试：

- 一次会话里「一个 push」变成「每页一个 push」，`handleApplySubtrees` 的
  `push_already_taken` 守卫删除；`push_required`（fetch 之前必须先有 push）保留。
- 报告里的「N 个对话没能放进本轮推送」整项删除；被对端延后的页现在计入 `deferred`。

## 审查发现的五个问题（已修）

代码审查在合并前抓到五处，其中两处是我这一版引入的静默数据损坏：

1. **末页会丢掉整页的 parts。** parts 按 `messages.first..messages.last` 的区间读，而末页补发
   的「游标漏掉的行」排在页首之前，区间因此塌陷——整页的 parts 一条不剩。两侧于是用一个
   不含 parts 的 digest 记为「已一致」，发送方本地还留着正文，接收方没有。改为两段读：页内
   连续区间 + 补给行按 id 查（`syncReadPartRowsByIds`）。
2. **修剪是 O(行数) 次查询与整页编码。** 现在页先按行预算装满，再读这一页的 parts，逐行
   记账后**在内存里**修剪：一次区间查询、每行只编码一次。
3. **每个 push beat 都重跑会话收尾并覆写会话字段。** 只有携带业务/工作区/技能内容的那个
   beat（首页）拥有这些字段；后续页不得用空值覆盖——被覆盖的正是 checkpoint 保存的那份
   文件 ledger。blob 拉取仍按页进行，其结局用 `absorb` 合并，失败项不会因为后一页成功而
   消失。
4. **发送进度的三个占位符顺序。** gen-l10n 按字母序排参数，`lanSyncPhaseSendingOf` 实际是
   `(bytes, done, total)`；调用点按阅读顺序传，三个都是 `Object`，分析器看不见。已改并加
   测试钉住。
5. **`CONTEXT.md` 与 ADR-0003 仍在描述已删除的预算机制。** 两处都已改写：CONTEXT 换成页
   传输的四条规则，ADR-0003 那一节标记为 superseded 并指向本文。

审查另外指出、我在同一轮处理掉的两点：

- **方向强制原先只写在 ADR 里。** `composeConversationPlan` 现在真的读 `cursor`：半发强制
  `iSend`、半收强制 `peerSends`，并且只在本地确实还持有该对话时生效。
- **`SyncFetchRequest.after` 是死字段。** fetch 方向还没分页，所以字段移除了——协议不为
  「以后会用到」保留形状。

## 第三轮审查（提交 cc5bf1ffe 之后）

1. **中断的会话不写游标**（已修）。checkpoint 只在会话走到终点时保存；deadline、退后台、断线都
   从 catch 走 `_finish`，只写对端记录。于是「续传」实际只有「对端延后」一条路可用，比一个会话
   更大的对话永远走不完。现在 push 循环被 `try` 包住，异常时先 `_persistPartialSend`（把本轮已
   确认的页记进条目，其余保持 prior）再 rethrow；yielded 的会话（`round.cancelled`）不写，因为
   它证明不了任何事。
2. **续传的末页会把游标之前的全部行重读一遍**（已修）。`sentIds` 只含本会话的行，末页于是把
   `ids − 本会话` 全当成「漏掉的行」重读并整页编码——续传一个 500 MB 的对话要为此分配数百 MB。
   现在从游标续传时先把 `prior.rows` 种进 `_TransferProgress.rows`，那些行本就是这次传输已送出
   的。
3. **每个页的 apply 都重排整个对话的顺序**（未修，记入已知代价）。`UNIQUE(conversation_id,
   message_order)` 让「中间页跳过重排、直接写携带的顺序」不安全，所以当前成本是页数 × 消息数条
   UPDATE。实测（内存 SQLite，只计消息行）：2,000 条／10 页 185 ms → 254 ms（×1.37，
   +69 ms）；10,000 条／25 页 1,521 ms → 4,704 ms（×3.09，+3.2 s）。每多一页约 25 µs × 已
   有行数，即额外开销 ≈ 25 µs × 行数 × (页数−1)/2。收敛正确，只是慢。要注意这个代价只在
   对话本身就大于一页（> 12.8 MB）时发生，小对话页数为一、开销为零。下一步是把第四阶段的
   逐行 UPDATE 换成一条 SQL 窗口函数，那样这一项会回到 ×1 附近。
4. **被动方没有实时进度**（未做，从「进度」一节移到这里）。引擎只给发起方发布相位，被拨号的一
   侧在卡片上仍显示「立即同步」。
5. **后续页把已装好的技能记成延后**（已修）。`_planSkillAdoptions` 在后续页拿到空 hash，会把每个
   技能判成取不到正文；现在只在首页算。

另：`SyncRequestRefusal.pushAlreadyTaken` 随「一次会话一次 push」的规则一起删除——它已无抛出点。

## 尚未落地

- **fetch 方向仍未分页。** `readSubtree` 现在会填 `ids`（否则接收端的删除推断会拿到
  空集合），但响应体本身仍可能很大。对齐 `_serveFetchSubtrees` 是下一步；`SyncFetchRequest`
  因此还没有游标字段。
- **工作区「到上限为止仍共享」未做。** 200 MiB 字节上限已删，但文件数超限的工作区仍然
  整体不共享——要改成部分共享，需要在广告表上带一个 `truncated` 标记，并让接收端对
  被截断的表不做删除推断。缺的是线格式字段，不是规则。
- 取代：无
- 相关：ADR-0003（LAN sync 架构），#1101（一次 push 的字节预算）

## 背景：硬上限是「没有分块」的直接后果

对话数据**没有分块**。一次 push 是一个 `SyncDeltaBatch` JSON 文档，在内存里
`jsonEncode → utf8 → gzip` 后一次 `PUT /sync/subtrees`。放不下时唯一的手段是
**整个对话省略**，于是三层数字串成一条链（`sync_limits.dart`）：

| 常量 | 值 | 含义 | 超限后果 |
|---|---|---|---|
| `kSyncMaxBodyBytes` | 256 MiB | 服务端接受的请求体（解压后） | **413，整轮失败**，下一轮重建同一个体 |
| `kSyncDeltaByteBudget` | 60% = 153.6 MiB | 一次 push 的准入预算 | 对话被整体省略 |
| `kSyncMaxConversationBytes` | ÷2 = 76.8 MiB | 单个对话 | 该对话在 push 方向**永远**上不去 |

而同一时刻，fetch 方向（对端拉取）**没有任何字节上限**：`_serveFetchSubtrees`
对每个请求的 id 直接 `readSubtree`，客户端 `_readJson` 无上限。同一条规则，一侧
是墙，一侧没有——超过 76.8 MiB 的对话只能靠对端恰好自己拨号来拉才到。

### 具体的不优雅之处

1. **传输单元 = 对话**，于是「大」只能是拒绝，不能是慢。
2. **规则只在一侧执行**：`admitConversations` 有单对话谓词，`_serveFetchSubtrees`
   对同一对话不做判断。ADR-0003 把这条写作已知限制。
3. **省略没有记号**：临时省略（本轮预算不够）与永久省略（>76.8 MiB）在报告里是
   同一句「没能放进本轮推送」，每轮重复，用户分不出「等下一轮」与「永远不会推」。
4. **内存随数据总量线性增长**：预算限的是「一次发多少」，不是「一次持有多少」——
   准入前就读了**全部**计划中的子树，发送端同时持有 row map、JSON、UTF-8、gzip
   四份，60% 的余量正是为这个留的。
5. **接收端同样**：`syncApplySubtree` 用 `syncReadMessageRows`（`SELECT *`）读该
   对话的全部消息行，接收一个 200 MiB 的对话要占它自身大小的多份内存。
6. **进度只有相位没有量**：最重的本地工作（读全部子树、两次编码）藏在「正在对比
   数据…」后面；`sending` 无计数；`files` 按 blob 个数而非字节；被动方无进度。

## 决定

**上限限的是「一次在飞多少」，不是「总共能走多少」。**

### 1. 页取代对话成为传输单元

- 删除 `kSyncMaxConversationBytes`。对话没有大小上限，它按页走。
- 页 = 对话行 + 若干 family 的若干行，按 `id` 顺序贪心装到页预算
  （`kSyncPageBytes`，建议 12.8 MiB = `kSyncMaxBodyBytes` 的 5%，需在手机上量内存
  峰值后定案）。派生而非重述：页预算 < 请求体上限的断言留在
  `sync_limits_test.dart`。
- 单行超过页预算 → 独占一页。唯一剩余的硬上限是 256 MiB 对**单行**，文本消息碰不到。

### 2. 页分区（依赖顺序决定谁在哪一页）

| 页 | 内容 |
|---|---|
| 首页 | 对话行 + 所有**不挂消息 revision** 的 family（`messageRevisionColumn == null`） |
| 中间页 | 对话行 + 一段消息（`id > after ORDER BY id`）+ 这些消息的 parts |
| 末页 | 对话行 + 剩余消息 + 其 parts + **挂 revision 的 family**（`providerArtifacts`）+ 全量 id 集 + 游标漏掉的行 |

挂 revision 的 family 不能提前：`_applyConversationDocuments` 用
`survivingRevisions` 做外键门，消息没到就先到文档 = 静默丢弃。

### 3. 游标与「不变量」

checkpoint 里每个对话的条目 = **「对端已被证明拥有什么」**，三种状态：

| 状态 | 含义 | 计划看到它 |
|---|---|---|
| absent | 从未证明过 | `iSend` 从头 |
| `cursor != null` | 部分：`rows` 是已证明的行，`digest` 仍是上次约定 | 按下述方向强制 |
| complete | 对端有我发过的全部 | 正常 LWW |

`SyncTransferCursor{bool sending, String? after}`：
- `sending = true`：本端欠行（半发）→ 强制 `iSend`，从 `after` 续。
- `sending = false`：本端欠收（半收）→ 强制 `peerSends`，从 it 自己最后应用的 id 续。

**方向位是关键**：没有它，两边都会算出 `bothSend`，接收方会把半棵副本推回去，而
发送方的删除推断会把「副本里没有的行」读成「对端删了」。

### 4. 删除推断的 gating（本设计最容易出错的地方）

`mergeMessageRows` 的 deletes 半边（`sync_merge.dart:839-848`）用三个条件判删除：
本地有、checkpoint 见过、**本次 incoming 里没有**。分页下：

- 非末页：`allowDeletes = false`，只做 upsert（upsert 半边本来按行幂等 LWW）。
- 末页：`incomingIds = payload.ids`（发送方持有的**全量** id 集），而不是本页的行集。
 否则前面各页送来的行「本地有、checkpoint 见过、末页没有」，会被整批误删。

### 5. 键集游标的洞与它的补法

按 `id` 分页时，传输期间新写入的行其 UUID 可能排在游标**之前**，被所有页跳过。
补法：末页把「本端持有 − 已确认送出」的行补进这一页，并把全量 id 集写进 `ids`。
因此 `ids` 同时是「发送方持有的一切」和「本次传输送出的一切」。

### 6. checkpoint 推进

- 发送端：只在**末页被 ack 且未 deferred** 时把条目合成完毕（`digest` 由各页累积的
  `id→clock` 与首页的非消息 family 合成，`updatedAtUs` 取首页的对话行时钟）。
  **不得**在推进时重读本地——会话中写入的行会被记成对端已有，下一轮按删除处理
  （这正是 `test:5137 a deferred push never deletes the sender's own new message`
  与 `:5706/:5766` 三条测试守的东西）。
- 接收端：`rows` 存 `prior ∪ 已收`（跨会话续传时删除推断需要 prior），完成后收敛为
  「本次收到的全部」。

### 7. 会话形态：一个会话，多页连发

会话活着就连续发页，被切断（deadline / 退后台 / 断网）才靠游标在下个会话续。
游标同时统一了 resume、退后台、断网、deadline 四件事——它们本是同一条路径。

### 8. fetch 方向对称

`_serveFetchSubtrees` 应当用同一个 `readPage` 按页装，响应带 `more`，initiator 循环再要。
**这一步没有落地**（见「尚未落地」）：当前 fetch 仍整棵发，只是 `readSubtree` 会填 `ids`，
否则接收端的删除推断会拿到空集合。

**过渡期的硬要求**：若 fetch 暂不分页，`readSubtree` 也必须填充 `ids`，否则
`allowDeletes` 配一个空集合 = 删光整个对话。

### 9. 协议

`kSyncProtocolVersion` → 11。现行策略是**严格相等**（`sync_engine.dart:1676`），
不做能力协商、不做退回，与仓库「不留兼容层」的政策一致。

### 10. 接收端内存：窄投影

`syncApplySubtree` 把 `syncReadMessageRows`（`SELECT *`）换成
`syncReadMessageMeta`（`id, updated_at, timestamp, message_order, group_id, version`）。
合并只读这些列，从不读内容——写完这一步，接收一个 200 MiB 的对话不再占它自身大小
的内存。这是廉价且独立的一步，可以先做。

## 进度（同一次改动的一部分）

- 新增 `preparing` 相位，前移到计算计划之后、读页之前。
- `sending`/`receiving` 带 `done/total`（对话数）与**已发字节**（每页发出前
  `jsonEncode` 一次得到的精确长度，逐页累加）。总量事先不可知——不显示百分比。
- `files` 按字节：`SyncBlobEntry.byteSize` 已有，客户端边收边 sha256。
- `conversationsOmittedForSize` 整个消失；`deferred` 只剩「生成中 / 对端延后应用」。
- 被动方发布同一套相位。UI 用一条 3dp 细进度条 + 一行文字（见
  `docs/mockups/sync-progress-a.html`）。只有一种「发送中」，没有「大对话」特例。

## 工作区上限：同一个原则

- `kMaxWorkspaceFiles` 2000 **留**（索引与 ledger 成本有界）。
- `kMaxWorkspaceBytes` 200 MiB **删**：文件是一个个拉的（暂留 + 原子 rename，有字节
  进度），总量大只是慢，不是内存风险。
- 到上限为止索引到的部分照常共享，表带 `truncated`；接收端对 `truncated` 的工作区
  **不做删除推断**（表里没有 ≠ 对端删了）。面板从「过大」改为「部分同步」。

## 受影响的位置（实施清单）

| 位置 | 改什么 |
|---|---|
| `sync_models.dart` | `SyncSubtreePayload` 加 `more`/`ids`；`SyncCheckpointConversation` 加 `cursor`；新 `SyncTransferCursor`；协议 11 |
| `sync_limits.dart` | 删 `kSyncMaxConversationBytes`；`kSyncDeltaByteBudget` → `kSyncPageBytes` |
| `sync_budget.dart` | 删 `admitConversations`，改页预算助手；`assertPushFits` 对页 |
| `sync_data_plane.dart` | 新 `readSubtreePage`；`readSubtree` 填 `ids` |
| `sync_merge.dart` | `mergeMessageRows` 加 `incomingIds` / `allowDeletes` |
| `chat_database_repository.dart` | 新 `syncReadMessageChunk` / `syncReadMessageIds` / `syncReadMessagesByIds` / `syncReadPartRowsBetween` / `syncReadMessageMeta`；`syncApplySubtree` 透传 `complete` |
| `sync_engine.dart` | push 段改逐页循环；`_advanceCheckpoint` 两臂看 `cursor`/`complete`；`handleApplySubtrees` 允许多次 push；`_serveFetchSubtrees` 按页（**未落地**） |
| `sync_messages.dart` / `sync_peer_card.dart` | 进度条与计数 |
| `app_*.arb` | 新字符串；`lanSyncReportConversationsOmittedForSize` 删；`lanSyncWorkspaceTip` 的「2,000 文件或 200 MB」改成「2,000 文件」 |

## 测试要守的（按 `blast-radius` 的要求逐条列出调用者）

- 非末页**不**删除：构造两页，第二页不含第一页的行，断言行还在。
- 末页用 `ids` 判删除：本地有一行、checkpoint 见过、`ids` 里没有 → 删。
- 传输中写入的行（id 排在游标之前）在末页被补发，接收端不缺。
- 跨会话续传：第一会话 deadline 切断，第二会话从 `cursor.after` 续，最终一致。
- deferred 页保留游标：对端生成中 → 条目停在上一页，不推进 digest。
- 大对话（> 旧 76.8 MiB 上限）现在能整棵到达。
- 单行超页预算仍能发（独占一页）。
- `sync_limits_test` 断言 页预算 < 请求体上限。
- 进度：相位与计数 widget 测试。

## 尚未量的事

- 页大小 8 / 12.8 / 16 MiB 的内存峰值，要在手机上量（`test/perf/sync_push_bench.dart`：
  读 / 编码 / 传输 / 应用分段计时）。
- 大对话跨多轮时，中途退出的有序性：中间页按携带的 `message_order` 写入（不是追加），
  末页统一重排；若传输永久中断，顺序仍有效，无需修复。

## 备选方案与否决理由

- **整棵发送 + 流式 JSON 写入 socket**：发送端内存问题缓解，接收端仍要缓冲整个 body，
  且请求体上限仍是墙。否决。
- **跨轮游标（一次会话只推一页）**：改动更小，但吞吐被 auto-sync 的 60 s 间隔门住
  （1 GiB ≈ 7 轮 ≈ 7 分钟，大部分在等），且大对话的进度断续。慢路径作为会话内连发被
  切断时的退化形态保留。
- **兼容旧端（页标记走能力协商）**：与仓库「不留兼容层」政策冲突，且旧端对半棵子树
  会做删除推断——正是本设计要防的灾难。否决，走协议升版。
