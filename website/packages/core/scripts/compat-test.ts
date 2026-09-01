/**
 * 端到端测试：构造合成 Kelivo v1.2.0 备份（manifest + database/kelivo.db + settings.json）
 * → 兼容转换 → 校验 Cuplivo 可恢复备份包
 * 运行：pnpm tsx scripts/compat-test.ts
 */
import JSZip from 'jszip';
import assert from 'node:assert/strict';
import sqlite3InitModule from '@sqlite.org/sqlite-wasm';
import { compatKelivoToCuplivo, compatOutputName } from '../src/compat';
import { transformAssistantsV1, transformSearchServicesV1 } from '../src/cuplivo/settings';
import { transformMemories } from '../src/compat/memory';
import { managedTail, portableSlash, relativeManaged } from '../src/cuplivo/chats';
import type { CompatReport } from '../src/compat/report';

const sqlite3 = await sqlite3InitModule({ print: () => {}, printErr: () => {} });

const AST_ID = 'ast-1';
const T0 = Date.UTC(2026, 0, 1, 10, 0, 0, 123) * 1000 + 456; // 2026-01-01T10:00:00.123456Z

// ---------- 1. 构造 kelivo.db（v1.2.0 真实表结构子集） ----------
let buildCounter = 0;
function buildDb(): Uint8Array {
  buildCounter++;
  const db = new sqlite3.oo1.DB(`/compat_build_${buildCounter}.db`, 'c');
  db.exec('PRAGMA user_version = 1');
  db.exec(`
    CREATE TABLE conversation_rows (
      id TEXT PRIMARY KEY, title TEXT, created_at INTEGER, updated_at INTEGER,
      is_pinned INTEGER DEFAULT 0, assistant_id TEXT, truncate_index INTEGER DEFAULT -1,
      version_selections_json TEXT DEFAULT '{}', summary TEXT,
      last_summarized_message_count INTEGER DEFAULT 0, chat_suggestions_json TEXT DEFAULT '[]',
      injected_memory_hash TEXT, last_memory_extracted_order INTEGER DEFAULT -1
    );
    CREATE TABLE conversation_mcp_server_rows (
      conversation_id TEXT, server_id TEXT, ordinal INTEGER,
      PRIMARY KEY (conversation_id, server_id), UNIQUE (conversation_id, ordinal)
    );
    CREATE TABLE message_rows (
      id TEXT PRIMARY KEY, conversation_id TEXT REFERENCES conversation_rows(id) ON DELETE CASCADE,
      role TEXT CHECK(role != ''), timestamp INTEGER, model_id TEXT, provider_id TEXT,
      total_tokens INTEGER, is_streaming INTEGER DEFAULT 0,
      reasoning_start_at INTEGER, reasoning_finished_at INTEGER,
      translation TEXT, reasoning_segments_json TEXT, group_id TEXT, version INTEGER DEFAULT 0,
      prompt_tokens INTEGER, completion_tokens INTEGER, cached_tokens INTEGER, duration_ms INTEGER,
      message_order INTEGER, UNIQUE (conversation_id, message_order), UNIQUE (conversation_id, group_id, version)
    );
    CREATE TABLE message_part_rows (
      part_id INTEGER PRIMARY KEY AUTOINCREMENT, conversation_id TEXT, revision_id TEXT,
      ordinal INTEGER, kind TEXT CHECK(kind != ''), payload TEXT,
      created_at INTEGER, updated_at INTEGER, UNIQUE (revision_id, ordinal)
    );
    CREATE TABLE provider_artifact_rows (
      conversation_id TEXT, revision_id TEXT, kind TEXT, payload TEXT,
      created_at INTEGER, updated_at INTEGER, PRIMARY KEY (revision_id, kind)
    );
    CREATE TABLE asset_rows (
      id TEXT PRIMARY KEY, content_hash TEXT UNIQUE, path TEXT, byte_size INTEGER,
      width INTEGER, height INTEGER, thumbnail_path TEXT, created_at INTEGER, last_referenced_at INTEGER
    );
    CREATE TABLE message_asset_rows (
      conversation_id TEXT, revision_id TEXT, asset_id TEXT, kind TEXT,
      PRIMARY KEY (revision_id, asset_id, kind)
    );
  `);

  db.exec(`
    INSERT INTO conversation_rows VALUES
      ('conv-1', '测试会话', ${T0}, ${T0 + 5000000}, 1, '${AST_ID}', -1,
       '{"g1":1}', NULL, 0, '["建议1"]', NULL, -1),
      ('conv-2', '无主会话', ${T0}, ${T0}, 0, NULL, -1, '{}', NULL, 0, '[]', NULL, -1);
    INSERT INTO conversation_mcp_server_rows VALUES ('conv-1', 'mcp-1', 0);
    INSERT INTO message_rows VALUES
      ('m1-0', 'conv-1', 'user', ${T0}, NULL, NULL, NULL, 0, NULL, NULL, NULL, NULL, 'g1', 0, NULL, NULL, NULL, NULL, 0),
      ('m1-1', 'conv-1', 'user', ${T0 + 1000}, NULL, NULL, NULL, 0, NULL, NULL, NULL, NULL, 'g1', 1, NULL, NULL, NULL, NULL, 1),
      ('m2', 'conv-1', 'assistant', ${T0 + 4000000}, 'gpt-4o', 'prov-1', 30, 0,
       ${T0 + 2000000}, ${T0 + 3000000}, NULL, NULL, NULL, 0, 10, 20, 0, 500, 2),
      ('m3', 'conv-2', 'assistant', ${T0 + 5000000}, 'gpt-4o', 'prov-1', 5, 0,
       NULL, NULL, NULL, NULL, NULL, 0, NULL, NULL, NULL, NULL, 0);
    INSERT INTO message_part_rows (conversation_id, revision_id, ordinal, kind, payload, created_at, updated_at) VALUES
      ('conv-1', 'm1-0', 0, 'text', '旧版本提问', ${T0}, ${T0}),
      ('conv-1', 'm1-1', 0, 'text', '选中版本提问', ${T0 + 1000}, ${T0 + 1000}),
      ('conv-1', 'm2', 0, 'text', '回答内容', ${T0 + 4000000}, ${T0 + 4000000}),
      ('conv-1', 'm2', 1, 'reasoning', '深度思考过程', ${T0 + 4000000}, ${T0 + 4000000}),
      ('conv-1', 'm2', 2, 'tool_call',
       '{"id":"call-1","name":"web_search","arguments":{"query":"test"},"content":"结果A"}',
       ${T0 + 4000000}, ${T0 + 4000000}),
      ('conv-1', 'm2', 3, 'image',
       '{"uri":"kelivo-file:///upload/paste_123.png","mime":"image/png"}',
       ${T0 + 4000000}, ${T0 + 4000000}),
      ('conv-1', 'm2', 4, 'image',
       '{"uri":"kelivo-file:///upload/gone.png","assetId":"asset-1"}',
       ${T0 + 4000000}, ${T0 + 4000000}),
      ('conv-1', 'm2', 5, 'image',
       '{"uri":"C:/Users/x/AppData/Local/kelivo/images/doc.png","mime":"image/png","unavailable":true}',
       ${T0 + 4000000}, ${T0 + 4000000}),
      ('conv-1', 'm2', 6, 'file',
       '{"uri":"kelivo-file:///images/doc.pdf","name":"报告.pdf","mime":"application/pdf"}',
       ${T0 + 4000000}, ${T0 + 4000000}),
      ('conv-2', 'm3', 0, 'text', '带签名的回复', ${T0 + 5000000}, ${T0 + 5000000}),
      ('conv-2', 'm3', 1, 'future_widget', '{"x":1}', ${T0 + 5000000}, ${T0 + 5000000}),
      ('conv-2', 'm3', 2, 'image', 'not-json', ${T0 + 5000000}, ${T0 + 5000000});
    INSERT INTO provider_artifact_rows VALUES
      ('conv-2', 'm3', 'gemini_thought_signature', 'sig-abc', ${T0 + 5000000}, ${T0 + 5000000});
    INSERT INTO asset_rows VALUES
      ('asset-1', 'hash1', 'images/asset1.png', 3, NULL, NULL, NULL, ${T0}, ${T0});
    INSERT INTO message_asset_rows VALUES ('conv-1', 'm2', 'asset-1', 'image');
  `);

  const bytes = sqlite3.capi.sqlite3_js_db_export(db.pointer);
  db.close();
  return bytes;
}

