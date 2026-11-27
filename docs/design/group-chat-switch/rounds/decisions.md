# 决策记录：助手 ↔ 群聊切换

> 每一轮一个决定，按轮次追加。目标书是输入，本文件是**已定的**结果。
> 目标书：`docs/design/group-chat-switch/refactor-plan.md`

| 轮 | 决定 | 结论 | 落下的东西 |
| --- | --- | --- | --- |
| 1 | 范围 | **B｜结构性**（非 A 窄修） | `ChatOwner` 为参数的一条 intent 管道：归属 / 会话 / reveal 三步 |
| 2 | 管道落点 | **A｜落 `HomePageController.openOwner`**（非独立 service） | 三个规则各一个唯一落点；状态表与失败模式写在一处 |
| 2b | 选中 vs 落盘 | **A｜语义归位、不改名**（不改 `defaultAssistantId`） | 选中由 `ownerOf(当前会话)` 派生、不落盘；只写「默认助手」；群不写 |
| 3 | 「自动切换话题」 | **A｜保留，两侧桌面布局都生效**（不删设置） | reveal 一个落点，左布局切 tab / 右布局开面板到话题页 |
| 4 | 开关开的语义 | **A｜一律新建**（矩阵 A 行 = 新） | 只修「落在群里」，不改开关开着时的其余行为 |
| 5 | 门禁 | **B｜按层拆 T1–T4**（非一张 36 格 widget 表） | controller 12 格 / 纯函数 4 格 / reveal 6 格 / smoke 3 条 + 5 条注入 |
| 6 | rebase 记录 | **B｜本轮登记为 unit 并注明取代 #1069** | 两张表各一行；sha 回填进完成定义 |

## 轮 1｜范围取 B（结构性）

- 选项：A 把 4.6.0 的 #1069 重放回来（F1/F3 消失，F4/F5 留存）；B 把「谁拥有这个会话」与
  「我要开一个谁的新会话」各收一处（F1/F3/F4/F5 一起消失）。
- 结论：**B**。
- 理由：F4/F5 不是同一段 diff 能盖住的；第三步 reveal 在热键路径上已有实现，不需要发明机制；
  新入口不必记得补步骤本身就是要买的东西。
- 后果：本轮之后走**伪代码轮**（数据流、不变量、失败模式），不直接开工；
  `onNewConversation(assistantId:)` 这样的参数链**不保留**（I6），被替换的入口删除。
- 证据：`a984426fa` = #1069 的完整 diff（15 个文件）；当前树 `createNewConversationAnimated`
  无 `assistantId`，`ChatBackdropSpec.resolve` 无群判断——整段没重放进 4.7.0。

## 轮 2｜管道落 `HomePageController.openOwner`（不拆 service）

- 选项：A 管道落 controller（五个步骤里四个已是 controller 的方法）；B 独立 `OwnerOpener`，
  controller 只接线。
- 结论：**A**。B 会用 5 个回调把控制权要回来，把一条规则切成两半，且端到端仍要再验一遍。
- 现状核对：reveal 的两种布局分支都已存在——`DesktopSidePanelController.open(kind: topics)`
  （热键路径正在用）与 `DesktopSidebarTabBus.switchToTopics`（抽屉已订阅该总线，
  `side_drawer.dart:264`）。抽屉里内联的 `_tabController.animateTo(1)` 是同一动作的第二份实现。

## 轮 2b｜选中是派生的，落盘的只是「默认助手」

- 修正来源：第 2 轮 A 的第 4 步把「哪个 owner 被选中」和「新 1:1 归谁」写成一步，
  这是不统一的——群这一半读会话、助手那一半读持久化字段。
- 结论：**A｜语义归位、不改名**（用户意见：以注释为主即可）。
  - **选中**：`ownerOf(当前会话)` 派生，不落盘；owner 列表高亮两种 kind 用同一句。
  - **默认助手**：`currentAssistantId` 就是它——40 余处读点全都在问「新 1:1 / 未绑定会话的
    fallback」。由已提交会话的归属派生（`syncDefaultAssistant`），幂等；群不写，
    因为群不能当任何 fallback。
  - 名字保留（`currentAssistantId`），契约写进 doc 注释 + 一条守卫测试
    （打开群话题后该字段不变，高亮落在群上）。
