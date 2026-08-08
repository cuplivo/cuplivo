import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, kIsWeb, TargetPlatform;
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../core/providers/settings_provider.dart';
import '../../../core/services/android_background.dart';
import '../../../core/services/notification_service.dart';
import '../../../icons/lucide_adapter.dart';
import '../../../l10n/app_localizations.dart';
import '../../../shared/widgets/ios_switch.dart';
import '../pages/ios_background_settings_page.dart';
import '../pages/google_fonts_picker_page.dart';
import 'package:Cuplivo/theme/app_font_weights.dart';
import 'package:Cuplivo/desktop/widgets/system_font_chooser.dart';
import 'package:file_picker/file_picker.dart';
import 'package:syncfusion_flutter_core/theme.dart';
import 'package:syncfusion_flutter_sliders/sliders.dart';
import 'ios_settings_widgets.dart';

enum FontTarget { app, code }

// --- Bottom sheets (moved from DisplaySettingsPage) ---

Future<void> showMobileFontSourceSheet(
  BuildContext context, {
  required FontTarget target,
}) async {
  final cs = Theme.of(context).colorScheme;
  final l10n = AppLocalizations.of(context)!;
  final choice = await showModalBottomSheet<String>(
    context: context,
    backgroundColor: cs.surface,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
    ),
    builder: (ctx) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            IosSettingsSheetOption(
              ctx,
              label: l10n.fontPickerChooseLocalFile,
              onTap: () => Navigator.of(ctx).pop('local'),
            ),
            IosSettingsSheetDivider(ctx),
            IosSettingsSheetOption(
              ctx,
              label: l10n.fontPickerGetFromGoogleFonts,
              onTap: () => Navigator.of(ctx).pop('google'),
            ),
            if (!kIsWeb &&
                (defaultTargetPlatform == TargetPlatform.macOS ||
                    defaultTargetPlatform == TargetPlatform.windows ||
                    defaultTargetPlatform == TargetPlatform.linux)) ...[
              IosSettingsSheetDivider(ctx),
              IosSettingsSheetOption(
                ctx,
                label: l10n.newSettingsSystemFontOption,
                onTap: () => Navigator.of(ctx).pop('system'),
              ),
            ],
            IosSettingsSheetDivider(ctx),
            IosSettingsSheetOption(
              ctx,
              label: l10n.displaySettingsPageFontResetLabel,
              onTap: () => Navigator.of(ctx).pop('reset'),
            ),
          ],
        ),
      ),
    ),
  );
  if (choice == null) return;
  if (!context.mounted) return;

  final settings = context.read<SettingsProvider>();
  if (choice == 'local') {
    final res = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: const ['ttf', 'otf'],
    );
    final path = res?.files.singleOrNull?.path;
    if (path == null) return;
    if (!context.mounted) return;
    if (target == FontTarget.app) {
      await settings.setAppFontFromLocal(path: path);
    } else {
      await settings.setCodeFontFromLocal(path: path);
    }
    return;
  }
  if (choice == 'google') {
    final title = target == FontTarget.app
        ? l10n.displaySettingsPageAppFontTitle
        : l10n.displaySettingsPageCodeFontTitle;
    final selected = await Navigator.of(context).push<String>(
      MaterialPageRoute(builder: (_) => GoogleFontsPickerPage(title: title)),
    );
    if (selected == null || selected.isEmpty) return;
    if (!context.mounted) return;
    if (target == FontTarget.app) {
      await settings.setAppFontFromGoogle(selected);
    } else {
      await settings.setCodeFontFromGoogle(selected);
    }
    return;
  }
  if (choice == 'system') {
    if (!context.mounted) return;
    await showSystemFontChooserDialog(
      context,
      codeFont: target == FontTarget.code,
    );
    return;
  }
  if (choice == 'reset') {
    if (target == FontTarget.app) {
      await settings.clearAppFont();
    } else {
      await settings.clearCodeFont();
    }
  }
}