// ---------- 2. 构造 settings.json（v1.2.0 形态：presetMessages 字符串、双代记忆） ----------
const AST_ID_2 = 'ast-2';
function buildSettings(): string {
  return JSON.stringify({
    theme_mode_v1: 'dark',
    image_upload_quality_v1: 85,
    image_compress_custom_quality_v1: 60,
    tts_speech_rate_v1: 1,
    search_services_v1: JSON.stringify([
      { type: 'exa', id: 'srv-1', name: 'Exa 搜索', apiKey: 'primary-key', apiKeys: ['k2', 'k3'], keyManagement: null },
    ]),
    current_assistant_id_v1: AST_ID,
    assistants_v1: JSON.stringify([
      {
        id: AST_ID,
        name: '写作助手',
        systemPrompt: '你是写作专家',
        messageTemplate: '{{ message }}',
        limitContextMessages: false,
        presetMessages: JSON.stringify([
          { id: 'pm-1', role: 'user', content: '开场白' },
        ]),
        regexRules: [],
        allowPastConversationRecall: true,
        autoOrganizeMemory: true,
        memorySmartAddMode: 'batched',
      },
      { id: AST_ID_2, name: '第二个助手', systemPrompt: '', messageTemplate: '{{ message }}', regexRules: [] },
    ]),
    assistant_memories_v1: JSON.stringify([
      { id: 1, assistantId: AST_ID, content: '旧记忆A' },
      { id: 2, assistantId: AST_ID_2, content: '旧记忆B' },
      { id: 5, assistantId: AST_ID, content: '新身份' },
    ]),
    memory_entries_v1: JSON.stringify([
      { id: 'mem_000001', scope: 'assistant', assistantId: AST_ID, type: 'identity', status: 'active', content: '新身份', source: 'manual', migrationIds: [1] },
      { id: 'mem_000002', scope: 'assistant', assistantId: AST_ID_2, type: 'workflow', status: 'active', content: '旧记忆B', source: 'manual', migrationIds: [2] },
      { id: 'mem_000003', scope: 'global', type: 'voice', status: 'active', content: '全局声音', source: 'tool' },
      { id: 'mem_000004', scope: 'assistant', assistantId: AST_ID, type: 'instruction', status: 'archived', content: '该忘的', source: 'manual' },
    ]),
  });
}