- 被否掉的：改名 `defaultAssistantId`——40 余处读点集中在 `side_drawer.dart`(12) 与
  `home_page.dart`(5)，正是 rebase 热区；语义已兑现，改名买的是可读性，另开一次机械提交。

## 轮 3｜「自动切换话题」保留，两种桌面布局都生效

- 选项：A 保留设置、左/右布局都真的生效；B 删掉设置、点 owner 一律切到它的列表。
- 结论：**A**。
  - 开：左布局切 tab（侧栏收着先展开）、右布局打开面板并停在「话题」页；点助手与点群一致。
  - 关：逐格与今天相同（左布局不动、右布局不动）。
  - 移动端：设置不出现，点 owner 只关抽屉。
- 理由：默认是关的，删设置等于对多数用户改行为，且与目标书 §4「开关关闭时行为逐格相同」正面冲突；
  删文案还要动 13 个语言的 ARB 与 settings 搜索索引。
- 被否掉的：右布局隐藏该设置（F5 会变成「永远不切」，与矩阵「可见视图：按设置」矛盾）；删除设置。

## 轮 4｜开关开时一律新建（按字面，含重复点同一位助手）

- 选项：A 点哪个助手都开它一张新会话（连点复用同一个空草稿）；B 只在换到另一位助手时才新建。
- 结论：**A**。矩阵 A 行固定读作「新」，测试断言「打开的会话 ≠ 该助手最近的会话」。
- 理由：修复只借「落在群里」这一个错，不顺手改开关开着时的其余行为；
  开关英文名 `New chat when switching assistants`，但**今天**的行为就是一律新建，回归面越窄越好。
- 后果：B 提到的「开关开时 A→A 会变成回到最近会话」这一行为变更不做；
  若之后要做，它是一次独立的产品决定。

## 轮 5｜门禁按层拆三张表（+ 3 条 smoke）

- 选项：A 一张 36 格全 widget 层；B 按层拆。
- 结论：**B**。
  - T1 controller（`openOwner`）：12 格 = 矩阵 6 行 × 开关两态，断言打开的会话归属。
  - T2 纯函数（`ownerOf` + 列表过滤）：4 格，断言列表口径与死群。
  - T3 widget（reveal）：6 格 = 三布局 × 开关两态。
  - T4 widget smoke：每布局一条，堵 T1 与 T2/T3 之间的组合缝。
  - 每条不变量一条注入记录；另加两条**永久守卫**：「＋」与「点 owner」对照；
    群话题打开时 `currentAssistantId` 不变而高亮在群上。
- 理由：24 格只差一个布尔，却在 widget 层重复付全套启动成本；且守卫证明要能指名哪条规则被破坏。
- 陷阱：`DesktopSidebarTabBus.instance` 与 `DesktopSidePanelController.instance` 是进程级状态，
  T3/T4 必须 `addTearDown` 重置，否则读到上一条的 tab 索引。

## 轮 6｜本轮登记为 rebase unit，并注明取代 #1069

- 选项：A 只补历史（unit 表补 #1069，本轮不登记）；B 连自己一起登记。
- 结论：**B**。
  - `docs/rebase-v1.3.6.md:140` 补 `#1069`；新增一行本轮 unit，成员写「#1092，
    取代 #1069 的 side_drawer / home_page_controller / 群背景三段」，sha 在提交后回填。
  - `docs/rebase-runbook.md:818` family 表：`#1069 group exit` → `#1092 owner switch（取代 …）`。
  - CHANGELOG 新条目写明是取代关系，不是「重新落地 #1069」。
- 理由：runbook 与 unit 表是下一次 rebase 唯一的输入；留着「重放 #1069」这一行，
  下次就会去重放一份与本轮文件重叠、且方向已被取代的补丁。

## 落地

