import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:Cuplivo/core/models/chat_message.dart';
import 'package:Cuplivo/core/models/message_quote.dart';
import 'package:Cuplivo/core/providers/settings_provider.dart';
import 'package:Cuplivo/core/providers/user_provider.dart';
import 'package:Cuplivo/features/chat/widgets/chat_message_widget.dart';
import 'package:Cuplivo/features/chat/widgets/quote_citation.dart';
import 'package:Cuplivo/l10n/app_localizations.dart';

import '../../../support/business_test_harness.dart';

/// The citation a sent reply shows above its user bubble ends at the bubble's
/// own right edge (docs/adr/0012).
///
/// A user turn is right-aligned, so a citation box stretched to the bubble's
/// width would strand its icon and text on the far left of a narrow bubble —
/// flush right in the layout, disconnected on screen. The chip therefore hugs
/// its content, capped at the width the bubble itself may reach.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Widget harness(Widget child) => MultiProvider(
    providers: [
      ChangeNotifierProvider(
        create: (_) => SettingsProvider(createBusinessTestPreferences()),
      ),
      ChangeNotifierProvider(
        create: (_) =>
            UserProvider(preferences: createBusinessTestPreferences()),
      ),
    ],
    child: MaterialApp(
      locale: const Locale('en'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(body: child),
    ),
  );

  ChatMessage reply({required MessageQuote quote, String text = 'ok'}) =>
      ChatMessage(
        id: 'user-reply',
        role: 'user',
        content: text,
        conversationId: 'conversation-reply',
        quote: quote,
      );

  Rect citationRect(WidgetTester tester) => tester.getRect(
    find.byKey(const ValueKey('user-message-quote:user-reply')),
  );

  Rect bubbleRect(WidgetTester tester) => tester.getRect(
    find.byKey(const ValueKey('user-message-text-bubble:user-reply')),
  );

  double screenWidth(WidgetTester tester) =>
      tester.view.physicalSize.width / tester.view.devicePixelRatio;

  testWidgets('a short citation hugs the bubble and shares its right edge', (
    tester,
  ) async {
    await tester.pumpWidget(
      harness(
        ChatMessageWidget(
          showUserAvatar: false,
          message: reply(
            quote: const MessageQuote(id: 'target', text: 'short span'),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final citation = citationRect(tester);
    final bubble = bubbleRect(tester);
    expect((citation.right - bubble.right).abs(), lessThan(0.5));
    // Content-hugging, not stretched to the 75% width the bubble may reach.
    expect(citation.width, lessThan(screenWidth(tester) * 0.75 * 0.5));
  });

  testWidgets(
    'a long citation caps at the bubble width and stays flush right',
    (tester) async {
      await tester.pumpWidget(
        harness(
          ChatMessageWidget(
            showUserAvatar: false,
            message: reply(
              quote: MessageQuote(
                id: 'target',
                text: List.filled(400, 'word').join(' '),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final citation = citationRect(tester);
      expect(
        citation.width,
        lessThanOrEqualTo(screenWidth(tester) * 0.75 + 0.5),
      );
      expect((citation.right - bubbleRect(tester).right).abs(), lessThan(0.5));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('a stretched citation box still ends its text at the right', (
    tester,
  ) async {
    // The widget's own contract: wherever a caller boxes it, the citation
    // leans right instead of trusting the box to be content-sized.
    await tester.pumpWidget(
      harness(
        const SizedBox(
          width: 400,
          child: QuoteCitation(
            quote: MessageQuote(id: 'target', text: 'short span'),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      tester.widget<Text>(find.text('short span')).textAlign,
      TextAlign.end,
    );
    expect(tester.getRect(find.text('short span')).right, closeTo(400, 0.5));
  });
}
