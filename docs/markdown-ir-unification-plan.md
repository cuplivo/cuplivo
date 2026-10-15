# Markdown IR 统一工程：剩余工作计划

**性质**：ADR-0008 的配套工作文档（ADR 记决策，本文件记「还差什么、怎么做、做到哪一步」）。
**暂停时间**：Phase B 开工前，设计已定、代码未动。
**分支**：`refactor/markdown-ir`（worktree `cuplivo-refactor-markdown-ir`）。

---

## 1. 已完成并已提交

| commit | 内容 | 验证 |
| --- | --- | --- |
| `9637d49a5` | IR 基础：`markdown_ir.dart`（节点树/叶子表/重发射器）、组件 `node()`、`walkNodes`/`walkDocument`、漂移测试 | markdown 集 412 绿；`dart analyze --fatal-infos lib test integration_test` 零问题；`dart format` 零变更 |
| `0f543dfc3` | ADR-0008：终态架构、四期路线、门槛、bench 基线 | 文档 |
| `c27fc9c6a` | **Phase A**：`generate`/`walkNodes` 合并为一个 `_walk` + 两个 sink；`walkNodes` 新增 `onNode`（并转发进组件的 content walk）；包内 analyzer 归零 | markdown 集 **413** 绿；包/app analyze 零问题；bench 交错配对无方向性差异 |
| `4263cfbb6` | **Phase B**：`MdSpanEmitter` + `InlineMd.span` 默认发射；包内 7 个行内 span 覆写删除；`AtxHeadingMd` 走节点；`ModernBlockQuote` 用共享 quote 规则；表行切分去重；inline 表格换 app 组件；删两个不可达组件；覆盖注册测试 + 12 个新 fixture（收口提交补齐三个共享助手，见 §3.8） | 包内自带测试 144 绿、markdown 集 352 绿、包/app analyze 零问题、format 零变更；全量 `flutter test` 8238 通过、8 失败且全部落在 `.toolbridge/known-failures.json` 台账内（toolbridge 判定 **8 known / 0 new**）；两处注入验证落地（见 §3.8） |
| `70e203dd7` | **Phase C**：7 个流式 fixture（未闭 fence、已闭 fence、未闭强调、未闭 `$`/`$$` 公式、段落+未闭 fence、纯段落）+ 每个流式 fixture 的「`MarkdownBlockList` 已生效」断言；新微基准 `test/perf/inline_walk_bench.dart`（泵外直调 walk、报逐次中位数、可按形状/尺寸/运行标签筛选）；3 对交错 A/B + 快路径 print 探针 → 条件项**不触发**，无生产代码变更；ADR-0008 补记三处 | drift 用例 28→35 绿；markdown 集 417 绿（14 个文件）；包/app analyze 零问题；format 零变更；全量 `flutter test` 8245 通过 / 8 失败且全部落在台账内（0 new）；两处注入验证（流式旗标 → 红；删 part 文件 → 编译失败，均字节还原）；A/B 每次翻转后工作树与 HEAD blob 逐字节一致 |

| `751c82289`..`6f0557935` | **Phase D**（6 提交）：切分器纯改名 → walk 派生边界（54 金标零重定基）→ 实测两个缺陷修复（run 增长、每帧重走整区）→ 删 fence parser/spanBuilder（净 −188）→ details 偏移量键 + registry 提级。§5.5 掩码判定与 §5.4 键设计见 §5 | 切分器 59 金标、markdown 集 348 绿；两处 analyze 零问题；format 零变更；新 bench `test/perf/split_cost_bench.dart`；注入证明四组（`$` 掩码、键回退、守卫、run 增长金标），新 parity 测试首跑即抓到缓存键 bug |

Phase A 交付物要点（后续阶段直接依赖）：

- `MarkdownComponent._walk<R>(String text, List<R> out, _MdWalkSink<R> sink, {config, includeGlobal, source, start})` —— 唯一遍历，拥有语法（`exp` 模式、组件集、pattern 缓存、递归位置）与偏移。
- `_MdSpanSink`（渲染：`component.span(...)` + `onSpan`）／`_MdNodeSink`（IR：`component.node(ctx, ...)` + `onNode`）。
- `typedef MdNodeCallback = void Function(MdNode, int start, int end, MarkdownComponent, bool block)`。
- `MdNodeContext.onNode` 字段：`ctx.walk(...)` 会转发回调 → 嵌套在列表项/引用/details 体里的元素也能被 `onNode` 看到（**注册测试的前提**）。
- 偏移语义：每次 walk 的偏移是「该次 walk 所寻址的 source」内的绝对偏移；组件 content walk 的 source 是它自己重导出的内容串（测试已固化）。

