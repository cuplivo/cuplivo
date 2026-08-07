/**
 * 端到端测试：构造合成 RikkaHub 备份 → 迁移 → 校验输出
 * 运行：pnpm tsx scripts/e2e-test.ts
 */
import JSZip from 'jszip';
import assert from 'node:assert/strict';
import sqlite3InitModule from '@sqlite.org/sqlite-wasm';
import { migrateRikkaHubToKelivo } from '../src/lib/migrate';
import { runRecovery, RECOVERY_ASSISTANT_NAME } from '../src/lib/kelivo/recovery';
import type { SettingsJson } from '../src/lib/kelivo/types';

const sqlite3 = await sqlite3InitModule({ print: () => {}, printErr: () => {} });

const DEFAULT_ASSISTANT = '0950e2dc-9bd5-4801-afa3-aa887aa36b4e';
const PROVIDER_ID = 'prov-1';
const MODEL_ID = 'model-1';
const AST_ID = 'ast-1';

// ---------- 1. 构造 RikkaHub SQLite（真实结构：WAL 模式 + nodes 恒 "[]" + message_node 表） ----------
let buildCounter = 0;
function buildDb(): { db: Uint8Array; wal: Uint8Array | null } {
  buildCounter++;
  const db = new sqlite3.oo1.DB(`/build_${buildCounter}.db`, 'c');
  db.exec('PRAGMA journal_mode=WAL');
  db.exec(`
    CREATE TABLE room_master_table (id INTEGER PRIMARY KEY, identity_hash TEXT);
    CREATE TABLE ConversationEntity (
      id TEXT PRIMARY KEY, assistant_id TEXT, title TEXT, nodes TEXT,
      create_at INTEGER, update_at INTEGER, suggestions TEXT, is_pinned INTEGER,
      custom_system_prompt TEXT, mode_injection_ids TEXT, lorebook_ids TEXT,
      workspace_cwd TEXT, folder_id TEXT
    );
    CREATE TABLE message_node (
      id TEXT PRIMARY KEY, conversation_id TEXT, node_index INTEGER,
      messages TEXT, select_index INTEGER
    );
    CREATE TABLE MemoryEntity (id INTEGER PRIMARY KEY, assistant_id TEXT, content TEXT);
    CREATE TABLE conversation_folder (id TEXT PRIMARY KEY, assistant_id TEXT, name TEXT, sort_index INTEGER, create_at INTEGER);
  `);
  db.exec(`INSERT INTO room_master_table VALUES (24, 'hash')`);
  db.exec(`INSERT INTO MemoryEntity VALUES (1, 'ast-1', '记得用户喜欢喝咖啡')`);
  db.exec(`INSERT INTO conversation_folder VALUES ('folder-1', '${DEFAULT_ASSISTANT}', '我的写作助手', 0, 0)`);

  const alt1 = {
    id: 'msg-1a', role: 'user', parts: [{ type: 'text', text: '旧版本提问', metadata: null }],
    annotations: [], createdAt: '2026-01-01T10:00:00.000', finishedAt: null,
    modelId: null, usage: null, translation: null,
  };
  const alt2 = {
    id: 'msg-1b', role: 'user', parts: [{ type: 'text', text: '选中版本提问', metadata: null }],
    annotations: [], createdAt: '2026-01-01T10:00:01.000', finishedAt: null,
    modelId: null, usage: null, translation: null,
  };
  const assistantMsg = {
    id: 'msg-2', role: 'assistant',
    parts: [
      { type: 'text', text: '回答内容', metadata: null },
      { type: 'image', url: 'upload/paste_123.png', metadata: null },
      { type: 'reasoning', reasoning: '深度思考过程', createdAt: '2026-01-01T10:00:02.000', finishedAt: '2026-01-01T10:00:03.000', metadata: null },
      { type: 'tool', toolCallId: 'call-1', toolName: 'web_search', input: '{"query":"test"}', output: [{ type: 'text', text: '结果A', metadata: null }], approvalState: { type: 'auto' }, metadata: null },
    ],
    annotations: [], createdAt: '2026-01-01T10:00:04.000', finishedAt: '2026-01-01T10:00:05.000',
    modelId: MODEL_ID, usage: { promptTokens: 10, completionTokens: 20, cachedTokens: 0, totalTokens: 30 }, translation: null,
  };
  const alt3 = { ...alt2, id: 'msg-3' };

  // 真实结构：ConversationEntity.nodes 恒为 "[]"；节点存于 message_node 表
  db.exec(
    `INSERT INTO ConversationEntity VALUES ('conv-1', '${AST_ID}', '测试会话', '[]', 1767250000000, 1767250005000, '["建议1"]', 1, '', '[]', '[]', '', '')`,
  );
  db.exec(
    `INSERT INTO ConversationEntity VALUES ('conv-2', '${DEFAULT_ASSISTANT}', '默认助手会话', '[]', 1767250000000, 1767250005000, '[]', 0, '你是我的写作搭档', '[]', '[]', '', '')`,
  );
  db.exec(
    `INSERT INTO message_node VALUES ('node-1', 'conv-1', 0, '${JSON.stringify([alt1, alt2])}', 1)`,
  );
  db.exec(
    `INSERT INTO message_node VALUES ('node-2', 'conv-1', 1, '${JSON.stringify([assistantMsg])}', 0)`,
  );
  db.exec(
    `INSERT INTO message_node VALUES ('node-3', 'conv-2', 0, '${JSON.stringify([alt3])}', 0)`,
  );

  const dbBytes = sqlite3.capi.sqlite3_js_db_export(db.pointer);
  db.close();
  // 不导出 wal：export 已含未 checkpoint 数据；zip 不含 wal 时验证非 WAL 路径
  return { db: dbBytes, wal: null };
}

