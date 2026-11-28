# 决策记录：Markdown image

> 一轮一个决定，按轮次追加。本文件是**已定的**结果；各轮的方案书在
> `rounds/r1-*.html`、`r2-*.html`、`r3-*.html`。
> 范围：工具页「Markdown image」（Markdown 进、一张 PNG 出），不是聊天内 `![]()` 的图片渲染。

| 轮 | 决定 | 结论 | 落下的东西 |
| --- | --- | --- | --- |
| 1 | Mermaid：预览与 PNG | **A｜实时预览 + 等图导出** | 预览自渲染（加载 → 图 / 失败卡），导出先预热；预览的失败卡可重试、可复制源码 |
| 2 | 字号与画布 | **B（修订）｜预览 1:1，导出跟随预览宽度** | 移除 `FittedBox` 缩放；导出与预览同宽；桌面上限 720、手机上限 480 |
| 3 | 选区 | **A（修订）｜与 ChatMessage 同一套** | `SelectionSession`；仅「翻译」chip；右键复制 / 复制 Markdown / 复制富文本 / 翻译 / 全选 |

## 轮 1｜Mermaid 取 A（实时预览 + 等图导出）

- 方案书：`r1-a-live-preview.html`（B 为“静态状态 + 导出时出图”）。
- 触发：桌面聊天能出图，但工具预览在预热期间一直显示图表源码，看起来像“没识别成 Mermaid”；
  v5.0.0 的聊天不出图是 rebase 前的旧状态，当前 HEAD 的桥正常。
- 根因：捕获模式（`ExportCaptureScope`）下图表块从不自渲染，只读 `MermaidImageCache`；
  缓存冷时退回普通代码块。预览又在**所有**图表都预热完才重建，所以多个图表时整篇源码等到最后一个。
- 结论：**A**。预览用实时块（加载 → 图 / 失败卡），导出仍先 `preRenderDiagramCodesForExport`；
  导出缓存冷时画失败卡，不画源码。预览的失败卡提供“重试”和“复制源码”；捕获里的失败卡只保留
  说明（PNG 里的按钮没有意义）。
- 后果：平台无渲染器（Linux）时，工具预览与 PNG 都画失败卡；聊天仍保留代码视图，
  PDF 仍回退源码（两者不在本工具的范围）。这是对方案书“Linux 只能走失败卡”的落实。
- 不需要平台侧改动：桥由当前 HEAD 的聊天路径证明可用。

## 轮 2｜字号取 B 修订（预览 1:1，导出跟随预览宽度）

- 方案书：`r2-rev-a-adaptive-preview-fixed-export.html` 与 `r2-rev-b-adaptive-both.html`；
  采纳 **r2-rev-b**（B），并按用户意见“自适应但保持 1:1”修订。
- 触发：“标准”字号下预览的文字比其他界面小；点“收起源码”后好转——这是 `FittedBox` 把
  720 宽的整张画布缩到 592 宽（约 0.82）造成的。
- 结论：
  - 预览按面板宽度**重排**，正文保持 15.5px，不再缩放整张画布；
  - 导出使用预览上报的同一宽度，预览怎么换行 PNG 就怎么换行；
  - 桌面上限 720；手机上上限 480，窄于上限时取实际面板宽度。
- 与方案书的差异：方案书写的“画布夹在 480–720”**没有**实现 480 下限。328px 宽的手机面板
  若夹到 480 就必须缩放，与“保持 1:1”冲突；用户明确要求与对话内消息一致。PNG 宽度因此随
  窗口/分栏变化（方案书已接受这一点）。
- 实现：`MarkdownExportPreview` 在 `LayoutBuilder` 里算 `min(面板宽, 上限)` 并回报；
  页面 `_exportWidth` 用它，未布局过（手机编辑页首次导出）时用窗口宽减 SafeArea 水平 inset
  再减布局的 16+16 内边距。算法抽成 `markdownExportWidthFor` 并有单测。