**未完成**：无（Phase D 已完成，见 §5.3；剩余只有 §6 的收尾）。

---

## 2. 关键事实与修正（勿再踩）

1. **`generate()` 不删除、仍是渲染入口**。终态不是「删除 generate」，而是「每次遍历只有一份、显示文本只由 `node()` 决定」：`component.span()` 保留为组件（尤其 app 组件）的渲染入口，只是其内容改为从节点发射。
2. **`markdown_line_lexer.dart` 不能整文件删**。`MarkdownLineLexer` 另有非渲染消费者：`assistant_paragraph_splitter.dart`（TTS 分段）、`timeline_visibility.dart`、`diagram_exporter.dart`、details 提取。D 期只删「流式块切分路径上的语法镜像」。
3. **C 期很薄**。`MdWidget` 的 `_plainAppendable`/`_prose`/`_spanGroups` 是输出端保留机制（保留 span 身份），不与 IR 竞争；A+B 之后渲染管线已是 walk→node→emit。用户原话是条件式「如果快路径那也可以有对应的 IR 处理变体」——C 期已按证据判定不需要变体（§4.2），且原计划里那个消解目标（「node 为默认内容叶的组件」）在活跃组件集中为空。
4. **bench 无法支撑 ±5% 门槛**。同一 commit 连续两次运行，单形状差异可达 ±40%（`single`/`lines` 最差，曾出现 +116%/−11% 同形状不同尺寸）。**只能用「交错配对运行」比较两个版本**（A/B/A/B 相邻运行），且只认「跨形状一致的方向」。ADR-0008 已记录该结论与 Phase A 实测（比值 0.81–1.44，中位 +3%）。C 期新增的 `test/perf/inline_walk_bench.dart` 把噪声压到 ±5–16%（同版本两次全扫 0.84–1.14），并且自带漂移对照（`walkNodes` 两版本代码相同）——后续要判「解析路径」的改动优先用它，`long_streaming_bench` 只用来判整帧追加成本。
5. **包内 `this.exp` 已经清理**（7 处），`markdown_ir.dart` 的 `MdSelection.index` 已私有化 → `dart analyze dependencies/gpt_markdown` 现在零问题，可作为后续每期门槛。
6. **math 默认开启**（`enableMathRendering = true`、`enableDollarLatex = true`），所以活跃组件集**包含** `LatexBlockScrollableMd` + `InlineLatexDollarScrollableMd` + `InlineLatexParenScrollableMd`；注册测试需要它们的 fixture。
7. `MdNode.kind` 的 `gap` 语义是「**不贡献被复制文本**」，不是「不渲染」——`ImageMd`、行内公式、fenced code 都是 gap 但都画东西。这是 B 期发射器回退策略的根据。

---

## 3. Phase B（已完成）：组件从节点发射

### 3.1 目标与判据

- 活跃组件里**不存在「span/build 自己再解析一遍内文」**的组件；显示文本只在 `node()` 或 node/span 共享的助手函数里决定。
- 漂移测试扩到每个倒置组件；新增**组件覆盖注册测试**（非空洞守卫）。
- 删除不可达组件；包内表行切分去重。
- 门槛：包 analyze 零问题、app analyze 零问题、`dart format` 零变更、markdown 集 + 全量 `flutter test` 绿、bench 交错配对无一致性回退。

### 3.2 发射器 `MdSpanEmitter`（新文件）

`dependencies/gpt_markdown/lib/md_span_emitter.dart`，`part of 'gpt_markdown.dart';`（并在 `gpt_markdown.dart` 的 `part` 列表登记）。

