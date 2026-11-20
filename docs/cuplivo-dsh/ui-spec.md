# DSH remote control — UI specification from the reference images

The owner's reference images are untracked at `docs/cuplivo-dsh/reference/`
(they are never committed). This file translates each image into concrete
surface requirements so implementation and acceptance read the same checklist.
Anything not shown here follows Cuplivo's native design language.

Legend: **[F]** Flutter-native (official DSH UI), **[W]** WebView body inside a
Flutter entry (plugin UI only).

## R1 — 助手与群聊: create menu (`image-01a1f435…png`)

- Dark theme, existing page chrome: back arrow left, centred title
  `助手与群聊`, `+` action right.
- Two existing assistant cards unchanged (`默认助手` with avatar 默 and
  subtitle `暂无提示词`; `示例助手` with avatar 示 and the prompt excerpt).
- The `+` action opens a bottom sheet with a drag handle and three rows, each
  a leading line icon + label:
  1. user-plus — `新建助手`
  2. users — `新建群聊`
  3. **whale mark — `DeepSeek Harness`** (new row; the DSH whale glyph, not a
     generic icon)
- Tapping the DSH row starts the creation flow (R2). The row keeps the same
  spacing/typography as the two existing rows.

## R2 — DSH assistant settings shell (`image-01a1f4ab…jpg`)

- Full-page settings, dark: back arrow, centred title = assistant name
  (`DeepSeek Harness`).
- Scrollable segmented tab strip directly under the app bar with five tabs, in
  DSH's own order: **连接设置** (selected), **通用设置**, **模型**, **内置插件**,
  **Agent 预设**. The selected tab is a filled pill; unselected are plain labels.
- Tab 1 body, two cards:
  - Card A: leading circular avatar (DSH whale mark), label `助手名称`, text
    field with the current name.
  - Card B: label `请输入DeepSeek Harness的WebUI访问链接`; one text field with
    the reference placeholder `例如127.0.0.1:3080/?token=PEaxKDfNOHzbHp…` (a
    truncated sample from the brief, not a real credential); full-width filled
    button `确认`.
- Tab 4 内置插件 is a native, read-only body: rows come from the remote
  `pluginInventory/list` inventory (`catalog.plugins`) and show the plugin's
  own localized title, module name, enabled/disabled state, Loader phase and
  diagnostics. There are no toggles or management actions in this slice; the
  Host owns them, so the body states that the list is read-only and has an
  honest empty state. A "needs restart" banner is only shown when a management
  change reports one (none exists yet, so it is not rendered speculatively).
- Tab 5 Agent 预设 is a native, read-only body: group cards come from the
  optional `agentPresets` groups of `pluginInventory/list`, headed by
  `group.name` (or the id), with a default badge, the preset's plugin rows,
  and any broken-composition reason. There is no select action in this slice.
- The invented **内容** tab is removed; it has no data source and no ARB keys.
- A plugin-registered settings tab is generic: after the user visits the
  Host's own settings dialog once, every `settings.section` the official UI
  lists that DSH itself did not register becomes one more tab in this strip
  (`plugin:<slug>`, label is the Host's own text — Cuplivo never knows a plugin
  name). Its body is the embedded official Web UI landed on that section; the
  body is built only when the tab is first selected. Inventory `meta.title` is
  never turned into a tab. See `plugin-compat.md` §3.4a. The 内置插件 tab carries
  one `打开官方设置` row (`dsh-settings-open-official`) that performs that visit.
- The tab strip scrolls horizontally when the five native tabs plus the
  plugin-registered ones do not fit.

## R3 — Connected assistant card (`image-01a1f451…jpg`)

- The 助手与群聊 list gains a third card: circular whale avatar, title
  `DeepSeek Harness`, subtitle **`远程连接的 DeepSeek Harness`** (the image's
  overlapping text is an AI artifact; this is the exact subtitle), same card
  shape as assistants. The row is draggable/editable like every owner.

## R4 — Local sidebar listing the remote (`image-01a1f467…jpg`)

- Existing drawer: search field `搜索当前助手` + history icon.
- Owner rows: `默认助手` (expandable, chevron), its child row, `示例助手`, then
  **`DeepSeek Harness`** with whale avatar and the pencil affordance used by
  every owner row. Tapping the pencil opens R2 for the remote.

## R5 — DSH chat sidebar (`image-01a1f47a…jpg`)

- Drawer content in DSH mode, dark:
  - Search field `搜索当前助手` + history icon.
  - Remote row: whale avatar, name, trailing chevron (collapses the sections).
  - Three entry rows with line icons: **插件** (puzzle), **自动化任务** (clock),
    **更多** (grid). Tapping an entry opens its Flutter entry page.
  - Workspace sections (`默认工作区`, `Test` are examples): folder icon + name,
    then session rows; the selected session has the Cuplivo selected-row
    treatment (filled rounded row). A workspace's new-session row is `新会话`.
  - Bottom bar: user avatar `用` + `用户`, grid action, settings gear.
