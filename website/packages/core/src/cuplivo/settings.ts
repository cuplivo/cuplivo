/**
 * settings.json 转换：近逐字直通 + 助手层手术
 *
 * 手术项（源码核实的形态分歧，避免 Cuplivo 静默丢失）：
 * 1. presetMessages：Kelivo v1.2.0 输出为 JSON 字符串，Cuplivo PresetMessage.decodeList
 *    只接受数组（字符串 → 返回 []，预设消息全丢）→ 解码重排为内联数组
 * 2. allowPastConversationRecall → enableRecentChatsReference：Kelivo 新字段名，
 *    Cuplivo 只认旧名 → 合成旧键；新键保留（保真）
 * 3. 记忆降级：memory_entries_v1（新版 MemoryEntry）→ assistant_memories_v1（旧版），
 *    Cuplivo v2.7.1 只读旧键（issue cuplivo/cuplivo#543）→ transformMemories
 * 4. 搜索服务：apiKeys 字符串池 → ApiKeyConfig 列表（Cuplivo readKeys 强转 Map，
 *    Kelivo List<String> 直通会让搜索配置加载崩溃）→ transformSearchServicesV1
 * 5. Kelivo 独有字段（autoOrganizeMemory 等）Cuplivo 忽略未知键，原样保留
 */
import { drop, type CompatReport } from '../compat/report';
import { transformMemories } from '../compat/memory';

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

/**
 * 搜索服务手术：Kelivo 把附加密钥池序列化为 `apiKeys: List<String>`
 * （仅 extraApiKeys 非空时输出），Cuplivo SearchServiceOptions.readKeys
 * 却把 apiKeys 强制映射为 List<ApiKeyConfig>（`e as Map` → 字符串强转，
 * 恢复后搜索配置加载崩溃）——直通即损坏。转换：主 key 优先入池，
 * 字符串 → `{key}` 对象，其余字段 Cuplivo fromJson 自补默认值。
 */
export function transformSearchServicesV1(
  sourceSettings: Record<string, unknown>,
  report: CompatReport,
): Record<string, unknown> {
  const out = { ...sourceSettings };
  const blob = out.search_services_v1;
  if (typeof blob !== 'string' || blob.length === 0) return out;

  let list: unknown;
  try {
    list = JSON.parse(blob);
  } catch {
    report.warnings.push('search_services_v1 不是合法 JSON 字符串，搜索配置原样保留。');
    return out;
  }
  if (!Array.isArray(list)) return out;

  let fixed = 0;
  let mixed = 0;
  const outList = list.map((entry) => {
    if (typeof entry !== 'object' || entry === null) return entry;
    const rec = { ...(entry as Record<string, unknown>) };
    const apiKeys = rec.apiKeys;
    if (!Array.isArray(apiKeys) || apiKeys.length === 0) return rec;
    if (!apiKeys.every((k) => typeof k === 'string')) {
      mixed++;
      return rec;
    }
    const primary = rec.apiKey;
    const pool: string[] =
      typeof primary === 'string' && primary.length > 0
        ? [primary, ...(apiKeys as string[])]
        : (apiKeys as string[]);
    rec.apiKeys = pool.map((key) => ({ key }));
    fixed++;
    return rec;
  });

  if (fixed > 0) {
    out.search_services_v1 = JSON.stringify(outList);
    report.warnings.push(`搜索服务手术：${fixed} 个服务的 apiKeys 字符串池已转为 ApiKeyConfig 列表（Cuplivo 读取时补默认字段）。`);
  }
  if (mixed > 0) drop(report, '搜索服务：apiKeys 含非字符串元素（保持原样）', mixed);
  return out;
}

/** 近逐字直通：除 assistants_v1 手术、记忆降级与搜索手术外，其余键全部保留 */
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
  let result = transformMemories(out, report);
  result = transformSearchServicesV1(result, report);
  return result;
}
