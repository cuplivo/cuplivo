# 0001: 用官方 sqlite-wasm + 纯 JS WAL checkpoint 读取 RikkaHub 数据库

RikkaHub 的 Room 数据库默认 WAL 模式，备份 zip 内 `rikka_hub-wal` / `rikka_hub-shm` 可选伴生；若应用退出未 checkpoint，最近事务只存在于 WAL 中。

## 决策

使用官方 `@sqlite.org/sqlite-wasm` 在浏览器内查询；**打开前**用纯 JS（`src/lib/rikkahub/wal.ts`）将已提交 WAL frames 合入主库字节，并把 header journal 模式改为 DELETE，再交给 sqlite-wasm（create_file 或 deserialize）。

## 原因

sqlite-wasm 可用 VFS（unix / unix-excl 等）**无 xShmMap**，直接打开 WAL 模式库会 `SQLITE_CANTOPEN`。官方文档要求 exclusive locking 也仍依赖 VFS 声明支持 SHM。OPFS + COOP/COEP 可部分缓解，但部署约束重，且非所有环境可用。

纯 JS checkpoint 保真已提交帧（salt 匹配 + frame checksum），与 native `PRAGMA wal_checkpoint` 结果一致；未提交尾帧丢弃。无 wal 或校验失败时降级为仅主库 + 迁移报告警告。

## 代价

- 大库需在内存中复制一份 prepared bytes（~主库大小）
- 需自行维护 WAL 格式解析（端序 / checksum 规则对齐 sqlite wal.c）

## 弃用方案

- sql.js：不支持 WAL，会丢近期数据
- 直接 db+wal 交给 wasm：CANTOPEN
- 强制 OPFS：需要 COOP/COEP，兼容性差