```dart
final class MdSpanEmitter {
  MdSpanEmitter(this.context, this.config);
  final BuildContext context;
  final GptMarkdownConfig config;

  /// 展平渲染（group 递归展开）。
  List<InlineSpan> emit(List<MdNode> nodes);
  /// 单节点渲染（group 包成 TextSpan(children: ...)）。
  InlineSpan emitNode(MdNode node);
}
```

**自行处理的 kind**：`text`、`decoration`、`group`、`bold`、`italic`、`strike`、`underline`、`inlineCode`(=HighlightedText，含 `config.highlightBuilder` 分支与默认 Paint 背景/粗体)、`link`、`image`。

**回退规则（关键设计，防止丢 widget）**：其余 kind 一律回退为
`MarkdownComponent.generate(context, node.range!.text, config, false)`。

理由：app 侧的 widget 类行内组件（两个行内公式、`HtmlAnchorMd`、`AllowedHtmlTagsMd`、`BackslashEscapeMd`、包 `LatexMath`、`SourceTag`）渲染依赖 app 私有助手或 `latexBuilder`，发射器不该、也无法复制；它们**不被倒置**，所以「回退 → 重新派发到组件 → 组件自己的 span」是正确且不会递归的。
**不变量（写进注释）**：凡是被倒置的组件，其 `node().kind` 必须由发射器直接处理；否则 `span = emit(node)` 与回退中的 `generate` 会互相调用成环。倒置集 = {bold, italic, strike, underline, inlineCode, link, image}，全部被直接处理 ✓。

**样式流动**：强调类通过「新建带样式的 config 的子发射器」实现，与今天的 `config.copyWith(style: ...)` + `generate(inner, conf, false)` 等价：

```dart
InlineSpan _styled(MdNode node, TextStyle? style) {
  final conf = config.copyWith(style: style);
  return TextSpan(style: conf.style, children: MdSpanEmitter(context, conf).emit(node.children));
}
```

（叶节点渲染为 `TextSpan(text: range.text, style: config.style)`，与今天 `generate` 的 `TextSpan(text: p0, style: config.style)` 同构。）

**link 的 url 来源**：对 `node.range!.text`（正好是 `[label](url)`）调用已有的共享助手 `_parseLinkElement`，不新增 `MdNode` 字段、不做 marker 字符串手术。label 子节点用带 link 样式的子发射器渲染，`ending` 作为 group 的兄弟节点自然展平（顺序不变）。

**image**：把 `ImageMd.span` 里那段「正则 + 括号配对扫描 + alt 尺寸解析」抽成包内共享 `_parseImageElement(String)`（同时消掉「span 另有一套扫描」的重复），`ImageMd.span` 与发射器都用它；widget 组装（`config.imageBuilder ?? SizedBox+Image`，含 `CustomImageLoading`/`CustomImageError`）与今天逐字一致。

### 3.3 倒置清单

包内（`markdown_component.dart`）：
- `BoldMd`、`ItalicMd`、`StrikeMd`、`UnderLineMd`、`HighlightedText`：`span()` = `node()` + 发射器；解析只剩 `node()` 一处。
  - 新增样式钩子 `FontWeight get emphasisWeight => FontWeight.bold;`（app 覆写）。
  - 保持今日口径：`text.trim()` 匹配、Italic 的 `group(1) ?? group(2)`、Highlighted 的 `highlightBuilder(context, inner, config.style ?? const TextStyle())` 与默认 Paint 背景（`strokeCap: round`、`strokeJoin: round`、`GptMarkdownTheme.of(context).highlightColor`）。
- `ATagMd`：`span()` = `node()` + 发射器（label 子节点 + ending 兄弟 + `linkBuilder`/`LinkButton`）。
- `ImageMd`：`span()` = `node()` + 发射器（kind=image）。

app 内（`lib/shared/widgets/markdown_with_highlight.dart`）：
- `EscapeAwareBoldMd` → 只留 `exp` + `emphasisWeight => AppFontWeights.strong`（删掉整个 `span`）。
- `EscapeAwareItalicMd`、`EscapeAwareHighlightedTextMd`、`EscapeAwareImageMd`、`LineSafeLinkMd` → 只留 `exp`（删掉多余覆写）。

