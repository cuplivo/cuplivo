/** Kelivo v1.2.0 备份包解析：manifest.json + database/kelivo.db + settings.json + 媒体目录 */
import JSZip from 'jszip';
import { openKelivoDb, type KelivoDb } from './db';
import { readZipBytes, readZipText } from '../zip';
import type { KelivoManifest } from './types';
import type { CompatReport } from '../compat/report';

export interface KelivoV120Source {
  zip: JSZip;
  fileName: string;
  manifest: KelivoManifest;
  settings: Record<string, unknown>;
  db: KelivoDb | null;
}

export function parseManifest(text: string): KelivoManifest | null {
  try {
    const obj = JSON.parse(text) as Record<string, unknown>;
    if (obj.format !== 'kelivo-backup' || typeof obj.formatVersion !== 'number') return null;
    if (obj.payloadKind !== 'sqlite' && obj.payloadKind !== 'settings-only') return null;
    if (typeof obj.entries !== 'object' || obj.entries === null) return null;
    return obj as unknown as KelivoManifest;
  } catch {
    return null;
  }
}

export async function loadKelivoV120Source(
  zip: JSZip,
  fileName: string,
  report: CompatReport,
): Promise<KelivoV120Source> {
  const manifestText = await readZipText(zip, 'manifest.json');
  const manifest = manifestText ? parseManifest(manifestText) : null;
  if (!manifest) {
    throw new Error(
      '不是 Kelivo v1.2.0 备份包（缺少 manifest.json 或格式无效）。v1.1.x 旧格式备份请先使用其它工具处理。',
    );
  }
  if (manifest.formatVersion !== 2) {
    throw new Error(`不支持的 Kelivo 备份格式版本：${manifest.formatVersion}（当前兼容 formatVersion=2）`);
  }

  const settingsText = await readZipText(zip, 'settings.json');
  let settings: Record<string, unknown>;
  try {
    const parsed = settingsText ? JSON.parse(settingsText) : null;
    settings = parsed && typeof parsed === 'object' && !Array.isArray(parsed) ? parsed : {};
  } catch {
    settings = {};
  }
  if (Object.keys(settings).length === 0) {
    report.warnings.push('settings.json 缺失或无法解析——助手/提供商/设置无法迁移。');
  }

  const dbBytes = await readZipBytes(zip, 'database/kelivo.db');
  let db: KelivoDb | null = null;
  if (!dbBytes) {
    report.warnings.push('未找到 database/kelivo.db——会话/消息无法迁移。');
  } else {
    try {
      const opened = await openKelivoDb(dbBytes);
      db = opened.db;
      if (opened.memoryFallback) {
        report.warnings.push(
          opened.diagnostics
            ? `database/kelivo.db 以内存模式兜底打开（${opened.diagnostics}）。`
            : 'database/kelivo.db 以内存模式兜底打开。',
        );
      }
    } catch (e) {
      report.warnings.push(`database/kelivo.db 打开失败: ${e instanceof Error ? e.message : String(e)}`);
      db = null;
    }
  }

  return { zip, fileName, manifest, settings, db };
}

export function closeSource(source: KelivoV120Source): void {
  source.db?.close();
}