实现计划：`docs/design/group-chat-switch/implementation-plan.md`（逐文件改动、7 步顺序、
T1–T4 门禁、5 条守卫注入、文档收尾）。守卫记录：`rounds/guard-injections.md`。

## 追加轮（第一次真机点验之后）｜开关对两种 owner 都生效

- 触发：真机闸门 `dirty:8f754bd94736` 判 fail，记录两条观察。
- 结论：**B｜开着开关点群也开该群的新话题**（用户意见：不动 l10n，标题照旧叫「助手」）。
  - 实现：`openOwner` 不再按 kind 分叉；`newChatOnAssistantSwitch` 对两种 owner 生效；
    群的新话题走 `createNewConversationAnimated(owner:)` + `reuseNewEntry`（连点不堆空话题）。
  - 文案：**不改**。标题保留原文，「助手」在这个开关里读作「对话对象」。
  - 矩阵 D 行随之固定：开 → 该群新话题；关 → 该群最近话题。
- 第二条（切到群时话题 tab 先闪一下上一个助手的列表）是**时序缺陷**，不是语义：
  reveal 改成 post-frame 回调，等新列表那一帧画完再切 tab。用 `addPostFrameCallback`
  而不是 `await endOfFrame`——后者会让 `openOwner` 在测试里等一个永远不来的帧。
- 被否掉的：A 只管助手（与「两种 owner 同一套规则」相悖，且用户明确期待新话题）。

## 追加轮之二（第二次真机点验之后）｜「正在生成」的点属于 owner，不属于选中的助手

- 触发：第二次闸门（`dirty:9e26cfe51390`）判 **pass**，只留一条观察：从**正在生成**的群聊切到
  闲置助手时，那个「正在生成」的点跑到助手行上。
- 根因：`loadingAssistantIds` 用 `resolveConversationAssistant(conversation.assistantId)`，群话题的
  `assistantId` 为 null → 解析成**当时选中的助手**。这与 I4 是同一类错误：另一个来源。
- 修法：指示器改为按 `ownerOfChat` 算出 owner key（助手与群都算），助手行与群行各自读取；
  群行的 `_AssistantInlineTile` 补上 `loading:`（此前群行根本没有这个参数，所以永远不显示）。
- 守卫：`owner_tap_wiring_test` › a generating group topic puts the dot on its group row
  （群话题在生成时只有群行亮，助手行不亮，默认助手没有被改写）。

## 评审轮（PR #1094）｜两条非阻断意见的处理

评审给出两条 Sev 2 / Occ 3，都没有阻断。逐条处理：

1. **删掉打开的群话题后跳到了助手的 1:1 —— 采纳并修了。**
   `_nextRecentConversationExcluding` 仍用 `c.assistantId == currentAssistantId` 选「下一个会话」。
   群话题的 `assistantId` 恒为 null，所以同群的其他话题永远不是候选，删除后用户被甩出群。
   这正是本轮在清掉的「同一决定第二份实现」，只是它在本轮改写的文件里留了下来（评审指出该行是
   既有代码，但正是本轮把它的前提判成了假）。
   - 修法：新增纯函数 `nextConversationAfterDelete`（scope = 当前会话的归属，排除被删的 id，
     没有打开的会话时沿用列表的兜底口径），抽屉与移动菜单的两处副本都改走它。
   - 守卫：注入第 6 条（scope 改回默认助手）→ `deleting the open group topic picks another
     topic of it` 红 → 哈希还原。
2. **开关现在也管群，而文案只说助手 —— 维持原决定，不改文案。**
   这是追加轮里你明确定的（「不用改 l10n，就直接叫助手就行了」）。评审的意见我记录在这里，
   并承认它的代价：开关打开时，群行不再表示「打开该群最近的话题」，而用户没有任何文案提示。
   若要给提示，唯一零 UI 成本的做法是改 `@displaySettingsPageNewChatOnAssistantSwitchTitle`
   的 ARB `description`（翻译者/维护者可见，应用内不显示）。它仍然是一次 ARB 改动，
   按你的口径**没有做**；需要时一行就能加。

## 评审轮之二（第二次评审）｜窄窗口的覆盖层

