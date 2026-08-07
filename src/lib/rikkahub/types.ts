/**
 * RikkaHub 备份格式类型定义（canonical，来源：rikkahub.md 调研文档）
 * - settings.json: kotlinx.serialization 序列化的嵌套 Settings data class（camelCase，encodeDefaults=true）
 * - rikka_hub.db: Room（version 24），8 张业务表
 * - 消息为 parts 结构，modelId 引用 providers[].models[].id (UUID)
 */

export type Uuid = string;

// ===== settings.json =====

export interface Settings {
  dynamicColor: boolean;
  themeId: string;
  customThemes: CustomTheme[];
  developerMode: boolean;
  displaySetting: DisplaySetting;
  favoriteModels: Uuid[];
  chatModelId: Uuid;
  fastModelId: Uuid;
  titleModelId: Uuid | null;
  imageGenerationModelId: Uuid;
  titlePrompt: string;
  translateModeId: Uuid;
  translatePrompt: string;
  translateThinkingBudget: number;
  enableSuggestion: boolean;
  suggestionModelId: Uuid | null;
  suggestionPrompt: string;
  ocrModelId: Uuid;
  ocrPrompt: string;
  compressModelId: Uuid;
  compressPrompt: string;
  assistantId: Uuid;
  providers: ProviderSetting[];
  assistants: Assistant[];
  assistantTags: Tag[];
  searchServices: SearchServiceOptions[];
  searchCommonOptions: SearchCommonOptions;
  searchServiceSelected: number;
  mcpServers: McpServerConfig[];
  webDavConfig: WebDavConfig;
  s3Config: S3Config;
  ttsProviders: TTSProviderSetting[];
  selectedTTSProviderId: Uuid;
  defaultTTSPlaybackSpeed: number;
  asrProviders: ASRProviderSetting[];
  selectedASRProviderId: Uuid | null;
  modeInjections: ModeInjection[];
  lorebooks: Lorebook[];
  quickMessages: QuickMessage[];
  webServerEnabled: boolean;
  webServerPort: number;
  webServerJwtEnabled: boolean;
  webServerAccessPassword: string;
  webServerLocalhostOnly: boolean;
  backupReminderConfig: BackupReminderConfig;
  launchCount: number;
  sponsorAlertDismissedAt: number;
}

export interface CustomTheme {
  id: string;
  name: string;
  primaryColorArgb: number;
  secondaryColorArgb: number | null;
  tertiaryColorArgb: number | null;
}

export interface DisplaySetting {
  userAvatar: Avatar;
  userNickname: string;
  useAppIconStyleLoadingIndicator: boolean;
  showUserAvatar: boolean;
  showAssistantBubble: boolean;
  bubbleOpacity: number;
  showModelIcon: boolean;
  showModelName: boolean;
  showDateTimeInMessage: boolean;
  showTokenUsage: boolean;
  showThinkingContent: boolean;
  autoCloseThinking: boolean;
  showUpdates: boolean;
  showMessageJumper: boolean;
  messageJumperOnLeft: boolean;
  fontSizeRatio: number;
  enableMessageGenerationHapticEffect: boolean;
  skipCropImage: boolean;
  enableNotificationOnMessageGeneration: boolean;
  enableLiveUpdateNotification: boolean;
  codeBlockAutoWrap: boolean;
  codeBlockAutoCollapse: boolean;
  showLineNumbers: boolean;
  ttsOnlyReadQuoted: boolean;
  ttsOnlyReadOutsideBrackets: boolean;
  autoPlayTTSAfterGeneration: boolean;
  pasteLongTextAsFile: boolean;
  pasteLongTextThreshold: number;
  sendOnEnter: boolean;
  enableAutoScroll: boolean;
  enableLatexRendering: boolean;
  enableBlurEffect: boolean;
  chatFontFamily: 'default' | 'serif' | 'monospace' | 'custom';
  chatCustomFontPath: string;
  chatCustomFontName: string;
  enableVolumeKeyScroll: boolean;
  volumeKeyScrollRatio: number;
}

export type Avatar =
  | { type: 'Dummy' }
  | { type: 'Emoji'; content: string }
  | { type: 'Image'; url: string };

// ===== 提供商 =====

export type ProviderSetting = ProviderOpenAI | ProviderGoogle | ProviderClaude;

interface ProviderBase {
  id: Uuid;
  enabled: boolean;
  name: string;
  models: Model[];
  balanceOption: BalanceOption;
}

export interface ProviderOpenAI extends ProviderBase {
  type: 'openai';
  apiKey: string;
  baseUrl: string;
  chatCompletionsPath: string;
  useResponseApi: boolean;
  includeHistoryReasoning: boolean;
}

export interface ProviderGoogle extends ProviderBase {
  type: 'google';
  apiKey: string;
  baseUrl: string;
  vertexAI: boolean;
  useServiceAccount: boolean;
  privateKey: string;
  serviceAccountEmail: string;
  location: string;
  projectId: string;
}

