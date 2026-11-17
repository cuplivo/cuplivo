# 守卫证明记录（第 5 轮 T1–T4 的注入）

> 每条都是：注入缺陷 → 指定测试红 → 字节级还原（SHA-256 相等）。
> 注入前的哈希（三个被改文件）：

```
439775793AA950F2A724C650EDFF04C7E737CD63C0DE8A6A263417C699C743B6  lib/features/home/controllers/home_page_controller.dart
1876FDA78A15D18AD17229EAC505A5B8E77FF313562BBFBA983317FA31CCAB3B  lib/features/home/widgets/side_drawer.dart
4838FEA1AA5CBE5BCD7A2BB50C34CB861548D9BF8556E4406BB139A9E9EDF90D  lib/features/chat/widgets/frosted/chat_frosted_backdrop.dart
```

| # | 注入 | 应红的测试 | 实测 | 不变量 |
| --- | --- | --- | --- | --- |
| 1 | `createNewConversationAnimated` 对具名 owner 仍继承当前群 | `openOwner_test` › a group topic + assistant with history (newChat=true) | 红：新建会话带上了群 id | I3 一次点击一个意图 |
| 2 | `revealTopics` 删掉 `topicsOnRight` 分支 | `openOwner_test` › topics on the right, setting on / panel already open | 红：面板没打开、活动 tab 仍是 files | I5 设置只在能生效处生效 |
| 3 | `_listScope` 忽略当前会话，只看默认助手 | `owner_tap_wiring_test` › the topic list follows the chat that is open | 红：群话题不出现 | I4 列表跟随归属 |
| 4 | 助手行高亮改回 `currentAssistantId` | `owner_tap_wiring_test` › a group topic highlights its group | 红：`['Alpha','Gamma']`（两行同时高亮） | I2 选择 ≠ 归属 |
| 5 | `ChatBackdropSpec.resolve` 不判断群话题 | `chat_backdrop_owner_test` | 红：群话题 active = true | I1 单一归属 |

五条全部按预期失败；还原后三个文件的哈希与注入前完全相同。

## 第 6 条（评审后追加）｜删掉打开的群话题后的「下一个会话」

| # | 注入 | 应红的测试 | 实测 | 不变量 |
| --- | --- | --- | --- | --- |
| 6 | `_nextRecentConversationExcluding` 的 scope 改回「默认助手」（忽略当前会话的归属） | `owner_tap_wiring_test` › deleting the open group topic picks another topic of it | 红：挑中了助手的 1:1 而不是同群的另一个话题 | I4 列表跟随归属 |

注入前 `side_drawer.dart` = `83177EA2…19F7A`，还原后同一哈希。

这条与评审的发现一致：删除后的「下一个会话」用的还是 `assistantId == currentAssistantId`，
而群话题的 `assistantId` 为 null，所以它永远不会成为候选——删除群话题会把用户甩到助手的 1:1。
现在它走 `nextConversationAfterDelete`（同一套归属判断），顺带把移动菜单里那份副本也删掉了。

## 第 7、8 条（第二次评审后）｜窄窗口的侧栏覆盖层

| # | 注入 | 应红的测试 | 实测 | 不变量 |
| --- | --- | --- | --- | --- |
| 7 | 去掉 `openOwner` 里的 `closeCompactSidebar()` | `owner_open_test` › a narrow desktop closes its sidebar overlay on a tap | 红：`tabletSidebarOpen` 仍为 true | I3（一次点击的收尾属于管道） |
| 8 | 去掉 `revealTopics` 的 `_compactDesktop` 分支（允许它重新打开覆盖层） | `owner_open_test` › a narrow desktop does not reopen the overlay to reveal | 红：`tabletSidebarOpen` 变回 true | I5 设置不制造遮挡 |

注入前 `home_page_controller.dart` = `95ECB67D…4712`，还原后同一哈希。

评审发现的是我引入的回归：窄窗口（< `AppBreakpoints.tablet`）下侧栏是 `AnimatedPositioned`
覆盖层 + `ModalBarrier`，不是路由，所以抽屉的 `maybePop()` 到不了它；而 `openOwner` 直接接在
页面上，绕过了原来两个回调里的 `closeCompactSidebar()`。修法是把「关掉遮挡当前会话的东西」
放进管道本身（不是包一层 tear-off），于是任何入口都自带这一步。

## 两条永久守卫（不是一次性注入）

- **「＋」与「点 owner」对照**：`owner_open_test` › a new chat from a dead group topic carries
  no group id —— 匿名「＋」保留群继承，具名 owner 绝不继承；把继承整个删掉会让前者红，
  把具名路径写回继承会让后者红（注入 1 证明后者）。
- **群话题不写默认助手**：`owner_open_test` › opening a group leaves the default assistant alone。
  选中是派生的，落盘的只是「默认助手」，群不是任何东西的 fallback。

## 与计划的偏差（实现时发现，已改）

1. **多一个纯函数 `ownerOfChat`**：provider 的 `Selector` 在父级重建时会失效重算
   （`oldWidget != widget`），所以「整个 `Conversation` 放进 select」会让每次切换都重建列表。
   列表只依赖归属的两个字段（`groupChatId` / `assistantId`），由 `ownerOfChat` 直接吃字段。
2. **`createNewConversationAnimated` 的参数从 `groupChatId` 换成 `owner`**：全仓没有调用点
   用过 `groupChatId`，两个可空字符串参数会变成「同一件事的两种说法」。
3. **删除 `lib/desktop/desktop_sidebar.dart`**：没有任何 import 的 `DesktopSidebar` 包装，
   不接 `onOpenOwner` 就是一条绕过管道的入口（I6）。
4. **`side_drawer_conversation_list_test` 的 orphan 用例**：它靠「切换选中的助手改变列表」，
   而列表口径现在是「当前会话的归属」。用例改为从「没有打开任何会话」这一状态出发——
   那正是快照状态（选中助手）决定口径的**唯一**场合。
