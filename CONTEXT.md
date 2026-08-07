# Kelivo Helper

面向 Kelivo 用户的纯前端工具集合：解析 Kelivo / RikkaHub 的备份导出包，提供迁移、找回、修复能力。所有处理均在浏览器本地完成，数据不出浏览器。

## Language

**Kelivo**:
一个聊天应用，导出格式为 zip（`settings.json` + `chats.json` + 媒体目录）。本项目的服务对象与目标格式基准。

**RikkaHub**:
与 Kelivo 同源（导出包结构相似、UI 同族）的聊天应用，导出格式为 zip（`settings.json` + `rikka_hub.db` SQLite + WAL/SHM + 媒体目录）。settings.json 是 kotlinx.serialization 序列化的嵌套 `Settings` data class（camelCase），**内嵌 assistants、providers、mcpServers 等全量定义**；数据库只存会话/消息等运行时数据。

**迁移（Migration）**:
RikkaHub 备份 → Kelivo 可恢复备份包的唯一途径。原则：保真数据 + 最小猜测 + 迁移报告。

**迁移报告（Migration Report）**:
迁移产物附带的可下载清单，记录丢弃项、未识别 modelId、占位助手等，供用户留档。

**占位助手（Placeholder Assistant）**:
助手定义丢失时（如迁移或配置损坏），按 chats.json 中出现过的 assistantId 生成的默认配置助手，命名如 `Found 01`。迁移的助手层以**真实还原**为主（RikkaHub settings.json 含全量定义），占位仅兜底未定义的 assistantId（如默认助手 UUID 未出现在 assistants 列表时）。

**助手找回（Assistant Recovery）**:
扫描 chats.json 中缺失于 assistants_v1 的 assistantId，重建占位助手并写回 settings.json，使历史对话恢复可访问。是**恢复工具**的两项能力之一。

**对话找回（Conversation Recovery）**:
conversation 条目损坏/丢失但 messages 幸存时，按 ChatMessage.conversationId 分组重建会话壳并**挂载到恢复助手**。代价：title、isPinned 等元数据丢失，原助手归属不可恢复。是**恢复工具**的两项能力之一。

**恢复工具（Recovery Tool）**:
合并**助手找回**与**对话找回**的单一工具：上传 Kelivo 备份 zip，一次扫描完成"缺失助手重建 + 孤儿消息重建会话壳 + null 会话挂载"。

**恢复助手（Recovery Assistant）**:
名为"恢复的会话"的共享占位助手，是**会话壳**与 `assistantId` 为 null 的会话的挂载点。孤儿消息无助手归属信息（ChatMessage 不含 assistantId），无法推断原助手，故单一共享而非逐个创建。

**墓碑（Tombstone）**:
deleted.json 中的删除记录（`{entityType, id, deletedAt}`），仅含 id 与时间戳、无内容——已删对话物理不可恢复，文档明示。

**会话壳（Conversation Shell）**:
由幸存消息重建的会话最小结构：id、title（取首条 user 消息）、messageIds、时间戳。**必须挂载到恢复助手**——`assistantId: null` 的会话在 Kelivo UI 中不可见。

## Relationships

- 一次**迁移**产生一份**迁移报告**；迁移中助手层使用**占位助手**
- **恢复工具**包含**助手找回**与**对话找回**两项能力，作用于 Kelivo 备份包，是迁移之外的独立工具
- **会话壳**与 `assistantId` 为 null 的**会话**均挂载到**恢复助手**
- **墓碑**的存在意味着"已删对话不可恢复"，是**对话找回**的边界
- **ChatMessage.conversationId** 是 message → conversation 的反向引用，**对话找回**依赖它分组重建**会话壳**

## Example dialogue

> **Dev:** "用户说对话被删了，能用 deleted.json 找回来吗？"
> **Domain expert:** "不行——deleted.json 只有墓碑（id + 删除时间），没有内容。只有 conversation 条目损坏但消息还在时，才能用对话找回重建会话壳。"
>
> **Dev:** "重建的会话壳 assistantId 设 null 就行了吧？"
> **Domain expert:** "不行——assistantId 为 null 的会话在 Kelivo UI 里不可见，必须挂载到恢复助手（'恢复的会话'占位助手）。孤儿消息没有助手归属信息，所以所有会话壳共享这一个助手。"

## Flagged ambiguities

- "对话找回"最初被理解为"从 message 重建 conversation"，曾被误认为不存在该通路——实际 `ChatMessage.conversationId` 反向引用存在，通路可用
- "转化"曾被用作 RikkaHub 工具的目标动词——已定为 **迁移**，目标是 Kelivo 可恢复备份包（唯一途径）
- RikkaHub settings.json 曾被记录为"仅 WebDavConfig"——**错误**；又一度被误记为"与 Kelivo 同构的扁平 prefs 快照"——**也错误**；实为 kotlinx.serialization 序列化的嵌套 `Settings` data class，内嵌全量助手/提供商定义
- 会话壳曾定 `assistantId: null`——**错误**：null 会话在 Kelivo UI 不可见，须挂载到**恢复助手**
- "助手找回/对话找回"两个页面曾计划独立——已合并为单一**恢复工具**入口
