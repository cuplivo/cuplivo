import 'dart:io';

import 'package:Cuplivo/core/database/chat_database_repository.dart';
import 'package:Cuplivo/core/models/chat_message.dart';
import 'package:Cuplivo/core/models/conversation.dart';
import 'package:Cuplivo/core/models/message_quote.dart';
import 'package:flutter_test/flutter_test.dart';

/// A reply citation rides `message_rows.extras_json` (docs/adr/0012): it has to
/// survive every write path that touches the row, and a copied conversation has
/// to point its citations at the copy's own rows.
void main() {
  late Directory directory;
  late ChatDatabaseRepository repository;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('cuplivo_quote_test_');
    repository = ChatDatabaseRepository.open(
      file: File('${directory.path}/chat.sqlite'),
    );
    await repository.ensureReady();
  });

  tearDown(() async {
    await repository.close();
    await directory.delete(recursive: true);
  });

  Conversation conversation({String id = 'conversation-1'}) =>
      Conversation(id: id, title: 'Conversation');

  ChatMessage message({
    required String id,
    String role = 'user',
    String content = 'text',
    MessageQuote? quote,
    int? reasoningTokens,
    String conversationId = 'conversation-1',
  }) {
    return ChatMessage(
      id: id,
      role: role,
      content: content,
      conversationId: conversationId,
      quote: quote,
      reasoningTokens: reasoningTokens,
    );
  }

  Future<String> rawExtras(
    String messageId, {
    String conversationId = 'conversation-1',
  }) async {
    final rows = await repository.syncReadMessageRows(conversationId);
    return rows.firstWhere((row) => row['id'] == messageId)['extras_json']
        as String;
  }

  test('an inserted citation lands in the row extras and reads back', () async {
    await repository.appendLinearMessageToConversation(
      conversation: conversation(),
      message: message(
        id: 'message-1',
        quote: const MessageQuote(id: 'message-0', text: '**bold** span'),
      ),
    );

    expect(await rawExtras('message-1'), contains('"reply.quote"'));
    final stored = await repository.getMessage('message-1');
    expect(
      stored?.quote,
      const MessageQuote(id: 'message-0', text: '**bold** span'),
    );
  });

  test('a row without a citation carries no reply extras key', () async {
    await repository.appendLinearMessageToConversation(
      conversation: conversation(),
      message: message(id: 'message-1'),
    );

    expect(await rawExtras('message-1'), isNot(contains('reply.quote')));
    expect((await repository.getMessage('message-1'))?.quote, isNull);
  });

  test('token extras and the citation share the column without loss', () async {
    await repository.appendLinearMessageToConversation(
      conversation: conversation(),
      message: message(
        id: 'message-1',
        quote: const MessageQuote(id: 'message-0'),
        reasoningTokens: 11,
      ),
    );
    // A later token write merges onto the row it read; it must not drop the
    // citation, and the citation write must not drop the token key.
    await repository.updateMessageFields('message-1', reasoningTokens: 12);

    final extras = await rawExtras('message-1');
    expect(extras, contains('"reply.quote"'));
    expect(extras, contains('"tokens.reasoning":12'));
    final stored = await repository.getMessage('message-1');
    expect(stored?.quote, const MessageQuote(id: 'message-0'));
    expect(stored?.reasoningTokens, 12);
  });

  test('a new version carries the citation of the row it versions', () async {
    await repository.appendLinearMessageToConversation(
      conversation: conversation(),
      message: message(
        id: 'message-1',
        quote: const MessageQuote(id: 'message-0', text: 'span'),
      ),
    );

    final result = await repository.appendMessageVersion(
      messageId: 'message-1',
      content: 'edited',
    );

    expect(
      result?.message.quote,
      const MessageQuote(id: 'message-0', text: 'span'),
    );
    expect(
      (await repository.getMessage(result!.message.id))?.quote,
      const MessageQuote(id: 'message-0', text: 'span'),
    );
  });

  test('a duplicate remaps its citations onto the copy\'s own rows', () async {
    await repository.appendLinearMessageToConversation(
      conversation: conversation(),
      message: message(id: 'message-1', content: 'original'),
    );
    await repository.appendLinearMessageToConversation(
      conversation: conversation(),
      message: message(
        id: 'message-2',
        content: 'reply',
        quote: const MessageQuote(id: 'message-1', text: 'original'),
      ),
    );

    final duplicate = await repository.duplicateConversation('conversation-1');
    final slots = (await repository.loadLinearMessageWindow(
      conversationId: duplicate!.id,
      fromStart: true,
    )).slots;
    final copiedIds = [for (final slot in slots) slot.revisionId];
    expect(copiedIds, hasLength(2));

    final copiedReply = await repository.getMessage(copiedIds[1]);
    expect(copiedReply?.quote?.id, copiedIds[0]);
    expect(copiedReply?.quote?.text, 'original');
    // The copy's citation can never point back into the source conversation.
    expect(copiedReply?.quote?.id, isNot('message-1'));
  });

  test('a duplicate drops a citation whose target it does not hold', () async {
    await repository.appendLinearMessageToConversation(
      conversation: conversation(),
      message: message(
        id: 'message-1',
        content: 'reply into the void',
        quote: const MessageQuote(id: 'not-in-this-conversation'),
      ),
    );

    final duplicate = await repository.duplicateConversation('conversation-1');
    final slots = (await repository.loadLinearMessageWindow(
      conversationId: duplicate!.id,
      fromStart: true,
    )).slots;

    final copied = await repository.getMessage(slots.single.revisionId);
    expect(copied?.quote, isNull);
    expect(
      await rawExtras(slots.single.revisionId, conversationId: duplicate.id),
      isNot(contains('reply.quote')),
    );
  });

  test(
    'a duplicate keeps a ranged citation whose target it does not hold',
    () async {
      // The span travels with the citation, so the copy can still show it and
      // still send it: dropping it would delete user-authored content that no
      // other rule deletes (docs/adr/0012).
      await repository.appendLinearMessageToConversation(
        conversation: conversation(),
        message: message(
          id: 'message-1',
          content: 'reply into the void',
          quote: const MessageQuote(
            id: 'not-in-this-conversation',
            text: 'the quoted span',
          ),
        ),
      );

      final duplicate = await repository.duplicateConversation(
        'conversation-1',
      );
      final slots = (await repository.loadLinearMessageWindow(
        conversationId: duplicate!.id,
        fromStart: true,
      )).slots;

      final copied = await repository.getMessage(slots.single.revisionId);
      expect(
        copied?.quote,
        const MessageQuote(
          id: 'not-in-this-conversation',
          text: 'the quoted span',
        ),
      );
      expect(
        await rawExtras(slots.single.revisionId, conversationId: duplicate.id),
        contains('reply.quote'),
      );
    },
  );
}
