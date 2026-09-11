import 'package:Cuplivo/shared/widgets/plain_text_code_editor.dart';
import 'package:Cuplivo/theme/app_semantic_colors.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:re_editor/re_editor.dart';

/// Tears a harness down without leaving re_editor's one-shot timers behind
/// (mirrors the helper in the prompt-editor settings tests: Re-Editor
/// schedules timers it never cancels).
Future<void> drainEditor(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 200));
  FocusManager.instance.primaryFocus?.unfocus();
  await tester.pump();
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump(const Duration(milliseconds: 200));
}

void main() {
  test('factory preserves CRLF and CR line endings', () {
    final crlf = createPlainTextCodeController('first\r\nlast');
    final cr = createPlainTextCodeController('first\rlast');
    addTearDown(crlf.dispose);
    addTearDown(cr.dispose);

    expect(crlf.options.lineBreak, TextLineBreak.crlf);
    expect(crlf.text, 'first\r\nlast');
    expect(cr.options.lineBreak, TextLineBreak.cr);
    expect(cr.text, 'first\rlast');
  });

  test('mixed line endings resolve to the first break found', () {
    final controller = createPlainTextCodeController('one\r\ntwo\nthree');
    addTearDown(controller.dispose);

    expect(controller.options.lineBreak, TextLineBreak.crlf);
    expect(controller.text, 'one\r\ntwo\r\nthree');
  });

  test('empty prompt round-trips as empty, not a stray newline', () {
    final controller = createPlainTextCodeController('');
    addTearDown(controller.dispose);

    expect(controller.options.lineBreak, TextLineBreak.lf);
    expect(controller.text, '');
  });

  test('factory preserves large LF plain text', () {
    final text = List<String>.generate(
      5000,
      (index) => 'line $index: ${'x' * 80}',
    ).join('\n');
    final controller = createPlainTextCodeController(text);
    addTearDown(controller.dispose);

    expect(controller.options.lineBreak, TextLineBreak.lf);
    expect(controller.text, text);
    expect(controller.lineCount, 5000);
  });

  testWidgets('renders the editor with theme-derived defaults', (tester) async {
    final controller = createPlainTextCodeController('');
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PlainTextCodeEditor(
            controller: controller,
            hint: 'Enter prompt…',
            maxHeight: 300,
          ),
        ),
      ),
    );

    expect(find.byType(PlainTextCodeEditor), findsOneWidget);
    expect(find.byType(CodeEditor), findsOneWidget);

    final editor = tester.widget<CodeEditor>(find.byType(CodeEditor));
    expect(editor.hint, 'Enter prompt…');
    expect(editor.readOnly, isFalse);
    expect(editor.wordWrap, isTrue);
    final context = tester.element(find.byType(PlainTextCodeEditor));
    expect(editor.style?.backgroundColor, context.appColors.surfaceFill);
    expect(tester.takeException(), isNull);

    await drainEditor(tester);
  });

  testWidgets('caps the editor height through maxHeight', (tester) async {
    final controller = createPlainTextCodeController('content');
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PlainTextCodeEditor(controller: controller, maxHeight: 120),
        ),
      ),
    );

    final boxFinder = find.byWidgetPredicate(
      (widget) =>
          widget is ConstrainedBox &&
          widget.constraints.maxHeight == 120 &&
          widget.constraints.minHeight == 0,
    );
    expect(boxFinder, findsOneWidget);
    expect(tester.takeException(), isNull);

    await drainEditor(tester);
  });
}
