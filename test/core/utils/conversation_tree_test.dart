import 'package:Cuplivo/core/models/chat_message.dart';
import 'package:Cuplivo/core/utils/conversation_tree.dart';
import 'package:flutter_test/flutter_test.dart';

ChatMessage _message({
  required String id,
  required String content,
  required String conversationId,
  required String? parentMessageId,
  required String groupId,
  required int version,
}) {
  return ChatMessage(
    id: id,
    role: id.startsWith('u') ? 'user' : 'assistant',
    content: content,
    conversationId: conversationId,
    parentMessageId: parentMessageId,
    groupId: groupId,
    version: version,
  );
}

void main() {
  group('ConversationTree', () {
    const conversationId = 'conversation-1';
    final rootGroup = ConversationTree.rootGroupId(conversationId);
    final messages = <ChatMessage>[
      _message(
        id: 'u1',
        content: '1',
        conversationId: conversationId,
        parentMessageId: null,
        groupId: rootGroup,
        version: 0,
      ),
      _message(
        id: 'a2',
        content: '2',
        conversationId: conversationId,
        parentMessageId: 'u1',
        groupId: 'u1',
        version: 0,
      ),
      _message(
        id: 'a3',
        content: '3',
        conversationId: conversationId,
        parentMessageId: 'u1',
        groupId: 'u1',
        version: 1,
      ),
      _message(
        id: 'u4',
        content: '4',
        conversationId: conversationId,
        parentMessageId: null,
        groupId: rootGroup,
        version: 1,
      ),
      _message(
        id: 'a5',
        content: '5',
        conversationId: conversationId,
        parentMessageId: 'u4',
        groupId: 'u4',
        version: 0,
      ),
    ];

    test('edited input only resolves to descendants of that input', () {
      final leaf = ConversationTree.selectLeafForBranch(
        messages: messages,
        branchStart: messages.singleWhere((message) => message.id == 'u4'),
        versionSelections: {rootGroup: 1},
      );

      expect(leaf.id, 'a5');
      expect(
        ConversationTree.pathToRoot(messages, leaf.id)
            .map((message) => message.id),
        ['u4', 'a5'],
      );
    });

    test('original input can switch only among its own regenerated answers', () {
      final leaf = ConversationTree.selectLeafForBranch(
        messages: messages,
        branchStart: messages.singleWhere((message) => message.id == 'u1'),
        versionSelections: {rootGroup: 0, 'u1': 1},
      );

      expect(leaf.id, 'a3');
      expect(
        ConversationTree.pathToRoot(messages, leaf.id)
            .map((message) => message.id),
        ['u1', 'a3'],
      );
    });

    test('next version is scoped to the exact parent', () {
      expect(
        ConversationTree.nextSiblingVersion(
          messages: messages,
          conversationId: conversationId,
          parentMessageId: 'u1',
        ),
        2,
      );
      expect(
        ConversationTree.nextSiblingVersion(
          messages: messages,
          conversationId: conversationId,
          parentMessageId: 'u4',
        ),
        1,
      );
    });

    test('missing parent is not rendered as an orphan branch', () {
      final damaged = _message(
        id: 'a6',
        content: 'damaged',
        conversationId: conversationId,
        parentMessageId: 'does-not-exist',
        groupId: 'does-not-exist',
        version: 0,
      );

      expect(
        ConversationTree.pathToRoot([...messages, damaged], damaged.id)
            .map((message) => message.id),
        isEmpty,
      );
    });

    test('cycle is rejected instead of producing a partial path', () {
      final first = _message(
        id: 'u6',
        content: 'first',
        conversationId: conversationId,
        parentMessageId: 'a7',
        groupId: 'a7',
        version: 0,
      );
      final second = _message(
        id: 'a7',
        content: 'second',
        conversationId: conversationId,
        parentMessageId: 'u6',
        groupId: 'u6',
        version: 0,
      );

      expect(
        ConversationTree.pathToRoot([...messages, first, second], first.id),
        isEmpty,
      );
    });
  });
}
