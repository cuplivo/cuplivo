# 第 5 轮·A｜一张表，全在 widget 层跑

> 目标书 §4 的矩阵有几行，测例就写几行；三列布局 × 开关两态 = 一张 36 格的表，
> 每格都真起一个抽屉/布局，断言三件事：打开的会话、侧栏列表、可见视图。

## 1. 形状

```
group('owner 点击：矩阵')
  for layout in [mobile, desktop-left, desktop-right]
    for switch in [on, off]
      for row in [A, B, C, D(topic/no-topic), E, F]
        test('$layout / 开关 $switch / $row') {
          pump(host(layout))                       // 真抽屉 + 真布局
          tapOwner(...)
          expect(openConversation.owner, expected)  // 打开的是谁的会话
          expect(sidebarRows.ownerScope, expected)  // 列表口径
          expect(revealState, expected)             // tab 索引 / 面板活动页
        }
```

- 好处：**每格都是端到端真话**。目标书 §4 说「每一格都要在真机和自动测试两处同时为真」，
  这张表就是那句话的直译，评审时能一格一格对着看。
- 列表口径与可见视图是**同一次 pump 之后**读的，不存在「两层各对一半、组合起来错」的缝。

## 2. 代价

- 36 个 widget test，每个都要起 providers + 抽屉 + 布局；本仓库的 drawer 测试单文件已经 1300 行，
  这类测试的启动成本不低，跑一遍的时间会明显变长。
- 两个进程级单例是**测试间泄漏源**：`DesktopSidebarTabBus.instance`（进程级广播流 + `_currentIndex`）
  和 `DesktopSidePanelController.instance`（单例，带持久化状态与 open/kind）。
  一条断言漏了 `addTearDown` 重置，下一条就会读到上一条的 tab 索引，
  而且失败信息会指向「reveal 没生效」，把排查方向带偏。
- 36 格里有 24 格只差「开关」一个布尔：它们的差别只体现在 reveal 一列，
  却在 widget 层重复付了 24 次全套启动成本。
- 守卫证明要注入的缺陷在不同层，36 格的表只能证明「某几格红了」，
  不容易说清「哪条规则被破坏了」。

## 3. 适合

要求「矩阵逐格可点验」，且接受测试时长与单例重置的维护成本。
