import 'package:flutter/material.dart';

import '../core/providers/settings_provider.dart';

/// Optional overrides for frosted/solid chat bubbles.
///
/// Every field is nullable. `null` means keep today's hardcoded default
/// (theme-following colors, 0.8pt border, 16pt corners, sigma 14, etc.).
class ChatBubbleStyleOverrides {
  const ChatBubbleStyleOverrides({
    this.backgroundArgbLight,
    this.backgroundArgbDark,
    this.borderArgbLight,
    this.borderArgbDark,
    this.textArgbLight,
    this.textArgbDark,
    this.borderWidth,
    this.borderOpacity,
    this.cornerRadius,
    this.blurSigma,
    this.frostedOpacity,
    this.solidOpacity,
  });

  // Shared colors (RGB; alpha comes from the opacity fields).
  final int? backgroundArgbLight;
  final int? backgroundArgbDark;
  final int? borderArgbLight;
  final int? borderArgbDark;
  final int? textArgbLight;
  final int? textArgbDark;

  // Shared geometry.
  final double? borderWidth; // null -> 0.8
  final double? borderOpacity; // null -> frosted 0.14 / solid 0.16
  final double? cornerRadius; // null -> 16

  // Per-style.
  final double? blurSigma; // frosted only, null -> 14
  final double? frostedOpacity; // null -> 0.66
  final double? solidOpacity; // null -> 1.0

  bool get isDefault =>
      backgroundArgbLight == null &&
      backgroundArgbDark == null &&
      borderArgbLight == null &&
      borderArgbDark == null &&
      textArgbLight == null &&
      textArgbDark == null &&
      borderWidth == null &&
      borderOpacity == null &&
      cornerRadius == null &&
      blurSigma == null &&
      frostedOpacity == null &&
      solidOpacity == null;

  bool hasTextOverride(Brightness brightness) => brightness == Brightness.dark
      ? textArgbDark != null
      : textArgbLight != null;

