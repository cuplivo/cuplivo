# 计划书 — 一次推送的字节预算

| | |
|---|---|
| worktree | `D:\Projects\.worktrees\089wkfcf\cuplivo-feat-sync-document-budget` |
| branch | `feat/sync-document-budget` |
| base | `04c1e594e`（#1088 之后） |
| 覆盖 | v9 把会话文档放进子树之后新开的口子：**文档没有体积闸**；无协议变更 |
| 状态 | **已落地**：轮 1 取 A（先量后分）；审计发现的 `bothSend` 检查点漏洞先修；准入、报告、文案、文档、测试全部到位 |

## 0. 一句话

**delta 是一个 JSON body，服务端上限 256 MB（`sync_server.dart:906`，解压后计数）。** 超了是 413，而下一轮会重建同一份 delta——同一份超限 body——于是这对设备**永久**不同步，报告只写"失败"。要在构造批次时就决定"这一轮装得下什么"。

## 1. 目标（验收锚点，不可协商）

- **G0 不会因为体积打出 413**：任何一轮推送的 body 都小于服务端上限并留出余量；余量覆盖业务面与资产 manifest。
- **G1 放不下就不发，不是失败**：超预算的会话**不进入** `outgoing`，其检查点保持 `prior`（沿用 `skippedSends` 的既有语义），下一轮重试；本轮其它会话照常送达。
- **G2 沉默消失**：报告里有 `conversationsOmittedForSize`（按**会话**计数，与 `conversationsWithDocumentsReplaced` 同单位），面板能看见。
- **G3 预算是一个派生的数**：`kSyncDeltaByteBudget` 与 `kSyncMaxConversationBytes` 都写在 `sync_limits.dart`，后者由前者推导（不是各写一个整数），并有测试断言两者与 `_syncMaxBodyBytes` 的关系——这是仓库对"两个必须一致的限值"的既有纪律。
- **G4 按真实字节判断**：估算量来自**与发送同构的序列化**（同一份 `toJson()`），不是按消息数或字段数猜；覆盖全部 travelling families（消息、parts、文档、artifacts、MCP 绑定）。
- **G5 每条目标注入即红**，恢复后按字节一致（hash 对比）。

## 2. 非目标

- 不做压缩（文档 payload 原样）；不改文档的合并语义（Q2 是另一条）。
- 不做分片传输（一条会话拆成多轮）——那是协议级改动，本 PR 明确不做，并把它记为已知限制。
- 不改服务端上限；只让客户端**尊重**它。
- 不动 blob / workspace 两条独立通路（它们各有自己的上限与推迟机制）。

## 3. 已定决策

| # | 决策 | 理由 |
|---|---|---|
| D-1 | 预算在**构造批次时**执行，不在收到 413 之后补救 | 413 是整轮失败，补救只能是"重来一轮"，而重来还是同一份 body |
| D-2 | 两级限值：整轮预算 + 单会话上限（由整轮推导，如 `整轮 / 2`） | 只有整轮预算时，一个 200 MB 的会话会挤掉其余全部；只有单会话上限时会累加超限 |
| D-3 | 跳过 = 不发送 + 不推进检查点 + 计数 | 与 `workspacesOmitted`、`skippedSends` 同一语义家族，不发明第三种"没发出去" |
| D-4 | 排序用计划顺序（稳定），不做按大小的贪婪重排 | 稳定顺序让"这次没发下轮会发"可预测；贪婪重排会让报告数字每轮变化 |
| D-5 | 上限先按 §11 的实测定，不先拍整数 | 计划书只要求"派生的关系"与"可测"，具体值由实测决定 |

## 4. 交付物（到面，不逐行）

| 面 | 一句话改动 |
|---|---|
| 限值 | `sync_limits.dart` 增两个常量，一个由另一个推导；注释写明与 `_syncMaxBodyBytes` 的关系 |
| 估算 | 一个纯函数：给定 `SyncSubtreePayload` 返回字节数（`jsonEncode` 一次，含文档家族）；放在 registry/模型旁，可单测 |
| 准入 | 引擎收集 `outgoing` 的循环里：按顺序累加，超单会话上限或超整轮预算即跳过并记入 `sizeOmitted` |
| 报告 | `SyncSessionReport` 增字段（本地，不上线），面板与既有计数同处 |
| 文档 | `CONTEXT.md` sync 节一条：一次推送有预算，超出的会话下一轮再试；ADR-0003 追加已知限制（不分片） |

## 5. 状态表（一格一测）

