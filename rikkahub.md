## Zip 备份格式（WebDavSync.kt:134 / S3Sync 同构）

备份文件名 `backup_yyyyMMdd_HHmmss.zip`，由 `ZipOutputStream` 生成，上传时 Content-Type 为 `application/zip`。压缩包内条目结构如下：

```
backup_yyyyMMdd_HHmmss.zip
├── settings.json          # 序列化的应用设置（WebDavConfig 项，恢复时经 SettingsJsonMigrator 迁移）
├── rikka_hub.db           # SQLite 数据库文件（可选，DATABASE 项）
├── rikka_hub-wal          # WAL 日志（可选）
├── rikka_hub-shm          # SHM 共享内存（可选）
├── upload/<文件名>        # 上传文件目录（可选，FILES 项，仅顶层文件）
├── skills/<相对路径>      # skills 目录递归打包（可选，FILES 项）
└── fonts/<文件名>         # 字体文件（可选，FILES 项，仅顶层）
```

恢复时按条目名分支：`settings.json` 走迁移+解析；`rikka_hub.db/-wal/-shm` 写回数据库目录；`upload/`、`skills/`、`fonts/` 前缀写回对应目录，其余条目跳过。

## SQLite 文件 TypeScript 描述

`rikka_hub.db` 为 Room 数据库（version 24），包含 8 张业务表 + Room 元数据表。JSON 字符串列按存储形态（TEXT）保留：

```typescript
/** Room 元数据（自动维护，勿手写） */
interface RoomMasterTable { id: number; identity_hash: string }

/** 会话（表名 ConversationEntity） */
interface ConversationEntity {
  id: string
  assistant_id: string                     // 默认 "0950e2dc-9bd5-4801-afa3-aa887aa36b4e"
  title: string
  nodes: string                            // **恒为 "[]"（历史遗留字段）**；节点数据实际存于 message_node 表
  create_at: number                        // epoch millis
  update_at: number
  suggestions: string                      // JSON: string[]，默认 "[]"
  is_pinned: boolean                       // 0/1
  custom_system_prompt: string
  mode_injection_ids: string               // JSON: string[]，默认 "[]"
  lorebook_ids: string                     // JSON: string[]，默认 "[]"
  workspace_cwd: string
  folder_id: string
}

/** 回合节点（表名 message_node，conversation_id 外键 CASCADE，索引 conversation_id）——真实数据源 */
interface MessageNodeEntity {
  id: string
  conversation_id: string
  node_index: number                        // 回合序号，按序拼接成完整对话
  messages: string                         // JSON: List<UIMessage>，同一回合的 alternatives（regenerate 版本）
  select_index: number                     // 当前展示的 alternative 下标（camelCase: selectIndex）；迁移只取该版
}

/** 记忆（表名 MemoryEntity） */
interface MemoryEntity { id: number; assistant_id: string; content: string }

/** 生成媒体（表名 GenMediaEntity） */
interface GenMediaEntity {
  id: number
  path: string
  model_id: string
  prompt: string
  create_at: number
  type: "image_generation" | "image_edit" | string  // 默认 image_generation
  source_paths: string | null              // JSON
}

/** 托管文件（表名 managed_files，relative_path 唯一，folder 索引） */
interface ManagedFileEntity {
  id: number
  folder: string
  relative_path: string
  display_name: string
  mime_type: string
  size_bytes: number
  created_at: number
  updated_at: number
}

/** 收藏（表名 favorites，ref_key 唯一，type/created_at 索引） */
interface FavoriteEntity {
  id: string
  type: string
  ref_key: string
  ref_json: string                         // JSON
  snapshot_json: string                    // JSON
  meta_json: string | null                 // JSON
  created_at: number
  updated_at: number
}

/** 工作区（表名 workspaces，root 唯一，updated_at 索引） */
interface WorkspaceEntity {
  id: string
  name: string
  root: string
  shell_status: string                     // DISABLED/...（WorkspaceShellStatus 枚举名）
  created_at: number
  updated_at: number
  last_access_at: number | null
  tool_approvals: string                   // JSON: { [toolName: string]: boolean }，默认 "{}"
}

/** 会话文件夹（表名 conversation_folder，assistant_id 索引） */
interface FolderEntity {
  id: string
  assistant_id: string
  name: string
  sort_index: number
  create_at: number
}
```