// ---------- 2. 构造 settings.json ----------
function buildSettings(): string {
  const settings = {
    dynamicColor: true,
    themeId: 'default',
    customThemes: [],
    developerMode: false,
    displaySetting: {
      showModelIcon: true, showModelName: true, showDateTimeInMessage: true, showTokenUsage: true,
      sendOnEnter: true, enableAutoScroll: false, enableLatexRendering: true, codeBlockAutoCollapse: true,
      codeBlockAutoWrap: true, showUpdates: false, userAvatar: { type: 'Dummy' }, userNickname: '',
    },
    favoriteModels: [MODEL_ID],
    chatModelId: MODEL_ID,
    fastModelId: MODEL_ID,
    titleModelId: null,
    imageGenerationModelId: MODEL_ID,
    titlePrompt: '',
    translateModeId: '',
    translatePrompt: '',
    translateThinkingBudget: 0,
    enableSuggestion: false,
    suggestionModelId: null,
    suggestionPrompt: '',
    ocrModelId: '',
    ocrPrompt: '',
    compressModelId: '',
    compressPrompt: '',
    assistantId: AST_ID,
    providers: [
      {
        type: 'openai', id: PROVIDER_ID, enabled: true, name: '我的OpenAI', apiKey: 'sk-test-123', baseUrl: 'https://api.openai.com/v1',
        chatCompletionsPath: '/chat/completions', useResponseApi: false, includeHistoryReasoning: false,
        balanceOption: { enabled: false, apiPath: '', resultPath: '' },
        models: [
          { modelId: 'gpt-4o', displayName: 'GPT-4o', id: MODEL_ID, type: 'CHAT', customHeaders: [], customBodies: [], inputModalities: ['TEXT'], outputModalities: ['TEXT'], abilities: ['TOOL'], tools: [], providerOverwrite: null },
          { modelId: 'dall-e-3', displayName: 'DALL-E 3', id: 'model-2', type: 'IMAGE', customHeaders: [], customBodies: [], inputModalities: ['TEXT'], outputModalities: ['IMAGE'], abilities: [], tools: [], providerOverwrite: null },
        ],
      },
    ],
    assistants: [
      {
        id: AST_ID, chatModelId: MODEL_ID, name: '写作助手', avatar: { type: 'Emoji', content: '✍️' }, useAssistantAvatar: true,
        tags: ['tag-1'], systemPrompt: '你是写作专家', temperature: 0.7, topP: null, contextMessageLimit: 32,
        streamOutput: true, enableMemory: true, useGlobalMemory: true, enableRecentChatsReference: true,
        messageTemplate: '{{ message }}', presetMessages: [], quickMessageIds: ['qm-1'],
        regexes: [{ id: 'rx-1', name: '缩写', enabled: true, findRegex: 'gpt', replaceString: 'GPT', affectingScope: ['USER'], visualOnly: false }],
        reasoningLevel: 'medium', maxTokens: null, customHeaders: [], customBodies: [], mcpServers: ['mcp-1'],
        localTools: ['time_info'], enableWebSearch: true, workspaceId: null, background: null, backgroundOpacity: 1,
        useGradientBackground: false, modeInjectionIds: ['mi-1'], lorebookIds: ['lb-1'], enabledSkills: ['skill-a'],
        enableTimeReminder: true, allowConversationSystemPrompt: true, allowConversationPromptInjection: true,
      },
    ],
    assistantTags: [{ id: 'tag-1', name: '创作' }],
    searchServices: [
      { type: 'tavily', id: 'ss-1', apiKey: 'tv-key' },
      { type: 'rikkahub', id: 'ss-2', apiKey: 'x' },
    ],
    searchCommonOptions: { resultSize: 5 },
    searchServiceSelected: 0,
    mcpServers: [
      { type: 'sse', id: 'mcp-1', commonOptions: { enable: true, name: '天气MCP', headers: [['Authorization', 'Bearer t']], tools: [{ enable: true, name: 'get_weather', description: null, inputSchema: { type: 'object', properties: { city: { type: 'string' } }, required: ['city'] }, needsApproval: false }], oauth: null }, url: 'https://mcp.example.com/sse' },
      { type: 'streamable_http', id: 'mcp-2', commonOptions: { enable: false, name: 'HTTP MCP', headers: [], tools: [], oauth: null }, url: 'https://mcp2.example.com' },
    ],
    webDavConfig: { url: 'https://dav.example.com', username: 'u', password: 'p', path: '/backup', items: ['DATABASE', 'FILES'] },
    s3Config: { endpoint: '', accessKeyId: '', secretAccessKey: '', bucket: 'b', region: '', pathStyle: false, items: [] },
    ttsProviders: [
      { type: 'openai', id: 'tts-1', name: 'TTS', apiKey: 'k', baseUrl: '', model: 'tts-1', voice: 'alloy' },
      { type: 'step', id: 'tts-2', name: 'StepTTS', apiKey: '', baseUrl: '', model: '', voice: '' },
    ],
    selectedTTSProviderId: 'tts-1',
    defaultTTSPlaybackSpeed: 1.0,
    asrProviders: [{ type: 'dashscope', id: 'asr-1', name: 'ASR' }],
    selectedASRProviderId: null,
    modeInjections: [{ id: 'mi-1', type: 'mode', name: '模式注入', enabled: true, priority: 0, position: 'before_system_prompt', content: '注入内容', injectDepth: 0, role: 'system' }],
    lorebooks: [{ id: 'lb-1', name: '世界书', description: 'd', enabled: true, entries: [{ id: 'le-1', type: 'regex', name: '条目', enabled: true, priority: 0, position: 'top_of_chat', content: '世界设定', injectDepth: 0, role: 'user', keywords: ['k'], useRegex: false, caseSensitive: false, scanDepth: 0, constantActive: true }] }],
    quickMessages: [{ id: 'qm-1', title: '打招呼', content: '你好' }],
    webServerEnabled: true,
    webServerPort: 8080,
    webServerJwtEnabled: false,
    webServerAccessPassword: '',
    webServerLocalhostOnly: true,
    backupReminderConfig: { enabled: true, intervalDays: 7, lastBackupTime: 1767250000000 },
    launchCount: 5,
    sponsorAlertDismissedAt: 0,
  };
  return JSON.stringify(settings);
}

