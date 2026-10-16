import "../../support/business_test_harness.dart";

import 'package:Cuplivo/core/providers/settings_provider.dart';
import 'package:Cuplivo/l10n/app_localizations.dart';
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
  });
}
