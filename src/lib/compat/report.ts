/** 兼容报告：Kelivo v1.2.0 → Cuplivo v2.7.1 转换的留档清单，同构于迁移报告 */
import type { DroppedItem } from '../report';

export interface CompatReport {
  generatedAt: string;
  source: {
    fileName: string;
    format: string;
    formatVersion: number;
    payloadKind: string;
    appVersion: string | null;
  };
  totals: {
    conversations: number;
    messages: number;
    mediaFiles: number;
    toolEvents: number;
    assistants: number;
    geminiSignatures: number;
  };
  dropped: DroppedItem[];
  warnings: string[];
}

export function emptyCompatReport(sourceFileName: string): CompatReport {
  return {
    generatedAt: new Date().toISOString(),
    source: {
      fileName: sourceFileName,
      format: 'kelivo-backup',
      formatVersion: 2,
      payloadKind: 'sqlite',
      appVersion: null,
    },
    totals: {
      conversations: 0,
      messages: 0,
      mediaFiles: 0,
      toolEvents: 0,
      assistants: 0,
      geminiSignatures: 0,
    },
    dropped: [],
    warnings: [],
  };
}

export function drop(report: CompatReport, category: string, count: number, detail?: string[]): void {
  if (count <= 0) return;
  report.dropped.push({ category, count, detail: detail && detail.length > 0 ? detail.slice(0, 5) : undefined });
}

/** 兼容报告 → 人类可读文本（留档下载用） */
export function compatReportToMarkdown(r: CompatReport): string {
  const lines: string[] = [];
  lines.push('# Kelivo Helper 兼容报告');
  lines.push('');
  lines.push(`- 生成时间: ${r.generatedAt}`);
  lines.push(`- 源文件: ${r.source.fileName}`);
  lines.push(`- 源格式: ${r.source.format} (formatVersion ${r.source.formatVersion})${r.source.appVersion ? `，应用版本 ${r.source.appVersion}` : ''}`);
  lines.push(`- 载荷: ${r.source.payloadKind === 'sqlite' ? 'SQLite 快照（会话+消息）' : '仅设置'}`);
  lines.push('');
  lines.push('## 转换总量');
  lines.push('');
  lines.push(
    `- 会话: ${r.totals.conversations} | 消息: ${r.totals.messages} | 工具事件: ${r.totals.toolEvents} | 助手: ${r.totals.assistants} | 媒体文件: ${r.totals.mediaFiles}`,
  );
  lines.push('');
  if (r.dropped.length > 0) {
    lines.push('## 丢弃项');
    lines.push('');
    for (const d of r.dropped) {
      lines.push(`- ${d.category}: ${d.count}`);
      if (d.detail) {
        for (const x of d.detail) lines.push(`  - ${x}`);
      }
    }
  }
  if (r.warnings.length > 0) {
    lines.push('');
    lines.push('## 警告');
    lines.push('');
    for (const w of r.warnings) lines.push(`- ${w}`);
  }
  lines.push('');
  lines.push('> 数据全程在浏览器本地处理，未上传任何内容。');
  return lines.join('\n');
}
