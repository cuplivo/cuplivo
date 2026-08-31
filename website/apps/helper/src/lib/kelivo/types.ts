/**
 * Kelivo / Cuplivo 备份格式类型定义（canonical，来源：kelivo.md 调研文档 + v1.2.0/v2.7.1 源码核实）
 * - chats.json: v1.1.17/v1.2.0 为 version 1；Cuplivo v2.4.0 起为 version 2（含 groupChats/groupMembers），
 *   v3.0.2 起上游锁回 version 1（Kelivo 旧导入端拒绝 v2，cuplivo/cuplivo#453）；
 *   restore 从不读取 version 字段，仅作标识
 * - settings.json: 扁平 `<功能>_v<n>` prefs 快照，集合类型均为 JSON 编码字符串
 */

/** ISO 8601 字符串（如 2026-07-03T12:34:56.123456） */
export type IsoDateTime = string;

/** JSON 编码的字符串值（解码后为注释所述结构） */
export type JsonString = string;

/** '<providerKey>::<modelId>' 复合模型引用 */
export type ModelRef = string;

// ===== chats.json =====

export interface ToolEvent {
  id: string;
  name: string;
  arguments: Record<string, unknown>;
  content: string | null;
  metadata?: Record<string, unknown>;
}

export interface Conversation {
  id: string;
  title: string;
  createdAt: IsoDateTime;
  updatedAt: IsoDateTime;
  messageIds: string[];
  isPinned: boolean;
  mcpServerIds: string[];
  assistantId: string | null;
  parentConversationId: string | null;
  truncateIndex: number;
  versionSelections: Record<string, number>;
  summary: string | null;
  lastSummarizedMessageCount: number;
  chatSuggestions: string[];
  conversationKind: string;
  /** kelivo v1.2.0 独有（兼容保真透传；Cuplivo 读取时忽略） */
  injectedMemoryHash?: string | null;
  lastMemoryExtractedOrder?: number;
}

export interface ChatMessage {
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
  subgroupId: string | null;
  version: number;
  promptTokens: number | null;
  completionTokens: number | null;
  cachedTokens: number | null;
  durationMs: number | null;
  isPreset: boolean;
  speakerAssistantId: string | null;
}

export interface GroupChat {
  id: string;
  name: string;
  avatar: string | null;
  conversationId: string;
  directorModelProvider: string | null;
  directorModelId: string | null;
  directorSystemPrompt: string;
  maxAssistantMessagesPerRound: number;
  assistantDetailInjectionMode: string;
  assistantDetailInjectionN: number;
  pendingCapAssistantMessageId: string | null;
  assistantMessagesThisRound: number;
  createdAt: IsoDateTime;
  updatedAt: IsoDateTime;
}

export interface GroupChatMember {
  groupChatId: string;
  memberKey: string;
  assistantId: string | null;
  sortOrder: number;
}

export interface ChatsFileV2 {
  /** Cuplivo v2.4.0 起写 2（含 groupChats/groupMembers）；restore 不校验，仅标识 */
  version: 1 | 2;
  conversations: Conversation[];
  messages: ChatMessage[];
  toolEvents: Record<string, ToolEvent[]>;
  geminiThoughtSigs: Record<string, string>;
  groupChats: GroupChat[];
  groupMembers: GroupChatMember[];
}

/** v1.1.17：无 groupChats/groupMembers；Conversation 缺部分字段；ChatMessage 缺 subgroupId/isPreset/speakerAssistantId */
export interface ChatsFileV1 {
  version: 1;
  conversations: Array<Partial<Conversation>>;
  messages: Array<Partial<ChatMessage>>;
  toolEvents: Record<string, ToolEvent[]>;
  geminiThoughtSigs: Record<string, string>;
}

export type ChatsFile = ChatsFileV2 | ChatsFileV1;

/** deleted.json：删除墓碑，按 entityType 分组，仅含 id 与 deletedAt（无内容） */
export interface DeletedFile {
  [entityType: string]: { id: string; deletedAt: IsoDateTime }[];
}

// ===== settings.json =====

export interface AssistantRegex {
  id: string;
  name: string;
  pattern: string;
  replacement: string;
  scopes: ('user' | 'assistant')[];
  visualOnly: boolean;
  replaceOnly: boolean;
  enabled: boolean;
}

