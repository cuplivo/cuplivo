/** 助手找回：扫描 chats.json 缺失于 assistants_v1 的 assistantId，重建占位助手并写回 settings.json */
import JSZip from 'jszip';
import { readZipText } from '../zip';
import { tryParse, tryParseOrNull } from '../rikkahub/util';
import type { Assistant, ChatsFile, SettingsJson } from './types';

export interface AssistantRecoveryResult {
  outputZip: JSZip;
  outputName: string;
  /** 识别到的缺失 assistantId 总数 */
  missingCount: number;
  /** 实际新建的占位助手数（已存在的跳过） */
  createdCount: number;
  /** assistantId → 采样对话标题 */
  missing: { assistantId: string; titles: string[]; created: boolean }[];
}

const DEFAULT_PLACEHOLDER: Omit<Assistant, 'id' | 'name' | 'createdAt' | 'updatedAt'> = {
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
  return { id, name, createdAt: now, updatedAt: now, ...DEFAULT_PLACEHOLDER };
}

export async function recoverAssistants(zip: JSZip, sourceFileName: string): Promise<AssistantRecoveryResult> {
  const chatsText = await readZipText(zip, 'chats.json');
  if (!chatsText) throw new Error('未在压缩包根目录找到 chats.json，请确保是合法的 Kelivo 备份包。');
  const chats = tryParseOrNull<ChatsFile>(chatsText);
  if (!chats || !Array.isArray(chats.conversations)) {
    throw new Error('chats.json 解析失败：缺少 conversations 列表。');
  }

  const settingsText = await readZipText(zip, 'settings.json');
  const settings = tryParse<SettingsJson>(settingsText ?? '{}', {});
  const existing = tryParse<Assistant[]>(settings.assistants_v1 as unknown as string, []);

  // 聚类缺失 assistantId，附采样标题
  const seen = new Set<string>();
  const missing: AssistantRecoveryResult['missing'] = [];
  for (const conv of chats.conversations) {
    const aid = conv.assistantId;
    if (!aid || existing.some((a) => a.id === aid)) continue;
    if (seen.has(aid)) {
      const item = missing.find((m) => m.assistantId === aid);
      if (item && item.titles.length < 5 && conv.title) item.titles.push(conv.title);
      continue;
    }
    seen.add(aid);
    missing.push({ assistantId: aid, titles: conv.title ? [conv.title] : [], created: false });
  }

  // 重建占位
  const now = new Date().toISOString();
  let createdCount = 0;
  const updatedAssistants = [...existing];
  for (const item of missing) {
    createdCount++;
    item.created = true;
    updatedAssistants.push(newPlaceholder(item.assistantId, `Found ${String(createdCount).padStart(2, '0')}`, now));
  }

  if (createdCount > 0) {
    settings.assistants_v1 = JSON.stringify(updatedAssistants);
    zip.file('settings.json', JSON.stringify(settings, null, 2));
  }

  const base = sourceFileName.replace(/\.zip$/i, '');
  return {
    outputZip: zip,
    outputName: `${base}_recovered.zip`,
    missingCount: missing.length,
    createdCount,
    missing,
  };
}
