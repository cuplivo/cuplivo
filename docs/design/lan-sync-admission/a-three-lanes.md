# 核心骨架 · 变体 A —— 三条车道，写仍是一整条

**已采纳**（2026-11-19，决定 D-1a）。落地后与本文的差别：`_Admission` 叫 `sync_admission.dart`
里的 `SyncAdmission`；`_WriteLane` 没有成为一个类，写车道仍是 `_serve` 里的那条 future 链；
`gate.io` 收的是回调而不是 future（一个已经启动的 future 被 gate 拒绝时会留下无人监听的错误）；
预算用 `Stopwatch` 量（单调钟，见 §2 的注）；车道判定是一张表——`_classify` 同时给 route 和 lane，
`_route` 对它穷尽 switch，`/pair` 在表里按鉴权分类（见 §1 的注）。
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

（落地时的两处修正：`remaining` 用 `Stopwatch` 量而不是 `DateTime.now()`——预算是"允许花多少工作"，
一次 NTP 校时不该判定一个正在推进的请求已经超时；`io` 收回调而不是 future，见 §6 F-3。）

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

- **I-1 提交不并发。** 两个写处理器的**提交**永不重叠：每个提交点都过 `check()`，被取消的处理器到
  下一个提交点必然被拒。注意这不是"两个处理器不重叠"——车道排的是**应答**，504 一写出去，下一个
  写请求就被放行，被放弃的处理器还在跑（它可能跑完一笔落盘/落 blob，那是幂等、下一轮会重规划的，
  真正记账的检查点在 `check()` 后面）。第一版把 I-1 写成"处理器不重叠"是假的；这一格
  （`a cancelled write handler cannot commit beside the next one`）钉的是能成立的那一条。
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
| F-2 | 读读到半张表 | 对端 404/尺寸不符，多传一轮 | I-2：整表替换由 #11 一格测，并发读者本身不另测——它看到的是没有第二次赋值的那个 map |
| F-3 | 把 `.timeout` 当取消 | 只解除调用者的等待，被放弃的 work 继续写 | `io()` 只用于**可放弃**的等待；要写的东西自己过 check |
| F-4 | 504 之后处理器再写 response | 双 close（`_safeRespond` 已有 try/catch，会**掩盖**） | 状态表断言"只答一次"；gate 死了就不进 `_route` 的应答路径 |
| F-5 | `finally` 没跑 | `beatsInFlight` 不归零，会话永不被 sweep | `_endBeat` 在 gate 抛出的路径上也要跑 |
| F-6 | `/pair` 被放弃却装了 peer | 对端显示已配对、永远 401 | 提交点 #2 |
| F-7 | 读车道没有上限 | 一个坏 peer 开 N 个 GET 占连接 | 已知限制：今天无上限，需要时照 `ping_busy` 加 |
| F-8 | 一个 peer 的写洪水 | 合法 peer 排在他后面 | 已知限制（A 的代价）；B 能缓解，不解决 |

## 7. 状态表 —— 一格一测

一格一个用例，下面第三列就是用例名（原写的"编号就是用例名"是假的，第一版交付时还没有这些用例）。
表外另有三格，测的是机制而不是某一格情形：`every route takes the lane its effect names`（路由与车道同一张表，16 个 method×path 逐条观测）、I-1 那一格（被取消的处理器提交不了）、以及 `a stream that keeps emitting is cut when the budget ends`（`ioStream` 逐块读预算，而不只是查空闲）。

| # | 情形 | 用例（`test/core/services/sync/`） |
|---|---|---|
| 1 | 写 beat 进行中，对端 `GET /sync/blob` | `sync_admission_test.dart`：a blob fetch is answered while a write beat holds the lane |
| 2 | 写 beat 进行中，对端 `POST /sync/wsfile` | 同上：the read direction of /sync/wsfile answers beside a write |
| 3 | A→B、B→C、C→A 各缺附件 | `sync_engine_integration_test.dart`：a ring of three devices does not wait on itself |
| 4 | 写 beat 进行中，同一 peer 的写 | `sync_admission_test.dart`：a write is still queued behind the one in flight |
| 5 | 排队 450 ms、执行 400 ms（预算 600 ms） | 同上：a request that waited keeps only what is left of its budget |
| 6 | 排队就耗尽预算 | 同上：a request queued behind a beat has already spent its budget |
| 7 | fetch beat 超时后原 future 恢复 | `sync_engine_integration_test.dart`：a fetch beat the deadline abandoned writes no checkpoint |
| 8 | hello 超时 | 同上：a hello the deadline abandoned installs no session |
| 9 | PUT 落盘前超时 | 同上：a pushed file is written only for the version the session asked for（末段的 spent-gate） |
| 10 | `/pair` 超时 | 同上：a pairing the deadline abandoned installs nothing |
| 11 | 发布是整表替换（读者看到的只可能是旧表或新表） | `workspace_content_sync_test.dart`：a published table is replaced whole, never merged（测的是替换，不是交错；一份已赋值给 `_served[peer]` 的表不会再被原地改，所以"半张表"在结构上不成立） |
| 12 | 未鉴权的 hello | `sync_admission_test.dart`：an unauthenticated request never joins a queue |
| 13 | 4 个 `/pair` 并发 | 同上：pairing has its own capped lane, and cannot hold the data plane |
| 14 | 上传时对端不读 socket | 同上：a push the peer never reads ends inside its budget |
| 15 | 错误响应正文不结束 | 同上：an error body that never ends is not waited out |
| 16 | 事务中途取消 | 两格：`sync_engine_integration_test.dart`：a push beat the deadline abandoned applies no conversation（引擎把 gate 接进 apply 的那一段）+ a cancelled apply finishes the conversation it is on, then stops（循环本身，直接调 `dataPlane`） |
| 17 | ping 仍在进行中的 beat 旁应答 | 同上：/sync/ping is answered beside a beat that is still running（既有） |

提交点没有编号，也各有一格：hello 安装（#8）、`/pair` 记录（#10）、`revoke` 删除
（`a revoke the deadline abandoned forgets nothing`）、文件 rename（#9）、blob 放置
（`a pushed blob is written only for the hash the session asked for` 末段）、检查点（#7）、
每个对话事务（#16）。删除循环只有一次检查、且每条删除都重读它所删的行，所以"循环中途取消"这一格
不存在——它唯一可达的状态是"继续删完，再拒绝检查点"，而检查点那一头由 #7 覆盖。

注入证明（G5）：(a) 注掉检查点前的 `check()` → #7 红；(b) `GET /sync/blob` 改回写车道 → #3 红
（整格挂死到框架 30 秒超时）；(c) `/pair` 放回写车道 → #13 红；(d) 把 `addStream` 放回计时器外 →
#14 红；(e) 上限抬到 99 → #13 红。各自按 sha256 还原核对。

## 8. 与变体 B 的那一处差别

B 把第 1 节的"write（一条）"换成"write（每个 peer 一条）"。其余骨架逐字相同——所以这个决定
可以单独做出，不必重画整份骨架。B 的收益与代价写在它那篇的第 5 节。
