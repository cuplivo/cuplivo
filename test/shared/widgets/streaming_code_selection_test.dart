import 'package:Cuplivo/l10n/app_localizations.dart';
import 'package:Cuplivo/shared/widgets/markdown_with_highlight.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('long code copies whole from the surface owner across chunks', (
    tester,
  ) async {
    // Past the shaping threshold the code block renders as windowed chunks.
    // That windowing is a layout cost decision, not a selection one: the chunks
    // are paragraphs of the surface's owner, so the owner's selection reaches
    // all of them and copies the code itself — never the U+FFFC an owner of its
    // own would put in its place.
    String? copied;
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') {
        copied = (call.arguments as Map)['text'] as String;
      }
      return null;
    });
    addTearDown(
      () => messenger.setMockMethodCallHandler(SystemChannels.platform, null),
    );
    final source = ValueNotifier(
      List.generate(200, (i) => 'final value$i = "中文 $i";').join('\n'),
    );
    addTearDown(source.dispose);
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: SingleChildScrollView(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              // The owner a surface provides; the code block is one of its
              // paragraphs.
              child: SelectionArea(
                child: ValueListenableBuilder<String>(
                  valueListenable: source,
                  builder: (_, value, _) => SelectableHighlightView(
                    value,
                    language: 'dart',
                    textStyle: const TextStyle(fontSize: 13, height: 1.5),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    expect(
      source.value.length,
      greaterThan(2048),
      reason: 'the test is about the windowed path',
    );
    for (var i = 0; i < 2; i++) {
      await tester.pumpAndSettle();
      // The code block owns no selection of its own; the only region is the
      // owner's.
      expect(find.byType(SelectableRegion), findsOneWidget);
      final region = tester.state<SelectableRegionState>(
        find.byType(SelectableRegion),
      );
      region.selectAll(SelectionChangedCause.keyboard);
      await tester.pumpAndSettle();
      final area = tester.widget<SelectionArea>(find.byType(SelectionArea));
      final menu =
          area.contextMenuBuilder!(
                tester.element(find.byType(SelectionArea)),
                region,
              )
              as AdaptiveTextSelectionToolbar;
      menu.buttonItems!
          .singleWhere((item) => item.type == ContextMenuButtonType.copy)
          .onPressed!();
      await tester.pump();
      expect(copied, source.value);
      // The next round proves a grown source still copies whole: streaming
      // appends a chunk while the selection is made.
      source.value += '\nfinal appended = "more";';
    }
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
