/**
 * settings.json 转换：近逐字直通 + 助手层手术
 *
 * 手术项（源码核实的形态分歧，避免 Cuplivo 静默丢失）：
 * 1. presetMessages：Kelivo v1.2.0 输出为 JSON 字符串，Cuplivo PresetMessage.decodeList
 *    只接受数组（字符串 → 返回 []，预设消息全丢）→ 解码重排为内联数组
 * 2. allowPastConversationRecall → enableRecentChatsReference：Kelivo 新字段名，
 *    Cuplivo 只认旧名 → 合成旧键；新键保留（保真）
 * 3. Kelivo 独有字段（autoOrganizeMemory 等）Cuplivo 忽略未知键，原样保留
 */
import { drop, type CompatReport } from '../compat/report';

export function transformAssistantsV1(raw: unknown, report: CompatReport): string | null {
  if (typeof raw !== 'string' || raw.length === 0) return null;
  let list: unknown;
  try {
    list = JSON.parse(raw);
  } catch {
    report.warnings.push('assistants_v1 不是合法 JSON 字符串，助手层原样保留。');
    return raw;
  }
  if (!Array.isArray(list)) {
    report.warnings.push('assistants_v1 不是数组，助手层原样保留。');
    return raw;
  }

  let presetFixed = 0;
  let presetUnparsable = 0;
  let recallMapped = 0;

  const out = list.map((a) => {
    if (typeof a !== 'object' || a === null) return a;
    const rec = { ...(a as Record<string, unknown>) };

    // 1. presetMessages 字符串 → 内联数组
    const pm = rec.presetMessages;
    if (typeof pm === 'string') {
      try {
        const parsed: unknown = JSON.parse(pm);
        if (Array.isArray(parsed)) {
          rec.presetMessages = parsed;
          presetFixed++;
        } else {
          presetUnparsable++;
        }
      } catch {
        presetUnparsable++;
      }
    }

    // 2. 合成旧键 enableRecentChatsReference
    if (
      typeof rec.allowPastConversationRecall === 'boolean' &&
      rec.enableRecentChatsReference === undefined
    ) {
      rec.enableRecentChatsReference = rec.allowPastConversationRecall;
      recallMapped++;
    }

    return rec;
  });

  report.totals.assistants = out.length;
  if (presetUnparsable > 0) {
    drop(report, 'presetMessages 无法解析（保持原样，Cuplivo 将忽略）', presetUnparsable);
  }
  if (presetFixed > 0 || recallMapped > 0) {
    report.warnings.push(
      `助手层手术：${presetFixed} 个 presetMessages 字符串已重排为数组，${recallMapped} 个 allowPastConversationRecall 已合成 enableRecentChatsReference。`,
    );
  }
  return JSON.stringify(out);
}

/** 近逐字直通：除 assistants_v1 手术外，其余键全部保留 */
export function transformSettings(
  sourceSettings: Record<string, unknown>,
  report: CompatReport,
): Record<string, unknown> {
  const out = { ...sourceSettings };
  const assistants = out.assistants_v1;
  if (assistants !== undefined) {
    const transformed = transformAssistantsV1(assistants, report);
    if (transformed !== null) out.assistants_v1 = transformed;
  }
  return out;
}
