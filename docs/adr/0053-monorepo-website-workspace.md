# ADR-0053: website/ Mono-repo for Official Site & Backup Tools

Status: accepted

备份工具 **kelivo-helper**（Svelte 5 + Vite，原独立仓库 `cup113/kelivo-helper`，Netlify 托管）与本项目新的**官方站**合并进本仓库的 `website/` 下，合并为一个 pnpm workspace。两个决定性动机：(1) helper 的**兼容**目标应用就是这个仓库——备份格式变更与 helper 管线改动应在同一个 PR 内完成，单一事实源；(2) 需要一个官方站，且备份工具成为它的首要特性——工具 UI **单主页**（B1）：工具页面只存在于官网，旧独立域名退役为永久 301。

## Decision

- **Workspace 边界**：`website/` 是唯一的 pnpm workspace 根，pnpm 绝不越界到仓库根。仓库根保持纯 Flutter（以 `dart analyze --fatal-infos lib test` + 现有 Flutter CI 为准）。原始 helper 历史通过 git subtree 并入（`website/apps/helper`）。
- **布局**：`website/apps/*`（`helper`——过渡期应用，割接后删除；`website`——SvelteKit + `adapter-static`）+ `website/packages/*`（`core`——纯 TS 备份处理核心，零 DOM）。
- **后端边界**：备份处理（迁移/兼容/找回）永远 100% 浏览器端，数据不出浏览器。未来任何后端都是独立服务，只承载**公共只读数据**（release 元数据、公告、下载统计），永不接收用户备份数据或用户输入；CORS 开放不改变这条信任边界。当前无真实需求，不建（YAGNI）。
- **域名**：官网 `cuplivo.cup11.top`（自有可携带域名；`cuplivo.netlify.app` 保留为 staging）。旧 `kelivo-helper.netlify.app` Netlify site 对象不删，部署内容替换为 `_redirects` 路径映射（`/` → 官网首页，`/kelivo-fill-assistant.html` → 恢复工具路由，其余全局 301）；独立的 `kelivo-fill-assistant.netlify.app`（遗留单文件工具站，CDN+inline JS，非构建产物）同样退役为 301 到恢复工具路由。
- **文档归属**：根 `CONTEXT.md` = Flutter 上下文；`website/CONTEXT.md` = Web 上下文（随合并迁入，增补后端边界与单主页表述）；新增根 `CONTEXT-MAP.md` 指向两者。Web 范围内决策走 `website/docs/adr/` 独立编号；仓库级决策走根 `docs/adr/`。

## Considered (rejected)

- **保持 `cup113/kelivo-helper` 独立仓库**：复杂——备份格式一变，改动被迫拆两个 PR，格式漂移风险。
- **官网纯营销/静态，工具留在独立域名**：UI 会维护两份，且用户转化路径断裂。
- **现在自建服务器/含后端项目**：推迟——无具体需求；边界已在本 ADR 记录，等下载统计等真实需求再立。
- **同批重写 Web 对话壳（`assets/web_chat/`）为 Svelte**：拒绝捆绑——壳重写是独立后续阶段（协议冻结、只 bump `webChatAssetVersion`、以 `test/protocol.test.mjs` 1523 行为验收网），届时另立 ADR；与本次迁移相互正交。
