# 核心骨架 · 变体 B —— 写车道按 peer 分开（计划书 D-1）

**未采纳**（2026-11-19，见计划书 D-1a）。保留的原因：它记录了"为什么环不是写车道造成的"，
以及如果多设备并发写真的成为瓶颈，代价清单在这里。

> 与 A 逐字相同，只有一行不同：写车道的 key 是"这一对设备"，不是"这台设备"。

同一份骨架，另一条车道。对应 `ADMISSION-PLAN.md` D-1；A 见同目录
[`a-three-lanes.md`](a-three-lanes.md)。**只有 §1 的表和第 5 节的不变量不同**，其余是为可读性重抄。

## 1. 车道表（按效果分，不按路径）

| 请求 | 它做什么 | 车道 |
|---|---|---|
| `GET /sync/blob/<hash>` | 查发布表 / 资产表，`stat` 文件 | **read**（并发） |
| `POST /sync/wsfile` | 查已发布的表，`stat` | **read**（并发） |
| `POST /sync/ping` | 什么都不做 | **ping**（已有，8 上限） |
| `POST /pair` | 写 peer 记录 + 内存 secret | **pair**（新，上限 4） |
| `POST /sync/hello` | 装会话，读检查点 | **write[peer]** |
| `PUT /sync/subtrees` | 逐对话事务、落文件、推进会话 | **write[peer]** |
| `POST /sync/subtrees` | 删除、写检查点、摘会话、写 peer 报告 | **write[peer]** |
| `POST /sync/revoke` | 删 peer 记录 | **write[peer]** |
| `PUT /sync/blob/<h>`、`PUT /sync/wsfile` | 落文件 | **write[peer]** |
| 其它（404 / 405 / 未鉴权） | 无 | **read** |

`write[peer]` = 每个已配对设备一条队。A 里那条设备级的队，在这里被拆成"每个 peer 一条"，于是
两个**不同** peer 的 beat 可以同时跑；同一个 peer 的两个写仍然串行（这一条 B 不动，也不该动）。

## 2. 准入：一个请求一个 gate，预算从进门开始

和 A 相同：鉴权提到派发点，只判定一次；`/sync/*` 没有身份就地 401，不进车道。B 白拿了这个好处
——它本来就需要身份来做 key，而 A 需要它来挡住伪造请求的排队。两条理由指向同一段代码。

```dart
Future<void> _serve(HttpServer server) async {
  await for (final request in server) {
    final gate = _Admission(_now(), _deadlineFor(request.uri.path));   // G2
    final path = request.uri.path;

    if (path == _pairPath) { _pairLane.enqueue(request, gate); continue; }

    final peer = _authenticatedPeer(request);        // 唯一的鉴权判定
    if (peer == null && path.startsWith('/sync/')) { _safeRespond(request, 401, notPaired); continue; }

    switch (_laneOf(request)) {
      case ping:  unawaited(_servePing(request, peer, gate));
      case read:  unawaited(_serveRouted(request, peer, gate));
      case write: _laneFor(peer).enqueue(request, peer, gate);        // ← 唯一差别：按 peer 取队
    }
  }
  await Future.wait(_writeLanes.values.map((lane) => lane.drained()));
}
```

```dart
final Map<String, _WriteLane> _writeLanes = {};

_WriteLane _laneFor(String peer) {                 // 空队回收，否则每见过一个 peer 就留一个 future
  final lane = _writeLanes[peer];
  if (lane != null) return lane;
  final fresh = _WriteLane(onIdle: () => _writeLanes.remove(peer));
  _writeLanes[peer] = fresh;
  return fresh;
}
```

车道本体、`_Admission`、`gate.io`/`gate.ioStream`、`_route(request, peer, gate)` 的签名，全部与 A 相同。

## 3. 取消：一个 gate，一串提交点

提交点与 A 的表格逐条相同（`_sessions[peer] = session`、`savePeer`+`rememberPeer`、`deletePeer`+
`forgetPeer`、两处 `land()` 的 rename、每个对话事务之前、删除循环之前、
`saveCheckpointUnlessReplaced`+`_sessions.remove`+`mutatePeer`）。

两处要额外说清楚，因为 B 让"两个写同时存在"成了常态：

- **检查点文件是每 peer 一个**（`sync_store` 的 `<deviceId>.json.gz`），两个写车道不会写同一个文件。
  这是 B 能成立的前提，不是巧合。
- **`store.mutatePeer` 已经是每 peer 串行的读改写**（`_peerWrites`），`/pair` 的 `savePeer` 是
  "记录出生"的整份写。两个车道同时碰 peer 记录因此是安全的，不需要新锁。