块内联内容：
- `AtxHeadingMd.build`：改为 `MdSpanEmitter(context, innerCfg).emit(node(...).children)`（`innerCfg = config.copyWith(style: TextStyle())`，与今天 `generate(raw, innerCfg, true)` 的样式口径一致）。
- `ModernBlockQuote.span`：去 `>` 循环改用共享 `markdownQuoteText()`（消掉与 `node()` 的重复实现）。
- **不动**：list/quote/details/check/radio/indent/hr/fence/table/各 math 组件仍通过同一组件集整体委派（`MdWidget`/`GptMarkdown`），其 `node()` 走同一规则、由漂移测试守护。理由见 ADR-0008 决策 3。

### 3.4 顺带修一处真实漂移

`markdownComponentsFor` 目前只把 **global** 列表里的 `TableMd` 换成 `EscapeAwareTableMd`，inline 列表仍留包内 `TableMd`。而 app 的表格渲染统一走 `tableBuilder`（自带选区，外层复制为空），包内 `TableMd.node` 却声明「单元格文本是显示文本」——嵌套在强调里的表格会产生漂移（如 `**| a | b |\n| - | - |**`）。
**修法**：inline 列表也替换为 `EscapeAwareTableMd`（`exp` 继承不变，仅 `build`/`node` 不同）。

### 3.5 去重与删除

- 包内 `TableMd.build` 与 `TableMd.node` 的行/格切分重复 → 抽 `List<List<String>> _markdownTableRows(String text)`（`build` 里 `asMap()`）。
- 删除不可达组件：`SetextHeadingMd`、`LabelValueLineMd`（仅 `// components.insert(0, LabelValueLineMd());` 一处注释引用，无注册点），连同那条注释。
- 注意：app `EscapeAwareTableMd` 用的是 escape-aware 的 `_splitMarkdownTableLine`，与包内规则不同，**不要**合并。

### 3.6 覆盖注册测试（非空洞守卫）

把 `test/shared/widgets/markdown_ir_drift_test.dart` 的 15 个 fixture 源重构成一个 `const` 列表（记录 `name/source/expand/tracksExpansion`），循环生成 `testWidgets`（保持用例名不变），外加「collapsed again」那条独立用例；然后新增用例：

```
walk 每个 fixture 源（用 markdownComponentsFor(...) 的组件集 + DetailsHtmlMd）并收集 onNode 报出的组件 runtimeType 集合；
断言 活跃组件集 ⊆ 命中集（排除表显式为空）。
```

非空洞证明（按 DSH 规则 9）：临时删掉某个 fixture，注册测试必须变红；之后字节还原。

**需要新增的 fixture**（每个活跃组件至少一个）：
- `~~strike~~`（StrikeMd）、`<u>under</u>`（UnderLineMd）
- `cite [1] here`（SourceTag）
- `<a href="https://example.com">site</a>`（HtmlAnchorMd）
- `line<br>break`（AllowedHtmlTagsMd）
- `\*not emphasis\*`（BackslashEscapeMd）
- `(x) selected`（ModernRadioMd）
- `- item\n\n  continued`（IndentMd，同时覆盖缩进并回）
- `value $x$ here`（InlineLatexDollarScrollableMd）、`the \(x^2\) value`（InlineLatexParenScrollableMd）、`$$\nx\n$$`（LatexBlockScrollableMd）
- `**| a | b |\n| - | - |**`（嵌套表格路径；3.4 修完后两侧显示空间都为空）
- 已有 fixture 已覆盖：EscapeAwareBoldMd、EscapeAwareItalicMd、EscapeAwareHighlightedTextMd、LineSafeLinkMd、EscapeAwareImageMd、AtxHeadingMd、ModernBlockQuote、ModernCheckBoxMd、SoftHrLine、FencedCodeBlockMd、DetailsHtmlMd、UnOrderedList、OrderedList、NewLines、EscapeAwareTableMd。

### 3.7 Phase B 执行顺序

1. `md_span_emitter.dart` + `part` 登记 + `_parseImageElement` 抽取。
2. 包内行内族倒置（Bold/Italic/Strike/UnderLine/Highlighted/ATag/Image）+ `emphasisWeight`。
3. app 侧收缩 EscapeAware*/LineSafeLink。
4. `AtxHeadingMd.build` 走节点；`ModernBlockQuote.span` 用 `markdownQuoteText`。
5. `TableMd` 行切分去重；`markdownComponentsFor` 的 inline 表格替换；删除 `SetextHeadingMd`/`LabelValueLineMd`。
6. 漂移 fixture 重构 + 新增 fixture + 注册测试（含非空洞注入验证）。
7. 三闸 + bench 交错配对 → 提交（commit message 记录证据）。

