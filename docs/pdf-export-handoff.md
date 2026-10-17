# PDF 导出交接（`exp/export-pdf-no-web`）

> 这份文件是给**下一个会话/接手者**的工作单。第 5 节是**已批准但尚未实现**的 v1.1 计划；
> 第 4 节是几处花了不少代价才查清的技术事实，**重新推导成本很高，不要凭直觉改动**。

---

## 1. 缘起与目标

v3 的会话 PDF 导出走 WebView 打印管线（v3 ADR-0052）：性能差、且要维护两套渲染器。
v4 合入 Markdown IR（ADR-0007/0008）后，本实验验证**直接用 IR 生成 PDF**：
纯 Dart 写 PDF、无 WebView、复用同一棵 IR 树。

**结论：可行。** 100 条消息会话 ≈ **153 ms / 96 KB**（含 CJK 字体解析与子集化），
远低于 WebView 打印管线的"全量 DOM 构建 + 引擎布局"。

---

## 2. 当前状态

### 2.1 已完成并验证

| 项 | 验证 |
|---|---|
| `pdf 3.12.0` 依赖 + archive override | 永久守卫测试证明 pdf 与 archive 4.2 共存 |
| `markdownTableData` 共享纯函数（build/node 共用） | 673 widget 测试绿 |
| IR 导出入口 `MarkdownWithCodeHighlight.markdownDocumentFor`（旗标版，无 provider） | isolate 往返测试绿 |
| `ExportBlock` 块模型 + MD/TXT 改造 | 36 导出测试绿，**输出逐字节不变** |
| 字体链 `pdf_export_fonts.dart`（用户字体 → 系统扫描 → 缓存 → 下载） | 端到端测试用真字体嵌入成功 |
| PDF 发射器 `markdown_pdf_emitter.dart` | 往返测试：CJK/标题/表格/代码/引用/details/分页 |
| 栅格化桥 `pdf_export_rasters.dart`（块级/行内公式离屏捕获 + 图表 PNG 复用） | 键契约测试绿 |
| 编排 `exportChatMessagesPdf` + `compute` isolate + 字节保存 | 编译与测试绿 |
| 入口：选择栏 PDF 按钮、批量对话框、批量底部面板、控制器方法 | 选择栏测试含 PDF 断言 |
| l10n 4 语言（`bridge_arb_edit` + gen-l10n） | 生成物已提交式写入 |
| 基准 `test/perf/pdf_export_bench.dart` | 50 条 149 ms/56 KB；100 条 153 ms/96 KB |
| **§5A 分页不再抛异常**（最高优先，用户实际命中） | `pdf_export_pagination_test.dart` 6 例全绿 |
| **§5B 行内公式栅格化** | `pdf_export_raster_layout_test.dart` 6 例 + 键契约 5 例全绿 |
| **§5C 彩色 emoji 面** | `pdf_export_fonts_test.dart` 3 例全绿（含「不触网」替身断言） |
| **§5D 导出配置弹窗 + 全局反馈 + 降级可见** | `pdf_export_dialog_test.dart` 8 例全绿（含「只有检查会联网」的替身计数器） |
| **§5E 删死键** | 4 个 ARB 区间删除 + gen-l10n exit 0 |
| **§5E′ 列表嵌套/公式排版** | `pdf_export_nesting_test.dart` 10 例全绿（内容流位置断言 + 纯函数 + 降级清单） |

最近一次定向验证：`dart analyze --fatal-infos lib test integration_test` → **零问题**；
`dart format lib test` → 6 个文件重排；`test/features/chat/utils/` → **43 passed**；
`test/features/chat/widgets/pdf_export_dialog_test.dart` → **8 passed**。

**全量 `flutter test`（D/E/E′ 之后，7 分 21 秒）**：`+8421 ~62 -8` —— 相对基线 `+8400 ~62 -8` **多了 21 个测试**
（§5D 的 8 例 + §5E′ 的 10 例 + 若干），失败数不变。这 **8 个失败全部是已登记的 Windows 平台性失败**（`D:\Projects\cuplivo\.toolbridge\known-failures.json`，本工作树已复制一份到
`.toolbridge/`，该目录在 `.gitignore` 里）：composer_draft_store 的私有目录逃逸、world_book_context_usage 的
临时目录占用、native_input_attachments 的 4 个 "sends original PDF" 用例、save_file_picker 的 2 个
"trailing spaces" 用例。它们与本轮改动无关（所属文件与 HEAD 逐字节相同，且 `settings_provider.dart` 的改动是
纯新增两个 getter）。

### 2.2 未提交

**全部改动都在工作树里、未 commit。** 分支 `exp/export-pdf-no-web`，基线 master `de67c1894`。

