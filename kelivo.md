Now let me check v1.1.17's settings export, zip packing, and model field differences:

One last verification pass on v1.1.17 message/assistant fields:

调研完成（v1.1.17 tag 与当前 v2.6.0 的 `data_sync.dart`、各模型 `toJson` 均已核对）。以下为两版交付物。

---

# v2.6.0 备份格式

## Zip 结构（自然语言）

备份文件命名 `kelivo_backup_YYYYMMDDThhmmss.ffffff.zip`（紧凑 ISO，微秒）。增量备份命名 `cuplivo_incr_YYYYMMDD-HHmmss-ffffff_YYYYMMDD-HHmmss.zip`（导出时间_起始时间），且**强制按 merge 模式恢复**。

Zip 根目录内容：

| 条目 | 是否必选 | 说明 |
|---|---|---|
| `settings.json` | 全量必含 | SharedPreferences 全量快照（JSON 对象） |
| `chats.json` | `includeChats` 时 | 聊天数据，顶层 `version: 2` |
| `deleted.json` | `includeChats` 时（失败可跳过） | 删除墓碑（tombstone），**v1.1.17 无此文件** |
| `skills/` | 恒含（与 includeFiles 无关） | 技能目录，保留相对路径 |
| `upload/` `avatars/` `images/` `fonts/` `workspaces/` | `includeFiles` 时 | 用户文件；`workspaces/` 排除任意以 `.` 开头的路径段（如 `.fetch_cache/`） |

增量备份下：`settings.json` 由 `includeSettings` 控制；目录按文件 mtime ≥ `since` 过滤；`chats.json` 按时间过滤且**组聊（group）消息整体包含、绝不切片**；Director 会话是临时的，从不导出。

## settings.json — 自然语言

顶层为扁平 JSON 对象：`key -> value`，value 类型为 SharedPreferences 原生类型（`string` / `bool` / `number` / `string[]`，JSON 化后无 double 与 int 之分）。键名遵循 `<功能>_v<n>` 约定（如 `theme_mode_v1`、`provider_configs_v1`、`world_books_v1`、`tts_speech_rate_v1`）。

- 导出时排除的本地键（`_localOnlyKeys`，不备份不恢复）：`window_width_v1`、`window_height_v1`、`window_pos_x_v1`、`window_pos_y_v1`、`window_maximized_v1`、`display_chat_font_scale_v1`、`desktop_hotkeys_commands_v1`、`desktop_hotkeys_enabled_v1`、`codex_oauth_v1`、`grok_oauth_v1`。
- **v2.6.0 特有**：导出前注入 `assistants_v1`（`Assistant` 数组 JSON 编码后的字符串）——助手已迁移到 SQLite，此键由导出器写回、恢复时取出并移除。恢复时还特殊处理旧版 `ocr_enabled_v1`（转为各助手的 `ocrMode`，绝不回写 prefs）。
- 合并恢复（merge）时，以下键按数组/对象合并去重：`assistant_memories_v1`、`provider_configs_v1`、`pinned_models_v1`、`providers_order_v1`、`mcp_servers_v1`、`provider_groups_v1`、`provider_group_map_v1`、`provider_group_collapsed_v1`、`search_services_v1`、`assistant_tags_v1`、`assistant_tag_map_v1`、`assistant_tag_collapsed_v1`；其余键仅在本地不存在时写入。

## chats.json / deleted.json — TypeScript Schema

