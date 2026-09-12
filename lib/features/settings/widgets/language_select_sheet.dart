import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, TargetPlatform;
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../../../icons/lucide_adapter.dart';
import '../../../l10n/app_localizations.dart';
import '../../../shared/widgets/ios_tactile.dart';
import '../../../shared/widgets/ios_checkbox.dart';
import '../../../shared/widgets/snackbar.dart';
import '../../../core/providers/settings_provider.dart';
import '../../../core/services/haptics.dart';
import '../../../desktop/desktop_context_menu.dart';
import '../../../desktop/menu_anchor.dart';
import 'package:Cuplivo/theme/app_font_weights.dart';

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

/// Full translate-target catalog. Order is the selector order; the user's
/// visible subset is a separate persisted preference
/// (`translate_visible_languages_v1`) and never reorders the catalog.
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
  LanguageOption(
    code: 'pt',
    displayName: 'Portuguese',
    displayNameZh: 'Português',
    flag: '🇵🇹',
  ),
  LanguageOption(
    code: 'ru',
    displayName: 'Russian',
    displayNameZh: 'Русский',
    flag: '🇷🇺',
  ),
  LanguageOption(
    code: 'ar',
    displayName: 'Arabic',
    displayNameZh: 'العربية',
    flag: '🇸🇦',
  ),
  LanguageOption(
    code: 'hi',
    displayName: 'Hindi',
    displayNameZh: 'हिन्दी',
    flag: '🇮🇳',
  ),
  LanguageOption(
    code: 'th',
    displayName: 'Thai',
    displayNameZh: 'ไทย',
    flag: '🇹🇭',
  ),
  LanguageOption(
    code: 'vi',
    displayName: 'Vietnamese',
    displayNameZh: 'Tiếng Việt',
    flag: '🇻🇳',
  ),
  LanguageOption(
    code: 'bn',
    displayName: 'Bengali',
    displayNameZh: 'বাংলা',
    flag: '🇧🇩',
  ),
];

const LanguageOption _clearLanguageOption = LanguageOption(
  code: '__clear__',
  displayName: 'Clear Translation',
  displayNameZh: '清空翻译',
  flag: '',
);

