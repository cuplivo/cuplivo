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
}
