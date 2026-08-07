/** 数据层：ConversationEntity + nodes → Kelivo conversations/messages/toolEvents */
import type { ChatMessage, Conversation, ToolEvent, Assistant } from '../kelivo/types';
import type { NodeTurn, UIMessage, UIMessagePart, ConversationEntity } from '../rikkahub/types';
import { basename, isHttpUrl, isoFromEpochMillis, marker, tryParse, tryParseOrNull } from '../rikkahub/util';
import { findFileByBasename } from '../zip';
import type { MigrateContext } from './context';
import { drop } from '../report';

export interface DataLayerOutput {
  conversations: Conversation[];
  messages: ChatMessage[];
  toolEvents: Record<string, ToolEvent[]>;
}

/** 占位助手命名与提示词线索 */
interface PlaceholderHint {
  folderName: string | null;
  systemPrompt: string | null;
}

/** 收集占位线索：会话文件夹名 + 会话级 custom_system_prompt */
function collectHints(ctx: MigrateContext, convs: ConversationEntity[]): Map<string, PlaceholderHint> {
  const hints = new Map<string, PlaceholderHint>();
  const folders: { assistantId: string; name: string }[] = [];
  try {
    for (const f of ctx.source.db?.queryAll<{ assistant_id: string; name: string }>(
      'SELECT assistant_id, name FROM conversation_folder ORDER BY sort_index, create_at',
    ) ?? []) {
      if (!folders.some((x) => x.assistantId === f.assistant_id)) {
        folders.push({ assistantId: f.assistant_id, name: f.name });
      }
    }
  } catch {
    /* conversation_folder 表可能不存在 */
  }
  for (const c of convs) {
    const h = hints.get(c.assistant_id) ?? { folderName: null, systemPrompt: null };
    if (!h.folderName) {
      const f = folders.find((x) => x.assistantId === c.assistant_id);
      h.folderName = f?.name ?? null;
    }
    if (!h.systemPrompt && c.custom_system_prompt.trim()) {
      h.systemPrompt = c.custom_system_prompt.trim();
    }
    hints.set(c.assistant_id, h);
  }
  return hints;
}

/** 为未定义 assistantId 生成占位助手 */
function ensurePlaceholders(ctx: MigrateContext, hints: Map<string, PlaceholderHint>): void {
  let nn = 0;
  for (const [assistantId, hint] of hints) {
    if (ctx.kelivoAssistants.has(assistantId)) continue;
    nn++;
    const name = hint.folderName ?? `Found ${String(nn).padStart(2, '0')}`;
    const now = new Date().toISOString();
    const placeholder: Assistant = {
        id: assistantId,
        name,
        avatar: '⭐',
        useAssistantAvatar: false,
        useAssistantName: false,
        chatModelProvider: null,
        chatModelId: null,
        temperature: null,
        topP: null,
        contextMessageSize: 64,
        limitContextMessages: true,
        streamOutput: true,
        thinkingBudget: null,
        maxTokens: null,
        systemPrompt: hint.systemPrompt ?? 'You are a helpful assistant.',
        messageTemplate: '{{ message }}',
        searchEnabled: false,
        mcpServerIds: [],
        localToolIds: [],
        skillIds: [],
        background: null,
        customHeaders: [],
        customBody: [],
        enableMemory: false,
        memoryMode: 'injection',
        enableRecentChatsReference: false,
        recentChatsSummaryMessageCount: 5,
        memoryRecordPrompt: '',
        presetMessages: [],
        regexRules: [],
        enableProactiveCare: false,
        proactiveCareNextMessageAt: null,
        proactiveCarePrompt: '',
        proactiveCareDecisionPrompt: '',
        docxMode: 'extract',
        pdfMode: 'extract',
        otherOfficeMode: 'extract',
        ocrMode: 'auto',
        enableTimeInjection: false,
        discoverable: false,
        handoffId: null,
        handoffDescription: null,
        createdAt: now,
        updatedAt: now,
      };
    ctx.kelivoAssistants.set(assistantId, placeholder);
    ctx.placeholderCount++;
    ctx.report.placeholderAssistants.push({
      assistantId,
      name,
      reason: hint.systemPrompt
        ? `助手定义缺失，已按会话文件夹「${hint.folderName ?? '未知'}」命名，提示词取自会话自定义系统提示词`
        : `助手定义缺失，已按会话文件夹「${hint.folderName ?? '未知'}」命名`,
    });
  }
}

function partToMarker(part: UIMessagePart, ctx: MigrateContext): string | null {
  if (part.type === 'image') {
    if (isHttpUrl(part.url)) return marker('image', part.url);
    const found = findFileByBasename(ctx.source.zip, basename(part.url));
    const path = found ?? part.url;
    return marker('image', path);
  }
  if (part.type === 'document' || part.type === 'video' || part.type === 'audio') {
    const name = part.type === 'document' ? part.fileName || basename(part.url) : basename(part.url);
    const mime =
      part.type === 'document' ? part.mime || 'application/octet-stream' : undefined;
    const found = findFileByBasename(ctx.source.zip, basename(part.url));
    const path = found ?? part.url;
    const m = mime ?? part.type === 'video' ? 'video/mp4' : part.type === 'audio' ? 'audio/mpeg' : 'application/octet-stream';
    return marker('file', `${path}|${name}|${m}`);
  }
  return null;
}

