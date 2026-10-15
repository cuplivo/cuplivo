import 'package:Cuplivo/core/providers/settings_provider.dart';
import 'package:Cuplivo/l10n/app_localizations.dart';
import 'package:Cuplivo/shared/widgets/markdown_with_highlight.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gpt_markdown/markdown_ir.dart';
import 'package:provider/provider.dart';

import '../../support/business_test_harness.dart';

/// Pumps [source] as an assistant reply and returns the text the framework
/// actually copies when everything is selected.
///
/// [expand] taps that summary first, so the same document is measured with a
/// details block open — the state in which its body is on screen.
Future<String> _copiedText(
  WidgetTester tester,
  String source, {
  String? expand,
  MarkdownDetailsExpansion? expansion,
}) async {
  String selected = '';
  await tester.pumpWidget(
    ChangeNotifierProvider(
      create: (_) => SettingsProvider(createBusinessTestPreferences()),
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: SelectionArea(
            onSelectionChanged: (content) =>
                selected = content?.plainText ?? '',
            child: Align(
              alignment: Alignment.topLeft,
              child: SizedBox(
                width: 420,
                child: MarkdownWithCodeHighlight(
                  text: source,
                  detailsExpansion: expansion,
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  if (expand != null) {
    await tester.tap(find.text(expand));
    await tester.pumpAndSettle();
  }
  final region = tester.state<SelectableRegionState>(
    find.byType(SelectableRegion),
  );
  region.selectAll(SelectionChangedCause.keyboard);
  await tester.pumpAndSettle();
  return selected;
}

/// The display space the IR predicts for the same surface.
MdDocument _document(
  WidgetTester tester,
  String source, {
  MarkdownDetailsExpansion? expansion,
}) {
  final settings = Provider.of<SettingsProvider>(
    tester.element(find.byType(MarkdownWithCodeHighlight)),
    listen: false,
  );
  return MarkdownWithCodeHighlight.markdownDocument(
    source,
    settings: settings,
    streaming: false,
    detailsExpansion: expansion,
  );
}

/// The proof that keeps the IR honest: for every surface, the text the
/// framework copies out of the rendered widgets must equal the display space
/// the IR builds for it. A component whose display text drifts from what it
/// renders turns this red instead of quietly mis-mapping a selection.
Future<void> _expectDisplaySpaceMatchesCopy(
  WidgetTester tester,
  String source, {
  String? expand,
  MarkdownDetailsExpansion? expansion,
}) async {
  final copied = await _copiedText(
    tester,
    source,
    expand: expand,
    expansion: expansion,
  );
  final predicted = _document(tester, source, expansion: expansion);
  expect(
    normalizeDisplayText(copied),
    predicted.displayText,
    reason: 'display space drifted for:\n$source',
  );
}

void main() {
  testWidgets('emphasis, inline code and paragraphs', (tester) async {
    await _expectDisplaySpaceMatchesCopy(
      tester,
      '**Bold**, and *italic* with `code`.\n\nSecond paragraph.',
    );
  });

  testWidgets('heading and body', (tester) async {
    await _expectDisplaySpaceMatchesCopy(tester, '# Heading\n\nbody text');
  });

  testWidgets('bullet and task lists', (tester) async {
    await _expectDisplaySpaceMatchesCopy(
      tester,
      '- first\n- second\n\n- [x] done\n- [ ] todo',
    );
  });

  testWidgets('ordered list', (tester) async {
    await _expectDisplaySpaceMatchesCopy(tester, '1. one\n2. two');
  });

  testWidgets('block quote', (tester) async {
    await _expectDisplaySpaceMatchesCopy(tester, '> quoted\n> lines');
  });

  testWidgets('fenced code block', (tester) async {
    await _expectDisplaySpaceMatchesCopy(tester, '```dart\nfinal a = 1;\n```');
  });

  testWidgets('image rides along without display text', (tester) async {
    await _expectDisplaySpaceMatchesCopy(
      tester,
      'before![alt](https://example.com/image.png)after',
    );
  });

  testWidgets('horizontal rule contributes no display text', (tester) async {
    await _expectDisplaySpaceMatchesCopy(tester, 'a\n\n---\n\nb');
  });

  testWidgets('link label', (tester) async {
    await _expectDisplaySpaceMatchesCopy(
      tester,
      '[label](https://example.com) tail',
    );
  });

  testWidgets('details block', (tester) async {
    await _expectDisplaySpaceMatchesCopy(
      tester,
      '<details><summary>More</summary>hidden body</details>',
    );
  });

  testWidgets('details block that the user expanded', (tester) async {
    const source = '<details><summary>More</summary>hidden body</details>';
    final expansion = MarkdownDetailsExpansion();
    await _expectDisplaySpaceMatchesCopy(
      tester,
      source,
      expand: 'More',
      expansion: expansion,
    );
  });

  testWidgets('details block that opens by its own attribute', (tester) async {
    await _expectDisplaySpaceMatchesCopy(
      tester,
      '<details open><summary>More</summary>hidden body</details>',
      expansion: MarkdownDetailsExpansion(),
    );
  });

  testWidgets('plain table', (tester) async {
    await _expectDisplaySpaceMatchesCopy(
      tester,
      '| A | B |\n| --- | --- |\n| 1 | 2 |',
    );
  });

  testWidgets('table cell holding an escaped pipe', (tester) async {
    // A table contributes nothing to the surrounding copy on any platform, so
    // whether its cells split on the escaped pipe never reaches this mapping.
    await _expectDisplaySpaceMatchesCopy(
      tester,
      '| cell \\| pipe | plain |\n| --- | --- |\n| x | y |',
    );
  });

  testWidgets('details block collapsed again after being read', (tester) async {
    const source = '<details><summary>More</summary>hidden body</details>';
    final expansion = MarkdownDetailsExpansion();
    // Open it, then close it: what the copy mapping reads must follow the
    // widget back, not stay at the state the body was first seen in.
    await _copiedText(tester, source, expand: 'More', expansion: expansion);
    await _copiedText(tester, source, expand: 'More', expansion: expansion);
    await _expectDisplaySpaceMatchesCopy(tester, source, expansion: expansion);
  });
}