Future<void> showChatMessageBackgroundSheet(BuildContext context) async {
  final cs = Theme.of(context).colorScheme;
  final l10n = AppLocalizations.of(context)!;
  final choice = await showModalBottomSheet<String>(
    context: context,
    backgroundColor: cs.surface,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
    ),
    builder: (ctx) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            IosSettingsSheetOption(
              ctx,
              label: l10n.displaySettingsPageChatMessageBackgroundDefault,
              onTap: () => Navigator.of(ctx).pop('default'),
            ),
            IosSettingsSheetDivider(ctx),
            IosSettingsSheetOption(
              ctx,
              label: l10n.displaySettingsPageChatMessageBackgroundFrosted,
              onTap: () => Navigator.of(ctx).pop('frosted'),
            ),
            IosSettingsSheetDivider(ctx),
            IosSettingsSheetOption(
              ctx,
              label: l10n.displaySettingsPageChatMessageBackgroundSolid,
              onTap: () => Navigator.of(ctx).pop('solid'),
            ),
          ],
        ),
      ),
    ),
  );
  if (choice == null) return;
  if (!context.mounted) return;

  final sp = context.read<SettingsProvider>();
  switch (choice) {
    case 'frosted':
      await sp.setChatMessageBackgroundStyle(
        ChatMessageBackgroundStyle.frosted,
      );
      break;
    case 'solid':
      await sp.setChatMessageBackgroundStyle(ChatMessageBackgroundStyle.solid);
      break;
    default:
      await sp.setChatMessageBackgroundStyle(
        ChatMessageBackgroundStyle.defaultStyle,
      );
  }
}

Future<void> showAndroidBackgroundChatSheet(BuildContext context) async {
  final cs = Theme.of(context).colorScheme;
  final l10n = AppLocalizations.of(context)!;
  final sp = context.read<SettingsProvider>();
  final previous = sp.androidBackgroundChatMode;
  final choice = await showModalBottomSheet<String>(
    context: context,
    backgroundColor: cs.surface,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
    ),
    builder: (ctx) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            IosSettingsSheetOption(
              ctx,
              label: l10n.androidBackgroundOptionOn,
              onTap: () => Navigator.of(ctx).pop('on'),
            ),
            IosSettingsSheetDivider(ctx),
            IosSettingsSheetOption(
              ctx,
              label: l10n.androidBackgroundOptionOnNotify,
              onTap: () => Navigator.of(ctx).pop('on_notify'),
            ),
            IosSettingsSheetDivider(ctx),
            IosSettingsSheetOption(
              ctx,
              label: l10n.androidBackgroundOptionOff,
              onTap: () => Navigator.of(ctx).pop('off'),
            ),
          ],
        ),
      ),
    ),
  );
  if (choice == null) return;
  if (!context.mounted) return;

  final notificationTitle = l10n.androidBackgroundNotificationTitle;
  final notificationText = l10n.androidBackgroundNotificationText;
  switch (choice) {
    case 'on_notify':
      await sp.setAndroidBackgroundChatMode(AndroidBackgroundChatMode.onNotify);
      try {
        await AndroidBackgroundManager.ensureInitialized(
          notificationTitle: notificationTitle,
          notificationText: notificationText,
        );
        await AndroidBackgroundManager.setEnabled(true);
        await NotificationService.ensureInitialized();
        final granted =
            await NotificationService.ensureAndroidNotificationsPermission();
        if (!granted) {
          debugPrint(
            'AndroidBackgroundManager: notifications permission denied, '
            'persisting on mode instead of onNotify',
          );
          await sp.setAndroidBackgroundChatMode(AndroidBackgroundChatMode.on);
        }
      } catch (e) {
        debugPrint('AndroidBackgroundManager init failed: $e');
        await sp.setAndroidBackgroundChatMode(previous);
      }
      break;
    case 'on':
      await sp.setAndroidBackgroundChatMode(AndroidBackgroundChatMode.on);
      try {
        await AndroidBackgroundManager.ensureInitialized(
          notificationTitle: notificationTitle,
          notificationText: notificationText,
        );
        await AndroidBackgroundManager.setEnabled(true);
        // Prepare notification channel as well to avoid FGS notification issues on some ROMs
        await NotificationService.ensureInitialized();
      } catch (e) {
        debugPrint('AndroidBackgroundManager init failed: $e');
        await sp.setAndroidBackgroundChatMode(previous);
      }
      break;
    default:
      await sp.setAndroidBackgroundChatMode(AndroidBackgroundChatMode.off);
      try {
        await AndroidBackgroundManager.setEnabled(false);
      } catch (e) {
        debugPrint('AndroidBackgroundManager disable failed: $e');
      }
  }
}