新增文件：
- `lib/features/chat/utils/export_document.dart`（块模型 + 遍历 + 文本渲染）
- `lib/features/chat/utils/markdown_pdf_emitter.dart`（IR → pdf 布局）
- `lib/features/chat/utils/pdf_export_fonts.dart`（字体链 + 可选面 + 候选枚举）
- `lib/features/chat/utils/pdf_export_options.dart`（会话级导出选项）
- `lib/features/chat/utils/pdf_export_rasters.dart`（栅格化桥）
- `lib/features/chat/widgets/export_progress_overlay.dart`（`runWithExportingOverlay`，图片/PDF 共用）
- `lib/features/chat/widgets/pdf_export_dialog.dart`（配置弹窗 + 结果弹窗）
- `lib/features/chat/widgets/pdf_font_picker.dart`（字体选择二级页）
- `test/features/chat/utils/pdf_export_test.dart`、`pdf_export_rasters_test.dart`
- `test/features/chat/utils/pdf_export_fonts_test.dart`（§5C）
- `test/features/chat/utils/pdf_export_pagination_test.dart`（§5A）
- `test/features/chat/utils/pdf_export_raster_layout_test.dart`（§5B）
- `test/features/chat/utils/pdf_export_nesting_test.dart`（§5E′）
- `test/features/chat/widgets/pdf_export_dialog_test.dart`（§5D）
- `test/perf/pdf_export_bench.dart`（**名字不含 `_test`，`flutter test` 会跳过**）

修改要点：
- `pubspec.yaml`：`pdf: '>=3.12.0 <3.13.0'` + `dependency_overrides: archive: ^4.2.0`
- `lib/shared/widgets/markdown_with_highlight.dart`：抽出 `markdownTableData`、`unmaskCodeSpanDollars`、
  `markdownFenceSource`、`markdownDetailsSummaryText`、`normalizeMathTex`、`unmaskBlockquoteFenceMarkers`、
  `markdownDocumentFor`；**顺手修了一个 6810 行的裸 NUL 字节**（改为 `\u0000` 转义，行为等价，此前该文件被判为"二进制"）
- `lib/features/chat/widgets/message_export_sheet.dart`：装配层改为消费块模型、PDF 编排、导出入口改开配置弹窗
- `lib/icons/lucide_adapter.dart`：加 `Smile`（emoji 字体行用）
- `lib/core/providers/settings_provider.dart`：新增 `appFontLocalPath` / `codeFontLocalPath` getter
- `lib/features/home/{controllers/home_page_controller.dart,pages/home_page.dart,widgets/chat_selection_export_bar.dart}`
- 4 个 ARB + 生成的 l10n；`test/features/home/widgets/chat_selection_action_bars_test.dart`

设计稿（**不进仓库**，`.gitignore:68` 忽略）：`.scratch/pdf-export-dialog-demo.html` —— 弹窗/选择器/结果页/导出中转圈的
HTML+Tailwind 视觉契约，配色与控件均按项目既有约定（`IosNavRow`/`_MemoryOptionRow`/`FormSheetActions`/
`_runWithExportingOverlay`）。改 UI 前先看它。

### 2.3 构建产物（**已过期**）

`build/windows/x64/runner/Debug/cuplivo.exe` 存在，但它是**栅格化桥之前**构建的：
含 PDF 入口与"系统字体优先"修复，**不含**公式/图表栅格化。验收任何新改动前必须重新构建。

---

## 3. 复现与验证命令

本机 Flutter/Dart 为 **3.13.0**，与 `pr-check.yml` 钉的版本一致（格式化不会漂移）。

```bash
flutter pub get
dart analyze --fatal-infos lib test integration_test     # 仓库门禁
flutter test test/features/chat/utils/                   # PDF/导出相关
flutter test test/features/chat/widgets/message_export_sheet_test.dart
flutter test test/shared/widgets/                         # markdown 套件（673）
flutter test test/shared/widgets/markdown_with_highlight_test.dart
flutter test test/perf/pdf_export_bench.dart             # 基准，需显式运行
dart format lib test                                     # 收尾
```

注意：`flutter test` 里**不要**写依赖引擎异步的断言（`RenderRepaintBoundary.toImage`、
`Image.toByteData`）——它们在伪时钟 zone 下永不完成，会挂到超时（本轮已踩过：566 秒挂起）。
捕获路径只能人工验收。

---

## 4. 已确认的技术事实（勿凭直觉改）

1. **分页抛异常的根因**：`pw.RichText.canSpan => overflow == pw.TextOverflow.span`（pdf `text.dart:1363`）。
   默认 `visible` ⇒ 任何单块高度 > 一页的内容都会在 `multi_page.dart:385` 抛
   `Widget won't fit into the page ...`。实测数字：759.890 = A4(841.89) − 40 − 42 边距；用户命中 3048.139。
   波及：超长代码块、工具输出大 JSON、单个超长段落、长引用/思考卡、**高图**（`pw.Image` 无 `canSpan`，必抛）。
2. **跨页重绘**：`StatelessWidget`/`SingleChildWidget`.canSpan **转发给子节点**；`Flex`（纵向）`canSpan == true`。
   内层 RichText 一旦用 `span`，外层 Container 的填充/圆角**每页重新布局并重绘** ⇒ 装饰块可连续跨页，不需要手工分块。
