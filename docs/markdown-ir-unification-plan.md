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
| `4263cfbb6` | **Phase B**：`MdSpanEmitter` + `InlineMd.span` 默认发射；包内 7 个行内 span 覆写删除；`AtxHeadingMd` 走节点；`ModernBlockQuote` 用共享 quote 规则；表行切分去重；inline 表格换 app 组件；删两个不可达组件；覆盖注册测试 + 13 个新 fixture（收口提交补齐三个共享助手，见 §3.8） | 包内自带测试 144 绿、markdown 集 352 绿、包/app analyze 零问题、format 零变更；全量 `flutter test` 8238 通过、8 失败且全部落在 `.toolbridge/known-failures.json` 台账内（toolbridge 判定 **8 known / 0 new**）；两处注入验证落地（见 §3.8） |

Phase A 交付物要点（后续阶段直接依赖）：

- `MarkdownComponent._walk<R>(String text, List<R> out, _MdWalkSink<R> sink, {config, includeGlobal, source, start})` —— 唯一遍历，拥有语法（`exp` 模式、组件集、pattern 缓存、递归位置）与偏移。
- `_MdSpanSink`（渲染：`component.span(...)` + `onSpan`）／`_MdNodeSink`（IR：`component.node(ctx, ...)` + `onNode`）。
- `typedef MdNodeCallback = void Function(MdNode, int start, int end, MarkdownComponent, bool block)`。
- `MdNodeContext.onNode` 字段：`ctx.walk(...)` 会转发回调 → 嵌套在列表项/引用/details 体里的元素也能被 `onNode` 看到（**注册测试的前提**）。
- 偏移语义：每次 walk 的偏移是「该次 walk 所寻址的 source」内的绝对偏移；组件 content walk 的 source 是它自己重导出的内容串（测试已固化）。

**未完成**：Phase C、Phase D（见 §4、§5）。

---

## 2. 关键事实与修正（勿再踩）

1. **`generate()` 不删除、仍是渲染入口**。终态不是「删除 generate」，而是「每次遍历只有一份、显示文本只由 `node()` 决定」：`component.span()` 保留为组件（尤其 app 组件）的渲染入口，只是其内容改为从节点发射。
2. **`markdown_line_lexer.dart` 不能整文件删**。`MarkdownLineLexer` 另有非渲染消费者：`assistant_paragraph_splitter.dart`（TTS 分段）、`timeline_visibility.dart`、`diagram_exporter.dart`、details 提取。D 期只删「流式块切分路径上的语法镜像」。
3. **C 期很薄**。`MdWidget` 的 `_plainAppendable`/`_prose`/`_spanGroups` 是输出端保留机制（保留 span 身份），不与 IR 竞争；A+B 之后渲染管线已是 walk→node→emit。用户原话是条件式「如果快路径那也可以有对应的 IR 处理变体」——按证据它不需要变体。
4. **bench 无法支撑 ±5% 门槛**。同一 commit 连续两次运行，单形状差异可达 ±40%（`single`/`lines` 最差，曾出现 +116%/−11% 同形状不同尺寸）。**只能用「交错配对运行」比较两个版本**（A/B/A/B 相邻运行），且只认「跨形状一致的方向」。ADR-0008 已记录该结论与 Phase A 实测（比值 0.81–1.44，中位 +3%）。
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
- fixture 实际为 27 个源（原 15 + 新 12），drift 文件用例数 16 → 29；覆盖注册测试的排除列表为空。
- **收口提交**：三个**仍自带 span**（即发射器回退目标）的组件把显示规则抽成类内共享助手，span 与 node 各调一次——
  `SourceTag._contentOf`、`AllowedHtmlTagsMd._displayOf`、`BackslashEscapeMd._escapedOf`。行为逐字不变
  （`_escapedOf` 复现的两个兜底分支本来就是 span 与 node 一致的），`_displayOf` 的合并正则与原先分开写的两个判定等价。
  至此 §3.1 第二句（显示文本只在 `node()` 或 node/span 共享助手里决定）**字面成立**。
- 门槛：包内自带测试 144 绿、markdown 集 352 绿、包/app `analyze --fatal-infos` 零问题、`dart format` 零变更。
  bench（顺序 B A B A B B）三组 after÷before 比值 0.76–1.39、中位 1.01/1.09/1.05；**同一版本**相邻两次
  比值 0.66–1.80、中位 1.06 —— 噪声包住了信号，无一致方向。唯一一致偏高的形状是 `single`（+14–29%），
  留给 §4 第 3 步判定。

---

## 4. Phase C（薄期）：流式路径

