import 'package:Cuplivo/shared/widgets/fluid_streaming_text.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('only appended text starts translucent and then settles', (
    tester,
  ) async {
    final text = ValueNotifier('Hello');
    addTearDown(text.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: ValueListenableBuilder<String>(
          valueListenable: text,
          builder: (_, value, _) => FluidStreamingText(
            streaming: true,
            text: Text(value, style: const TextStyle(color: Colors.black)),
          ),
        ),
      ),
    );

    text.value = 'Hello world';
    await tester.pump();

    final rich = tester.widget<Text>(find.byType(Text).last);
    final spans = <TextSpan>[];
    void collect(InlineSpan span) {
      if (span is! TextSpan) return;
      if (span.text?.isNotEmpty == true) spans.add(span);
      for (final child in span.children ?? const <InlineSpan>[]) {
        collect(child);
      }
    }

    collect(rich.textSpan!);

    expect(spans.map((span) => span.text).join(), 'Hello world');
    expect(spans.first.style?.color?.a, 1);
    expect(spans.last.style?.color?.a, lessThan(1));

    await tester.pump(const Duration(milliseconds: 240));
    final settled = tester.widget<Text>(find.byType(Text).last);
    expect(settled.data, 'Hello world');
  });

  testWidgets('reduce motion renders appended text immediately', (
    tester,
  ) async {
    final text = ValueNotifier('A');
    addTearDown(text.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(disableAnimations: true),
          child: ValueListenableBuilder<String>(
            valueListenable: text,
            builder: (_, value, _) =>
                FluidStreamingText(streaming: true, text: Text(value)),
          ),
        ),
      ),
    );
    text.value = 'AB';
    await tester.pump();

    final rendered = tester.widget<Text>(find.text('AB'));
    expect(rendered.data, 'AB');
  });
}