3. **彩色 emoji 只能走 fontFallback**：`text.dart:834-843` 仅在 fallback 链上、且字体是 `PdfTtfFont`
   且有 CBDT 位图时才 `_addEmoji` 画位图。放 base 无效。
4. **`.ttc` 与 CFF 不可用**：pdf 的 `TtfParser` 在固定偏移 12 读表目录，**没有 `ttcf` 处理**；
   `OTTO`（CFF 轮廓）没有 `glyf` ⇒ 会嵌进一个"没有字形"的字体。这就是"iOS/Android 系统 CJK 字体不可用、
   必须下载"的原因（PingFang/NotoSansCJK 全是 `.ttc`）。Windows 上 `Deng.ttf`/`simhei.ttf` 是纯 TTF ✓。
5. **字体链顺序**（`pdf_export_fonts.dart`）：用户字体文件 → **系统扫描** → 缓存 → GF 下载。
   下载放最后是因为它是**三次串行网络请求**（8MB 目录 + license + ~10MB 字体，各 30s 超时），
   首次导出曾因此静默数十秒（用户实际踩到）。下载失败本会话只重试一次。
6. **栅格尺寸必须携带逻辑点数**：捕获是 3×（公式）或 `devicePixelRatio × 2`（mermaid canvas），
   按像素数嵌入会印成 2–3 倍大。`PdfRaster{bytes,width,height}` 就是为此存在。
7. **`pw.WidgetSpan({child, double baseline})`** 可用 ⇒ 行内公式栅格化可行（数字基线偏移）。
8. **伪粗体代价**：`renderingMode: PdfTextRenderingMode.fillAndStroke` 是一行，但描边宽度**包内硬编码 0.5pt**
   （`text.dart:309`），10.5pt 正文下会发糊；斜体需 skew，包内无文本级变换 ⇒ 不做（详见 §5F）。
9. **isoate 传输已验证**：`ExportBlock`/`ExportMessage`/`PdfRaster` 等自定义对象可跨 `compute` 传递
   （有测试守着）。`compute` **无法取消**。
10. **离屏捕获的既有一致做法**：`Positioned(left:-10000, top:-10000)` + `RepaintBoundary` + 等 3 帧
    （`message_export_sheet.dart` 的全图捕获；栅格化桥的公式捕获同款）。
11. **archive override 的由来**：`pdf 3.12` 声明 `archive <4.1.0`，但 `data_sync.dart` 覆写了
    `OutputStream.writeBackReference`（**archive 4.2 API**，#954）⇒ 不能降 archive，
    只能 override 并靠守卫测试兜住。`pdf 3.13+` 需要 `xml 7`，而 `xml 7` 与 `syncfusion 31`
    （锁 `xml ^6.5.0`）和 `math_expressions 2.x`（锁 `petitparser 6`）冲突 ⇒ 上限卡在 `<3.13.0`。
12. **`overflow: span` 只在「MultiPage 的直接子节点」有效**（本轮实测，9 组对照）：
    - `Padding > RichText(span)` ✓ 12 页全文本；`Container(装饰) > RichText(span)` ✓（装饰每页重画）；
      多个并列 span ✓；`pw.Text(overflow: span)` ✓（`Text` 直接把 overflow 转发给内部 `RichText`）。
    - **放进 Column 就完蛋**：`Container > Column > [Text, RichText(span)]` ⇒ `TooManyPagesException`。
      因为 `Flex` 只在**子节点之间**断开（`flex.dart:284` 超出即 break），子节点自身永远不会被
      MultiPage 驱动 span，于是 `lastChild` 停在同一个子节点上不再前进。
    - **横向 `Row` 内的 span 也不行**：`Flex.canSpan => direction == Axis.vertical`，Row ⇒ false ⇒ 直接抛
      `Widget won't fit into the page`（既不是挂死也不是分页）。
    ⇒ 结论：**能无限长的文本叶子必须是页面流的直接子节点**；分组只能用「逐块皮肤」而不是 Column。
13. **写入器的页数守卫是 `assert`**（`multi_page.dart:292-300`，注释明写 "This is not checked with a
    Release build"）⇒ **release 下任何不前进的布局都是死循环**（不是抛异常、不是降级）。所以本轮把
    所有会不前进的形状都消灭掉，而不是捕获异常。
14. **`Table.canSpan => true` 且 `hasMoreWidgets => true`（永远）**⇒ 一个「单行高于所在页可用高度」的表格
    必然死循环：行放不下 ⇒ `index--`、`lastLine == firstLine` ⇒ 换页重来同一行。表头行还会在续页重复，
    占掉更多空间。**这是 `_CappedCell` 存在的唯一理由**。
15. **可用高度是实测出来的，不是算出来的**：运行页眉 17.248pt、页脚 19.248pt（A4 + 46/40/42 边距，
    见 `pdf_export_pagination_test.dart` 的注入实验）。实测边界：**680pt 的行能分页，690pt 就死循环**。
    因此 `_maxUnbreakableHeight = _pageContentHeight * 0.85`（≈646pt），把表头行、单元格 padding、
    标题占位都留在余量里。**提高这个系数会让表格导出挂死**——已用注入实验验证过（改成 `* 1.0` 就
    `TooManyPagesException`）。
