import 'package:Cuplivo/core/models/assistant.dart';
import 'package:Cuplivo/core/models/conversation.dart';
import 'package:Cuplivo/core/services/chat/chat_context_transforms.dart';
import 'package:flutter_test/flutter_test.dart';

Conversation conversation({
  required String id,
  required String title,
  required DateTime updatedAt,
  String assistantId = 'assistant-1',
  String kind = Conversation.kindNormal,
  String? summary,
}) {
  return Conversation(
    id: id,
    title: title,
    updatedAt: updatedAt,
    assistantId: assistantId,
    conversationKind: kind,
    summary: summary,
  );
}

void main() {
  group('ChatContextTransforms', () {
    test('formats and appends the normal smart-time timestamp', () {
      final timestamp = DateTime(2026, 8, 18, 9, 7, 5);

      expect(
        ChatContextTransforms.appendTimestamp('hello', timestamp),
        'hello\n\n(Tue 26-08-18 09:07:05)',
      );
    });

    test('stripTimestampNote removes the appended note only', () {
      final timestamp = DateTime(2026, 9, 12, 15, 0, 15);
      final appended = ChatContextTransforms.appendTimestamp('战争', timestamp);
      expect(appended, contains('(Sat 26-09-12 15:00:15)'));
      expect(ChatContextTransforms.stripTimestampNote(appended), '战争');

      // No note → untouched; a parenthesized body that is not a timestamp
      // survives.
      expect(ChatContextTransforms.stripTimestampNote('战争'), '战争');
      expect(ChatContextTransforms.stripTimestampNote('战争(见附录)'), '战争(见附录)');
    });

    test('selects the latest ten eligible recent chats', () {
      final base = DateTime(2026, 8, 18);
      final chats = <Conversation>[
        for (var index = 0; index < 12; index++)
          conversation(
            id: 'chat-$index',
            title: 'Chat $index',
            updatedAt: base.add(Duration(days: index)),
          ),
        conversation(
          id: 'current',
          title: 'Current',
          updatedAt: base.add(const Duration(days: 20)),
        ),
        conversation(
          id: 'group',
          title: 'Group',
          updatedAt: base.add(const Duration(days: 21)),
          kind: Conversation.kindGroup,
        ),
        conversation(
          id: 'other-assistant',
          title: 'Other',
          updatedAt: base.add(const Duration(days: 22)),
          assistantId: 'assistant-2',
        ),
        conversation(
          id: 'empty-title',
          title: '   ',
          updatedAt: base.add(const Duration(days: 23)),
        ),
      ];

      final selected = ChatContextTransforms.selectRecentChats(
        chats,
        assistantId: 'assistant-1',
        currentConversationId: 'current',
      );

      expect(selected, hasLength(10));
      expect(selected.map((chat) => chat.id), [
        'chat-11',
        'chat-10',
        'chat-9',
        'chat-8',
        'chat-7',
        'chat-6',
        'chat-5',
        'chat-4',
        'chat-3',
        'chat-2',
      ]);
    });

    test('builds recent-chat references with title and optional summary', () {
      final block = ChatContextTransforms.buildRecentChatsBlock([
        conversation(
          id: 'with-summary',
          title: ' Plans ',
          updatedAt: DateTime(2026, 8, 18),
          summary: 'Pack tonight',
        ),
        conversation(
          id: 'without-summary',
          title: 'Music',
          updatedAt: DateTime(2026, 8, 17),
        ),
      ]);

      expect(block, contains('<conversation>'));
      expect(block, contains('2026-08-18: Plans || Pack tonight'));
      expect(block, contains('2026-08-17: Music'));
      expect(block, endsWith('</recent_chats>\n'));
    });

    test('message limit preserves system and the newest tail', () {
      final messages = <Map<String, dynamic>>[
        {'role': 'system', 'content': 'system'},
        {'role': 'user', 'content': 'old'},
        {'role': 'assistant', 'content': 'middle'},
        {'role': 'user', 'content': 'latest'},
      ];

      ChatContextTransforms.applyMessageLimit(
        messages,
        Assistant(
          id: 'assistant-1',
          name: 'Assistant',
          limitContextMessages: true,
          contextMessageSize: 2,
        ),
      );

      expect(messages.map((message) => message['content']), [
        'system',
        'middle',
        'latest',
      ]);
    });
  });
}
