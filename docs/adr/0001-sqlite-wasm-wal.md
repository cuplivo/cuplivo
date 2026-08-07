# 0001: 用官方 sqlite-wasm（WAL 回放）而非 sql.js 读取 RikkaHub 数据库

RikkaHub 的 Room 数据库默认 WAL 模式，备份 zip 内 `rikka_hub-wal` / `rikka_hub-shm` 可选伴生；若应用退出未 checkpoint，最近事务只存在于 WAL 中。为遵循"保真数据"原则，选型官方 `@sqlite.org/sqlite-wasm`（VFS 实现 `-shm` 共享内存语义，可回放 WAL），弃用更省事的 sql.js（不支持 WAL，会丢近期数据）。代价：库体 ~400KB（brotli）、需在迁移工具中 lazy-load，且 VFS 只能在浏览器环境（`https`）下完整工作。

考虑过 wa-sqlite（同支持 WAL 但社区 API 较杂）与 OPFS 变体，最终以官方构建为准。WAL 打开失败时优雅降级：只读主库并在迁移报告中警告。
