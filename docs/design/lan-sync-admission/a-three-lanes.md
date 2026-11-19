# 核心骨架 · 变体 A —— 三条车道，写仍是一整条

**已采纳**（2026-11-19，决定 D-1a）。落地后与本文的差别：`_Admission` 叫 `sync_admission.dart`
里的 `SyncAdmission`；`_WriteLane` 没有成为一个类，写车道仍是 `_serve` 里的那条 future 链；
`gate.io` 收的是回调而不是 future（一个已经启动的 future 被 gate 拒绝时会留下无人监听的错误）。
ADR 的正式文本见 `docs/adr/0003-lan-sync-architecture.md` 的 "Amendment (2026-11, admission)"。

> 读不排队；写互相排队；`/pair` 自成一队。预算从**入队**起算；超时不是"不再等这个 future"，
> 是"收回这个处理器继续写的权利"。

这一份只到骨架：数据流、不变量、失效模式。对应计划书 `ADMISSION-PLAN.md`；
变体 B 见同目录 [`b-per-peer-write-lane.md`](b-per-peer-write-lane.md)，两文只差第 1 节一行与第 5 节一条。

## 1. 车道表（按效果分，不按路径）

| 请求 | 它做什么 | 车道 |
|---|---|---|
| `GET /sync/blob/<hash>` | 查发布表 / 资产表，`stat` 文件 | **read**（并发） |
| `POST /sync/wsfile` | 查已发布的表，`stat` | **read**（并发） |
| `POST /sync/ping` | 什么都不做 | **ping**（已有，8 上限） |
| `POST /pair` | 写 peer 记录 + 内存 secret | **pair**（新，上限 4） |
| `POST /sync/hello` | 装会话，读检查点 | **write**（一条） |
| `PUT /sync/subtrees` | 逐对话事务、落文件、推进会话 | **write** |
| `POST /sync/subtrees` | 删除、写检查点、**摘会话**、写 peer 报告 | **write** |
| `POST /sync/revoke` | 删 peer 记录 | **write** |
| `PUT /sync/blob/<h>`、`PUT /sync/wsfile` | 落文件 | **write** |
| 其它（404 / 405 / 未鉴权） | 无 | **read** |

分类依据是"会不会改设备状态"。读车道能并发，正因为它的处理器只读——所以它们**被允许**并发的前置
条件是第 5 节的不变量 I-2，不是"读路由看起来无害"。

写车道在 A 里仍是**设备级一条**：今天"两个写不能同时跑"这条不变量原样保留，D-1 不采纳。

## 2. 准入：一个请求一个 gate，预算从进门开始

鉴权提到派发点，只判定一次：`/sync/*` 没有身份就地 401，**不进任何车道**——一条伪造的
`POST /sync/hello` 洪水因此排不到合法请求前面（N1 的另一半）。`_route` 里那段鉴权随之删除。

```dart
Future<void> _serve(HttpServer server) async {
  await for (final request in server) {
    final gate = _Admission(_now(), _deadlineFor(request.uri.path));   // G2：时钟在入队处
    final path = request.uri.path;

    if (path == _pairPath) { _pairLane.enqueue(request, gate); continue; }

    final peer = _authenticatedPeer(request);        // 唯一的鉴权判定
    if (peer == null && path.startsWith('/sync/')) { _safeRespond(request, 401, notPaired); continue; }

    switch (_laneOf(request)) {                       // 按 (path, method) 分类，见 §1
      case ping:  unawaited(_servePing(request, peer, gate));   // 已有上限，仍在池内计数
      case read:  unawaited(_serveRouted(request, peer, gate)); // 并发，不排队
      case write: _writeLane.enqueue(request, peer, gate);      // 队尾
    }
  }
  await _writeLane.drained();                         // 关闭时把队尾等完，和今天一致
}
```

```dart
class _Admission {
  final DateTime enteredAt; final Duration budget;
  bool _lost = false;

  Duration get remaining => budget - (_now() - enteredAt);   // 只减不增：排队是在花它
  bool get alive => !_lost && remaining > Duration.zero;

  void lose() => _lost = true;

  /// 提交点调用：事务之前、落库之前、装会话之前、摘会话之前。
  void check() { if (!alive) throw const _AdmissionLost(); }

  /// 所有可能永久悬住的 await 都必须从这里过（见 §6 F-3）。
  Future<T> io<T>(Future<T> work) {
    check();
    return work.timeout(remaining, onTimeout: () { lose(); throw const _AdmissionLost(); });
  }

  Stream<T> ioStream<T>(Stream<T> s) {
    check();
    return s.timeout(remaining, onTimeout: (sink) {
      lose(); sink.addError(const _AdmissionLost()); sink.close();
    });
  }
}
```

