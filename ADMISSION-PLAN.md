# 计划书 — 准入、期限与取消

这份文件是**计划**：目标、决定、提交切分。设计本身在
[`docs/design/lan-sync-admission/a-three-lanes.md`](docs/design/lan-sync-admission/a-three-lanes.md)，
决定的历史在 [`docs/adr/0003-lan-sync-architecture.md`](docs/adr/0003-lan-sync-architecture.md) 的
`Amendment (2026-11, admission)`。两处都改过而这里没跟上的句子，以那两处为准——计划记的是当时怎么
想的，不是系统现在是什么样。

| | |
|---|---|
| branch | `refactor/lan-sync-admission` |
| base | `04c1e594e`（#1088 之后） |
| 覆盖 | N1（未鉴权 `/pair` 占全局串行）、N2（上传与 drain 无期限）、O1（只读路由被写 beat 挡住 → 环形互等）、O2（超时不取消）；**无协议变更** |
| 状态 | 已交付；评审第一轮五条、第二轮四条按提交记录回应（见分支历史） |
| 骨架 | `docs/design/lan-sync-admission/a-three-lanes.md`（伪代码、不变量、失效模式、状态表与用例名） |

## 0. 一句话

**一个监听端只有一条按到达顺序排队的串行链，而"谁可以和谁并跑""调用者消失后会发生什么"从来没有被设计过，只被逐个调用点地补过。** 于是只读的 blob GET 排在写 beat 后面，deadline 在出队后才开始算，超时也不取消——三条缺陷同一根。

## 1. 目标（验收锚点，不可协商）

- **G0 只读不被写挡住**：`GET /sync/blob/<hash>` 与读方向的 `POST /sync/wsfile` 在一个写 beat 进行中仍能被应答；三设备环形（A→B、B→C、C→A 各自缺附件）不再互相等待。
- **G1 截止即取消**：一个被 deadline 放弃的处理器**不能**再安装会话、写检查点或落库；串行隔离在超时之后仍然成立。
- **G2 期限从准入开始**：一个请求的预算从**进入队列**那一刻算起，排队时间计入；排在长 beat 后面的请求不会获得"完整的 30 分钟再来一次"。
- **G3 客户端有整段预算**：从第一字节到最后一个 `drain` 都有期限；`addStream` 不再跑在计时器之外（N2）。
- **G4 未鉴权不占车道**：`/pair` 有自己的低并发车道，占满即 503 `pair_busy`（与 `ping_busy` 同一种拒绝语言），不能靠排队拖住数据面（N1）；未鉴权的 `/sync/*` 在派发点就地 401，根本不进队。
- **G5 每条目标注入即红**，恢复后按字节一致（hash 对比）。

## 2. 非目标

- 不改 wire、不改协议版本、不改合并语义。
- 不为"三设备环形"做全局死锁检测：G0 让它不发生即可。
- 不改配对窗口、PIN、TLS、端点集。
- 不重写会话状态机；只加"这次写入是否仍被授权"的判定。

## 3. 已定决策

| # | 决策 | 理由 |
|---|---|---|
| D-1 | 按**效果**分道，不按路径：只读（blob GET、wsfile 读 POST、ping）并跑；写（hello/push/fetch/revoke/PUT）**排队**，`/pair` 独立车道 | 环是被"读排在写 beat 后面"卡住的，分开读就断了；写车道是否再按 peer 拆是另一个决定 |
| D-1a | **写车道保持设备级一条**（不按 peer 拆；计划初稿的按 peer 串行**不采纳**） | 拆 peer 不带来 G0 的任何收益，却把"并发写"从事故变成常态：不变量从设备级降到 peer 级，ADR slice 3 那句"共享会话状态与检查点文件"必须改口，且新增 I-4′（事务内无网络 await）从习惯变承重。多设备并发的收益留待实测后再议 |
| D-2 | 取消用一个随请求走的 **gate**（入场时间 + 预算 + 已失权标记），处理器在每个提交点前 `check()` | 只靠"尽力而为的 future 忽略"无法阻止旧处理器落库（O2）；一个对象同时携带"还剩多少预算"与"还能不能写"，两件事才不会各说各话 |
| D-3 | 取消只发生在**事务边界之间**：当前事务跑完，下一步之前拒绝继续 | 中途掐断事务会留下半写状态，比超时本身更糟 |
| D-4 | 队列等待也计时，且 `_deadlineFor` 的时钟起点改在**入队** | 否则"排队 30 分钟 + 执行 30 分钟"是合法状态（N1 的一半） |
| D-5 | `/pair` 独立车道 + 并发上限（复用 `kMaxPingsInFlight` 的写法） | 未鉴权路由不能与数据面共享一条无上限的链 |
| D-6 | 本 PR **amend ADR-0003** slice 19/24 的车道描述 | 这是对既有决定的修改，不是实现细节；ADR 必须改口 |