```ts
// ===== v2.6.0 =====

/** ISO 8601 字符串（如 2026-07-03T12:34:56.123456） */
type IsoDateTime = string;

interface ChatsFileV2 {
  version: 2;
  conversations: Conversation[];
  messages: ChatMessage[];
  /** 仅含 role === 'assistant' 且确有事件的消息 */
  toolEvents: Record<string, ToolEvent[]>;
  geminiThoughtSigs: Record<string, string>;
  /** v2 新增 */
  groupChats: GroupChat[];
  groupMembers: GroupChatMember[];
}

interface Conversation {
  id: string;
  title: string;
  createdAt: IsoDateTime;
  updatedAt: IsoDateTime;
  messageIds: string[];
  isPinned: boolean;
  mcpServerIds: string[];
  assistantId: string | null;
  /** v2 新增 */
  parentConversationId: string | null;
  truncateIndex: number;              // -1 = 不截断
  versionSelections: Record<string, number>; // groupId -> 选中版本
  summary: string | null;
  lastSummarizedMessageCount: number;
  chatSuggestions: string[];
  /** v2 新增；'normal' | 'group' */
  conversationKind: string;
}

interface ChatMessage {
  id: string;
  role: 'user' | 'assistant';
  content: string;
  timestamp: IsoDateTime;
  modelId: string | null;
  providerId: string | null;
  totalTokens: number | null;
  conversationId: string;
  isStreaming: boolean;
  reasoningText: string | null;
  reasoningStartAt: IsoDateTime | null;
  reasoningFinishedAt: IsoDateTime | null;
  translation: string | null;
  reasoningSegmentsJson: string | null;   // 多段思考 JSON 字符串
  groupId: string | null;
  /** v2 新增：Multi-AI 并行分支 */
  subgroupId: string | null;
  version: number;
  promptTokens: number | null;
  completionTokens: number | null;
  cachedTokens: number | null;
  durationMs: number | null;
  isPreset: boolean;
  /** v2 新增：组聊发言者助手 id */
  speakerAssistantId: string | null;
}

/** 事件为流式层写出的不透明 JSON，无固定 schema，典型形态如下 */
interface ToolEvent {
  id: string;
  name: string;
  arguments: Record<string, unknown>;
  content: string | null;
  metadata?: Record<string, unknown>;
}

interface GroupChat {
  id: string;
  name: string;
  avatar: string | null;
  conversationId: string;              // 公开转写即 Conversation
  directorModelProvider: string | null;
  directorModelId: string | null;
  directorSystemPrompt: string;
  maxAssistantMessagesPerRound: number; // 默认 3
  assistantDetailInjectionMode: string; // storageValue，如 'end_of_every_user_message'
  assistantDetailInjectionN: number;    // 默认 5
  pendingCapAssistantMessageId: string | null;
  assistantMessagesThisRound: number;
  createdAt: IsoDateTime;
  updatedAt: IsoDateTime;
}

interface GroupChatMember {
  groupChatId: string;
  /** 'user' 表示人类，否则为助手 id */
  memberKey: string;
  assistantId: string | null;
  sortOrder: number;
}

/** 每类型最多 deletedJsonPerTypeCap 条，按 deletedAt 倒序 */
interface DeletedFile {
  [entityType: string]: { id: string; deletedAt: IsoDateTime }[];
}
```

settings.json 中的 `assistants_v1`（v2.6.0 注入 / v1.1.17 原生）是 `Assistant[]` 的 JSON 字符串：

```ts
interface Assistant {
  id: string;
  name: string;
  avatar: string | null;
  useAssistantAvatar: boolean;
  useAssistantName: boolean;
  chatModelProvider: string | null;
  chatModelId: string | null;
  temperature: number | null;
  topP: number | null;
  contextMessageSize: number;          // 默认 64
  limitContextMessages: boolean;
  streamOutput: boolean;
  thinkingBudget: number | null;
  maxTokens: number | null;
  systemPrompt: string;
  messageTemplate: string;             // 默认 '{{ message }}'
  searchEnabled: boolean;
  mcpServerIds: string[];
  localToolIds: string[];
  /** v2 新增 */
  skillIds: string[];
  background: string | null;
  customHeaders: { name: string; value: string }[];
  customBody: { key: string; value: string }[];
  enableMemory: boolean;
  /** v2 新增；'injection' | 'tool' */
  memoryMode: string;
  enableRecentChatsReference: boolean;
  recentChatsSummaryMessageCount: number;
  /** v2 新增 */
  memoryRecordPrompt: string;
  presetMessages: { id: string; role: string; content: string }[];
  regexRules: AssistantRegex[];        // {id,name,pattern,replacement,enabled,...}
  /** v2 新增（Ta的来信等） */
  enableProactiveCare: boolean;
  proactiveCareNextMessageAt: IsoDateTime | null;
  proactiveCarePrompt: string;
  proactiveCareDecisionPrompt: string;
  docxMode: string;                    // 'extract'|'direct'|'discard'
  pdfMode: string;
  otherOfficeMode: string;
  ocrMode: string;                     // 'auto'|'always'|'never'
  enableTimeInjection: boolean;
  discoverable: boolean;
  handoffId: string | null;
  handoffDescription: string | null;
  createdAt: IsoDateTime;
  updatedAt: IsoDateTime;
}
```

---

# v1.1.17 备份格式

## Zip 结构差异（自然语言）

- 命名：`kelivo_backup_YYYY-MM-DDTHH-mm-ss.ffffff.zip`（短横线分隔 ISO）。
- 顶层：`settings.json`、`chats.json`（顶层 `version: 1`）、`upload/`、`avatars/`、`images/`、`fonts/`（后四者受 `includeFiles` 控制）。
- **没有** `deleted.json`、`skills/`、`workspaces/`、无增量格式。
- `settings.json` 为纯 prefs 快照，**无注入**——此版本助手仍存于 SharedPreferences，`assistants_v1` 是快照中真实存在的键（且属于 mergeableKeys，与 `provider_configs_v1` 等相同）。
- 恢复时无 `ocr_enabled_v1` 特殊处理；`chats.json` 解析不读 `groupChats`/`groupMembers`/`deleted.json`。

