import "../../support/business_test_harness.dart";

import 'package:Cuplivo/core/providers/settings_provider.dart';
import 'package:Cuplivo/l10n/app_localizations.dart';
import 'dart:io';

import 'package:Cuplivo/shared/widgets/markdown_with_highlight.dart';
import 'package:Cuplivo/shared/widgets/sanitizing_selection_area.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
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

/// A mouse drag across [finder] at the middle of its first visible line.
Future<void> _dragAcross(WidgetTester tester, Finder finder) async {
  final rect = tester.getRect(finder);
  await _dragSelection(
    tester,
    Offset(rect.left + 2, rect.center.dy),
    Offset(rect.right - 2, rect.center.dy),
  );
}

/// A mouse drag across the first line of [finder], which is where a tall or
/// clipped block is actually on screen.
Future<void> _dragFirstLine(WidgetTester tester, Finder finder) async {
  final rect = tester.getRect(finder);
  await _dragSelection(
    tester,
    Offset(rect.left + 6, rect.top + 8),
    Offset(rect.right - 6, rect.top + 8),
  );
}

/// Selects inside [finder]: the middle of its first visible line when it is tall
/// or clipped, the middle of the box when it is short (a padded cell's text does
/// not start at its own top edge).
Future<void> _dragInside(WidgetTester tester, Finder finder) async {
  final rect = tester.getRect(finder);
  if (rect.height > 60) {
    await _dragFirstLine(tester, finder);
  } else {
    await _dragAcross(tester, finder);
  }
}

/// The selectable whose own text contains [text] — a table cell, whose text is
/// a span rather than `data`.
Finder _selectableContaining(String text) => find.byWidgetPredicate((widget) {
  if (widget is! SelectableText) return false;
  return widget.textSpan?.toPlainText().contains(text) ?? false;
});

/// The keyboard shortcut, dispatched from the focused owner — which is what the
/// framework does.
Future<void> _copyFromFocus(WidgetTester tester) async {
  final focus = FocusManager.instance.primaryFocus!;
  Actions.invoke(focus.context!, CopySelectionTextIntent.copy);
  await tester.pumpAndSettle();
}

/// The region this widget owns.
Finder _ownRegion() => find
    .descendant(
      of: find.byType(SanitizingSelectionArea),
      matching: find.byType(SelectableRegion),
    )
    .first;

/// Copies through this widget's own override, which is also what proves the
/// override is registered — the region's own copy action is overridable and
/// forwards to it, so dispatching from the region's element reaches ours.
Future<void> _copyThroughOverride(WidgetTester tester) async {
  Actions.invoke(tester.element(_ownRegion()), CopySelectionTextIntent.copy);
  await tester.pumpAndSettle();
}

/// Selects everything this region owns and proves it owns that selection,
/// leaving an empty clipboard record. Every nested-owner guard needs this state:
/// the bug they cover is a *stale* selection, so a guard that never held one
/// first would pass by accident.
Future<void> _selectProseFirst(
  WidgetTester tester,
  _ClipboardRecorder recorder,
  String prose,
) async {
  final state = tester.state<SelectableRegionState>(_ownRegion());
  // Clear first: a claim leaves this region's own selection in place, and a
  // re-selection of the *same* text reports no change, so the cache would stay
  // empty.
  state.clearSelection();
  await tester.pumpAndSettle();
  state.selectAll(SelectionChangedCause.keyboard);
  await tester.pumpAndSettle();
  await _copyThroughOverride(tester);
  expect(
    recorder.copiedText(),
    contains(prose),
    reason: 'the region must own a selection before a nested owner takes one',
  );
  recorder.calls.clear();
}

