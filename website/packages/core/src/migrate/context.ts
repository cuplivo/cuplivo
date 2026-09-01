/** 迁移上下文：跨模块共享的索引与状态 */
import type { Assistant as KelivoAssistant } from '../kelivo/types';
import type { Settings } from '../rikkahub/types';
import type { MigrationReport } from '../report';
import type { RikkaHubSource } from '../rikkahub/load';

export interface ModelResolution {
  providerKey: string;
  modelId: string;
}

export interface MigrateContext {
  source: RikkaHubSource;
  settings: Settings;
  report: MigrationReport;
  /** Model UUID → (providerKey, modelId) */
  modelById: Map<string, ModelResolution>;
  /** Provider UUID → providerKey（即 Kelivo provider_configs_v1 的键） */
  providerKeyById: Map<string, string>;
  /** assistantId → 迁移后的 Kelivo 助手（含占位） */
  kelivoAssistants: Map<string, KelivoAssistant>;
  /** assistantId → 第一个 tag id */
  tagMap: Map<string, string>;
  /** 占位助手计数 */
  placeholderCount: number;
  /**
   * 额外媒体拷贝：输出 zip 路径 → 源 zip 路径
   * （头像 → avatars/、背景 → images/，源多在 upload/）
   */
  extraAssetCopies: Map<string, string>;
}
