# 方案 B｜固定余量：留 15%

> 与 A 只有一处不同：**会话可用额 = 上限 × 85%**，业务面与 workspace 表不先量。
> 准入只在今天的位置多一条判断，引擎的读顺序不动。目标书：`../plan.md`（基 `04c1e594e`）。

## 用户会看到什么

| 今天 | 本方案之后 |
| --- | --- |
| 文档把 delta 撑过 256 MB → 413 → 这对设备**永久**不同步 | 常见库上消失：一轮发不下的会话被推迟，下轮再试 |
| 业务面很大（技能正文、回忆、世界书）或 workspace 表很大 | **仍然 413**：38 MB 余量只是「大概够」，而 413 那一轮已经白跑 |
| 一轮里只有被跳过的会话 | 卡片仍然出现，而不是看起来像「什么都没发生」 |

## 数据流（伪代码）

```dart
// 限值：三个数同住 sync_limits.dart，后两个是推导
const int kSyncMaxBodyBytes = 256 * 1024 * 1024;      // 从 sync_server.dart:906 搬来
const int kSyncDeltaByteBudget = kSyncMaxBodyBytes * 85 ~/ 100;
const int kSyncMaxConversationBytes = kSyncDeltaByteBudget ~/ 2;

// 准入：就在今天 1052–1067 的循环里，读完一条判一条
var used = 0;
for (final item in plan) {
  // …isStreaming / readSubtree / 检查点不动，与今天相同…
  final bytes = utf8Length(jsonEncode(subtree.toJson())) + 1;
  if (bytes > kSyncMaxConversationBytes ||
      used + bytes > kSyncDeltaByteBudget) {
    sizeOmitted.add(item.conversationId);   // 不推进检查点 → 下一轮重试
    continue;
  }
  used += bytes;
  outgoing.add(subtree);
}
```

## 不变量

- **I1 同 A**：`kSyncMaxBodyBytes` / `kSyncDeltaByteBudget` / `kSyncMaxConversationBytes` 同一文件、
  后两个由前者推导，断言 `2 * kSyncMaxConversationBytes <= kSyncDeltaByteBudget < kSyncMaxBodyBytes`。
- **I2′ 只在假设上成立**：`used + fixed <= budget` 要求「固定部分 ≤ 38 MB」，
  而这个假设**没有任何地方能检查**——能检查的前提就是先量（那就是 A）。
- **I3–I6 同 A**：检查点停在 `prior`、`bothSend` 只砍一半、报告两处、准入纯函数可小数测试。

## 失败模式

| 情形 | 结果 |
| --- | --- |
| 业务面 + workspace 表 > 38 MB | 会话照发，body 超限 → 413，与今天相同：本 PR 要杀的症状在这类库上残留 |
| 一条会话 > 单会话上限 | 跳过它，其余照发；计数 1 |
| 被跳的会话下一轮仍超限 | 仍然只跳它，整轮不失败 |
| 用户裁掉压缩历史 | 下一轮正常发送，计数归 0 |
| 对端 manifest 有、本机跳过 | 不触发删除（检查点未推进） |

## 代价

- **余量是一句「够用」，不是一条能证明的关系**：15% 与业务面 / workspace 表的大小之间没有任何联系。
  能做的只有事后观察：413 出现了再调大百分比，而那一轮已经白发。
- 换来的是：无顺序改动、无第二次清单、无第二次编码（准入那一次不计：两案都要）。
- 上限搬家、报告落两处、7 个 ARB、文档收尾——与 A 相同（见 A 的「代价」一节）。

## 适合

先止血：把绝大多数库从「永久不同步」里拉出来，接受「业务面极大」这个角落仍然 413，
下一轮再把它变成算得出来的。

## 不做

不预先量固定部分；不改引擎读顺序；不裁业务面；不分片（计划书 §2 的非目标）。