/// A code block past 2048 characters, i.e. one the code view shapes windowed
/// and wraps in a selection area of its own.
String _longCode() =>
    '```dart\n${List.generate(120, (i) => 'final value$i = "x";').join('\n')}\n```';

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

    testWidgets('keyboard copy inside a nested code block copies its text', (
      tester,
    ) async {
      // The markdown renderer nests a SelectableText (short code) or a nested
      // SelectionArea (long code) inside this widget, so that selection belongs
      // to the nested owner and never reaches ours. Without the fallback to the
      // focused owner's selection, this copied nothing at all.
      final recorder = _ClipboardRecorder()..install(tester);
      const code = '```dart\nvoid main() { print("hi"); }\n```';
      await tester.pumpWidget(
        await _harness(MarkdownWithCodeHighlight(text: code)),
      );
      await tester.pumpAndSettle();

      final rect = tester.getRect(find.byType(SelectableHighlightView).first);
      final gesture = await tester.startGesture(
        Offset(rect.left + 6, rect.top + 8),
        kind: PointerDeviceKind.mouse,
      );
      await tester.pump(const Duration(milliseconds: 20));
      await gesture.moveTo(Offset(rect.right - 6, rect.top + 8));
      await tester.pump(const Duration(milliseconds: 20));
      await gesture.up();
      await tester.pumpAndSettle();

      // The framework dispatches the shortcut from the focused widget.
      final focus = FocusManager.instance.primaryFocus!;
      Actions.invoke(focus.context!, CopySelectionTextIntent.copy);
      await tester.pumpAndSettle();

      expect(recorder.copiedText(), 'void main() { print("hi"); }');
    });

    testWidgets('a nested selectable copies through the framework, not us', (
      tester,
    ) async {
      // Recorded limitation, not a wish. While a *nested* selectable owns the
      // selection we cannot read it — `SelectableRegionState` exposes no public
      // selection getter, and an ancestor cannot reach an [EditableText]'s
      // state — so the copy override stands down and the framework copies the
      // text it owns, un-sanitized. A code block carries no renderer-inserted
      // characters; what is left is a table cell's soft-break ZWSPs, which
      // leaked before this branch existed too (ADR-0009).
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

    testWidgets('a nested code block takes the copy back from our selection', (
      tester,
    ) async {
      // Review of this PR: select prose, then select inside the code block, then
      // press Ctrl+C. The block's selection never reaches this region, so a
      // stand-down keyed on "the cache is empty" kept our override registered
      // and the clipboard got the *prose* — where master, which registers no
      // override at all, copies the code. The override now stands down as soon
      // as a nested owner reports a selection.
      final recorder = _ClipboardRecorder()..install(tester);
      await tester.pumpWidget(
        await _harness(
          const MarkdownWithCodeHighlight(
            text:
                'prose words here\n\n```dart\nvoid main() { print("hi"); }\n```',
          ),
        ),
      );
      await tester.pumpAndSettle();

      await _selectProseFirst(tester, recorder, 'prose words here');
      await _dragFirstLine(tester, find.byType(SelectableHighlightView).first);
      await _copyFromFocus(tester);

      expect(recorder.copiedText(), 'void main() { print("hi"); }');
    });

    testWidgets('a long nested code block takes the copy back too', (
      tester,
    ) async {
      // Past 2048 characters the code view is a selection area of its own, and
      // its copy action is overridable in exactly the same way.
      final recorder = _ClipboardRecorder()..install(tester);
      final source = _longCode();
      expect(source.length, greaterThan(2048));
      await tester.pumpWidget(
        await _harness(
          MarkdownWithCodeHighlight(text: 'prose words here\n\n$source'),
        ),
      );
      await tester.pumpAndSettle();

      await _selectProseFirst(tester, recorder, 'prose words here');
      await _dragFirstLine(tester, find.byType(SelectableHighlightView).first);
      await _copyFromFocus(tester);

      final copied = recorder.copiedText();
      expect(copied, isNotNull);
      expect(copied, contains('final value0 = "x";'));
      expect(copied, isNot(contains('prose words here')));
    });

    testWidgets('a table cell takes the copy back from our selection', (
      tester,
    ) async {
      // A desktop table's cells are `SelectableText`s: nested owners on this
      // branch, reached through their own area rather than through the text
      // around them.
      markdownTableTargetPlatformOverride = TargetPlatform.windows;
      addTearDown(() => markdownTableTargetPlatformOverride = null);
      final recorder = _ClipboardRecorder()..install(tester);
      await tester.pumpWidget(
        await _harness(
          const MarkdownWithCodeHighlight(
            text:
                'prose words here\n\n| head | second |\n| --- | --- |\n| alpha | bravo |',
          ),
        ),
      );
      await tester.pumpAndSettle();

      await _selectProseFirst(tester, recorder, 'prose words here');
      await _dragAcross(tester, _selectableContaining('alpha'));
      await _copyFromFocus(tester);

      expect(recorder.copiedText(), 'alpha');
    });

    testWidgets('every nested owner the renderer creates claims the selection', (
      tester,
    ) async {
      // The three guards above name the owners this branch knows about. This one
      // asks the tree, per kind of content, so a component that nests a
      // selectable cannot be added without wiring the claim: an owner that does
      // not claim leaves this area's override registered, and the copy then
      // writes the area's stale text instead of the owner's.
      markdownTableTargetPlatformOverride = TargetPlatform.windows;
      addTearDown(() => markdownTableTargetPlatformOverride = null);
      final recorder = _ClipboardRecorder()..install(tester);
      final corpora = <String, String>{
        'short code': 'prose words here\n\n```dart\nvoid main() {}\n```',
        'long code': 'prose words here\n\n${_longCode()}',
        'table':
            'prose words here\n\n'
            '| head | second |\n| --- | --- |\n| alpha | bravo |',
      };
      var exercised = 0;
      for (final corpus in corpora.entries) {
        await tester.pumpWidget(
          await _harness(MarkdownWithCodeHighlight(text: corpus.value)),
        );
        await tester.pumpAndSettle();
        final regions = find.byType(SelectableRegion).evaluate().length;
        final owners = <String, Finder>{
          // The first region is this area's own; the rest are nested owners.
          for (var i = 1; i < regions; i++)
            '${corpus.key} region $i': find.byType(SelectableRegion).at(i),
          for (
            var i = 0;
            i < find.byType(SelectableText).evaluate().length;
            i++
          )
            '${corpus.key} selectable $i': find.byType(SelectableText).at(i),
        };
        for (final entry in owners.entries) {
          exercised++;
          await _selectProseFirst(tester, recorder, 'prose words here');
          await _dragInside(tester, entry.value);
          await _copyFromFocus(tester);
          final copied = recorder.copiedText();
          expect(
            copied,
            isNotNull,
            reason: '${entry.key} claimed the selection but nothing was copied',
          );
          expect(
            copied,
            isNotEmpty,
            reason: '${entry.key} claimed the selection but copied nothing',
          );
          expect(
            copied,
            isNot(contains('prose words here')),
            reason:
                '${entry.key} left this area answering for its own selection',
          );
        }
      }
      // Four cells, one short code view, one long code region. A corpus that
      // stopped producing owners would make the loop vacuous, so the count is
      // part of the guard.
      expect(exercised, 6);
    });
  });

  group('nested selection owners claim from source', () {
    test('every nested owner in a markdown surface claims the selection', () {
      // The guards above drive the owners this branch knows about; this one asks
      // the renderer's own source, because the property is "every nested owner
      // claims": an owner that appears without a claim leaves the enclosing
      // area's override registered, and a copy inside it then writes the area's
      // stale text. A diagram's code view is why this cannot be a widget loop —
      // it exists only once its code tab is selected, and the preview beside it
      // fetches a diagram over the network.
      for (final file in const [
        'lib/shared/widgets/markdown_with_highlight.dart',
        'lib/shared/widgets/plantuml_block.dart',
      ]) {
        final source = File(file).readAsStringSync();
        final owners = RegExp(
          r'SelectableText(\.rich)?\(|SelectionArea\(',
        ).allMatches(source).length;
        final claims = RegExp(
          r'reportNestedSelectionClaimed\(',
        ).allMatches(source).length;
        expect(
          claims,
          owners,
          reason:
              '$file has $owners nested selection owners but $claims claims',
        );
      }
      // A diagram keeps its own selection area whatever else changes, so its
      // file must keep producing an owner for the equality above to mean
      // anything there.
      expect(
        RegExp(r'SelectableText(\.rich)?\(|SelectionArea\(').allMatches(
          File('lib/shared/widgets/plantuml_block.dart').readAsStringSync(),
        ),
        isNotEmpty,
      );
    });
  });
}