## chats.json — TypeScript Schema

```ts
// ===== v1.1.17 =====
interface ChatsFileV1 {
  version: 1;
  conversations: ConversationV1[];
  messages: ChatMessageV1[];
  toolEvents: Record<string, ToolEvent[]>;
  geminiThoughtSigs: Record<string, string>;
}

interface ConversationV1 {
  id: string;
  title: string;
  createdAt: IsoDateTime;
  updatedAt: IsoDateTime;
  messageIds: string[];
  isPinned: boolean;
  mcpServerIds: string[];
  assistantId: string | null;
  truncateIndex: number;
  versionSelections: Record<string, number>;
  summary: string | null;
  lastSummarizedMessageCount: number;
  chatSuggestions: string[];
  // 无 parentConversationId、无 conversationKind
}

interface ChatMessageV1 {
  id: string;
  role: 'user' | 'assistant';
  content: string;
  timestamp: IsoDateTime;
  modelId: string | null;
  providerId: string | null;
  totalTokens: number | null;
  conversationId: string;
  isStreaming: boolean;
  reasoningText: string | null;
  reasoningStartAt: IsoDateTime | null;
  reasoningFinishedAt: IsoDateTime | null;
  translation: string | null;
  reasoningSegmentsJson: string | null;
  groupId: string | null;
  version: number;
  promptTokens: number | null;
  completionTokens: number | null;
  cachedTokens: number | null;
  durationMs: number | null;
  // 无 subgroupId、无 isPreset、无 speakerAssistantId
}
```

v1.1.17 的 `assistants_v1`（`AssistantV1[]` 的 JSON 字符串）：字段为 v2.6.0 的**子集**——仅含到 `regexRules` 为止的部分（id … presetMessages、regexRules），**无** `skillIds`、`memoryMode`、`memoryRecordPrompt`、`enableProactiveCare`、`proactiveCare*`、`docxMode`、`pdfMode`、`otherOfficeMode`、`ocrMode`、`enableTimeInjection`、`discoverable`、`handoff*`、`createdAt`、`updatedAt`。

---

## 兼容性要点

- v2.6.0 可恢复 v1.1.17 备份（`version: 1` 缺省字段全部有默认值兜底；旧 `ocr_enabled_v1` 映射到 `ocrMode`）；反向不保证。
- `version` 字段在恢复时未参与分支判断，仅作标识。

---

`assistants_v1` 的值 = `jsonEncode(Assistant.toJson() 列表)`——即 JSON 字符串，解析后为对象数组。以下是反序列化后的（序列化前）interface，两版各一：

## v1.1.17 — `AssistantV1`

```ts
interface AssistantV1 {
  id: string;
  name: string;
  avatar: string | null;                 // 路径/URL/base64；null=首字母头像
  useAssistantAvatar: boolean;
  useAssistantName: boolean;
  chatModelProvider: string | null;      // null=用全局默认
  chatModelId: string | null;
  temperature: number | null;            // null=关闭；否则 0.0–2.0
  topP: number | null;                   // null=关闭；否则 0.0–1.0
  contextMessageSize: number;            // 默认 64
  limitContextMessages: boolean;         // 默认 true
  streamOutput: boolean;                 // 默认 true
  thinkingBudget: number | null;         // null=全局默认；0=关
  maxTokens: number | null;
  systemPrompt: string;
  messageTemplate: string;               // 默认 '{{ message }}'
  searchEnabled: boolean;
  mcpServerIds: string[];
  localToolIds: string[];
  background: string | null;
  customHeaders: { name: string; value: string }[];   // 读取时兼容 {key,value}
  customBody: { key: string; value: string }[];       // 读取时兼容 {name,value}
  enableMemory: boolean;
  enableRecentChatsReference: boolean;
  recentChatsSummaryMessageCount: number;             // 默认 5
  presetMessages: { id: string; role: string; content: string }[];
  regexRules: AssistantRegex[];
}
```

## v2.6.0 — `Assistant`（v1 的超集，`AssistantV1 extends` 关系）

