import 'package:Cuplivo/core/models/chat_message.dart';
import 'package:Cuplivo/core/models/message_quote.dart';
import 'package:Cuplivo/core/providers/settings_provider.dart';
import 'package:Cuplivo/features/chat/utils/reply_citation_label.dart';
import 'package:Cuplivo/features/chat/widgets/quote_citation.dart';
import 'package:Cuplivo/l10n/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../support/business_test_harness.dart';

/// The one-line presentation of a reply citation (docs/adr/0011): the
/// renderer's display space, never the raw markdown the model receives.
void main() {
  Future<SettingsProvider> newSettings() async {
    SharedPreferences.setMockInitialValues({});
    final settings = SettingsProvider(createBusinessTestPreferences());
    await settings.loaded;
    return settings;
  }

  Future<void> pumpCitation(WidgetTester tester, Widget citation) async {
    final settings = await newSettings();
    await tester.pumpWidget(
      ChangeNotifierProvider<SettingsProvider>.value(
        value: settings,
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(body: citation),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  ChatMessage target({String content = 'the quoted reply'}) => ChatMessage(
    id: 'message-0',
    role: 'assistant',
    content: content,
    conversationId: 'conversation-1',
  );

  group('replyCitationLabel', () {
    test('is the rendered text, not the markdown', () async {
      final settings = await newSettings();
      expect(
        replyCitationLabel('## Setup\n\nrun **npm ci**', settings: settings),
        'Setup run npm ci',
      );
    });

    test('an empty citation has no label', () async {
      final settings = await newSettings();
      expect(replyCitationLabel('   ', settings: settings), '');
    });

    test('a long citation is clipped for the one line it renders in', () async {
      final settings = await newSettings();
      final long = List.filled(60, 'word').join(' ');
      final label = replyCitationLabel(long, settings: settings);
      expect(label.length, replyCitationLabelBudget + 1);
      expect(label.endsWith('…'), isTrue);
    });
  });

  group('QuoteCitation', () {
    testWidgets('a ranged citation shows its own text with no target', (
      tester,
    ) async {
      // The snapshot is self-sufficient: a target the window cannot resolve
      // must not turn a citation the reply still carries into a stub.
      await pumpCitation(
        tester,
        const QuoteCitation(
          quote: MessageQuote(id: 'message-0', text: '**bold** span'),
        ),
      );

      expect(find.text('bold span'), findsOneWidget);
      expect(find.text('Original message unavailable'), findsNothing);
    });

    testWidgets('a whole-message citation shows the target it resolved', (
      tester,
    ) async {
      await pumpCitation(
        tester,
        QuoteCitation(
          quote: const MessageQuote(id: 'message-0'),
          target: target(),
        ),
      );

      expect(find.text('the quoted reply'), findsOneWidget);
    });

    testWidgets('a whole-message citation with no target shows the stub', (
      tester,
    ) async {
      await pumpCitation(
        tester,
        const QuoteCitation(quote: MessageQuote(id: 'message-0')),
      );

      expect(find.text('Original message unavailable'), findsOneWidget);
    });

    testWidgets('tapping jumps only where a target resolved', (tester) async {
      var jumps = 0;
      await pumpCitation(
        tester,
        QuoteCitation(
          quote: const MessageQuote(id: 'message-0'),
          target: target(),
          onTap: () => jumps++,
        ),
      );
      await tester.tap(find.byType(QuoteCitation));
      await tester.pump();
      expect(jumps, 1);

      // No target means no handler: a stub is not a jump that goes nowhere.
      await pumpCitation(
        tester,
        const QuoteCitation(quote: MessageQuote(id: 'message-0')),
      );
      await tester.tap(find.byType(QuoteCitation));
      await tester.pump();
      expect(jumps, 1);
    });
  });
}