### 3.8 落地结果（本提交，含与 3.2/3.3 的差异）

- **回退规则**按 §3.2 实现：发射器不处理的 kind 一律 `generate(元素源, config, includeGlobal)`；
  `includeGlobal` 是发射器实例的属性（行内组件默认 false，`AtxHeadingMd` 传 true），只影响回退时用哪套组件集。
  发射器还直接处理 `image`（gap 叶子）与 `decoration`（列表项/序号这类「显示但不来自源」的文本）。
  叶子判定：`link` 只有 `_parseLinkElement` 认得出来才自己画，否则交回组件（`HtmlAnchorMd` 也声明 `link` kind）。
- **差异 1（比设计更彻底）**：不是逐组件删 `span`，而是把「`span()` = `nodeOfElement()` + 发射器」写进
  `InlineMd` 的默认实现，包内 7 个类的 `span` 覆写整体删除。`InlineMd.span` 的注释写明不变量：
  node 不被发射器描述的组件必须自带 `span`，否则回退会成环。
- **差异 2**：强调字重不在构造发射器时传入，而是 `BoldMd.emphasisWeight` + 发射器从 `config.inlineComponents`
  里找 `BoldMd` 取——「这个表面用什么笔迹画强调」本来就由组件集声明。嵌套在斜体里的粗体因此同样拿到
  `AppFontWeights.strong`（新增 Android 专测 + 注入验证）。
- **差异 3**：app 侧 `EscapeAwareItalicMd`/`EscapeAwareHighlightedTextMd`/`EscapeAwareImageMd`/`LineSafeLinkMd`
  本来就只覆写 `exp`（无需改动）；只有 `EscapeAwareBoldMd` 删掉了 `span`，改为 `exp` + `emphasisWeight`。
- `markdownQuoteText` 的逐行判定放宽为 `[ \t]*>`：app 的 `span` 原本接受 tab、`node` 不接受，本身就是一处漂移。
- fixture 实际为 26 个源（原 14 + 新 12），drift 文件用例数 16 → 28（C 期再增 7 个流式源 → 33 源 / 35 用例，
  见 §4.3；§3.6 的「15 个源」是计划期的估算，实际原文件为 14 个）；覆盖注册测试的排除列表为空。
- **收口提交**：三个**仍自带 span**（即发射器回退目标）的组件把显示规则抽成类内共享助手，span 与 node 各调一次——
  `SourceTag._contentOf`、`AllowedHtmlTagsMd._displayOf`、`BackslashEscapeMd._escapedOf`。行为逐字不变
  （`_escapedOf` 复现的两个兜底分支本来就是 span 与 node 一致的），`_displayOf` 的合并正则与原先分开写的两个判定等价。
  至此 §3.1 第二句（显示文本只在 `node()` 或 node/span 共享助手里决定）**字面成立**。
- 门槛：包内自带测试 144 绿、markdown 集 352 绿、包/app `analyze --fatal-infos` 零问题、`dart format` 零变更。
  bench（顺序 B A B A B B）三组 after÷before 比值 0.76–1.39、中位 1.01/1.09/1.05；**同一版本**相邻两次
  比值 0.66–1.80、中位 1.06 —— 噪声包住了信号，无一致方向。唯一一致偏高的形状是 `single`（+14–29%），
  留给 §4 第 3 步判定。

---

## 4. Phase C（薄期）：流式路径（已完成）

### 4.1 计划条目（含执行中的修正）

1. **流式 fixture**：`streaming: true` 下的未闭合构造，断言 `normalizeDisplayText(copied) == displayText`。
   实际 7 个：未闭 fence、已闭 fence（钉住流式模式下 fence 仍是 gap）、未闭强调、未闭 `$` 行内公式、
   未闭 `$$` 显示公式、段落+未闭 fence、纯段落。每个流式 fixture 另断言 `MarkdownBlockList` 命中——
   旗标确实生效，否则「等式成立」可能只是静态路径又渲染了一遍。