16. **`MultiPage.maxPages` 数的是「自上一个被放下的 widget 以来的迭代次数」**，也就是**单个 span 块跨了多少页**
    （放下 widget 时归零），默认 20 ⇒ 一个 4000 行代码块（≈64 页）在 debug 下直接抛 `TooManyPagesException`。
    已改为 2000。**release 无此限制**，所以它只是 debug 期的护栏。
17. **`SingleChildWidget` 不带 `paint`**：mixin 只提供 `paintChild`，所以一个覆写 `layout` 的子类必须自己
    写 `paint() { super.paint(context); paintChild(context); }`，否则子节点「布局了但不可见」（本轮踩过）。
18. **行内公式的尺寸靠共享常量**：`kPdfBodyFontSize = 10.5` 同时被布局（正文样式）和栅格化桥（行内捕获字号）
    使用 ⇒ 行内栅格**按捕获尺寸原样嵌入**（不再缩放），基线用 `WidgetSpan(baseline: -h * 0.25)`。
    块级公式仍是 22pt/`MathStyle.display`，行内是 10.5pt/`MathStyle.text`。
19. **栅格键现在是一个函数**：`pdfRasterLookupKey(PdfRasterKey)`，两侧共用。同一个 TeX 的行内版与块级版
    是**两个不同的键**（`display: ` 前缀），因为它们画出来不一样；图表键就是围栏代码本身（语言只决定怎么画）。
20. **内容流里：缩进在 `cm`，不在 `Td`**。`Padding` 之类的平移会写 `q 1 0 0 1 tx ty cm`，而 `Td` 的操作数是
   **控件局部坐标**（实测同一条列表项的 `Td` x 都是 0，缩进体现在 `cm` 的 tx：46 → 60 → 74）。而且写入器
   **一个词一个 `BT…ET` 块**（`[(-)]TJ` 和 `[(alpha)]TJ` 是两个块）。所以任何「文本画在哪」的测试都要维护
   `q/Q/cm` 平移栈，并把「同一行」判定成 `y` 相同而不是「同一个串」（`pdf_export_nesting_test.dart` 有现成实现）。
21. **块之间的空白是一个 `MdNodeKind.text` 节点，且它的 offset 可能指向上一行的换行**。例：`- alpha\n  - bravo`
   走出的节点是 `listItem(start=0)` → `text(start=7)` → `listItem(start=8, indent=14)`。所以
   （a）缩进函数量的是「第一个非空白字符所在行」的缩进，不是 `offset` 所在行；（b）`flush()` 必须跳过**整段空白**，
   否则每个块之间都会多出一个空段落（列表项之间尤其明显）。
22. **缩进项的 `range.start` 落在行首空白上**，不是 `-` 上（实测 `  - bravo` ⇒ `start=8`，`-` 在 10）。
   这反而正好：节点自己那一行的缩进就是它的嵌套层级。`UnOrderedList`/`OrderedList` 的 `expString` 只匹配一行，
   `MdNodeKind` 里**没有列表容器**，所以嵌套只能这样恢复——不要试图从 `depth` 推。
   `pdfIndentForSourceLine(source, offset)` 是公开纯函数：空格 2 列一层、Tab 4 列、上限 6 层、每层 14pt。
23. **`pw.RichText` 没有首行缩进**（构造参数只有 `text/textAlign/textDirection/softWrap/tightBounds/
   textScaleFactor/maxLines/overflow/hyphenation`，且写入器按 span 区间切文本）⇒ **悬挂缩进不可达**：
   单独成盒的 marker 要么是 `Row`（`Flex.canSpan == false`，不可跨页）要么是 `Table` 行（被 `_CappedCell` 裁断）。
   这是「列表项折行对齐 marker 而不是对齐正文」这一取舍的唯一原因。
24. **纯图片段落曾经从不嵌入图片**：`![…](…)` 单独一行时 run = [图片, 换行]，而判据是 `pictures == run.length`
   ⇒ 走散文分支只画 alt 文本，图片既不嵌入**也不进降级清单**（于是「图片导出」的测试一直是空转的）。
   判据改为 `pictures > 0 && pictures + blanks == run.length`；同时图片分支要按 `kind` 过滤，
   否则空白节点会被 `_imageParts('\n')` 解析成一个空 URL 混进清单。
25. **字体解析器是对象，`allowDownload` 就是「有没有 catalogue」**：`PdfFontResolver(googleFonts: null)` 的
   `resolve` 连下载分支都进不去，所以「先看盘上有什么」不需要额外的旁路开关；`resolvePdfExportFonts` 自由函数
   已删除（无兼容层）。`PdfFontResolver` 故意不是 `final class`，测试要替换它。

---

## 5. v1.1 计划与进度

