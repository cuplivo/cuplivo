import 'package:flutter_test/flutter_test.dart';
import 'package:Cuplivo/core/models/chat_input_data.dart';
import 'package:Cuplivo/features/home/controllers/home_view_model.dart';

void main() {
  group('PendingSendQueue', () {
    late PendingSendQueue queue;

    QueuedChatInput queuedFor(String conversationId, String text) {
      return QueuedChatInput(
        conversationId: conversationId,
        // ignore: prefer_const_constructors
        input: ChatInputData(text: text),
      );
    }

    setUp(() {
      queue = PendingSendQueue();
    });

    test('empty queue has no entry', () {
      expect(queue.entryFor('a'), isNull);
    });

    test('tryPut stores one entry per conversation', () {
      final ok = queue.tryPut('a', queuedFor('a', 'hello'));
      expect(ok, isTrue);
      expect(queue.entryFor('a')?.input.text, 'hello');
    });

    test('second put on the same conversation is rejected (no overwrite)', () {
      expect(queue.tryPut('a', queuedFor('a', 'first')), isTrue);
      expect(queue.tryPut('a', queuedFor('a', 'second')), isFalse);
      expect(queue.entryFor('a')?.input.text, 'first');
    });

    test('conversation A and B do not shadow each other', () {
      expect(queue.tryPut('a', queuedFor('a', 'in a')), isTrue);
      expect(queue.tryPut('b', queuedFor('b', 'in b')), isTrue);
      expect(queue.entryFor('a')?.input.text, 'in a');
      expect(queue.entryFor('b')?.input.text, 'in b');
      expect(queue.contains('a'), isTrue);
      expect(queue.contains('b'), isTrue);
    });

    test('remove returns the entry and frees the slot', () {
      queue.tryPut('a', queuedFor('a', 'hello'));
      final removed = queue.remove('a');
      expect(removed?.input.text, 'hello');
      expect(queue.entryFor('a'), isNull);
      expect(queue.contains('a'), isFalse);
      expect(queue.tryPut('a', queuedFor('a', 'again')), isTrue);
    });

    test('uninitialized conversationId entry is absent', () {
      expect(queue.entryFor(null), isNull);
    });
  });
}
