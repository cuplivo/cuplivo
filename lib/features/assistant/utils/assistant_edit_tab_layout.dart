import 'dart:io' show Platform;

const String assistantEditTabBasic = 'basic';
const String assistantEditTabPrompts = 'prompts';
const String assistantEditTabMemory = 'memory';
const String assistantEditTabMcp = 'mcp';
const String assistantEditTabLocalTools = 'localTools';
const String assistantEditTabSkills = 'skills';
const String assistantEditTabQuickPhrase = 'quickPhrase';
const String assistantEditTabCustom = 'custom';
const String assistantEditTabRegex = 'regex';

/// Android-only roleplay tab ("角色扮演"): Ta的来信 and future roleplay
/// features live here.
const String assistantEditTabRoleplay = 'roleplay';

const List<String> defaultAssistantEditTabIds = [
  assistantEditTabBasic,
  assistantEditTabPrompts,
  assistantEditTabMemory,
  assistantEditTabLocalTools,
  assistantEditTabSkills,
  assistantEditTabMcp,
  assistantEditTabQuickPhrase,
  assistantEditTabCustom,
  assistantEditTabRegex,
];

/// Default tab order with the roleplay tab included, right after 记忆
/// (memory) and before 本地工具 (local tools).
const List<String> defaultAssistantEditTabIdsWithRoleplay = [
  assistantEditTabBasic,
  assistantEditTabPrompts,
  assistantEditTabMemory,
  assistantEditTabRoleplay,
  assistantEditTabLocalTools,
  assistantEditTabSkills,
  assistantEditTabMcp,
  assistantEditTabQuickPhrase,
  assistantEditTabCustom,
  assistantEditTabRegex,
];

/// The default order to use on this platform: the roleplay tab only exists
/// on Android (it depends on Android letter alarms).
List<String> platformDefaultAssistantEditTabIds() => Platform.isAndroid
    ? defaultAssistantEditTabIdsWithRoleplay
    : defaultAssistantEditTabIds;

List<String> orderAssistantEditTabIds({
  required List<String> savedOrder,
  List<String> defaultOrder = defaultAssistantEditTabIds,
}) {
  final validIds = defaultOrder.toSet();
  final seen = <String>{};
  final result = <String>[];
  for (final id in savedOrder) {
    if (validIds.contains(id) && seen.add(id)) result.add(id);
  }
  for (final id in defaultOrder) {
    if (seen.add(id)) result.add(id);
  }
  return List.unmodifiable(result);
}

List<String> visibleAssistantEditTabIds({
  required List<String> savedOrder,
  required Set<String> hiddenIds,
  List<String> defaultOrder = defaultAssistantEditTabIds,
}) {
  final ordered = orderAssistantEditTabIds(
    savedOrder: savedOrder,
    defaultOrder: defaultOrder,
  );
  final visible = ordered.where((id) => !hiddenIds.contains(id)).toList();
  return List.unmodifiable(visible.isNotEmpty ? visible : [ordered.first]);
}

int visualAssistantEditTabIndex({
  required double animationValue,
  required int tabCount,
}) {
  if (tabCount <= 0) return 0;
  return animationValue.round().clamp(0, tabCount - 1);
}
