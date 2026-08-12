/** 迁移编排器：RikkaHub 备份 → Kelivo 可恢复备份包 + 迁移报告 */
import JSZip from 'jszip';
import { loadRikkaHubSource, closeSource } from '../rikkahub/load';
import { copyZipDir, outputNameFrom } from '../zip';
import { emptyReport, type MigrationReport } from '../report';
import type { Settings } from '../rikkahub/types';
import type { ChatsFileV2, SettingsJson } from '../kelivo/types';
import { stringifySettingsJson } from '../kelivo/serialize';
import type { MigrateContext } from './context';
import { mapProviders } from './providers';
import { mapAssistants } from './assistants';
import { mapDataLayer } from './conversations';
import { mapSettings } from './settings';

export interface MigrationResult {
  outputZip: JSZip;
  report: MigrationReport;
  outputName: string;
  chatsFile: ChatsFileV2;
  settingsFile: SettingsJson;
}

export async function migrateRikkaHubToKelivo(zip: JSZip, sourceFileName: string): Promise<MigrationResult> {
  const report = emptyReport(sourceFileName);
  const source = await loadRikkaHubSource(zip, sourceFileName, report);
  report.source.dbVersion = source.dbVersion;
  report.source.walReplayed = source.walReplayed;

  try {
    if (!source.settings) {
      report.warnings.push('settings.json 缺失——只能迁移数据库会话，无法还原助手/提供商。');
    }
    const settings: Settings | null = source.settings;

    const ctx: MigrateContext = {
      source,
      settings: settings ?? ({} as Settings),
      report,
      modelById: new Map(),
      providerKeyById: new Map(),
      kelivoAssistants: new Map(),
      tagMap: new Map(),
      placeholderCount: 0,
    };

    // 防御：settings 数组字段若缺失/非数组（版本差异），归一化为空数组并警告
    if (settings) {
      for (const key of [
        'providers', 'assistants', 'assistantTags', 'searchServices', 'mcpServers',
        'ttsProviders', 'asrProviders', 'quickMessages', 'modeInjections', 'lorebooks',
        'favoriteModels',
      ] as const) {
        const v = (settings as unknown as Record<string, unknown>)[key];
        if (v !== undefined && !Array.isArray(v)) {
          report.warnings.push(`settings.json 字段「${key}」不是数组（可能是旧版本格式），已忽略该层。`);
          (settings as unknown as Record<string, unknown>)[key] = [];
        }
      }
    }

    // 1. 模型层：providers → provider_configs_v1（同时填充 modelById）
    const providers = settings ? mapProviders(ctx) : { configs: {}, order: [], pinned: [], selected: null, titleModel: null };

    // 2. 助手层：真实还原 + 标签/世界书/注入关联
    const assistants = settings ? mapAssistants(ctx) : { assistants: [], tagList: [], tagMap: {}, lorebookIdsByAssistant: {}, injectionIdsByAssistant: {} };

    // 3. 数据层：会话 + 消息 + 工具事件 + 占位兜底
    const data = mapDataLayer(ctx);
    // 助手全集 = 真实还原 + 占位（占位在数据层补入 ctx.kelivoAssistants）
    const allAssistants = [...ctx.kelivoAssistants.values()];

    // 4. 设置层
    const settingsFile = settings
      ? mapSettings(ctx, {
          assistants: JSON.stringify(allAssistants),
          providerConfigs: JSON.stringify(providers.configs),
          providersOrder: providers.order,
          pinned: providers.pinned,
          selected: providers.selected,
          titleModel: providers.titleModel,
          tagList: assistants.tagList,
          tagMap: assistants.tagMap,
          lorebookIdsByAssistant: assistants.lorebookIdsByAssistant,
          injectionIdsByAssistant: assistants.injectionIdsByAssistant,
        })
      : {};

    // 5. chats.json v2
    const chatsFile: ChatsFileV2 = {
      version: 2,
      conversations: data.conversations,
      messages: data.messages,
      toolEvents: data.toolEvents,
      geminiThoughtSigs: {},
      groupChats: [],
      groupMembers: [],
    };

    // 6. 组装输出 zip：settings.json + chats.json + 媒体目录透传
    const outputZip = new JSZip();
    outputZip.file('settings.json', stringifySettingsJson(settingsFile));
    outputZip.file('chats.json', JSON.stringify(chatsFile, null, 2));

    let mediaFiles = 0;
    for (const dir of ['upload/', 'skills/', 'fonts/']) {
      mediaFiles += await copyZipDir(source.zip, outputZip, dir);
    }
    report.totals.mediaFiles = mediaFiles;

    return {
      outputZip,
      report,
      outputName: outputNameFrom(sourceFileName, 'kelivo'),
      chatsFile,
      settingsFile,
    };
  } finally {
    closeSource(source);
  }
}
