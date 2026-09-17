import 'package:Cuplivo/features/chat/widgets/tool_detail_text_section.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Widget harness(String label, String text) => MaterialApp(
    home: Scaffold(
      body: SizedBox(
        height: 400,
        child: CustomScrollView(
          slivers: [ToolDetailTextSection(label: label, text: text)],
        ),
      ),
    ),
  );

  testWidgets('small result renders as a single eager text block', (
    tester,
  ) async {
    await tester.pumpWidget(harness('Result', 'short result'));

    expect(find.text('Result'), findsOneWidget);
    expect(find.text('short result'), findsOneWidget);
    expect(find.byKey(ToolDetailTextSection.lazyListKey), findsNothing);
  });

  testWidgets('huge result is chunked and only builds visible chunks', (
    tester,
  ) async {
    final text = List<String>.generate(
      10000,
      (index) => 'result-$index',
    ).join('\n');

    await tester.pumpWidget(harness('Result', text));

    expect(find.byKey(ToolDetailTextSection.lazyListKey), findsOneWidget);
    expect(find.textContaining('result-0'), findsOneWidget);
    expect(find.textContaining('result-9999'), findsNothing);

    final builtChunks = tester.widgetList<Text>(find.byType(Text)).length;
    expect(builtChunks, lessThan(20));
  });

  testWidgets('chunk boundaries preserve the original text', (tester) async {
    final text = List<String>.generate(
      500,
      (index) => 'line-$index',
    ).join('\n');

    expect(ToolDetailTextSection.chunksOf(text).join('\n'), text);
    expect(ToolDetailTextSection.shouldChunk(text), isTrue);
    expect(ToolDetailTextSection.shouldChunk('a\nb\nc'), isFalse);
  });

  testWidgets('chunked content can still be scrolled to the end', (
    tester,
  ) async {
    final text = List<String>.generate(400, (index) => 'row-$index').join('\n');

    await tester.pumpWidget(harness('Result', text));
    expect(find.byKey(ToolDetailTextSection.lazyListKey), findsOneWidget);

    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('tool-detail-text-chunk-9')),
      300,
      scrollable: find.byType(Scrollable).first,
    );

    expect(find.textContaining('row-399'), findsOneWidget);
  });
}