/** UIMessage → ChatMessage；返回 null 表示该消息被跳过 */
function mapMessage(
  um: UIMessage,
  conversationId: string,
  ctx: MigrateContext,
  toolEvents: Record<string, ToolEvent[]>,
): ChatMessage | null {
  if (um.role !== 'user' && um.role !== 'assistant') {
    drop(ctx.report, `${um.role} 角色消息（Kelivo 仅支持 user/assistant）`, 1);
    return null;
  }
  const parts = um.parts;
  const contentParts: string[] = [];
  const reasoningTexts: string[] = [];
  let reasoningStartAt: string | null = null;
  let reasoningFinishedAt: string | null = null;
  let media = false;
  const events: ToolEvent[] = [];

  for (const p of parts) {
    switch (p.type) {
      case 'text':
        contentParts.push(p.text);
        break;
      case 'image':
      case 'document':
      case 'video':
      case 'audio': {
        const marker = partToMarker(p, ctx);
        if (marker) contentParts.push(marker);
        media = true;
        break;
      }
      case 'reasoning':
        reasoningTexts.push(p.reasoning);
        reasoningStartAt ??= p.createdAt;
        reasoningFinishedAt = p.finishedAt;
        break;
      case 'tool': {
        const input = tryParse<unknown>(p.input, null);
        const outputText = p.output
          .filter((o): o is Extract<typeof o, { type: 'text' }> => o.type === 'text')
          .map((o) => o.text)
          .join('\n');
        events.push({
          id: p.toolCallId,
          name: p.toolName,
          arguments: input && typeof input === 'object' ? (input as Record<string, unknown>) : { raw: p.input },
          content: outputText || null,
          metadata: {},
        });
        break;
      }
      case 'search':
      case 'tool_call':
      case 'tool_result':
        drop(ctx.report, '废弃 part 类型（search/tool_call/tool_result）', 1);
        break;
    }
  }

  if (media) ctx.report.totals.mediaMessages++;

  const model = um.modelId ? ctx.modelById.get(um.modelId) : undefined;
  if (um.modelId && !model) {
    ctx.report.unrecognizedModelIds.push(um.modelId);
  }

  const message: ChatMessage = {
    id: um.id,
    role: um.role,
    content: contentParts.join('\n'),
    timestamp: um.createdAt,
    modelId: model?.modelId ?? null,
    providerId: model?.providerKey ?? null,
    totalTokens: um.usage?.totalTokens ?? null,
    conversationId,
    isStreaming: false,
    reasoningText: reasoningTexts.length > 0 ? reasoningTexts.join('\n') : null,
    reasoningStartAt,
    reasoningFinishedAt,
    translation: um.translation ?? null,
    reasoningSegmentsJson: null,
    groupId: null,
    subgroupId: null,
    version: 0,
    promptTokens: um.usage?.promptTokens ?? null,
    completionTokens: um.usage?.completionTokens ?? null,
    cachedTokens: um.usage?.cachedTokens ?? null,
    durationMs: null,
    isPreset: false,
    speakerAssistantId: null,
  };

  if (events.length > 0) toolEvents[message.id] = events;
  return message;
}

function parseNodes(raw: string): NodeTurn[] | null {
  const nodes = tryParseOrNull<NodeTurn[]>(raw);
  if (!Array.isArray(nodes)) return null;
  return nodes.filter((n) => n && Array.isArray(n.messages));
}

export function mapDataLayer(ctx: MigrateContext): DataLayerOutput {
  const { source, report } = ctx;
  const db = source.db;
  const conversations: Conversation[] = [];
  const messages: ChatMessage[] = [];
  const toolEvents: Record<string, ToolEvent[]> = {};

  if (!db) {
    report.warnings.push('数据库不可用，未迁移任何会话。');
    return { conversations, messages, toolEvents };
  }

  let convs: ConversationEntity[];
  try {
    convs = db.queryAll<ConversationEntity>('SELECT * FROM ConversationEntity ORDER BY create_at');
  } catch {
    report.warnings.push('ConversationEntity 表不存在或不可读。');
    return { conversations, messages, toolEvents };
  }

  const hints = collectHints(ctx, convs);
  ensurePlaceholders(ctx, hints);

  let droppedAlternatives = 0;
  for (const c of convs) {
    const convMessageIds: string[] = [];
    let firstTs: string | null = null;
    let lastTs: string | null = null;

    const nodes = parseNodes(c.nodes);
    if (!nodes || nodes.length === 0) {
      drop(report, 'nodes 解析失败或为空（消息未迁移）', 1, [c.title || c.id]);
    }
    for (const node of nodes ?? []) {
      const sel = node.select_index ?? 0;
      const alternatives = node.messages;
      const chosen = alternatives[sel] ?? alternatives[0];
      droppedAlternatives += alternatives.length - (chosen ? 1 : 0);
      if (!chosen) continue;
      const m = mapMessage(chosen, c.id, ctx, toolEvents);
      if (!m) continue;
      messages.push(m);
      convMessageIds.push(m.id);
      firstTs ??= m.timestamp;
      lastTs = m.timestamp;
    }

    conversations.push({
      id: c.id,
      title: c.title,
      createdAt: firstTs ?? isoFromEpochMillis(c.create_at),
      updatedAt: lastTs ?? isoFromEpochMillis(c.update_at),
      messageIds: convMessageIds,
      isPinned: !!c.is_pinned,
      mcpServerIds: [],
      assistantId: c.assistant_id,
      parentConversationId: null,
      truncateIndex: -1,
      versionSelections: {},
      summary: null,
      lastSummarizedMessageCount: 0,
      chatSuggestions: tryParse<string[]>(c.suggestions, []),
      conversationKind: 'normal',
    });
  }

  report.totals.conversations = conversations.length;
  report.totals.messages = messages.length;
  report.totals.toolEvents = Object.values(toolEvents).reduce((a, e) => a + e.length, 0);
  report.totals.placeholders = ctx.placeholderCount;
  report.droppedAlternatives = droppedAlternatives;
  return { conversations, messages, toolEvents };
}