export interface ProviderClaude extends ProviderBase {
  type: 'claude';
  apiKey: string;
  baseUrl: string;
  promptCaching: boolean;
  promptCacheTtl: '5m' | '1h';
}

export interface BalanceOption {
  enabled: boolean;
  apiPath: string;
  resultPath: string;
}

export interface Model {
  modelId: string;
  displayName: string;
  id: Uuid;
  type: 'CHAT' | 'IMAGE' | 'EMBEDDING';
  customHeaders: CustomHeader[];
  customBodies: CustomBody[];
  inputModalities: ('TEXT' | 'IMAGE')[];
  outputModalities: ('TEXT' | 'IMAGE')[];
  abilities: ('TOOL' | 'REASONING')[];
  tools: ('search' | 'url_context' | 'image_generation')[];
  providerOverwrite: ProviderSetting | null;
}

export interface CustomHeader {
  name: string;
  value: string;
}

export interface CustomBody {
  key: string;
  value: unknown;
}

// ===== 助手 =====

export interface Assistant {
  id: Uuid;
  chatModelId: Uuid | null;
  name: string;
  avatar: Avatar;
  useAssistantAvatar: boolean;
  tags: Uuid[];
  systemPrompt: string;
  temperature: number | null;
  topP: number | null;
  contextMessageLimit: number;
  streamOutput: boolean;
  enableMemory: boolean;
  useGlobalMemory: boolean;
  enableRecentChatsReference: boolean;
  messageTemplate: string;
  presetMessages: UIMessage[];
  quickMessageIds: Uuid[];
  regexes: AssistantRegex[];
  reasoningLevel: 'off' | 'auto' | 'low' | 'medium' | 'high' | 'xhigh';
  maxTokens: number | null;
  customHeaders: CustomHeader[];
  customBodies: CustomBody[];
  mcpServers: Uuid[];
  localTools: LocalToolOption[];
  enableWebSearch: boolean;
  workspaceId: Uuid | null;
  background: string | null;
  backgroundOpacity: number;
  useGradientBackground: boolean;
  modeInjectionIds: Uuid[];
  lorebookIds: Uuid[];
  enabledSkills: string[];
  enableTimeReminder: boolean;
  allowConversationSystemPrompt: boolean;
  allowConversationPromptInjection: boolean;
}

export type LocalToolOption =
  | 'javascript_engine'
  | 'time_info'
  | 'clipboard'
  | 'tts'
  | 'ask_user'
  | 'screen_time'
  | 'calendar';

export interface AssistantRegex {
  id: Uuid;
  name: string;
  enabled: boolean;
  findRegex: string;
  replaceString: string;
  affectingScope: ('USER' | 'ASSISTANT')[];
  visualOnly: boolean;
}

// ===== 消息 =====

export interface UIMessage {
  id: Uuid;
  role: 'system' | 'user' | 'assistant' | 'tool';
  parts: UIMessagePart[];
  annotations: UIMessageAnnotation[];
  createdAt: string;
  finishedAt: string | null;
  modelId: Uuid | null;
  usage: TokenUsage | null;
  translation: string | null;
}

export interface TokenUsage {
  promptTokens: number;
  completionTokens: number;
  cachedTokens: number;
  totalTokens: number;
}

export type UIMessagePart =
  | { type: 'text'; text: string; metadata: JsonObject | null }
  | { type: 'image'; url: string; metadata: JsonObject | null }
  | { type: 'video'; url: string; metadata: JsonObject | null }
  | { type: 'audio'; url: string; metadata: JsonObject | null }
  | { type: 'document'; url: string; fileName: string; mime: string; metadata: JsonObject | null }
  | { type: 'reasoning'; reasoning: string; createdAt: string; finishedAt: string | null; metadata: JsonObject | null }
  | { type: 'search'; metadata: JsonObject | null }
  | { type: 'tool_call'; toolCallId: string; toolName: string; arguments: string; approvalState: ToolApprovalState; metadata: JsonObject | null }
  | { type: 'tool_result'; toolCallId: string; toolName: string; content: unknown; arguments: unknown; metadata: JsonObject | null }
  | { type: 'tool'; toolCallId: string; toolName: string; input: string; output: UIMessagePart[]; approvalState: ToolApprovalState; metadata: JsonObject | null };

export type JsonObject = Record<string, unknown>;

export type ToolApprovalState =
  | { type: 'auto' }
  | { type: 'pending' }
  | { type: 'approved' }
  | { type: 'denied'; reason: string }
  | { type: 'answered'; answer: string };

export type UIMessageAnnotation = { type: 'url_citation'; title: string; url: string };

// ===== 标签 / 快捷消息 =====

export interface Tag {
  id: Uuid;
  name: string;
}

export interface QuickMessage {
  id: Uuid;
  title: string;
  content: string;
}

// ===== 提示词注入 / Lorebook =====

