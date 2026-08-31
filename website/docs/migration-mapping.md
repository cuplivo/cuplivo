# 迁移映射表：RikkaHub 备份 → Kelivo 备份包

决策上下文见 CONTEXT.md（迁移 = RikkaHub → Kelivo 可恢复备份包，唯一途径；原则：保真数据 + 最小猜测 + 迁移报告）。

## 概览

| 层 | 源 | 目标 | 策略 |
|---|---|---|---|
| 会话 | `ConversationEntity` + `message_node` | `chats.json.conversations` | 节点取自 **message_node 表**（`ConversationEntity.nodes` 恒为 `"[]"`，历史遗留）；逐回合取 `select_index` 版本，未选版本丢弃入报告 |
| 消息 | `UIMessage`（parts） | `chats.json.messages` + `toolEvents` | parts → content 内联标记 + 推理字段 + 工具事件 |
| 助手 | `Settings.assistants` | `assistants_v1` | 全量真实还原，UUID 保留；未定义 assistantId 兜底占位 |
| 提供商 | `Settings.providers` | `provider_configs_v1` | 生成 providerKey = RikkaHub provider UUID，模型 UUID 解引用 |
| 记忆 | `MemoryEntity` | `assistant_memories_v1` | 直接映射（assistantId 为 UUID，迁移后仍有效） |
| 设置 | `Settings` 各字段 | `settings.json` 各 `_v1` 键 | 语义清晰 1:1 映射；无对应丢弃；备份凭据默认不复制 |
| 媒体 | `upload/` `fonts/` `skills/` | 同名目录 | 透传（`_cleanupOrphanUploads` 会在恢复时清理孤儿） |

## 会话层

`ConversationEntity` + `message_node` 表 → `Conversation`：

| 源 | 目标 | 备注 |
|---|---|---|
| `id` | `id` | UUID 保留 |
| `title` | `title` | |
| `message_node` 行（按 `node_index` 升序；`messages` JSON 为该回合 alternatives + `select_index`） | 线性化 | 每回合取 `messages[select_index]`（kotlinx camelCase），其余 alternatives 丢弃计数入报告；`ConversationEntity.nodes` 恒为 `"[]"`，仅作历史兜底 |
| 首/末条消息 `createdAt` | `createdAt` / `updatedAt` | 避免 epoch→ISO 的时区猜测；无消息时用 `create_at`/`update_at` 兜底 |
| 线性化消息 id 列表 | `messageIds` | |
| `is_pinned` | `isPinned` | |
| `assistant_id` | `assistantId` | 引用迁移后的助手 UUID；若未定义 → 生成占位助手 |
| — | `parentConversationId: null, truncateIndex: -1, versionSelections: {}, summary: null, lastSummarizedMessageCount: 0, chatSuggestions: [], conversationKind: 'normal'` | 固定值 |
| `suggestions` | `chatSuggestions` | |
| `custom_system_prompt` | 占位助手的 `systemPrompt` | 仅当该会话的助手为占位（定义缺失）且提示词非空时 |
| `mode_injection_ids` / `lorebook_ids` / `workspace_cwd` | 丢弃 | 无 per-conversation 对应，入报告 |

## 消息层

`UIMessage` → `ChatMessage`：

| 源 | 目标 | 备注 |
|---|---|---|
| `id` | `id` | UUID 保留 |
| `role` | `role` | `system`/`tool` 跳过，计数入报告 |
| parts 串联 | `content` | 见下方 parts 规则 |
| `createdAt` | `timestamp` | 原样（ISO LocalDateTime 字符串） |
| `modelId`（UUID） | `providerId` / `modelId` | 经 `Settings.providers[].models[]` 解引用；不可解 → null + 报告"未识别 modelId" |
| `usage` | `promptTokens`/`completionTokens`/`cachedTokens`/`totalTokens` | |
| `translation` | `translation` | |
| reasoning part | `reasoningText` + `reasoningStartAt`/`reasoningFinishedAt` | 多个 reasoning part 串联 |
| — | `isStreaming: false, version: 0, groupId: null, subgroupId: null, isPreset: false, speakerAssistantId: null, reasoningSegmentsJson: null` | 固定值 |

### parts → content 规则

