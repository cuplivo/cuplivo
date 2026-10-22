import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show defaultTargetPlatform;
import 'package:markstream/markstream.dart';
import 'package:Cuplivo/features/chat/widgets/frosted/chat_frosted_backdrop.dart';
import 'package:Cuplivo/shared/widgets/export_capture_scope.dart';
import 'markdown_surface_scope.dart';
import 'package:Cuplivo/core/providers/settings_provider.dart';
import 'package:Cuplivo/theme/app_font_weights.dart';
import 'package:Cuplivo/theme/surface_ladder.dart' show atTone, surfaceTone;
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
  var scheme = Theme.of(context).colorScheme;
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
  final desktop =
      defaultTargetPlatform == TargetPlatform.linux ||
      defaultTargetPlatform == TargetPlatform.macOS ||
      defaultTargetPlatform == TargetPlatform.windows;
  final backdrop = resolveMarkdownBackdrop(context, settings);
  if (backdrop != MarkstreamBackdrop.plain) {
    final customBackground = MarkdownSurfaceScope.maybeOf(
      context,
    )?.customBackground;
    if (customBackground != null) {
      // Fixed syntax colors need a near-dark or near-light block surface, even
      // over arbitrary wallpaper. Retain the bubble's hue, not its midtones.
      final tone = surfaceTone(customBackground);
      final dark = tone < 50;
      final blockTone = dark ? tone.clamp(0.0, 5.0) : tone.clamp(98.0, 100.0);
      scheme = scheme.copyWith(
        surface: blockTone == tone
            ? customBackground
            : atTone(customBackground, blockTone),
        onSurface: dark ? Colors.white : Colors.black,
        brightness: dark ? Brightness.dark : Brightness.light,
      );
    }
  }
  final theme = MarkstreamTheme.fromColorScheme(
    scheme,
    backdrop: backdrop,
    maskStrength: backdrop == MarkstreamBackdrop.plain
        ? 1
        : settings.chatBackgroundMaskStrength,
    bodyStyle: body,
    desktop: desktop,
    codeFontFamily: (settings.codeFontFamily?.isNotEmpty ?? false)
        ? settings.codeFontFamily!
        : 'monospace',
    medium: AppFontWeights.medium,
    semibold: AppFontWeights.semibold,
    strong: AppFontWeights.strong,
  );
  if (!settings.useLegacyInlineCodeStyle) return theme;
  final translucent =
      backdrop == MarkstreamBackdrop.wallpaper ||
      backdrop == MarkstreamBackdrop.frostedBubble;
  return theme.copyWith(
    inlineCode: theme.inlineCode.copyWith(
      text: theme.inlineCode.text.copyWith(
        height: 1.4,
        color: theme.colors.ink,
      ),
      // Keep short code within the paragraph's line height while giving
      // wrapped code room between lines.
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      backgroundColor: translucent
          ? theme.colors.fillBlock
          : theme.brightness == Brightness.dark
          ? Colors.white12
          : const Color(0x66F1F3F5),
      borderColor: theme.colors.border,
    ),
  );
}

MarkstreamBackdrop resolveMarkdownBackdrop(
  BuildContext context,
  SettingsProvider settings,
) {
  if (ExportCaptureScope.of(context)) return MarkstreamBackdrop.plain;
  // ChatBackdropSpec already resolves this with stable provider selectors.
  // Reuse that boolean instead of registering another selector per stream tick.
  final scope = ChatFrostedBackdropScope.maybeOf(context);
  if (scope == null || !scope.backgroundActive) return MarkstreamBackdrop.plain;
  final surface = MarkdownSurfaceScope.maybeOf(context);
  // Custom bubbles need the readable block fill even when the outer bubble is
  // opaque: a small tint cannot shield fixed syntax colors from a midtone.
  if (surface?.customBackground != null) {
    return MarkstreamBackdrop.wallpaper;
  }
  return switch (surface?.kind) {
    MarkdownSurfaceKind.solid => MarkstreamBackdrop.solidBubble,
    MarkdownSurfaceKind.frosted => MarkstreamBackdrop.frostedBubble,
    // User/reasoning tints can be only 8% opaque and cannot shield the text
    // like a frosted bubble. Keep the wallpaper readability guard here.
    MarkdownSurfaceKind.tinted => MarkstreamBackdrop.wallpaper,
    null => MarkstreamBackdrop.wallpaper,
  };
}