用户初验结论（原话对应）：1 删除单条；2 不用；3 暂时不用；**4/13 超长块会报错**；5 不用；
**6 现在做**；7 之后；**8 现在做**；9 之后；10 之后；**11 现在做**（改成导出前弹窗 + 可配置 + 字体情况 +
全程全局反馈）；12 问"现在是否容易"；14/15 见 11；16–18 之后再说。

**状态：A、B、C 已实现并验证；D、E 未开始；F 结论是不做。**
A/B/C 都还没有**人工验收**（需要重新构建 Windows 产物），D 做完后一起验收更省事。

### A. 分页抛异常（最高优先，用户实际命中）——**已完成**

原计划是「给所有无上界 RichText 加 `overflow: span`」。**实测否掉了它的一半**（见事实 12）：
`span` 只在页面流的直接子节点上生效，放进 Column 反而变成死循环。所以本轮不是加旗标，而是**改写布局**：

- **A1 结构**：发射器不再用 `Column` 组织任何块。新增 `_BlockSkin`（缩进 + 填充 + 左边框 + 内外间距），
  每个叶子单独套自己的皮肤；相邻带填充的块因为「间距画在填充**内部**」而看起来是连续的一个面板
  （引用块的左边框同理，不会断成虚线）。所有文本叶子带 `overflow: pw.TextOverflow.span`。
  - 思考卡 = 标签叶子 + 正文叶子（同一皮肤）；工具调用 = **一个** 叶子（`[name]\n` + 内容，实测
    换行在 span 内可用）；引用/details/列表项 = 逐块皮肤；列表项的标记并入首段行内（**代价：换行后没有悬挂缩进**）。
- **A2 高图封顶**：图片/图表/表格行统一 `_maxUnbreakableHeight = _pageContentHeight * 0.85`（事实 15）。
- **A3 不再需要手工分块**：文本交给写入器分页；不可分的东西靠封顶。
- **额外（计划外，因为发现了死循环）**：`_CappedCell` 把表格单元格截断（事实 14），并把
  `MultiPage.maxPages` 提到 2000（事实 16）。
- **验证**：`test/features/chat/utils/pdf_export_pagination_test.dart`（6 例，全绿）——4000 行围栏、
  6000 词单段、长引用/思考卡/工具输出/列表项、100×4000 PNG、5000 词表格单元格、正常表格。
  **非空洞性**：把系数从 0.85 改成 1.0，表格那例会 `TooManyPagesException`（已注入验证，53 秒后抛出）。
- **已知观感副作用**：跨页装饰块每页各带一次圆角；列表项无悬挂缩进；表格单元格超长会被裁掉
  （裁剪后文本仍在内容流里，可被选择/抽取，但画面上看不到）。

### B. 行内公式栅格化（#6）——**已完成**

- 键：`PdfRasterKey` 增 `display`，并提供 `pdfRasterLookupKey`（事实 19）。
- 桥：行内按 `kPdfBodyFontSize`(10.5) + `MathStyle.text` + padding 2 捕获；块级不变（22pt/display/padding 6）。
- 发射器：`_spans` 的 `math` 分支 → `pw.WidgetSpan(pw.Image(...), baseline: -h*0.25)`，按捕获尺寸原样嵌入；
  无栅格时维持 TeX 文本降级。
- **验证**：`pdf_export_raster_layout_test.dart`（6 例）用**注入的栅格**驱动，不需要引擎：有栅格 ⇒ 文档里
  出现 `/Subtype /Image` 且读回的文本里没有该 TeX；无栅格 ⇒ 无图像且 TeX 在文本里；
  **只给行内键的栅格不会被块级公式取用**（跨键防串用）；图表同理。
  **仍需人工验收**：公式在行内的基线是否好看（`baseline: -h*0.25` 是估的）。

### C. 彩色 emoji（#8）——**已完成**

- 字体链增 emoji 面（`PdfExportFonts.emoji` / `emojiDescription` / `emojiIsColour`）：
  系统扫描（`notocoloremoji` → `notoemoji` → `applecoloremoji` → `seguiemj` …，**位图面优先**）→ 缓存 → 下载
  （`Noto Color Emoji` → `Noto Emoji`）。
  **注意**：仍然「系统优先于下载」——Windows 的 `seguiemj.ttf` 是 COLR（无 CBDT），会印成单色；
  为把它变成彩色而静默下载 10MB 不划算，D 的弹窗会把实际用面显示出来，让用户自己选。
- 接线：`ThemeData.withFont(fontFallback: [mono, emoji])`（**fallback，不是 base**，见事实 3）。
- 新增 `pdfFontHasColourBitmaps(bytes)`：读表目录判断 CBDT+CBLC（即「彩色」与「单色」的区别）。
- 缓存文件改为**按角色**命名（`body.ttf` / `emoji.ttf` + `.family.txt` + `.license.txt`）：原来按 family slug
  命名时，目录里没有列出的 family（例如命中 `chinese-simplified` 兜底分支）会缓存不命中、反复下载。