```ts
interface Assistant extends AssistantV1 {
  /** v2 新增 ↓ */
  skillIds: string[];                    // 绑定的技能名
  memoryMode: string;                    // 'injection' | 'tool'
  memoryRecordPrompt: string;            // 默认内置秘书提示词
  enableProactiveCare: boolean;          // “Ta的来信”
  proactiveCareNextMessageAt: string | null;   // ISO 8601
  proactiveCarePrompt: string;
  proactiveCareDecisionPrompt: string;
  docxMode: string;                      // 'extract' | 'direct' | 'discard'
  pdfMode: string;                       // 同上
  otherOfficeMode: string;               // 同上
  ocrMode: string;                       // 'auto' | 'always' | 'never'
  enableTimeInjection: boolean;
  discoverable: boolean;                 // 可被转交（handoff）
  handoffId: string | null;
  handoffDescription: string | null;
  createdAt: string;                     // ISO 8601
  updatedAt: string;                     // ISO 8601
}
```

## 公共子结构（两版一致）

```ts
interface AssistantRegex {
  id: string;
  name: string;
  pattern: string;
  replacement: string;
  scopes: ('user' | 'assistant')[];      // 枚举 AssistantRegexScope
  visualOnly: boolean;
  replaceOnly: boolean;
  enabled: boolean;
}
```

序列化注意点（两版相同）：`presetMessages`/`regexRules` 以对象数组内联（非 JSON 字符串）；`customHeaders` 输出 `{name,value}` 形态、`customBody` 输出 `{key,value}` 形态（读取时两种形态都兼容）；v1.1.17 无 `createdAt`/`updatedAt`，导入时以 `DateTime.now()` 兜底。

---

## Settings

**settings.json 本质**：`SharedPreferences` 的完整快照（`lib/core/services/backup/data_sync.dart:2358` 的 `snapshot()`），导出时额外注入 `assistants_v1`（data_sync.dart:949）。以下 10 个键被 `_localOnlyKeys` 排除、**永不出现**在 settings.json 中：`window_width/height/pos_x/pos_y/maximized_v1`、`display_chat_font_scale_v1`、`desktop_hotkeys_commands_v1`、`desktop_hotkeys_enabled_v1`、`codex_oauth_v1`、`grok_oauth_v1`。

以下 TypeScript Interface 覆盖全部可导出字段（顶层为扁平键值映射，所有键均可缺失）：

