/**
 * 兼容编排器：Kelivo v1.2.0 备份 zip → Cuplivo v2.7.1 可恢复备份 zip + 兼容报告
 *
 * 与迁移（RikkaHub→Kelivo）相互独立，不共享转换管线（CONTEXT.md 术语「兼容」）。
 * 目标 zip 形态对齐 Cuplivo 自身导出惯例：settings.json + chats.json(version 1，
 * 字段群含 groupChats 等) + deleted.json({}) + upload|avatars|images|fonts/，
 * 文件名 kelivo_backup_<紧凑ISO>.zip
 */
import JSZip from 'jszip';
import { loadKelivoV120Source, closeSource } from '../kelivo-v120/load';
import { copyZipDir } from '../zip';
import { emptyCompatReport, type CompatReport } from './report';
import { transformSettings } from '../cuplivo/settings';
import { buildChats } from '../cuplivo/chats';
import { stringifySettingsJson } from '../kelivo/serialize';

export interface CompatResult {
  outputZip: JSZip;
  report: CompatReport;
  outputName: string;
}

/** kelivo_backup_YYYYMMDDTHHMMSS.ffffff.zip（目标应用紧凑 ISO 惯例，UTC） */
function compactIso(now: Date): string {
  const pad = (n: number, w: number) => String(n).padStart(w, '0');
  return (
    `${now.getUTCFullYear()}${pad(now.getUTCMonth() + 1, 2)}${pad(now.getUTCDate(), 2)}T` +
    `${pad(now.getUTCHours(), 2)}${pad(now.getUTCMinutes(), 2)}${pad(now.getUTCSeconds(), 2)}.` +
    `${pad(now.getUTCMilliseconds(), 3)}000`
  );
}

export function compatOutputName(now: Date = new Date()): string {
  return `kelivo_backup_${compactIso(now)}.zip`;
}

export async function compatKelivoToCuplivo(
  zip: JSZip,
  sourceFileName: string,
  now: Date = new Date(),
): Promise<CompatResult> {
  const report = emptyCompatReport(sourceFileName);
  const source = await loadKelivoV120Source(zip, sourceFileName, report);
  report.source.format = source.manifest.format;
  report.source.formatVersion = source.manifest.formatVersion;
  report.source.payloadKind = source.manifest.payloadKind;
  report.source.appVersion = source.manifest.appVersion ?? null;

  try {
    // 1. settings.json：近逐字直通 + 助手层手术
    const settingsFile = transformSettings(source.settings, report);

    // 2. chats.json：全保真展平（version 恒 1）
    const chatsFile = buildChats(source, report);

    // 3. 组装输出 zip：settings + chats + deleted({}) + 媒体目录透传
    const outputZip = new JSZip();
    // stringifySettingsJson：double 键归一（1.0 → '1' 会被写回成 int，
    // Cuplivo v2.7.1 恢复后 prefs.getDouble 强转崩溃——1b42277b 同因）
    outputZip.file('settings.json', stringifySettingsJson(settingsFile));
    outputZip.file('chats.json', JSON.stringify(chatsFile, null, 2));
    outputZip.file('deleted.json', '{}');

    let mediaFiles = 0;
    for (const dir of ['upload/', 'avatars/', 'images/', 'fonts/']) {
      mediaFiles += await copyZipDir(zip, outputZip, dir);
    }
    report.totals.mediaFiles = mediaFiles;

    if (source.manifest.payloadKind === 'settings-only') {
      report.warnings.push('源备份为仅设置模式（includeChats=false）——会话/消息为空。');
    }

    return {
      outputZip,
      report,
      outputName: compatOutputName(now),
    };
  } finally {
    closeSource(source);
  }
}