- **验证**：`test/features/chat/utils/pdf_export_fonts_test.dart`（3 例，全绿）：
  - 合成表目录：`CBDT+CBLC` ⇒ true；只有 `CBDT` ⇒ false；`COLR/CPAL/glyf` ⇒ false；`ttcf` ⇒ false；
  - 字体链在 `googleFonts` 为一个「一调用就抛」的替身时**不触网**就跑完（顺序的最强断言）；
  - 有/无 emoji 面的对照：**无面时字符被整个丢掉**（读回文本全 ASCII，且文档没有 `/FontFile2`），
    有面时读回到一个非 ASCII 字形（抽取器经子集读回来的码点不准：U+1F389 读成 U+1F38，所以断言的是
    「出现了非 ASCII 字形」，不是具体字符）。代码块内的 emoji 同样成立。
- **仍然无法在本机验证**：CBDT 彩色位图路径（本机只有 COLR 的 `seguiemj.ttf`）；GF 下载分支依然未执行。
  实测结论修正：**COLR 面不会空白**——`_preProcessSpans` 对「fallback 支持该 rune 但无位图」的分支会用
  该面画 `glyf` 轮廓（单色）；真正会丢字符的是「一个面都没有」。

### D. 导出前配置弹窗 + 全局反馈 + 降级可见（#11/#14/#15）——**已完成**

与本节原先的草案相比，落地时改了四处，都是被代码逼的：

- **API 不再是一个自由函数**。`resolvePdfExportFonts(...)` 换成 `PdfFontResolver`（可注入、可被测试替换，
  所以不是 `final class`）：`resolve({body, mono, emoji, appFontPath, codeFontPath, allowDownload})` +
  `candidates(role)`。`allowDownload: false` 是「先看盘上有什么」那一趟，**不是**一个绕过网络的开关——
  没有 catalogue 的 resolver 连下载分支都进不去。
- **面选择是显式的**：`PdfFontChoice` = `PdfFontAuto` / `PdfFontSystemFace(path)` / `PdfFontDownload(family)` /
  `PdfFontBuiltIn`。选了取不到的面**回落 auto 链并写明原因**（`PdfFontStatus.fallback`），陈旧路径不会产出空白 PDF。
  等宽角色**不提供下载**：`_autoMono` 的设计就是退回正文面。
- **页数是精确值**，不是草案里的「扫字节数 `/Type /Page`」：`document.document.pdfPageList.pages.length`。
- **结果页比草案少**：只留「N 页 · X MB」+（有降级时）一行计数与逐类一行；不列实际用面、不显示文件名、
  没有「打开所在文件夹」——用面在导出前那一屏已经看过（用户当轮明确要求减字）。

落地形态：

- `lib/features/chat/widgets/pdf_export_dialog.dart`：桌面 `Dialog` / 移动 `showModalBottomSheet`
  （`ResponsiveHelper.isDesktop`，桌面禁 sheet）。正文用 `IosSectionHeader` + `SectionCard(dividers: true)` +
  `IosSwitchRow` / `IosNavRow`，底栏用 `FormSheetActions`（等宽 h44 r12 gap12）。
  打开时只做 `allowDownload: false` 的解析（秒开）；「检查字体」才允许联网。
- `lib/features/chat/widgets/pdf_font_picker.dart`：候选=自动 / 系统可嵌入面 / 可下载 family / 内置，
  当前项尾部 `Lucide.Check`，行间 0.5px 分隔线；桌面 dialog、移动 push。
- `PdfExportResult{bytes, pages, degradedMath[], degradedDiagrams[], undrawnImages[]}`：
  `buildConversationPdf` 返回它，`exportChatMessagesPdf` 返回 `Future<PdfExportResult?>`（picker 取消 ⇒ null）。
  降级收集点：`_inlineMath`/`_displayMath` 无栅格、图表围栏无栅格、图片无字节或行内被换成引用（都是 `LinkedHashSet`，去重保序）。
- `runWithExportingOverlay` 从 `message_export_sheet.dart` 挪进 `export_progress_overlay.dart` 并公开：
  PDF 与图片导出共用同一张遮罩，`exportChatMessagesPdf` 全程在它里面（字体解析 → 取图 → 排版 → 保存框）。
- 3 个入口改为开弹窗：批量 dialog（`:2135`）、批量 sheet（`:2402`）、`home_page_controller.exportSelectedAsPdf`。
- l10n：32 个新键一次性写 4 个 ARB（含 `{pages}/{size}/{count}` 占位），`gen-l10n` exit 0；手写 `@` 元数据被
  `bridge_arb_edit` 拒绝，占位类型由生成器推断为 `Object`，`int` 实参照传即可。
- **验证**：`test/features/chat/widgets/pdf_export_dialog_test.dart`（8 例，全绿）：三行状态文案（含单色/彩色）、
  内置字体警告、**只有「检查」会联网**（替身计数器断言 `downloads`）、选面后行更新且 `used.body` 是所选项、
  结果页数字与降级计数、取消保存 ⇒ 不弹结果、无降级 ⇒ 只有一行、选择器候选与分组。
  需要 1000×1800 的测试面：默认 800×600 下弹窗下半部被裁，裁掉的行的 `tap` 打不中（这条本身是个坑）。

