# Cuplivo v4.0.0 数据迁移指南

> 面向从 v3.x（`cuplivo` 线，≤ v3.2.1+40）升级到 v4.0.0 的用户。决策背景见 `website/docs/adr/0004-v4-rebaseline-upstream.md`。

## 升级路径总览

v4 换了数据库地基：v3.x 的 Hive 数据箱在**首次启动**时迁移到上游栈的 SQLite（Drift），随后走 `SchemaMigrations` 链到 schema v6。

```
v3.x Hive 箱 ──首启迁移──▶ SQLite v1 ──迁移链──▶ v2 ▶ v3 ▶ v4 ▶ v5 ▶ v6
```

## 安全纪律（实现保证，非建议）

- **旧数据永不先删**：迁移开始前先落 pre-migration copy；任何一步失败，副本回滚原位，下一次启动重试。
- 迁移后的库通过原始结构校验（表/列完全匹配）才被接纳；校验失败即回滚。
- 全程无云端参与：迁移只发生在本机。

## 迁移内容

- 会话、消息（含分段/推理/工具调用部件）、助手、模型配置、世界书（v4 起含分组标签）、快捷短语、搜索/TTS 服务、MCP 服务器、设置。
- v4 新 schema 字段（回复 quote、群聊表、多 AI `subgroupId`/`contextTokens`）对旧数据一律取空/默认值。

## 已接受的损失（不会迁移）

| 项 | 说明 |
|---|---|
| 回收站/墓碑 | v3 的 trash/tombstones 不迁移；升级前如需找回，请先在 v3.x 内恢复。 |
| 局域网同步历史 | v4 的增量备份引擎是全量重设计，LAN 同步状态重新建立。 |

## 建议

1. 升级前在 v3.x 内做一次完整备份（导出文件永久有效，v4 的恢复入口可读旧格式）。
2. 首启迁移期间不要强杀进程；失败无副作用，重启即重试。
3. 如需回退 v3.x：保留 `cuplivo` 存档分支构建；迁移不破坏旧 Hive 箱的原始文件。

## 开发者参考

- 迁移引擎：`lib/features/migration/hive_to_sqlite_migration_service.dart`（Hive→SQLite v1）；`lib/core/database/schema_migrations.dart`（v1→v6 链与加版流程）。
- 每级 schema 的冻结快照：`drift_schemas/app_database/drift_schema_vN.json`；测试侧生成物在 `test/core/database/generated_schema/`。
- 测试证据：`test/core/database/schema_migrations_test.dart` 覆盖 1→6 全链迁移、首装建库、未发布版本拒绝。
