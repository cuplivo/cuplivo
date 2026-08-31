/**
 * Kelivo v1.2.0 备份包类型定义（manifest.json + database/kelivo.db 快照格式）
 * 调研来源：Chevey339/kelivo tag v1.2.0（lib/core/services/backup/data_sync.dart）
 * 注意：表行类型按 sqlite-wasm rowMode=object 的**实际列名（snake_case）**定义
 */

/** manifest.json */
export interface KelivoManifest {
  format: string;
  formatVersion: number;
  payloadKind: 'sqlite' | 'settings-only';
  createdAtUtc: string;
  appVersion: string;
  includeChats: boolean;
  includeFiles: boolean;
  secretsIncluded: boolean;
  businessEntityRowIds?: Record<string, string[]>;
  database?: {
    entry: string;
    schemaVersion: number;
    conversationCount: number;
    messageCount: number;
  };
  entries: Record<string, { bytes: number; sha256: string }>;
}

/** conversation_rows 表行 */
export interface ConversationRow {
  id: string;
  title: string;
  /** epoch 微秒 */
  created_at: number;
  /** epoch 微秒 */
  updated_at: number;
  is_pinned: number;
  assistant_id: string | null;
  truncate_index: number;
  version_selections_json: string;
  summary: string | null;
  last_summarized_message_count: number;
  chat_suggestions_json: string;
  injected_memory_hash: string | null;
  last_memory_extracted_order: number;
}

/** conversation_mcp_server_rows 表行 */
export interface ConversationMcpRow {
  conversation_id: string;
  server_id: string;
}

/** message_rows 表行 */
export interface MessageRow {
  id: string;
  conversation_id: string;
  role: 'user' | 'assistant';
  /** epoch 微秒 */
  timestamp: number;
  model_id: string | null;
  provider_id: string | null;
  total_tokens: number | null;
  is_streaming: number;
  /** epoch 微秒 */
  reasoning_start_at: number | null;
  /** epoch 微秒 */
  reasoning_finished_at: number | null;
  translation: string | null;
  reasoning_segments_json: string | null;
  group_id: string | null;
  version: number;
  prompt_tokens: number | null;
  completion_tokens: number | null;
  cached_tokens: number | null;
  duration_ms: number | null;
  message_order: number;
}

/** message_part_rows 表行 */
export interface MessagePartRow {
  part_id: number;
  conversation_id: string;
  revision_id: string;
  ordinal: number;
  kind: string;
  payload: string;
}

/** provider_artifact_rows 表行（仅 gemini_thought_signature 关注） */
export interface ProviderArtifactRow {
  revision_id: string;
  kind: string;
  payload: string;
}

/** asset_rows 表行（媒体库去重路径） */
export interface AssetRow {
  id: string;
  content_hash: string;
  path: string;
  byte_size: number;
}

/** message_asset_rows 表行（消息 → 媒体库引用） */
export interface MessageAssetRow {
  revision_id: string;
  asset_id: string;
}
