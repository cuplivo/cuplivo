/**
 * chats.json v2 构造：kelivo.db 会话/消息/部件 → Cuplivo chats.json
 *
 * 原则（兼容裁定）：全保真展平
 * - 消息全量（含全部 revision 与 versionSelections）——Cuplivo 原生格式即如此
 * - text → content；reasoning → reasoningText（\n 拼接）；tool_call → toolEvents[messageId]（载荷原样）
 * - image/file → [image:ref] / [file:ref|name|mime] 标记；kelivo-file: URI → /root/rel
 * - unknown 部件原样入 content；损坏部件丢弃入报告
 * - null assistantId 会话原样保留（Cuplivo 侧边栏显式包含 null 会话，无需挂载）
 */
import { drop, type CompatReport } from '../compat/report';
import type { KelivoV120Source } from '../kelivo-v120/load';
import type {
  AssetRow,
  ConversationRow,
  MessagePartRow,
  MessageRow,
} from '../kelivo-v120/types';
import {
  microsToIso,
  nullableMicrosToIso,
  parseJsonOr,
  queryAssets,
  queryConversationMcps,
  queryConversations,
  queryGeminiSignatures,
  queryMessageAssets,
  queryMessages,
  queryParts,
} from '../kelivo-v120/query';
import type { ChatsFileV2, ChatMessage, Conversation, ToolEvent } from '../kelivo/types';

const MANAGED_ROOTS = ['upload', 'images', 'avatars', 'fonts'];

/** 绝对路径 → 便携斜杠路径；file: scheme 剥除；UNC 拒绝 */
function portableSlash(path: string): string | null {
  let v = path;
  if (/^file:/i.test(v)) {
    try {
      const u = new URL(v);
      if (u.host !== '' && u.host !== 'localhost') return null;
      v = decodeURIComponent(u.pathname);
      if (/^\/[A-Za-z]:/.test(v)) v = v.substring(1);
    } catch {
      return null;
    }
  }
  if (v.startsWith('\\\\') || v.startsWith('//')) return null;
  if (/^[A-Za-z]:[\\/]/.test(v)) return v.replaceAll('\\', '/');
  if (v.includes('\\')) return null;
  return v;
}

/** 在路径中定位管理根目录（upload/images/avatars/fonts），返回 'root/rest'（含根） */
function managedTail(path: string): string | null {
  const lower = path.toLowerCase();
  for (const root of MANAGED_ROOTS) {
    const i = lower.indexOf(`/${root}/`);
    if (i !== -1) {
      const tail = path.substring(i + 1);
      if (tail.length > root.length + 1) return tail;
    }
  }
  return null;
}

/** 形如 'upload/x.png' 的相对路径 → 校验根目录 */
function relativeManaged(path: string): string | null {
  const m = /^([A-Za-z0-9_-]+)\/(.+)$/.exec(path);
  if (!m) return null;
  const root = m[1].toLowerCase();
  if (!MANAGED_ROOTS.includes(root)) return null;
  if (m[2].length === 0 || m[2].includes('..')) return null;
  return `${root}/${m[2]}`;
}

interface PartPayloadObj {
  uri?: unknown;
  name?: unknown;
  mime?: unknown;
  assetId?: unknown;
}

function parsePartPayload(payload: string): PartPayloadObj | null {
  try {
    const parsed: unknown = JSON.parse(payload);
    if (typeof parsed === 'object' && parsed !== null && !Array.isArray(parsed)) {
      return parsed as PartPayloadObj;
    }
  } catch {
    /* fallthrough */
  }
  return null;
}

export interface FlattenContext {
  zipHas: (path: string) => boolean;
  assetPathById: Map<string, string>;
}