### E. 删除单条消息 PDF 残留（#1）——**已完成**

`bridge_arb_edit` 区间删除从 4 个 ARB 移除 `messageExportSheetSinglePdfSubtitle`（死键）+ 重生成。代码侧无需改动。

### E′. 「列表嵌套公式」这类情形（本轮新增，**已完成**）

用户点名的那一类，查下去是 6 个彼此独立的缺陷，其中 3 个正好被「列表 + 公式」同时踩中：

| # | 缺陷 | 证据 | 改法 |
|---|---|---|---|
| 1 | 嵌套列表在 IR 里是平的 | 列表组件各匹配一行（`UnOrderedList.expString = r"(?:\-|\*)\ ([^\n]+)$"`），`MdNodeKind` 无列表容器 | 从节点自己那一行的**源码缩进**求层级（事实 21/22） |
| 2 | marker 掉到单独一行 | `_isInlineKind` 不含 `math`/`group`；`- $x^2$ …` 与 `- [文字](url) …` 都走「块首」分支 | `_opensParagraph`：inline ∪ group ∪ **非 display 的 math** |
| 3 | 缩进累乘 | `indent + depth * 12` 而 `skin.indent` 已含父级 `depth * 12` ⇒ 三层实占 72pt | 每个构造只加**一次** `_indentStep = 14`（引用加 `_quoteInset = 10`） |
| 4 | 宽度帽无视缩进 | `_rasterImage`/`_inlineMath` 都用整页 `_contentWidth` | `_BlockSkin.availableWidth` + 公开纯函数 `pdfRasterScale(...)` |
| 5 | 行内公式没有高度帽 | `_inlineMath` 只按宽度缩放；`WidgetSpan` 不可分页 ⇒ release 死循环 | 同一 `pdfRasterScale` 套 `_maxUnbreakableHeight` |
| 6 | 单元格里的 `$$` 被当行内排 | `_spans` 的 math 分支无条件 `_inlineMath` | 按 `_isDisplayMath(node)` 选栅格 |
| 7 | 块首是 display 公式时 marker 段仍带块间距 | 空段落走 `skin.wrap` 的 `bottom` | marker 段 `bottom: 0` |

外加两个实现中撞见、必须一起修的东西：

- **块之间的空白是一个 text 节点**，它的 `range.start` 可能正落在上一行的换行上（事实 20）。所以缩进函数量的是
  「第一个非空白字符所在行」的缩进，且 `flush()` 要跳过整段空白（否则每个列表项之间多一个空行）。
- **纯图片段落从来没走图片分支**：`![…](…)` 那一行的 run 是 [图片, 换行]，而条件是 `pictures == run.length`
  ⇒ 被当散文，只画 alt 文本，图片既不嵌入也不进降级清单。改成 `pictures + blanks == run.length`；顺带发现
  图片分支在遍历 run 时把空白节点也当图片处理（`_imageParts('\n')` 产出空 URL）——已按 kind 过滤。

**不做**：悬挂缩进。`pw.RichText` 的构造参数没有首行缩进（`text/textAlign/textDirection/softWrap/tightBounds/
textScaleFactor/maxLines/overflow/hyphenation`），把 marker 拿出去单独成盒就是 `Row`（不可跨页）或 `Table` 行
（被 `_CappedCell` 裁断）——**保留「marker 内联、折行对齐 marker 而非正文」**。

**验证**：`test/features/chat/utils/pdf_export_nesting_test.dart`（10 例，全绿）。位置断言的要点是**内容流**：
`Td` 的操作数是控件局部坐标，缩进在它前面的 `1 0 0 1 tx ty cm` 里，所以提取器维护一个 `q/Q/cm` 平移栈；
写入器**一个词一个 `BT…ET` 块**，所以「同一行」是 `y` 相同而不是「同一个串」。
- 纯函数：空格=2 列/层、Tab=4 列、上限 6 层（40 空格 ⇒ 84pt）、末尾 offset ⇒ 0；
- 布局：扁平列表三行 x 相同（**负控**，证明断言不是恒真），嵌套 14/14；引用里的列表两级都缩进；
  8 层嵌套的 marker x 只有 7 个不同值且跨度正好 6×14（钳制真的生效）；
- marker：`- $x^2$ is the area` 这一行的**最左块是 `-`**；`- $$…$$` 的 `-` 与公式**不在同一 y**（反向断言）；
- 降级：无栅格的公式/图表、无字节的图片都进清单，且同类多次只报一次。

### F. #12 伪粗体（结论：本轮不做）
- 唯一现成手段 `renderingMode: fillAndStroke`，但描边宽度硬编码 0.5pt、无样式可调 ⇒ 发糊；斜体不可行（事实 8）。
- 若用户要"试观感版"：给 `_bodyStyle` 家族加 `renderingMode`，仅在"字体无粗体兄弟面"时启用，验完再定去留。

