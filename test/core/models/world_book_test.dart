import 'package:flutter_test/flutter_test.dart';

import 'package:Cuplivo/core/models/world_book.dart';

void main() {
  group('WorldBook group field', () {
    test('defaults to empty group when absent in JSON (old data)', () {
      final book = WorldBook.fromJson(const <String, dynamic>{
        'id': 'b1',
        'name': 'Legacy',
        'entries': <Map<String, dynamic>>[],
      });
      expect(book.group, '');
    });

    test('round-trips the group field through toJson/fromJson', () {
      final book = const WorldBook(
        id: 'b1',
        name: 'Sci-Fi',
        group: '设定集',
        entries: <WorldBookEntry>[],
      );
      final restored = WorldBook.fromJson(book.toJson());
      expect(restored.group, '设定集');
      expect(restored.entries, isEmpty);
    });

    test('copyWith keeps group and can change it', () {
      const original = WorldBook(id: 'b1', group: 'A');
      expect(original.copyWith(group: 'B').group, 'B');
      expect(original.copyWith().group, 'A');
    });
  });
}