Future<void> showLanguageSheet(BuildContext context) async {
  final cs = Theme.of(context).colorScheme;
  final l10n = AppLocalizations.of(context)!;
  final selected = await showModalBottomSheet<String>(
    context: context,
    backgroundColor: cs.surface,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
    ),
    builder: (ctx) {
      return SafeArea(
        child: Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              IosSettingsSheetOption(
                ctx,
                label: l10n.settingsPageSystemMode,
                onTap: () => Navigator.of(ctx).pop('system'),
              ),
              IosSettingsSheetDivider(ctx),
              IosSettingsSheetOption(
                ctx,
                label: l10n.displaySettingsPageLanguageChineseLabel,
                onTap: () => Navigator.of(ctx).pop('zh_CN'),
              ),
              IosSettingsSheetDivider(ctx),
              IosSettingsSheetOption(
                ctx,
                label: l10n.languageDisplayTraditionalChinese,
                onTap: () => Navigator.of(ctx).pop('zh_Hant'),
              ),
              IosSettingsSheetDivider(ctx),
              IosSettingsSheetOption(
                ctx,
                label: l10n.displaySettingsPageLanguageEnglishLabel,
                onTap: () => Navigator.of(ctx).pop('en_US'),
              ),
            ],
          ),
        ),
      );
    },
  );
  if (selected == null) return;
  if (!context.mounted) return;

  final settings = context.read<SettingsProvider>();
  switch (selected) {
    case 'system':
      await settings.setAppLocaleFollowSystem();
      break;
    case 'zh_CN':
      await settings.setAppLocale(const Locale('zh', 'CN'));
      break;
    case 'zh_Hant':
      await settings.setAppLocale(
        const Locale.fromSubtags(languageCode: 'zh', scriptCode: 'Hant'),
      );
      break;
    case 'en_US':
    default:
      await settings.setAppLocale(const Locale('en', 'US'));
  }
}

Future<void> showChatFontSizeSheet(BuildContext context) async {
  final cs = Theme.of(context).colorScheme;
  final l10n = AppLocalizations.of(context)!;
  await showModalBottomSheet(
    context: context,
    backgroundColor: cs.surface,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
    ),
    isScrollControlled: false,
    builder: (ctx) {
      return SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 18),
          child: Builder(
            builder: (context) {
              final theme = Theme.of(context);
              final cs = theme.colorScheme;
              final isDark = theme.brightness == Brightness.dark;
              final scale = context.watch<SettingsProvider>().chatFontScale;
              return Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Text(
                        '50%',
                        style: TextStyle(
                          color: cs.onSurface.withValues(alpha: 0.7),
                          fontSize: 12,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: SfSliderTheme(
                          data: SfSliderThemeData(
                            activeTrackHeight: 8,
                            inactiveTrackHeight: 8,
                            overlayRadius: 14,
                            activeTrackColor: cs.primary,
                            inactiveTrackColor: cs.onSurface.withValues(
                              alpha: isDark ? 0.25 : 0.20,
                            ),
                            tooltipBackgroundColor: cs.primary,
                            tooltipTextStyle: TextStyle(
                              color: cs.onPrimary,
                              fontWeight: AppFontWeights.semibold,
                            ),
                            activeTickColor: cs.onSurface.withValues(
                              alpha: isDark ? 0.45 : 0.35,
                            ),
                            inactiveTickColor: cs.onSurface.withValues(
                              alpha: isDark ? 0.30 : 0.25,
                            ),
                            activeMinorTickColor: cs.onSurface.withValues(
                              alpha: isDark ? 0.34 : 0.28,
                            ),
                            inactiveMinorTickColor: cs.onSurface.withValues(
                              alpha: isDark ? 0.24 : 0.20,
                            ),
                          ),
                          child: SfSlider(
                            value: scale,
                            min: 0.5,
                            max: 1.50001,
                            stepSize: 0.05,
                            showTicks: true,
                            showLabels: true,
                            interval: 0.1,
                            minorTicksPerInterval: 1,
                            enableTooltip: true,
                            shouldAlwaysShowTooltip: false,
                            tooltipShape: const SfPaddleTooltipShape(),
                            labelFormatterCallback: (value, text) =>
                                (value as double).toStringAsFixed(1),
                            thumbIcon: Container(
                              width: 20,
                              height: 20,
                              decoration: BoxDecoration(
                                color: cs.primary,
                                shape: BoxShape.circle,
                                boxShadow: isDark
                                    ? []
                                    : [
                                        BoxShadow(
                                          color: Colors.black.withValues(
                                            alpha: 0.08,
                                          ),
                                          blurRadius: 8,
                                          offset: Offset(0, 2),
                                        ),
                                      ],
                              ),
                            ),
                            onChanged: (v) => context
                                .read<SettingsProvider>()
                                .setChatFontScale(
                                  (v as double).clamp(0.5, 1.5),
                                ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        '${(scale * 100).round()}%',
                        style: TextStyle(color: cs.onSurface, fontSize: 12),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: Theme.of(context).brightness == Brightness.dark
                          ? Colors.white12
                          : const Color(0xFFF2F3F5),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Text(
                      l10n.displaySettingsPageChatFontSampleText,
                      style: TextStyle(
                        fontSize:
                            16 *
                            context.watch<SettingsProvider>().chatFontScale,
                      ),
                    ),
                  ),
                ],
              );
            },
          ),
        ),
      );
    },
  );
}