/// Localized display name for a translate target language code. Single source
/// shared by every selector surface; an unknown code falls back to the code.
String translateLanguageDisplayName(AppLocalizations l10n, String code) {
  switch (code) {
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
    case 'pt':
      return l10n.languageDisplayPortuguese;
    case 'ru':
      return l10n.languageDisplayRussian;
    case 'ar':
      return l10n.languageDisplayArabic;
    case 'hi':
      return l10n.languageDisplayHindi;
    case 'th':
      return l10n.languageDisplayThai;
    case 'vi':
      return l10n.languageDisplayVietnamese;
    case 'bn':
      return l10n.languageDisplayBengali;
    default:
      return code;
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
/// current one when still visible, otherwise the first visible (catalog order).
String? effectiveTranslateTarget(Set<String> visibleCodes, String? current) {
  if (current == null || visibleCodes.contains(current)) return current;
  return visibleTranslateLanguages(visibleCodes).first.code;
}

/// The active target shown by the standalone translate pages: the persisted
/// one when still visible, else the locale language when visible, else the
/// first visible catalog entry. Single shared precedence for both pages.
LanguageOption effectiveTranslateLanguage({
  required List<LanguageOption> visible,
  required String? persistedCode,
  required String localeLanguageCode,
}) {
  final persisted = _languageByCode(visible, persistedCode);
  if (persisted != null) return persisted;
  final normalized = localeLanguageCode.toLowerCase();
  return _languageByCode(
        visible,
        normalized.startsWith('zh') ? 'zh-CN' : 'en',
      ) ??
      visible.first;
}

LanguageOption? _languageByCode(List<LanguageOption> options, String? code) {
  if (code == null || code.isEmpty) return null;
  for (final option in options) {
    if (option.code == code) return option;
  }
  return null;
}

Future<LanguageOption?> showLanguageSelector(BuildContext context) async {
  final isDesktop =
      defaultTargetPlatform == TargetPlatform.macOS ||
      defaultTargetPlatform == TargetPlatform.windows ||
      defaultTargetPlatform == TargetPlatform.linux;
  if (!isDesktop) {
    final cs = Theme.of(context).colorScheme;
    return showModalBottomSheet<LanguageOption>(
      context: context,
      isScrollControlled: true,
      backgroundColor: cs.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => const _LanguageSelectSheet(),
    );
  }

  // Desktop anchored menu
  final l10n = AppLocalizations.of(context)!;
  final settings = context.read<SettingsProvider>();
  final visible = visibleTranslateLanguages(settings.translateVisibleLanguages);
  LanguageOption? selected;
  var manageRequested = false;
  final items = [
    ...visible.map(
      (lang) => DesktopContextMenuItem(
        icon: null,
        label: '${lang.flag} ${translateLanguageDisplayName(l10n, lang.code)}',
        onTap: () => selected = lang,
      ),
    ),
    DesktopContextMenuItem(
      icon: Lucide.Settings2,
      label: l10n.translateLanguageManagerTitle,
      onTap: () => manageRequested = true,
    ),
    DesktopContextMenuItem(
      icon: Lucide.X,
      label: l10n.languageSelectSheetClearButton,
      onTap: () => selected = _clearLanguageOption,
      danger: true,
    ),
  ];
  await showDesktopContextMenuAt(
    context,
    globalPosition: DesktopMenuAnchor.positionOrCenter(context),
    items: items,
  );
  if (manageRequested) {
    if (!context.mounted) return null;
    await showTranslateLanguageManager(context);
    return null;
  }
  return selected;
}

/// Shared manage surface (mobile bottom sheet / desktop centered dialog) for
/// choosing which catalog languages appear in the selector.
Future<void> showTranslateLanguageManager(BuildContext context) async {
  final isDesktop =
      defaultTargetPlatform == TargetPlatform.macOS ||
      defaultTargetPlatform == TargetPlatform.windows ||
      defaultTargetPlatform == TargetPlatform.linux;
  if (isDesktop) {
    await showDialog<void>(
      context: context,
      builder: (_) => Dialog(
        clipBehavior: Clip.antiAlias,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420, maxHeight: 560),
          child: const _TranslateLanguageManager(),
        ),
      ),
    );
    return;
  }
  final cs = Theme.of(context).colorScheme;
  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: cs.surface,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (_) => const _TranslateLanguageManager(),
  );
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
    final settings = context.watch<SettingsProvider>();
    final visible = visibleTranslateLanguages(
      settings.translateVisibleLanguages,
    );

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
                      ...visible.map((lang) => _languageOption(context, lang)),
                      const SizedBox(height: 8),
                      TranslateLanguageActionRow(
                        icon: Lucide.Settings2,
                        label: l10n.translateLanguageManagerTitle,
                        onTap: () {
                          Haptics.light();
                          showTranslateLanguageManager(context);
                        },
                      ),
                      const SizedBox(height: 8),
                      // Clear translation row (iOS style)
                      TranslateLanguageActionRow(
                        icon: Lucide.X,
                        color: cs.error,
                        label: l10n.languageSelectSheetClearButton,
                        onTap: () {
                          Haptics.light();
                          Navigator.of(context).pop(_clearLanguageOption);
                        },
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
          baseColor: Theme.of(context).colorScheme.surface,
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
                  translateLanguageDisplayName(l10n, lang.code),
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
}

class _TranslateLanguageManager extends StatelessWidget {
  const _TranslateLanguageManager();

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;
    final settings = context.watch<SettingsProvider>();
    final selected = settings.translateVisibleLanguages;