// ---------- 3. 组装 zip 并迁移 ----------
const built = buildDb();
const zip = new JSZip();
zip.file('settings.json', buildSettings());
zip.file('rikka_hub.db', built.db);
if (built.wal) zip.file('rikka_hub-wal', built.wal);
zip.file('upload/paste_123.png', new Uint8Array([0x89, 0x50, 0x4e, 0x47]));

const result = await migrateRikkaHubToKelivo(zip, 'backup_20260101_120000.zip');
const outZip = result.outputZip;
const report = result.report;

const chats = JSON.parse(await outZip.file('chats.json')!.async('string'));
const settingsJson = JSON.parse(await outZip.file('settings.json')!.async('string')) as SettingsJson;

// ---------- 4. 校验 chats.json ----------
assert.strictEqual(chats.version, 2, 'chats.json version=2');
assert.strictEqual(chats.conversations.length, 2, '2 个会话');
assert.strictEqual(chats.messages.length, 3, '3 条消息（alt 丢弃 1 条）');
const conv1 = chats.conversations.find((c: { id: string }) => c.id === 'conv-1');
assert.strictEqual(conv1.messageIds.length, 2, 'conv-1 消息 2 条');
assert.ok(!chats.messages.some((m: { id: string }) => m.id === 'msg-1a'), '未选中的替代版本已丢弃');
assert.ok(chats.messages.some((m: { id: string }) => m.id === 'msg-1b'), '选中版本保留');
const msg2 = chats.messages.find((m: { id: string }) => m.id === 'msg-2');
assert.ok(msg2.content.includes('[image:upload/paste_123.png]'), '图片标记写入 content');
assert.strictEqual(msg2.reasoningText, '深度思考过程', '推理文本');
assert.strictEqual(msg2.providerId, PROVIDER_ID, 'providerId 解析');
assert.strictEqual(msg2.modelId, 'gpt-4o', 'modelId 解引用');
assert.strictEqual(msg2.totalTokens, 30, 'token 统计');
assert.strictEqual(chats.toolEvents['msg-2']?.length, 1, 'toolEvents 1 条');
assert.strictEqual(chats.toolEvents['msg-2'][0].name, 'web_search', '工具名');
assert.deepStrictEqual(chats.toolEvents['msg-2'][0].arguments, { query: 'test' }, '工具参数解析');
const conv2 = chats.conversations.find((c: { id: string }) => c.id === 'conv-2');
assert.strictEqual(conv2.assistantId, DEFAULT_ASSISTANT, 'conv-2 引用默认助手');