### 交付顺序与验收清单
1 ~~A（bug）~~ → 2 ~~B~~ → 3 ~~C~~ → 4 ~~D~~ → 5 ~~E~~ → 5′ ~~E′（嵌套/公式）~~ →
6 **文档（进行中：本节 + §2 + §4 + CONTEXT.md 术语）** → 7 提交 → 8 人工验收（换新构建） → 9 ADR-0011。
每步：`dart analyze --fatal-infos lib test integration_test` + 定向测试 + `dart format`；收尾全量 `flutter test`。

**需人工确认**（代码与自动测试都已就位，只差在设备上看）：4000 行代码块跨页不报错；行内/块级公式都是图且基线正常；
emoji 有彩色位图（本机只能验单色轮廓）；长表格单元格被裁而不是卡死；嵌套列表肉眼可见分层；
字体弹窗三面来源可见且「检查」能预暖；全程全局转圈；结束有结果摘要；结果页降级计数与实际相符。

---

## 6. 明确不做（本轮）与降级清单

| 编号 | 项 | 状态 |
|---|---|---|
| #2 | 一键"导出整段会话"入口 | 不做（需先进多选） |
| #3 | 书签/大纲、元数据扩展（只有 title+author） | 暂时不做 |
| #5 | 明暗主题选择（恒浅色） | 不做（既定决定） |
| #7 | PlantUML 图表（离线渲染器只认 mermaid/SVG） | 之后做，现退代码文本 |
| #9 | 网络图片（http/https）不拉取 | 之后做，现退 alt/URL |
| #10 | 引用块内 / 表格单元格内图片不参与预解析 | 之后做，现退 alt |
| #12 | 伪粗体/斜体合成 | 见 §5F |
| #16–18 | 人工验收、捕获路径测试、GF 下载分支测试 | 之后再说 |

其他已知降级：代码块恒导全文（不跟随折叠态，设计如此）；系统字体族自动映射（被 D③ 的选择面取代）；
页面参数不可配（A4 + 46pt 边距 + 页脚 `x / y`）；`compute` 无取消；嵌套列表项折行时对齐 marker 而不是正文
（悬挂缩进在 `pw.RichText` 下不可达，见事实 23）。

---

## 7. 验证缺口（不要假装已覆盖）

- **公式/图表捕获、emoji 位图、跨页观感**：引擎级异步，`flutter test` 无法驱动 ⇒ **只能人工验收**。
- **GF 下载分支**（iOS/Android 唯一的 CJK 字体来源）**从未执行过**：既无测试也未实测；
  失败且无缓存时移动端会退到内置字体（中文变空白）。D 的「检查字体」是它第一次有机会被跑到。
- **从未真正启动过**：Windows 构建成功，但一次都没运行（初验由用户在自己构建上完成）。
  `build/windows/.../cuplivo.exe` 仍是**栅格化桥之前**的产物，验收任何本轮改动前必须重新构建。
- **弹窗与结果页的观感**：自动测试只断言文案与计数，不断言好看。视觉契约是
  `.scratch/pdf-export-dialog-demo.html`（不进仓库），实现按它对齐；两者不一致时以代码为准并更新 demo。
- **弹窗测试依赖测试面尺寸**：默认 800×600 下弹窗下半部被裁，被裁的行 `tap` 打不中而**静默无效**；
  测试已固定 1000×1800。新增的弹窗测试要照做，否则会写出看起来在断言、其实什么都没点的测试。
- **嵌套/公式的位置断言只覆盖内置字体的 ASCII 用例**：内容流提取靠字面量 `(...)` 串，嵌入 TTF 后是字形索引，
  抽取器读不回来。要断言 CJK/嵌入面的位置需要另一套提取器（或换成读回文本 + 表格坐标）。

---

## 8. 交接注意事项（不变量）

1. **只有一处遍历**：`MarkdownWithCodeHighlight.markdownDocumentFor` 是唯一入口；
   渲染、复制映射、PDF 三者共用。**不要为 PDF 另写 markdown 解析**（ADR-0007/0008 治的就是这个病）。
2. **PDF 发射器忽略显示空间**：`gap`/`opaque`/`decoration` 是为**复制映射**服务的；
   发射器只读 `kind` + `children` + `range`。判断块级/行内靠 range 文本（如 `$$`）与节点种类，不猜语法。
3. **硬叶子的结构回收**：引用 `markdownQuoteText` + 同 walk 重走；围栏 `markdownFenceSource`；
   表格 `markdownTableData`；details `markdownParseDetails`；图片 5 行扫描；公式从 range 剥定界符。
   **一律复用这些公开规则**，不要就地再写一套。
4. **`export_document.dart` 是 MD/TXT/PDF 的共同来源**，MD/TXT 输出必须逐字节不变
   （`message_export_sheet_test.dart` 的精确空白断言是护栏）。
5. **栅格键契约**：`pdfRasterKeysIn` 产出的键就是 `rasters` 的查找键；桥和布局必须共用它
   （现由 `pdf_export_rasters_test.dart` 守着）。
6. **字体链顺序**与 **fallback 放 emoji** 两条都有源码级理由（事实 4/5/3），改动前先读 §4。
