# ADR-0010: 局域网同步采用两次往返协议 + since 增量复用

- **日期：** 2026-07-29
- **状态：** 已采纳

## 上下文

需要在不依赖云存储（WebDAV / S3）的前提下，在两台局域网设备间同步聊天数据。
现有基础设施：增量备份 zip（`since` 时间戳过滤，`cuplivo_incr_` 前缀）+ merge restore（按 ID 去重）。

核心约束：
- 依托 zip 传输，不引入新的序列化格式
- 每端均可开启 HTTP 服务（`dart:io HttpServer`，单次生命周期）
- 不更新上次备份时间（同步与常规备份时间线独立）

## 决策

### 协议：两次 HTTP 往返

| 步骤 | 方向 | 路径 | 内容 |
|------|------|------|------|
| 1 | A → B | `POST /sync/plan` | `{conversations: {convId: [msgIds...]}, assistantIds: [...]}` |
| 2 | B → A | 200 Response | sync plan（三态 + 缺失 assistant + `since` 时间戳） |
| 3 | A → B | `POST /sync/exchange` | A 的增量 zip（multipart） |
| 4 | B → A | 200 Response | B 的增量 zip |

传输完成后双方各自 merge restore + restart。无跨端 ACK。

选择两次往返而非单次（A 直接把 zip 推过去）的原因：
- B 需要先知道 A 的索引才能决定自己要回传什么
- 单次往返要么 B 无从得知 A 缺什么，要么 A 必须预先打包全量（浪费）
- 两次往返里第二次的 request/response 各带一个 zip，正好实现双向传输

### 比对粒度：per-conversation messageId 列表

放弃"全局单条最近公共消息"概念。消息在数据库中按 `messageOrder`（conversation 内整数序号）排序，无全局时间线。

发送方提交 `{convId: [msgIds...]}`（按 `messageOrder` 排列），接收方对每个双方共有的 conversation 找最后一个共有 messageId——即该 conversation 的分叉点。

三态判定：
- 仅 A 有增量 → B 导入 A 的 zip
- 仅 B 有增量 → A 导入 B 的 zip
- 双方都有不同增量 → **fork**（v1 检测但不处理，未来保留两份）

### zip 打包：复用 `since` 增量备份代码路径

per-conversation messageId 比对用于 **sync plan 和 fork 检测**（协议层），实际 zip 打包仍走 `DataSync.prepareBackupFile(incremental: IncrementalBackupConfig(since: ...))`。

`since` 取所有分叉点中最早的 `message.timestamp`。这会 over-inclusive——可能包含接收端已有的消息/文件——但 merge restore 按 ID 去重，结果正确。选择 over-inclusive 而非 per-conversation 精确打包的原因：复用现有代码路径，零新增打包逻辑。

文件（upload / images / avatars / fonts / skills）由现有 `since` 过滤（`lastModifiedSync >= since`）自动覆盖。

### Assistant 同步与设置同步（v2 修订）

v1 的 `includeSettings: false` 意味着 zip 里没有 settings.json，助手/供应商等设置数据实际不会传输——sync plan 里的 assistant set difference 只出现在计划中，无法落地。

**v2 修订（issue #476）**：增量 zip 改为 `includeSettings: true`。助手随 settings.json 的 `assistants_v1` 全量携带，恢复端走标准 settings 合并（`mergeableKeys` 并集 + `_mergeAssistantMaps` 字段级合并，avatar/background 本地优先）。sync plan 中的 assistant set difference（`missingAssistantIds` / `remoteMissingAssistantIds`）保留为计划信息，不再承担传输职责。设备绑定键（窗口几何、输入草稿、热键、OAuth token）由 `SharedPreferencesAsync._localOnlyKeys` 排除，永不跨设备。双端各自打包 → 各自 merge → 配置收敛为并集。

### 不更新上次备份时间

`BackupReminderProvider.lastBackupTime` 不受同步影响。下次常规增量备份仍从上次常规备份的时间点开始。同步与备份完全独立。

### 安全：4 位 PIN

服务端启动时随机生成 0000–9999 PIN，显示在 UI 上。每个 HTTP 请求需携带 `X-Sync-Pin` header，不匹配返回 401。PIN 不持久化，随 server 关闭失效。

### 端口与生命周期

默认端口 `9527`，冲突时 fallback 随机端口（`ServerSocket.bind(0)`），UI 始终显示实际值。单次生命周期：同步完成 → apply → restart → server 随进程消亡。

## 权衡

### 为什么不用 mDNS 自动发现

v1 手动输入 IP:port。局域网同步是低频操作，不值得为发现协议写额外代码。UDP 广播在部分路由器/防火墙下不可靠，增加 debug 面。未来按需追加。

### 为什么 v1 不处理 fork

fork 保留两份需要新的数据模型（`forkedFromId` 字段 + schema migration）和写入策略。协议层已具备 fork 检测能力（messageId 比对），未来只需改写入策略，不需要动协议或 zip 格式。

### 为什么无鉴权不做 v1

最终加入 4 位 PIN。防的是"室友/同事误连"，不是防攻击者。完整鉴权（TLS / token 交换）对局域网场景 overkill。

## 影响

- 新增 `lib/core/services/sync/lan_sync_server.dart`（HTTP server + PIN 生成）
- 新增 `lib/core/services/sync/lan_sync_client.dart`（发起方逻辑）
- 新增 `lib/features/backup/widgets/lan_sync_section.dart`（UI 入口，复用现有 backup 页面）
- 复用 `DataSync.prepareBackupFile(incremental:)` 和 `_restoreFromBackupFile(mode: merge)`
- 复用 `ChatDatabaseRepository.getMessageIdsSync(convId)` 和 `getAllAssistants()`
- 无 schema 变更（v1 不处理 fork）
- 无 ARB 变更以外的 i18n 影响（新增的 user-visible 文本需走标准 4 文件同步流程）

## 追加：二维码 / 链接与最近地址记忆（2026-09-10）

不做自动发现的前提下，为降低手动输入成本追加：

- 服务端对话框展示二维码与可复制链接（`cuplivo-lansync:v1:` 前缀 + JSON，携带全部 LAN 地址、端口与本次 PIN，与屏幕明文 PIN 同级）。
- 客户端扫码（移动端）或粘贴链接（桌面端）自动填充；多地址按顺序重试，PIN 错误不重试。
- 客户端记住最近 5 个成功连接的 `host:port`（`lan_sync_recent_endpoints_v1`，localOnly，永不备份/迁移），打开时自动预填最近一条。

协议（`/sync/plan`、`/sync/exchange`）未变更；mDNS / UDP 广播仍不做。