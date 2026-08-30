import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:Cuplivo/features/home/webview/android_web_chat_view.dart';
import 'package:Cuplivo/shared/widgets/interactive_drawer.dart';

void main() {
  testWidgets('Android controller requests an immediate native scroll stop', (
    tester,
  ) async {
    const channel = MethodChannel('cuplivo/web_chat/42');
    final calls = <MethodCall>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
      call,
    ) async {
      calls.add(call);
      return null;
    });
    addTearDown(() {
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        channel,
        null,
      );
    });
    final controller = AndroidWebChatController.attach(
      viewId: 42,
      onMessage: (_) {},
      onResourceError: (_) {},
      onNavigationRequest: (_) {},
      onDiagnostic: (_) {},
    );
    addTearDown(controller.dispose);

    await controller.stopScrolling();

    expect(calls, hasLength(1));
    expect(calls.single.method, 'stopScrolling');
    expect(calls.single.arguments, 'programmatic');

    await controller.stopScrolling('touch');
    expect(calls, hasLength(2));
    expect(calls.last.arguments, 'touch');
  });

  testWidgets('Android Web chat only claims vertical drag gestures', (
    tester,
  ) async {
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: AndroidWebChatView(onPlatformViewCreated: (_) {}),
      ),
    );

    final view = tester.widget<AndroidView>(find.byType(AndroidView));
    final recognizers = view.gestureRecognizers;
    expect(recognizers, isNotNull);
    expect(recognizers, hasLength(1));
    final recognizer = recognizers!.single.constructor();
    expect(recognizer, isA<VerticalDragGestureRecognizer>());
    expect(recognizer, isNot(isA<EagerGestureRecognizer>()));
  });

  testWidgets('horizontal drag over Android Web chat opens the outer drawer', (
    tester,
  ) async {
    final controller = InteractiveDrawerController();
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: InteractiveDrawer(
          controller: controller,
          drawerWidth: 300,
          drawer: const ColoredBox(color: Colors.black),
          child: AndroidWebChatView(onPlatformViewCreated: (_) {}),
        ),
      ),
    );

    await tester.drag(find.byType(AndroidView), const Offset(240, 0));
    await tester.pumpAndSettle();

    expect(controller.isOpen, isTrue);
  });
}
