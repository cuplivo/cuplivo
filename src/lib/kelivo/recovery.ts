/**
 * 恢复工具引擎：一次扫描完成
 * 1. 助手找回：缺失于 assistants_v1 的 assistantId 重建占位助手
 * 2. 对话找回：孤儿消息按 conversationId 重建会话壳
 * 3. null 挂载：会话壳与 assistantId 为 null 的现有会话挂载到恢复助手（否则 Kelivo UI 不可见）
 */
import JSZip from 'jszip';
import { readZipText } from '../zip';
import { tryParse, tryParseOrNull } from '../rikkahub/util';
import type { Assistant, ChatMessage, ChatsFile, Conversation, IsoDateTime, SettingsJson } from './types';

export const RECOVERY_ASSISTANT_NAME = '恢复的会话';
/** 固定 id：不与其他助手冲突；若备份已存在同名助手则复用其 id */
export const RECOVERY_ASSISTANT_ID = 'recovered-conversations-assistant';

export interface RecoveryResult {
  outputZip: JSZip;
  outputName: string;
  /** 缺失助手（不含恢复助手） */
  missingAssistants: { assistantId: string; titles: string[]; created: boolean }[];
  /** 新建占位助手数（含恢复助手） */
  placeholdersCreated: number;
  /** 孤儿消息数 */
  orphanMessages: number;
  /** 重建的会话壳数 */
  shellsRestored: number;
  /** 挂载到恢复助手的会话数（壳 + 原 null 会话） */
  mountedCount: number;
  /** 恢复助手 id（复用或新建） */
  recoveryAssistantId: string;
  warnings: string[];
}

const PLACEHOLDER_TEMPLATE: Omit<Assistant, 'id' | 'name' | 'createdAt' | 'updatedAt'> = {
  avatar: '⭐',
  useAssistantAvatar: false,
  useAssistantName: false,
  chatModelProvider: 'deepseek',
  chatModelId: 'deepseek-v4-flash',
  temperature: null,
  topP: null,
  contextMessageSize: 1024,
  limitContextMessages: false,
  streamOutput: true,
  thinkingBudget: 1024,
  maxTokens: null,
  systemPrompt: 'You are a helpful assistant.',
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
};

function newPlaceholder(id: string, name: string, now: string): Assistant {
  return { id, name, createdAt: now, updatedAt: now, ...PLACEHOLDER_TEMPLATE };
}

