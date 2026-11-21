import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:Cuplivo/shared/widgets/segmented_tabs.dart';

/// Four closed-set labels on a 360 dp phone: the Russian words for the model
/// types are the long ones ("Изображение" measures ~87 px at 13 pt), so an
/// ellipsis control leaves two segments reading "[Изображе…]". Scaling the
/// label down keeps every option legible and distinguishable.
void main() {
  Widget host(Widget child, {double width = 320}) => MaterialApp(
    home: Scaffold(
      body: Center(
        child: SizedBox(width: width, child: child),
      ),
    ),
  );

  List<SegmentedTab> longTabs() => const [
    SegmentedTab(label: 'Чат'),
    SegmentedTab(label: 'Изображение'),
    SegmentedTab(label: 'Эмбеддинг'),
    SegmentedTab(label: 'Решение'),
  ];

  testWidgets('a shrinking label is scaled, never ellipsized', (tester) async {
    await tester.pumpWidget(
      host(
        SegmentedTabs(
          shrinkLabels: true,
          tabs: longTabs(),
          index: 0,
          onChanged: (_) {},
        ),
      ),
    );

    final paragraph = tester.renderObject<RenderParagraph>(
      find.text('Изображение'),
    );
    expect(paragraph.didExceedMaxLines, isFalse);
  });

  testWidgets('the default still ellipsizes rather than shrinking', (
    tester,
  ) async {
    await tester.pumpWidget(
      host(SegmentedTabs(tabs: longTabs(), index: 0, onChanged: (_) {})),
    );

    final paragraph = tester.renderObject<RenderParagraph>(
      find.text('Изображение'),
    );
    expect(paragraph.didExceedMaxLines, isTrue);
  });
}
