import "../../support/business_test_harness.dart";

import 'package:Cuplivo/core/providers/settings_provider.dart';
import 'package:Cuplivo/l10n/app_localizations.dart';
import 'dart:io';

import 'package:Cuplivo/shared/widgets/markdown_with_highlight.dart';
import 'package:Cuplivo/shared/widgets/sanitizing_selection_area.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gpt_markdown/gpt_markdown.dart';
import 'package:provider/provider.dart';

/// The renderer only inserts soft-break ZWSPs into inline code segments of
/// 60+ chars (every 24 chars, see `_softBreakInline`).
final String _longToken = 'a' * 61;

Future<Widget> _harness(Widget child) async {
  final harness = await createBusinessTestHarness();
  addTearDown(harness.close);
  final settings = SettingsProvider(harness.preferences);
  await settings.loaded;
  return ChangeNotifierProvider<SettingsProvider>.value(
    value: settings,
    child: MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(
        body: Align(
          alignment: Alignment.topLeft,
          child: SanitizingSelectionArea(child: child),
        ),
      ),
    ),
  );
}

/// A desktop table: `useCompactTable` is false there, so its cells are
/// selectable.
void _forceDesktopTables() {
  markdownTableTargetPlatformOverride = TargetPlatform.windows;
  addTearDown(() => markdownTableTargetPlatformOverride = null);
}

/// The paragraph whose plain text contains [text].
Finder _paragraphContaining(String text) => find
    .byWidgetPredicate(
      (widget) =>
          widget is RichText && widget.text.toPlainText().contains(text),
    )
    .first;

/// A mouse drag from one point to another, which is how a selection is made on
/// desktop (a touch drag would scroll or long-press instead).
Future<void> _dragSelection(WidgetTester tester, Offset from, Offset to) async {
  final gesture = await tester.startGesture(
    from,
    kind: PointerDeviceKind.mouse,
  );
  await tester.pump(const Duration(milliseconds: 20));
  await gesture.moveTo(to);
  await tester.pump(const Duration(milliseconds: 20));
  await gesture.up();
  await tester.pumpAndSettle();
}

/// Copies the current selection from the focused owner, as the keyboard
/// shortcut does.
Future<String?> _copySelection(
  WidgetTester tester,
  _ClipboardRecorder recorder,
) async {
  final focus = FocusManager.instance.primaryFocus!;
  Actions.invoke(focus.context!, CopySelectionTextIntent.copy);
  await tester.pumpAndSettle();
  return recorder.copiedText();
}

class _ClipboardRecorder {
  final List<MethodCall> calls = <MethodCall>[];

  void install(WidgetTester tester) {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      calls.add(call);
      return null;
    });
    addTearDown(() {
      messenger.setMockMethodCallHandler(SystemChannels.platform, null);
    });
  }

  String? copiedText() {
    for (final call in calls.reversed) {
      if (call.method == 'Clipboard.setData') {
        return (call.arguments as Map<Object?, Object?>)['text'] as String?;
      }
    }
    return null;
  }

  String? sharedText() {
    for (final call in calls.reversed) {
      if (call.method == 'Share.invoke') {
        return call.arguments as String?;
      }
    }
    return null;
  }
}

/// The nested selection owners a source file creates for itself: a
/// `SelectableText` or a `SelectionArea` of its own.
int _nestedOwners(String source) => RegExp(
  r'SelectableText(\.rich)?\(|SelectionArea\(',
).allMatches(source).length;

/// How many of a source file's nested owners report the claim.
int _claims(String source) =>
    RegExp(r'reportNestedSelectionClaimed\(').allMatches(source).length;