## 4. 客户端：一次传输一个预算

与 A 逐字相同（`_transfer` + `addStream`/`close`/`drain` 共用一只秒表；断的时候 `request.abort()`）。
客户端看不见车道，这条不因 A/B 而异。

## 5. 不变量（B 的代价都在这里）

- **I-1′ 同一 peer 的写不并发。** 比 A 的 I-1 弱一档：跨 peer 的写现在会重叠。这是 B 买的全部东西，
  也是 B 要付的全部风险。
- **I-2 读只读已发布的快照。** 与 A 相同，且**更重要**：读可能落在两个写之间，而这两个写各自的
  中间状态都必须是不可见的。`publish` 的整表赋值（`_served[peer] = served`）仍然是那个机制。
- **I-3 预算单调。** 与 A 相同。
- **I-4′ 事务内无网络 await —— 从"好习惯"变成"承重"。** B 里一个 peer 的 apply 与另一个 peer 的读
  会同时要数据库。drift 会把事务排队，所以不会写坏；但一个"事务里等网络"的 apply 会把它后面所有
  读都挡住——环形互等就以数据库为介质回来了。今天 `_fetchOne` 是"先网络、后落盘、后 DB"，成立；
  这条必须写成断言，而不是注释。

B 新增的并发面，逐条说清：

| 面 | 两个 peer 同时写会怎样 |
|---|---|
| 会话表 `_sessions` | 按 peer 分键，无交集 |
| 检查点文件 | 按 peer 分文件，无交集 |
| peer 记录 | `mutatePeer` 已串行；`savePeer` 只写自己的文件 |
| 对话/业务行 | LWW 时钟比较与写入顺序无关，乱序也收敛；今天两个会话串行跑也是这个结果 |
| `_publishedBlobs` | 全局 map，两个车道各写各的键；同步段内赋值，无 await 插入 |
| 工作区文件 | 两条 `land()` 可能同时写同一个 path：临时文件 + rename 是原子的，最后一个赢，另一边 ledger 下一轮自愈 |
| 数据库事务 | drift 串行，不坏；只影响延迟（见 I-4′） |

## 6. 失效模式（只列与 A 不同的）

| # | 失效 | 表现 | 防线 |
|---|---|---|---|
| F-1 | 同一 peer 的两条队被建出来 | 检查点两份互相覆盖（R1 原样） | 一个 peer 只有一个 key；状态表 #18 |
| F-2 | 空队不回收 | 每见过一个 peer 留一个 future | `onIdle` 回收；状态表 #19 |
| F-3 | 跨 peer 重叠写共享缓存 | 面板读到半更新的列表 | I-2 + 现有 `reloadAfterExternalChange` 的整份重读 |
| F-4 | 事务里等网络 | 读被 DB 挡住，环形以数据库形式回来 | I-4′；状态表 #20 |
| F-5 | 两条 `land()` 同 path | 一个覆盖另一个 | rename 原子 + ledger 自愈；状态表 #21 |

A 的 F-1…F-8 在 B 里同样成立（漏 `check()`、半张表、`.timeout` 不是取消、双 close、`finally` 没跑、
`/pair` 装了 peer、读车道无上限、写洪水），不重复列表。

## 7. 状态表 —— 一格一测

A 的 17 格全部保留，#4 的期望从"排队"改为"两个不同 peer 可以同时写，同一 peer 仍排队"。
新增四格：

| # | 情形 | 期望 |
|---|---|---|
| 18 | 同一 peer 两个写并发 | 串行；检查点只有一份（D-1 的不变量） |
| 19 | 一个 peer 的队跑空 | `_writeLanes` 里没有它了 |
| 20 | peer P 的 apply 事务进行中，peer Q 的读 | Q 的读在事务结束后应答，不超时（I-4′） |
| 21 | 两个 peer 同时落同一 path | 文件是其中一份完整的，ledger 下轮自愈，无半文件 |

注入证明在 A 的三条之外加一条：(d) 把 `_laneFor(peer)` 改成 `_laneFor('*')`（退化回 A）→ #18 仍绿、
#4 变红，证明"按 peer 分"确实是生效的那一处。

## 8. 若要选 B，ADR 必须改口的地方

slice 3 的"它们共享会话状态和检查点文件，所以一次只能跑一个"在 B 之后只对**同一对设备**成立。
`docs/adr/0003-lan-sync-architecture.md` 里那句要缩到 peer 级，并补上 §5 的两条新不变量（I-1′、I-4′）。
A 不改这句话——这也是 A 更便宜的一半原因。