2. **bench 复核**：见 4.2。
3. **条件项（叶快路径 IR 变体）——原计划与修正**：原写「在 `_walk` 的 render sink 里对『node 为默认
   内容叶的组件』直接产 `TextSpan(text: element)`」。执行时逐类核对后**该集合在活跃组件里为空**：七个被
   倒置的行内组件全部覆写 `node`，而唯一用默认 `node` 的 `NewLines` 自带 `span`（渲染时不物化节点）。
   B 期真正的每元素成本在 `InlineMd.span` 默认实现内：`MdNodeContext`/`MdNode`/`MdRange` 分配、
   每次构造 `MdSpanEmitter`、以及 `_emphasisWeightOf` 对组件集的逐元素扫描。故条件项重划为
   **3a** 字重查询缓存（机械、保 B 期不变式）／**3b** 节点消解（必须在 `span` 里重新解析，等于局部
   回滚 B 期「解析只此一处」，属架构取舍，需单独立项并经确认）。
4. `MdWidget` 的 `_prose` 提交逻辑（`component is ItalicMd` 前瞻）**不动**：组件身份仍经 `onSpan` 传递。
5. ADR-0008 补记：保留机制留在 span 层是设计选择（节点是遍历瞬态产物，保留关心输出身份）。

### 4.2 bench 与条件项判决（不触发）

新仪器 `test/perf/inline_walk_bench.dart`：pump 一次取 `BuildContext`，之后**进程内循环**调
`MarkdownComponent.generate`（旁挂 `walkNodes` 作节点侧参照），报**逐次调用的中位数**；`--dart-define`
可筛形状/尺寸/运行标签，便于定点 A/B。它只引用 `generate`/`walkNodes`/`markdownComponentsFor`，因此两代
代码都能编译（A/B 期间 bench 文件本身不参与翻转）。

- **同版本抖动**：两次全扫（3 形状 × 2 方法 × 2 尺寸）比值 0.84–1.08 —— 比 widget bench 的 ±40% 好一个量级，
  但仍是进程级漂移，不是采样不足（改用中位数后仍在）。
- **交错 A/B**（3 对，1000 元素，after÷before）：`emphasis` 0.92 / 1.07 / 1.10，`mixed` 1.04 / 1.10 / 1.10，
  `plain` 对照 1.02 / 0.95 / 0.97。两版本**代码完全相同**的 `walkNodes` 在同形状上跨 0.84–1.14 ——
  未改动路径复现了同量级漂移，方向不可辨。中位数×3 在带行内元素的两个形状上偏高 7–8%，落在控制组噪声内。
- **量级论证**：同一次运行内，1000 元素强调源的整体 inline walk ≈32–35 ms，1000 句纯文本（字数翻倍、零元素）
  ≈14–20 ms → 每句多 17–21 µs，除以两个元素、再按纯文本形状的每字符成本给强调句自己的文本计费 →
  单元素「匹配+递归+节点+发射」全链路 ≈10–14 µs；而 widget bench 在 `single` 上测的追加帧是 3.3–6.4 ms。
  B 期只在这 10–14 µs 之上加了节点对象。
- **机制实测**：`single` 的追加后缀 `'新增输出。'` 不含 `MdWidget._markdownDelimiter` 字符 → 走
  `_plainAppendable` 快路径，**根本不进入 walk**。临时在 `_parse` 与快路径分支各插一行 print，对流式段落
  追加 3 次：初始帧 1 次 `_parse`、3 次 fastpath、之后无解析（探针与临时测试均删除，字节还原）。
- **判决**：**条件项不触发**——不做 3a/3b，Phase C 无生产代码变更，故也未重跑 `long_streaming_bench`
  （无运行时变更可测）。

### 4.3 落地结果

- drift 用例 **28 → 35**（fixture 26 → 33，新增 7 个流式源）；覆盖注册测试改为按每个 fixture 自己的
  `streaming` 旗标 walk（两套组件集只差 fence 组件的模式，但 walk 不该是丢弃该旗标的地方）。
