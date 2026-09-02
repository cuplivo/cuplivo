import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:Cuplivo/core/providers/settings_provider.dart';
import 'package:Cuplivo/theme/chat_bubble_style.dart';

void main() {
  final cs = ColorScheme.fromSeed(seedColor: const Color(0xFF4D5C92));

  test('empty overrides are default and omit json fields', () {
    const empty = ChatBubbleStyleOverrides();
    expect(empty.isDefault, isTrue);
    expect(empty.toJson(), isEmpty);
    expect(ChatBubbleStyleOverrides.fromJson(const {}), empty);
  });

  test('copyWith can set and clear nullable fields', () {
    const empty = ChatBubbleStyleOverrides();
    final set = empty.copyWith(
      blurSigma: () => 20,
      backgroundArgbLight: () => 0xFF112233,
    );
    expect(set.isDefault, isFalse);
    expect(set.blurSigma, 20);
    expect(set.backgroundArgbLight, 0xFF112233);

    final cleared = set.copyWith(blurSigma: () => null);
    expect(cleared.blurSigma, isNull);
    expect(cleared.backgroundArgbLight, 0xFF112233);
  });

  test('fromJson accepts ints and doubles', () {
    final parsed = ChatBubbleStyleOverrides.fromJson({
      'borderWidth': 1,
      'frostedOpacity': 0.5,
      'backgroundArgbDark': 0xFFABCDEF,
    });
    expect(parsed.borderWidth, 1.0);
    expect(parsed.frostedOpacity, 0.5);
    expect(parsed.backgroundArgbDark, 0xFFABCDEF);
  });

  test('fromJson normalizes non-finite and out-of-range values', () {
    final parsed = ChatBubbleStyleOverrides.fromJson({
      'blurSigma': double.nan,
      'cornerRadius': -5,
      'borderWidth': 99,
      'borderOpacity': double.infinity,
      'frostedOpacity': 2.0,
      'solidOpacity': -0.4,
      'textArgbLight': -1,
      'backgroundArgbLight': 0x1FFFFFFFF,
    });
    expect(parsed.blurSigma, isNull);
    expect(parsed.cornerRadius, 0);
    expect(parsed.borderWidth, 3);
    expect(parsed.borderOpacity, isNull);
    expect(parsed.frostedOpacity, 1.0);
    expect(parsed.solidOpacity, 0.0);
    expect(parsed.textArgbLight, isNull);
    expect(parsed.backgroundArgbLight, isNull);
  });

  test('resolveBubbleStyle stays safe with programmatic bad values', () {
    const overrides = ChatBubbleStyleOverrides(
      cornerRadius: -4,
      blurSigma: double.infinity,
      borderWidth: -1,
      frostedOpacity: 1.5,
      solidOpacity: -1,
    );
    final resolved = resolveBubbleStyle(
      cs,
      Brightness.light,
      ChatMessageBackgroundStyle.frosted,
      overrides,
    );
    expect(resolved.radius, 16);
    expect(resolved.blurSigma, 14);
    expect(resolved.borderWidth, 0.8);
    expect(resolved.background, Colors.white.withValues(alpha: 1.0));
  });

  test('frosted light defaults match the previous hardcoded surface', () {
    const overrides = ChatBubbleStyleOverrides();
    final resolved = resolveBubbleStyle(
      cs,
      Brightness.light,
      ChatMessageBackgroundStyle.frosted,
      overrides,
    );
    expect(resolved.background, Colors.white.withValues(alpha: 0.66));
    expect(resolved.border, cs.outlineVariant.withValues(alpha: 0.14));
    expect(resolved.text, cs.onSurface);
    expect(resolved.borderWidth, 0.8);
    expect(resolved.radius, 16);
    expect(resolved.blurSigma, 14);
  });

  test('frosted dark defaults stay on the fixed 0xFF1C1C1E glass', () {
    final resolved = resolveBubbleStyle(
      cs,
      Brightness.dark,
      ChatMessageBackgroundStyle.frosted,
      const ChatBubbleStyleOverrides(),
    );
    expect(
      resolved.background,
      const Color(0xFF1C1C1E).withValues(alpha: 0.66),
    );
  });

  test('solid defaults match the surfaceCard derivation', () {
    final resolved = resolveBubbleStyle(
      cs,
      Brightness.light,
      ChatMessageBackgroundStyle.solid,
      const ChatBubbleStyleOverrides(),
    );
    expect(
      resolved.background,
      Color.alphaBlend(Colors.white.withValues(alpha: 0.96), cs.surface),
    );
    expect(resolved.border, cs.outlineVariant.withValues(alpha: 0.16));
    expect(resolved.blurSigma, 14);

    final dark = resolveBubbleStyle(
      cs,
      Brightness.dark,
      ChatMessageBackgroundStyle.solid,
      const ChatBubbleStyleOverrides(),
    );
    expect(
      dark.background,
      Color.alphaBlend(Colors.white.withValues(alpha: 0.10), cs.surface),
    );
  });

  test('dark color fields apply independently of light', () {
    const overrides = ChatBubbleStyleOverrides(
      backgroundArgbLight: 0xFF111111,
      backgroundArgbDark: 0xFFEEEEEE,
      textArgbDark: 0xFF00FF00,
      frostedOpacity: 0.4,
    );
    final light = resolveBubbleStyle(
      cs,
      Brightness.light,
      ChatMessageBackgroundStyle.frosted,
      overrides,
    );
    final dark = resolveBubbleStyle(
      cs,
      Brightness.dark,
      ChatMessageBackgroundStyle.frosted,
      overrides,
    );
    expect(light.background, const Color(0xFF111111).withValues(alpha: 0.4));
    expect(dark.background, const Color(0xFFEEEEEE).withValues(alpha: 0.4));
    expect(light.text, cs.onSurface);
    expect(dark.text, const Color(0xFF00FF00));
    expect(overrides.hasTextOverride(Brightness.light), isFalse);
    expect(overrides.hasTextOverride(Brightness.dark), isTrue);
  });
}