| 情形 | 期望 |
|---|---|
| 全部会话合计在预算内 | 全部发送，计数为 0 |
| 3 个会话各 30 MB、预算 64 MB | 发 2 个、跳 1 个；计数 1；被跳的检查点不动 |
| 单个会话 100 MB > 单会话上限 | 跳过它、其余照发；计数 1 |
| 被跳的会话下一轮仍超限 | 仍然只跳过它；**不会**让整轮失败（这是本 PR 的核心断言） |
| 被跳的会话被用户裁掉了压缩历史 | 下一轮正常发送，计数归 0 |
| 对端 manifest 里有而本机跳过的会话 | 不触发删除（检查点未推进 → 不是"双方删除"） |
| 预算边界（恰好等于上限） | 发；大于一个字节即跳过 |
| 业务面的行与资产 manifest 也在同一 body | 余量覆盖它们；断言 body 总量 < 服务端上限 |

## 6. commit 结构

1. `feat(sync): one budget for a delta, derived from the body cap`（G3/G4，纯函数 + 限值 + 测试）
2. `feat(sync): a conversation that does not fit is deferred, not failed`（G0/G1）
3. `feat(sync): the report names what the budget left behind`（G2）
4. `docs(context): a push has a budget`
5. `test(sync): the budget's state table, one cell per case`

## 7. 验证

- `dart analyze --fatal-infos lib test integration_test`；`dart format`（CI 钉住的 Dart 版本）
- `flutter test test/core/services/sync` + 完整 `sync_engine_integration_test.dart`
- 实测（计划书 §11 的三个数字里的两个）：压缩 3 次后 `conversationContext` payload 的 p95；空库对满库首轮 delta 的峰值。**用来定 D-5 的具体值，并把结果写进 PR 描述**
- 注入证明：把准入判断改成"永不超限"，用 3×30 MB 的夹具跑集成测试 → 出现超限 body / 断言红；按 hash 还原

## 8. 风险与回滚

- **R1** 估算与真实序列化不一致（少算一个字段 → 仍然 413）。缓解：估算就是同一份 `toJson()` 的 `jsonEncode`，不维护第二套公式；再留 15% 余量。
- **R2** 一个永久超限的会话永远不同步。这是**有意的**取舍：它比"整轮失败、什么并不同步"好，且报告点名，用户可以裁掉压缩历史。文档要写清这条。
- **R3** 预算偏小会让收敛变慢（多轮）。计数可见，可调；且预算只在超大库上生效。
- **回滚**：限值调大即等于关闭（不会引入数据变化）；三个 commit 独立可 revert。

## 9. 落地记录（本轮）

**轮 1 决策：A｜先量后分**（见 `docs/design/sync-document-budget/rounds/`）。

### 9.1 计划书没列、本轮补上的三项

1. **报告字段要落两处**：面板读的是持久化的 `SyncPeerReport`（`sync_report_breakdown.dart:25` ←
   `sync_store.dart:906`），只加 `SyncSessionReport` 面板看不见。字段还进了 `toPeerReport`、本地 JSON
   （`fromJson` 默认 0）与 `sync_messages.dart` 的摘要行。线上协议不变。
2. **一句新文案 × 7 个 ARB** + `flutter gen-l10n`（面板不能凭空多一行文字）。
3. **`_syncMaxBodyBytes` 搬进 `sync_limits.dart`**（`kSyncMaxBodyBytes`）：不搬，G3 的"派生关系"没有对象可断言。

### 9.2 审计（用户要求：延迟发送不许把自己坑了）

只读审计现有 deferral 路径，结论：**`_advanceCheckpoint` 的 `bothSend` 分支不检查发送是否真的发出**。
`iSend` 有 `skippedSends` 守卫，`bothSend` 只判 `outcome.deferred`/`peerDeferred`；被跳过的 bothSend 会话在
应用对端副本后把检查点写成"双方已一致"，下一轮计划读成 `peerSends`，拉到一份没有本机那行的副本，合并把
本机那行删掉（本地独有 + 时钟与记录相等 → 删除分支）。今天的流式跳过侥幸不触发（`isStreaming` 同时让 apply
延期）；体积跳过不延期，于是**每轮都触发**——是数据丢失。

修法：两条发送臂共用同一个问题——**这批 payload 过线了吗**——`sentSubtrees.containsKey(id) && sendsConfirmed`；
`skippedSends`/`missingIncoming` 两个参数随之删掉（后者本是死参数）。响应侧的同一条臂（fetch beat，
`sendsConfirmed: false`）因此一并修好。

未修、记为已知限制（ADR-0003）：**fetch 响应没有上限**，超大会话只能靠对端拉取到达；不分片。

### 9.3 与计划的差异

- 排序、跳过语义、报告单位、非目标：与 §3/§2 一致，未改。
- 常量：`kSyncDeltaByteBudget = kSyncMaxBodyBytes × 60%`（余下的 40% 是发送路径自身的多份拷贝），
  `kSyncMaxConversationBytes = 预算 ~/ 2`。§7 的两个实测值仍应复核这个比例，`kSyncDeltaBudgetPercent` 是唯一的旋钮。
- 预算与单会话上限是 `SyncEngine` 的构造参数（默认取常量），只为让 §5 的状态表用几百字节的夹具跑；
  生产不传。
