# 0003: 备份格式层抽取为 `packages/core`（helper-core），helper 只留 UI 壳

`apps/helper/src/lib/` 的格式管线（迁移/兼容/恢复核心）与 UI 重组为工作区双包：核心逻辑进 `packages/core`（包名 `helper-core`），`apps/helper` 只剩导航壳、页面与 `ui/` 组件。目标：官网（`apps/website`）与 tool 应用共享同一份格式实现。

## 决策

- `helper-core` 是 **source-only 包**（无 build，`exports` 直接指向 `./src/*.ts`），由消费方 bundler（Vite/esbuild）转换；`pnpm -r build` 自动跳过无 build script 的包。
- 包名不挂 scope；`apps/helper` 与（未来的）`apps/website` 均以 `workspace:*` 引用。
- exports 走**显式子路径**（`./migrate` `./compat` `./compat/report` `./report` `./zip` `./kelivo/recovery`），不用 `./*` 通配，避免意外暴露入口与名称遮蔽。
- 回归网随包走：`scripts/e2e-test.ts` + `scripts/compat-test.ts` 移入 `packages/core`，以 `tsx` 运行（`pnpm -r test`）；脚本**不在 tsc 类型检查面**（与抽取前一致，helper 时代即排除）。
- `jszip`、`@sqlite.org/sqlite-wasm` 依赖随代码迁到 core；helper 仅剩 `jszip` 作为 devDependency（页面只剩 `import type`）。app 侧 `vite optimizeDeps.exclude: ['@sqlite.org/sqlite-wasm']` 按模块 id 排除，与声明方无关，两条消费路径均保留。
- 零 DOM 界线的例外：`zip.ts` 的 `downloadBlob/downloadText` 是 core 内唯一 DOM 触点（`document.createElement`），按「原样迁入」执行——core tsconfig 因此保留 DOM lib；core 包内其余代码零 DOM。

## 原因

- 格式管线（解析/迁移/兼容/找回）是「纯前端硬边界」下唯一真正的可复用逻辑（根 ADR-0053）：官网工具页与现有 tool 应用需要的**是同一份实现**，不是 UI 层重新调用 Web 服务（后端只承载公共只读数据）。
- 抽取边界以现有 import 图为据：格式层没有任何来自 `ui/`、`view*` 的引用，切断点天然干净。
- tsx 下测试无需构建产物，source-only 方案最小且可直接跑通。

## 代价

- 消费方必须能解析 `exports` 指向的 `.ts`（TS `moduleResolution: bundler` + Vite 链接包源文件解析）——此为 monorepo source package 常规前提；e2e/compat 测试即为保护。
- core 引入 DOM lib 属类型层妥协（两个下载 helper），严格零 DOM 需要后续把 download 辅助单独拆出（当前无必要）。
- 「迁移/兼容转出的 zip 带 download 辅助」使 core 在理论上是「纯浏览器友好」，非严格 Node-only——Node 测试不调用 downloadBlob，不受影响。
