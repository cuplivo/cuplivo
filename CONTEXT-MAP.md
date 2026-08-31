# Context Map

本仓库有两个限界上下文（拆分与边界见 [ADR-0053](./docs/adr/0053-monorepo-website-workspace.md)）。

## Contexts

- [Cuplivo 应用（Flutter）](./CONTEXT.md) — 跨平台 LLM 聊天客户端（Android/iOS/macOS/Windows/Linux）。本地 Drift 数据库、Web 对话壳（`assets/web_chat/`）、桌面壳与移动端入口。
- [Cuplivo Web（官网与备份工具）](./website/CONTEXT.md) — pnpm workspace：官方站（`cuplivo.cup11.top`，营销/文档 + 工具路由）+ 备份处理核心。工具全部在浏览器本地，数据不出浏览器。

## Relationships

- **Web → 应用**：Web 上下文的**兼容**转换的目标就是应用仓库的备份格式；备份格式变更（ADR-0048 等）应同时评估 helper 管线——两处变更落在同一 PR 内。
- **应用 → Web**：README 下载链接与官网入口（README 双文件同步规则见根 AGENTS.md）。
- **无共享代码包**（Dart vs TS，两个运行时）。未来若 Web 对话壳改由 web 工具链构建（挂到 `assets/web_chat/`），以独立 ADR 划定边界。
