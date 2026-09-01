/** 迁移报告：记录丢弃项、未识别 modelId、占位助手等，供用户留档 */

export interface DroppedItem {
  category: string;
  count: number;
  /** 超出 5 条的明细截断 */
  detail?: string[];
}

export interface PlaceholderAssistantInfo {
  assistantId: string;
  name: string;
  reason: string;
}

export interface MigrationReport {
  generatedAt: string;
  source: {
    fileName: string;
    app: 'rikkahub';
    dbVersion: number | null;
    walReplayed: boolean;
  };
  totals: {
    conversations: number;
    messages: number;
    mediaMessages: number;
    mediaFiles: number;
    toolEvents: number;
    memories: number;
    providers: number;
    assistants: number;
    placeholders: number;
  };
  droppedAlternatives: number;
  dropped: DroppedItem[];
  placeholderAssistants: PlaceholderAssistantInfo[];
  unrecognizedModelIds: string[];
  warnings: string[];
}

export function emptyReport(sourceFileName: string): MigrationReport {
  return {
    generatedAt: new Date().toISOString(),
    source: { fileName: sourceFileName, app: 'rikkahub', dbVersion: null, walReplayed: false },
    totals: {
      conversations: 0,
      messages: 0,
      mediaMessages: 0,
      mediaFiles: 0,
      toolEvents: 0,
      memories: 0,
      providers: 0,
      assistants: 0,
      placeholders: 0,
    },
    droppedAlternatives: 0,
    dropped: [],
    placeholderAssistants: [],
    unrecognizedModelIds: [],
    warnings: [],
  };
}

export function drop(report: MigrationReport, category: string, count: number, detail?: string[]): void {
  if (count <= 0) return;
  report.dropped.push({ category, count, detail: detail && detail.length > 0 ? detail.slice(0, 5) : undefined });
}

/** 迁移报告 → 人类可读文本（留档下载用） */
export function reportToMarkdown(r: MigrationReport): string {
  const lines: string[] = [];
  lines.push('# Kelivo Helper 迁移报告');
  lines.push('');
  lines.push(`- 生成时间: ${r.generatedAt}`);
  lines.push(`- 源文件: ${r.source.fileName}`);
  lines.push(`- 源应用: RikkaHub (数据库版本 ${r.source.dbVersion ?? '未知'}${r.source.walReplayed ? '，WAL 已回放' : ''})`);
  lines.push('');
  lines.push('## 迁移总量');
  lines.push('');
  lines.push(
    `- 会话: ${r.totals.conversations} | 消息: ${r.totals.messages} | 含媒体消息: ${r.totals.mediaMessages} | 工具事件: ${r.totals.toolEvents}`,
  );
  lines.push(
    `- 助手: ${r.totals.assistants}（其中占位 ${r.totals.placeholders}）| 提供商: ${r.totals.providers} | 记忆: ${r.totals.memories} | 媒体文件: ${r.totals.mediaFiles}`,
  );
  lines.push('');
  if (r.droppedAlternatives > 0) {
    lines.push(`- 未选中的 regenerate 版本（已丢弃）: ${r.droppedAlternatives} 条`);
  }
  if (r.unrecognizedModelIds.length > 0) {
    lines.push(`- 未识别 modelId（已置空，显示为默认）: ${r.unrecognizedModelIds.length} 个`);
    lines.push(`  ${r.unrecognizedModelIds.slice(0, 5).join(', ')}`);
  }
  if (r.placeholderAssistants.length > 0) {
    lines.push('');
    lines.push('## 占位助手');
    lines.push('');
    for (const p of r.placeholderAssistants) {
      lines.push(`- ${p.name} (${p.assistantId}) — ${p.reason}`);
    }
  }
  if (r.dropped.length > 0) {
    lines.push('');
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
