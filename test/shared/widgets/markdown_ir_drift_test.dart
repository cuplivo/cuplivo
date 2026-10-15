import 'package:Cuplivo/core/providers/settings_provider.dart';
import 'package:Cuplivo/l10n/app_localizations.dart';
import 'package:Cuplivo/shared/widgets/markdown_block_list.dart';
import 'package:Cuplivo/shared/widgets/markdown_line_lexer.dart';
import 'package:Cuplivo/shared/widgets/markdown_with_highlight.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gpt_markdown/custom_widgets/markdown_config.dart';
import 'package:gpt_markdown/gpt_markdown.dart';
import 'package:provider/provider.dart';

import '../../support/business_test_harness.dart';

/// One document the drift check runs over.
///
/// The list is also the coverage of the check itself: every component the
/// surface can claim text with is matched by at least one source here, which is
/// what keeps the equality below from holding vacuously (see the coverage test
/// at the end of this file).
final class _DriftFixture {
  const _DriftFixture(
    this.name,
    this.source, {
    this.expand,
    this.tracksExpansion = false,
    this.streaming = false,
  });

  final String name;
  final String source;

  /// Summary text to tap before selecting, so the same document is measured
  /// with that `<details>` block open.
  final String? expand;

  /// Whether the source carries a `<details>` block whose state is read back.
  final bool tracksExpansion;

  /// Whether the surface renders this source the way a growing reply does.
  /// An unfinished construct only reaches its streaming form this way.
  final bool streaming;
}

const List<_DriftFixture> _fixtures = [
  _DriftFixture(
    'emphasis, inline code and paragraphs',
    '**Bold**, and *italic* with `code`.\n\nSecond paragraph.',
  ),
  _DriftFixture('heading and body', '# Heading\n\nbody text'),
  _DriftFixture(
    'bullet and task lists',
    '- first\n- second\n\n- [x] done\n- [ ] todo',
  ),
  _DriftFixture('ordered list', '1. one\n2. two'),
  _DriftFixture('block quote', '> quoted\n> lines'),
  _DriftFixture('fenced code block', '```dart\nfinal a = 1;\n```'),
  _DriftFixture(
    'image rides along without display text',
    'before![alt](https://example.com/image.png)after',
  ),
  _DriftFixture('horizontal rule contributes no display text', 'a\n\n---\n\nb'),
  // The preprocessor masks code before its own math and tag passes, so a fence
  // body reaches the code view verbatim. Removing the fence fast path did not
  // make that masking redundant: with it disabled the body's dollars come back
  // as LaTeX.
  // Two blocks with identical text: each keeps its own expansion state, so the
  // document measured with the first one open has to be the one copied.
  _DriftFixture(
    'two identical details, the first opened',
    '<details><summary>More</summary>body</details>\n\n'
        '<details><summary>More</summary>body</details>',
    expand: 'More',
    tracksExpansion: true,
  ),
  _DriftFixture(
    'fence body holding dollars and tags',
    '```text\nprice \$5 and <b>bold</b> and \$x\$\n```',
  ),
  _DriftFixture(
    'unclosed fence body holding dollars and tags',
    '```text\nprice \$5 and <b>bold</b>',
    streaming: true,
  ),
  _DriftFixture('link label', '[label](https://example.com) tail'),
  _DriftFixture(
    'details block',
    '<details><summary>More</summary>hidden body</details>',
  ),
  _DriftFixture(
    'details block that the user expanded',
    '<details><summary>More</summary>hidden body</details>',
    expand: 'More',
    tracksExpansion: true,
  ),
  _DriftFixture(
    'details block that opens by its own attribute',
    '<details open><summary>More</summary>hidden body</details>',
    tracksExpansion: true,
  ),
  _DriftFixture('plain table', '| A | B |\n| --- | --- |\n| 1 | 2 |'),
  _DriftFixture(
    'table cell holding an escaped pipe',
    // A table contributes nothing to the surrounding copy on any platform, so
    // whether its cells split on the escaped pipe never reaches this mapping.
    '| cell \\| pipe | plain |\n| --- | --- |\n| x | y |',
  ),
  _DriftFixture('strikethrough', '~~strike~~'),
  _DriftFixture('underline tag', '<u>under</u>'),
  _DriftFixture('citation chip', 'cite [1] here'),
  _DriftFixture('html anchor', '<a href="https://example.com">site</a>'),
  _DriftFixture('allowed html line break', 'line<br>break'),
  _DriftFixture('backslash-escaped punctuation', r'\*not emphasis\*'),
  _DriftFixture('radio button line', '(x) selected'),
  _DriftFixture('indented continuation line', '- item\n\n  continued'),
  _DriftFixture('dollar inline formula', r'value $x$ here'),
  _DriftFixture('paren inline formula', r'the \(x^2\) value'),
  _DriftFixture('display formula block', '\$\$\nx\n\$\$'),
  _DriftFixture('table nested in emphasis', '**| a | b |\n| - | - |**'),
  // Streaming fixtures: the last construct is unfinished, which is the state a
  // growing reply spends most of its time in.
  _DriftFixture(
    'unclosed fenced code while streaming',
    '```dart\nfinal a = 1;',
    streaming: true,
  ),
  _DriftFixture(
    'closed fence still a gap while streaming',
    '```dart\nfinal a = 1;\n```',
    streaming: true,
  ),
  _DriftFixture(
    'unclosed emphasis while streaming',
    'text **par',
    streaming: true,
  ),
  _DriftFixture(
    'unclosed dollar inline math while streaming',
    r'the value is $x',
    streaming: true,
  ),
  _DriftFixture(
    'unclosed display math while streaming',
    '\$\$\n\\frac{1}{2}',
    streaming: true,
  ),
  _DriftFixture(
    'paragraph then unclosed fence while streaming',
    'intro\n\n```python\nprint(1)',
    streaming: true,
  ),
  _DriftFixture(
    'plain paragraph while streaming',
    'plain streaming text',
    streaming: true,
  ),
];

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
  bool streaming = false,
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
                  streaming: streaming,
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
  if (streaming) {
    // The flag has to have reached the surface: a streaming source renders
    // through the incremental block list, and a source that never got there
    // could satisfy the equality below by rendering as a static document.
    expect(find.byType(MarkdownBlockList), findsOneWidget);
  }
  if (expand != null) {
    // The first match: a document may hold two identical blocks, and then only
    // one of them is being opened.
    await tester.tap(find.text(expand).first);
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
  bool streaming = false,
}) {
  final settings = _settings(tester);
  return MarkdownWithCodeHighlight.markdownDocument(
    source,
    settings: settings,
    streaming: streaming,
    detailsExpansion: expansion,
  );
}

