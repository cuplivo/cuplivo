# 0004: Cuplivo v4.0.0 重定基线到上游 Kelivo

> 本 ADR 记录 Cuplivo v4.0.0 将代码基线从旧 fork 线（`cuplivo` → `ee54b508`，v3.2.1+40）重放到上游 Kelivo `915a8b1d`（v1.2.7+76）的决策与执行纪律。它取代旧线的一切演进承诺（含旧线 ADR-0067 的后续效力：**superseded by 本 ADR**，其结论仅对 v3.x 存档线继续成立）。

## 决策

- **重放（replay），永不整包 merge**：上游栈作为新基线，fork 功能以 cherry-pick/适配方式逐个重放其上；全程禁止 `git merge upstream/master` 与 `-X ours/theirs`。每个功能保留 fork 血统语义（提交信息详述谱系与适配点），但实现服从新栈的架构纪律（drift schema、Provider、列序纪律、schema_migrations 配方）。
- **基线锁定**：`upstream/master` = `915a8b1d`（2026-09-17）。产物命名契约 `Cuplivo_<platform>_<version>_<abi/ext>` 与应用 ID `com.cup11.cuplivo` 不变。
- **数据纪律**：旧库（Hive）迁移前永不删除；迁移走 pre-migration copy → 校验 → 回滚路径。首启数据迁移（P3）覆盖 schema v1→v6 全链。
- **v6 schema 增量**：v4 回放（回复/群聊/OCR+文档/Ta 的来信）与 v5（多 AI 对比 subgroupId/contextTokens）全部并入 schema v6 一次性交付——v6 从未发布，无 v7 债务。
- **品牌基座**：包名/品牌补丁永远是重放序列的第一个独立提交；`kelivo_*` MCP 工具名、`@kelivo/*`、`kelivo-file://`、`kelivo_backups` 前缀、 psycheas.top URL、备份载荷 `appName: 'Kelivo'` 基线值等**保持原样的残留按设计保留**（互操作性），不作"补全改写"。

## 原因

- 旧 fork 线与上游漂移 3 个月（merge base `c8c9ff37`，2026-06-22），merge 代价已高于重放。
- 上游同期完成了 Hive→drift 的数据库迁移、schema 治理与备份可移植性——这些是旧线缺失的地基，重放次序（地基→功能）避免了在旧线上重复实现。
- 重放而非重写：保留 fork 全部产品语义（增量备份/LAN 同步/世界书分组/多 AI 对比等），只换实现地基。

## 代价

- 重放窗口内 fork 独有 UI 细节以「最简端到端版」先行（如多 AI 的单选加模型），打磨项单列跟进。
- 已接受损失：回收站/墓碑（trash/tombstones）旧数据不迁移；LAN 同步历史在 v4 重置（增量备份引擎全量重设计）。
- 测试基线：17 项上游 auth 失败（claude_oauth 10 + provider_oauth 7）与 root 环境 chmod 失败为**预先存在**，发布门只看"无新增失败"。

## 后果

- v4.0.0 起单一主线 = 上游栈 + 重放功能；`cuplivo` 分支转存档/LTS。
- 后续上游跟进沿用同一 ADR 纪律：锁基线→重放→文档三件套（本 ADR 增补、README 特性表、CHANGELOG）。
