/** kelivo.db 表查询 + 时间转换（drift 存 epoch 微秒，输出 ISO 8601 带 6 位小数） */
import type {
  AssetRow,
  ConversationMcpRow,
  ConversationRow,
  MessageAssetRow,
  MessagePartRow,
  MessageRow,
  ProviderArtifactRow,
} from './types';
import type { KelivoDb } from './db';

/** epoch 微秒 → 'YYYY-MM-DDTHH:mm:ss.ffffffZ'（UTC，保真瞬时） */
export function microsToIso(micros: number): string {
  const ms = Math.floor(micros / 1000);
  const microPart = ((micros % 1000) + 1000) % 1000;
  const base = new Date(ms).toISOString().replace(/\.\d{3}Z$/, '');
  const msPart = ((ms % 1000) + 1000) % 1000;
  return `${base}.${String(msPart).padStart(3, '0')}${String(microPart).padStart(3, '0')}Z`;
}

export function nullableMicrosToIso(micros: number | null): string | null {
  return micros == null ? null : microsToIso(micros);
}

export function queryConversations(db: KelivoDb): ConversationRow[] {
  return db.queryAll<ConversationRow>(
    'SELECT id, title, created_at, updated_at, is_pinned, assistant_id, truncate_index, ' +
      'version_selections_json, summary, last_summarized_message_count, chat_suggestions_json, ' +
      'injected_memory_hash, last_memory_extracted_order FROM conversation_rows',
  );
}

export function queryConversationMcps(db: KelivoDb): ConversationMcpRow[] {
  return db.queryAll<ConversationMcpRow>(
    'SELECT conversation_id, server_id FROM conversation_mcp_server_rows ORDER BY conversation_id, ordinal',
  );
}

export function queryMessages(db: KelivoDb): MessageRow[] {
  return db.queryAll<MessageRow>(
    'SELECT id, conversation_id, role, timestamp, model_id, provider_id, total_tokens, is_streaming, ' +
      'reasoning_start_at, reasoning_finished_at, translation, reasoning_segments_json, group_id, ' +
      'version, prompt_tokens, completion_tokens, cached_tokens, duration_ms, message_order ' +
      'FROM message_rows ORDER BY conversation_id, message_order',
  );
}

export function queryParts(db: KelivoDb): MessagePartRow[] {
  return db.queryAll<MessagePartRow>(
    'SELECT part_id, conversation_id, revision_id, ordinal, kind, payload ' +
      'FROM message_part_rows ORDER BY revision_id, ordinal',
  );
}

export function queryGeminiSignatures(db: KelivoDb): ProviderArtifactRow[] {
  return db.queryAll<ProviderArtifactRow>(
    "SELECT revision_id, kind, payload FROM provider_artifact_rows WHERE kind = 'gemini_thought_signature'",
  );
}

export function queryAssets(db: KelivoDb): AssetRow[] {
  return db.queryAll<AssetRow>('SELECT id, content_hash, path, byte_size FROM asset_rows');
}

export function queryMessageAssets(db: KelivoDb): MessageAssetRow[] {
  return db.queryAll<MessageAssetRow>(
    'SELECT revision_id, asset_id FROM message_asset_rows ORDER BY revision_id',
  );
}

/** 解析会话 JSON 字符串字段（{}/[] 兜底） */
export function parseJsonOr<T>(raw: string | null, fallback: T): T {
  if (raw == null) return fallback;
  try {
    const parsed = JSON.parse(raw);
    return parsed === undefined || parsed === null ? fallback : (parsed as T);
  } catch {
    return fallback;
  }
}