    final maxHeight = MediaQuery.of(context).size.height * 0.8;
    return SafeArea(
      top: false,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: maxHeight),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 2),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  l10n.translateLanguageManagerTitle,
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: AppFontWeights.semibold,
                    color: cs.onSurface,
                  ),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  l10n.translateLanguageManagerSubtitle,
                  style: TextStyle(
                    fontSize: 12.5,
                    color: cs.onSurface.withValues(alpha: 0.6),
                  ),
                ),
              ),
            ),
            const Divider(height: 1),
            Flexible(
              child: SingleChildScrollView(
                physics: const BouncingScrollPhysics(),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    for (final lang in supportedLanguages)
                      _LanguageCheckRow(
                        option: lang,
                        checked: selected.contains(lang.code),
                        onTap: () => _toggle(context, settings, lang.code),
                      ),
                    const SizedBox(height: 8),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _toggle(BuildContext context, SettingsProvider settings, String code) {
    final l10n = AppLocalizations.of(context)!;
    final next = <String>{...settings.translateVisibleLanguages};
    if (next.contains(code)) {
      if (next.length <= 1) {
        showAppSnackBar(
          context,
          message: l10n.translateLanguageManagerAtLeastOne,
          type: NotificationType.warning,
        );
        return;
      }
      next.remove(code);
    } else {
      next.add(code);
    }
    settings.setTranslateVisibleLanguages(next);

    // Hiding the active target must not leave it invisible: switch to the
    // first still-visible language (catalog order).
    final active = settings.translateTargetLang;
    final effective = effectiveTranslateTarget(next, active);
    if (active != null && effective != active) {
      settings.setTranslateTargetLang(effective!);
    }
  }
}

class _LanguageCheckRow extends StatelessWidget {
  const _LanguageCheckRow({
    required this.option,
    required this.checked,
    required this.onTap,
  });

  final LanguageOption option;
  final bool checked;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;
    return IosCardPress(
      baseColor: Colors.transparent,
      borderRadius: BorderRadius.zero,
      pressedBlendStrength: 0,
      pressedScale: 1.0,
      haptics: false,
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 9),
        child: Row(
          children: [
            Text(option.flag, style: const TextStyle(fontSize: 18)),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                translateLanguageDisplayName(l10n, option.code),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: AppFontWeights.medium,
                  color: cs.onSurface.withValues(alpha: 0.9),
                ),
              ),
            ),
            const SizedBox(width: 10),
            IosCheckbox(value: checked, onChanged: (_) => onTap()),
          ],
        ),
      ),
    );
  }
}

/// Shared footer action row (Manage Languages / Clear Translation). Used by the
/// mobile language sheet and the desktop dropdown footer; on desktop it is
/// reachable by Tab and activated with Enter/Space, with a focus ring.
class TranslateLanguageActionRow extends StatefulWidget {
  const TranslateLanguageActionRow({
    super.key,
    required this.icon,
    required this.label,
    required this.onTap,
    this.color,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final Color? color;

  @override
  State<TranslateLanguageActionRow> createState() =>
      _TranslateLanguageActionRowState();
}

class _TranslateLanguageActionRowState
    extends State<TranslateLanguageActionRow> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final color = widget.color ?? cs.onSurface.withValues(alpha: 0.75);
    return FocusableActionDetector(
      shortcuts: const <ShortcutActivator, Intent>{
        SingleActivator(LogicalKeyboardKey.enter): ActivateIntent(),
        SingleActivator(LogicalKeyboardKey.space): ActivateIntent(),
      },
      actions: <Type, Action<Intent>>{
        ActivateIntent: CallbackAction<ActivateIntent>(
          onInvoke: (_) {
            widget.onTap();
            return null;
          },
        ),
      },
      onShowFocusHighlight: (value) => setState(() => _focused = value),
      child: SizedBox(
        height: 48,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          curve: Curves.easeOutCubic,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: _focused ? cs.primary : Colors.transparent,
              width: 1.5,
            ),
          ),
          child: IosCardPress(
            borderRadius: BorderRadius.circular(14),
            baseColor: cs.surface,
            duration: const Duration(milliseconds: 260),
            onTap: widget.onTap,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Row(
              children: [
                Icon(widget.icon, size: 20, color: color),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    widget.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: AppFontWeights.medium,
                      color: color,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
