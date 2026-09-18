import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, TargetPlatform;
import '../../../icons/lucide_adapter.dart';
import '../../../l10n/app_localizations.dart';
import '../../../shared/widgets/ios_tactile.dart';
import '../../../core/services/haptics.dart';
import '../../../desktop/desktop_context_menu.dart';
import '../../../desktop/menu_anchor.dart';
import 'package:Cuplivo/theme/app_font_weights.dart';
import 'package:Cuplivo/theme/app_semantic_colors.dart';
import '../../../shared/widgets/section_card.dart';
import 'package:provider/provider.dart';
import 'package:Cuplivo/core/providers/settings_provider.dart';
import 'package:Cuplivo/shared/widgets/snackbar.dart';

class LanguageOption {
  final String code;
  final String displayName;
  final String displayNameZh;
  final String flag;

  const LanguageOption({
    required this.code,
    required this.displayName,
    required this.displayNameZh,
    required this.flag,
  });
}

const List<LanguageOption> supportedLanguages = [
  LanguageOption(
    code: 'zh-CN',
    displayName: 'Simplified Chinese',
    displayNameZh: '简体中文',
    flag: '🇨🇳',
  ),
  LanguageOption(
    code: 'en',
    displayName: 'English',
    displayNameZh: 'English',
    flag: '🇺🇸',
  ),
  LanguageOption(
    code: 'zh-TW',
    displayName: 'Traditional Chinese',
    displayNameZh: '繁體中文',
    flag: '🇨🇳',
  ),
  LanguageOption(
    code: 'ja',
    displayName: 'Japanese',
    displayNameZh: '日本語',
    flag: '🇯🇵',
  ),
  LanguageOption(
    code: 'ko',
    displayName: 'Korean',
    displayNameZh: '한국어',
    flag: '🇰🇷',
  ),
  LanguageOption(
    code: 'fr',
    displayName: 'French',
    displayNameZh: 'Français',
    flag: '🇫🇷',
  ),
  LanguageOption(
    code: 'de',
    displayName: 'German',
    displayNameZh: 'Deutsch',
    flag: '🇩🇪',
  ),
  LanguageOption(
    code: 'it',
    displayName: 'Italian',
    displayNameZh: 'Italiano',
    flag: '🇮🇹',
  ),
  LanguageOption(
    code: 'es',
    displayName: 'Spanish',
    displayNameZh: 'Español',
    flag: '🇪🇸',
  ),
  // LanguageOption(code: 'pt', displayName: 'Portuguese', displayNameZh: 'Português', flag: '🇵🇹'),
  // LanguageOption(code: 'ru', displayName: 'Russian', displayNameZh: 'Русский', flag: '🇷🇺'),
  // LanguageOption(code: 'ar', displayName: 'Arabic', displayNameZh: 'العربية', flag: '🇸🇦'),
  // LanguageOption(code: 'hi', displayName: 'Hindi', displayNameZh: 'हिन्दी', flag: '🇮🇳'),
  // LanguageOption(code: 'th', displayName: 'Thai', displayNameZh: 'ไทย', flag: '🇹🇭'),
  // LanguageOption(code: 'vi', displayName: 'Vietnamese', displayNameZh: 'Tiếng Việt', flag: '🇻🇳'),
];

String _displayNameFor(AppLocalizations l10n, String languageCode) {
  switch (languageCode) {
    case 'zh-CN':
      return l10n.languageDisplaySimplifiedChinese;
    case 'en':
      return l10n.languageDisplayEnglish;
    case 'zh-TW':
      return l10n.languageDisplayTraditionalChinese;
    case 'ja':
      return l10n.languageDisplayJapanese;
    case 'ko':
      return l10n.languageDisplayKorean;
    case 'fr':
      return l10n.languageDisplayFrench;
    case 'de':
      return l10n.languageDisplayGerman;
    case 'it':
      return l10n.languageDisplayItalian;
    case 'es':
      return l10n.languageDisplaySpanish;
    default:
      return languageCode;
  }
}