| part | 目标 |
|---|---|
| `text` | 原文追加 |
| `image` | `&#91;image:&lt;url&gt;&#93;`；`http(s)`/`data:` 原样；本地路径提取 basename → `upload/<basename>`（文件透传至 `upload/`） |
| `document` | `&#91;file:&lt;path&gt;\|<fileName>\|<mime>&#93;` |
| `video` / `audio` | `&#91;file:&lt;path&gt;\|<basename>\|<mime>&#93;`（Kelivo 无独立标记，归入 file） |
| `reasoning` | 不写入 content，进 `reasoningText` |
| `tool` | 进 `toolEvents[messageId]`：`{id: toolCallId, name: toolName, arguments: JSON.parse(input)??{}, content: output 文本串联, metadata: {}}`；不写入 content |
| `search` / `tool_call` / `tool_result`（deprecated） | 丢弃，计数入报告 |

## 助手层

`Settings.assistants[i]` → `assistants_v1` 条目：

| 源 | 目标 | 备注 |
|---|---|---|
| `id` | `id` | UUID 保留（会话引用不失效） |
| `name` | `name` | |
| `avatar`（Dummy/Emoji/Image） | `avatar` | Dummy→null，Emoji→content，Image→url |
| `useAssistantAvatar` | `useAssistantAvatar` | |
| — | `useAssistantName: true` | RikkaHub 无对应，取 Kelivo 默认 |
| `chatModelId`（UUID） | `chatModelProvider` / `chatModelId` | 解引用；null → null |
| `systemPrompt` | `systemPrompt` | |
| `temperature` / `topP` | 同名 | |
| `contextMessageLimit` | `contextMessageSize` | |
| — | `limitContextMessages: true` | RikkaHub 无开关，取默认 |
| `streamOutput` | `streamOutput` | |
| `reasoningLevel` | `thinkingBudget` | `off`→0，其余→null（近似全局默认），报告注明 |
| `maxTokens` | `maxTokens` | |
| `messageTemplate` | `messageTemplate` | |
| `searchEnabled`（来自 `enableWebSearch`） | `searchEnabled` | |
| `customHeaders` | `customHeaders` | 同构 |
| `customBodies` | `customBody` | value 为 JSON 元素：字符串原样，其余 JSON.stringify |
| `mcpServers`（UUID[]） | `mcpServerIds` | 引用迁移后的 MCP server id |
| `localTools` | `localToolIds` | 枚举同源，原样 |
| `enableMemory` | `enableMemory` | |
| — | `memoryMode: 'injection'`、`memoryRecordPrompt: 默认` | RikkaHub 无对应，取默认 |
| `enableRecentChatsReference` | 同名 | |
| — | `recentChatsSummaryMessageCount: 5` | 默认 |
| `presetMessages`（UIMessage[]） | `presetMessages` | 取各消息 text part 串联 → `{id, role, content}` |
| `regexes` | `regexRules` | `pattern=findRegex, replacement=replaceString, scopes=affectingScope 小写, replaceOnly=false` |
| `tags`（首个） | `assistant_tags_v1` + `assistant_tag_map_v1` | Kelivo 每助手仅 1 tag；多余丢弃入报告 |
| `modeInjectionIds` | `instruction_injections_active_ids_by_assistant_v1` | |
| `lorebookIds` | `world_books_active_ids_by_assistant_v1` | |
| `enabledSkills` | `skillIds` | |
| `enableTimeReminder` | `enableTimeInjection` | |
| `background` | `background` | |
| `backgroundOpacity`/`useGradientBackground`/`workspaceId`/`allowConversation*` | 丢弃 | 无对应，入报告 |
| — | `createdAt`/`updatedAt` | 迁移时刻 ISO，参照 Kelivo 对 v1 导入的 `DateTime.now()` 兜底 |

**占位助手**：会话引用但 `Settings.assistants` 未定义的 assistantId（典型：默认助手 UUID `0950e2dc-9bd5-4801-afa3-aa887aa36b4e`）→ 按 `conversation_folder.name` 命名（缺则 `Found NN`），`custom_system_prompt` 非空时作为其 systemPrompt。

## 模型层

`Settings.providers[i]` → `provider_configs_v1`（`Record<providerKey, ProviderConfig>`）：

