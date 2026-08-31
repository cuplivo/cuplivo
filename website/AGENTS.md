# AGENTS.md — website/（Web 工作区）

> 本文件仅约束 `website/` 下的 pnpm workspace。仓库根的 AGENTS.md 约束 Flutter 应用（l10n/Drift/provider 等规则在此**不适用**）。

## 前置

- 仓库根是 Flutter 应用：workspace 元数据全部在 `website/` 内，**pnpm 操作一律在 `website/` 下执行**，绝不越界到仓库根。
- 包管理：pnpm。workspace 根 = `website/pnpm-workspace.yaml`（patterns: `apps/*`, `packages/*`）。
- 技术栈：Svelte 5 + Vite / SvelteKit（+ `adapter-static`）+ Tailwind 4 + TypeScript（严格模式）。

## 常用命令

```bash
cd website
pnpm install          # 安装全部（锁文件只有一份：website/pnpm-lock.yaml）
pnpm -r check         # svelte-check（所有包）
pnpm -r test          # 各包测试（apps/helper: e2e + compat）
pnpm -r build         # 静态构建所有包
```

## 新增包

- 应用放 `apps/`；可复用处理逻辑放 `packages/`（**纯 TS、零 DOM**，如备份解析/迁移/兼容/找回核心）。
- 决策记录走 `website/docs/adr/`（独立编号；请勿并入仓库根 `docs/adr/`——那里只放 Flutter/仓库级决策）。
- 术语与边界以 `website/CONTEXT.md` + 根 `CONTEXT-MAP.md` 为准。

## 硬边界（根 `docs/adr/0053`）

- **备份处理（迁移/兼容/恢复）必须纯浏览器端**：任何包不得引入将用户备份数据（聊天记录、settings.json、密钥等）上传的代码路径。
- 后端（若存在）只承载公共只读数据（release 元数据/公告），永不接收用户备份或用户输入。
- 若某包产出为 `assets/web_chat/`（Web 对话壳）构建产物（Phase 3）：产物提交但**禁手改**（与 `*.g.dart` 同一纪律），交付说明中写明构建命令。

## 提交纪律

- `dist/`、`node_modules/`、`.svelte-kit/`、`.netlify/` 不入库（根 `.gitignore` + `website/.gitignore` 已覆盖）。
- 修改 `packages/core` 或格式相关代码：必须跑 `pnpm -r test`（e2e + compat 全覆盖）。