Future<void> showAutoScrollIdleSheet(BuildContext context) async {
  final cs = Theme.of(context).colorScheme;
  final l10n = AppLocalizations.of(context)!;
  await showModalBottomSheet(
    context: context,
    backgroundColor: cs.surface,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
    ),
    isScrollControlled: false,
    builder: (ctx) {
      return SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 18),
          child: Builder(
            builder: (context) {
              final theme = Theme.of(context);
              final cs = theme.colorScheme;
              final isDark = theme.brightness == Brightness.dark;
              final sp = context.watch<SettingsProvider>();
              final seconds = sp.autoScrollIdleSeconds;
              final enabled = sp.autoScrollEnabled;
              return Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Text(
                        l10n.displaySettingsPageAutoScrollEnableTitle,
                        style: TextStyle(fontSize: 15, color: cs.onSurface),
                      ),
                      const Spacer(),
                      IosSwitch(
                        value: enabled,
                        onChanged: (v) => context
                            .read<SettingsProvider>()
                            .setAutoScrollEnabled(v),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Text(
                        '2s',
                        style: TextStyle(
                          color: cs.onSurface.withValues(alpha: 0.7),
                          fontSize: 12,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: SfSliderTheme(
                          data: SfSliderThemeData(
                            activeTrackHeight: 8,
                            inactiveTrackHeight: 8,
                            overlayRadius: 14,
                            activeTrackColor: cs.primary,
                            inactiveTrackColor: cs.onSurface.withValues(
                              alpha: isDark ? 0.25 : 0.20,
                            ),
                            tooltipBackgroundColor: cs.primary,
                            tooltipTextStyle: TextStyle(
                              color: cs.onPrimary,
                              fontWeight: AppFontWeights.semibold,
                            ),
                            activeTickColor: cs.onSurface.withValues(
                              alpha: isDark ? 0.45 : 0.35,
                            ),
                            inactiveTickColor: cs.onSurface.withValues(
                              alpha: isDark ? 0.30 : 0.25,
                            ),
                            activeMinorTickColor: cs.onSurface.withValues(
                              alpha: isDark ? 0.34 : 0.28,
                            ),
                            inactiveMinorTickColor: cs.onSurface.withValues(
                              alpha: isDark ? 0.24 : 0.20,
                            ),
                          ),
                          child: SfSlider(
                            value: seconds.toDouble(),
                            min: 2.0,
                            max: 64.0,
                            stepSize: 2.0,
                            showTicks: true,
                            showLabels: true,
                            interval: 10.0,
                            minorTicksPerInterval: 1,
                            enableTooltip: true,
                            shouldAlwaysShowTooltip: false,
                            tooltipShape: const SfPaddleTooltipShape(),
                            labelFormatterCallback: (value, text) =>
                                value.toInt().toString(),
                            thumbIcon: Container(
                              width: 20,
                              height: 20,
                              decoration: BoxDecoration(
                                color: cs.primary,
                                shape: BoxShape.circle,
                                boxShadow: isDark
                                    ? []
                                    : [
                                        BoxShadow(
                                          color: Colors.black.withValues(
                                            alpha: 0.08,
                                          ),
                                          blurRadius: 8,
                                          offset: Offset(0, 2),
                                        ),
                                      ],
                              ),
                            ),
                            onChanged: enabled
                                ? (v) => context
                                      .read<SettingsProvider>()
                                      .setAutoScrollIdleSeconds(
                                        (v as double).round(),
                                      )
                                : null,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        enabled
                            ? '${seconds.round()}s'
                            : l10n.displaySettingsPageAutoScrollDisabledLabel,
                        style: TextStyle(
                          color: cs.onSurface.withValues(
                            alpha: enabled ? 1.0 : 0.5,
                          ),
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Text(
                    l10n.displaySettingsPageAutoScrollIdleSubtitle,
                    style: TextStyle(
                      fontSize: 12,
                      color: cs.onSurface.withValues(alpha: 0.6),
                    ),
                  ),
                ],
              );
            },
          ),
        ),
      );
    },
  );
}

