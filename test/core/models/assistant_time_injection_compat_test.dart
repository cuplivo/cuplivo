import 'package:flutter_test/flutter_test.dart';

import 'package:Cuplivo/core/models/assistant.dart';

void main() {
  group('Assistant time injection wire compatibility', () {
    test('toJson dual-writes both keys with the same value', () {
      final on = Assistant(id: 'a', name: 'A', enableTimeInjection: true);
      final off = Assistant(id: 'b', name: 'B', enableTimeInjection: false);

      final onJson = on.toJson();
      final offJson = off.toJson();

      expect(onJson['appendCurrentTimeToUserMessage'], isTrue);
      expect(onJson['enableTimeInjection'], isTrue);
      expect(offJson['appendCurrentTimeToUserMessage'], isFalse);
      expect(offJson['enableTimeInjection'], isFalse);
    });

    test('fromJson prefers the new key when both are present', () {
      final a = Assistant.fromJson({
        'id': 'a',
        'name': 'A',
        'appendCurrentTimeToUserMessage': true,
        'enableTimeInjection': false,
      });

      expect(a.enableTimeInjection, isTrue);
    });

    test('fromJson falls back to the legacy key', () {
      final a = Assistant.fromJson({
        'id': 'a',
        'name': 'A',
        'enableTimeInjection': true,
      });

      expect(a.enableTimeInjection, isTrue);
    });

    test('fromJson defaults to false when neither key exists', () {
      final a = Assistant.fromJson({'id': 'a', 'name': 'A'});

      expect(a.enableTimeInjection, isFalse);
    });

    test('decodeList restores a legacy backup with only the old key', () {
      final restored = Assistant.decodeList(
        '[{"id":"legacy","name":"Legacy","enableTimeInjection":true}]',
      );

      expect(restored, hasLength(1));
      expect(restored.first.enableTimeInjection, isTrue);
    });

    test('decodeList restores a new-style backup with the new key', () {
      final restored = Assistant.decodeList(
        '[{\"id\":\"new\",\"name\":\"New\",\"appendCurrentTimeToUserMessage\":true}]',
      );

      expect(restored, hasLength(1));
      expect(restored.first.enableTimeInjection, isTrue);
    });

    test('useIso8601TimeFormat defaults to false', () {
      final a = Assistant(id: 'a', name: 'A');
      final fromJson = Assistant.fromJson({'id': 'a', 'name': 'A'});

      expect(a.useIso8601TimeFormat, isFalse);
      expect(fromJson.useIso8601TimeFormat, isFalse);
    });

    test('toJson round-trips useIso8601TimeFormat', () {
      final on = Assistant(id: 'a', name: 'A', useIso8601TimeFormat: true);
      final off = Assistant(id: 'b', name: 'B', useIso8601TimeFormat: false);

      expect(on.toJson()['useIso8601TimeFormat'], isTrue);
      expect(off.toJson()['useIso8601TimeFormat'], isFalse);
      expect(
        Assistant.fromJson(on.toJson()).useIso8601TimeFormat,
        isTrue,
      );
      expect(
        Assistant.fromJson(off.toJson()).useIso8601TimeFormat,
        isFalse,
      );
    });

    test('copyWith toggles useIso8601TimeFormat independently', () {
      final a = Assistant(id: 'a', name: 'A');

      expect(a.copyWith(useIso8601TimeFormat: true).useIso8601TimeFormat,
          isTrue);
      expect(a.copyWith(useIso8601TimeFormat: false).useIso8601TimeFormat,
          isFalse);
    });
  });
}