| 源 | 目标 | 备注 |
|---|---|---|
| `id` | 键（providerKey） | **key = RikkaHub provider UUID**，避免发明命名规则；`name` 字段保留展示名 |
| `type` | `providerType` | `openai`/`google`/`claude` 同名 |
| `apiKey` | `apiKey` | 迁移即插即用（用户已知悉风险；备份凭据类仅 webdav/s3 不复制） |
| `baseUrl` | `baseUrl` | |
| `chatCompletionsPath` | `chatPath` | |
| `useResponseApi` | `useResponseApi` | |
| `vertexAI`/`location`/`projectId` | 同名 | google |
| `privateKey`/`serviceAccountEmail` | 丢弃 | 无法确定 `serviceAccountJson` 重组格式，入报告 |
| `promptCaching`/`promptCacheTtl` | `claudePromptCachingEnabled`/`claudePromptCachingTtl` | claude |
| `balanceOption` | `balanceEnabled`/`balanceApiPath`/`balanceResultPath` | |
| `models[]` | `models` + `modelOverrides` | `models` = modelId 字符串（按类型排序）；`modelOverrides`：`name=displayName, type: CHAT→chat, EMBEDDING→embedding, IMAGE→chat`（报告注明），`input/output/abilities/tools` 原样 |
| — | `claudePromptCachingEnabled: false` | 必需默认 |
| `favoriteModels`（UUID[]） | `pinned_models_v1` | 解引用 → `<providerKey>::<modelId>` |
| `chatModelId`/`fastModelId`/`titleModelId` | `selected_model_v1`（chatModelId） | 解引用；title 键 `title_model_v1` 可由迁移工具写入 |
| `Settings.assistantId` | `current_assistant_id_v1` | |

## 设置层

### 映射组（语义清晰）

| RikkaHub | Kelivo | 备注 |
|---|---|---|
| `searchServices` | `search_services_v1` | 同名 type 直映（tavily/exa/zhipu/searxng/linkup/brave/metaso/ollama/perplexity/grok/serper/jina/bocha/bing_local）；`apiKey`/`url` 复制；firecrawl/tinyfish/custom_js/rikkahub 丢弃入报告 |
| `searchServiceSelected` | `search_selected_v1` | 映射后重算下标 |
| `ttsProviders` | `tts_services_v1` | 同名 kind 直映（openai/gemini/minimax/qwen/groq/xai/mimo/elevenlabs）；`system` 忽略；step/fish-audio 丢弃入报告 |
| `selectedTTSProviderId` | `tts_selected_v1` | 映射后重算下标 |
| `defaultTTSPlaybackSpeed` | `tts_speech_rate_v1` | |
| `mcpServers` | `mcp_servers_v1` | `sse`→`sse`，`streamable_http`→`http`；headers pairs→Record；tools→McpToolConfig（params 自 inputSchema 推导） |
| `quickMessages` | `quick_phrases_v1` | `isGlobal: true` |
| `assistantTags` | `assistant_tags_v1` | id 保留 |
| `MemoryEntity`（DB） | `assistant_memories_v1` | |
| `lorebooks` | `world_books_v1` | position 枚举大写映射；role `user→USER, assistant→ASSISTANT`，其余条目丢弃入报告 |
| `modeInjections` | `instruction_injections_v1` | `title=name, prompt=content, group='default'` |
| `backupReminderConfig` | `backup_reminder_enabled_v1`/`interval_days_v1`/`last_backup_at_v1` | |
| `displaySetting` 安全键 | `display_show_model_icon_v1` 等 | 仅映射明确 1:1 的键（见代码常量 DISPLAY_MAP）；其余丢弃 |
| `themeId`/`dynamicColor`/`customThemes` | 丢弃 | 语义不对应（Kelivo 为 light/dark/system），入报告 |

### 丢弃组（无对应，入报告）

`asrProviders`、`webServer*`、`workspaces`、`favorites`、`gen_media`、`developerMode`、`launchCount`、`sponsorAlertDismissedAt`、`imageGenerationModelId`、`ocrModelId`/`ocrPrompt`、`translateModeId`/`translatePrompt`、`compressModelId`/`compressPrompt`、`suggestionModelId`/`suggestionPrompt`、`titlePrompt`、`enableSuggestion`、`searchCommonOptions`。

### 敏感组（默认不复制）

`webDavConfig`、`s3Config`——复制会使 Kelivo 备份导去 RikkaHub 服务器且目录冲突；默认不复制，迁移报告提示。

## 迁移报告

下载 JSON + 屏显摘要。字段：`generatedAt`、`source{fileName, dbVersion}`、`totals{conversations, messages, mediaFiles, toolEvents, memories}`、`dropped[]{category, count, detail?}`、`placeholderAssistants[]`、`unrecognizedModelIds[]`、`droppedAlternatives`、`warnings[]`。
