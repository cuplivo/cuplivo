/** 设置层：语义清晰 1:1 映射 / 无对应丢弃 / 备份凭据默认不复制 */
import type { SettingsJson, McpServerConfig, SearchServiceOptions, TtsServiceOptions, WorldBook, WorldBookEntry } from '../kelivo/types';
import type { Settings } from '../rikkahub/types';
import { isoFromEpochMillis } from '../rikkahub/util';
import type { MigrateContext } from './context';
import { drop } from '../report';

/** RikkaHub type → Kelivo search type（同名集合；其余丢弃） */
const SEARCH_TYPE_MAP = new Set([
  'bing_local', 'tavily', 'exa', 'zhipu', 'searxng', 'linkup', 'brave', 'metaso',
  'ollama', 'perplexity', 'grok', 'serper', 'jina', 'bocha',
]);

/** RikkaHub TTS kind → Kelivo kind（同名集合；system/step/fish-audio 丢弃） */
const TTS_KIND_MAP = new Set(['openai', 'gemini', 'minimax', 'qwen', 'groq', 'xai', 'mimo', 'elevenlabs']);

const POSITION_MAP: Record<string, WorldBookEntry['position']> = {
  before_system_prompt: 'BEFORE_SYSTEM_PROMPT',
  after_system_prompt: 'AFTER_SYSTEM_PROMPT',
  top_of_chat: 'TOP_OF_CHAT',
  bottom_of_chat: 'BOTTOM_OF_CHAT',
  at_depth: 'AT_DEPTH',
};

function mapSearchServices(ctx: MigrateContext): { list: SearchServiceOptions[]; selectedIndex: number } {
  const { settings, report } = ctx;
  const list: SearchServiceOptions[] = [];
  let dropped = 0;
  const droppedNames: string[] = [];
  for (const s of settings.searchServices) {
    if (!SEARCH_TYPE_MAP.has(s.type)) {
      dropped++;
      if (droppedNames.length < 5) droppedNames.push(`${s.type} (${s.name ?? s.id})`);
      continue;
    }
    const item: SearchServiceOptions = {
      type: s.type,
      id: s.id,
      apiKeys: [],
    };
    for (const k of ['apiKey', 'url', 'engines', 'language', 'username', 'password', 'depth',
      'maxTokens', 'maxTokensPerPage', 'summary', 'model', 'customUrl', 'systemPrompt',
      'searchUrl', 'scrapeUrl'] as const) {
      const v = s[k];
      if (typeof v === 'string' || typeof v === 'number' || typeof v === 'boolean') {
        (item as Record<string, unknown>)[k] = v;
      }
    }
    list.push(item);
  }
  drop(report, '搜索服务（Kelivo 不支持的类型）', dropped, droppedNames);

  const selectedId = settings.searchServices[settings.searchServiceSelected]?.id;
  let selectedIndex = 0;
  if (selectedId) {
    const idx = list.findIndex((x) => x.id === selectedId);
    if (idx >= 0) selectedIndex = idx;
  }
  return { list, selectedIndex };
}

function mapTtsProviders(ctx: MigrateContext): { list: TtsServiceOptions[]; selectedIndex: number | null } {
  const { settings, report } = ctx;
  const list: TtsServiceOptions[] = [];
  let dropped = 0;
  const droppedNames: string[] = [];
  for (const t of settings.ttsProviders) {
    if (!TTS_KIND_MAP.has(t.type)) {
      dropped++;
      if (droppedNames.length < 5) droppedNames.push(`${t.type} (${t.name})`);
      continue;
    }
    const item: TtsServiceOptions = {
      kind: t.type,
      id: t.id,
      enabled: true,
      name: t.name,
    };
    for (const k of ['apiKey', 'baseUrl', 'model', 'voice'] as const) {
      const v = t[k];
      if (typeof v === 'string') item[k] = v;
    }
    // 保留 kind 特有字段（voiceId/speed 等）
    for (const [k, v] of Object.entries(t)) {
      if (['type', 'id', 'name', 'apiKey', 'baseUrl', 'model', 'voice'].includes(k)) continue;
      if (typeof v === 'string' || typeof v === 'number' || typeof v === 'boolean' || v === null) {
        (item as Record<string, unknown>)[k] = v;
      }
    }
    list.push(item);
  }
  drop(report, 'TTS 服务（Kelivo 不支持的 kind）', dropped, droppedNames);

  const sel = settings.ttsProviders.find((t) => t.id === settings.selectedTTSProviderId);
  if (!sel) return { list, selectedIndex: null };
  if (sel.type === 'system') return { list, selectedIndex: -1 };
  const idx = list.findIndex((x) => x.id === sel.id);
  return { list, selectedIndex: idx >= 0 ? idx : null };
}

