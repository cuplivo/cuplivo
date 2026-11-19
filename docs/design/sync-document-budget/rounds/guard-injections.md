# 守卫证明记录：一次推送的字节预算

> 每条都是：注入缺陷 → 指定测试红 → 字节级还原（SHA-256 相等）。

## 第 1 条｜`bothSend` 的检查点不检查"这一半发了没有"

这是审计发现的数据丢失（见 `decisions.md`），修在准入之前，证明也先做。

| # | 注入 | 应红的测试 | 实测 | 不变量 |
| --- | --- | --- | --- | --- |
| 1 | 发送臂的守卫整个去掉：`myHalfCrossed` 恒定 `true`（`_advanceCheckpoint` 里 `peerSends || bothSend` 合并后的那一处） | `sync_engine_integration_test.dart` › one push's byte budget an omitted bothSend conversation keeps the edit it did not send | 红：`Expected: contains 'conv-a-aonly'` / `Actual: Set:['conv-a-m0', 'conv-a-bonly']` —— 本机没发出去的那行被下一轮删掉了 | I3「被跳过的会话检查点停在 prior」 |

注入前 `sync_engine.dart` = `5D1A0149DF3787F9266D8B943D7A7887036667BE2D371264038452FB4011AA69`（193,925 字节），
还原后同一哈希。

> 这条在评审后被重跑过一次：第一次记录的是 `907B8100…`，而评审拿到的树是 `B2A4B232…` —— 那份记录证明的是
> 一个已经不存在的文件（中间还有 `sizeOmitted.isEmpty` 的资产清单改动）。现在记录的是**当前树**的哈希。

## 第 2–5 条｜预算的四个格子

一次注入、一次运行，四条规则同时破：按**代码单元**计数（而不是 UTF-8 字节）、忽略单会话上限、
在第一处超限处 `break`（而不是 `continue`）、以及由此带来的 CJK 那一格。

| # | 注入 | 应红的测试 | 实测 | 不变量 |
| --- | --- | --- | --- | --- |
| 2 | `utf8LengthOf` 改成 `text.length` | `sync_budget_test.dart` › a CJK string is three bytes per code unit | 红：`Expected: <12>` / `Actual: <4>` | G4 按真实字节 |
| 3 | 同上 | › a conversation is counted in wire bytes, not Dart characters | 红：`269` vs `189` | G4 |
| 4 | `admitConversations` 去掉 `bytes > perConversationBytes` | › a conversation larger than the per-conversation cap rides in no round | 红：`['small','huge']`（超限的也进了批次） | D-2 单会话上限 |
| 5 | `continue` 改成 `break` | › an over-budget conversation does not end the walk | 红：`[]`（后面两条也被饿死） | D-4 顺序 + 跳过语义 |
| — | 三条叠加 | › CJK bytes decide, not Dart length | 红：`444`（字符数）而不是 `888`（字节数） | G4 |

注入前 `sync_budget.dart` = `04A221222E7DE21160FAB7D01295F71A985A7680AF177D6BF42FB38EC84239F3`，
还原后同一哈希。运行：`flutter test test/core/services/sync/sync_budget_test.dart`，6 红 / 3 绿。

## 第 6 条｜发送前那一次实测（`assertPushFits`）

评审指出 G0 只有"手搓 batch 的算式"一条证明，引擎把**量的那份**和**发的那份**错开时没有东西会红。
补的是发送点上的一次实测断言：`assert(assertPushFits(pushBatch, deltaByteBudget))`。

| # | 注入 | 应红的测试 | 实测 | 不变量 |
| --- | --- | --- | --- | --- |
| 6 | 把发送点的预算改成 `assertPushFits(pushBatch, 1)` | `sync_engine_integration_test.dart` › one push's byte budget a conversation the budget leaves behind is deferred, not failed | 红：`error:Bad state: push body 108 B exceeds the 1 B budget` —— 断言量的是**真正要发出去的那份 body** | G0「不会因为体积打出 413」 |

注入前同一哈希 `5D1A0149…AA69`，还原后一致。断言本身另有一条纯函数测试
（`sync_budget_test.dart` › the batch about to be sent is checked against the budget）：恰好等于预算通过，少一个字节抛错。