1. **流式 fixture**：`streaming: true` 组件集下的未闭合构造——未闭 fence（` ```dart\nfinal a = 1;`）、未闭强调（`**par`）、未闭行内公式——断言 `normalizeDisplayText(copied) == displayText`。
2. **bench 复核**：B 落地后的数字入 ADR；若不一致方向成立则进入第 3 步。
3. **条件项（叶快路径 IR 变体）**：只有 bench 显示分配回退时才做——在 `_walk` 的 render sink 里对「node 为默认内容叶的组件」直接产 `TextSpan(text: element)`，不物化 `MdNode`/`MdRange`。只改一处，不逐组件。
4. `MdWidget` 的 `_prose` 提交逻辑（`component is ItalicMd` 前瞻检查）**不动**：组件身份仍经 `onSpan` 传递。
5. ADR-0008 补记：保留机制留在 span 层是设计选择（节点是遍历瞬态产物，保留关心输出身份）。

---

## 5. Phase D：块切分归入 IR

### 5.1 现状与要删的东西

现在这套东西**镜像渲染器语法**：
- `IncrementalMarkdownDocument`（303 行）：按物理空行切块 + fence 保护 + 列表 pending + 缩进并回 + 空白空行拒切 + CR 归一。
- `StreamingCodeFenceParser`（~135 行，`streaming_code_fence.dart`）：独立探测整篇 fence。
- `swallowsSeparator`/`_separatorCache`/`_swallowsTrailingBlankLine`（~80 行）：镜像 `NewLines` 间隙语义。
- `MarkdownDisplayMathScanner`：仅在切分路径中作公式保护。

### 5.2 新切分器设计（`lib/shared/widgets/markdown_streaming_split.dart`，app 侧）

- **边界来自遍历**：`walkNodes(global)` 顶层节点序列中，`NewLines` 间隙节点之后即候选边界。fence/details 占位/已闭合公式都是单节点 claiming，内部**天然无间隙** → 现行 fence 保护与 details 深度跟踪自动消解。
- **带空白的空行**（`a\n \nb`）无 `\n\n+` 邻接 → 无间隙 → 不切，与现行拒切规则一致。
- **列表/缩进并回谓词**：优先用节点 kind（前块首节点 `listItem`、后块首节点 `listItem`/缩进 `group` → 不切）；kind 粒度不足时回落现行 `_listMarker` 行级正则，并把它记为**唯一保留的行级规则**。
- **未闭合公式守卫（唯一保留的前瞻）**：未闭合 `\[`/`$$` 内部空行会产生间隙，而 walk 在闭合前无法产出 math 节点 → 保留 `MarkdownDisplayMathScanner`，只回答「此边界之前是否存在未闭合开符」，用于否决边界。ADR 记录理由。
- **冻结前缀**：已提交块复用**同一块对象**（`MarkdownBlockList` 靠 `identical(_previous[i], blocks[i])` 做保留）；追加只重走尾部；边界只落在换行 run 之后，保证 lookbehind（`(?<!\\)` 等）在子串与全文等价（文档化为不变式）。
- **`swallowsSeparator`**：直接由「walk 是否在该块后产出间隙节点」得出，`_separatorCache` 删除。
- 保留：CR 归一、`MarkdownSourceScan` 的 append 证明、`_preprocessFences`（正交，见 5.4）。

### 5.3 执行顺序（先立金标）

1. **金标先行**：把 `incremental_markdown_document_test.dart` 的切分用例矩阵移植为新 API 的测试（含带空白空行拒切、列表 pending、缩进并回、公式尾部保护、CR 归一、append 证明），先对**旧实现**跑绿。
2. 实现新切分器并接线 `_MarkdownWithCodeHighlightState`；金标测试不变，红→绿即证明等价。
3. 删除：`incremental_markdown_document.dart`、`streaming_code_fence.dart`（含 `_codeFenceParser` 与 `spanBuilder` fence 路径，walk 已原生 claim 未闭 fence）、`_swallowsTrailingBlankLine` 机制及其独占依赖、对应测试文件（已移植）。`markdownEndsWithDisplayMath` 若无剩余调用者，连 `MarkdownDisplayMathScanner` 一并评估删除。
4. **保留**：`MarkdownLineLexer`（TTS 分段/timeline/diagram/details 提取）、`MarkdownSourceScan`、details 占位机制。
5. 净估计：约 −550~600 行、+300 行（含测试）。

### 5.4 details 按出现序键（关闭遗留项）

同一回复里两个相同 `<details>` 目前共享展开键。改法：registry 提升为 `_MarkdownWithCodeHighlightState` 级（非 append 重建时重置），展开键用 registry 的 token 序号而非 `parsed.source` 文本；`_DetailsHtmlBlock.expansionKey` 随之更换；补「两个相同 details 独立展开/复制」测试。

### 5.5 决策门（实现时判定，不预设答案）

- `_preprocessFences` 的 `<`/`$` 掩码是否因 walk 原生 claim fence 而冗余：用「fence 内含 `<` 与 `$`」的漂移 fixture 判定，冗余则删，不冗余则保留并记录原因。

---

## 6. 收尾（工程外）

- 全量 `flutter test`（含 perf bench 单独跑）与 CI 三闸。
- `feat/direct-select-text-v4` rebase 到本分支：删 `subsequenceMatch` 及其测试、ADR 0007→0008 重编号、`SelectionMarkdownMemory.takeCopyText()` 改走 `markdownDocument(...).emitSelectionMarkdown(...)`。
- 已知限制台账（ADR-0007/0008 已有）：同一气泡内重复文本解析到首次出现；HTML 标签组件 best-effort；quote 整体重发射。

---

## 7. 下一步动作（按序）

1. Phase C（见 §4）；第 3 步（叶快路径）的触发条件是 `single` 形状那 +14–29% 是否真实。
2. Phase D（见 §5），金标必须先绿。
3. 收尾（见 §6）：全量 `flutter test` 已有基线（8 个失败全部在 `.toolbridge/known-failures.json` 台账内，
   本 worktree 已放入该台账以便 toolbridge 自动分类）；`feat/direct-select-text-v4` rebase。
