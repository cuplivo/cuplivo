/// Tumin-style three presets that apply a coherent set of values to the
/// [Assistant] memory knobs. Picking a preset in the UI calls
/// [applyStrategy]; a custom edit (numeric fields) decouples the assistant
/// from any preset — [detectStrategy] returns `null` in that case so the UI
/// can render a "Custom" indicator.
///
/// Keep the default values in sync with [Assistant]'s constructor so a
/// freshly built assistant reads as the `natural` preset without a manual
/// pick.
library;

import '../models/assistant.dart';

enum MemoryStrategy {
  natural('natural', '自然 · 推荐', '近期经历保留适中，重要旧记忆按需想起。', '中等记忆量 · 中等 Token'),
  saver('saver', '省 Token', '更积极整理旧内容，只保留较少近期细节。', '较少记忆量 · 较低 Token'),
  strong('strong', '记得更多', '保留更多近期细节，也更容易想起过去。', '更多记忆量 · 较高 Token');

  const MemoryStrategy(
    this.id,
    this.label,
    this.description,
    this.cost,
  );

  final String id;
  final String label;
  final String description;
  final String cost;
}

/// Returns the preset matching [a]'s current values, or `null` if the
/// assistant has been edited to a custom combination.
MemoryStrategy? detectStrategy(Assistant a) {
  if (a.crossWindowMemoryCompressionThresholdChars == 8000 &&
      a.crossWindowMemoryTailEntries == 10 &&
      a.longTermMemoryRecallCount == 4 &&
      a.longTermMemoryMaxChars == 1800) {
    return MemoryStrategy.saver;
  }
  if (a.crossWindowMemoryCompressionThresholdChars == 20000 &&
      a.crossWindowMemoryTailEntries == 24 &&
      a.longTermMemoryRecallCount == 10 &&
      a.longTermMemoryMaxChars == 5000) {
    return MemoryStrategy.strong;
  }
  if (a.crossWindowMemoryCompressionThresholdChars == 12000 &&
      a.crossWindowMemoryTailEntries == 16 &&
      a.longTermMemoryRecallCount == 6 &&
      a.longTermMemoryMaxChars == 3000) {
    return MemoryStrategy.natural;
  }
  return null;
}

/// Returns a copy of [a] with the values of [strategy] applied. The
/// three-layer / cross-window / compression flags are also enabled so a
/// preset pick is a one-shot opt-in.
Assistant applyStrategy(Assistant a, MemoryStrategy strategy) {
  switch (strategy) {
    case MemoryStrategy.natural:
      return a.copyWith(
        enableThreeLayerMemory: true,
        enableCrossWindowMemory: true,
        enableCrossWindowMemoryCompression: true,
        crossWindowMemoryCompressionThresholdChars: 12000,
        crossWindowMemoryTailEntries: 16,
        longTermMemoryRecallCount: 6,
        longTermMemoryMaxChars: 3000,
      );
    case MemoryStrategy.saver:
      return a.copyWith(
        enableThreeLayerMemory: true,
        enableCrossWindowMemory: true,
        enableCrossWindowMemoryCompression: true,
        crossWindowMemoryCompressionThresholdChars: 8000,
        crossWindowMemoryTailEntries: 10,
        longTermMemoryRecallCount: 4,
        longTermMemoryMaxChars: 1800,
      );
    case MemoryStrategy.strong:
      return a.copyWith(
        enableThreeLayerMemory: true,
        enableCrossWindowMemory: true,
        enableCrossWindowMemoryCompression: true,
        crossWindowMemoryCompressionThresholdChars: 20000,
        crossWindowMemoryTailEntries: 24,
        longTermMemoryRecallCount: 10,
        longTermMemoryMaxChars: 5000,
      );
  }
}