export interface Assistant {
  id: string;
  name: string;
  avatar: string | null;
  useAssistantAvatar: boolean;
  useAssistantName: boolean;
  chatModelProvider: string | null;
  chatModelId: string | null;
  temperature: number | null;
  topP: number | null;
  contextMessageSize: number;
  limitContextMessages: boolean;
  streamOutput: boolean;
  thinkingBudget: number | null;
  maxTokens: number | null;
  systemPrompt: string;
  messageTemplate: string;
  searchEnabled: boolean;
  mcpServerIds: string[];
  localToolIds: string[];
  skillIds: string[];
  background: string | null;
  customHeaders: { name: string; value: string }[];
  customBody: { key: string; value: string }[];
  enableMemory: boolean;
  memoryMode: string;
  enableRecentChatsReference: boolean;
  recentChatsSummaryMessageCount: number;
  memoryRecordPrompt: string;
  presetMessages: { id: string; role: string; content: string }[];
  regexRules: AssistantRegex[];
  enableProactiveCare: boolean;
  proactiveCareNextMessageAt: IsoDateTime | null;
  proactiveCarePrompt: string;
  proactiveCareDecisionPrompt: string;
  docxMode: string;
  pdfMode: string;
  otherOfficeMode: string;
  ocrMode: string;
  enableTimeInjection: boolean;
  discoverable: boolean;
  handoffId: string | null;
  handoffDescription: string | null;
  createdAt: IsoDateTime;
  updatedAt: IsoDateTime;
}

export interface ProviderConfig {
  id: string;
  enabled: boolean;
  name: string;
  apiKey: string;
  baseUrl: string;
  providerType?: string;
  chatPath?: string;
  useResponseApi?: boolean;
  enableToolResultImages?: boolean;
  vertexAI?: boolean;
  location?: string;
  projectId?: string;
  serviceAccountJson?: string;
  models: string[];
  modelOverrides?: Record<
    string,
    {
      apiModelId?: string;
      name?: string;
      type?: 'chat' | 'embedding';
      input?: unknown[];
      output?: unknown[];
      abilities?: unknown[];
      tools?: unknown;
    }
  >;
  proxyEnabled?: boolean;
  proxyType?: string;
  proxyHost?: string;
  proxyPort?: string;
  proxyUsername?: string;
  proxyPassword?: string;
  avatarType?: 'emoji' | 'url' | 'file' | 'icon' | 'lobehub';
  avatarValue?: string;
  multiKeyEnabled?: boolean;
  apiKeys?: unknown[];
  keyManagement?: unknown;
  aihubmixAppCodeEnabled?: boolean;
  balanceEnabled?: boolean;
  balanceApiPath?: string;
  balanceResultPath?: string;
  claudePromptCachingEnabled: boolean;
  claudePromptCachingTtl?: '5m' | '1h';
  customHeaders?: { name: string; value: string }[] | null;
  customBody?: { key: string; value: string }[] | null;
}

export interface AssistantMemory {
  id: number;
  assistantId: string;
  content: string;
}

/** Kelivo v1.2.0 新版记忆 MemoryEntry 载荷（v1.2.0 起 memory_entry_rows 为主、blob 为兼容面） */
export interface MemoryEntry {
  id: string;
  scope: 'global' | 'assistant';
  assistantId?: string | null;
  type: 'identity' | 'workflow' | 'voice' | 'instruction';
  status: 'active' | 'archived';
  content: string;
  source: 'manual' | 'tool' | 'extracted' | 'distilled';
  relatedIds?: string[];
  migrationIds?: number[];
  createdAt: number;
  updatedAt: number;
}

export interface AssistantTag {
  id: string;
  name: string;
}

export interface WorldBookEntry {
  id: string;
  name: string;
  enabled: boolean;
  priority: number;
  position:
    | 'BEFORE_SYSTEM_PROMPT'
    | 'AFTER_SYSTEM_PROMPT'
    | 'TOP_OF_CHAT'
    | 'BOTTOM_OF_CHAT'
    | 'AT_DEPTH';
  content: string;
  injectDepth: number;
  role: 'USER' | 'ASSISTANT';
  keywords: string[];
  useRegex: boolean;
  caseSensitive: boolean;
  scanDepth: number;
  constantActive: boolean;
}