// ---------- 5. 校验 settings.json ----------
const assistants = JSON.parse(settingsJson.assistants_v1!);
assert.strictEqual(assistants.length, 2, '2 个助手（1 还原 + 1 占位）');
const ast = assistants.find((a: { id: string }) => a.id === AST_ID);
assert.strictEqual(ast.name, '写作助手');
assert.strictEqual(ast.chatModelId, 'gpt-4o', '助手模型解引用');
assert.strictEqual(ast.chatModelProvider, PROVIDER_ID);
assert.strictEqual(ast.regexRules[0].pattern, 'gpt');
assert.strictEqual(ast.skillIds[0], 'skill-a');
assert.strictEqual(ast.mcpServerIds[0], 'mcp-1');
assert.strictEqual(ast.enableTimeInjection, true);
const placeholder = assistants.find((a: { id: string }) => a.id === DEFAULT_ASSISTANT);
assert.strictEqual(placeholder.name, '我的写作助手', '占位助手用文件夹名命名');
assert.strictEqual(placeholder.systemPrompt, '你是我的写作搭档', '占位助手取会话自定义提示词');

const providers = JSON.parse(settingsJson.provider_configs_v1!);
assert.strictEqual(providers[PROVIDER_ID].apiKey, 'sk-test-123', 'apiKey 迁移');
assert.deepStrictEqual(providers[PROVIDER_ID].models, ['gpt-4o', 'dall-e-3'], '模型列表');
assert.ok(!('webdav_config_v1' in settingsJson), '备份凭据未复制');
assert.strictEqual(settingsJson.current_assistant_id_v1, AST_ID);
assert.deepStrictEqual(settingsJson.pinned_models_v1, ['prov-1::gpt-4o'], '收藏模型解引用');
assert.strictEqual(settingsJson.selected_model_v1, 'prov-1::gpt-4o', '选中模型');

