import 'dart:convert';

import 'package:Cuplivo/core/models/chat_message.dart';
import 'package:Cuplivo/core/models/message_quote.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('MessageQuote', () {
    test('round-trips through JSON', () {
      final quote = MessageQuote(id: 'msg-1', start: 3, end: 9);
      final json = jsonDecode(jsonEncode(quote.toJson()));
      final restored = MessageQuote.fromJson(
        (json as Map).cast<String, dynamic>(),
      );
      expect(restored.id, 'msg-1');
      expect(restored.start, 3);
      expect(restored.end, 9);
    });

    test('id-only quote omits null range fields', () {
      final quote = MessageQuote(id: 'msg-1');
      expect(quote.toJson(), {'id': 'msg-1'});
    });

    test('rejects empty id', () {
      expect(
        () => MessageQuote.fromJson(const <String, dynamic>{'id': ''}),
        throwsFormatException,
      );
    });
  });

  group('ChatMessage.quoteJson', () {
    ChatMessage messageWith(String? quoteJson) => ChatMessage(
      role: 'user',
      content: 'reply',
      conversationId: 'c1',
      quoteJson: quoteJson,
    );

    test('parses quote and its range', () {
      final message = messageWith('{"id":"m","start":1,"end":4}');
      final quote = message.quote;
      expect(quote, isNotNull);
      expect(quote!.id, 'm');
      expect(quote.start, 1);
      expect(quote.end, 4);
    });

    test('malformed JSON treated as absent, never throws', () {
      final message = messageWith('{not json');
      expect(message.quote, isNull);
    });

    test('non-map JSON treated as absent', () {
      expect(messageWith('"str"').quote, isNull);
      expect(messageWith('[1,2]').quote, isNull);
    });

    test('copyWith clears quote explicitly (sentinel pattern)', () {
      final message = messageWith('{"id":"m"}');
      expect(message.copyWith(quoteJson: null).quote, isNull);
      expect(message.copyWith().quoteJson, '{"id":"m"}');
    });

    test('toJson/fromJson round-trips quoteJson', () {
      final message = messageWith('{"id":"m","start":2,"end":5}');
      final restored = ChatMessage.fromJson(message.toJson());
      expect(restored.quoteJson, '{"id":"m","start":2,"end":5}');
      expect(restored.quote!.start, 2);
    });
  });
}
