import 'package:Cuplivo/core/models/chat_message.dart';
import 'package:Cuplivo/core/models/composer_draft.dart';
import 'package:Cuplivo/core/models/message_quote.dart';
import 'package:flutter_test/flutter_test.dart';

/// The reply citation's persistence and copy shapes (docs/adr/0011).
void main() {
  group('MessageQuote', () {
    test('round-trips a whole-message citation without a text key', () {
      const quote = MessageQuote(id: 'message-1');
      expect(quote.toJson(), {'id': 'message-1'});
      expect(MessageQuote.tryParse(quote.toJson()), quote);
      expect(MessageQuote.tryParse({'id': 'message-1'})?.hasText, isFalse);
    });

    test('round-trips a ranged citation with its snapshot', () {
      const quote = MessageQuote(id: 'message-1', text: '**bold** text');
      expect(quote.toJson(), {'id': 'message-1', 'text': '**bold** text'});
      expect(MessageQuote.tryParse(quote.toJson()), quote);
      expect(quote.hasText, isTrue);
    });

    test('malformed stored values read as no reply, never throw', () {
      expect(MessageQuote.tryParse(null), isNull);
      expect(MessageQuote.tryParse('nonsense'), isNull);
      expect(MessageQuote.tryParse(<String, dynamic>{}), isNull);
      expect(MessageQuote.tryParse({'id': ''}), isNull);
      expect(MessageQuote.tryParse({'id': 7}), isNull);
      // An empty snapshot means "whole message", not a citation of nothing.
      expect(MessageQuote.tryParse({'id': 'm', 'text': ''})?.hasText, isFalse);
      expect(MessageQuote.tryParse({'id': 'm', 'text': 7})?.hasText, isFalse);
    });

    test('reads and writes the row extras key it persists under', () {
      final extras = <String, dynamic>{'tokens.reasoning': 3};
      const quote = MessageQuote(id: 'message-1', text: 'quoted');
      quote.encodeIntoExtras(extras);

      expect(extras[MessageQuote.extrasKey], {
        'id': 'message-1',
        'text': 'quoted',
      });
      expect(MessageQuote.decodeFromExtras(extras), quote);
      // The token side channel is untouched.
      expect(extras['tokens.reasoning'], 3);
      expect(MessageQuote.decodeFromExtras(const {}), isNull);
    });

    test(
      'a copy remaps its target, and drops it when the target is absent',
      () {
        const quote = MessageQuote(id: 'old-1', text: 'quoted');
        expect(
          quote.remapped({'old-1': 'new-1', 'old-2': 'new-2'}),
          const MessageQuote(id: 'new-1', text: 'quoted'),
        );
        expect(quote.remapped({'old-2': 'new-2'}), isNull);
      },
    );
  });

  group('ChatMessage.quote', () {
    test('rides toJson/fromJson so a backup round-trip keeps it', () {
      final message = ChatMessage(
        id: 'message-1',
        role: 'user',
        content: 'what about this?',
        conversationId: 'conversation-1',
        quote: const MessageQuote(id: 'message-0', text: 'quoted span'),
      );
      final restored = ChatMessage.fromJson(message.toJson());
      expect(
        restored.quote,
        const MessageQuote(id: 'message-0', text: 'quoted span'),
      );
    });

    test('a payload written before the feature has no reply', () {
      final message = ChatMessage(
        id: 'message-1',
        role: 'user',
        content: 'plain',
        conversationId: 'conversation-1',
      );
      final json = message.toJson()..remove('quote');
      expect(ChatMessage.fromJson(json).quote, isNull);
      expect(json.containsKey('quote'), isFalse);
    });

    test('a malformed stored quote reads as no reply', () {
      final message = ChatMessage(
        id: 'message-1',
        role: 'user',
        content: 'plain',
        conversationId: 'conversation-1',
      );
      final json = message.toJson()..['quote'] = {'id': ''};
      expect(ChatMessage.fromJson(json).quote, isNull);
    });

    test('a new version keeps the citation it was made under', () {
      final message = ChatMessage(
        id: 'message-1',
        role: 'user',
        content: 'v0',
        conversationId: 'conversation-1',
        quote: const MessageQuote(id: 'message-0'),
      );
      expect(
        message.copyWith(id: 'message-2', content: 'v1').quote,
        const MessageQuote(id: 'message-0'),
      );
    });
  });

  group('ComposerDraftInput', () {
    test('carries the citation and its label through the draft JSON', () {
      const draft = ComposerDraftInput(
        text: 'reply text',
        quote: MessageQuote(id: 'message-0', text: 'quoted span'),
        quoteLabel: 'quoted span',
      );
      final restored = ComposerDraftInput.fromJson(draft.toJson());
      expect(restored.quote, draft.quote);
      expect(restored.quoteLabel, 'quoted span');
      expect(restored.toInput().quote, draft.quote);
    });

    test('a draft written before the feature has no reply', () {
      const draft = ComposerDraftInput(text: 'plain');
      final json = draft.toJson()
        ..remove('quote')
        ..remove('quoteLabel');
      final restored = ComposerDraftInput.fromJson(json);
      expect(restored.quote, isNull);
      expect(restored.quoteLabel, isNull);
    });

    test('copyWith keeps the citation, withoutQuote drops it', () {
      const draft = ComposerDraftInput(
        text: 'a',
        quote: MessageQuote(id: 'message-0'),
        quoteLabel: 'label',
      );
      expect(draft.copyWith(text: 'ab').quote, draft.quote);
      expect(draft.copyWith(text: 'ab').quoteLabel, 'label');
      final cleared = draft.withoutQuote();
      expect(cleared.quote, isNull);
      expect(cleared.quoteLabel, isNull);
      expect(cleared.text, 'a');
    });

    test('a pending citation alone is not sendable content', () {
      const draft = ComposerDraftInput(quote: MessageQuote(id: 'message-0'));
      expect(draft.isEmpty, isTrue);
    });

    test('sameValue sees a changed citation', () {
      const withQuote = ComposerDraftInput(
        text: 'a',
        quote: MessageQuote(id: 'message-0'),
      );
      const other = ComposerDraftInput(
        text: 'a',
        quote: MessageQuote(id: 'message-1'),
      );
      expect(withQuote.sameValue(withQuote.copyWith()), isTrue);
      expect(withQuote.sameValue(other), isFalse);
    });
  });
}