function buildManifest(dbBytes: Uint8Array): string {
  return JSON.stringify({
    format: 'kelivo-backup',
    formatVersion: 2,
    payloadKind: 'sqlite',
    createdAtUtc: '2026-08-12T00:00:00Z',
    appVersion: '1.2.0 (42)',
    includeChats: true,
    includeFiles: true,
    secretsIncluded: true,
    businessEntityRowIds: { assistant_rows: ['1'] },
    database: {
      entry: 'database/kelivo.db',
      schemaVersion: 1,
      conversationCount: 2,
      messageCount: 4,
    },
    entries: {
      'settings.json': { bytes: 300, sha256: '0'.repeat(64) },
      'database/kelivo.db': { bytes: dbBytes.length, sha256: '0'.repeat(64) },
      'upload/paste_123.png': { bytes: 3, sha256: '0'.repeat(64) },
    },
  });
}

// ---------- 3. 组装 zip 并转换 ----------
const dbBytes = buildDb();
const zip = new JSZip();
zip.file('settings.json', buildSettings());
zip.file('database/kelivo.db', dbBytes);
zip.file('manifest.json', buildManifest(dbBytes));
zip.file('upload/paste_123.png', new Uint8Array([0x89, 0x50, 0x4e, 0x47]));
zip.file('images/asset1.png', new Uint8Array([0x89, 0x50, 0x4e, 0x47]));
zip.file('images/doc.pdf', new Uint8Array([0x25, 0x50, 0x44, 0x46]));
zip.file('avatars/a.png', new Uint8Array([0x89, 0x50, 0x4e, 0x47]));
zip.file('fonts/f.ttf', new Uint8Array([0x00, 0x01]));

const result = await compatKelivoToCuplivo(zip, 'kelivo_backup_20260812T000000.000000.zip');
const outZip = result.outputZip;
const report: CompatReport = result.report;

