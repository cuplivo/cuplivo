import 'package:Cuplivo/core/models/chat_item.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('ChatItem.isPinned', () {
    test('defaults to false', () {
      final item = ChatItem(
        id: 'a',
        title: 'Alpha',
        created: DateTime(2026, 1, 1),
      );
      expect(item.isPinned, isFalse);
    });

    test('preserves explicit isPinned through copyWith', () {
      final item = ChatItem(
        id: 'a',
        title: 'Alpha',
        created: DateTime(2026, 1, 1),
        isPinned: true,
      );
      expect(item.isPinned, isTrue);
      expect(item.copyWith(title: 'Beta').isPinned, isTrue);
      expect(item.copyWith(isPinned: false).isPinned, isFalse);
    });
  });
}