void main() {
  group('stripRendererInsertedCharacters', () {
    test('removes the soft breaks the renderer inserts', () {
      expect(stripRendererInsertedCharacters('a\u200Bb\u200Bc'), 'abc');
      expect(stripRendererInsertedCharacters(''), '');
    });

    test('keeps a zero-width non-joiner, which is orthography', () {
      // The enumerated-heading disambiguator that used to write U+200C is gone
      // — a heading body is walked with the inline components — so every ZWNJ
      // left in copied text is one a user wrote.
      expect(stripRendererInsertedCharacters('می\u200Cرود'), 'می\u200Cرود');
      expect(stripRendererInsertedCharacters('1.\u200C引言'), '1.\u200C引言');
    });

    test('keeps other invisible characters', () {
      // ZWNJ, ZWJ, LRM, RLM, BOM, soft hyphen, word joiner, invisible plus.
      const others = [
        0x200c,
        0x200d,
        0x200e,
        0x200f,
        0xfeff,
        0x00ad,
        0x2060,
        0x2064,
      ];
      final input = String.fromCharCodes(others);
      expect(stripRendererInsertedCharacters('x${input}y'), 'x${input}y');
    });

    test('keeps emoji ZWJ sequences intact', () {
      const womanTechnologist = '\u{1F469}\u200D\u{1F4BB}';
      const prideFlag = '\u{1F3F3}\uFE0F\u200D\u{1F308}';
      expect(
        stripRendererInsertedCharacters('coding $womanTechnologist $prideFlag'),
        'coding $womanTechnologist $prideFlag',
      );
    });

    test('keeps visible content intact', () {
      expect(
        stripRendererInsertedCharacters('plain text\nsecond line • \u{1F600}'),
        'plain text\nsecond line • \u{1F600}',
      );
    });
  });

  group('SanitizingSelectionArea', () {
    testWidgets('keyboard copy strips renderer-inserted zero-width breaks', (
      tester,
    ) async {
      final recorder = _ClipboardRecorder()..install(tester);
      await tester.pumpWidget(
        await _harness(
          MarkdownWithCodeHighlight(text: 'Head `$_longToken` tail'),
        ),
      );
      await tester.pumpAndSettle();

      // Fixture sanity: the renderer really inserted soft-break ZWSPs.
      final codeText = tester.widget<Text>(find.textContaining('a' * 12));
      expect(codeText.data, isNotNull);
      expect(codeText.data!, contains('\u200B'));

      final context = tester.element(find.byType(MarkdownWithCodeHighlight));
      Actions.invoke(
        context,
        const SelectAllTextIntent(SelectionChangedCause.keyboard),
      );
      await tester.pump();
      Actions.invoke(context, CopySelectionTextIntent.copy);
      await tester.pump();

      expect(recorder.copiedText(), 'Head $_longToken tail');
    });

    testWidgets('keyboard copy without selection writes nothing', (
      tester,
    ) async {
      final recorder = _ClipboardRecorder()..install(tester);
      await tester.pumpWidget(await _harness(const Text('plain')));
      await tester.pumpAndSettle();

      final context = tester.element(find.text('plain'));
      Actions.invoke(context, CopySelectionTextIntent.copy);
      await tester.pump();

      expect(recorder.copiedText(), isNull);
    });

    testWidgets('toolbar Copy button copies sanitized text', (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      final recorder = _ClipboardRecorder()..install(tester);
      const display = 'before \u200Btarget after';
      await tester.pumpWidget(await _harness(const Text(display)));
      await tester.pumpAndSettle();

      final context = tester.element(find.text(display));
      Actions.invoke(
        context,
        const SelectAllTextIntent(SelectionChangedCause.keyboard),
      );
      await tester.pump();

      // Right-click on the selection keeps it and opens the default toolbar.
      await tester.tap(find.text(display), buttons: kSecondaryButton);
      await tester.pumpAndSettle();

      await tester.tap(find.text('Copy'));
      await tester.pumpAndSettle();

      expect(recorder.copiedText(), 'before target after');
      debugDefaultTargetPlatformOverride = null;
    });

    testWidgets('toolbar Share button shares sanitized text', (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      final recorder = _ClipboardRecorder()..install(tester);
      const display = 'before \u200Btarget after';
      await tester.pumpWidget(await _harness(const Text(display)));
      await tester.pumpAndSettle();

      final context = tester.element(find.text(display));
      Actions.invoke(
        context,
        const SelectAllTextIntent(SelectionChangedCause.keyboard),
      );
      await tester.pump();

      await tester.tap(find.text(display), buttons: kSecondaryButton);
      await tester.pumpAndSettle();

      await tester.tap(find.text('Share'));
      await tester.pumpAndSettle();

      expect(recorder.sharedText(), 'before target after');
      debugDefaultTargetPlatformOverride = null;
    });

    testWidgets('a nested selectable copies through the framework, not us', (
      tester,
    ) async {
      // Recorded limitation, not a wish. While a *nested* selectable owns the
      // selection we cannot read it — `SelectableRegionState` exposes no public
      // selection getter, and an ancestor cannot reach an [EditableText]'s
      // state — so the copy override stands down and the framework copies the
      // text it owns, un-sanitized. The one owner the app still nests is a
      // diagram's code view (ADR-0010), whose text is the diagram source and
      // carries nothing to strip; a caller that nests a selectable of its own
      // without reporting owes this same shape (ADR-0009 decision 5).
      final recorder = _ClipboardRecorder()..install(tester);
      const display = 'before\u200Btarget after';
      await tester.pumpWidget(
        await _harness(const SelectableText.rich(TextSpan(text: display))),
      );
      await tester.pumpAndSettle();

      final rect = tester.getRect(find.byType(SelectableText));
      final gesture = await tester.startGesture(
        Offset(rect.left + 2, rect.center.dy),
        kind: PointerDeviceKind.mouse,
      );
      await tester.pump(const Duration(milliseconds: 20));
      await gesture.moveTo(Offset(rect.right - 2, rect.center.dy));
      await tester.pump(const Duration(milliseconds: 20));
      await gesture.up();
      await tester.pumpAndSettle();

      final focus = FocusManager.instance.primaryFocus!;
      Actions.invoke(focus.context!, CopySelectionTextIntent.copy);
      await tester.pumpAndSettle();

      expect(recorder.copiedText(), 'before\u200Btarget after');
    });

    testWidgets('a code block copies its code, and a part of it on request', (
      tester,
    ) async {
      // The block is a paragraph of this widget's own selection owner, so a
      // drag inside it selects part of the code, and the copy reaches our
      // sanitizing path with the code the block shows.
      final recorder = _ClipboardRecorder()..install(tester);
      const code = '```dart\nvoid main() { print("hi"); }\n```';
      await tester.pumpWidget(
        await _harness(MarkdownWithCodeHighlight(text: code)),
      );
      await tester.pumpAndSettle();

      final view = find.byType(SelectableHighlightView).first;
      final rect = tester.getRect(view);
      await _dragSelection(
        tester,
        Offset(rect.left + 6, rect.top + 8),
        Offset(rect.right - 6, rect.top + 8),
      );
      expect(
        await _copySelection(tester, recorder),
        'void main() { print("hi"); }',
      );

      // Partial: the first four characters only, which a nested owner could
      // never do from a drag that reaches into the block.
      final paragraphFinder = find
          .descendant(of: view, matching: find.byType(RichText))
          .first;
      final paragraph = tester.renderObject<RenderParagraph>(paragraphFinder);
      final box = tester.getRect(paragraphFinder);
      Offset caret(int offset) {
        final local = paragraph.getOffsetForCaret(
          TextPosition(offset: offset),
          Rect.zero,
        );
        return Offset(box.left + local.dx + 1, box.top + local.dy + 4);
      }

      await _dragSelection(tester, caret(0), caret(4));
      final partial = await _copySelection(tester, recorder);
      debugPrint('CODE PARTIAL COPY: "$partial"');
      expect(partial, 'void');
    });

    testWidgets('a copy of the whole surface leaves the code header out', (
      tester,
    ) async {
      // The header is chrome — the language label among it — and the code block
      // toggle is what keeps it out of a selection. A selection that covers the
      // whole surface therefore copies the code alone.
      final recorder = _ClipboardRecorder()..install(tester);
      await tester.pumpWidget(
        await _harness(
          const MarkdownWithCodeHighlight(text: '```dart\nvoid main() {}\n```'),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('dart'), findsOneWidget);

      final area = find.byType(SanitizingSelectionArea);
      final region = tester.state<SelectableRegionState>(
        find
            .descendant(of: area, matching: find.byType(SelectableRegion))
            .first,
      );
      region.selectAll(SelectionChangedCause.keyboard);
      await tester.pump();

      // Copy from inside the area, which is where the override lives.
      Actions.invoke(
        tester.element(
          find.descendant(of: area, matching: find.byType(SelectionArea)).first,
        ),
        CopySelectionTextIntent.copy,
      );
      await tester.pumpAndSettle();

      final copied = recorder.copiedText();
      debugPrint('CODE CHROME COPY: "$copied"');
      expect(copied, 'void main() {}');
    });

    testWidgets('a table cell copies its inline code, not a placeholder', (
      tester,
    ) async {
      // The reported bug: the cell owned its selection with a nested
      // `SelectableText`, whose edit value holds one U+FFFC where the
      // inline-code chip sits. The clipboard got that character, and the code
      // had no interior position to select into.
      final recorder = _ClipboardRecorder()..install(tester);
      _forceDesktopTables();
      await tester.pumpWidget(
        await _harness(
          const MarkdownWithCodeHighlight(
            text: '| head | second |\n| --- | --- |\n| `code` | tail |',
          ),
        ),
      );
      await tester.pumpAndSettle();

      final table = find.byType(Table);
      expect(
        find.descendant(of: table, matching: find.byType(SelectableText)),
        findsNothing,
        reason: 'a cell must be a paragraph of the enclosing owner',
      );
      final chip = find.descendant(
        of: table,
        matching: find.byKey(const ValueKey('inline-code-surface')),
      );
      expect(chip, findsOneWidget);

      final rect = tester.getRect(chip);
      await _dragSelection(
        tester,
        Offset(rect.left + 2, rect.center.dy),
        Offset(rect.right - 2, rect.center.dy),
      );
      final copied = await _copySelection(tester, recorder);
      debugPrint('TABLE CELL COPY: "$copied"');
      expect(copied, contains('code'));
      expect(copied, isNot(contains('\uFFFC')));
    });

    testWidgets('one drag crosses from one table cell into the next', (
      tester,
    ) async {
      final recorder = _ClipboardRecorder()..install(tester);
      _forceDesktopTables();
      await tester.pumpWidget(
        await _harness(
          const MarkdownWithCodeHighlight(
            text: '| head | second |\n| --- | --- |\n| alpha | bravo |',
          ),
        ),
      );
      await tester.pumpAndSettle();

      final alpha = tester.getRect(_paragraphContaining('alpha'));
      final bravo = tester.getRect(_paragraphContaining('bravo'));
      await _dragSelection(
        tester,
        Offset(alpha.left + 2, alpha.center.dy),
        Offset(bravo.right - 2, bravo.center.dy),
      );
      final copied = await _copySelection(tester, recorder);
      debugPrint('TABLE CELL CROSSING COPY: "$copied"');
      expect(copied, contains('alpha'));
      expect(copied, contains('bravo'));
    });

    testWidgets('a drag across a table copies the cells with the text', (
      tester,
    ) async {
      // The cells are paragraphs of the enclosing owner now, so a selection
      // spanning the table reports their text. (The Markdown form of the same
      // selection is the menu item's path, covered where the bubble wires
      // `SelectionMarkdownMemory`.)
      final recorder = _ClipboardRecorder()..install(tester);
      _forceDesktopTables();
      await tester.pumpWidget(
        await _harness(
          const MarkdownWithCodeHighlight(
            text:
                'before\n\n| head | second |\n| --- | --- |\n'
                '| alpha | bravo |\n\nafter',
          ),
        ),
      );
      await tester.pumpAndSettle();

      // The whole document renders as one paragraph — "before\n\n<U+FFFC>\n\n
      // after", the table embedded as a widget between the two runs — so the
      // spanning drag has to follow the paragraph's own caret geometry.
      final block = find.byType(RichText).first;
      final paragraph = tester.renderObject<RenderParagraph>(block);
      final box = tester.getRect(block);
      final plain = paragraph.text.toPlainText();
      debugPrint(
        'TABLE SPANNING PARAGRAPH: "${plain.replaceAll('\n', r'\n')}"',
      );
      Offset caret(int offset) {
        final local = paragraph.getOffsetForCaret(
          TextPosition(offset: offset),
          Rect.zero,
        );
        return Offset(box.left + local.dx + 1, box.top + local.dy + 6);
      }

      await _dragSelection(tester, caret(0), caret(plain.length));
      final copied = await _copySelection(tester, recorder);
      debugPrint('TABLE SPANNING COPY: "${copied?.replaceAll('\n', r'\n')}"');
      expect(copied, contains('before'));
      expect(copied, contains('after'));
      expect(
        copied,
        contains('alpha'),
        reason: 'the cells must be part of the selection, not a nested owner',
      );
    });
  });

  group('nested selection owners claim from source', () {
    test('every owner a renderer file creates reports the claim', () {
      // ADR-0010's rule is one selection owner per surface, and ADR-0009
      // decision 5 is the other half of it: what a surface's owner cannot reach
      // as text owns its own selection — a diagram's code view, or a block in a
      // surface that provides no owner at all — and reporting the claim is what
      // stands the enclosing area's copy override down. Counting owners against
      // claims is what keeps a new one from being added without that report.
      for (final file in const [
        'lib/shared/widgets/markdown_with_highlight.dart',
        'lib/shared/widgets/plantuml_block.dart',
      ]) {
        final source = File(file).readAsStringSync();
        expect(
          _claims(source),
          _nestedOwners(source),
          reason:
              '$file has ${_nestedOwners(source)} nested selection owners but '
              '${_claims(source)} claims',
        );
      }

      // A diagram's code view is why this is not simply "the renderer nests
      // nothing": it is outside ADR-0010's one-owner rule, exists only once the
      // code tab is selected, and its preview fetches a diagram over the
      // network — so it is a source-level count rather than a widget loop. Its
      // file must keep producing an owner for the comparison above to mean
      // anything there.
      expect(
        _nestedOwners(
          File('lib/shared/widgets/plantuml_block.dart').readAsStringSync(),
        ),
        greaterThan(0),
      );
    });

    testWidgets('an ordinary code block and table nest no owner of their own', (
      tester,
    ) async {
      // The property a source count cannot see: a code body and a table's cells
      // are paragraphs of the surface's owner, so the only region in the tree is
      // the owner's own. A fallback owner is for a surface that provides none,
      // not for these.
      markdownTableTargetPlatformOverride = TargetPlatform.windows;
      addTearDown(() => markdownTableTargetPlatformOverride = null);
      await tester.pumpWidget(
        await _harness(
          const MarkdownWithCodeHighlight(
            text:
                'prose words here\n\n```dart\nvoid main() {}\n```\n\n'
                '| head | second |\n| --- | --- |\n| alpha | bravo |',
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byType(SelectableRegion), findsOneWidget);
      expect(
        find.descendant(
          of: find.byType(SanitizingSelectionArea),
          matching: find.byType(SelectableRegion),
        ),
        findsOneWidget,
        reason: 'the only region is the surface owner\'s own',
      );
    });
  });
}