Future<void> showChatBackgroundMaskSheet(BuildContext context) async {
  final cs = Theme.of(context).colorScheme;
  await showModalBottomSheet(
    context: context,
    backgroundColor: cs.surface,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
    ),
    isScrollControlled: false,
    builder: (ctx) {
      return SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 18),
          child: Builder(
            builder: (context) {
              final theme = Theme.of(context);
              final cs = theme.colorScheme;
              final isDark = theme.brightness == Brightness.dark;
              final strength = context
                  .watch<SettingsProvider>()
                  .chatBackgroundMaskStrength;
              return Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Text(
                        '0%',
                        style: TextStyle(
                          color: cs.onSurface.withValues(alpha: 0.7),
                          fontSize: 12,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: SfSliderTheme(
                          data: SfSliderThemeData(
                            activeTrackHeight: 8,
                            inactiveTrackHeight: 8,
                            overlayRadius: 14,
                            activeTrackColor: cs.primary,
                            inactiveTrackColor: cs.onSurface.withValues(
                              alpha: isDark ? 0.25 : 0.20,
                            ),
                            tooltipBackgroundColor: cs.primary,
                            tooltipTextStyle: TextStyle(
                              color: cs.onPrimary,
                              fontWeight: AppFontWeights.semibold,
                            ),
                            activeTickColor: cs.onSurface.withValues(
                              alpha: isDark ? 0.45 : 0.35,
                            ),
                            inactiveTickColor: cs.onSurface.withValues(
                              alpha: isDark ? 0.30 : 0.25,
                            ),
                            activeMinorTickColor: cs.onSurface.withValues(
                              alpha: isDark ? 0.34 : 0.28,
                            ),
                            inactiveMinorTickColor: cs.onSurface.withValues(
                              alpha: isDark ? 0.24 : 0.20,
                            ),
                          ),
                          child: SfSlider(
                            value: (strength * 100)
                                .roundToDouble()
                                .clamp(0.0, 200.0)
                                .toDouble(),
                            min: 0.0,
                            max: 200.0001,
                            stepSize: 5.0,
                            showTicks: true,
                            showLabels: true,
                            interval: 50,
                            minorTicksPerInterval: 1,
                            enableTooltip: true,
                            shouldAlwaysShowTooltip: false,
                            tooltipShape: const SfPaddleTooltipShape(),
                            labelFormatterCallback: (value, text) =>
                                '${(value as double).round()}%',
                            thumbIcon: Container(
                              width: 20,
                              height: 20,
                              decoration: BoxDecoration(
                                color: cs.primary,
                                shape: BoxShape.circle,
                                boxShadow: isDark
                                    ? []
                                    : [
                                        BoxShadow(
                                          color: Colors.black.withValues(
                                            alpha: 0.08,
                                          ),
                                          blurRadius: 8,
                                          offset: Offset(0, 2),
                                        ),
                                      ],
                              ),
                            ),
                            onChanged: (v) => context
                                .read<SettingsProvider>()
                                .setChatBackgroundMaskStrength(
                                  ((v as double) / 100.0).clamp(0.0, 2.0),
                                ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        '${(strength * 100).round()}%',
                        style: TextStyle(color: cs.onSurface, fontSize: 12),
                      ),
                    ],
                  ),
                ],
              );
            },
          ),
        ),
      );
    },
  );
}

Future<void> showChatInputBackgroundOpacitySheet(BuildContext context) async {
  final cs = Theme.of(context).colorScheme;
  await showModalBottomSheet(
    context: context,
    backgroundColor: cs.surface,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
    ),
    isScrollControlled: false,
    builder: (ctx) {
      return SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 18),
          child: Builder(
            builder: (context) {
              final theme = Theme.of(context);
              final isDark = theme.brightness == Brightness.dark;
              final l10n = AppLocalizations.of(context)!;
              final settings = context.watch<SettingsProvider>();
              return Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _chatInputOpacitySlider(
                    context,
                    label: l10n.settingsPageLightMode,
                    brightness: Brightness.light,
                    opacity: settings.chatInputBackgroundOpacityLight,
                    isDark: isDark,
                  ),
                  const SizedBox(height: 18),
                  _chatInputOpacitySlider(
                    context,
                    label: l10n.settingsPageDarkMode,
                    brightness: Brightness.dark,
                    opacity: settings.chatInputBackgroundOpacityDark,
                    isDark: isDark,
                  ),
                ],
              );
            },
          ),
        ),
      );
    },
  );
}