- The chat behind the drawer keeps Cuplivo's normal app bar (R6).

## R6 — Chat surface (`image-01a1f48c…jpg`) — **重点**

- App bar: hamburger left; title `新会话`; subtitle `deepseek-flash (DeepSeek)`
  (remote model + provider group); right side: new-conversation icon, then a
  **right-rail button to its right** (the minimap entry is removed on this
  surface).
- User message: right-aligned bubble, `用户` name and timestamp above, avatar;
  under it the Cuplivo action row (copy / regenerate / edit / more / version
  arrows).
- Assistant message: DSH avatar + `DeepSeek Harness` name + timestamp, then
  Cuplivo's own rendering stack:
  - a collapsible reasoning card (`深度思考 (0.5s)`),
  - markdown body,
  - tool timeline cards (DNS icons + `联网检索: …`, `读取网页: …` with chevron).
- Composer at the bottom: rounded field with placeholder
  `输入消息与AI聊天`; bottom row shows the remote model selector, reasoning-effort
  selector, plus-menu, and the send button. Cuplivo's own hidden output
  components are not shown; the model / effort lists come from the remote.
  The permission control is the new Cuplivo-side control required by the brief:
  *仅可查看 / 工作区内修改 / 全部权限*.
- The `+` menu mirrors the DSH composer's plus menu: commands and skills come
  from the remote, grouped the way DSH groups them; attachments follow DSH.

## R7 — Right rail open (`image-01a1f490…jpg`) — **重点**

- Opening the rail **pushes the chat off-screen**; the rail is not stacked on
  top of it. The rail occupies the right side of the window with its own header
  (`开始`, layout/expand/close actions at the right).
- Body (official DSH surface → Flutter native, rule "official UI is Flutter"):
  - compass/start glyph,
  - four tool cards with leading icon, title, subtitle, shortcut:
    `工作区文件` / `浏览会话工作区的文件` / `Ctrl + P`,
    `新建终端` / `在会话工作区运行命令` / `Ctrl + ` ``,
    `浏览器` / `浏览网页` / `Ctrl + T`,
    `更多工具` / (no subtitle).
- Plugin contributions appear as additional entries; their inner panel is
  **[W] WebView** inside the Flutter rail chrome.
- Official tool panels are native: workspace files browser, terminal, browser
  use Cuplivo's own surfaces driven by the remote's APIs, not an embedded DSH
  Web page.

## R8 — 通用设置 (`image` — text-only requirement)

- Shows only the two settings the brief calls out as outside Cuplivo's scope:
  - `选择新会话的默认权限限制`
  - `在使用官方模型API时上传Session Log`
- Every official rendering setting (language, appearance, font size, working
  step display/collapse timing, reply display, code view, shortcuts, busy-send
  behaviour, performance/usage) is hidden here — Cuplivo's own settings govern
  them.

## R9 — 模型 tab (`image-01a1f4bc…jpg`)

- Search field `搜索供应商或分组` + `+` action; provider cards: circular provider
  icon (DeepSeek whale), provider name, `启用` pill, chevron.
- The list is the remote's provider list, styled exactly like Cuplivo's provider
  page. Models are **not** usable by local Cuplivo chats.

## R10 — Provider list when adding (`image-01a1f4c4…jpg`)

- `+` opens a full provider list in Cuplivo's existing provider-picker style:
  circular icon + name + chevron, alphabetical (`ant-ling`, `Anthropic`, `Azure`,
  `Basaten`, `Cerebras`, `Cloudflare AI Gateway`, `Cloudflare Workers AI`,
  `DeepSeek`, `Fireworks`, `GitHub Copilot`, `Google`, `Google Vertex`, `Groq`,
  …). The server's full provider catalog decides membership; **`自定义提供商`
  must be the first row** (the brief asks for it explicitly even though the
  screenshot starts at ant-ling).

## R11 — Provider detail (`image-01a1f4c7…jpg`)

- Header `DeepSeek  deepseek-official`; API-key field (`API 密钥` with the `?`
  help, placeholder `留空使用已保存凭据`).
- `自定义设置` collapsible: `API 地址` field with the protocol hint
  (`https://api.deepseek.com/anthropic（默认使用环境 DEEPSEEK_BASE_URL）`,
  `请填写兼容 Anthropic Messages 协议的 API 地址。`).
- `模型目录`: `正在使用适配器默认模型` states, model rows with drag handle,
  model id, display name, delete; per-model fields `上下文窗口`,
  `最大输出 token 数`, `输入类型` (文本 / 图片 checkboxes); `+ 添加模型` action.
- For a **自定义提供商** each model additionally offers its available
  reasoning-effort choices — the UI must expose the same fields DSH exposes and
  no fields DSH cannot serve.

## Acceptance checklist

For every numbered reference above: the E2E screenshot (or a manual screenshot
in the PR) is compared with the image, and the PR lists any deliberate
difference with the reason. Cuplivo-native styling wins where the reference is
silent (loading, error, empty, light theme, desktop widths).