## 4. 交付物（到面，不逐行）

| 面 | 一句话改动 |
|---|---|
| 服务端分道 | `_serve` 的单一 `serial` 链拆成：只读直派（并发）、一条写链（设备级）、`/pair` 车道；鉴权提到派发点做唯一一次判定，未鉴权的 `/sync/*` 不进任何车道 |
| 准入 | 入队时装置计时器（含排队时间），出队后用剩余预算执行 |
| 取消 | 每个写处理器带一次"代次"；`_route` 的每次落库前校验，失败即放弃且不写 |
| 客户端 | `pushWorkspaceFile`/`pushBlob` 的 `addStream` 纳入预算；七处 `drain` 加期限；超时取消请求 |
| 常量 | 预算与并发上限进 `sync_limits.dart`；`/pair` 上限按"一次真人配对只有一台设备"定并写明依据，**不从端点上限推导**（两者无关，硬套一个数字只会造出第二个无人核对的边界） |
| 文档 | ADR-0003 amendment：分道规则、取消语义、排队计时；`CONTEXT.md` 的"Every request is bounded"改为"从入队起有界" |

## 5. 状态表（一格一测）

完整的格在骨架文档 §7（每格点名它落在哪个用例；这一节只是写计划时的四组锚点，不是清单）。

| 情形 | 期望 |
|---|---|
| 写 beat 进行中，对端 `GET /sync/blob` | 立即应答（G0） |
| 三设备 A→B、B→C、C→A，各缺附件 | 不再环等；最坏是一轮内的正常往返 |
| 处理器超时后，原 future 恢复 | 不安装会话、不写检查点、不落库（G1） |
| 请求排队 29 分钟、执行 2 分钟 | 出队时只剩 1 分钟预算；超即 504（G2） |
| 上传时对端不读 socket | `addStream` 在预算内失败，会话可重试（G3） |
| 错误响应正文不结束 | `drain` 有期限，不永久占连接（G3） |
| 8 个 `/pair` 并发 | 第 5 个 503 `pair_busy`；数据面照常（G4） |
| 同一 peer 的两个写请求并发 | 串行；检查点只有一份（除 D-1a 外，写车道设备级一条让它更强） |

## 6. commit 结构

1. `fix(sync): a read-only route is not queued behind a write beat`（G0）
2. `refactor(sync): a deadline starts at admission and cancels its handler`（G1/G2，含代次）
3. `fix(sync): a transfer has one budget from first byte to last drain`（G3）
4. `fix(sync): pairing has its own lane`（G4）
5. `docs(adr): the lane design, and what cancelling means`

## 7. 验证

- `dart analyze --fatal-infos lib test integration_test`；`dart format`（CI 钉住的 Dart 版本）
- `flutter test test/core/services/sync` + 完整 `sync_engine_integration_test.dart`（它已有 `/sync/ping` 旁跑、半发 `/pair` 等用例，是本 PR 的回归网）
- 新增并发测试进新文件 `sync_admission_test.dart`（骨架 §7 逐格点名用例）
- 注入证明（实际做了五条，各自按 sha256 还原核对）：注掉检查点提交点前的 `check()` → "超时后不写检查点"那格红；把 `GET /sync/blob` 改回写车道 → 环形那格红；去掉 `/pair` 车道 → 并发那格红；把 `addStream` 放回计时器外 → 上传那格红；上限抬到 99 → 拒绝消失

## 8. 风险与回滚

- **R1** 写链不再按 peer 拆（D-1a），"两份检查点互相覆盖"这条老风险因此原样不存在；换来的是新的耦合面：读车道与写 beat 并发，活性依赖两条不变量——**读只读已发布快照**（`publish` 整表赋值已如此）与**事务内无网络 await**（`_fetchOne` 已是"先网络后落盘后 DB"）。两条都要写成断言 + 各自一格测试，而不是注释。
- **R2** 取消打断事务——D-3 已把它限制在事务边界之间；测试要覆盖"事务中途不取消"。
- **R3** `/pair` 车道上限可能误伤正常配对（用户连点扫描）。上限要按"几个并发配对算正常"来定，并有拒绝文案。
- **R4** 这是四个 PR 里唯一动并发骨架的：放最后合，冲突面最小（`sync_engine.dart` 里它碰会话/取消，前三个碰批次构建与 hello）。
- **回滚**：commit 可按需单独 revert；分道回退到全局链即恢复今天的行为（并恢复环形互等）。
