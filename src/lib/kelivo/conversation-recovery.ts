/** 对话找回：conversation 条目损坏/丢失但 messages 幸存时，按 conversationId 分组重建会话壳 */
import JSZip from 'jszip';
import { readZipText } from '../zip';
import { tryParseOrNull } from '../rikkahub/util';
import type { ChatMessage, ChatsFile, Conversation, IsoDateTime } from './types';

export interface ConversationRecoveryResult {
  outputZip: JSZip;
  outputName: string;
  /** 找到的孤儿消息数（conversationId 无对应会话） */
  orphanCount: number;
  /** 重建的会话壳数 */
  restoredCount: number;
  restored: { conversationId: string; title: string; messageCount: number }[];
}

function shellTitle(messages: ChatMessage[]): string {
  const firstUser = messages.find((m) => m.role === 'user');
  const raw = firstUser?.content ?? '(无文本消息)';
  const cleaned = raw
    .replace(/\[(image|file):[^\]]*\]/g, '')
    .replace(/\s+/g, ' ')
    .trim();
  return cleaned.length > 50 ? `${cleaned.slice(0, 50)}…` : (cleaned || '(无标题)');
}

function minTime(a: IsoDateTime | null, b: IsoDateTime | null): IsoDateTime | null {
  if (!a) return b;
  if (!b) return a;
  return a < b ? a : b;
}

function maxTime(a: IsoDateTime | null, b: IsoDateTime | null): IsoDateTime | null {
  if (!a) return b;
  if (!b) return a;
  return a > b ? a : b;
}

export async function recoverConversations(zip: JSZip, sourceFileName: string): Promise<ConversationRecoveryResult> {
  const chatsText = await readZipText(zip, 'chats.json');
  if (!chatsText) throw new Error('未在压缩包根目录找到 chats.json，请确保是合法的 Kelivo 备份包。');
  const chats = tryParseOrNull<ChatsFile>(chatsText);
  if (!chats || !Array.isArray(chats.conversations) || !Array.isArray(chats.messages)) {
    throw new Error('chats.json 解析失败：缺少 conversations/messages 列表。');
  }

  const existingIds = new Set(chats.conversations.map((c) => c.id));
  const orphanGroups = new Map<string, Array<ChatMessage & Partial<ChatMessage>>>();
  for (const raw of chats.messages) {
    const m = raw as ChatMessage & Partial<ChatMessage>;
    if (!m.conversationId) continue;
    if (existingIds.has(m.conversationId)) continue;
    const list = orphanGroups.get(m.conversationId) ?? [];
    list.push(m);
    orphanGroups.set(m.conversationId, list);
  }

  const restored: ConversationRecoveryResult['restored'] = [];
  let orphanCount = 0;
  const now = new Date().toISOString();
  for (const [conversationId, group] of orphanGroups) {
    orphanCount += group.length;
    const sorted = [...group].sort((a, b) => a.timestamp.localeCompare(b.timestamp));
    const title = shellTitle(sorted);
    let createdAt: IsoDateTime | null = null;
    let updatedAt: IsoDateTime | null = null;
    for (const m of sorted) {
      createdAt = minTime(createdAt, m.timestamp);
      updatedAt = maxTime(updatedAt, m.timestamp);
    }
    const shell: Conversation = {
      id: conversationId,
      title,
      createdAt: createdAt ?? now,
      updatedAt: updatedAt ?? now,
      messageIds: sorted.map((m) => m.id),
      isPinned: false,
      mcpServerIds: [],
      assistantId: null,
      parentConversationId: null,
      truncateIndex: -1,
      versionSelections: {},
      summary: null,
      lastSummarizedMessageCount: 0,
      chatSuggestions: [],
      conversationKind: 'normal',
    };
    chats.conversations.push(shell);
    restored.push({ conversationId, title, messageCount: group.length });
  }

  if (restored.length > 0) {
    zip.file('chats.json', JSON.stringify(chats, null, 2));
  }

  return {
    outputZip: zip,
    outputName: sourceFileName.replace(/\.zip$/i, '') + '_recovered.zip',
    orphanCount,
    restoredCount: restored.length,
    restored,
  };
}