  ChatBubbleStyleOverrides copyWith({
    int? Function()? backgroundArgbLight,
    int? Function()? backgroundArgbDark,
    int? Function()? borderArgbLight,
    int? Function()? borderArgbDark,
    int? Function()? textArgbLight,
    int? Function()? textArgbDark,
    double? Function()? borderWidth,
    double? Function()? borderOpacity,
    double? Function()? cornerRadius,
    double? Function()? blurSigma,
    double? Function()? frostedOpacity,
    double? Function()? solidOpacity,
  }) {
    return ChatBubbleStyleOverrides(
      backgroundArgbLight: backgroundArgbLight != null
          ? backgroundArgbLight()
          : this.backgroundArgbLight,
      backgroundArgbDark: backgroundArgbDark != null
          ? backgroundArgbDark()
          : this.backgroundArgbDark,
      borderArgbLight: borderArgbLight != null
          ? borderArgbLight()
          : this.borderArgbLight,
      borderArgbDark: borderArgbDark != null
          ? borderArgbDark()
          : this.borderArgbDark,
      textArgbLight: textArgbLight != null
          ? textArgbLight()
          : this.textArgbLight,
      textArgbDark: textArgbDark != null ? textArgbDark() : this.textArgbDark,
      borderWidth: borderWidth != null ? borderWidth() : this.borderWidth,
      borderOpacity: borderOpacity != null
          ? borderOpacity()
          : this.borderOpacity,
      cornerRadius: cornerRadius != null ? cornerRadius() : this.cornerRadius,
      blurSigma: blurSigma != null ? blurSigma() : this.blurSigma,
      frostedOpacity: frostedOpacity != null
          ? frostedOpacity()
          : this.frostedOpacity,
      solidOpacity: solidOpacity != null ? solidOpacity() : this.solidOpacity,
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
    if (backgroundArgbLight != null) 'backgroundArgbLight': backgroundArgbLight,
    if (backgroundArgbDark != null) 'backgroundArgbDark': backgroundArgbDark,
    if (borderArgbLight != null) 'borderArgbLight': borderArgbLight,
    if (borderArgbDark != null) 'borderArgbDark': borderArgbDark,
    if (textArgbLight != null) 'textArgbLight': textArgbLight,
    if (textArgbDark != null) 'textArgbDark': textArgbDark,
    if (borderWidth != null) 'borderWidth': borderWidth,
    if (borderOpacity != null) 'borderOpacity': borderOpacity,
    if (cornerRadius != null) 'cornerRadius': cornerRadius,
    if (blurSigma != null) 'blurSigma': blurSigma,
    if (frostedOpacity != null) 'frostedOpacity': frostedOpacity,
    if (solidOpacity != null) 'solidOpacity': solidOpacity,
  };

  factory ChatBubbleStyleOverrides.fromJson(Map<String, dynamic> json) {
    // Fork-side hardening (upstream parses raw): persisted values may come
    // from imports, old versions, or hand-edited backups, and non-finite /
    // out-of-range numbers would later crash the paint path
    // (BorderRadius/ImageFilter/Border/withValues). Normalize here so the
    // model only ever holds values the renderer and the settings editors can
    // express.
    return ChatBubbleStyleOverrides(
      backgroundArgbLight: _asArgb(json['backgroundArgbLight']),
      backgroundArgbDark: _asArgb(json['backgroundArgbDark']),
      borderArgbLight: _asArgb(json['borderArgbLight']),
      borderArgbDark: _asArgb(json['borderArgbDark']),
      textArgbLight: _asArgb(json['textArgbLight']),
      textArgbDark: _asArgb(json['textArgbDark']),
      borderWidth: _asClampedDouble(json['borderWidth'], 0, 3),
      borderOpacity: _asClampedDouble(json['borderOpacity'], 0, 1),
      cornerRadius: _asClampedDouble(json['cornerRadius'], 0, 28),
      blurSigma: _asClampedDouble(json['blurSigma'], 0, 30),
      frostedOpacity: _asClampedDouble(json['frostedOpacity'], 0, 1),
      solidOpacity: _asClampedDouble(json['solidOpacity'], 0, 1),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is ChatBubbleStyleOverrides &&
      other.backgroundArgbLight == backgroundArgbLight &&
      other.backgroundArgbDark == backgroundArgbDark &&
      other.borderArgbLight == borderArgbLight &&
      other.borderArgbDark == borderArgbDark &&
      other.textArgbLight == textArgbLight &&
      other.textArgbDark == textArgbDark &&
      other.borderWidth == borderWidth &&
      other.borderOpacity == borderOpacity &&
      other.cornerRadius == cornerRadius &&
      other.blurSigma == blurSigma &&
      other.frostedOpacity == frostedOpacity &&
      other.solidOpacity == solidOpacity;

  @override
  int get hashCode => Object.hash(
    backgroundArgbLight,
    backgroundArgbDark,
    borderArgbLight,
    borderArgbDark,
    textArgbLight,
    textArgbDark,
    borderWidth,
    borderOpacity,
    cornerRadius,
    blurSigma,
    frostedOpacity,
    solidOpacity,
  );
}

class ResolvedBubbleStyle {
  const ResolvedBubbleStyle({
    required this.background,
    required this.border,
    required this.text,
    required this.borderWidth,
    required this.radius,
    required this.blurSigma,
  });

  final Color background;
  final Color border;
  final Color text;
  final double borderWidth;
  final double radius;
  final double blurSigma;
}

/// Resolve overrides + theme + style into the values the chat surface paints.
///
/// Fallbacks match the previous hardcoded frosted/solid branch so leaving
/// every field `null` preserves current pixels.
ResolvedBubbleStyle resolveBubbleStyle(
  ColorScheme cs,
  Brightness brightness,
  ChatMessageBackgroundStyle style,
  ChatBubbleStyleOverrides overrides,
) {
  final isDark = brightness == Brightness.dark;
  final bgArgb = isDark
      ? overrides.backgroundArgbDark
      : overrides.backgroundArgbLight;
  final borderArgb = isDark
      ? overrides.borderArgbDark
      : overrides.borderArgbLight;
  final textArgb = isDark ? overrides.textArgbDark : overrides.textArgbLight;

  final opacity = switch (style) {
    ChatMessageBackgroundStyle.frosted => _sanitizeOpacity(
      overrides.frostedOpacity,
      0.66,
    ),
    ChatMessageBackgroundStyle.solid => _sanitizeOpacity(
      overrides.solidOpacity,
      1.0,
    ),
    ChatMessageBackgroundStyle.defaultStyle => _sanitizeOpacity(
      overrides.solidOpacity,
      1.0,
    ),
  };
  final borderOpacity = _sanitizeOpacity(
    overrides.borderOpacity,
    style == ChatMessageBackgroundStyle.frosted ? 0.14 : 0.16,
  );
  final bgValue = bgArgb != null ? _sanitizeArgb(bgArgb) : null;
  final borderValue = borderArgb != null ? _sanitizeArgb(borderArgb) : null;
  final textValue = textArgb != null ? _sanitizeArgb(textArgb) : null;

  // Cuplivo defaults (not upstream's surfaceContainerHigh): match the pixels
  // of the previous hardcoded branches — frosted glass white/0xFF1C1C1E,
  // solid fills `AppSemanticColors.surfaceCard` (white @ 0.96 light /
  // 0.10 dark over the scheme surface).
  final Color defaultBackground;
  switch (style) {
    case ChatMessageBackgroundStyle.frosted:
      defaultBackground = isDark ? const Color(0xFF1C1C1E) : Colors.white;
    case ChatMessageBackgroundStyle.solid:
    case ChatMessageBackgroundStyle.defaultStyle:
      defaultBackground = isDark
          ? Color.alphaBlend(Colors.white.withValues(alpha: 0.10), cs.surface)
          : Color.alphaBlend(Colors.white.withValues(alpha: 0.96), cs.surface);
  }

  return ResolvedBubbleStyle(
    background: (bgValue != null ? Color(bgValue) : defaultBackground)
        .withValues(alpha: opacity),
    border: (borderValue != null ? Color(borderValue) : cs.outlineVariant)
        .withValues(alpha: borderOpacity),
    text: textValue != null ? Color(textValue) : cs.onSurface,
    borderWidth: _sanitizeNonNegative(overrides.borderWidth, 0.8),
    radius: _sanitizeNonNegative(overrides.cornerRadius, 16),
    blurSigma: _sanitizeNonNegative(overrides.blurSigma, 14),
  );
}

/// Clamps a persisted value into its supported range; non-finite or missing
/// values become `null` (meaning "use the default").
double? _asClampedDouble(Object? value, double min, double max) {
  if (value is! num) return null;
  final v = value.toDouble();
  if (!v.isFinite) return null;
  return v.clamp(min, max);
}

/// Validates a 32-bit ARGB literal from persistence.
int? _asArgb(Object? value) {
  if (value is! num) return null;
  final v = value.toInt();
  if (v < 0 || v > 0xFFFFFFFF) return null;
  return v;
}

/// Render-boundary sanitizer: geometry values must be finite and >= 0,
/// otherwise the paint path (BorderRadius/ImageFilter/Border) is unsafe.
double _sanitizeNonNegative(double? value, double fallback) {
  if (value == null || !value.isFinite || value < 0) return fallback;
  return value;
}

/// Render-boundary sanitizer: opacity must be finite within 0..1
/// ([Color.withValues] rejects out-of-range alpha channels).
double _sanitizeOpacity(double? value, double fallback) {
  if (value == null || !value.isFinite) return fallback;
  return value.clamp(0.0, 1.0);
}

/// ARGB literals outside 32-bit are not renderable; drop them at the render
/// boundary so the default color applies instead.
int? _sanitizeArgb(int? value) {
  if (value == null || value < 0 || value > 0xFFFFFFFF) return null;
  return value;
}