const tags = JSON.parse(settingsJson.assistant_tags_v1!);
assert.strictEqual(tags.length, 1);
assert.deepStrictEqual(JSON.parse(settingsJson.assistant_tag_map_v1!), { [AST_ID]: 'tag-1' }, '标签映射');
const memories = JSON.parse(settingsJson.assistant_memories_v1!);
assert.strictEqual(memories.length, 1, '记忆迁移');
const quick = JSON.parse(settingsJson.quick_phrases_v1!);
assert.strictEqual(quick[0].content, '你好');
const search = JSON.parse(settingsJson.search_services_v1!);
assert.strictEqual(search.length, 1, '仅保留 tavily');
assert.strictEqual(search[0].apiKey, 'tv-key');
const tts = JSON.parse(settingsJson.tts_services_v1!);
assert.strictEqual(tts.length, 1, '仅保留 openai TTS');
const mcp = JSON.parse(settingsJson.mcp_servers_v1!);
assert.strictEqual(mcp.length, 2, '2 个 MCP');
assert.strictEqual(mcp[0].transport, 'sse');
assert.strictEqual(mcp[1].transport, 'http');
assert.strictEqual(mcp[0].tools[0].params[0].name, 'city');
const wb = JSON.parse(settingsJson.world_books_v1!);
assert.strictEqual(wb[0].entries[0].position, 'TOP_OF_CHAT', '世界书枚举映射');
const inj = JSON.parse(settingsJson.instruction_injections_v1!);
assert.strictEqual(inj[0].prompt, '注入内容');
assert.strictEqual(settingsJson.backup_reminder_enabled_v1, true);
assert.strictEqual(settingsJson.display_show_model_icon_v1, true, '显示键映射');
assert.strictEqual(settingsJson.display_show_model_timestamp_v1, true, '时间戳显示映射');

// ---------- 6. 校验报告 ----------
assert.strictEqual(report.droppedAlternatives, 1, '丢弃 1 条未选版本');
assert.strictEqual(report.totals.mediaFiles, 1, '媒体文件透传 1 个');
assert.strictEqual(report.totals.placeholders, 1, '占位 1 个');
assert.ok(report.dropped.some((d) => d.category.includes('搜索服务')), '搜索丢弃入报告');
assert.ok(report.dropped.some((d) => d.category.includes('TTS')), 'TTS 丢弃入报告');
assert.ok(report.warnings.some((w) => w.includes('WebDAV')), '凭据警告');
assert.ok(report.placeholderAssistants[0].assistantId === DEFAULT_ASSISTANT, '占位助手记录');

// ---------- 6.5 故障 1 回归：settings 数组字段为非数组/缺失时不得崩溃 ----------
const badSettings = JSON.parse(buildSettings());
badSettings.providers = { 'prov-1': { id: 'prov-1' } };
delete badSettings.assistants;
const badZip = new JSZip();
badZip.file('settings.json', JSON.stringify(badSettings));
badZip.file('rikka_hub.db', buildDb().db);
const badResult = await migrateRikkaHubToKelivo(badZip, 'bad.zip');
assert.strictEqual(badResult.report.totals.conversations, 2, 'settings 异常时仍迁移 DB 会话');
assert.strictEqual(badResult.report.totals.assistants, 0, 'assistants 缺失 → 0 个映射助手');
assert.ok(
  badResult.report.warnings.some((w) => w.includes('providers') && w.includes('不是数组')),
  'providers 非数组警告',
);