要点：`TokenUsage` 以 JSON 字符串存于 `messages` 内的 UIMessage 中；`is_pinned` 为 0/1；时间戳均为 epoch millis；Room 表名未指定时使用类名原样（`ConversationEntity`/`MemoryEntity`/`GenMediaEntity`），指定时用 `message_node`/`managed_files`/`favorites`/`workspaces`/`conversation_folder`。

## settings

调查完成。备份 zip 内的 `settings.json` 由 `WebDavSync.prepareBackupFile` 写入（WebDavSync.kt:147），内容是 `JsonInstant.encodeToString(Settings)`——即整个 `Settings` data class（`encodeDefaults = true`，所有默认值都会序列化；`init` 为 `@Transient` 不出现）。以下为完整 TypeScript 表示：

```typescript
// ============ 基础类型 ============
type UUID = string                       // kotlin.uuid.Uuid 序列化为字符串
type JsonObject = Record<string, unknown>
type JsonElement = unknown               // kotlinx.serialization.json.JsonElement
// sealed class 默认用 "type" 字段作判别（除非子类有 @SerialName，判别值取类名）

export interface Settings {
  dynamicColor: boolean
  themeId: string
  customThemes: CustomTheme[]
  developerMode: boolean
  displaySetting: DisplaySetting
  favoriteModels: UUID[]                 // 收藏的模型 id
  chatModelId: UUID
  fastModelId: UUID
  titleModelId: UUID | null
  imageGenerationModelId: UUID
  titlePrompt: string
  translateModeId: UUID
  translatePrompt: string
  translateThinkingBudget: number
  enableSuggestion: boolean
  suggestionModelId: UUID | null
  suggestionPrompt: string
  ocrModelId: UUID
  ocrPrompt: string
  compressModelId: UUID
  compressPrompt: string
  assistantId: UUID
  providers: ProviderSetting[]
  assistants: Assistant[]
  assistantTags: Tag[]
  searchServices: SearchServiceOptions[]
  searchCommonOptions: SearchCommonOptions
  searchServiceSelected: number
  mcpServers: McpServerConfig[]
  webDavConfig: WebDavConfig
  s3Config: S3Config
  ttsProviders: TTSProviderSetting[]
  selectedTTSProviderId: UUID
  defaultTTSPlaybackSpeed: number        // Float，夹在 0.5~2.0
  asrProviders: ASRProviderSetting[]
  selectedASRProviderId: UUID | null
  modeInjections: ModeInjection[]
  lorebooks: Lorebook[]
  quickMessages: QuickMessage[]
  webServerEnabled: boolean
  webServerPort: number
  webServerJwtEnabled: boolean
  webServerAccessPassword: string
  webServerLocalhostOnly: boolean
  backupReminderConfig: BackupReminderConfig
  launchCount: number
  sponsorAlertDismissedAt: number
}

// ============ 主题 ============
export interface CustomTheme {
  id: string
  name: string
  primaryColorArgb: number               // Long，如 4282212516 (0xFF6750A4)
  secondaryColorArgb: number | null
  tertiaryColorArgb: number | null
}

// ============ 显示设置 ============
export interface DisplaySetting {
  userAvatar: Avatar
  userNickname: string
  useAppIconStyleLoadingIndicator: boolean
  showUserAvatar: boolean
  showAssistantBubble: boolean
  bubbleOpacity: number
  showModelIcon: boolean
  showModelName: boolean
  showDateTimeInMessage: boolean
  showTokenUsage: boolean
  showThinkingContent: boolean
  autoCloseThinking: boolean
  showUpdates: boolean
  showMessageJumper: boolean
  messageJumperOnLeft: boolean
  fontSizeRatio: number
  enableMessageGenerationHapticEffect: boolean
  skipCropImage: boolean
  enableNotificationOnMessageGeneration: boolean
  enableLiveUpdateNotification: boolean
  codeBlockAutoWrap: boolean
  codeBlockAutoCollapse: boolean
  showLineNumbers: boolean
  ttsOnlyReadQuoted: boolean
  ttsOnlyReadOutsideBrackets: boolean
  autoPlayTTSAfterGeneration: boolean
  pasteLongTextAsFile: boolean
  pasteLongTextThreshold: number
  sendOnEnter: boolean
  enableAutoScroll: boolean
  enableLatexRendering: boolean
  enableBlurEffect: boolean
  chatFontFamily: 'default' | 'serif' | 'monospace' | 'custom'
  chatCustomFontPath: string
  chatCustomFontName: string
  enableVolumeKeyScroll: boolean
  volumeKeyScrollRatio: number
}

export type Avatar =
  | { type: 'Dummy' }
  | { type: 'Emoji'; content: string }
  | { type: 'Image'; url: string }

// ============ 提供商 ============
export type ProviderSetting = ProviderOpenAI | ProviderGoogle | ProviderClaude

interface ProviderBase {
  id: UUID
  enabled: boolean
  name: string
  models: Model[]
  balanceOption: BalanceOption
  // builtIn / description / shortDescription 为 @Transient，不序列化
}
export interface ProviderOpenAI extends ProviderBase {
  type: 'openai'
  apiKey: string
  baseUrl: string
  chatCompletionsPath: string
  useResponseApi: boolean
  includeHistoryReasoning: boolean
}
export interface ProviderGoogle extends ProviderBase {
  type: 'google'
  apiKey: string
  baseUrl: string
  vertexAI: boolean
  useServiceAccount: boolean
  privateKey: string
  serviceAccountEmail: string
  location: string
  projectId: string
}
export interface ProviderClaude extends ProviderBase {
  type: 'claude'
  apiKey: string
  baseUrl: string
  promptCaching: boolean
  promptCacheTtl: '5m' | '1h'
}

export interface BalanceOption {
  enabled: boolean
  apiPath: string
  resultPath: string
}

export interface Model {
  modelId: string
  displayName: string
  id: UUID
  type: 'CHAT' | 'IMAGE' | 'EMBEDDING'
  customHeaders: CustomHeader[]
  customBodies: CustomBody[]
  inputModalities: ('TEXT' | 'IMAGE')[]
  outputModalities: ('TEXT' | 'IMAGE')[]
  abilities: ('TOOL' | 'REASONING')[]
  tools: ('search' | 'url_context' | 'image_generation')[]
  providerOverwrite: ProviderSetting | null
}

export interface CustomHeader { name: string; value: string }
export interface CustomBody { key: string; value: JsonElement }

// ============ 助手 ============
export interface Assistant {
  id: UUID
  chatModelId: UUID | null
  name: string
  avatar: Avatar
  useAssistantAvatar: boolean
  tags: UUID[]
  systemPrompt: string
  temperature: number | null
  topP: number | null
  contextMessageLimit: number
  streamOutput: boolean
  enableMemory: boolean
  useGlobalMemory: boolean
  enableRecentChatsReference: boolean
  messageTemplate: string
  presetMessages: UIMessage[]
  quickMessageIds: UUID[]
  regexes: AssistantRegex[]
  reasoningLevel: 'off' | 'auto' | 'low' | 'medium' | 'high' | 'xhigh'
  maxTokens: number | null
  customHeaders: CustomHeader[]
  customBodies: CustomBody[]
  mcpServers: UUID[]
  localTools: LocalToolOption[]
  enableWebSearch: boolean
  workspaceId: UUID | null
  background: string | null
  backgroundOpacity: number
  useGradientBackground: boolean
  modeInjectionIds: UUID[]
  lorebookIds: UUID[]
  enabledSkills: string[]
  enableTimeReminder: boolean
  allowConversationSystemPrompt: boolean
  allowConversationPromptInjection: boolean
}

export type LocalToolOption = 'javascript_engine' | 'time_info' | 'clipboard' | 'tts' | 'ask_user' | 'screen_time' | 'calendar'

export interface AssistantRegex {
  id: UUID
  name: string
  enabled: boolean
  findRegex: string
  replaceString: string
  affectingScope: ('USER' | 'ASSISTANT')[]
  visualOnly: boolean
}

// ============ 消息（presetMessages）============
export interface UIMessage {
  id: UUID
  role: 'system' | 'user' | 'assistant' | 'tool'
  parts: UIMessagePart[]
  annotations: UIMessageAnnotation[]
  createdAt: string                       // ISO-8601 LocalDateTime
  finishedAt: string | null
  modelId: UUID | null
  usage: TokenUsage | null
  translation: string | null
}
export interface TokenUsage {
  promptTokens: number
  completionTokens: number
  cachedTokens: number
  totalTokens: number
}
export type UIMessagePart =
  | { type: 'text'; text: string; metadata: JsonObject | null }
  | { type: 'image'; url: string; metadata: JsonObject | null }
  | { type: 'video'; url: string; metadata: JsonObject | null }
  | { type: 'audio'; url: string; metadata: JsonObject | null }
  | { type: 'document'; url: string; fileName: string; mime: string; metadata: JsonObject | null }
  | { type: 'reasoning'; reasoning: string; createdAt: string; finishedAt: string | null; metadata: JsonObject | null }
  | { type: 'search'; metadata: JsonObject | null }                                  // Deprecated
  | { type: 'tool_call'; toolCallId: string; toolName: string; arguments: string; approvalState: ToolApprovalState; metadata: JsonObject | null }   // Deprecated
  | { type: 'tool_result'; toolCallId: string; toolName: string; content: JsonElement; arguments: JsonElement; metadata: JsonObject | null }       // Deprecated
  | { type: 'tool'; toolCallId: string; toolName: string; input: string; output: UIMessagePart[]; approvalState: ToolApprovalState; metadata: JsonObject | null }

export type ToolApprovalState =
  | { type: 'auto' }
  | { type: 'pending' }
  | { type: 'approved' }
  | { type: 'denied'; reason: string }
  | { type: 'answered'; answer: string }

export type UIMessageAnnotation =
  | { type: 'url_citation'; title: string; url: string }

// ============ 标签 / 快捷消息 ============
export interface Tag { id: UUID; name: string }
export interface QuickMessage { id: UUID; title: string; content: string }

// ============ 提示词注入 / Lorebook ============
interface PromptInjectionBase {
  id: UUID
  name: string
  enabled: boolean
  priority: number
  position: 'before_system_prompt' | 'after_system_prompt' | 'top_of_chat' | 'bottom_of_chat' | 'at_depth'
  content: string
  injectDepth: number
  role: 'system' | 'user' | 'assistant' | 'tool'
}
export interface ModeInjection extends PromptInjectionBase { type: 'mode' }
export interface RegexInjection extends PromptInjectionBase {
  type: 'regex'
  keywords: string[]
  useRegex: boolean
  caseSensitive: boolean
  scanDepth: number
  constantActive: boolean
}
export interface Lorebook {
  id: UUID
  name: string
  description: string
  enabled: boolean
  entries: RegexInjection[]
}

// ============ 搜索 ============
export interface SearchCommonOptions { resultSize: number }

export type SearchServiceOptions =
  | { type: 'bing_local'; id: UUID }
  | { type: 'zhipu'; id: UUID; apiKey: string }
  | { type: 'tavily'; id: UUID; apiKey: string; depth: string }
  | { type: 'exa'; id: UUID; apiKey: string }
  | { type: 'searxng'; id: UUID; url: string; engines: string; language: string; username: string; password: string }
  | { type: 'linkup'; id: UUID; apiKey: string; depth: string }
  | { type: 'brave'; id: UUID; apiKey: string }
  | { type: 'metaso'; id: UUID; apiKey: string }
  | { type: 'ollama'; id: UUID; apiKey: string }
  | { type: 'perplexity'; id: UUID; apiKey: string; maxTokens: number | null; maxTokensPerPage: number | null }
  | { type: 'firecrawl'; id: UUID; apiKey: string }
  | { type: 'jina'; id: UUID; apiKey: string; searchUrl: string; scrapeUrl: string }
  | { type: 'bocha'; id: UUID; apiKey: string; summary: boolean }
  | { type: 'rikkahub'; id: UUID; apiKey: string; depth: string }
  | { type: 'grok'; id: UUID; apiKey: string; model: string; customUrl: string; systemPrompt: string }
  | { type: 'tinyfish'; id: UUID; apiKey: string }
  | { type: 'serper'; id: UUID; apiKey: string }
  | { type: 'custom_js'; id: UUID; name: string; searchScript: string; scrapeScript: string }

// ============ MCP ============
export type McpServerConfig =
  | { type: 'sse'; id: UUID; commonOptions: McpCommonOptions; url: string }
  | { type: 'streamable_http'; id: UUID; commonOptions: McpCommonOptions; url: string }

export interface McpCommonOptions {
  enable: boolean
  name: string
  headers: [string, string][]            // List<Pair<String,String>>
  tools: McpTool[]
  oauth: McpOAuthState | null
}
export interface McpOAuthState {
  enabled: boolean
  clientId: string | null
  clientSecret: string | null
  authorizationEndpoint: string | null
  tokenEndpoint: string | null
  registrationEndpoint: string | null
  scope: string | null
  accessToken: string | null
  refreshToken: string | null
  expiresAt: number                       // epoch millis
}
export interface McpTool {
  enable: boolean
  name: string
  description: string | null
  inputSchema: InputSchema | null
  needsApproval: boolean
}
export type InputSchema = { type: 'object'; properties: JsonObject; required: string[] | null }

// ============ 备份配置 ============
export interface WebDavConfig {
  url: string
  username: string
  password: string
  path: string
  items: ('DATABASE' | 'FILES')[]
}
export interface S3Config {
  endpoint: string
  accessKeyId: string
  secretAccessKey: string
  bucket: string
  region: string
  pathStyle: boolean
  items: ('DATABASE' | 'FILES')[]
}
export interface BackupReminderConfig {
  enabled: boolean
  intervalDays: number
  lastBackupTime: number                  // epoch millis
}

// ============ TTS ============
export type TTSProviderSetting =
  | { type: 'openai'; id: UUID; name: string; apiKey: string; baseUrl: string; model: string; voice: string }
  | { type: 'gemini'; id: UUID; name: string; apiKey: string; baseUrl: string; model: string; voiceName: string }
  | { type: 'system'; id: UUID; name: string; speechRate: number; pitch: number }
  | { type: 'minimax'; id: UUID; name: string; apiKey: string; baseUrl: string; model: string; voiceId: string; speed: number }
  | { type: 'qwen'; id: UUID; name: string; apiKey: string; baseUrl: string; model: string; voice: string; languageType: string }
  | { type: 'groq'; id: UUID; name: string; apiKey: string; baseUrl: string; model: string; voice: string }
  | { type: 'xai'; id: UUID; name: string; apiKey: string; baseUrl: string; voiceId: string; language: string }
  | { type: 'mimo'; id: UUID; name: string; apiKey: string; baseUrl: string; model: string; voice: string }
  | { type: 'elevenlabs'; id: UUID; name: string; apiKey: string; baseUrl: string; model: string; voiceId: string; stability: number; similarityBoost: number }
  | { type: 'step'; id: UUID; name: string; apiKey: string; baseUrl: string; model: string; voice: string; responseFormat: string; speed: number; volume: number; sampleRate: number; instruction: string }
  | { type: 'fish-audio'; id: UUID; name: string; apiKey: string; baseUrl: string; model: string; referenceId: string; temperature: number; speed: number; format: string; topP: number; chunkLength: number; normalize: boolean; latency: string }

// ============ ASR ============
export type ASRProviderSetting =
  | { type: 'openai_realtime'; id: UUID; name: string; apiKey: string; websocketUrl: string; model: string; language: string; prompt: string; sampleRate: number; vadThreshold: number; prefixPaddingMs: number; silenceDurationMs: number }
  | { type: 'dashscope'; id: UUID; name: string; apiKey: string; websocketUrl: string; model: string; language: string; sampleRate: number; vadThreshold: number; silenceDurationMs: number }
  | { type: 'volcengine'; id: UUID; name: string; apiKey: string; websocketUrl: string; resourceId: string; language: string }
  | { type: 'mimo'; id: UUID; name: string; apiKey: string; baseUrl: string; model: string; language: string; sampleRate: number; segmentDurationSec: number }
  | { type: 'step'; id: UUID; name: string; apiKey: string; baseUrl: string; model: string; language: string; sampleRate: number; segmentDurationSec: number; enableItn: boolean; enableTimestamp: boolean; hotwords: string[] }
```

**关键发现**：
- 来源：`WebDavSync.prepareBackupFile` 用 `JsonInstant`（`encodeDefaults = true`）序列化 `Settings`，所以所有字段（含默认值）都会出现在 JSON 中；`Settings.init`、`ProviderSetting.builtIn/description/shortDescription` 是 `@Transient`，不会出现
- UUID、时间（LocalDateTime/Instant）均序列化为字符串；`Set` → 数组；`Pair` → 二元组数组
- sealed class 统一带 `type` 判别字段；无 `@SerialName` 的枚举（ModelType、Modality、AffectScope、BackupItem 等）用大写类名，有 `@SerialName` 的用指定值
- 敏感字段（apiKey、password、accessToken、clientSecret 等）原样明文存储