Future<LanguageOption?> showLanguageSelector(BuildContext context) async {
  final isDesktop =
      defaultTargetPlatform == TargetPlatform.macOS ||
      defaultTargetPlatform == TargetPlatform.windows ||
      defaultTargetPlatform == TargetPlatform.linux;
  if (!isDesktop) {
    return showModalBottomSheet<LanguageOption>(
      context: context,
      isScrollControlled: true,
      backgroundColor: context.overlaySurface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => const _LanguageSelectSheet(),
    );
  }

  // Desktop anchored menu
  final l10n = AppLocalizations.of(context)!;
  final visible = visibleTranslateLanguages(
    context.read<SettingsProvider>().translateVisibleLanguages,
  );
  LanguageOption? selected;
  final items = [
    ...visible.map(
      (lang) => DesktopContextMenuItem(
        icon: null,
        label: '${lang.flag} ${_displayNameFor(l10n, lang.code)}',
        onTap: () => selected = lang,
      ),
    ),
    DesktopContextMenuItem(
      icon: Lucide.Settings2,
      label: l10n.translateLanguageManagerTitle,
      onTap: () async {
        await showTranslateLanguageManager(context);
      },
    ),
    DesktopContextMenuItem(
      icon: Lucide.X,
      label: l10n.languageSelectSheetClearButton,
      onTap: () => selected = const LanguageOption(
        code: '__clear__',
        displayName: 'Clear Translation',
        displayNameZh: '清空翻译',
        flag: '',
      ),
      danger: true,
    ),
  ];
  await showDesktopContextMenuAt(
    context,
    globalPosition: DesktopMenuAnchor.positionOrCenter(context),
    items: items,
  );
  return selected;
}

class _LanguageSelectSheet extends StatefulWidget {
  const _LanguageSelectSheet();

  @override
  State<_LanguageSelectSheet> createState() => _LanguageSelectSheetState();
}

class _LanguageSelectSheetState extends State<_LanguageSelectSheet> {
  // Auto height with a max constraint; no draggable sheet.

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;