/** 媒体引用 → Cuplivo 标记内路径（保真优先；映射失败的引用保留原文并计数） */
function resolveMediaRef(
  uri: unknown,
  assetId: unknown,
  ctx: FlattenContext,
  report: CompatReport,
): string | null {
  if (typeof uri !== 'string' || uri.length === 0) return null;

  // 网络/data URI：原样（无前导斜杠）
  if (/^(https?:|data:)/i.test(uri)) return uri;

  const assetPath =
    typeof assetId === 'string' && assetId.length > 0
      ? ctx.assetPathById.get(assetId)
      : undefined;

  // kelivo-file:///root/rel → /root/rel（语义即位置；zip 缺文件时尝试媒体库路径）
  const kf = /^kelivo-file:\/\/\/(.+)$/.exec(uri);
  if (kf) {
    let rel: string | null = null;
    try {
      const segments = kf[1].split('/').map((s) => decodeURIComponent(s));
      if (
        segments.length >= 2 &&
        !segments.some((s) => s.length === 0 || s === '.' || s === '..') &&
        MANAGED_ROOTS.includes(segments[0].toLowerCase())
      ) {
        segments[0] = segments[0].toLowerCase();
        rel = segments.join('/');
      }
    } catch {
      /* fallthrough */
    }
    if (rel === null) {
      drop(report, 'kelivo-file: URI 无法解析（标记保留原文）', 1, [uri]);
      return uri;
    }
    if (ctx.zipHas(rel)) return `/${rel}`;
    const lib = managedTail(assetPath ?? '') ?? relativeManaged(assetPath ?? '');
    if (lib && ctx.zipHas(lib)) return `/${lib}`;
    drop(report, '媒体文件不在备份包中（标记保留路径，Cuplivo 将显示为缺失）', 1, [uri]);
    return `/${rel}`;
  }

  // 绝对沙盒路径 / 相对路径：词法映射到管理根
  const portable = portableSlash(uri);
  if (portable === null) {
    drop(report, '媒体路径无法识别（标记保留原文）', 1, [uri]);
    return uri;
  }
  const rel = managedTail(portable) ?? relativeManaged(portable);
  if (rel !== null && (ctx.zipHas(rel) || portable !== uri)) {
    return `/${rel}`;
  }
  if (rel !== null) {
    drop(report, '媒体文件不在备份包中（标记保留路径，Cuplivo 将显示为缺失）', 1, [uri]);
    return `/${rel}`;
  }
  return portable;
}

export interface FlattenedPart {
  text: string;
  toolEvent: ToolEvent | null;
  /** 是否属于 reasoning（归入 reasoningText 而非 content） */
  isReasoning: boolean;
}

function flattenPart(kind: string, payload: string, ctx: FlattenContext, report: CompatReport): FlattenedPart {
  switch (kind) {
    case 'text':
      return { text: payload, toolEvent: null, isReasoning: false };
    case 'reasoning':
      return { text: payload, toolEvent: null, isReasoning: true };
    case 'tool_call': {
      try {
        const parsed: unknown = JSON.parse(payload);
        if (typeof parsed === 'object' && parsed !== null) {
          return { text: '', toolEvent: parsed as ToolEvent, isReasoning: false };
        }
        drop(report, 'tool_call 载荷非对象（丢弃）', 1);
        return { text: '', toolEvent: null, isReasoning: false };
      } catch {
        drop(report, 'tool_call 载荷无法解析（丢弃）', 1, [payload.slice(0, 120)]);
        return { text: '', toolEvent: null, isReasoning: false };
      }
    }
    case 'image': {
      const p = parsePartPayload(payload);
      if (p === null) {
        drop(report, 'image 部件损坏（丢弃）', 1);
        return { text: '', toolEvent: null, isReasoning: false };
      }
      const ref = resolveMediaRef(p.uri, p.assetId, ctx, report);
      if (ref === null) {
        drop(report, 'image 部件损坏（丢弃）', 1);
        return { text: '', toolEvent: null, isReasoning: false };
      }
      return { text: `\n[image:${ref}]`, toolEvent: null, isReasoning: false };
    }
    case 'file': {
      const p = parsePartPayload(payload);
      if (p === null) {
        drop(report, 'file 部件损坏（丢弃）', 1);
        return { text: '', toolEvent: null, isReasoning: false };
      }
      const ref = resolveMediaRef(p.uri, p.assetId, ctx, report);
      if (ref === null) {
        drop(report, 'file 部件损坏（丢弃）', 1);
        return { text: '', toolEvent: null, isReasoning: false };
      }
      const name = typeof p.name === 'string' && p.name.length > 0 ? p.name : 'file';
      const mime = typeof p.mime === 'string' && p.mime.length > 0 ? p.mime : 'application/octet-stream';
      return { text: `\n[file:${ref}|${name}|${mime}]`, toolEvent: null, isReasoning: false };
    }
    default:
      // 未知部件：原样保留到 content（保真）+ 报告计数
      drop(report, `未知消息部件类型「${kind}」（原样保留到 content）`, 1);
      return { text: payload, toolEvent: null, isReasoning: false };
  }
}

function buildConversation(
  row: ConversationRow,
  mcpsByConv: Map<string, string[]>,
  idsByConv: Map<string, string[]>,
): Conversation {
  return {
    id: row.id,
    title: row.title,
    createdAt: microsToIso(row.created_at),
    updatedAt: microsToIso(row.updated_at),
    messageIds: idsByConv.get(row.id) ?? [],
    isPinned: !!row.is_pinned,
    mcpServerIds: mcpsByConv.get(row.id) ?? [],
    assistantId: row.assistant_id,
    parentConversationId: null,
    truncateIndex: row.truncate_index,
    versionSelections: parseJsonOr<Record<string, number>>(row.version_selections_json, {}),
    summary: row.summary,
    lastSummarizedMessageCount: row.last_summarized_message_count,
    chatSuggestions: parseJsonOr<string[]>(row.chat_suggestions_json, []),
    conversationKind: 'normal',
    // kelivo v1.2.0 独有（保真透传；Cuplivo 忽略）
    injectedMemoryHash: row.injected_memory_hash,
    lastMemoryExtractedOrder: row.last_memory_extracted_order,
  };
}