function shellTitle(messages: Array<ChatMessage & Partial<ChatMessage>>): string {
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

export async function runRecovery(zip: JSZip, sourceFileName: string): Promise<RecoveryResult> {
  const warnings: string[] = [];

  const chatsText = await readZipText(zip, 'chats.json');
  if (!chatsText) throw new Error('未在压缩包根目录找到 chats.json，请确保是合法的 Kelivo 备份包。');
  const chats = tryParseOrNull<ChatsFile>(chatsText);
  if (!chats || !Array.isArray(chats.conversations) || !Array.isArray(chats.messages)) {
    throw new Error('chats.json 解析失败：缺少 conversations/messages 列表。');
  }

  const settingsText = await readZipText(zip, 'settings.json');
  const settings = tryParse<SettingsJson>(settingsText ?? '{}', {});
  const existingAssistants = tryParse<Assistant[]>(settings.assistants_v1, []);

  const conversations = chats.conversations;
  const messages = chats.messages as Array<ChatMessage & Partial<ChatMessage>>;

  // 原有 null 会话数（不含稍后新建的会话壳）
  let nullCount = 0;
  for (const conv of conversations) {
    if (conv.assistantId === null || conv.assistantId === undefined) nullCount++;
  }

  // ---------- 1. 重建会话壳（孤儿消息） ----------
  const existingIds = new Set(conversations.map((c) => c.id));
  const orphanGroups = new Map<string, Array<ChatMessage & Partial<ChatMessage>>>();
  for (const m of messages) {
    if (!m.conversationId) continue;
    if (existingIds.has(m.conversationId)) continue;
    const list = orphanGroups.get(m.conversationId) ?? [];
    list.push(m);
    orphanGroups.set(m.conversationId, list);
  }

  const now = new Date().toISOString();
  for (const [conversationId, group] of orphanGroups) {
    const sorted = [...group].sort((a, b) => a.timestamp.localeCompare(b.timestamp));
    let createdAt: IsoDateTime | null = null;
    let updatedAt: IsoDateTime | null = null;
    for (const m of sorted) {
      createdAt = minTime(createdAt, m.timestamp);
      updatedAt = maxTime(updatedAt, m.timestamp);
    }
    const shell: Conversation = {
      id: conversationId,
      title: shellTitle(sorted),
      createdAt: createdAt ?? now,
      updatedAt: updatedAt ?? now,
      messageIds: sorted.map((m) => m.id),
      isPinned: false,
      mcpServerIds: [],
      assistantId: null, // 占位，稍后挂载
      parentConversationId: null,
      truncateIndex: -1,
      versionSelections: {},
      summary: null,
      lastSummarizedMessageCount: 0,
      chatSuggestions: [],
      conversationKind: 'normal',
    };
    conversations.push(shell);
  }

  // ---------- 2. 收集缺失助手 ----------
  const knownIds = new Set(existingAssistants.map((a) => a.id));
  const missingMap = new Map<string, string[]>(); // assistantId -> 采样标题
  for (const conv of conversations) {
    if (conv.assistantId === null || conv.assistantId === undefined) continue;
    if (knownIds.has(conv.assistantId)) continue;
    const titles = missingMap.get(conv.assistantId) ?? [];
    if (titles.length < 5 && conv.title) titles.push(conv.title);
    missingMap.set(conv.assistantId, titles);
  }

  // ---------- 3. 恢复助手（复用同名助手或新建） ----------
  let recoveryAssistantId = RECOVERY_ASSISTANT_ID;
  let recoveryAssistantAdded = false;
  const existingByName = existingAssistants.find((a) => a.name === RECOVERY_ASSISTANT_NAME);
  if (existingByName) {
    recoveryAssistantId = existingByName.id;
  } else if (!knownIds.has(recoveryAssistantId)) {
    existingAssistants.push(newPlaceholder(recoveryAssistantId, RECOVERY_ASSISTANT_NAME, now));
    recoveryAssistantAdded = true;
  }

  // ---------- 4. 挂载 null 会话到恢复助手 ----------
  for (const conv of conversations) {
    if (conv.assistantId === null || conv.assistantId === undefined) {
      conv.assistantId = recoveryAssistantId;
    }
  }

  // ---------- 5. 缺失助手占位（Found NN） ----------
  const missingAssistants: RecoveryResult['missingAssistants'] = [];
  let foundCount = 0;
  for (const [assistantId, titles] of missingMap) {
    foundCount++;
    const placeholder = newPlaceholder(
      assistantId,
      `Found ${String(foundCount).padStart(2, '0')}`,
      now,
    );
    existingAssistants.push(placeholder);
    missingAssistants.push({ assistantId, titles, created: true });
  }

  // ---------- 6. 写回 ----------
  if (orphanGroups.size > 0 || nullCount > 0 || missingMap.size > 0) {
    zip.file('chats.json', JSON.stringify(chats, null, 2));
  }
  if (foundCount > 0 || recoveryAssistantAdded) {
    settings.assistants_v1 = JSON.stringify(existingAssistants);
    zip.file('settings.json', JSON.stringify(settings, null, 2));
  }
  if (nullCount > 0 && !settings.assistants_v1) {
    warnings.push('settings.json 缺失或无法写入——恢复助手无法注册，挂载的会话可能仍不可见。');
  }

  return {
    outputZip: zip,
    outputName: sourceFileName.replace(/\.zip$/i, '') + '_recovered.zip',
    missingAssistants,
    placeholdersCreated: foundCount + (recoveryAssistantAdded ? 1 : 0),
    orphanMessages: [...orphanGroups.values()].reduce((a, g) => a + g.length, 0),
    shellsRestored: orphanGroups.size,
    mountedCount: orphanGroups.size + nullCount,
    recoveryAssistantId,
    warnings,
  };
}