const chats = JSON.parse(await outZip.file('chats.json')!.async('string'));
const settingsText = await outZip.file('settings.json')!.async('string');
const settingsJson = JSON.parse(settingsText);

// ---------- 4. 校验 chats.json ----------
assert.match(result.outputName, /^kelivo_backup_\d{8}T\d{6}\.\d{6}\.zip$/, '目标惯例文件名');
assert.strictEqual(chats.version, 1, 'chats.json version=1（锁定常量：Kelivo 旧导入端拒绝 v2，cuplivo#453）');
assert.strictEqual(chats.conversations.length, 2, '2 个会话');
assert.strictEqual(chats.messages.length, 4, '4 条消息（含全部 revision）');
assert.deepStrictEqual(chats.groupChats, [], 'groupChats 空');
assert.deepStrictEqual(chats.groupMembers, [], 'groupMembers 空');

const conv1 = chats.conversations.find((c: { id: string }) => c.id === 'conv-1');
assert.deepStrictEqual(conv1.messageIds, ['m1-0', 'm1-1', 'm2'], 'messageIds 全量 revision 按 message_order');
assert.deepStrictEqual(conv1.versionSelections, { g1: 1 }, 'versionSelections 保真');
assert.strictEqual(conv1.assistantId, AST_ID);
assert.deepStrictEqual(conv1.mcpServerIds, ['mcp-1'], 'mcpServerIds 从关联表');
assert.strictEqual(conv1.conversationKind, 'normal');
assert.strictEqual(conv1.parentConversationId, null);
assert.strictEqual(conv1.isPinned, true);
assert.strictEqual(conv1.injectedMemoryHash, null, 'kelivo 独有字段保真透传');
const conv2 = chats.conversations.find((c: { id: string }) => c.id === 'conv-2');
assert.strictEqual(conv2.assistantId, null, 'null assistantId 原样保留（Cuplivo 可见）');

const m1v0 = chats.messages.find((m: { id: string }) => m.id === 'm1-0');
assert.strictEqual(m1v0.content, '旧版本提问', '未选中 revision 也保留');
assert.strictEqual(m1v0.groupId, 'g1');
assert.strictEqual(m1v0.version, 0);
assert.strictEqual(m1v0.subgroupId, null);
assert.strictEqual(m1v0.isPreset, false);
assert.strictEqual(m1v0.speakerAssistantId, null);

const m2 = chats.messages.find((m: { id: string }) => m.id === 'm2');
assert.ok(m2.content.includes('回答内容'), 'text part 入 content');
assert.ok(m2.content.includes('[image:/upload/paste_123.png]'), 'kelivo-file URI → /upload/ 标记');
assert.ok(m2.content.includes('[image:/images/asset1.png]'), 'zip 缺文件时经 assetId 媒体库定位');
assert.ok(m2.content.includes('[image:/images/doc.png]'), 'legacy 绝对路径词法映射到管理根（unavailable 保留标记）');
assert.ok(m2.content.includes('[file:/images/doc.pdf|报告.pdf|application/pdf]'), 'file 标记');
assert.strictEqual(m2.reasoningText, '深度思考过程', 'reasoning 部件 → reasoningText');
assert.strictEqual(m2.reasoningStartAt, '2026-01-01T10:00:02.123456Z', 'reasoning 起始时间');
assert.strictEqual(m2.reasoningFinishedAt, '2026-01-01T10:00:03.123456Z', 'reasoning 结束时间');
assert.strictEqual(m2.providerId, 'prov-1');
assert.strictEqual(m2.modelId, 'gpt-4o');
assert.strictEqual(m2.totalTokens, 30);
assert.strictEqual(m2.promptTokens, 10);
assert.strictEqual(m2.durationMs, 500);
assert.strictEqual(chats.toolEvents['m2']?.length, 1, 'toolEvents 1 条');
assert.deepStrictEqual(chats.toolEvents['m2'][0], { id: 'call-1', name: 'web_search', arguments: { query: 'test' }, content: '结果A' }, 'tool_call 载荷原样透传');
assert.strictEqual(chats.geminiThoughtSigs['m3'], 'sig-abc', 'gemini 签名从 provider_artifact_rows');

