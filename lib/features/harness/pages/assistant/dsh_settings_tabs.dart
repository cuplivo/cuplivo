import 'package:flutter/widgets.dart';

/// One tab of the DeepSeek Harness assistant settings page.
///
/// The page builds the native DSH tabs first and appends the plugin-registered
/// tabs the Host reports, so the strip is data instead of a hardcoded widget
/// list. A tab whose data source is unavailable is simply absent: there is no
/// placeholder tab to keep.
@immutable
class DshSettingsTabSpec {
  const DshSettingsTabSpec({
    required this.id,
    required this.label,
    required this.body,
    this.key,
  });

  /// Stable across rebuilds: `connection`, `general`, `models`, `plugins`,
  /// `agentPresets`, or `plugin:<entryId>`.
  final String id;

  /// Localized label shown in the strip.
  final String label;

  /// Builds the body for this tab.
  final WidgetBuilder body;

  /// Explicit test/E2E key. When null the strip uses
  /// [ValueKey]`('dsh-settings-tab-<id>')`.
  final Key? key;
}

/// Stable ASCII slug for a plugin-contributed settings section.
///
/// DSH exposes no id for `settings.section` slots — only the label the official
/// UI renders — so the tab id is derived from that label. A label with no ASCII
/// letters/digits (e.g. a CJK-only label) cannot be slugged; [ordinal] keeps the
/// fallback stable for as long as the Host keeps the section order.
String dshSettingsSectionSlug(String label, {required int ordinal}) {
  final slug = label
      .toLowerCase()
      .replaceAll(RegExp(r'[^a-z0-9]+'), '-')
      .replaceAll(RegExp(r'^-+|-+$'), '');
  return slug.isEmpty ? 'section-$ordinal' : slug;
}

/// Resolves a plugin-authored `meta.title` for the current UI locale, falling
/// back to [fallback] when the plugin shipped no matching language.
///
/// Plugin metadata is authored by the plugin, not by Cuplivo, so this must not
/// go through the app's ARB resources. The read-only 内置插件 and Agent 预设 rows
/// use it for their labels.
String dshSettingsLocalizedPluginTitle(
  BuildContext context, {
  required Map<String, String> titles,
  required String fallback,
}) {
  if (titles.isEmpty) return fallback.trim();
  final locale = Localizations.localeOf(context);
  final tag = locale.toLanguageTag();
  final candidates = <String>[
    tag,
    tag.replaceAll('-', '_'),
    locale.languageCode,
  ];
  for (final candidate in candidates) {
    final value = titles[candidate];
    if (value != null && value.trim().isNotEmpty) return value.trim();
  }
  final english = titles['en'];
  if (english != null && english.trim().isNotEmpty) return english.trim();
  for (final value in titles.values) {
    if (value.trim().isNotEmpty) return value.trim();
  }
  return fallback.trim();
}
