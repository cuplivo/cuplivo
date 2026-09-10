import 'dart:convert';

import 'package:Cuplivo/core/models/assistant.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('gradient setting persists and toggling preserves the wallpaper', () {
    final assistant = Assistant(
      id: 'a',
      name: 'A',
      background: '/wallpaper.png',
    );
    final enabled = Assistant.fromJson(
      assistant.copyWith(useGradientBackground: true).toJson(),
    );
    expect(enabled.useGradientBackground, isTrue);
    expect(enabled.copyWith(name: 'B').useGradientBackground, isTrue);
    final disabled = Assistant.fromJson(
      enabled.copyWith(useGradientBackground: false).toJson(),
    );
    expect(disabled.useGradientBackground, isFalse);
    expect(disabled.background, assistant.background);
    expect(Assistant.fromJson({'id': 'a'}).useGradientBackground, isFalse);
  });
  test('static position survives serialization and assistant copies', () {
    final assistant = Assistant(id: 'a', name: 'A').copyWith(
      useGradientBackground: true,
      gradientBackgroundAnimated: false,
      gradientBackgroundPhase: 7.25,
      gradientBackgroundOffsetX: -0.4,
      gradientBackgroundOffsetY: 0.7,
    );
    final restored = Assistant.fromJson(assistant.toJson()).copyWith(id: 'b');
    expect(restored.gradientBackgroundAnimated, isFalse);
    expect(restored.gradientBackgroundPhase, 7.25);
    expect(restored.gradientBackgroundOffsetX, -0.4);
    expect(restored.gradientBackgroundOffsetY, 0.7);
    expect(
      Assistant.fromJson({
        'id': 'c',
        'gradientBackgroundOffsetX': 5,
      }).gradientBackgroundOffsetX,
      1,
    );
  });
  test('malformed gradient values fall back to defaults', () {
    final restored = Assistant.fromJson({
      'id': 'a',
      'gradientBackgroundPhase': double.infinity,
      'gradientBackgroundOffsetX': double.nan,
      'gradientBackgroundOffsetY': -7,
    });
    expect(
      restored.gradientBackgroundPhase,
      Assistant.defaultGradientBackgroundPhase,
    );
    // Non-finite offsets fall back to 0; finite ones clamp to [-1, 1].
    expect(restored.gradientBackgroundOffsetX, 0);
    expect(restored.gradientBackgroundOffsetY, -1);
  });
  test('non-bool gradient flags fall back to defaults', () {
    final restored = Assistant.fromJson({
      'id': 'a',
      'useGradientBackground': 1,
      'gradientBackgroundAnimated': 'true',
    });
    expect(restored.useGradientBackground, isFalse);
    expect(restored.gradientBackgroundAnimated, isTrue);
    // Same guard through the SQLite blob storage codec.
    final fromBlob = Assistant.fromJson({
      'id': 'a',
      ...Assistant.decodeGradientBackgroundStorage(
        '{"useGradientBackground":1,"gradientBackgroundAnimated":"false"}',
      ),
    });
    expect(fromBlob.useGradientBackground, isFalse);
    expect(fromBlob.gradientBackgroundAnimated, isTrue);
  });
  test('gradient storage blob round-trips and tolerates malformed input', () {
    final assistant = Assistant(id: 'a', name: 'A').copyWith(
      useGradientBackground: true,
      gradientBackgroundAnimated: false,
      gradientBackgroundPhase: 4.5,
      gradientBackgroundOffsetX: 0.25,
      gradientBackgroundOffsetY: -0.5,
    );
    final restored = Assistant.fromJson({
      'id': 'a',
      ...Assistant.decodeGradientBackgroundStorage(
        jsonEncode(assistant.gradientBackgroundToJson()),
      ),
    });
    expect(restored.useGradientBackground, isTrue);
    expect(restored.gradientBackgroundAnimated, isFalse);
    expect(restored.gradientBackgroundPhase, 4.5);
    expect(restored.gradientBackgroundOffsetX, 0.25);
    expect(restored.gradientBackgroundOffsetY, -0.5);
    expect(Assistant.decodeGradientBackgroundStorage(null), isEmpty);
    expect(Assistant.decodeGradientBackgroundStorage('not json'), isEmpty);
    expect(Assistant.decodeGradientBackgroundStorage('[1,2]'), isEmpty);
  });
}
