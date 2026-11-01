import 'package:flutter_test/flutter_test.dart';

import 'package:Cuplivo/core/models/chat_message.dart';
import 'package:Cuplivo/core/models/compress_context_options.dart';

/// A group's summary is what the next speakers read instead of the turns it
/// replaced, so the compression source has to keep the voices apart.
void main() {
  ChatMessage message(
    String id,
    String role,
    String content, {
    String? senderId,
  }) {
    return ChatMessage(
      id: id,
      role: role,
      content: content,
      timestamp: DateTime.utc(2026),
      conversationId: 'c1',
      senderId: senderId,
    );
  }

  final messages = [
    message('u1', 'user', 'who is reading chapter three?'),
    message('a1', 'assistant', 'I am.', senderId: 'alice'),
    message('a2', 'assistant', 'So am I.', senderId: 'bob'),
  ];
  String labelOf(ChatMessage m) => m.role == 'assistant'
      ? switch (m.senderId) {
          'alice' => 'Alice',
          'bob' => 'Bob',
          _ => 'Assistant',
        }
      : 'User';

  test('a reply with no labeller is an anonymous Assistant', () {
    expect(conversationLineForCompression(messages[1], quoteMarker: (index) => '[$index]',), 'Assistant: I am.');
  });

  test('the labeller names each speaker', () {
    expect(
      conversationLineForCompression(messages[1], quoteMarker: (index) => '[$index]', labelOf: labelOf),
      'Alice: I am.',
    );
  });

  test('both chunked windows carry the names', () {
    final chunked = chunkMessagesForCompression(
      messages,
      maxChars: 4000,
      quoteMarker: (index) => '[$index]',
      labelOf: labelOf,
    ).join('\n\n');
    expect(chunked, contains('Alice: I am.'));
    expect(chunked, contains('Bob: So am I.'));
    expect(chunked, isNot(contains('Assistant: I am.')));

    for (final mode in [
      CompressContextLimitMode.start,
      CompressContextLimitMode.recent,
    ]) {
      final bounded = buildBoundedConversationText(
        messages,
        mode: mode,
        maxChars: 4000,
        quoteMarker: (index) => '[$index]',
        labelOf: labelOf,
      );
      expect(bounded, contains('Alice: I am.'), reason: '$mode');
      expect(bounded, isNot(contains('Assistant: I am.')));
    }
  });
}