```dart
class _WriteLane {
  Future<void> _tail = Future<void>.value();

  void enqueue(HttpRequest request, String? peer, _Admission gate) {
    _tail = _tail.then((_) => _run(request, peer, gate));
  }

  Future<void> _run(HttpRequest request, String? peer, _Admission gate) async {
    if (!gate.alive) { _safeRespond(request, 504, timeout); return; }   // 排队就把预算花完
    try {
      await _route(request, peer, gate);       // 预算已是剩下的那一段，不再另起一次 timeout
    } on _AdmissionLost          { _safeRespond(request, 504, timeout); }
      on _RequestBodyTooLarge    { _safeRespond(request, 413, bodyTooLarge); }
      on SyncRequestRefusal catch (r) { _safeRespond(request, r.statusCode, r.error); }
      catch (e, s)               { _safeRespond(request, 500, '$e'); print(e, s); }
  }
}
```

`_serveSerial` 与它外层那次 `.timeout()` 一起消失：超时不再是"套在未来外面的一圈",
而是 gate 在处理器**内部**抛出来的一段——只有这样才能让 `finally` 跑、让 beat 计数归零。

## 3. 取消：一个 gate，一串提交点

gate 不被"等待"，只被"检查"：处理器在**每个真正改状态的地方之前**调一次 `check()`，失败就整段放弃，
之前已经落的东西保持原样（它们都是幂等的，见 §6 F-1）。事务**内部绝不检查**（D-3）。

| # | 提交点（现有符号） | 放弃时发生什么 |
|---|---|---|
| 1 | `handleHello` → `_sessions[peer] = session` | 会话不装；对端下轮重试 |
| 2 | `handlePair` → `store.savePeer` + `rememberPeer` | **不装对端**：否则对端拿到一个它永远验不过的配对 |
| 3 | `handleRevoke` → `store.deletePeer` + `forgetPeer` | 不解除；对端下个会话自己发现 |
| 4 | `handlePutWorkspaceFile` → `land()` 的 rename 之前 | 临时文件删掉，工作区不动 |
| 5 | `handlePutBlob` → 同上 | 同上 |
| 6 | `handleApplySubtrees` → 每个 `dataPlane.applySubtrees`/`applyBusiness` **的每个对话事务之前** | 已落的对话保留（下轮重算即可） |
| 7 | `handleFetchSubtrees` → 删除循环开始前一次 | 已删的保留（`_deletionStillStands` 幂等） |
| 8 | `handleFetchSubtrees` → `saveCheckpointUnlessReplaced` + `_sessions.remove` + `mutatePeer` | 检查点**不写**、会话留着被 sweep 收走 |

第 6 条是"每个对话事务之前"而不是"每个对话开始前"：一次 apply 里几十个事务，检查太稀会让一个
早已超时的请求继续写很久；检查太密（事务内）则违反 D-3。事务边界就是那个稀疏度。

`handlePutWorkspaceFile`/`handlePutBlob` 的 `body` 读与 `land()` 写都必须经 `gate.ioStream`/`gate.io`，
否则"对端不读 socket"这一格由 `_beginBeat` 的 `finally` 兜着，而那个 `finally` 永远不会到。

## 4. 客户端：一次传输一个预算

`pushBlob` / `pushWorkspaceFile` 今天把 `addStream` 放在计时器之外（N2），七处 `drain` 也没有期限。
一处一个秒表，所有 await 都花同一个预算：

```dart
Future<void> _transfer(Future<void> Function(Duration left) body) async {
  final sw = Stopwatch()..start();
  Duration left() {
    final r = blobDeadline - sw.elapsed;
    if (r <= Duration.zero) throw const SyncClientException('transfer_timeout');
    return r;
  }
  try { await body(left()); } finally { sw.stop(); }
}

// pushBlob / pushWorkspaceFile 里：
await _transfer((left) async {
  await request.addStream(source.openRead()).timeout(left);   // 对端不读就在这里断
  final response = await request.close().timeout(left);
  await response.drain<void>().timeout(left);                  // 正文不结束就在这里断
  if (response.statusCode != noContent) throw ...;
});
```

断的时候 `request.abort()`（`HttpClientRequest.abort`）而不是"等它自己超时"：per-await 的 `.timeout`
只解除等待，socket 还开着，下一次请求会排在它后面。

## 5. 不变量

- **I-1 写不并发。** 设备上任何两个写处理器不重叠。A 用一条车道达成，和今天一致。
- **I-2 读只读已发布的快照。** 读处理器能看到的一切，都在发布点整份替换，绝不原地拼：
  `WorkspaceContentSync.publish` 先建整张新表再赋值（`_served[peer] = served`），会话字段在发布
  之后不可变，`_publishedBlobs`/`_publishedSkillIds` 只在同步段里改。违反它，读车道并发就会
  答出半张表——这是本变体唯一新增的耦合面。
