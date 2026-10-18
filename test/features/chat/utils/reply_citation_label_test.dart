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

/// Whether [value] carries a surrogate half with no partner — what a raw
/// `substring` cut can leave behind and what the chip would render as a
/// replacement glyph.
bool _hasLoneSurrogate(String value) {
  for (var i = 0; i < value.length; i++) {
    final unit = value.codeUnitAt(i);
    if (unit >= 0xD800 && unit <= 0xDBFF) {
      final next = i + 1 < value.length ? value.codeUnitAt(i + 1) : 0;
      if (next < 0xDC00 || next > 0xDFFF) return true;
      i++;
    } else if (unit >= 0xDC00 && unit <= 0xDFFF) {
      return true;
    }
  }
  return false;
}

/// The one-line presentation of a reply citation (docs/adr/0012): the
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

    test('the clip never tears a surrogate pair at the budget', () async {
      final settings = await newSettings();
      // 119 code units, then an astral character whose high surrogate lands
      // exactly on index 119 — the last unit the budget keeps. A raw substring
      // cut leaves that half of the pair behind.
      final source = '${'a' * 119}😀 tail';
      final rawCut = source.substring(0, replyCitationLabelBudget);
      expect(
        _hasLoneSurrogate(rawCut),
        isTrue,
        reason: 'the guard would be vacuous without this shape',
      );

      final label = replyCitationLabel(source, settings: settings);

      expect(label.endsWith('…'), isTrue);
      expect(_hasLoneSurrogate(label), isFalse);
      expect(label.length, replyCitationLabelBudget);
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

    testWidgets('a resolved target with no text is no stub', (tester) async {
      // An image-only message, or an answer that is only a tool call: the target
      // resolved and is still tappable, so "Original message unavailable" would
      // assert an absence that is not one. The item's own label is what the
      // composer's preview row shows for the very same citation.
      var jumps = 0;
      await pumpCitation(
        tester,
        QuoteCitation(
          quote: const MessageQuote(id: 'message-0'),
          target: target(content: ''),
          onTap: () => jumps++,
        ),
      );

      expect(find.text('Original message unavailable'), findsNothing);
      expect(find.text('Reply'), findsOneWidget);

      await tester.tap(find.byType(QuoteCitation));
      await tester.pump();
      expect(jumps, 1);
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