const m3 = chats.messages.find((m: { id: string }) => m.id === 'm3');
assert.ok(m3.content.includes('{"x":1}'), '未知部件原样保留到 content');
assert.ok(!m3.content.includes('not-json'), '损坏 image 部件丢弃');

// ---------- 5. 校验 settings.json ----------
assert.strictEqual(settingsJson.theme_mode_v1, 'dark', '直通键保留');
assert.strictEqual(settingsJson.image_upload_quality_v1, 85, '图像键保持 Kelivo 形态（Cuplivo 恢复时翻译）');
const assistants = JSON.parse(settingsJson.assistants_v1);
assert.strictEqual(assistants.length, 2);
const ast = assistants[0];
assert.deepStrictEqual(ast.presetMessages, [{ id: 'pm-1', role: 'user', content: '开场白' }], 'presetMessages 字符串 → 内联数组');
assert.strictEqual(ast.enableRecentChatsReference, true, '合成 enableRecentChatsReference');
assert.strictEqual(ast.allowPastConversationRecall, true, '原字段保留（保真）');
assert.strictEqual(ast.autoOrganizeMemory, true, 'Kelivo 独有字段保留');

const memories: { id: number; assistantId: string; content: string }[] = JSON.parse(settingsJson.assistant_memories_v1);
assert.deepStrictEqual(
  memories,
  [
    { id: 6, assistantId: AST_ID, content: '新身份' },
    { id: 7, assistantId: AST_ID_2, content: '旧记忆B' },
    { id: 8, assistantId: AST_ID, content: '全局声音' },
    { id: 9, assistantId: AST_ID_2, content: '全局声音' },
  ],
  '记忆降级：migrationIds 取代 + 内容去重 + global 复制所有助手 + 新 id 从旧 max+1',
);
assert.strictEqual(settingsJson.memory_entries_v1, undefined, 'memory_entries_v1 已移除');

assert.ok(settingsText.includes('"tts_speech_rate_v1": 1.0'), 'double 键序列化补小数点（getDouble 强转防崩溃）');
const searchServices = JSON.parse(settingsJson.search_services_v1);
assert.deepStrictEqual(
  searchServices[0].apiKeys,
  [{ key: 'primary-key' }, { key: 'k2' }, { key: 'k3' }],
  'search apiKeys 字符串池 → ApiKeyConfig 列表（主 key 优先）',
);
assert.strictEqual(searchServices[0].apiKey, 'primary-key', 'apiKey 主键串保留（向后兼容）');

// ---------- 6. 校验 zip 结构 ----------
assert.deepStrictEqual(JSON.parse(await outZip.file('deleted.json')!.async('string')), {}, 'deleted.json 空对象');
assert.ok(outZip.file('upload/paste_123.png'), '媒体目录透传');
assert.ok(outZip.file('images/asset1.png'));
assert.ok(outZip.file('images/doc.pdf'));
assert.ok(outZip.file('avatars/a.png'));
assert.ok(outZip.file('fonts/f.ttf'));
assert.strictEqual(outZip.file('chats.json')!.name.endsWith('chats.json'), true);
assert.ok(!outZip.file('skills/'), '无 skills/（源格式无技能）');
assert.ok(!outZip.file('workspaces/'), '无 workspaces/（源格式无工作区导出）');

// ---------- 7. 校验报告 ----------
assert.strictEqual(report.source.format, 'kelivo-backup');
assert.strictEqual(report.source.formatVersion, 2);
assert.strictEqual(report.source.appVersion, '1.2.0 (42)');
assert.strictEqual(report.totals.conversations, 2);
assert.strictEqual(report.totals.messages, 4);
assert.strictEqual(report.totals.toolEvents, 1);
assert.strictEqual(report.totals.assistants, 2);
assert.strictEqual(report.totals.mediaFiles, 5);
assert.strictEqual(report.totals.geminiSignatures, 1);
assert.strictEqual(report.totals.memories, 4, '记忆转换计数');
assert.ok(report.dropped.some((d) => d.category.includes('archived')), 'archived 记忆入报告');
assert.ok(report.warnings.some((w) => w.includes('记忆转换')), '记忆转换警告');
assert.ok(report.dropped.some((d) => d.category.includes('future_widget')), '未知部件入报告');
assert.ok(report.dropped.some((d) => d.category.includes('损坏')), '损坏部件入报告');
const missing = report.dropped.filter((d) => d.category.includes('不在备份包中'));
assert.strictEqual(missing.length, 1, '媒体缺失入报告');
assert.strictEqual(missing[0].count, 1, '仅 doc.png（legacy 映射但 zip 无此文件）计数 1；gone.png 已由 assetId 库定位');
assert.ok(report.warnings.some((w) => w.includes('presetMessages')), '助手手术警告');

