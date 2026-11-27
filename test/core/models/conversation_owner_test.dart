import 'package:flutter_test/flutter_test.dart';

import 'package:Cuplivo/core/models/chat_owner.dart';
import 'package:Cuplivo/core/models/conversation.dart';

/// The one answer to "who owns this conversation", asserted where the answer is
/// built rather than through a widget tree: the topic list, the owner highlight,
/// the fallback assistant and the chat backdrop all read this.
void main() {
  bool liveGroup(String id) => id == 'g1';

  String? resolveAssistant(String? id) => id;

  Conversation conversation({String? groupChatId, String? assistantId}) =>
      Conversation(
        title: 'topic',
        assistantId: assistantId,
        extras: {
          if (groupChatId != null) Conversation.groupChatIdKey: groupChatId,
        },
      );

  ChatOwner? ownerOf(Conversation? conversation) => ownerOfConversation(
    conversation,
    isLiveGroup: liveGroup,
    resolveAssistantId: resolveAssistant,
  );

  test(
    'a live group owns its topic, even if an assistant id was left over',
    () {
      expect(
        ownerOf(conversation(groupChatId: 'g1', assistantId: 'a1')),
        const ChatOwner.group('g1'),
      );
    },
  );

  test('a topic whose group row is gone belongs to its assistant', () {
    expect(
      ownerOf(conversation(groupChatId: 'gone', assistantId: 'a1')),
      const ChatOwner.assistant('a1'),
    );
  });

  test('a dead group topic with no resolvable assistant belongs to nobody', () {
    expect(ownerOf(conversation(groupChatId: 'gone')), isNull);
  });

  test('no open conversation belongs to nobody', () {
    expect(ownerOf(null), isNull);
  });

  test('a plain 1:1 belongs to its assistant', () {
    expect(
      ownerOf(conversation(assistantId: 'a1')),
      const ChatOwner.assistant('a1'),
    );
  });

  group('the chat to open after one is deleted', () {
    Conversation topic(String title, {String group = 'g1', DateTime? at}) =>
        Conversation(
          title: title,
          updatedAt: at,
          extras: {Conversation.groupChatIdKey: group},
        );

    Conversation oneToOne(
      String title, {
      String assistant = 'a1',
      DateTime? at,
    }) => Conversation(title: title, assistantId: assistant, updatedAt: at);

    String? nextOf(
      List<Conversation> conversations,
      ChatOwner? scope,
      Set<String> exclude,
    ) => nextConversationAfterDelete(
      conversations,
      scope: scope,
      excludeIds: exclude,
      isLiveGroup: liveGroup,
      resolveAssistantId: resolveAssistant,
    )?.id;

    test('deleting a group topic picks another topic of that group', () {
      final older = topic('older', at: DateTime(2026, 1, 1));
      final gone = topic('gone', at: DateTime(2026, 1, 3));
      // The fallback assistant's newest chat: what the old predicate chose.
      final assistantChat = oneToOne('a1 chat', at: DateTime(2026, 1, 4));

      expect(
        nextOf(
          [assistantChat, gone, older],
          const ChatOwner.group('g1'),
          {gone.id},
        ),
        older.id,
      );
    });

    test('with no topic left the scope has nothing to open', () {
      final gone = topic('gone');
      final assistantChat = oneToOne('a1 chat');

      expect(
        nextOf([assistantChat, gone], const ChatOwner.group('g1'), {gone.id}),
        isNull,
      );
    });

    test('deleting a 1:1 picks that assistant\'s most recent chat', () {
      final older = oneToOne('older', at: DateTime(2026, 1, 1));
      final newer = oneToOne('newer', at: DateTime(2026, 1, 5));
      final other = oneToOne('other assistant', assistant: 'a2');

      expect(
        nextOf(
          [other, older, newer],
          const ChatOwner.assistant('a1'),
          {newer.id},
        ),
        older.id,
      );
      expect(
        nextOf([other, older], const ChatOwner.assistant('a1'), const {}),
        older.id,
      );
    });

    test('a gone chat with no owner has no successor', () {
      expect(nextOf([oneToOne('a1 chat')], null, const {}), isNull);
    });
  });
}
