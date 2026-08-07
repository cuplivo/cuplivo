/** 模型层：RikkaHub providers → Kelivo provider_configs_v1 + ModelRef 解析 */
import type { ProviderConfig, ModelRef } from '../kelivo/types';
import type { Model, ProviderSetting } from '../rikkahub/types';
import type { MigrateContext } from './context';
import { drop } from '../report';

export interface ProvidersOutput {
  configs: Record<string, ProviderConfig>;
  order: string[];
  pinned: ModelRef[];
  selected: ModelRef | null;
  titleModel: ModelRef | null;
}

function mapModelType(t: Model['type']): 'chat' | 'embedding' {
  if (t === 'EMBEDDING') return 'embedding';
  return 'chat';
}

function mapProvider(p: ProviderSetting): ProviderConfig {
  const base: ProviderConfig = {
    id: p.id,
    enabled: p.enabled,
    name: p.name,
    apiKey: p.apiKey,
    baseUrl: p.baseUrl,
    models: p.models.map((m) => m.modelId),
    claudePromptCachingEnabled: false,
  };
  const overrides: NonNullable<ProviderConfig['modelOverrides']> = {};
  for (const m of p.models) {
    overrides[m.modelId] = {
      name: m.displayName,
      type: mapModelType(m.type),
      input: m.inputModalities,
      output: m.outputModalities,
      abilities: m.abilities,
      tools: m.tools,
    };
  }
  if (Object.keys(overrides).length > 0) base.modelOverrides = overrides;
  if (p.balanceOption && p.balanceOption.enabled) {
    base.balanceEnabled = true;
    base.balanceApiPath = p.balanceOption.apiPath;
    base.balanceResultPath = p.balanceOption.resultPath;
  }
  if (p.type === 'openai') {
    base.providerType = 'openai';
    if (p.chatCompletionsPath) base.chatPath = p.chatCompletionsPath;
    if (p.useResponseApi) base.useResponseApi = true;
  } else if (p.type === 'google') {
    base.providerType = 'google';
    base.vertexAI = p.vertexAI;
    if (p.location) base.location = p.location;
    if (p.projectId) base.projectId = p.projectId;
  } else {
    base.providerType = 'claude';
    base.claudePromptCachingEnabled = p.promptCaching;
    base.claudePromptCachingTtl = p.promptCacheTtl;
  }
  return base;
}

export function mapProviders(ctx: MigrateContext): ProvidersOutput {
  const { settings, report } = ctx;
  const configs: Record<string, ProviderConfig> = {};
  const order: string[] = [];

  for (const p of settings.providers ?? []) {
    configs[p.id] = mapProvider(p);
    order.push(p.id);
    ctx.providerKeyById.set(p.id, p.id);
    for (const m of p.models) {
      ctx.modelById.set(m.id, { providerKey: p.id, modelId: m.modelId });
    }
    if (p.models.some((m) => m.type === 'IMAGE')) {
      report.warnings.push(`提供商「${p.name}」含 IMAGE 类型模型，已按 chat 类型近似映射。`);
    }
    if (p.type === 'google' && p.useServiceAccount && !p.privateKey) {
      drop(report, 'google 服务账号私钥（无法重组 serviceAccountJson）', 1, [p.name]);
    }
  }

  const resolveRef = (uuid: string | null | undefined): ModelRef | null => {
    if (!uuid) return null;
    const r = ctx.modelById.get(uuid);
    if (!r) {
      report.unrecognizedModelIds.push(uuid);
      return null;
    }
    return `${r.providerKey}::${r.modelId}`;
  };

  const pinned: ModelRef[] = [];
  for (const uuid of settings.favoriteModels ?? []) {
    const ref = resolveRef(uuid);
    if (ref) pinned.push(ref);
  }
  const selected = resolveRef(settings.chatModelId);
  const titleModel = resolveRef(settings.titleModelId);

  report.totals.providers = order.length;
  return { configs, order, pinned, selected, titleModel };
}
