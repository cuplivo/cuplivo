import 'package:Cuplivo/features/home/widgets/message_list_view.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:super_sliver_list/super_sliver_list.dart';

void main() {
  // check that triple-click or drag selection keeps focus and allows Ctrl+C.
  // Note: selectable footer text tests the list's focus handling without rendering chat messages
  for (final dragSelection in [false, true]) {
    testWidgets(
      'timeline ${dragSelection ? 'drag' : 'multi-click'} selection retains focus for copying',
      (tester) async {
        final scrollController = ScrollController();
        final listController = ListController();
        final processing = ValueNotifier<String?>(null);
        final selectionFocus = FocusNode();
        addTearDown(scrollController.dispose);
        addTearDown(listController.dispose);
        addTearDown(processing.dispose);
        addTearDown(selectionFocus.dispose);
        var clipboard = 'clipboard sentinel';
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          (call) async {
            if (call.method == 'Clipboard.setData') {
              clipboard = (call.arguments as Map)['text'] as String;
            }
            return null;
          },
        );
        addTearDown(
          () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
            SystemChannels.platform,
            null,
          ),
        );
        const text = 'copyable timeline text';
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: MessageListView(
                scrollController: scrollController,
                listController: listController,
                messages: const [],
                byGroup: const {},
                versionSelections: const {},
                reasoning: const {},
                reasoningSegments: const {},
                contentSplits: const {},
                toolParts: const {},
                translations: const {},
                selecting: false,
                selectedItems: const {},
                dividerPadding: EdgeInsets.zero,
                processingFilesMessageId: processing,
                footer: Align(
                  alignment: Alignment.centerLeft,
                  child: SelectionArea(
                    focusNode: selectionFocus,
                    child: const Text(text),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final rect = tester.getRect(find.text(text));
        if (dragSelection) {
          final gesture = await tester.startGesture(
            Offset(rect.left + 1, rect.center.dy),
            kind: PointerDeviceKind.mouse,
          );
          await gesture.moveTo(Offset(rect.right + 1, rect.center.dy));
          await gesture.up();
          await tester.pump();
        } else {
          for (var click = 0; click < 3; click++) {
            await tester.tapAt(rect.center, kind: PointerDeviceKind.mouse);
            await tester.pump(const Duration(milliseconds: 100));
          }
        }
        final modifier = defaultTargetPlatform == TargetPlatform.macOS
            ? LogicalKeyboardKey.metaLeft
            : LogicalKeyboardKey.controlLeft;
        await tester.sendKeyDownEvent(modifier);
        await tester.sendKeyDownEvent(LogicalKeyboardKey.keyC);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.keyC);
        await tester.sendKeyUpEvent(modifier);
        await tester.pump();
        expect(clipboard, text);
        expect(selectionFocus.hasPrimaryFocus, isTrue);
      },
      variant: const TargetPlatformVariant({
        TargetPlatform.linux,
        TargetPlatform.windows,
        TargetPlatform.macOS,
      }),
    );
  }

  const platforms = <TargetPlatform>[
    TargetPlatform.android,
    TargetPlatform.iOS,
    TargetPlatform.macOS,
    TargetPlatform.windows,
    TargetPlatform.linux,
  ];

  for (final platform in platforms) {
    testWidgets('$platform uses its timeline input surface contract', (
      tester,
    ) async {
      debugDefaultTargetPlatformOverride = platform;
      final scrollController = ScrollController();
      addTearDown(scrollController.dispose);
      final listController = ListController();
      addTearDown(listController.dispose);
      final processing = ValueNotifier<String?>(null);
      addTearDown(processing.dispose);
      var userScrollIntentCount = 0;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: MessageListView(
              scrollController: scrollController,
              listController: listController,
              messages: const [],
              byGroup: const {},
              versionSelections: const {},
              reasoning: const {},
              reasoningSegments: const {},
              contentSplits: const {},
              toolParts: const {},
              translations: const {},
              selecting: false,
              selectedItems: const {},
              dividerPadding: EdgeInsets.zero,
              processingFilesMessageId: processing,
              onUserScrollIntent: () => userScrollIntentCount++,
            ),
          ),
        ),
      );

      final list = tester.widget<SuperListView>(find.byType(SuperListView));
      final desktop =
          platform == TargetPlatform.macOS ||
          platform == TargetPlatform.windows ||
          platform == TargetPlatform.linux;
      expect(
        list.keyboardDismissBehavior,
        desktop
            ? ScrollViewKeyboardDismissBehavior.manual
            : ScrollViewKeyboardDismissBehavior.onDrag,
      );
      expect(find.byType(Scrollbar), desktop ? findsOneWidget : findsNothing);

      if (desktop) {
        await tester.tap(find.byType(SuperListView));
        await tester.sendKeyDownEvent(LogicalKeyboardKey.pageUp);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.pageUp);
        await tester.pump();
        expect(userScrollIntentCount, greaterThanOrEqualTo(1));
      }
      debugDefaultTargetPlatformOverride = null;
    });
  }
}
