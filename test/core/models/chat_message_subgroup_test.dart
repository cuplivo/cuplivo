import 'package:flutter_test/flutter_test.dart';

import 'package:Cuplivo/core/models/chat_message.dart';

void main() {
  group('ChatMessage subgroupId', () {
    test('defaults to null (classic message)', () {
      final m = ChatMessage(
        conversationId: 'c1',
        id: 'm1',
        role: 'user',
        content: 'hi',
      );
      expect(m.subgroupId, isNull);
    });

    test('JSON round-trip preserves the parallel-thread id', () {
      final m = ChatMessage(
        id: 'm1',
        conversationId: 'c1',
        role: 'assistant',
        content: 'hi',
        subgroupId: 'thread-2',
      );
      final restored = ChatMessage.fromJson(m.toJson());
      expect(restored.subgroupId, 'thread-2');
    });

    test('legacy payloads without subgroupId restore as null', () {
      final json = ChatMessage(
        id: 'm1',
        conversationId: 'c1',
        role: 'assistant',
        content: 'hi',
      ).toJson();
      json.remove('subgroupId');
      expect(ChatMessage.fromJson(json).subgroupId, isNull);
    });

    test('copyWith keeps subgroupId when omitted, replaces when set', () {
      final m = ChatMessage(
        id: 'm1',
        conversationId: 'c1',
        role: 'assistant',
        content: 'hi',
        subgroupId: 'a',
      );
      expect(m.copyWith(content: 'x').subgroupId, 'a');
      expect(m.copyWith(subgroupId: 'b').subgroupId, 'b');
    });

    test('independent from groupId (round anchor)', () {
      final m = ChatMessage(
        id: 'm1',
        conversationId: 'c1',
        role: 'assistant',
        content: 'hi',
        groupId: 'round-1',
        subgroupId: 'thread-1',
      );
      expect(m.groupId, isNot(equals(m.subgroupId)));
      expect(m.copyWith(groupId: 'other').subgroupId, 'thread-1');
    });
  });
}