export interface WorldBook {
  id: string;
  name: string;
  description: string;
  enabled: boolean;
  entries: WorldBookEntry[];
}

export interface InstructionInjection {
  id: string;
  title: string;
  prompt: string;
  group: string;
}

export interface QuickPhrase {
  id: string;
  title: string;
  content: string;
  isGlobal: boolean;
  assistantId?: string | null;
}

export interface McpToolConfig {
  enabled: boolean;
  name: string;
  description?: string;
  params: { name: string; required: boolean; type?: string; default?: unknown }[];
  schema?: Record<string, unknown>;
  needsApproval: boolean;
}

export interface McpServerConfig {
  id: string;
  enabled: boolean;
  name: string;
  transport: 'sse' | 'http' | 'stdio' | 'inmemory';
  url: string;
  tools: McpToolConfig[];
  headers: Record<string, string>;
  command?: string;
  args: string[];
  env: Record<string, string>;
  workingDirectory?: string;
  heartbeatIntervalSeconds?: number;
  toolPrefix: string;
  oauth?: Record<string, unknown>;
  oauthToken?: Record<string, unknown>;
}

export interface SearchServiceOptions {
  type: string;
  id: string;
  apiKeys: unknown[];
  apiKey?: string;
  keyManagement?: unknown;
  [k: string]: unknown;
}

export interface TtsServiceOptions {
  kind: string;
  id: string;
  enabled: boolean;
  name: string;
  apiKey?: string;
  baseUrl?: string;
  model?: string;
  voice?: string;
  [k: string]: unknown;
}

/** settings.json 顶层：扁平键值快照，全部可选 */
export interface SettingsJson {
  // 应用/主题
  app_locale_v1?: string;
  theme_mode_v1?: string;
  theme_palette_v1?: string;
  use_dynamic_color_v1?: boolean;
  dynamic_color_seed_v1?: number;
  // 助手
  assistants_v1?: JsonString;
  current_assistant_id_v1?: string;
  ocr_enabled_v1?: boolean;
  // 供应商/模型
  provider_configs_v1?: JsonString;
  providers_order_v1?: string[];
  pinned_models_v1?: string[];
  selected_model_v1?: ModelRef;
  title_model_v1?: ModelRef;
  // 记忆/标签/世界书/指令注入/快捷短语
  assistant_memories_v1?: JsonString;
  memory_entries_v1?: JsonString;
  assistant_tags_v1?: JsonString;
  assistant_tag_map_v1?: JsonString;
  world_books_v1?: JsonString;
  world_books_active_ids_by_assistant_v1?: JsonString;
  instruction_injections_v1?: JsonString;
  instruction_injections_active_ids_by_assistant_v1?: JsonString;
  quick_phrases_v1?: JsonString;
  // MCP/搜索/TTS
  mcp_servers_v1?: JsonString;
  search_services_v1?: JsonString;
  search_selected_v1?: number;
  tts_services_v1?: JsonString;
  tts_selected_v1?: number;
  tts_speech_rate_v1?: number;
  // 备份提醒
  backup_reminder_enabled_v1?: boolean;
  backup_reminder_interval_days_v1?: number;
  backup_reminder_last_backup_at_v1?: IsoDateTime;
  // 显示（迁移时按需写入的少数安全键）
  display_show_model_icon_v1?: boolean;
  display_show_model_name_v1?: boolean;
  display_show_token_stats_v1?: boolean;
  display_show_model_timestamp_v1?: boolean;
  display_show_user_timestamp_v1?: boolean;
  display_enter_to_send_on_mobile_v1?: boolean;
  display_auto_scroll_enabled_v1?: boolean;
  display_enable_math_rendering_v1?: boolean;
  display_auto_collapse_code_block_v1?: boolean;
  display_mobile_code_block_wrap_v1?: boolean;
  display_show_app_updates_v1?: boolean;
  // 其余键透传（不修改，仅保留）
  [k: string]: unknown;
}

/** Kelivo 备份 zip 顶层条目 */
export const KELIVO_ZIP_ENTRIES = [
  'settings.json',
  'chats.json',
  'deleted.json',
  'skills/',
  'upload/',
  'avatars/',
  'images/',
  'fonts/',
  'workspaces/',
] as const;
