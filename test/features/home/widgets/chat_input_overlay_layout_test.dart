import 'package:Cuplivo/features/home/widgets/chat_input_overlay_layout.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('内容铺满可用区域，底部覆盖层贴住底部', (tester) async {
    const rootKey = Key('root');
    const contentKey = Key('content');
    const overlayKey = Key('overlay');

    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: SizedBox(
            key: rootKey,
            width: 400,
            height: 600,
            child: ChatInputOverlayLayout(
              topInset: 100,
              content: ColoredBox(key: contentKey, color: Colors.blue),
              bottomOverlay: SizedBox(key: overlayKey, width: 200, height: 50),
            ),
          ),
        ),
      ),
    );

    expect(tester.getTopLeft(find.byKey(contentKey)).dy, 0);
    expect(tester.getBottomLeft(find.byKey(contentKey)).dy, 600);
    expect(tester.getTopLeft(find.byKey(overlayKey)).dy, 550);
  });

  testWidgets('底部覆盖层内的居中包装不会把输入框推到中间', (tester) async {
    const overlayKey = Key('overlay');

    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 400,
            height: 600,
            child: ChatInputOverlayLayout(
              topInset: 100,
              content: ColoredBox(color: Colors.blue),
              bottomOverlay: Center(
                child: SizedBox(key: overlayKey, width: 200, height: 50),
              ),
            ),
          ),
        ),
      ),
    );

    expect(tester.getTopLeft(find.byKey(overlayKey)).dy, 550);
  });

  testWidgets('输入框层位于前景遮罩上方', (tester) async {
    var inputTaps = 0;
    var foregroundTaps = 0;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 400,
            height: 600,
            child: ChatInputOverlayLayout(
              topInset: 100,
              content: const ColoredBox(color: Colors.blue),
              foreground: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => foregroundTaps++,
              ),
              bottomOverlay: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => inputTaps++,
                child: const SizedBox(width: 400, height: 88),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tapAt(const Offset(200, 560));
    await tester.pump();

    expect(inputTaps, 1);
    expect(foregroundTaps, 0);
  });

  testWidgets('底部覆盖层后方有渐变遮罩隔开消息内容', (tester) async {
    const fadeKey = Key('chat-input-overlay-bottom-fade');

    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 400,
            height: 600,
            child: ChatInputOverlayLayout(
              topInset: 100,
              content: ColoredBox(color: Colors.blue),
              bottomOverlay: SizedBox(width: 200, height: 50),
            ),
          ),
        ),
      ),
    );

    final fadeFinder = find.byKey(fadeKey);
    expect(fadeFinder, findsOneWidget);
    expect(tester.getTopLeft(fadeFinder).dy, 420);
    expect(tester.getBottomLeft(fadeFinder).dy, 600);

    final decoration = tester.widget<DecoratedBox>(
      find.descendant(of: fadeFinder, matching: find.byType(DecoratedBox)),
    );
    final boxDecoration = decoration.decoration as BoxDecoration;
    final gradient = boxDecoration.gradient as LinearGradient;
    expect(gradient.begin, Alignment.topCenter);
    expect(gradient.end, Alignment.bottomCenter);
    expect(gradient.colors.first.a, 0);
    expect(gradient.colors[1].a, greaterThan(0.80));
    expect(gradient.colors.last.a, greaterThan(0.95));
  });

  testWidgets('顶部导航栏后方有渐变遮罩隔开消息内容', (tester) async {
    const fadeKey = Key('chat-input-overlay-top-fade');

    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 400,
            height: 600,
            child: ChatInputOverlayLayout(
              topInset: 100,
              content: ColoredBox(color: Colors.blue),
              bottomOverlay: SizedBox(width: 200, height: 50),
            ),
          ),
        ),
      ),
    );

    final fadeFinder = find.byKey(fadeKey);
    expect(fadeFinder, findsOneWidget);
    expect(tester.getTopLeft(fadeFinder).dy, 0);
    expect(tester.getBottomLeft(fadeFinder).dy, 116);

    final decoration = tester.widget<DecoratedBox>(
      find.descendant(of: fadeFinder, matching: find.byType(DecoratedBox)),
    );
    final boxDecoration = decoration.decoration as BoxDecoration;
    final gradient = boxDecoration.gradient as LinearGradient;
    expect(gradient.begin, Alignment.topCenter);
    expect(gradient.end, Alignment.bottomCenter);
    expect(gradient.colors.first.a, 1);
    expect(gradient.colors[1].a, greaterThan(0.98));
    expect(gradient.colors[2].a, inInclusiveRange(0.85, 0.90));
    expect(gradient.colors.last.a, 0);
  });

  testWidgets('背景图模式下用背景覆盖顶部且不渲染纯色遮罩', (tester) async {
    const bottomFadeKey = Key('chat-input-overlay-bottom-fade');
    const bottomBackgroundKey = Key('chat-input-overlay-bottom-background');
    const topFadeKey = Key('chat-input-overlay-top-fade');
    const topBackgroundKey = Key('chat-input-overlay-top-background');
    const backgroundKey = Key('background');

    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 400,
            height: 600,
            child: ChatInputOverlayLayout(
              topInset: 100,
              backgroundImageActive: true,
              topBackground: ColoredBox(
                key: backgroundKey,
                color: Colors.green,
              ),
              content: ColoredBox(color: Colors.blue),
              bottomOverlay: SizedBox(width: 200, height: 50),
            ),
          ),
        ),
      ),
    );

    expect(find.byKey(bottomFadeKey), findsNothing);
    expect(find.byKey(bottomBackgroundKey), findsOneWidget);
    expect(find.byKey(topFadeKey), findsNothing);
    expect(find.byKey(topBackgroundKey), findsOneWidget);
    expect(find.byKey(backgroundKey), findsNWidgets(2));

    final clipRect = tester.widget<ClipRect>(
      find.ancestor(
        of: find.byKey(topBackgroundKey),
        matching: find.byType(ClipRect),
      ),
    );
    final clip = clipRect.clipper!.getClip(const Size(400, 600));
    expect(clip.height, 116);

    final bottomClipRect = tester.widget<ClipRect>(
      find.ancestor(
        of: find.byKey(bottomBackgroundKey),
        matching: find.byType(ClipRect),
      ),
    );
    final bottomClip = bottomClipRect.clipper!.getClip(const Size(400, 600));
    expect(bottomClip.top, 420);
    expect(bottomClip.height, 180);
  });

  testWidgets('键盘弹出时背景仍按键盘收起时的高度布局', (tester) async {
    const backgroundKey = Key('background');
    const contentKey = Key('content');

    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    Widget build() {
      return const MaterialApp(
        home: Scaffold(
          resizeToAvoidBottomInset: true,
          body: ChatInputOverlayLayout(
            topInset: 100,
            backgroundImageActive: true,
            topBackground: ColoredBox(key: backgroundKey, color: Colors.green),
            content: ColoredBox(key: contentKey, color: Colors.blue),
            bottomOverlay: SizedBox(width: 200, height: 50),
          ),
        ),
      );
    }

    await tester.pumpWidget(build());
    final closedContentHeight = tester.getSize(find.byKey(contentKey)).height;
    final closedBackgroundHeight = tester
        .getSize(find.byKey(backgroundKey).first)
        .height;
    expect(closedBackgroundHeight, closedContentHeight);

    tester.view.viewInsets = const FakeViewPadding(bottom: 300);
    await tester.pumpWidget(build());

    // The body really did shrink around the keyboard...
    expect(
      tester.getSize(find.byKey(contentKey)).height,
      closedContentHeight - 300,
    );
    // ...but the artwork keeps its original box, so BoxFit.cover does not
    // re-crop and the background stays put.
    expect(
      tester.getSize(find.byKey(backgroundKey).first).height,
      closedBackgroundHeight,
    );
    expect(tester.getTopLeft(find.byKey(backgroundKey).first).dy, 0);
  });
}