- **非空洞证明**：把 `_copiedText` 传给 widget 的 `streaming` 硬编码为 `false` → 首个流式 fixture 变红
  （`MarkdownBlockList` 命中 0 个）；字节还原并校验 sha256（`2d9973ae…`）。
- **编译响应性证明**（A/B 前提）：删除 `md_span_emitter.dart` → `flutter test` 立即编译失败，证明无陈旧
  增量缓存；字节还原并校验 sha256（`3f5029d8…`）。
- **A/B 翻转机制**：只用 `git cat-file blob <rev>:<path>` 取字节写入（pre-B 侧删除当时不存在的
  `md_span_emitter.dart`），每次翻转后 `git status --short` 确认状态，结束后工作树与 HEAD blob 逐字节一致
  （仅剩本期的两个文件）。
- 门槛：见 §1 表。

### 4.4 明确不做

- 流式 `<details>` fixture（details 占位 + registry 键属 D 期 §5.4）。
- fence 内含 `<`/`$` 的 fixture（属 D 期 §5.5 决策门）。
- 3b 节点消解（架构取舍，未获证据支持且需单独确认）。

---

## 5. Phase D：块切分归入 IR（已完成）

### 5.1 计划条目与执行中的修正

1. **金标先行**：计划写「移植为新 API，先对旧实现跑绿」。实际做法更省事也更硬：D1 把模块**纯改名**
   （`incremental_markdown_document.dart` → `markdown_streaming_split.dart`，零行为变更），矩阵当场对
   旧实现绿；D2 再换实现。于是「54 条金标零重定基」成了等价性证明，而不是新测试通过了事。
2. **边界来自遍历**，三个否决与两条谓词（§5.2 原文）基本成立，但有两处必须修正：
   - 「pending 列表自动消解」**不成立**：`UnOrderedList`/`OrderedList` 的 exp 只 claim 单行（`[^\n]+`），
     松散列表项之间是真的间隙。列表并回谓词是主路径而非兜底（kind 优先，`_listMarker` 兜住 `+`、`1)`、
     任务框这类写不出的形态）。
   - 「details 深度跟踪自动消解」**只对闭合 details 成立**：`DetailsHtmlMd` 的 pattern 要求 `</details>`，
     未闭合的流式 details 在 walk 眼里就是普通文本，其内部空行是真间隙 → 保留 `MarkdownLineLexer` 的
     details 深度作否决（它本来就是 details 提取共用的 `MarkdownDetailsWalker`，不是语法镜像）。
3. **`swallowsSeparator` 没有删除，而是上移**：`---`/`$$` 以 `\s*$` 收尾会把 run 的一个换行吃进匹配，
   边界仍然存在、只是不插分隔符。计划里「间隙判定即得」的说法只对「节点是否吞掉整个 run」成立，而
   吞掉一个换行的那类要保留。块因此多一个 `swallowsSeparator` 字段，widget 的 `swallowsSeparator`/
   `_separatorCache`/`_swallowsTrailingBlankLine` 及其助手整体删除。
4. **§5.4 的键改成「绝对偏移 + 源文本」**，不用计划里写的「token 序号」。理由：序号要保证两侧分配顺序
   一致（widget 逐块、复制侧整源、嵌套 body 由渲染方触发），而偏移量键**与遍历顺序无关** —— 三处对同一个块
   mint 同一个 token。另：只加偏移不行（同位置被替换的块会继承旧状态，`replacing a tail resets` 会红），
   只加文本也不行（就是这个 bug 本身），两者合起来才对。
5. **§5.5 用注入判定**（不是论证）：关掉 `_preprocessFences` 的代码掩码后，fence 体内的 `$5` 以 `\(5\)`
   到达代码视图 ⇒ `$` 那一半**承重，保留**；单独关掉 `<` 标签那一半后 168 个用例全绿 ⇒ **未被证明必要**，
   保留但记录为未证明，不凭无证据删除。

### 5.2 bench 与判决（新仪器）

`test/perf/split_cost_bench.dart`（新）按形状与追加类型打印 **walk 次数**与每次追加的耗时中位数，可复现到
几个百分点；`long_streaming_bench` **不再作为本阶段门槛**：同版本重复就能差 20–30%（它的 `lines` 形状在
105KB 是 6.8ms、在 175KB 反而 5.9ms，线性成本不可能如此），只留作整帧粗看。

