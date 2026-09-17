import 'package:Cuplivo/core/models/chat_message.dart';
import 'package:Cuplivo/core/models/message_quote.dart';
import 'package:Cuplivo/features/chat/widgets/quote_block.dart';
import 'package:Cuplivo/l10n/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _harness(Widget child) {
  return MaterialApp(
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: Scaffold(body: child),
  );
}

ChatMessage _target(String content) => ChatMessage(
  id: 'target-1',
  role: 'assistant',
  content: content,
  conversationId: 'c1',
);

void main() {
  group('QuoteBlock', () {
    testWidgets('id-only quote renders clipped plain text of the target', (
      tester,
    ) async {
      final long = ('word ' * 60).trim();
      await tester.pumpWidget(
        _harness(
          QuoteBlock(
            quote: const MessageQuote(id: 'target-1'),
            target: _target(long),
          ),
        ),
      );

      final text = tester.widget<Text>(find.byType(Text).last).data!;
      expect(text, startsWith('word word'));
      expect(text.endsWith('…'), isTrue);
    });

    testWidgets('markdown markers are stripped from the display text', (
      tester,
    ) async {
      await tester.pumpWidget(
        _harness(
          QuoteBlock(
            quote: const MessageQuote(id: 'target-1'),
            target: _target('# **Hello** world'),
          ),
        ),
      );

      expect(find.text('Hello world'), findsOneWidget);
    });

    testWidgets('null target renders the localized deleted stub', (
      tester,
    ) async {
      await tester.pumpWidget(
        _harness(
          QuoteBlock(quote: const MessageQuote(id: 'gone'), target: null),
        ),
      );

      expect(
        find.text('The original message has been deleted'),
        findsOneWidget,
      );
    });

    testWidgets('ranged quote highlights the span inside a window', (
      tester,
    ) async {
      const word = 'quick brown fox jumps over the lazy dog ';
      final body = (word * 10).trim();
      // Target the LAST occurrence so the ranged window actually truncates
      // pre/post context (a mid-text span within the budget renders whole).
      final start = body.lastIndexOf('lazy');
      final end = start + 'lazy'.length;
      await tester.pumpWidget(
        _harness(
          QuoteBlock(
            quote: MessageQuote(id: 'target-1', start: start, end: end),
            target: _target(body),
          ),
        ),
      );

      final rich = tester.widget<RichText>(find.byType(RichText).last);
      final highlighted = <String>[];
      void walk(InlineSpan span) {
        if (span is TextSpan && span.style?.backgroundColor != null) {
          highlighted.add(span.toPlainText());
        }
        if (span is TextSpan) {
          for (final child in span.children ?? const <InlineSpan>[]) {
            walk(child);
          }
        }
      }

      walk(rich.text);
      expect(highlighted, contains('lazy'));
    });
  });
}