function mapMcpServers(ctx: MigrateContext): McpServerConfig[] {
  const { settings } = ctx;
  const out: McpServerConfig[] = [];
  for (const m of settings.mcpServers) {
    const common = m.commonOptions;
    out.push({
      id: m.id,
      enabled: common.enable,
      name: common.name,
      transport: m.type === 'sse' ? 'sse' : 'http',
      url: m.url,
      tools: common.tools.map((t) => {
        const params: { name: string; required: boolean; type?: string; default?: unknown }[] = [];
        if (t.inputSchema) {
          const props = t.inputSchema.properties as Record<string, { type?: string; default?: unknown }>;
          for (const [name, prop] of Object.entries(props)) {
            params.push({
              name,
              required: !!t.inputSchema.required?.includes(name),
              type: typeof prop.type === 'string' ? prop.type : undefined,
              default: prop.default,
            });
          }
        }
        return {
          enabled: t.enable,
          name: t.name,
          description: t.description ?? undefined,
          params,
          needsApproval: t.needsApproval,
        };
      }),
      headers: Object.fromEntries(common.headers ?? []),
      args: [],
      env: {},
      toolPrefix: '',
      oauth: common.oauth
        ? {
            authorizationEndpoint: common.oauth.authorizationEndpoint ?? '',
            tokenEndpoint: common.oauth.tokenEndpoint ?? '',
            clientId: common.oauth.clientId ?? '',
            clientSecret: common.oauth.clientSecret ?? '',
            scopes: common.oauth.scope ?? '',
            redirectUri: '',
            clientRegistrationVersion: 0,
          }
        : undefined,
      oauthToken: common.oauth
        ? {
            access_token: common.oauth.accessToken ?? '',
            token_type: 'Bearer',
            refresh_token: common.oauth.refreshToken ?? '',
            expires_in: undefined,
            scope: common.oauth.scope ?? '',
            issued_at: 0,
          }
        : undefined,
    });
  }
  return out;
}

function mapLorebooks(ctx: MigrateContext): { books: WorldBook[]; droppedEntries: number } {
  const { settings } = ctx;
  let droppedEntries = 0;
  const books: WorldBook[] = settings.lorebooks.map((l) => ({
    id: l.id,
    name: l.name,
    description: l.description,
    enabled: l.enabled,
    entries: l.entries
      .filter((e) => {
        const pos = POSITION_MAP[e.position];
        const ok = pos !== undefined && (e.role === 'user' || e.role === 'assistant');
        if (!ok) droppedEntries++;
        return ok;
      })
      .map((e) => ({
        id: e.id,
        name: e.name,
        enabled: e.enabled,
        priority: e.priority,
        position: POSITION_MAP[e.position]!,
        content: e.content,
        injectDepth: e.injectDepth,
        role: e.role === 'assistant' ? 'ASSISTANT' : 'USER',
        keywords: e.keywords,
        useRegex: e.useRegex,
        caseSensitive: e.caseSensitive,
        scanDepth: e.scanDepth,
        constantActive: e.constantActive,
      })),
  }));
  return { books, droppedEntries };
}

const DISPLAY_MAP: Record<keyof Settings['displaySetting'], string | null> = {
  showModelIcon: 'display_show_model_icon_v1',
  showModelName: 'display_show_model_name_v1',
  showTokenUsage: 'display_show_token_stats_v1',
  showDateTimeInMessage: null,
  sendOnEnter: 'display_enter_to_send_on_mobile_v1',
  enableAutoScroll: 'display_auto_scroll_enabled_v1',
  enableLatexRendering: 'display_enable_math_rendering_v1',
  codeBlockAutoCollapse: 'display_auto_collapse_code_block_v1',
  codeBlockAutoWrap: 'display_mobile_code_block_wrap_v1',
  showUpdates: 'display_show_app_updates_v1',
  userAvatar: null,
  userNickname: null,
  useAppIconStyleLoadingIndicator: null,
  showUserAvatar: null,
  showAssistantBubble: null,
  bubbleOpacity: null,
  showThinkingContent: null,
  autoCloseThinking: null,
  showMessageJumper: null,
  messageJumperOnLeft: null,
  fontSizeRatio: null,
  enableMessageGenerationHapticEffect: null,
  skipCropImage: null,
  enableNotificationOnMessageGeneration: null,
  enableLiveUpdateNotification: null,
  showLineNumbers: null,
  ttsOnlyReadQuoted: null,
  ttsOnlyReadOutsideBrackets: null,
  autoPlayTTSAfterGeneration: null,
  pasteLongTextAsFile: null,
  pasteLongTextThreshold: null,
  enableBlurEffect: null,
  chatFontFamily: null,
  chatCustomFontPath: null,
  chatCustomFontName: null,
  enableVolumeKeyScroll: null,
  volumeKeyScrollRatio: null,
};

