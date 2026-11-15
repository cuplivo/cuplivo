import 'package:flutter_test/flutter_test.dart';

import 'package:Cuplivo/core/models/memory_entry.dart';
import 'package:Cuplivo/core/models/user_profile_field.dart';

void main() {
  group('MemoryEntry.normalizeContent', () {
    test('trims, collapses whitespace, and lowercases', () {
      expect(MemoryEntry.normalizeContent('  Hello\n\tWORLD  '), 'hello world');
      expect(MemoryEntry.normalizeContent('A   B\r\nC'), 'a b c');
      expect(MemoryEntry.normalizeContent(' already '), 'already');
    });
  });

  group('MemoryEntry payload', () {
    test('toPayload omits contentNormalized and uses microsecond epochs', () {
      final created = DateTime.utc(2026, 8, 6, 12, 1, 20, 0, 106);
      final updated = DateTime.utc(2026, 8, 7, 12, 1, 20, 0, 106);
      final entry = MemoryEntry(
        id: 'mem_a1b2c3d4',
        scope: MemoryScope.global,
        type: MemoryType.workflow,
        content: '用户开发 Flutter 应用时重视跨平台与长列表性能。',
        source: MemorySource.extracted,
        relatedIds: const ['mem_e5f6g7h8'],
        migrationIds: const ['legacy_memory_v1:receipt'],
        createdAt: created,
        updatedAt: updated,
      );
      final payload = entry.toPayload();
      expect(payload.containsKey('contentNormalized'), isFalse);
      expect(payload['createdAt'], created.microsecondsSinceEpoch);
      expect(payload['updatedAt'], updated.microsecondsSinceEpoch);
      expect(payload['scope'], 'global');
      expect(payload['type'], 'workflow');
      expect(payload['status'], 'active');
      expect(payload['source'], 'extracted');

      final roundTrip = MemoryEntry.fromPayload(payload);
      expect(roundTrip.id, entry.id);
      expect(roundTrip.scope, entry.scope);
      expect(roundTrip.type, entry.type);
      expect(roundTrip.content, entry.content);
      expect(roundTrip.relatedIds, entry.relatedIds);
      expect(roundTrip.migrationIds, entry.migrationIds);
      expect(
        roundTrip.createdAt.microsecondsSinceEpoch,
        entry.createdAt.microsecondsSinceEpoch,
      );
      expect(
        roundTrip.updatedAt.microsecondsSinceEpoch,
        entry.updatedAt.microsecondsSinceEpoch,
      );
    });

    test('newId uses mem_ + 8 hex chars', () {
      final id = MemoryEntry.newId();
      expect(id, matches(RegExp(r'^mem_[0-9a-f]{8}$')));
    });
  });

  group('UserProfileField', () {
    test('isValidKey accepts known and custom keys', () {
      expect(UserProfileField.isValidKey('preferred_name'), isTrue);
      expect(UserProfileField.isValidKey('custom.company'), isTrue);
      expect(UserProfileField.isValidKey('custom.a-b_1'), isTrue);
      expect(UserProfileField.isValidKey('nickname'), isFalse);
      expect(UserProfileField.isValidKey('custom.'), isFalse);
    });

    test('payload uses id for key', () {
      final field = UserProfileField(
        key: 'preferred_name',
        value: 'Psyche',
        source: MemorySource.tool,
        updatedAt: DateTime.fromMicrosecondsSinceEpoch(1786012880106000),
      );
      final payload = field.toPayload();
      expect(payload['id'], 'preferred_name');
      expect(payload['value'], 'Psyche');
      expect(payload['source'], 'tool');
      expect(UserProfileField.fromPayload(payload).key, 'preferred_name');
    });
  });
}
