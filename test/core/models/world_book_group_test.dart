import 'package:flutter_test/flutter_test.dart';

import 'package:Cuplivo/core/models/world_book.dart';

void main() {
  group('WorldBook group', () {
    test('defaults to ungrouped', () {
      const book = WorldBook(id: 'b1');
      expect(book.group, '');
    });

    test('round-trips through the backup codec', () {
      const book = WorldBook(id: 'b1', name: 'Lore', group: 'Fantasy');
      final json = book.toJson();
      expect(json['group'], 'Fantasy');
      final restored = WorldBook.fromJson(json);
      expect(restored.group, 'Fantasy');
    });

    test('legacy payloads without a group restore as ungrouped', () {
      final restored = WorldBook.fromJson({
        'id': 'b1',
        'name': 'Lore',
        'entries': <Map<String, dynamic>>[],
      });
      expect(restored.group, '');
    });

    test('copyWith keeps group when omitted, replaces when set', () {
      const book = WorldBook(id: 'b1', group: 'A');
      expect(book.copyWith(name: 'x').group, 'A');
      expect(book.copyWith(group: 'B').group, 'B');
      expect(book.copyWith(group: '').group, '');
    });
  });
}