```ts
// ===== 基础工具类型 =====
type Iso8601 = string;                // ISO-8601 日期字符串
type JsonString<T> = string;          // settings.json 中的原值是 string，decode 后为 T
type ModelRef = string;               // '<providerKey>::<modelId>'（冒号分隔的模型引用）

// ===== settings.json 顶层（SharedPreferences 快照，全部可选）=====
interface SettingsJson {
  // --- 应用/主题 ---
  app_locale_v1?: 'system' | 'en_US' | 'zh_CN' | 'zh_Hant';
  app_launch_count_v1?: number;                  // int
  theme_mode_v1?: 'light' | 'dark' | 'system';
  theme_palette_v1?: 'default' | 'blue' | 'green' | 'purple' | 'yellow' | 'smoky_rose' | 'terracotta' | 'monochrome' | 'doc_theme' | 'custom_dynamic';
  use_dynamic_color_v1?: boolean;
  dynamic_color_seed_v1?: number;                // int；未设置时键不存在

  // --- 助手（旧版，仅导出时注入；SQLite 迁移后正常不存在）---
  assistants_v1?: JsonString<Assistant[]>;
  current_assistant_id_v1?: string;
  ocr_enabled_v1?: boolean;                      // 旧版全局 OCR 开关，迁移后被移除（旧备份中可能残留）

  // --- 供应商/模型 ---
  provider_configs_v1?: JsonString<Record<string, ProviderConfig>>;
  provider_configs_backup_v1?: JsonString<Record<string, ProviderConfig>>; // 迁移前快照，只写不读
  providers_order_v1?: string[];                 // 供应商 key 列表
  pinned_models_v1?: string[];                   // ModelRef 列表
  selected_model_v1?: ModelRef;
  title_model_v1?: ModelRef;
  title_prompt_v1?: string;
  title_generation_thinking_enabled_v1?: boolean;
  ocr_model_v1?: ModelRef;
  ocr_prompt_v1?: string;
  ocr_thinking_enabled_v1?: boolean;
  summary_model_v1?: ModelRef;
  summary_prompt_v1?: string;
  summary_thinking_enabled_v1?: boolean;
  compress_model_v1?: ModelRef;
  compress_prompt_v1?: string;
  compress_thinking_enabled_v1?: boolean;
  translate_model_v1?: ModelRef;
  translate_prompt_v1?: string;
  translate_thinking_enabled_v1?: boolean;
  translate_target_lang_v1?: string;             // 清空时键被移除
  suggestion_model_v1?: ModelRef;
  suggestion_prompt_v1?: string;
  suggestion_thinking_enabled_v1?: boolean;
  suggestion_insert_on_tap_only_v1?: boolean;
  proactive_care_decision_model_v1?: ModelRef;
  proactive_care_l10n_v1?: JsonString<{ defaultConversationTitle: string; carePromptDefault: string; decisionPromptDefault: string; failureNotificationBody: string }>;
  thinking_budget_v1?: number;                   // int；-1=auto, 0=off, >0=token 数；null 时键不存在
  learning_mode_enabled_v1?: boolean;
  learning_mode_prompt_v1?: string;
  provider_groups_v1?: JsonString<ProviderGroup[]>;
  provider_group_map_v1?: JsonString<Record<string, string>>;              // providerKey -> groupId
  provider_group_collapsed_v1?: JsonString<Record<string, boolean>>;       // key: 'groupId|__ungrouped__'
  provider_ungrouped_position_v1?: number;       // int
  migrations_version_v1?: number;                // int；当前期望值 3

  // --- MCP ---
  mcp_servers_v1?: JsonString<McpServerConfig[]>;
  mcp_log_enabled_v1?: boolean;
  mcp_request_timeout_ms_v1?: number;            // int，默认 30000

  // --- 搜索 ---
  search_services_v1?: JsonString<SearchServiceOptions[]>;
  search_common_v1?: JsonString<{ resultSize: number; timeout: number }>;
  search_enabled_v1?: boolean;
  search_selected_v1?: number;                   // int，search_services_v1 下标
  search_log_enabled_v1?: boolean;
  search_auto_test_on_launch_v1?: boolean;

  // --- 记忆/标签/世界书/指令注入/快捷短语（除 memories 外均以 SQLite 为主，prefs 为兼容面）---
  assistant_memories_v1?: JsonString<AssistantMemory[]>;
  assistant_tags_v1?: JsonString<AssistantTag[]>;
  assistant_tag_map_v1?: JsonString<Record<string, string>>;       // assistantId -> tagId
  assistant_tag_collapsed_v1?: JsonString<Record<string, boolean>>;
  world_books_v1?: JsonString<WorldBook[]>;
  world_books_active_ids_by_assistant_v1?: JsonString<Record<string, string[]>>; // 空助手键为 '__global__'
  world_books_collapsed_v1?: JsonString<Record<string, boolean>>;
  instruction_injections_v1?: JsonString<InstructionInjection[]>;
  instruction_injections_active_id_v1?: string;                     // 旧版全局镜像，空时键移除
  instruction_injections_active_ids_v1?: JsonString<string[]>;
  instruction_injections_active_ids_by_assistant_v1?: JsonString<Record<string, string[]>>;
  instruction_injection_group_collapsed_v1?: JsonString<Record<string, boolean>>;
  quick_phrases_v1?: JsonString<QuickPhrase[]>;

  // --- TTS ---
  tts_services_v1?: JsonString<TtsServiceOptions[]>;
  tts_selected_v1?: number;                      // int；-1 = 系统 TTS
  tts_speech_rate_v1?: number;                   // double，0.1–1.0
  tts_pitch_v1?: number;                         // double，0.5–2.0
  tts_engine_v1?: string;                        // 平台引擎 id
  tts_language_v1?: string;                      // BCP-47
  tts_auto_play_assistant_replies_v1?: boolean;
  tts_log_enabled_v1?: boolean;
  tts_text_selection_mode_v1?: 'fullText' | 'quotedOnly' | 'outsideParentheses' | 'italicOnly' | 'nonItalic';

  // --- 备份目标（敏感：含密码/密钥）---
  webdav_config_v1?: JsonString<WebDavConfig>;
  s3_config_v1?: JsonString<S3Config>;
  filesystem_mounts_v1?: JsonString<FilesystemMount[]>;

  // --- 桌面（窗口/热键/快捷键被排除，见开头说明）---
  desktop_sidebar_open_v1?: boolean;
  desktop_sidebar_width_v1?: number;             // double，200–640
  desktop_right_sidebar_open_v1?: boolean;
  desktop_right_sidebar_width_v1?: number;       // double
  desktop_topic_position_v1?: 'left' | 'right';
  desktop_send_shortcut_v1?: 'enter' | 'ctrlEnter';

  // --- 全局代理 ---
  global_proxy_enabled_v1?: boolean;
  global_proxy_type_v1?: 'http' | 'https' | 'socks5';
  global_proxy_host_v1?: string;
  global_proxy_port_v1?: string;                 // 注意：是 string，默认 '8080'
  global_proxy_username_v1?: string;
  global_proxy_password_v1?: string;
  global_proxy_bypass_v1?: string;               // 逗号分隔 host/CIDR 列表

  // --- 备份提醒 / 增量备份 ---
  backup_reminder_enabled_v1?: boolean;
  backup_reminder_enabled_at_v1?: Iso8601;
  backup_reminder_last_backup_at_v1?: Iso8601;
  backup_reminder_interval_days_v1?: number;     // int，1–365
  backup_reminder_minutes_of_day_v1?: number;    // int，0–1439；未设置时键移除
  incr_include_settings_v1?: boolean;
  incr_update_backup_time_v1?: boolean;

  // --- 平台后台行为 ---
  android_background_chat_mode_v1?: 'off' | 'on' | 'on_notify';
  ios_background_generation_enabled_v1?: boolean;
  ios_background_notifications_enabled_v1?: boolean;
  ios_background_task_refresh_enabled_v1?: boolean;
  ios_live_activity_enabled_v1?: boolean;

  // --- 图片压缩 / 日志 / 存储 ---
  one_click_compress_enabled_v1?: boolean;
  one_click_compress_always_jpg_v1?: boolean;
  one_click_compress_quality_v1?: number;        // int，50–95
  one_click_compress_max_long_edge_v1?: number;  // int，768–4096
  image_cropper_enabled_v1?: boolean;
  log_save_output_v1?: boolean;
  log_max_size_mb_v1?: number;                   // int
  log_auto_delete_days_v1?: number;              // int
  request_log_enabled_v1?: boolean;
  flutter_log_enabled_v1?: boolean;
  trash_cap_mb_v1?: number;                      // int，0=不限
  reader_font_size_v1?: number;                  // int，14–24

  // --- 移动端编辑器 ---
  mobile_assistant_detail_outline_enabled_v1?: boolean;
  mobile_assistant_edit_tab_hidden_v1?: string[]; // 取自 'basic'|'prompts'|'memory'|'proactiveLetter'|'mcp'|'localTools'|'skills'|'quickPhrase'|'custom'|'regex'
  mobile_assistant_edit_tab_order_v1?: string[];  // 同上 10 个 tab id 的排列

  // --- 显示（字体/消息/交互）---
  display_app_font_family_v1?: string;
  display_app_font_is_google_v1?: boolean;
  display_app_font_local_alias_v1?: string;
  display_app_font_local_path_v1?: string;
  display_code_font_family_v1?: string;
  display_code_font_is_google_v1?: boolean;
  display_code_font_local_alias_v1?: string;
  display_code_font_local_path_v1?: string;
  display_chat_background_mask_strength_v1?: number;   // double，0.0–2.0
  display_chat_input_background_opacity_dark_v1?: number;  // double，0–1
  display_chat_input_background_opacity_light_v1?: number; // double，0–1
  display_chat_message_background_style_v1?: 'default' | 'frosted' | 'solid';
  display_auto_scroll_enabled_v1?: boolean;
  display_auto_scroll_idle_seconds_v1?: number;  // int，2–64
  display_auto_collapse_code_block_v1?: boolean;
  display_auto_collapse_code_block_lines_v1?: number;  // int，1–999
  display_auto_collapse_thinking_v1?: boolean;
  display_collapse_thinking_steps_v1?: boolean;
  display_enter_to_send_on_mobile_v1?: boolean;
  display_enable_assistant_markdown_v1?: boolean;
  display_enable_user_markdown_v1?: boolean;
  display_enable_dollar_latex_v1?: boolean;
  display_enable_math_rendering_v1?: boolean;
  display_enable_reasoning_markdown_v1?: boolean;
  display_show_message_nav_v1?: boolean;         // 旧版合并开关
  display_mobile_message_nav_buttons_mode_v1?: 'always' | 'scroll' | 'never';
  display_desktop_message_nav_buttons_mode_v1?: 'always' | 'scroll' | 'hover' | 'scrollAndHover' | 'never';
  display_desktop_auto_switch_topics_v1?: boolean;
  display_mobile_code_block_wrap_v1?: boolean;
  display_show_model_icon_v1?: boolean;
  display_show_model_name_v1?: boolean;
  display_show_model_timestamp_v1?: boolean;
  display_show_model_name_timestamp_v1?: boolean; // 旧版合并键
  display_show_provider_in_model_capsule_v1?: boolean;
  display_show_provider_in_chat_message_v1?: boolean;
  display_show_token_stats_v1?: boolean;
  display_show_user_avatar_v1?: boolean;
  display_show_user_name_v1?: boolean;
  display_show_user_timestamp_v1?: boolean;
  display_show_user_name_timestamp_v1?: boolean;  // 旧版合并键
  display_show_user_message_actions_v1?: boolean;
  display_show_tool_result_summary_v1?: boolean;
  display_show_regenerate_confirm_dialog_v1?: boolean;
  display_show_chat_list_date_v1?: boolean;
  display_show_app_updates_v1?: boolean;
  display_new_chat_on_launch_v1?: boolean;
  display_new_chat_on_assistant_switch_v1?: boolean;
  display_new_chat_after_delete_v1?: boolean;
  display_regenerate_delete_trailing_messages_v1?: boolean;
  display_keep_sidebar_open_on_assistant_tap_v1?: boolean;
  display_keep_sidebar_open_on_topic_tap_v1?: boolean;
  display_keep_assistant_list_expanded_on_sidebar_close_v1?: boolean;
  display_use_new_assistant_avatar_ux_v1?: boolean;
  display_use_pure_background_v1?: boolean;
  display_haptics_global_enabled_v1?: boolean;
  display_haptics_ios_switch_v1?: boolean;
  display_haptics_on_card_tap_v1?: boolean;
  display_haptics_on_drawer_v1?: boolean;
  display_haptics_on_generate_v1?: boolean;
  display_haptics_on_list_item_tap_v1?: boolean;
  display_desktop_show_tray_v1?: boolean;
  display_desktop_minimize_to_tray_on_close_v1?: boolean;
}

// ===== JSON 解码后的子结构 =====
interface Assistant {
  id: string; name: string; avatar?: string | null;
  useAssistantAvatar: boolean; useAssistantName: boolean;
  chatModelProvider?: string | null; chatModelId?: string | null;
  temperature?: number | null; topP?: number | null;
  contextMessageSize: number; limitContextMessages: boolean; streamOutput: boolean;
  thinkingBudget?: number | null; maxTokens?: number | null;
  systemPrompt: string; messageTemplate: string;
  searchEnabled: boolean;
  mcpServerIds: string[]; localToolIds: string[]; skillIds: string[];
  background?: string | null;
  customHeaders?: Record<string, string>[] | null;
  customBody?: Record<string, string>[] | null;
  enableMemory: boolean; memoryMode: string;
  enableRecentChatsReference: boolean; recentChatsSummaryMessageCount: number;
  memoryRecordPrompt: string;
  presetMessages: { id: string; role: string; content: string }[];
  regexRules: unknown[];   // AssistantRegex 数组
  enableProactiveCare: boolean;
  proactiveCareNextMessageAt?: Iso8601 | null;
  proactiveCarePrompt: string; proactiveCareDecisionPrompt: string;
  docxMode: string; pdfMode: string; otherOfficeMode: string; ocrMode: string;
  enableTimeInjection: boolean; discoverable: boolean;
  handoffId?: string | null; handoffDescription?: string | null;
  createdAt: Iso8601; updatedAt: Iso8601;
}

interface ProviderConfig {
  id: string; enabled: boolean; name: string;
  apiKey: string; baseUrl: string;
  providerType?: string;              // ProviderKind.name
  chatPath?: string;
  useResponseApi?: boolean;
  enableToolResultImages?: boolean;
  vertexAI?: boolean;
  location?: string; projectId?: string; serviceAccountJson?: string;
  models: string[];
  modelOverrides?: Record<string, {
    apiModelId?: string; name?: string;
    type?: 'chat' | 'embedding';
    input?: unknown[]; output?: unknown[]; abilities?: unknown[]; tools?: unknown;
  }>;
  proxyEnabled?: boolean; proxyType?: string; proxyHost?: string;
  proxyPort?: string; proxyUsername?: string; proxyPassword?: string;
  avatarType?: 'emoji' | 'url' | 'file' | 'icon' | 'lobehub';
  avatarValue?: string;
  multiKeyEnabled?: boolean;
  apiKeys?: ApiKeyConfig[];
  keyManagement?: KeyManagementConfig;
  aihubmixAppCodeEnabled?: boolean;
  balanceEnabled?: boolean; balanceApiPath?: string; balanceResultPath?: string;
  claudePromptCachingEnabled: boolean;
  claudePromptCachingTtl?: '5m' | '1h';
  customHeaders?: Record<string, string>[] | null;
  customBody?: Record<string, string>[] | null;
}

interface ApiKeyConfig {
  id: string; key: string; name?: string; isEnabled: boolean;
  priority: number; maxRequestsPerMinute?: number;
  usage: Record<string, unknown>;
  status: 'active' | 'disabled' | 'error' | 'rateLimited';
  lastError?: string; createdAt: number; updatedAt: number;
}

interface KeyManagementConfig {
  strategy: 'roundRobin' | 'priority' | 'leastUsed' | 'random';
  maxFailuresBeforeDisable: number; failureRecoveryTimeMinutes: number;
  enableAutoRecovery: boolean; roundRobinIndex?: number;
}

interface ProviderGroup { id: string; name: string; createdAt: number; } // createdAt: epoch ms

interface McpServerConfig {
  id: string; enabled: boolean; name: string;
  transport: 'sse' | 'http' | 'stdio' | 'inmemory';
  url: string;
  tools: McpToolConfig[];
  headers: Record<string, string>;
  command?: string; args: string[]; env: Record<string, string>;
  workingDirectory?: string; heartbeatIntervalSeconds?: number;
  toolPrefix: string;
  oauth?: { authorizationEndpoint: string; tokenEndpoint: string; clientId: string;
            clientSecret?: string; scopes?: string; redirectUri?: string;
            clientRegistrationVersion?: number };
  oauthToken?: { access_token: string; token_type: string; expires_in?: number;
                 refresh_token?: string; scope?: string; issued_at: number };
}
interface McpToolConfig {
  enabled: boolean; name: string; description?: string;
  params: { name: string; required: boolean; type?: string; default?: unknown }[];
  schema?: Record<string, unknown>;
  needsApproval: boolean;
}

interface SearchServiceOptions {
  type: 'bing_local' | 'tavily' | 'exa' | 'zhipu' | 'searxng' | 'linkup' | 'brave'
      | 'metaso' | 'ollama' | 'jina' | 'bocha' | 'duckduckgo' | 'perplexity'
      | 'serper' | 'grok' | 'querit';
  id: string;
  apiKeys: ApiKeyConfig[];
  apiKey?: string;              // 旧版双写
  keyManagement?: KeyManagementConfig;
  [k: string]: unknown;         // 各 type 特有字段
}

interface TtsServiceOptions {
  kind: 'openai' | 'gemini' | 'minimax' | 'qwen' | 'groq' | 'xai' | 'elevenlabs' | 'mimo';
  id: string; enabled: boolean; name: string;
  apiKey?: string; baseUrl?: string; model?: string; voice?: string;
  // minimax: voiceId, emotion, speed:number; qwen: languageType; xai: language;
  // elevenlabs: modelId, voiceId, outputFormat; gemini: voiceName
  [k: string]: unknown;
}

interface AssistantMemory { id: number; assistantId: string; content: string; }
interface AssistantTag { id: string; name: string; }
interface WorldBook {
  id: string; name: string; description: string; enabled: boolean;
  entries: WorldBookEntry[];
}
interface WorldBookEntry {
  id: string; name: string; enabled: boolean; priority: number;
  position: 'BEFORE_SYSTEM_PROMPT' | 'AFTER_SYSTEM_PROMPT' | 'TOP_OF_CHAT' | 'BOTTOM_OF_CHAT' | 'AT_DEPTH';
  content: string; injectDepth: number;
  role: 'USER' | 'ASSISTANT';
  keywords: string[]; useRegex: boolean; caseSensitive: boolean;
  scanDepth: number; constantActive: boolean;
}
interface InstructionInjection { id: string; title: string; prompt: string; group: string; }
interface QuickPhrase {
  id: string; title: string; content: string;
  isGlobal: boolean; assistantId?: string | null;
}
interface WebDavConfig {
  url: string; username: string; password: string;
  path: string; userAgent: string;
  includeChats: boolean; includeFiles: boolean;
}
interface S3Config {
  endpoint: string; region: string; bucket: string;
  accessKeyId: string; secretAccessKey: string; sessionToken: string;
  prefix: string; pathStyle: boolean; userAgent: string;
  includeChats: boolean; includeFiles: boolean;
}
interface FilesystemMount { alias: string; path: string; readOnly: boolean; }
```

**关键注意点**：
- `int`/`double` 在 JSON 中都是 `number`；字符串列表是真正的 JSON 数组，其余集合类型全部是 JSON 编码字符串。
- `*_model_v1` 系列存 `providerKey::modelId` 复合串；`selected_model_v1` 同构。
- `providers_order_v1`、`pinned_models_v1`、`mobile_assistant_edit_tab_*` 是唯一的 3 组 `string[]` 键。
- `desktop_hotkeys_*_v1` 虽然是 string[]，但被 `_localOnlyKeys` 排除，不导出；`codex_oauth_v1`/`grok_oauth_v1` 同样被排除（batch B 的结论有误，已用 data_sync.dart:2349-2350 核实）。
- `tool_events_v1`、`hive_migration_complete_v1`、`cuplivo_bg_chat_v2`、`ask_user_input_v0`、`eleven_multilingual_v2` 不是 prefs 键，不在 settings.json 中。