interface BuiltMessage {
  message: ChatMessage;
  toolEvents: ToolEvent[];
}

function buildMessage(row: MessageRow, parts: MessagePartRow[], ctx: FlattenContext, report: CompatReport): BuiltMessage {
  let content = '';
  const reasoning: string[] = [];
  const toolEvents: ToolEvent[] = [];
  for (const part of parts) {
    const f = flattenPart(part.kind, part.payload, ctx, report);
    if (f.isReasoning) {
      if (f.text.length > 0) reasoning.push(f.text);
    } else {
      content += f.text;
    }
    if (f.toolEvent !== null) toolEvents.push(f.toolEvent);
  }
  return {
    message: {
      id: row.id,
      role: row.role,
      content,
      timestamp: microsToIso(row.timestamp),
      modelId: row.model_id,
      providerId: row.provider_id,
      totalTokens: row.total_tokens,
      conversationId: row.conversation_id,
      isStreaming: !!row.is_streaming,
      reasoningText: reasoning.length > 0 ? reasoning.join('\n') : null,
      reasoningStartAt: nullableMicrosToIso(row.reasoning_start_at),
      reasoningFinishedAt: nullableMicrosToIso(row.reasoning_finished_at),
      translation: row.translation,
      reasoningSegmentsJson: row.reasoning_segments_json,
      groupId: row.group_id,
      subgroupId: null,
      version: row.version,
      promptTokens: row.prompt_tokens,
      completionTokens: row.completion_tokens,
      cachedTokens: row.cached_tokens,
      durationMs: row.duration_ms,
      isPreset: false,
      speakerAssistantId: null,
    },
    toolEvents,
  };
}

export function buildChats(source: KelivoV120Source, report: CompatReport): ChatsFileV2 {
  const db = source.db;

  if (!db) {
    drop(report, '会话/消息（数据库缺失）', 1);
    return {
      version: 2,
      conversations: [],
      messages: [],
      toolEvents: {},
      geminiThoughtSigs: {},
      groupChats: [],
      groupMembers: [],
    };
  }

  const convRows = queryConversations(db);
  const mcpRows = queryConversationMcps(db);
  const msgRows = queryMessages(db);
  const partRows = queryParts(db);
  const sigRows = queryGeminiSignatures(db);
  const assetRows = queryAssets(db);
  const msgAssetRows = queryMessageAssets(db);

  const mcpsByConv = new Map<string, string[]>();
  for (const r of mcpRows) {
    const list = mcpsByConv.get(r.conversation_id) ?? [];
    list.push(r.server_id);
    mcpsByConv.set(r.conversation_id, list);
  }

  const idsByConv = new Map<string, string[]>();
  for (const r of msgRows) {
    const list = idsByConv.get(r.conversation_id) ?? [];
    list.push(r.id);
    idsByConv.set(r.conversation_id, list);
  }

  const partsByRevision = new Map<string, MessagePartRow[]>();
  for (const p of partRows) {
    const list = partsByRevision.get(p.revision_id) ?? [];
    list.push(p);
    partsByRevision.set(p.revision_id, list);
  }

  const assetsById = new Map<string, AssetRow>();
  for (const a of assetRows) assetsById.set(a.id, a);
  const assetPathById = new Map<string, string>();
  for (const link of msgAssetRows) {
    const asset = assetsById.get(link.asset_id);
    if (asset && !assetPathById.has(link.asset_id)) {
      assetPathById.set(link.asset_id, asset.path);
    }
  }

  const zipHas = (path: string): boolean => source.zip.file(path) !== null;

  const ctx: FlattenContext = { zipHas, assetPathById };

  const toolEvents: Record<string, ToolEvent[]> = {};
  const messages = msgRows.map((row) => {
    const built = buildMessage(row, partsByRevision.get(row.id) ?? [], ctx, report);
    if (built.toolEvents.length > 0) toolEvents[row.id] = built.toolEvents;
    return built.message;
  });

  const geminiThoughtSigs: Record<string, string> = {};
  for (const sig of sigRows) {
    geminiThoughtSigs[sig.revision_id] = sig.payload;
  }

  const conversations = convRows.map((row) => buildConversation(row, mcpsByConv, idsByConv));

  report.totals.conversations = conversations.length;
  report.totals.messages = messages.length;
  report.totals.toolEvents = Object.values(toolEvents).reduce((n, e) => n + e.length, 0);
  report.totals.geminiSignatures = Object.keys(geminiThoughtSigs).length;

  return {
    version: 2,
    conversations,
    messages,
    toolEvents,
    geminiThoughtSigs,
    groupChats: [],
    groupMembers: [],
  };
}

export { portableSlash, managedTail, relativeManaged };