- **I-3 预算单调。** `remaining` 只减；`io()` 不重置它；出队不重新发预算（D-4）。
- **I-4 事务内无网络 await。** 读车道的活性依赖写车道的**事务**短，而不是写 beat 短。今天
  `_fetchOne` 是"先网络后落盘后 DB"，成立；这是要保持的形状，不是可以随手破的。

## 6. 失效模式

| # | 失效 | 表现 | 防线 |
|---|---|---|---|
| F-1 | 某处提交点漏了 `check()` | 超时后照样落库（O2 原样） | G5 注入证明：注掉 #8 那格红；hash 还原 |
| F-2 | 读读到半张表 | 对端 404/尺寸不符，多传一轮 | I-2；状态表有一格专测并发读 |
| F-3 | 把 `.timeout` 当取消 | 只解除调用者的等待，被放弃的 work 继续写 | `io()` 只用于**可放弃**的等待；要写的东西自己过 check |
| F-4 | 504 之后处理器再写 response | 双 close（`_safeRespond` 已有 try/catch，会**掩盖**） | 状态表断言"只答一次"；gate 死了就不进 `_route` 的应答路径 |
| F-5 | `finally` 没跑 | `beatsInFlight` 不归零，会话永不被 sweep | `_endBeat` 在 gate 抛出的路径上也要跑 |
| F-6 | `/pair` 被放弃却装了 peer | 对端显示已配对、永远 401 | 提交点 #2 |
| F-7 | 读车道没有上限 | 一个坏 peer 开 N 个 GET 占连接 | 已知限制：今天无上限，需要时照 `ping_busy` 加 |
| F-8 | 一个 peer 的写洪水 | 合法 peer 排在他后面 | 已知限制（A 的代价）；B 能缓解，不解决 |

## 7. 状态表 —— 一格一测

新文件 `test/core/services/sync/sync_admission_test.dart`；编号就是用例名。

| # | 情形 | 期望 |
|---|---|---|
| 1 | 写 beat 进行中，对端 `GET /sync/blob` | 立即应答（G0） |
| 2 | 写 beat 进行中，对端 `POST /sync/wsfile` | 立即应答（G0） |
| 3 | A→B、B→C、C→A 各缺附件 | 一轮内收敛，不环等（G0） |
| 4 | 写 beat 进行中，另一 peer 的 hello | 排队；不并发写（I-1） |
| 5 | 排队 29 min、执行 2 min | 出队只剩 1 min，超时 504（G2） |
| 6 | 排队就耗尽预算 | 不入执行，504，零副作用 |
| 7 | fetch beat 超时后原 future 恢复 | 不写检查点、不摘会话、不写报告（G1） |
| 8 | push beat 超时 | 会话不装（G1） |
| 9 | PUT 落盘前超时 | 工作区不变，临时文件没了 |
| 10 | `/pair` 超时 | 不装 peer：对端再试仍能配上（F-6） |
| 11 | 读与同 peer 写并发 | 答案是旧表或新表，绝不是两者混合（I-2） |
| 12 | 未鉴权的 hello 洪水 | 就地 401，写车道零排队 |
| 13 | 8 个 `/pair` 并发 | 第 5 个 503 `pair_busy`，数据面照常（G4） |
| 14 | 上传时对端不读 socket | `addStream` 在预算内断，会话可重试（G3） |
| 15 | 错误响应正文不结束 | `drain` 有期限（G3） |
| 16 | 事务中途超时 | 当前事务跑完，下一个不开（D-3） |
| 17 | ping 仍在进行中的 beat 旁应答 | 回归 slice 19 |

#1、#2、#4–#6、#12–#17 落在 `sync_admission_test.dart`；#3 需要三个引擎，落在
`sync_engine_integration_test.dart` 的 "a ring of three devices does not wait on itself"；
#7–#11 也各有一格引擎层的用例。

注入证明（G5）：(a) 注掉提交点 #8 的 `check()` → #7 红；(b) `GET /sync/blob` 改回写车道 → #3 红
（整格 30 秒挂死）；(c) 去掉 `/pair` 车道 → #13 红；(d) 把 `addStream` 放回计时器外 → #14 红；
(e) 上限抬到 99 → #13 红。各自按 sha256 还原核对。

## 8. 与变体 B 的那一处差别

B 把第 1 节的"write（一条）"换成"write（每个 peer 一条）"。其余骨架逐字相同——所以这个决定
可以单独做出，不必重画整份骨架。B 的收益与代价写在它那篇的第 5 节。
