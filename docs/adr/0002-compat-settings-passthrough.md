# 0002: 兼容工具的 settings.json 采用「近逐字直通 + 助手层手术」，而非迁移的白名单映射

兼容（Kelivo v1.2.0 → Cuplivo v2.7.1，`src/lib/compat/`）与迁移（RikkaHub → Kelivo，`src/lib/migrate/`）两条管线的设置层策略**故意相反**：迁移逐键白名单映射（新键默认丢弃入报告），兼容近逐字直通（除 `assistants_v1` 手术外全键保留）。

## 决策

`src/lib/cuplivo/settings.ts`：输出 settings.json = 源 settings.json 逐字复制，仅做五处有限手术：

1. `presetMessages` 字符串 → 内联数组（Kelivo v1.2.0 输出字符串，Cuplivo `PresetMessage.decodeList` 只接受数组，直通会**静默清空**预设消息）
2. `allowPastConversationRecall` → 合成 `enableRecentChatsReference`（Cuplivo 只认旧名，直通会静默丢失回忆开关）
3. 记忆降级：`memory_entries_v1`（新版 MemoryEntry）→ `assistant_memories_v1`（旧版），详见 `src/lib/compat/memory.ts`——Cuplivo v2.7.1 只读旧键，直通 = 新版记忆整体静默丢失（issue cuplivo/cuplivo#543）；转换后移除新键
4. 搜索服务：`apiKeys` 字符串池 → ApiKeyConfig 列表（Kelivo 存 `List<String>`，Cuplivo `readKeys` 强转 Map 直通即崩溃，cuplivo/cuplivo#453 镜像问题）；主 key 优先入池，其余字段 Cuplivo fromJson 自补
5. Kelivo 独有字段（autoOrganizeMemory 等）原样保留——Cuplivo 忽略未知键，不崩溃

同理，`chats.json` 版本常量锁定为 1（`src/lib/cuplivo/chats.ts`）：Cuplivo 导入端从不读版本字段，而 Kelivo 旧版导入端只接受 version 1、v2 抛 `FormatException('version')`——上游已同因锁定（cuplivo/cuplivo#453）。`groupChats` 等字段照常保留。

图像键（`image_upload_quality_v1` 等）保持 Kelivo 形态**不做预翻译**，交给 Cuplivo 恢复时的 `KelivoImageSettingsMapper.translateFromUpstream`（其翻译含 1568px 长边近似，属 Cuplivo 自身语义）；`ocr_enabled_v1` 同理。

## 原因

- 保真数据是兼容的裁定原则：两格式同源同族（settings.json 都是扁平 prefs 快照），白名单映射会系统性丢弃新键，违背保真。
- 手术只针对源码核实的**静默丢失**点（Cuplivo fromJson 默认值/忽略未知键行为），共 4 类；其余键 Cuplivo restore 均宽容写入。
- 与迁移形成对照：RikkaHub settings 是 kotlinx 嵌套结构，无「直通」可言，白名单是唯一可行解。

## 代价

- 输出 settings.json 可能携带 Cuplivo 不认识的键（如 `restore_*` 外的未来键）；Cuplivo 恢复时忽略、重导出时丢失——数据在兼容产物中保真，但 Cuplivo 重新备份后不保留。
- 未来若 Kelivo 新增键与 Cuplivo 语义冲突，需在 `transformSettings` 增量补手术——每次变更需重新核对两侧 fromJson（kelivo.md 为调研依据）。