// ---------- 8. 单元：路径映射工具 ----------
assert.strictEqual(portableSlash('file:///C:/Users/x/AppData/Local/kelivo/upload/a.png'), 'C:/Users/x/AppData/Local/kelivo/upload/a.png', 'file: scheme 剥除');
assert.strictEqual(portableSlash('C:\\Users\\x\\upload\\a.png'), 'C:/Users/x/upload/a.png', '反斜杠归一');
assert.strictEqual(portableSlash('\\\\server\\share\\a.png'), null, 'UNC 拒绝');
assert.strictEqual(portableSlash('https://cdn.example/a.png'), 'https://cdn.example/a.png', 'URL 原样');
assert.strictEqual(managedTail('C:/Users/x/AppData/Local/kelivo/images/a.png'), 'images/a.png', 'managedTail 定位');
assert.strictEqual(managedTail('kelivo-file:///upload/a.png'), 'upload/a.png', 'managedTail 通用子串扫描（URI 由 resolveMediaRef 专用分支先处理）');
assert.strictEqual(relativeManaged('upload/a.png'), 'upload/a.png', '相对路径');
assert.strictEqual(relativeManaged('workspaces/a.png'), null, '非管理根拒绝');

// ---------- 9. 单元：助手手术 ----------
{
  const report0: CompatReport = {
    generatedAt: '',
    source: { fileName: 'x', format: 'kelivo-backup', formatVersion: 2, payloadKind: 'sqlite', appVersion: null },
    totals: { conversations: 0, messages: 0, mediaFiles: 0, toolEvents: 0, assistants: 0, geminiSignatures: 0, memories: 0 },
    dropped: [],
    warnings: [],
  };
  const raw = JSON.stringify([
    { id: 'a', presetMessages: '[1,2]', allowPastConversationRecall: false },
    { id: 'b', presetMessages: 'not-json' },
    { id: 'c', presetMessages: [{ id: 'x', role: 'user', content: 'y' }], enableRecentChatsReference: true },
  ]);
  const out = transformAssistantsV1(raw, report0)!;
  const list = JSON.parse(out);
  assert.deepStrictEqual(list[0].presetMessages, [1, 2], '字符串数组重排');
  assert.strictEqual(list[0].enableRecentChatsReference, false, 'false 也合成');
  assert.strictEqual(list[1].presetMessages, 'not-json', '解析失败保留原样');
  assert.strictEqual(list[2].presetMessages[0].content, 'y', '已是数组不动');
  assert.strictEqual(list[2].enableRecentChatsReference, true, '已有旧键不覆盖');
  assert.ok(report0.dropped.some((d) => d.category.includes('presetMessages')), '无法解析计数');
}

// ---------- 9.5 单元：记忆降级边界 ----------
{
  const report1: CompatReport = {
    generatedAt: '', source: { fileName: 'x', format: 'kelivo-backup', formatVersion: 2, payloadKind: 'sqlite', appVersion: null },
    totals: { conversations: 0, messages: 0, mediaFiles: 0, toolEvents: 0, assistants: 0, geminiSignatures: 0, memories: 0 },
    dropped: [], warnings: [],
  };
  const out1 = transformMemories({ memory_entries_v1: 'not-json', assistant_memories_v1: '[{"id":7,"assistantId":"a","content":"旧"}]' }, report1);
  assert.strictEqual(out1.memory_entries_v1, undefined, '不可解析的新键移除');
  assert.strictEqual(out1.assistant_memories_v1, '[{"id":7,"assistantId":"a","content":"旧"}]', '旧键原样保留');
  assert.strictEqual(report1.totals.memories, 0, '未转换不计总数');
  assert.ok(report1.warnings.some((w) => w.includes('memory_entries_v1')), '不可解析警告');

  const report2: CompatReport = {
    generatedAt: '', source: { fileName: 'x', format: 'kelivo-backup', formatVersion: 2, payloadKind: 'sqlite', appVersion: null },
    totals: { conversations: 0, messages: 0, mediaFiles: 0, toolEvents: 0, assistants: 0, geminiSignatures: 0, memories: 0 },
    dropped: [], warnings: [],
  };
  const out2 = transformMemories(
    {
      memory_entries_v1: JSON.stringify([
        { id: 'm1', scope: 'global', status: 'active', content: '孤儿全局' },
        { id: 'm2', scope: 'assistant', status: 'active', content: '' },
        { id: 'm3', scope: 'assistant', assistantId: 'a', status: 'weird', content: 'x' },
      ]),
    },
    report2,
  );
  assert.strictEqual(out2.assistant_memories_v1, undefined, '无合法记录时移除旧键');
  assert.ok(report2.dropped.some((d) => d.category.includes('global')), '无助手列表时 global 丢弃');
  assert.strictEqual(report2.dropped.find((d) => d.category.includes('非法'))?.count, 2, '空内容/非法 status 计数');
}