    final maxHeight = MediaQuery.of(context).size.height * 0.8;
    return SafeArea(
      top: false,
      child: AnimatedPadding(
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOutCubic,
        padding: EdgeInsets.only(
          bottom: MediaQuery.of(context).viewInsets.bottom,
        ),
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: maxHeight),
          child: SingleChildScrollView(
            physics: const BouncingScrollPhysics(),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Header with drag indicator (reduced spacing)
                Padding(
                  padding: const EdgeInsets.only(top: 6, bottom: 6),
                  child: Container(
                    width: 40,
                    height: 4,
                    decoration: BoxDecoration(
                      color: cs.onSurface.withValues(alpha: 0.2),
                      borderRadius: BorderRadius.circular(999),
                    ),
                  ),
                ),
                // No title per iOS style; keep content close to handle
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      ...visibleTranslateLanguages(
                        context
                            .read<SettingsProvider>()
                            .translateVisibleLanguages,
                      ).map((lang) => _languageOption(context, lang)),
                      SizedBox(
                        height: 44,
                        child: IosCardPress(
                          borderRadius: BorderRadius.circular(14),
                          baseColor: sheetTileColor(context),
                          duration: const Duration(milliseconds: 260),
                          onTap: () async {
                            Haptics.light();
                            await showTranslateLanguageManager(context);
                          },
                          padding: const EdgeInsets.symmetric(horizontal: 12),
                          child: Row(
                            children: [
                              Icon(
                                Lucide.Settings2,
                                size: 18,
                                color: cs.primary,
                              ),
                              const SizedBox(width: 10),
                              Expanded(
                                child: Text(
                                  AppLocalizations.of(
                                    context,
                                  )!.translateLanguageManagerTitle,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(height: 8),
                      // Clear translation row (iOS style)
                      SizedBox(
                        height: 48,
                        child: IosCardPress(
                          borderRadius: BorderRadius.circular(14),
                          baseColor: sheetTileColor(context),
                          duration: const Duration(milliseconds: 260),
                          onTap: () {
                            Haptics.light();
                            Navigator.of(context).pop(
                              const LanguageOption(
                                code: '__clear__',
                                displayName: 'Clear Translation',
                                displayNameZh: '清空翻译',
                                flag: '',
                              ),
                            );
                          },
                          padding: const EdgeInsets.symmetric(horizontal: 12),
                          child: Row(
                            children: [
                              Icon(
                                Lucide.X,
                                size: 20,
                                color: Theme.of(context).colorScheme.error,
                              ),
                              const SizedBox(width: 10),
                              Text(
                                l10n.languageSelectSheetClearButton,
                                style: TextStyle(
                                  fontSize: 15,
                                  fontWeight: AppFontWeights.medium,
                                  color: Theme.of(context).colorScheme.error,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(height: 8),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _languageOption(BuildContext context, LanguageOption lang) {
    final l10n = AppLocalizations.of(context)!;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: SizedBox(
        height: 48,
        child: IosCardPress(
          borderRadius: BorderRadius.circular(14),
          baseColor: sheetTileColor(context),
          duration: const Duration(milliseconds: 260),
          onTap: () {
            Haptics.light();
            Navigator.of(context).pop(lang);
          },
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Row(
            children: [
              // Flag only
              Text(lang.flag, style: const TextStyle(fontSize: 20)),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  _getLanguageDisplayName(l10n, lang.code),
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: AppFontWeights.medium,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  String _getLanguageDisplayName(AppLocalizations l10n, String languageCode) {
    switch (languageCode) {
      case 'zh-CN':
        return l10n.languageDisplaySimplifiedChinese;
      case 'en':
        return l10n.languageDisplayEnglish;
      case 'zh-TW':
        return l10n.languageDisplayTraditionalChinese;
      case 'ja':
        return l10n.languageDisplayJapanese;
      case 'ko':
        return l10n.languageDisplayKorean;
      case 'fr':
        return l10n.languageDisplayFrench;
      case 'de':
        return l10n.languageDisplayGerman;
      case 'it':
        return l10n.languageDisplayItalian;
      case 'es':
        return l10n.languageDisplaySpanish;
      default:
        return languageCode;
    }
  }
}

/// Catalog entries whose codes are in [visibleCodes], in catalog order.
/// Guaranteed non-empty: falls back to the default visible set.
List<LanguageOption> visibleTranslateLanguages(Set<String> visibleCodes) {
  final filtered = supportedLanguages
      .where((l) => visibleCodes.contains(l.code))
      .toList(growable: false);
  if (filtered.isNotEmpty) return filtered;
  return supportedLanguages
      .where(
        (l) =>
            SettingsProvider.defaultTranslateVisibleLanguages.contains(l.code),
      )
      .toList(growable: false);
}

/// The target language that stays valid after [visibleCodes] changes: the
/// current one when still visible, otherwise the first visible (catalog
/// order).
String? effectiveTranslateTarget(Set<String> visibleCodes, String? current) {
  if (current == null || visibleCodes.contains(current)) return current;
  return visibleTranslateLanguages(visibleCodes).first.code;
}

/// Manage-languages dialog: checkbox list of the full catalog; unchecked
/// codes leave the translate target selector. Dialog — desktop safe.
Future<void> showTranslateLanguageManager(BuildContext context) async {
  final settings = context.read<SettingsProvider>();
  final l10n = AppLocalizations.of(context)!;
  var visible = Set<String>.of(settings.translateVisibleLanguages);
  final changed = await showDialog<bool>(
    context: context,
    builder: (dctx) => StatefulBuilder(
      builder: (dctx, setDState) {
        final cs = Theme.of(dctx).colorScheme;
        return AlertDialog(
          title: Text(l10n.translateLanguageManagerTitle),
          content: SizedBox(
            width: 420,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Text(
                      l10n.translateLanguageManagerSubtitle,
                      style: TextStyle(
                        fontSize: 12,
                        color: cs.onSurfaceVariant,
                      ),
                    ),
                  ),
                  for (final lang in supportedLanguages)
                    CheckboxListTile(
                      value: visible.contains(lang.code),
                      title: Text(
                        '${lang.flag} ${_displayNameFor(l10n, lang.code)}',
                      ),
                      dense: true,
                      onChanged: (checked) {
                        // Keep at least one language visible.
                        if (checked != true && visible.length <= 1) {
                          showAppSnackBar(
                            dctx,
                            message: l10n.translateLanguageManagerAtLeastOne,
                            type: NotificationType.warning,
                          );
                          return;
                        }
                        setDState(() {
                          checked == true
                              ? visible.add(lang.code)
                              : visible.remove(lang.code);
                        });
                      },
                    ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dctx).pop(false),
              child: Text(MaterialLocalizations.of(dctx).cancelButtonLabel),
            ),
            FilledButton(
              onPressed: () => Navigator.of(dctx).pop(true),
              child: Text(MaterialLocalizations.of(dctx).okButtonLabel),
            ),
          ],
        );
      },
    ),
  );
  if (changed == true) {
    await settings.setTranslateVisibleLanguages(visible);
  }
}
