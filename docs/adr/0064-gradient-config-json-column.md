# ADR-0064: Assistant Gradient Config Stored as a Single JSON Column (渐变配置单 JSON 列)

Status: accepted

助手新增 5 个渐变字段（`useGradientBackground` / `gradientBackgroundAnimated` / `gradientBackgroundPhase` / `gradientBackgroundOffsetX` / `gradientBackgroundOffsetY`，见 ADR-0063）。上游 Kelivo 把整个助手序列化成 JSON payload 存储，因此新增字段零迁移；Cuplivo 的 `assistant_rows` 是规范化列表（标量一字段一列、结构/集合走 JSON 列），无论哪种方案都必须做一次 schema 迁移。本 ADR 记录选择「单 JSON 列」而非「5 个规范化列」的取舍。

## Decision

- **单列** `gradient_background_json TEXT NOT NULL DEFAULT '{}'`，承载 5 个 wire 键（与 `Assistant.toJson` 同名），schema **v24**。
- **编解码单点**放在模型上：`Assistant.gradientBackgroundToJson()` 产出 blob；`Assistant.decodeGradientBackgroundStorage(String?)` 解码，非法/空/非对象 blob 走 `debugPrint` + 默认值（绝不抛出）。两个 row mapper（`ChatDatabaseRepository._assistantFromRow`、`ProactiveCareMessageFlow._assistantFromRow` 镜像）共用该 codec，杜绝镜像漂移。
- **mapper 展开顺序**：blob 先展开、列派生键后写，损坏 blob 中的重复键永远不能覆盖 `id`/`name` 等真实列。
- **同步义务**（AGENTS.md §3.20）：除表定义/迁移外，必须同时更新 heal 集合 `_healSchemaIfNeeded`、两个 row mapper、`schema_heal_discoverable_test.dart` 的 v23→v24 迁移用例与「v24 缺列自愈」用例；`Assistant.toJson/fromJson/copyWith` 及备份 `assistants_v1`（`_mergeAssistantMaps` 是泛型 map 合并，新键自动流过）保持不变。
- **值归一化仍由 `Assistant.fromJson` 单点负责**：phase 非有限或 < 0 回退 `7.0`；offset 非有限回退 `0`、有限值 clamp 到 `[-1, 1]`。DB blob 不是第二真相，只是存储格式。

## Compatibility (兼容性)

- **旧行/旧备份**：无列时迁移/自愈补列并得到 `'{}'` → 5 个字段取默认值（渐变关、动画开、相位 7.0、偏移 0）；旧 ZIP 无这些 JSON 键同样取默认。不崩、不丢。
- **新→旧**：新构建写出的备份 JSON 多 5 个顶层键，旧构建 `fromJson` 忽略未知键；blob 列只存在于新构建的 SQLite。
- **非有限/越界导入**：`gradientBackgroundPhase` 为 `Infinity`/负数 → 7.0；offset 为 `NaN` → 0，越界 → clamp 到 `[-1, 1]`。
- **演化**：未来渐变参数可直接进 blob，无需再开 schema 迁移；代价是 SQL 层不可查询/索引（本功能无此类需求）。

## Considered (rejected)

- **5 个规范化列**（初版计划）：与本表「标量一字段一列」惯例一致、SQL 可读；但迁移仪式（5×`addColumn` + heal + 测试）更重，且渐变参数预期会继续演化。经显式决策选择单 blob；代价是偏离规范化惯例，以本 ADR 记录。
- **复用 `preference_rows` KV**（按助手 id 造键）：把实体字段挪出实体表，破坏单一事实来源，备份/LAN 合并语义割裂（assistant 随 chats 位、KV 随 settings 位），拒绝。
- **塞进现有 `background` 字符串**（如特殊前缀编码）：解析脆弱、与图片路径语义混淆、旧构建会把它当图片路径，拒绝。
- **重写 `assistant_rows` 为整行 JSON payload（对齐上游）**：改动面最大、需要全表数据迁移，与当前 main 的规范化方向相反，拒绝。