// ---------- 7. 恢复工具（合成 Kelivo zip）----------
const kelivoZip = new JSZip();
kelivoZip.file(
  'settings.json',
  JSON.stringify({
    theme_mode_v1: 'dark',
    assistants_v1: JSON.stringify([
      { id: 'ast-ok', name: '已有助手', systemPrompt: 'x', messageTemplate: '{{ message }}' },
    ]),
  }),
);
kelivoZip.file(
  'chats.json',
  JSON.stringify({
    version: 2,
    conversations: [
      { id: 'c1', title: '会话1', assistantId: 'ast-missing', messageIds: ['m1'], createdAt: '2026-01-01T00:00:00', updatedAt: '2026-01-01T00:00:00', isPinned: false, mcpServerIds: [], parentConversationId: null, truncateIndex: -1, versionSelections: {}, summary: null, lastSummarizedMessageCount: 0, chatSuggestions: [], conversationKind: 'normal' },
      { id: 'c2', title: '会话2', assistantId: 'ast-ok', messageIds: ['m2'], createdAt: '2026-01-01T00:00:00', updatedAt: '2026-01-01T00:00:00', isPinned: false, mcpServerIds: [], parentConversationId: null, truncateIndex: -1, versionSelections: {}, summary: null, lastSummarizedMessageCount: 0, chatSuggestions: [], conversationKind: 'normal' },
      { id: 'c3', title: '无主会话', assistantId: null, messageIds: [], createdAt: '2026-01-01T00:00:00', updatedAt: '2026-01-01T00:00:00', isPinned: false, mcpServerIds: [], parentConversationId: null, truncateIndex: -1, versionSelections: {}, summary: null, lastSummarizedMessageCount: 0, chatSuggestions: [], conversationKind: 'normal' },
    ],
    messages: [
      { id: 'm1', role: 'user', content: 'hi', timestamp: '2026-01-01T00:00:00', conversationId: 'c1' },
      { id: 'm2', role: 'assistant', content: 'ok', timestamp: '2026-01-01T00:00:01', conversationId: 'c2' },
      { id: 'm3', role: 'user', content: '孤儿消息', timestamp: '2026-01-02T00:00:00', conversationId: 'ghost-1' },
      { id: 'm4', role: 'assistant', content: '回复', timestamp: '2026-01-02T00:00:01', conversationId: 'ghost-1' },
    ],
    toolEvents: {},
    geminiThoughtSigs: {},
    groupChats: [],
    groupMembers: [],
  }),
);

const rec = await runRecovery(kelivoZip, 'kelivo_backup.zip');
assert.strictEqual(rec.missingAssistants.length, 1, '找回 1 个缺失助手');
assert.strictEqual(rec.placeholdersCreated, 2, '新建占位 2 个（ast-missing + 恢复的会话）');
assert.strictEqual(rec.orphanMessages, 2, '2 条孤儿消息');
assert.strictEqual(rec.shellsRestored, 1, '重建 1 个会话壳');
assert.strictEqual(rec.mountedCount, 2, '挂载 2 个（会话壳 + 原 null 会话）');

const recSettings = JSON.parse(await rec.outputZip.file('settings.json')!.async('string'));
const recAssistants = JSON.parse(recSettings.assistants_v1);
assert.strictEqual(recAssistants.length, 3, '助手列表 3 个（已有 + Found 01 + 恢复的会话）');
assert.ok(recAssistants.some((a: { id: string; name: string }) => a.id === 'ast-missing' && a.name === 'Found 01'), 'Found 01 占位');
assert.ok(
  recAssistants.some((a: { id: string; name: string }) => a.name === RECOVERY_ASSISTANT_NAME),
  '恢复的会话助手存在',
);

const recChats = JSON.parse(await rec.outputZip.file('chats.json')!.async('string'));
assert.strictEqual(recChats.conversations.length, 4, '会话总数 4（含会话壳）');
const ghost = recChats.conversations.find((c: { id: string }) => c.id === 'ghost-1');
assert.strictEqual(ghost.assistantId, rec.recoveryAssistantId, '会话壳挂载到恢复助手');
assert.strictEqual(ghost.title, '孤儿消息');
assert.deepStrictEqual(ghost.messageIds, ['m3', 'm4']);
const c3 = recChats.conversations.find((c: { id: string }) => c.id === 'c3');
assert.strictEqual(c3.assistantId, rec.recoveryAssistantId, '原 null 会话挂载到恢复助手');

console.log('✅ e2e 全部通过');
console.log(`  迁移: ${report.totals.conversations} 会话 / ${report.totals.messages} 消息 / ${report.totals.assistants} 助手 / ${report.totals.providers} 提供商`);
