/** RikkaHub 备份包解析：settings.json + DB 提取 */
import JSZip from 'jszip';
import { openRikkaHubDb, type RikkaHubDb } from './db';
import { readZipBytes, readZipText } from '../zip';
import { tryParseOrNull } from './util';
import type { Settings } from './types';
import type { MigrationReport } from '../report';

export interface RikkaHubSource {
  zip: JSZip;
  fileName: string;
  settings: Settings | null;
  db: RikkaHubDb | null;
  dbVersion: number | null;
  walReplayed: boolean;
}

export async function loadRikkaHubSource(zip: JSZip, fileName: string, report: MigrationReport): Promise<RikkaHubSource> {
  // 1. settings.json
  const settingsText = await readZipText(zip, 'settings.json');
  const settings = settingsText ? tryParseOrNull<Settings>(settingsText) : null;
  if (!settings) {
    report.warnings.push('settings.json 缺失或无法解析——助手/提供商/设置无法迁移，仅能迁移数据库会话数据。');
  }

  // 2. rikka_hub.db (+wal)
  const dbBytes = await readZipBytes(zip, 'rikka_hub.db');
  let db: RikkaHubDb | null = null;
  let dbVersion: number | null = null;
  let walReplayed = false;
  if (!dbBytes) {
    report.warnings.push('未找到 rikka_hub.db——数据库会话/消息无法迁移。');
  } else {
    const walBytes = await readZipBytes(zip, 'rikka_hub-wal');
    if (walBytes && walBytes.length > 0) {
      walReplayed = true;
    }
    try {
      db = await openRikkaHubDb({ dbName: 'rikka_hub.db', dbBytes, walBytes });
      const master = db.queryOne<{ id: number; identity_hash: string }>(
        'SELECT id FROM room_master_table ORDER BY id LIMIT 1',
      );
      dbVersion = master?.id ?? null;
    } catch (e) {
      report.warnings.push(`rikka_hub.db 打开失败: ${e instanceof Error ? e.message : String(e)}`);
      db = null;
    }
  }

  return { zip, fileName, settings, db, dbVersion, walReplayed };
}

export function closeSource(source: RikkaHubSource): void {
  source.db?.close();
}
