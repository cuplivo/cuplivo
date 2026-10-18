import 'package:Cuplivo/core/database/app_database.dart';
import 'package:Cuplivo/core/database/chat_database_repository.dart';
import 'package:Cuplivo/core/models/assistant.dart';
import 'package:Cuplivo/core/models/chat_message.dart';
import 'package:Cuplivo/core/models/conversation.dart';
import 'package:Cuplivo/core/models/message_quote.dart';
import 'package:Cuplivo/core/providers/settings_provider.dart';
import 'package:Cuplivo/core/services/chat/chat_service.dart';
import 'package:Cuplivo/features/home/services/message_builder_service.dart';
import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../support/business_test_harness.dart';

class _FakeBuildContext implements BuildContext {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// The live app's own service: `ChatService.getMessages` serves a conversation
/// from its cache, which a test never populates, so every lookup here goes
/// through the paths the reply citation actually has to survive (the request's
/// source list, then the repository).
class _FakeChatService extends ChatService {}

/// The reply citation's resolution rules (docs/adr/0012).
///
/// A citation names a message by row id, and a row id is only meaningful inside
/// its own conversation: the backup *merge* import remaps message ids while
/// copying `extras_json` verbatim (it must, or the conversation fingerprint
/// stops matching and re-merging the same backup imports a second copy), so an
/// imported reply can be left naming an id that its own conversation no longer
/// holds — and that same id still names a row elsewhere on the device.
void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  late AppDatabase database;
  late ChatDatabaseRepository chatRepository;
  late SettingsProvider settings;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    database = AppDatabase(
      NativeDatabase.memory(
        setup: (raw) => raw.execute('PRAGMA foreign_keys = ON;'),
      ),
    );
    chatRepository = ChatDatabaseRepository(database);
    await chatRepository.ensureReady();
    settings = SettingsProvider(createBusinessTestPreferences());
    await settings.loaded;
  });

  tearDown(() async {
    await database.close();
  });

  Future<ChatMessage> putMessage({
    required String id,
    required String conversationId,
    required String role,
    required String content,
    required int messageOrder,
    MessageQuote? quote,
  }) async {
    final message = ChatMessage(
      id: id,
      role: role,
      content: content,
      conversationId: conversationId,
      quote: quote,
      timestamp: DateTime.utc(
        2026,
        8,
        7,
        12,
      ).add(Duration(minutes: messageOrder)),
    );
    await chatRepository.putMessage(message, messageOrder: messageOrder);
    return message;
  }

  Future<void> putConversation(String id) => chatRepository.putConversation(
    Conversation(id: id, title: id, messageIds: const []),
  );

  MessageBuilderService buildService() => MessageBuilderService(
    chatService: _FakeChatService(),
    chatRepository: chatRepository,
    contextProvider: _FakeBuildContext(),
  );

  /// The turn [message] would produce, with [window] as the request's own
  /// source list and [conversationId] as the conversation it is sent in.
  Future<String> assembledTurn({
    required ChatMessage message,
    required List<ChatMessage> window,
    required String conversationId,
  }) async {
    final service = buildService();
    final apiMessages = <Map<String, dynamic>>[
      {
        'role': 'user',
        'content': message.content,
        MessageBuilderService.internalRevisionIdKey: message.id,
      },
    ];
    await service.processUserMessagesForApi(
      apiMessages,
      settings,
      const Assistant(id: 'assistant-1', name: 'Test'),
      conversation: Conversation(id: conversationId, title: conversationId),
      sourceMessages: window,
    );
    return apiMessages.single['content'] as String;
  }

  test(
    'a citation whose id belongs to another conversation never grounds',
    () async {
      await putConversation('conversation-a');
      await putConversation('conversation-b');
      final otherTarget = await putMessage(
        id: 'a-target',
        conversationId: 'conversation-a',
        role: 'assistant',
        content: 'ANOTHER CONVERSATION',
        messageOrder: 0,
      );
      final target = await putMessage(
        id: 'b-target',
        conversationId: 'conversation-b',
        role: 'assistant',
        content: 'THIS CONVERSATION',
        messageOrder: 0,
      );
      // The imported reply: its citation still names the pre-remap id, and the
      // id is live on this device — as a row of a different conversation.
      final reply = await putMessage(
        id: 'b-reply',
        conversationId: 'conversation-b',
        role: 'user',
        content: 'about that?',
        messageOrder: 1,
        quote: MessageQuote(id: otherTarget.id),
      );
      expect(
        (await chatRepository.getMessage(otherTarget.id))?.conversationId,
        'conversation-a',
        reason: 'the global primary-key lookup still finds the other row',
      );

      final turn = await assembledTurn(
        message: reply,
        window: [target, reply],
        conversationId: 'conversation-b',
      );

      expect(turn, 'about that?');
      expect(turn, isNot(contains('<reply-to>')));
      expect(turn, isNot(contains('ANOTHER CONVERSATION')));
    },
  );

  test(
    'a citation grounds on its own conversation outside the window',
    () async {
      await putConversation('conversation-c');
      final target = await putMessage(
        id: 'c-target',
        conversationId: 'conversation-c',
        role: 'assistant',
        content: 'SCROLLED AWAY',
        messageOrder: 0,
      );
      final reply = await putMessage(
        id: 'c-reply',
        conversationId: 'conversation-c',
        role: 'user',
        content: 'what about that?',
        messageOrder: 1,
        quote: MessageQuote(id: target.id),
      );

      final turn = await assembledTurn(
        // The target is not part of the request's own stream: the request loaded
        // only the reply, so the repository has to supply the quoted message.
        message: reply,
        window: [reply],
        conversationId: 'conversation-c',
      );

      expect(turn, '<reply-to>SCROLLED AWAY</reply-to>\n\nwhat about that?');
    },
  );

  test('a frozen prompt is reused with its citation inside it', () async {
    await putConversation('conversation-d');
    final target = await putMessage(
      id: 'd-target',
      conversationId: 'conversation-d',
      role: 'assistant',
      content: 'TARGET',
      messageOrder: 0,
    );
    final reply = await putMessage(
      id: 'd-reply',
      conversationId: 'conversation-d',
      role: 'user',
      content: 'about that?',
      messageOrder: 1,
      quote: MessageQuote(id: target.id),
    );
    const frozen = '<reply-to>TARGET</reply-to>\n\nabout that?';
    await chatRepository.putMessagePrompt(
      revisionId: reply.id,
      conversationId: 'conversation-d',
      payload: frozen,
      carriesMemorySnapshot: false,
    );

    final turn = await assembledTurn(
      message: reply,
      window: [target, reply],
      conversationId: 'conversation-d',
    );

    expect(turn, frozen);
  });
}