评审只给出一条 Sev 3 / Occ 4，但它是我引入的真回归：

- **现象**：桌面窗口窄于 `AppBreakpoints.tablet`（900px）时，侧栏是覆盖层（`AnimatedPositioned`
  + `ModalBarrier`），不是路由。点 owner 后聊天区切换了，覆盖层还盖着，要再点一次遮罩。
- **成因**：那条关闭动作原本在页面的 `onSelectConversation` / `onNewConversation` 里；本轮把
  owner 点击直接接到 `openOwner`，`maybePop()` 对覆盖层无效（首页是第一个路由，
  `RoutePopDisposition.bubble`，什么都不做）。
- **修法**：把 `closeCompactSidebar()` 放进 `openOwner` 本身（不在页面包一层 tear-off）——
  于是它是管道的一步，任何新入口都自带；内部 guard 让它在手机、平板、宽窗口上都是空操作。
- **连带**：`revealTopics` 在窄窗口不再为了「显示话题」而*重新打开*覆盖层（那会盖住刚打开的
  聊天）；tab 仍然切到话题，下次打开覆盖层时就在话题页。这条与旧行为一致（旧代码也是切 tab
  后由回调关掉覆盖层）。
- 守卫：注入 7 / 8 两条，各自让对应测试变红，哈希还原（`rounds/guard-injections.md`）。

### 评审留作「待确认」的两条，我的结论

1. **`isGroupConversation` 与死群话题**：它的定义是「有 groupChatId」，不是「群还活着」；有若干
   调用点（`model_select_sheet`、`home_view_model` 的群回合判定、`chat_service`）因此把死群话题
   仍当群会话处理。这与 I1（死群话题按普通会话归属）在**行为**层面不完全一致，但它属于
   「模型选择 / 重放」那一轴，不是本轮的归属轴，且改动面会跨出本轮范围。记在这里作为后续事项，
   不在本 PR 里顺手改。
2. **`_syncDefaultAssistant` 是切换后唯一写入者**：这是第 2b 轮定的——选中由已提交会话派生，
   点击时不写。评审确认的「切换前写」正是被删掉的那条平行决定。

## 评审轮之三（第三次评审）｜三条非阻断，全部是回归

| # | 现象 | 处理 |
| --- | --- | --- |
| 1 | 手机抽屉要等整个切换（≳360ms）才关，切换抛异常时干脆不关 | 改成**先关再切**：`maybePop()` 放在 `await` 之前 |
| 2 | 桌面头部头像的「显示话题」被 `desktopAutoSwitchTopics` 挡住了，默认设置下点了没反应 | 拆分：`revealTopics()` 是机制（头像、热键、允许时的点击），`_revealAfterOwnerTap()` 才读设置 |
| 3 | 生成中的群话题在手机抽屉里画两个点（头部 + 会话行） | 头部只在「列表口径就是它名字里的那个助手」时才画点 |

第 2 条是我把两条不同意图塞进一个函数的后果：头像/热键的意思是「把列表给我看」，与「切换后
自动回到话题列表」这个设置无关。拆分后 `revealTopics()` 与 4.6.0 的 `_revealAssistantTopics`
行为一致（含窄窗口打开覆盖层），而设置只约束 owner 点击那一步。

第 1 条同时修掉了「切换失败时抽屉不关」：关闭发生在切换之前，与切换成败无关。

第 3 条的前提是我上一轮把点修到了群行上——修对了行，却让头部继续按 `listScope` 画，于是同一次
生成被报了两次。头部的语义是「名字里的这个助手在生成」，所以只在该助手就是当前会话的 owner
时才亮。

**收窄的一条**：最初我把头部条件写成「只有 owner 就是头部那个助手时才亮」，结果撞掉了既有测试
`mobile assistant indicators update on $platform`——它钉的是「头部跟随列表 owner」这一**既有**
语义（评审也说明头部归属问题早于本 PR）。所以最终只加了 `!listScope.isGroup`：群的活动只在群行
显示，助手场景保持原样，既有测试不用改。