## 轮 3｜选区取 A 修订（与 ChatMessage 同一套）

- 方案书：`r3-rev-a-chatmessage-parity.html`（B 为“只复制”）。
- 结论：`SelectionSession` 统一消息与文档两种选区；预览选中后浮出**仅翻译** chip；
  右键菜单为复制 / 复制 Markdown / 复制富文本 / 翻译 / 全选，**没有“引用”**（预览没有消息）；
  翻译面板不再强制 `ChatMessage`，改收 provider / model / conversation（预览的 conversation 可为 null）。
- 实现：`AppSelectionArea` 只问 session；`SelectionSession.document` 的选区快照
  `start/end` 固定为 0（没有消息源偏移可映射，也没有消费者）。将来若做“从文档引用”或
  源码高亮，需要用 markstream 的 `sourceRanges` 补上真实偏移，不能继续用 0。

## 实现记录（方案书没写、落地时定下的细节）

1. **预览与 PNG 必须同一套版式规则。** 预览和捕获都包 `ExportCaptureScope(enabled: true)`，
   这样代码块展开、表格全行、移动端换行、不虚拟化这些捕获规则在两边一致；只把“**可以启动
   渲染器**”拆成 `ExportCaptureScope.renderDiagrams`：预览 true、捕获 false、聊天不在 scope 内
   因此为 true。初版把整块 scope 关掉，导致预览与 PNG 在代码块/表格上分叉，已由第一次评审
   指出并修正。
2. **预览的图表重试预算与导出一致。** 文档预览按导出的 500ms + 8×200ms 等待，聊天保持
   120ms + 4×120ms。否则一个慢渲染可能在预览里判失败、在 PNG 里却成功，屏幕与文件再次分叉。
3. **失败卡文案复用现有 ARB。** `mermaidGenerationFailedHint` / `retry` / `genuiCopySource`，
   不改 ARB（避免整组翻译指纹与四语种同步）。代价：提示语仍是聊天语境的
   “Generation failed. Try asking another way.”；要改需新增 key 并过 `translate.py check`。
4. **导出宽度接线只有算术有测试。** `markdownExportWidthFor` 覆盖“预览已上报 / 手机列 /
   SafeArea / 上限 / 0 宽”；“预览回调 → 页面字段 → 服务参数”这两行接线靠阅读，无 widget 测试。

## 评审轮

- **第一次评审（uncommitted）**：两条 Sev 5。
  1. `test/features/chat/widgets/markstream_export_test.dart` 仍在断言已被移除的
     “导出画源码”回退——拆成 HTML 与 Mermaid 两条，后者断言失败卡且无操作按钮。
  2. 预览关掉 `ExportCaptureScope` 后，代码块展开 / 表格行数 / 移动端换行 / 虚拟化一并关掉，
     预览与 PNG 分叉——按上面第 1 条修正。评审留下的 `test/probes/` 已删除。
- **第二次评审（uncommitted）**：一条 Sev 2 —— 本目录只有方案书、没有决策记录；本文件即回应。
  另外四条“待确认”的结论：
  1. Linux PNG 画失败卡还是源码？——**失败卡**（轮 1 的结论）；聊天/PDF 不动。
  2. 预览与导出重试预算不同？——**已对齐**（实现记录第 2 条）。
  3. 文档选区偏移固定 0？——**已知限制**，无消费者；将来做源码映射时按轮 3 的说明补。
  4. 导出宽度接线无测试？——**算术已测**，接线靠阅读（实现记录第 4 条）。

## 验证

- `dart analyze --fatal-infos lib test integration_test`：无问题。
- `dart format --output=none --set-exit-if-changed`（CI 钉的 Dart 3.13.0）覆盖全部改动文件：无差异。
- `flutter test`：导出/图表/选区目标组、`markstream_export_test`、`test/shared/markdown` 全套通过。