SettingsProvider _settings(WidgetTester tester) =>
    Provider.of<SettingsProvider>(
      tester.element(find.byType(MarkdownWithCodeHighlight)),
      listen: false,
    );

/// The proof that keeps the IR honest: for every surface, the text the
/// framework copies out of the rendered widgets must equal the display space
/// the IR builds for it. A component whose display text drifts from what it
/// renders turns this red instead of quietly mis-mapping a selection.
Future<void> _expectDisplaySpaceMatchesCopy(
  WidgetTester tester,
  String source, {
  String? expand,
  MarkdownDetailsExpansion? expansion,
  bool streaming = false,
}) async {
  final copied = await _copiedText(
    tester,
    source,
    expand: expand,
    expansion: expansion,
    streaming: streaming,
  );
  final predicted = _document(
    tester,
    source,
    expansion: expansion,
    streaming: streaming,
  );
  expect(
    normalizeDisplayText(copied),
    predicted.displayText,
    reason: 'display space drifted for:\n$source',
  );
}

void main() {
  for (final fixture in _fixtures) {
    testWidgets(fixture.name, (tester) async {
      await _expectDisplaySpaceMatchesCopy(
        tester,
        fixture.source,
        expand: fixture.expand,
        expansion: fixture.tracksExpansion ? MarkdownDetailsExpansion() : null,
        streaming: fixture.streaming,
      );
    });
  }

  testWidgets('details block collapsed again after being read', (tester) async {
    const source = '<details><summary>More</summary>hidden body</details>';
    final expansion = MarkdownDetailsExpansion();
    // Open it, then close it: what the copy mapping reads must follow the
    // widget back, not stay at the state the body was first seen in.
    await _copiedText(tester, source, expand: 'More', expansion: expansion);
    await _copiedText(tester, source, expand: 'More', expansion: expansion);
    await _expectDisplaySpaceMatchesCopy(tester, source, expansion: expansion);
  });

  // Every fixture above asserts that one document's display space is right.
  // That guarantee is only as wide as the fixtures are, so this test pins the
  // width: a component the surface can claim text with, and that no fixture
  // matches, is a component the drift check stopped watching.
  testWidgets('every component the surface can claim text with is covered', (
    tester,
  ) async {
    await _copiedText(tester, 'plain');
    final settings = _settings(tester);
    final set = markdownComponentsFor(
      enableMathRendering: settings.enableMathRendering,
      enableDollarLatex: settings.enableDollarLatex,
      streaming: false,
    );
    final active = <Type>{
      for (final component in [DetailsHtmlMd(), ...set.global, ...set.inline])
        component.runtimeType,
    };

    final hit = <Type>{};
    for (final fixture in _fixtures) {
      // A registry is per document: it binds its placeholder nonce to the
      // first source it rewrites, exactly as a rendered surface does.
      final registry = MarkdownDetailsRegistry(
        enableMath: settings.enableMathRendering,
      );
      // A streaming source is walked with the component set it renders with:
      // the two sets differ only in the fence component's mode, so the walk
      // must not be the place where the flag is dropped.
      final fixtureSet = markdownComponentsFor(
        enableMathRendering: settings.enableMathRendering,
        enableDollarLatex: settings.enableDollarLatex,
        streaming: fixture.streaming,
      );
      MarkdownComponent.walkNodes(
        fixture.source,
        config: GptMarkdownConfig(
          components: [DetailsHtmlMd(registry), ...fixtureSet.global],
          inlineComponents: fixtureSet.inline,
          preprocessBlocks: registry.rewrite,
          streaming: fixture.streaming,
        ),
        onNode: (node, start, end, component, block) =>
            hit.add(component.runtimeType),
      );
    }

    expect(
      hit,
      containsAll(active),
      reason:
          'no fixture reaches: '
          '${active.difference(hit).map((type) => type.toString())}',
    );
    // An empty active set would make the assertion above pass whatever the
    // fixtures do, so the check would stop being one without ever going red.
    expect(active, isNotEmpty);
  });
}