Widget _chatInputOpacitySlider(
  BuildContext context, {
  required String label,
  required Brightness brightness,
  required double opacity,
  required bool isDark,
}) {
  final cs = Theme.of(context).colorScheme;
  return Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(
        label,
        style: TextStyle(
          color: cs.onSurface,
          fontSize: 13,
          fontWeight: AppFontWeights.semibold,
        ),
      ),
      const SizedBox(height: 8),
      Row(
        children: [
          Text(
            '0%',
            style: TextStyle(
              color: cs.onSurface.withValues(alpha: 0.7),
              fontSize: 12,
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: SfSliderTheme(
              data: SfSliderThemeData(
                activeTrackHeight: 8,
                inactiveTrackHeight: 8,
                overlayRadius: 14,
                activeTrackColor: cs.primary,
                inactiveTrackColor: cs.onSurface.withValues(
                  alpha: isDark ? 0.25 : 0.20,
                ),
                tooltipBackgroundColor: cs.primary,
                tooltipTextStyle: TextStyle(
                  color: cs.onPrimary,
                  fontWeight: AppFontWeights.semibold,
                ),
                activeTickColor: cs.onSurface.withValues(
                  alpha: isDark ? 0.45 : 0.35,
                ),
                inactiveTickColor: cs.onSurface.withValues(
                  alpha: isDark ? 0.30 : 0.25,
                ),
                activeMinorTickColor: cs.onSurface.withValues(
                  alpha: isDark ? 0.34 : 0.28,
                ),
                inactiveMinorTickColor: cs.onSurface.withValues(
                  alpha: isDark ? 0.24 : 0.20,
                ),
              ),
              child: SfSlider(
                value: (opacity * 100).roundToDouble(),
                min: 0.0,
                max: 100.0001,
                stepSize: 5.0,
                showTicks: true,
                showLabels: true,
                interval: 25,
                minorTicksPerInterval: 1,
                enableTooltip: true,
                shouldAlwaysShowTooltip: false,
                tooltipShape: const SfPaddleTooltipShape(),
                labelFormatterCallback: (value, text) =>
                    '${(value as double).round()}%',
                thumbIcon: Container(
                  width: 20,
                  height: 20,
                  decoration: BoxDecoration(
                    color: cs.primary,
                    shape: BoxShape.circle,
                    boxShadow: isDark
                        ? []
                        : [
                            BoxShadow(
                              color: Colors.black.withValues(alpha: 0.08),
                              blurRadius: 8,
                              offset: Offset(0, 2),
                            ),
                          ],
                  ),
                ),
                onChanged: (v) => context
                    .read<SettingsProvider>()
                    .setChatInputBackgroundOpacity(
                      brightness,
                      ((v as double) / 100.0).clamp(0.0, 1.0),
                    ),
              ),
            ),
          ),
          const SizedBox(width: 8),
          Text(
            '${(opacity * 100).round()}%',
            style: TextStyle(color: cs.onSurface, fontSize: 12),
          ),
        ],
      ),
    ],
  );
}

/// Localized label for a theme mode, shared by the sheet and the row.
String themeModeLabel(AppLocalizations l10n, ThemeMode mode) {
  switch (mode) {
    case ThemeMode.dark:
      return l10n.settingsPageDarkMode;
    case ThemeMode.light:
      return l10n.settingsPageLightMode;
    case ThemeMode.system:
      return l10n.settingsPageSystemMode;
  }
}

Future<void> showThemeModeSheet(BuildContext context) async {
  final cs = Theme.of(context).colorScheme;
  final l10n = AppLocalizations.of(context)!;

  final selected = await showModalBottomSheet<ThemeMode>(
    context: context,
    backgroundColor: cs.surface,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
    ),
    builder: (ctx) {
      return SafeArea(
        child: Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              IosSettingsSheetOption(
                ctx,
                icon: Lucide.Monitor,
                label: themeModeLabel(l10n, ThemeMode.system),
                onTap: () => Navigator.of(ctx).pop(ThemeMode.system),
              ),
              IosSettingsSheetDivider(ctx),
              IosSettingsSheetOption(
                ctx,
                icon: Lucide.Sun,
                label: themeModeLabel(l10n, ThemeMode.light),
                onTap: () => Navigator.of(ctx).pop(ThemeMode.light),
              ),
              IosSettingsSheetDivider(ctx),
              IosSettingsSheetOption(
                ctx,
                icon: Lucide.Moon,
                label: themeModeLabel(l10n, ThemeMode.dark),
                onTap: () => Navigator.of(ctx).pop(ThemeMode.dark),
              ),
            ],
          ),
        ),
      );
    },
  );
  if (selected == null) return;
  if (!context.mounted) return;
  await context.read<SettingsProvider>().setThemeMode(selected);
}

