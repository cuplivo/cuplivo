/** 助手层：RikkaHub Settings.assistants 全量真实还原 → Kelivo Assistant */
import type { Assistant as KelivoAssistant } from '../kelivo/types';
import type { Assistant as RhAssistant, Avatar, UIMessage } from '../rikkahub/types';
import { normalizePolymorphicType, resolveKelivoAsset } from '../rikkahub/util';
import { findFileByBasename } from '../zip';
import type { MigrateContext } from './context';
import { drop } from '../report';

const DEFAULT_MEMORY_PROMPT =
  '你是一个记忆管理器。用户消息会被提供给你，请将重要信息整理为简洁的记忆条目。';

function registerAsset(ctx: MigrateContext, src: string, dest: string): void {
  if (!ctx.extraAssetCopies.has(dest)) ctx.extraAssetCopies.set(dest, src);
}

export function mapAvatar(a: Avatar, ctx?: MigrateContext): string | null {
  const t = normalizePolymorphicType(a.type);
  if (t === 'Dummy') return null;
  if (t === 'Emoji') {
    const c = 'content' in a && typeof a.content === 'string' ? a.content : null;
    return c;
  }
  const url =
    'url' in a && typeof a.url === 'string' && a.url
      ? a.url
      : t === 'Image'
        ? null
        : null;
  if (url) {
    if (!ctx) return url;
    return resolveKelivoAsset(
      url,
      (name) => findFileByBasename(ctx.source.zip, name),
      'avatars',
      (src, dest) => registerAsset(ctx, src, dest),
    );
  }
  if ('content' in a && typeof a.content === 'string') return a.content;
  return null;
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
  const bg = rh.background
    ? resolveKelivoAsset(
        rh.background,
        (name) => findFileByBasename(ctx.source.zip, name),
        'images',
        (src, dest) => registerAsset(ctx, src, dest),
      )
    : null;
  return {
    id: rh.id,
    name: rh.name,
    avatar: mapAvatar(rh.avatar, ctx),
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
    background: bg,
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
  const tagList = (settings.assistantTags ?? []).map((t) => ({ id: t.id, name: t.name }));
  const tagMap: Record<string, string> = {};
  const lorebookIdsByAssistant: Record<string, string[]> = {};
  const injectionIdsByAssistant: Record<string, string[]> = {};

  for (const rh of settings.assistants ?? []) {
    const k = mapAssistant(rh, ctx);
    assistants.push(k);
    ctx.kelivoAssistants.set(k.id, k);
    if (rh.tags && rh.tags.length > 0) {
      const first = rh.tags[0];
      if (tagList.some((t) => t.id === first)) {
        tagMap[k.id] = first;
      }
      if (rh.tags.length > 1) {
        drop(report, '助手多标签（Kelivo 每助手仅支持 1 个，保留首个）', rh.tags.length - 1, [rh.name]);
      }
    }
    if (rh.lorebookIds && rh.lorebookIds.length > 0) lorebookIdsByAssistant[k.id] = [...rh.lorebookIds];
    if (rh.modeInjectionIds && rh.modeInjectionIds.length > 0) injectionIdsByAssistant[k.id] = [...rh.modeInjectionIds];
  }

  report.totals.assistants = assistants.length;
  return { assistants, tagList, tagMap, lorebookIdsByAssistant, injectionIdsByAssistant };
}
