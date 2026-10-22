import 'package:Cuplivo/core/models/chat_message.dart';
import 'package:Cuplivo/core/models/message_quote.dart';
import 'package:Cuplivo/core/providers/settings_provider.dart';
import 'package:Cuplivo/features/chat/widgets/quote_citation.dart';
import 'package:Cuplivo/l10n/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import '../../../support/business_test_harness.dart';

/// Counts one settings read the Markdown walk performs, so "did this rebuild
/// re-walk the whole citation" is observable without a debug hook in production
/// code. `enableDollarLatex` is read exactly once per walk and once per build by
/// the label cache's key.
class _CountingSettings extends SettingsProvider {
  _CountingSettings(super.preferences, {this.dollarLatex});

  final bool? dollarLatex;
  int dollarReads = 0;

  @override
  bool get enableDollarLatex {
    dollarReads++;
    return dollarLatex ?? super.enableDollarLatex;
  }
}

/// The citation chip's cost model (docs/adr/0012).
///
/// Deriving the one-line label walks the whole quoted message through the
/// Markdown IR — milliseconds on a long answer — while a bubble is rebuilt on
/// every stream publish (the timeline debounces at 50 ms, i.e. 20 Hz). The chip
/// therefore derives it once per citation, not once per build; these tests pin
/// both halves of that: a rebuild is free, and a settings change is not ignored.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  /// ~24 KB of ordinary markdown, the shape a whole-message reply quotes.
  final longMarkdown = List.generate(
    120,
    (index) =>
        '## Section $index\n\n'
        'Paragraph $index with **bold**, a `code span`, a [link](https://x.test) '
        'and enough prose to be a realistic paragraph of an answer.\n\n',
  ).join();

  Future<void> pumpChip(
    WidgetTester tester, {
    required SettingsProvider settings,
    required String content,
  }) async {
    await tester.pumpWidget(
      ChangeNotifierProvider<SettingsProvider>.value(
        value: settings,
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: QuoteCitation(
              quote: const MessageQuote(id: 'message-0'),
              target: ChatMessage(
                id: 'message-0',
                role: 'assistant',
                content: content,
                conversationId: 'conversation-1',
              ),
            ),
          ),
        ),
      ),
    );
  }

  testWidgets('a rebuild does not re-walk the citation', (tester) async {
    final settings = _CountingSettings(createBusinessTestPreferences());
    await pumpChip(tester, settings: settings, content: longMarkdown);
    final afterFirst = settings.dollarReads;
    expect(afterFirst, greaterThan(0), reason: 'the first build derives it');
    expect(find.textContaining('Section 0'), findsOneWidget);

    const rebuilds = 5;
    for (var i = 0; i < rebuilds; i++) {
      await pumpChip(tester, settings: settings, content: longMarkdown);
    }

    // One read per rebuild is the cache key; the walk reads the same setting, so
    // a re-walk would show up as two per rebuild.
    expect(settings.dollarReads - afterFirst, rebuilds);
    expect(find.textContaining('Section 0'), findsOneWidget);
  });

  testWidgets('a setting the walk reads invalidates the cached label', (
    tester,
  ) async {
    final off = _CountingSettings(
      createBusinessTestPreferences(),
      dollarLatex: false,
    );
    await pumpChip(tester, settings: off, content: longMarkdown);
    expect(off.dollarReads, greaterThan(0));

    final on = _CountingSettings(
      createBusinessTestPreferences(),
      dollarLatex: true,
    );
    await pumpChip(tester, settings: on, content: longMarkdown);

    // The key comparison (one read) plus the re-walk it triggers (one more): a
    // cache that ignored the settings would read only once and keep a label the
    // walk would no longer produce.
    expect(on.dollarReads, 2);
  });
}