// ---------- 9.6 单元：搜索服务手术边界 ----------
{
  const report3: CompatReport = {
    generatedAt: '', source: { fileName: 'x', format: 'kelivo-backup', formatVersion: 2, payloadKind: 'sqlite', appVersion: null },
    totals: { conversations: 0, messages: 0, mediaFiles: 0, toolEvents: 0, assistants: 0, geminiSignatures: 0, memories: 0 },
    dropped: [], warnings: [],
  };
  const native = transformSearchServicesV1(
    { search_services_v1: JSON.stringify([{ id: 'a', apiKey: 'p', apiKeys: [{ key: 'x', isEnabled: true }] }]) },
    report3,
  );
  assert.deepStrictEqual(
    JSON.parse(native.search_services_v1 as string)[0].apiKeys,
    [{ key: 'x', isEnabled: true }],
    '已是 Map 不动（Cuplivo 原生）',
  );
  const mixed = transformSearchServicesV1(
    { search_services_v1: JSON.stringify([{ id: 'b', apiKey: 'p', apiKeys: ['s1', 5] }]) },
    report3,
  );
  assert.deepStrictEqual(JSON.parse(mixed.search_services_v1 as string)[0].apiKeys, ['s1', 5], '混合元素保持原样');
  assert.ok(report3.dropped.some((d) => d.category.includes('搜索服务')), '混合元素入报告');
  const bad = transformSearchServicesV1({ search_services_v1: 'not-json' }, report3);
  assert.strictEqual(bad.search_services_v1, 'not-json', '非法 JSON 原样保留');
  assert.ok(report3.warnings.some((w) => w.includes('search_services_v1')), '非法 JSON 警告');
  assert.strictEqual(report3.totals.memories, 0, '搜索手术不动记忆计数');
}

// ---------- 10. 非 v1.2.0 输入拒绝 ----------
{
  const legacyZip = new JSZip();
  legacyZip.file('settings.json', '{}');
  legacyZip.file('chats.json', '{"version":1,"conversations":[],"messages":[]}');
  await assert.rejects(
    () => compatKelivoToCuplivo(legacyZip, 'kelivo_backup_old.zip'),
    /v1\.2\.0/,
    '旧格式 zip 明确拒绝',
  );
  const badManifestZip = new JSZip();
  badManifestZip.file('manifest.json', JSON.stringify({ format: 'kelivo-backup', formatVersion: 1, payloadKind: 'sqlite', entries: {} }));
  await assert.rejects(
    () => compatKelivoToCuplivo(badManifestZip, 'x.zip'),
    /formatVersion=2/,
    '格式版本校验',
  );
}

// ---------- 11. 输出文件名 ----------
assert.match(compatOutputName(new Date('2026-08-12T03:04:05.678Z')), /^kelivo_backup_20260812T030405\.678000\.zip$/, '紧凑 ISO 文件名');

console.log('✅ compat e2e 全部通过');
console.log(
  `  兼容: ${report.totals.conversations} 会话 / ${report.totals.messages} 消息 / ${report.totals.toolEvents} 工具事件 / ${report.totals.assistants} 助手 / ${report.totals.memories} 记忆 / ${report.totals.mediaFiles} 媒体`,
);
