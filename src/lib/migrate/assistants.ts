/** 助手层：RikkaHub Settings.assistants 全量真实还原 → Kelivo Assistant */
import type { Assistant as KelivoAssistant } from '../kelivo/types';
import type { Assistant as RhAssistant, Avatar, UIMessage } from '../rikkahub/types';
import type { MigrateContext } from './context';
import { drop } from '../report';

const DEFAULT_MEMORY_PROMPT =
  '你是一个记忆管理器。用户消息会被提供给你，请将重要信息整理为简洁的记忆条目。';

export function mapAvatar(a: Avatar): string | null {
  if (a.type === 'Dummy') return null;
  if (a.type === 'Emoji') return a.content;
  return a.url;
}

function textOf(um: UIMessage): string {
  return um.parts
    .filter((p): p is Extract<typeof p, { type: 'text' }> => p.type === 'text')
    .map((p) => p.text)
    .join('\n');
}

export function mapAssistant(rh: RhAssistant, ctx: MigrateContext): KelivoAssistant {
  const model = rh.chatModelId ? ctx.modelById.get(rh.chatModelId) : undefined;
  const now = new Date().toISOString();
  return {
    id: rh.id,
    name: rh.name,
    avatar: mapAvatar(rh.avatar),
    useAssistantAvatar: rh.useAssistantAvatar,
    useAssistantName: true,
    chatModelProvider: model?.providerKey ?? null,
    chatModelId: model?.modelId ?? null,
    temperature: rh.temperature,
    topP: rh.topP,
    contextMessageSize: rh.contextMessageLimit,
    limitContextMessages: true,
    streamOutput: rh.streamOutput,
    thinkingBudget: rh.reasoningLevel === 'off' ? 0 : null,
    maxTokens: rh.maxTokens,
    systemPrompt: rh.systemPrompt,
    messageTemplate: rh.messageTemplate,
    searchEnabled: rh.enableWebSearch,
    mcpServerIds: rh.mcpServers,
    localToolIds: [...rh.localTools],
    skillIds: [...rh.enabledSkills],
    background: rh.background,
    customHeaders: rh.customHeaders.map((h) => ({ name: h.name, value: h.value })),
    customBody: rh.customBodies.map((b) => ({
      key: b.key,
      value: typeof b.value === 'string' ? b.value : JSON.stringify(b.value),
    })),
    enableMemory: rh.enableMemory,
    memoryMode: 'injection',
    enableRecentChatsReference: rh.enableRecentChatsReference,
    recentChatsSummaryMessageCount: 5,
    memoryRecordPrompt: DEFAULT_MEMORY_PROMPT,
    presetMessages: rh.presetMessages.map((um) => ({
      id: um.id,
      role: um.role === 'tool' ? 'assistant' : um.role,
      content: textOf(um),
    })),
    regexRules: rh.regexes.map((r) => ({
      id: r.id,
      name: r.name,
      pattern: r.findRegex,
      replacement: r.replaceString,
      scopes: r.affectingScope.map((s) => s.toLowerCase() as 'user' | 'assistant'),
      visualOnly: r.visualOnly,
      replaceOnly: false,
      enabled: r.enabled,
    })),
    enableProactiveCare: false,
    proactiveCareNextMessageAt: null,
    proactiveCarePrompt: '',
    proactiveCareDecisionPrompt: '',
    docxMode: 'extract',
    pdfMode: 'extract',
    otherOfficeMode: 'extract',
    ocrMode: 'auto',
    enableTimeInjection: rh.enableTimeReminder,
    discoverable: false,
    handoffId: null,
    handoffDescription: null,
    createdAt: now,
    updatedAt: now,
  };
}

export interface AssistantLayerOutput {
  assistants: KelivoAssistant[];
  tagList: { id: string; name: string }[];
  tagMap: Record<string, string>;
  lorebookIdsByAssistant: Record<string, string[]>;
  injectionIdsByAssistant: Record<string, string[]>;
}

export function mapAssistants(ctx: MigrateContext): AssistantLayerOutput {
  const { settings, report } = ctx;
  const assistants: KelivoAssistant[] = [];
  const tagList = settings.assistantTags.map((t) => ({ id: t.id, name: t.name }));
  const tagMap: Record<string, string> = {};
  const lorebookIdsByAssistant: Record<string, string[]> = {};
  const injectionIdsByAssistant: Record<string, string[]> = {};

  for (const rh of settings.assistants) {
    const k = mapAssistant(rh, ctx);
    assistants.push(k);
    ctx.kelivoAssistants.set(k.id, k);
    if (rh.tags.length > 0) {
      const first = rh.tags[0];
      if (tagList.some((t) => t.id === first)) {
        tagMap[k.id] = first;
      }
      if (rh.tags.length > 1) {
        drop(report, '助手多标签（Kelivo 每助手仅支持 1 个，保留首个）', rh.tags.length - 1, [rh.name]);
      }
    }
    if (rh.lorebookIds.length > 0) lorebookIdsByAssistant[k.id] = [...rh.lorebookIds];
    if (rh.modeInjectionIds.length > 0) injectionIdsByAssistant[k.id] = [...rh.modeInjectionIds];
  }

  report.totals.assistants = assistants.length;
  return { assistants, tagList, tagMap, lorebookIdsByAssistant, injectionIdsByAssistant };
}
