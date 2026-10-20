import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show defaultTargetPlatform;
import 'package:markstream/markstream.dart';
import 'package:Cuplivo/core/providers/settings_provider.dart';
import 'package:Cuplivo/theme/app_font_weights.dart';
import 'package:Cuplivo/theme/theme_factory.dart' show getPlatformFontFallback;

/// The size the markdown surface sets prose at when its caller names none.
///
/// It is the reference the PDF export's page scale is computed against: everything
/// the screen measured in its own pixels lands on paper as this ratio, so the one
/// number has to live where both can read it.
const double kMarkdownBodyFontSize = 15.5;

MarkstreamTheme mapMarkdownTheme(
  BuildContext context,
  SettingsProvider settings,
  TextStyle? baseStyle,
) {
  final scheme = Theme.of(context).colorScheme;
  final family = settings.appFontFamily;
  final body =
      (baseStyle ?? Theme.of(context).textTheme.bodyMedium ?? const TextStyle())
          .copyWith(
            fontFamily: family == null || family.isEmpty
                ? baseStyle?.fontFamily
                : family,
            fontFamilyFallback:
                baseStyle?.fontFamilyFallback ?? getPlatformFontFallback(),
            fontSize: baseStyle?.fontSize ?? kMarkdownBodyFontSize,
            height: baseStyle?.height ?? 1.55,
            letterSpacing:
                baseStyle?.letterSpacing ??
                (Localizations.localeOf(context).languageCode == 'zh'
                    ? 0
                    : .05),
            color: DefaultTextStyle.of(context).style.color ?? scheme.onSurface,
          );
  final theme = MarkstreamTheme.fromColorScheme(
    scheme,
    bodyStyle: body,
    codeFontFamily: (settings.codeFontFamily?.isNotEmpty ?? false)
        ? settings.codeFontFamily!
        : 'monospace',
    medium: AppFontWeights.medium,
    semibold: AppFontWeights.semibold,
    strong: AppFontWeights.strong,
  );
  final mobile =
      defaultTargetPlatform == TargetPlatform.android ||
      defaultTargetPlatform == TargetPlatform.iOS;
  return mobile
      ? theme.copyWith(
          table: theme.table.copyWith(
            bodyBackgroundColor: Color.alphaBlend(
              scheme.primary.withValues(
                alpha: theme.brightness == Brightness.dark ? .045 : .018,
              ),
              scheme.surface,
            ).withValues(alpha: theme.fillAlphas.table),
          ),
        )
      : theme;
}