// --- Shared row widgets ---

class ThemeModeRow extends StatelessWidget {
  const ThemeModeRow({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final sp = context.watch<SettingsProvider>();

    return IosSettingsNavRow(
      context,
      icon: Lucide.SunMoon,
      label: l10n.settingsPageColorMode,
      detailText: themeModeLabel(l10n, sp.themeMode),
      onTap: () => showThemeModeSheet(context),
    );
  }
}

class LanguageRow extends StatelessWidget {
  const LanguageRow({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;
    return IosSettingsNavRow(
      context,
      icon: Lucide.Languages,
      label: l10n.displaySettingsPageLanguageTitle,
      detailBuilder: (ctx) {
        final settings = ctx.watch<SettingsProvider>();
        String labelFor(Locale l) {
          if (l.languageCode == 'zh') {
            if ((l.scriptCode ?? '').toLowerCase() == 'hant') {
              return l10n.languageDisplayTraditionalChinese;
            }
            return l10n.displaySettingsPageLanguageChineseLabel;
          }
          return l10n.displaySettingsPageLanguageEnglishLabel;
        }

        return Text(
          settings.isFollowingSystemLocale
              ? l10n.settingsPageSystemMode
              : labelFor(settings.appLocale),
          style: TextStyle(
            color: cs.onSurface.withValues(alpha: 0.6),
            fontSize: 13,
          ),
        );
      },
      onTap: () => showLanguageSheet(context),
    );
  }
}

class ChatMessageBackgroundRow extends StatelessWidget {
  const ChatMessageBackgroundRow({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final sp = context.watch<SettingsProvider>();
    String labelOf() {
      switch (sp.chatMessageBackgroundStyle) {
        case ChatMessageBackgroundStyle.frosted:
          return l10n.displaySettingsPageChatMessageBackgroundFrosted;
        case ChatMessageBackgroundStyle.solid:
          return l10n.displaySettingsPageChatMessageBackgroundSolid;
        case ChatMessageBackgroundStyle.defaultStyle:
          return l10n.displaySettingsPageChatMessageBackgroundDefault;
      }
    }

    return IosSettingsNavRow(
      context,
      icon: Lucide.MessageSquare,
      label: l10n.displaySettingsPageChatMessageBackgroundTitle,
      detailText: labelOf(),
      onTap: () => showChatMessageBackgroundSheet(context),
    );
  }
}

class ChatBackgroundMaskRow extends StatelessWidget {
  const ChatBackgroundMaskRow({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final v = context.watch<SettingsProvider>().chatBackgroundMaskStrength;
    return IosSettingsNavRow(
      context,
      icon: Lucide.Image,
      label: l10n.displaySettingsPageChatBackgroundMaskTitle,
      detailText: '${(v * 100).round()}%',
      onTap: () => showChatBackgroundMaskSheet(context),
    );
  }
}

class ChatInputBackgroundOpacityRow extends StatelessWidget {
  const ChatInputBackgroundOpacityRow({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final brightness = Theme.of(context).brightness;
    final settings = context.watch<SettingsProvider>();
    final opacity = settings.chatInputBackgroundOpacityFor(brightness);
    return IosSettingsNavRow(
      context,
      icon: Lucide.RectangleHorizontal,
      label: l10n.displaySettingsPageChatInputBackgroundOpacityTitle,
      detailText: '${(opacity * 100).round()}%',
      onTap: () => showChatInputBackgroundOpacitySheet(context),
    );
  }
}

class AutoScrollIdleRow extends StatelessWidget {
  const AutoScrollIdleRow({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final sp = context.watch<SettingsProvider>();
    final disabled = !sp.autoScrollEnabled;
    return IosSettingsNavRow(
      context,
      icon: Lucide.ArrowDown,
      label: l10n.displaySettingsPageAutoScrollIdleTitle,
      detailText: disabled
          ? l10n.displaySettingsPageAutoScrollDisabledLabel
          : '${sp.autoScrollIdleSeconds.round()}s',
      onTap: () => showAutoScrollIdleSheet(context),
    );
  }
}

class AppFontRow extends StatelessWidget {
  const AppFontRow({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final sp = context.watch<SettingsProvider>();
    final fam = sp.appFontFamily;
    final useLocal = (sp.appFontLocalAlias ?? '').isNotEmpty;
    final text = useLocal
        ? l10n.displaySettingsPageFontLocalFileLabel
        : (fam == null || fam.isEmpty)
        ? l10n.desktopFontFamilySystemDefault
        : fam;
    return IosSettingsNavRow(
      context,
      icon: Lucide.Type,
      label: l10n.displaySettingsPageAppFontTitle,
      detailText: text,
      onTap: () => showMobileFontSourceSheet(context, target: FontTarget.app),
    );
  }
}

class CodeFontRow extends StatelessWidget {
  const CodeFontRow({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final sp = context.watch<SettingsProvider>();
    final fam = sp.codeFontFamily;
    final useLocal = (sp.codeFontLocalAlias ?? '').isNotEmpty;
    final text = useLocal
        ? l10n.displaySettingsPageFontLocalFileLabel
        : (fam == null || fam.isEmpty)
        ? l10n.desktopFontFamilyMonospaceDefault
        : fam;
    return IosSettingsNavRow(
      context,
      icon: Lucide.Code,
      label: l10n.displaySettingsPageCodeFontTitle,
      detailText: text,
      onTap: () => showMobileFontSourceSheet(context, target: FontTarget.code),
    );
  }
}

class ChatFontSizeRow extends StatelessWidget {
  const ChatFontSizeRow({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final scale = context.watch<SettingsProvider>().chatFontScale;
    return IosSettingsNavRow(
      context,
      icon: Lucide.CaseSensitive,
      label: l10n.displaySettingsPageChatFontSizeTitle,
      detailText: '${(scale * 100).round()}%',
      onTap: () => showChatFontSizeSheet(context),
    );
  }
}

/// Android/iOS background-generation row; renders nothing on other
/// platforms.
class BackgroundChatRow extends StatelessWidget {
  const BackgroundChatRow({super.key});

