import 'package:Cuplivo/core/models/conversation.dart';
import 'package:Cuplivo/core/services/chat/chat_service.dart';
import 'package:Cuplivo/features/home/controllers/chat_controller.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeChatService extends ChatService {
  final Map<String, int> counts = {};

  @override
  bool isMessageCountKnown(String conversationId) =>
      counts.containsKey(conversationId);

  @override
  int getMessageCount(String conversationId) => counts[conversationId] ?? -1;
}

void main() {
  test('setDraftConversation allows unknown message count', () {
    final chatService = _FakeChatService();
    final controller = ChatController(chatService: chatService);
    final conversation = Conversation(title: 'Draft');

    expect(
      () => controller.setDraftConversation(conversation),
      returnsNormally,
    );
    expect(controller.currentConversation?.id, conversation.id);
  });

  test('setDraftConversation rejects known non-zero count', () {
    final chatService = _FakeChatService();
    final conversation = Conversation(title: 'Persisted');
    chatService.counts[conversation.id] = 2;
    final controller = ChatController(chatService: chatService);

    expect(
      () => controller.setDraftConversation(conversation),
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'message',
          'persisted_conversation_requires_async_open',
        ),
      ),
    );
  });

  test('setDraftConversation allows known zero count', () {
    final chatService = _FakeChatService();
    final conversation = Conversation(title: 'Empty');
    chatService.counts[conversation.id] = 0;
    final controller = ChatController(chatService: chatService);

    expect(
      () => controller.setDraftConversation(conversation),
      returnsNormally,
    );
  });
}
