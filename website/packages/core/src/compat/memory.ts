/**
 * 记忆降级：Kelivo v1.2.0 新版记忆（memory_entries_v1）→ Cuplivo v2.7.1 旧版格式（assistant_memories_v1）
 *
 * 依据（源码核实）：
 * - Kelivo v1.2.0 为双代记忆：新 MemoryEntry（scope/type/status/content/source/migrationIds，
 *   settings.json blob memory_entries_v1，SQLite memory_entry_rows），旧 AssistantMemory
 *   （{id, assistantId, content}，assistant_memories_v1 / assistant_memory_rows）
 * - Cuplivo v2.7.1 只读旧键 assistant_memories_v1，对新键无任何引用 → 直通 = 静默丢失
 *
 * 转换规则（issue cuplivo/cuplivo#543，用户裁定）：
 * - scope=assistant 直转；scope=global 复制到所有助手（assistants_v1 的 id 列表）
 * - status=archived 无旧版对应 → 丢弃 + 报告
 * - 精确去重：新条目的 migrationIds（应用内 legacy 迁移留下的原旧 id）取代旧记录；
 *   (assistantId, normalize(content)) 兜底，与 Kelivo 归一化同构
 * - 旧 id 原样保留，新 id 从旧 id max+1 递增；转换后移除 memory_entries_v1
 */
import type { AssistantMemory, MemoryEntry } from '../kelivo/types';
import { drop, type CompatReport } from './report';

/** 载荷字段松散视图（备份解析允许缺字段，逐项校验） */
type MemoryEntryV1 = Partial<MemoryEntry>;

/** 与 Kelivo MemoryEntry.normalizeContent 同构：trim + 空白折叠 + 小写 */
function normalizeContent(content: string): string {
  return content.trim().replace(/\s+/g, ' ').toLowerCase();
}

function parseJsonArray(value: unknown): unknown[] | null {
  if (typeof value !== 'string' || value.length === 0) return null;
  try {
    const parsed: unknown = JSON.parse(value);
    return Array.isArray(parsed) ? parsed : null;
  } catch {
    return null;
  }
}

function assistantIdsOf(blob: unknown): string[] {
  const list = parseJsonArray(blob);
  if (!list) return [];
  const ids: string[] = [];
  for (const a of list) {
    if (typeof a !== 'object' || a === null) continue;
    const id = (a as Record<string, unknown>).id;
    if (typeof id === 'string') ids.push(id);
  }
  return ids;
}

function isLegacyRecord(r: unknown): r is AssistantMemory {
  if (typeof r !== 'object' || r === null) return false;
  const rec = r as Record<string, unknown>;
  return typeof rec.id === 'number' && typeof rec.assistantId === 'string' && typeof rec.content === 'string';
}

export function transformMemories(
  sourceSettings: Record<string, unknown>,
  report: CompatReport,
): Record<string, unknown> {
  const out = { ...sourceSettings };
  const newBlob = out.memory_entries_v1;
  if (newBlob === undefined) return out;

  // 转换后移除新键：Cuplivo 不使用且恢复时写入无用 prefs
  delete out.memory_entries_v1;

  const entries = parseJsonArray(newBlob);
  if (entries === null) {
    if (typeof newBlob === 'string') {
      report.warnings.push('memory_entries_v1 不是合法 JSON 字符串，新版记忆未转换（键已移除）。');
    }
    return out;
  }

  // 旧版记忆（打开合并）
  const legacy: AssistantMemory[] = [];
  let legacyInvalid = 0;
  const legacyParsed = parseJsonArray(out.assistant_memories_v1);
  if (legacyParsed !== null) {
    for (const r of legacyParsed) {
      if (isLegacyRecord(r)) legacy.push(r);
      else legacyInvalid++;
    }
  } else if (typeof out.assistant_memories_v1 === 'string') {
    report.warnings.push('assistant_memories_v1 不是合法 JSON，按空列表处理。');
  }

  // 新条目：确定性排序（createdAt 升序，其次 id），校验字段
  let malformed = 0;
  const processed: MemoryEntryV1[] = [];
  for (const e of entries) {
    if (typeof e === 'object' && e !== null) processed.push(e as MemoryEntryV1);
    else malformed++;
  }
  processed.sort(
    (a, b) => (a.createdAt ?? 0) - (b.createdAt ?? 0) || String(a.id ?? '').localeCompare(String(b.id ?? '')),
  );

  const assistantIds = assistantIdsOf(out.assistants_v1);
  const superseded = new Set<number>();
  const seenKeys = new Set<string>();
  const newRecords: { assistantId: string; content: string }[] = [];
  let archived = 0;
  let globalNoAssistants = 0;
  let globalCopies = 0;

  for (const e of processed) {
    if (e.status === 'archived') {
      archived++;
      continue;
    }
    if (e.status !== undefined && e.status !== 'active') {
      malformed++;
      continue;
    }
    if (typeof e.content !== 'string' || e.content.length === 0) {
      malformed++;
      continue;
    }
    if (Array.isArray(e.migrationIds)) {
      for (const id of e.migrationIds) if (typeof id === 'number') superseded.add(id);
    }

    const addFor = (assistantId: string): boolean => {
      const key = `${assistantId}\n${normalizeContent(e.content!)}`;
      if (seenKeys.has(key)) return false;
      seenKeys.add(key);
      newRecords.push({ assistantId, content: e.content! });
      return true;
    };

    if (e.scope === 'assistant') {
      if (typeof e.assistantId === 'string') addFor(e.assistantId);
      else malformed++;
    } else if (e.scope === 'global') {
      if (assistantIds.length === 0) {
        globalNoAssistants++;
      } else {
        for (const aid of assistantIds) if (addFor(aid)) globalCopies++;
      }
    } else {
      malformed++;
    }
  }

  // 旧记录合并：migrationIds 精确取代 + 内容兜底去重（不动旧记录间的重复）
  const legacyKept: AssistantMemory[] = [];
  let supersededDropped = 0;
  let contentDupDropped = 0;
  for (const r of legacy) {
    if (superseded.has(r.id)) {
      supersededDropped++;
      continue;
    }
    if (seenKeys.has(`${r.assistantId}\n${normalizeContent(r.content)}`)) {
      contentDupDropped++;
      continue;
    }
    legacyKept.push(r);
  }

  let nextId = legacy.reduce((m, r) => Math.max(m, r.id), 0) + 1;
  const converted: AssistantMemory[] = newRecords.map((r) => ({
    id: nextId++,
    assistantId: r.assistantId,
    content: r.content,
  }));
  const finalList = [...converted, ...legacyKept];

  if (finalList.length > 0) out.assistant_memories_v1 = JSON.stringify(finalList);
  else delete out.assistant_memories_v1;

  report.totals.memories = finalList.length;
  if (archived > 0) drop(report, '记忆：archived（旧版格式无此状态）', archived);
  if (globalNoAssistants > 0) drop(report, '记忆：global 但 assistants_v1 缺失/不可解析', globalNoAssistants);
  if (malformed > 0) drop(report, '记忆：非法条目（scope/status/assistantId/content 不完整）', malformed);
  if (legacyInvalid > 0) drop(report, '记忆：非法旧版记录', legacyInvalid);
  if (converted.length > 0) {
    report.warnings.push(
      `记忆转换：${processed.length} 个新版记忆 → ${converted.length} 条旧版记录` +
        (globalCopies > 0 ? `（global 复制 ${globalCopies} 份）` : '') +
        `；取代旧记录 ${supersededDropped} 条，内容去重 ${contentDupDropped} 条。`,
    );
  }
  return out;
}