  /// Whether the background-chat feature exists on [p].
  static bool supportedOn(TargetPlatform p) =>
      !kIsWeb && (p == TargetPlatform.android || p == TargetPlatform.iOS);

  @override
  Widget build(BuildContext context) {
    final platform = defaultTargetPlatform;
    if (!supportedOn(platform)) {
      return const SizedBox.shrink();
    }
    final l10n = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;
    if (platform == TargetPlatform.android) {
      final sp = context.watch<SettingsProvider>();
      return IosSettingsNavRow(
        context,
        icon: Lucide.Monitor,
        label: l10n.displaySettingsPageAndroidBackgroundChatTitle,
        detailBuilder: (ctx) {
          switch (sp.androidBackgroundChatMode) {
            case AndroidBackgroundChatMode.off:
              return Text(
                l10n.androidBackgroundStatusOff,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                softWrap: false,
                style: TextStyle(
                  color: cs.onSurface.withValues(alpha: 0.6),
                  fontSize: 13,
                ),
              );
            case AndroidBackgroundChatMode.on:
              return Text(
                l10n.androidBackgroundStatusOn,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                softWrap: false,
                style: TextStyle(
                  color: cs.onSurface.withValues(alpha: 0.6),
                  fontSize: 13,
                ),
              );
            case AndroidBackgroundChatMode.onNotify:
              return Text(
                l10n.androidBackgroundStatusOther,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                softWrap: false,
                style: TextStyle(
                  color: cs.onSurface.withValues(alpha: 0.6),
                  fontSize: 13,
                ),
              );
          }
        },
        onTap: () => showAndroidBackgroundChatSheet(context),
      );
    }
    final sp = context.watch<SettingsProvider>();
    return IosSettingsNavRow(
      context,
      icon: Lucide.Activity,
      label: l10n.displaySettingsPageIosBackgroundChatTitle,
      detailBuilder: (ctx) {
        return Text(
          sp.iosBackgroundGenerationEnabled
              ? l10n.iosBackgroundStatusOn
              : l10n.iosBackgroundStatusOff,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          softWrap: false,
          style: TextStyle(
            color: cs.onSurface.withValues(alpha: 0.6),
            fontSize: 13,
          ),
        );
      },
      onTap: () => Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => const IosBackgroundSettingsPage()),
      ),
    );
  }
}