interface PromptInjectionBase {
  id: Uuid;
  name: string;
  enabled: boolean;
  priority: number;
  position: 'before_system_prompt' | 'after_system_prompt' | 'top_of_chat' | 'bottom_of_chat' | 'at_depth';
  content: string;
  injectDepth: number;
  role: 'system' | 'user' | 'assistant' | 'tool';
}

export interface ModeInjection extends PromptInjectionBase {
  type: 'mode';
}

export interface RegexInjection extends PromptInjectionBase {
  type: 'regex';
  keywords: string[];
  useRegex: boolean;
  caseSensitive: boolean;
  scanDepth: number;
  constantActive: boolean;
}

export interface Lorebook {
  id: Uuid;
  name: string;
  description: string;
  enabled: boolean;
  entries: RegexInjection[];
}

// ===== 搜索 =====

export interface SearchCommonOptions {
  resultSize: number;
}

export type SearchServiceOptions = {
  type: string;
  id: Uuid;
  apiKey?: string;
  url?: string;
  engines?: string;
  language?: string;
  username?: string;
  password?: string;
  depth?: string;
  [k: string]: unknown;
};

// ===== MCP =====

export type McpServerConfig =
  | { type: 'sse'; id: Uuid; commonOptions: McpCommonOptions; url: string }
  | { type: 'streamable_http'; id: Uuid; commonOptions: McpCommonOptions; url: string };

export interface McpCommonOptions {
  enable: boolean;
  name: string;
  headers: [string, string][];
  tools: McpTool[];
  oauth: McpOAuthState | null;
}

export interface McpOAuthState {
  enabled: boolean;
  clientId: string | null;
  clientSecret: string | null;
  authorizationEndpoint: string | null;
  tokenEndpoint: string | null;
  registrationEndpoint: string | null;
  scope: string | null;
  accessToken: string | null;
  refreshToken: string | null;
  expiresAt: number;
}

export interface McpTool {
  enable: boolean;
  name: string;
  description: string | null;
  inputSchema: InputSchema | null;
  needsApproval: boolean;
}

export type InputSchema = { type: 'object'; properties: Record<string, unknown>; required: string[] | null };

// ===== 备份配置 =====

export interface WebDavConfig {
  url: string;
  username: string;
  password: string;
  path: string;
  items: ('DATABASE' | 'FILES')[];
}

export interface S3Config {
  endpoint: string;
  accessKeyId: string;
  secretAccessKey: string;
  bucket: string;
  region: string;
  pathStyle: boolean;
  items: ('DATABASE' | 'FILES')[];
}

export interface BackupReminderConfig {
  enabled: boolean;
  intervalDays: number;
  lastBackupTime: number;
}

// ===== TTS / ASR =====

export type TTSProviderSetting = {
  type: string;
  id: Uuid;
  name: string;
  apiKey?: string;
  baseUrl?: string;
  model?: string;
  voice?: string;
  [k: string]: unknown;
};

export type ASRProviderSetting = {
  type: string;
  id: Uuid;
  name: string;
  [k: string]: unknown;
};

// ===== SQLite（Room v24）=====

export interface ConversationEntity {
  id: string;
  assistant_id: string;
  title: string;
  nodes: string;
  create_at: number;
  update_at: number;
  suggestions: string;
  is_pinned: boolean;
  custom_system_prompt: string;
  mode_injection_ids: string;
  lorebook_ids: string;
  workspace_cwd: string;
  folder_id: string;
}

/** 回合节点：同一轮 regenerate 的 alternatives，select_index 为当前展示版本 */
export interface MessageNodeEntity {
  id: string;
  conversation_id: string;
  node_index: number;
  messages: string;
  select_index: number;
}

/** ConversationEntity.nodes 内的节点条目（与 message_node 表同构） */
export interface NodeTurn {
  id: string;
  messages: UIMessage[];
  select_index: number;
}

export interface MemoryEntity {
  id: number;
  assistant_id: string;
  content: string;
}

export interface GenMediaEntity {
  id: number;
  path: string;
  model_id: string;
  prompt: string;
  create_at: number;
  type: string;
  source_paths: string | null;
}

export interface ManagedFileEntity {
  id: number;
  folder: string;
  relative_path: string;
  display_name: string;
  mime_type: string;
  size_bytes: number;
  created_at: number;
  updated_at: number;
}

export interface FavoriteEntity {
  id: string;
  type: string;
  ref_key: string;
  ref_json: string;
  snapshot_json: string;
  meta_json: string | null;
  created_at: number;
  updated_at: number;
}

export interface WorkspaceEntity {
  id: string;
  name: string;
  root: string;
  shell_status: string;
  created_at: number;
  updated_at: number;
  last_access_at: number | null;
  tool_approvals: string;
}

export interface FolderEntity {
  id: string;
  assistant_id: string;
  name: string;
  sort_index: number;
  create_at: number;
}