export function mapSettings(ctx: MigrateContext, extras: {
  assistants: SettingsJson['assistants_v1'];
  providerConfigs: SettingsJson['provider_configs_v1'];
  providersOrder: string[];
  pinned: string[];
  selected: string | null;
  titleModel: string | null;
  tagList: { id: string; name: string }[];
  tagMap: Record<string, string>;
  lorebookIdsByAssistant: Record<string, string[]>;
  injectionIdsByAssistant: Record<string, string[]>;
}): SettingsJson {
  const { settings, report } = ctx;
  const out: SettingsJson = {};

  // 助手与提供商
  out.assistants_v1 = extras.assistants;
  out.provider_configs_v1 = extras.providerConfigs;
  if (extras.providersOrder.length > 0) out.providers_order_v1 = extras.providersOrder;
  if (extras.pinned.length > 0) out.pinned_models_v1 = extras.pinned;
  if (extras.selected) out.selected_model_v1 = extras.selected;
  if (extras.titleModel) out.title_model_v1 = extras.titleModel;
  out.current_assistant_id_v1 = settings.assistantId;

  // 标签 / 记忆
  if (extras.tagList.length > 0) out.assistant_tags_v1 = JSON.stringify(extras.tagList);
  if (Object.keys(extras.tagMap).length > 0) out.assistant_tag_map_v1 = JSON.stringify(extras.tagMap);
  try {
    const memories = ctx.source.db?.queryAll<{ id: number; assistant_id: string; content: string }>(
      'SELECT id, assistant_id, content FROM MemoryEntity',
    );
    if (memories && memories.length > 0) {
      out.assistant_memories_v1 = JSON.stringify(
        memories.map((m) => ({ id: m.id, assistantId: m.assistant_id, content: m.content })),
      );
      report.totals.memories = memories.length;
    }
  } catch {
    drop(report, 'MemoryEntity 表不可读', 1);
  }

  // MCP / 搜索 / TTS
  const mcp = mapMcpServers(ctx);
  if (mcp.length > 0) out.mcp_servers_v1 = JSON.stringify(mcp);
  const search = mapSearchServices(ctx);
  if (search.list.length > 0) {
    out.search_services_v1 = JSON.stringify(search.list);
    out.search_selected_v1 = search.selectedIndex;
  }
  const tts = mapTtsProviders(ctx);
  if (tts.list.length > 0) {
    out.tts_services_v1 = JSON.stringify(tts.list);
    if (tts.selectedIndex !== null) out.tts_selected_v1 = tts.selectedIndex;
  }
  if (settings.defaultTTSPlaybackSpeed) out.tts_speech_rate_v1 = settings.defaultTTSPlaybackSpeed;

  // 快捷消息（全局）
  if (settings.quickMessages.length > 0) {
    out.quick_phrases_v1 = JSON.stringify(
      settings.quickMessages.map((q) => ({ id: q.id, title: q.title, content: q.content, isGlobal: true })),
    );
  }

  // 世界书 / 指令注入
  const lorebooks = mapLorebooks(ctx);
  if (lorebooks.books.length > 0) out.world_books_v1 = JSON.stringify(lorebooks.books);
  if (lorebooks.droppedEntries > 0) drop(report, '世界书条目（position/role 无法映射）', lorebooks.droppedEntries);
  if (Object.keys(extras.lorebookIdsByAssistant).length > 0) {
    out.world_books_active_ids_by_assistant_v1 = JSON.stringify(extras.lorebookIdsByAssistant);
  }
  if (settings.modeInjections.length > 0) {
    out.instruction_injections_v1 = JSON.stringify(
      settings.modeInjections.map((m) => ({ id: m.id, title: m.name, prompt: m.content, group: 'default' })),
    );
  }
  if (Object.keys(extras.injectionIdsByAssistant).length > 0) {
    out.instruction_injections_active_ids_by_assistant_v1 = JSON.stringify(extras.injectionIdsByAssistant);
  }

  // 备份提醒
  const b = settings.backupReminderConfig;
  if (b) {
    out.backup_reminder_enabled_v1 = b.enabled;
    out.backup_reminder_interval_days_v1 = b.intervalDays;
    if (b.lastBackupTime) out.backup_reminder_last_backup_at_v1 = isoFromEpochMillis(b.lastBackupTime);
  }

  // 显示（安全键）
  const d = settings.displaySetting;
  for (const [key, kelivoKey] of Object.entries(DISPLAY_MAP)) {
    if (!kelivoKey) continue;
    const v = d[key as keyof Settings['displaySetting']];
    if (typeof v === 'boolean') (out as Record<string, unknown>)[kelivoKey] = v;
  }
  if (d.showDateTimeInMessage) {
    out.display_show_model_timestamp_v1 = true;
    out.display_show_user_timestamp_v1 = true;
  }

  // 丢弃组
  const droppedDetails: [string, number][] = [
    ['ASR 服务', settings.asrProviders.length],
    ['WebServer 配置', settings.webServerEnabled ? 1 : 0],
    ['工作区（workspaces）', 0],
    ['收藏（favorites）', 0],
    ['生成媒体记录（gen_media）', 0],
    ['主题/动态取色', settings.dynamicColor ? 1 : 0],
    ['TTS/OCR/翻译/压缩/建议 专用模型键', settings.imageGenerationModelId ? 1 : 0],
  ];
  for (const [category, count] of droppedDetails) {
    drop(report, category, count);
  }

  // 敏感组：备份凭据默认不复制
  if (settings.webDavConfig?.url || settings.s3Config?.bucket) {
    report.warnings.push('RikkaHub 的 WebDAV/S3 备份凭据未迁移（避免目录冲突与凭据泄露），如需沿用请在 Kelivo 中手动配置。');
  }

  return out;
}
