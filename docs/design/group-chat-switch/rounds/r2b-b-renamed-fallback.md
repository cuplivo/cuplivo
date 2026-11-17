# 第 2 轮·修正版 B｜把名字也改对：`defaultAssistantId` + 派生选中

> 与修正版 A 相同的语义，多做一件事：让代码里的名字不再说谎。
> 代价是一次面很宽、纯机械、且落在 rebase 热文件里的改名。

## 1. 语义：与 A 完全相同

- **选中** = `ownerOf(当前会话)`，两种 owner 同一句，不落盘。
- **默认助手** = 新 1:1 的 fallback，落盘，由已提交会话的归属派生（`syncDefaultAssistant`）。
- 群打开时什么都不写——群不能当任何 fallback。

## 2. 这次多做的一步：改名

```dart
// AssistantProvider
String? get defaultAssistantId => defaultAssistant?.id;
Assistant? get defaultAssistant { ... }        // 原 currentAssistant
Future<void> setDefaultAssistant(String id)    // 原 setCurrentAssistant
```

- 全仓 40 余处读点改叫 `defaultAssistantId` / `defaultAssistant`。
- `HomeViewModel._assistantSwitchFor` 改名 `syncDefaultAssistant`，与管道第 4 步同名同义。
- **持久化键 `current_assistant_id_v1` 不改**：那是已存的数据格式，改名等于迁移，
  目标书 §5 明确不做。
- 注释里的 `currentAssistantId` 一并改（`home_view_model.dart:1670` 一处注释解释了
  「它会被重写」，改名后这句话才读得通）。

## 3. 改名落在哪：这是决策的全部成本

| 文件 | 读点数 | rebase 冲突面 |
| --- | --- | --- |
| `side_drawer.dart` | 12 | 高（sidebar 是上游常改区） |
| `home_page.dart` | 5 | 高 |
| `home_view_model.dart` | 4 | 中 |
| `home_mobile_layout.dart` | 1 | 中 |
| `ensure_conversation.dart` | 1 | 低 |
| `assistant_provider.dart` | 6 | 低 |

编译器会兜住漏改（改了 getter 名，调用点不跟就是编译错误），所以**正确性风险低**；
风险在**冲突面**：每多改一行上游也动过的行，下一次 rebase 就多一处要手工合。

## 4. 收益

- 「群不写」在命名上自洽：一个叫 `default` 的字段，群不写是显然的；一个叫 `current` 的字段，
  群不写就要解释。
- 下一个入口的作者不会再拿 `currentAssistantId` 当选中用——今天 `side_drawer.dart:4111`
  就是这么用的（`selected: ap2.currentAssistantId == a.id && currentGroupId == null`）。
- I6「一套实现」在命名层也成立：一条规则一个名字。

## 5. 代价

- 一次纯机械改动的审查成本，且**与本次修复的正确性无关**。
- 上游若在 `side_drawer.dart` / `home_page.dart` 上做了同名区域的重构，冲突会集中在这次改名上，
  而不是集中在管道上——等于把「一次大 conflict」的风险从结构改动挪到了命名改动。
- 与「最简实现」的张力：语义已经由 A 兑现，B 买的是可读性。

## 6. 两者关系

A 是必须做的；B 是 A 之上的命名收尾。B 可以独立成一次提交（`refactor: name the fallback
assistant what it is`），不带任何行为变化，也可以并入本轮。选 B 意味着本轮一起做。
