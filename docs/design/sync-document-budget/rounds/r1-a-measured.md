# 方案 A｜先量后分：余量是算出来的

> 与 B 只有一处不同：**会话可用额 = 上限 − 已经量出来的固定部分**，不是一个拍出来的百分比。
> 限值、报告、状态表两案共用。目标书：`../plan.md`（基 `04c1e594e`）。

## 用户会看到什么

| 今天 | 本方案之后 |
| --- | --- |
| 文档把 delta 撑过 256 MB → 413 → 这对设备**永久**不同步，卡片只写「失败」 | 放不下的那几条会话本轮不发、下轮再试；其余照常送达；卡片多一行 |
| 业务面（助手、世界书、技能正文、回忆）很大时，任何固定余量都可能不够，413 照样出现 | 业务面先量再分，剩下的才给会话；余量不靠猜 |
| 一轮里只有被跳过的会话 | 卡片仍然出现，而不是看起来像「什么都没发生」 |

## 数据流（伪代码；行号取自 `04c1e594e`）

```dart
// 1 · 先读、先量：这些都不依赖「发哪几个会话」
final planned = <SyncSubtreePayload>[];            // 今天 1052–1067：只读，不下判断
final business = (await dataPlane.readBusinessRows(...)).payload; // 今天 1093
final snapshots = await dataPlane.workspaceSnapshots();           // 今天 1127（提前）
final tables = dataPlane.workspaceTables(snapshots);              // 今天 1128
final assetsUpper = await dataPlane.buildBlobManifest(            // 按计划全集：疏集 ⊆ 全集
  subtrees: planned,
  business: business,
);

// 2 · 固定部分 = 不含会话的整个 body，一次编码量出来
final fixed = utf8Length(jsonEncode(SyncDeltaBatch(
  const [],
  business: business,
  assets: assetsUpper,
  skillHashes: pushedSkillHashes,
  workspaceFiles: tables,
).toJson()));

// 3 · 准入：计划顺序累加（D-4），放不下的跳过、检查点不动
var remaining = kSyncDeltaByteBudget - fixed;
final sizeOmitted = <String>{};
final outgoing = <SyncSubtreePayload>[];
for (final subtree in planned) {
  final bytes = utf8Length(jsonEncode(subtree.toJson())) + 1; // +1 是分隔逗号
  final id = subtree.conversation['id'] as String;
  if (bytes > kSyncMaxConversationBytes || bytes > remaining) {
    sizeOmitted.add(id);        // 不推进检查点 → 下一轮重试
    continue;
  }
  remaining -= bytes;
  outgoing.add(subtree);
}

// 4 · 最终清单只描述真正要发的行（重建一次；文件哈希已缓存）
final assets = await dataPlane.buildBlobManifest(
  subtrees: outgoing,
  business: business,
);
```

`utf8Length` 是 `utf8.encode(s).length` 的计数版（chunked sink）：量长度不再分配第二份 bytes。

## 不变量

- **I1 两个限值是一对派生数。** `kSyncMaxBodyBytes` 从 `sync_server.dart:906` 的私有常量搬进
  `sync_limits.dart`，`kSyncDeltaByteBudget = kSyncMaxBodyBytes - kSyncDeltaStructuralMarginBytes`，
  `kSyncMaxConversationBytes = kSyncDeltaByteBudget ~/ 2`。
  断言：`2 * kSyncMaxConversationBytes <= kSyncDeltaByteBudget < kSyncMaxBodyBytes`。
- **I2 G0 是可算的，不是留出来的。** `body = fixed + Σ bytes − 1`
  （`"subtrees":[]` 变成 `"subtrees":[a,b]` 只差一个字符），所以
  `Σ bytes <= budget − fixed` ⇒ `body <= budget − 1 < 上限`。1 MB 的
  `kSyncDeltaStructuralMarginBytes` 不是为业务面留的（已量），只为「量法与线格式之间还有未知」。
- **I3 被跳过的会话，检查点停在 `prior`。** `_advanceCheckpoint` 的 `iSend` 分支已经这么写：
  `sentSubtrees[id] == null` 就保留 prior（`sync_engine.dart:2427–2443`）。
- **I4 `bothSend` 只砍发送那一半。** 对端副本照常应用，与 `skippedSends`（生成中）今天的语义一致。
- **I5 发出去的清单是量过的那份的子集。** 准入集 ⊆ 计划集 ⇒ 资产条目只少不多。
- **I6 准入是纯函数、预算当参数。** 状态表的「30 MB」格子用 30 字节的夹具跑，CI 里没有 90 MB 数据。

## 失败模式

| 情形 | 结果 |
| --- | --- |
| 固定部分自己就超预算（业务面 + workspace 表 > 上限） | 会话全跳，body 仍可能超限 → 413。**本方案唯一的洞**：要修得连业务面一起裁，超出本 PR |
| 一条会话 > 单会话上限 | 跳过它，其余照发；计数 1 |
| 被跳的会话下一轮仍超限 | 仍然只跳它，整轮不失败（本 PR 的核心断言） |
| 用户裁掉压缩历史 | 下一轮正常发送，计数归 0 |
| 对端 manifest 有、本机跳过 | 不触发删除（检查点未推进 → 不是「双方删除」） |

## 代价

- **引擎读顺序真的变了**：业务面、workspace 快照与表、资产清单从「发送前」提到「准入前」
  （`publishWorkspaceContent` 可留在原处，`_rememberPublished` 用最终清单）。不是纯新增。
- **资产清单算两次**：全集量一次、准入集发一次；第二次是字符串扫描（文件哈希已缓存），
  但为被跳的会话也白哈希了一遍文件。
- **编码两次**：准入一次、`_writeJson` 发送一次（不同时驻留）。不能再量一次整个 body——那是第三次。
- **上限搬家**：`_syncMaxBodyBytes` → `sync_limits.dart` 的 `kSyncMaxBodyBytes`，服务端引用它。
- **报告要落两处，不是一处**：面板读的是持久化的 `SyncPeerReport`
  （`sync_report_breakdown.dart:25` ← `sync_store.dart:906`），所以字段要加在
  `SyncSessionReport` **与** `SyncPeerReport`，并映射 `toPeerReport` + 本地 JSON（`fromJson` 默认 0）。
  `syncReportHasRow`（`sync_messages.dart:180`）也要算上它。线上协议不变。
- **文案**：一句 × 7 个 ARB + `flutter gen-l10n`——计划书交付物表里没有这一项。

## 适合

计划书 G0 是「不可协商」时的正确读法：唯一能把「不会 413」变成**算得出来**的形状。

## 不做

不复用准入时的编码（要改 `SyncClient` 签名）；不裁业务面；不动 blob / workspace 两条通路；
不分片（计划书 §2 的非目标）。