实测抓到两个金标看不见的缺陷，都已修（D2b）：

| 症状 | 修前 | 修后 |
| --- | --- | --- |
| run 被留在原地后又增长（列表等下一行）→ 提交的块文本尾随换行 | `- a\n\n\n\nnext` 得 `- a\n\n` | `- a`（`_nextRun` 回退到 run 首个换行，并重判该 run） |
| 守卫问「追加后缀是否含标点」= 英文散文每帧都成立 → 整区重走 | 175KB 上 67–110 ms/帧 | 改问区域：无 run 即无事可决 → **0.5 ms、0 walk** |
| 松散列表（run 未决时期留在区内） | 87–164 ms/帧 | **28 µs、0 walk**（文本层先答，仅提交/缩进豁免才 walk） |

一次性的成本留在台账：长段落后**首个**边界要 walk 一整区 —— 175KB 一帧 74–106 ms（之后区域变小）。

### 5.3 落地结果（提交与门槛）

| commit | 内容 |
| --- | --- |
| `751c82289` | D1 纯改名（金标先绿） |
| `c6fe90325` | D2 walk 派生边界；54 金标零重定基 + 4 条新金标 |
| `8cd894e89` | D2b 修 run 增长 bug；守卫改问区域 |
| `281f4eb0c` | D2b walk 惰性化（文本层先答）；新 bench |
| `17e8f419f` | D3 删 fence parser/spanBuilder/wholeFence（净 −188） |
| `6f0557935` | D4 details 偏移量键 + registry 提级 + 缓存有界 |

- 门槛：切分器 59 金标、markdown 集 **348** 用例、`dart analyze --fatal-infos` 两处零问题、`dart format`
  零变更；全量 `flutter test` 见 §6。本阶段净 **+905/−761**（含测试）。
- 注入证明（均字节还原并校 sha）：`$` 掩码 ⇒ 两条 fence 体守卫红；键改回 `parsed.source` ⇒ 漂移 fixture 红
  （widget 那条不红——块在自己的 state 里保存展开态，直到 state 重建才会读到共享键，已如实记录）；
  新增的 parity 测试**第一次运行就抓到真 bug**：重写缓存只按文本作键，同文本在不同偏移会返回第一个位置的
  token（正是 §5.4 要修的重复块情形），缓存键已含 base。
- 与计划的三处差异已写进 ADR-0008 的 D 条目（列表/details 否决、`swallowsSeparator` 上移、偏移量键）。

### 5.4 明确不做

- **不修 #544**（`D:\ComfyUI\` 代码跨度被吞）：#561 已把它与 ADR-0042 的「唯一代码识别引擎」一起
  合入**被归档的 3.x 线**（`cuplivo` 分支，Sep 13 归档），本基线按 ADR-0004 重写过、不含该引擎；
  实测该 bug 在本线仍在。窄修只需一行（闭符 lookbehind 去掉 `\`）+ 一处测试重定基，但它属于「另一条线的
  遗产」，等用户决定后再做。
- `<` 标签掩码半边的删除（无证据）。
- 3b 节点消解（架构取舍，需单独立项）。

---

## 6. 收尾（工程外）

- 全量 `flutter test`（含 perf bench 单独跑）与 CI 三闸。
- `feat/direct-select-text-v4` rebase 到本分支：删 `subsequenceMatch` 及其测试、ADR 0007→0008 重编号、`SelectionMarkdownMemory.takeCopyText()` 改走 `markdownDocument(...).emitSelectionMarkdown(...)`。
- 已知限制台账（ADR-0007/0008 已有）：同一气泡内重复文本解析到首次出现；HTML 标签组件 best-effort；quote 整体重发射。

---

## 7. 下一步动作（按序）

1. ~~Phase D（见 §5）~~ **已完成**（§5.3 的六个提交）。
2. 收尾（见 §6）：全量 `flutter test` 已有基线（8 个失败全部在 `.toolbridge/known-failures.json` 台账内，
   本 worktree 已放入该台账以便 toolbridge 自动分类）；`feat/direct-select-text-v4` rebase。
3. 待用户决定：本线上是否窄修 #544（一行 + 一处测试重定基，见 §5.4）。
