import 'package:Cuplivo/core/database/business_preferences.dart';
import 'package:Cuplivo/core/models/assistant.dart';
import 'package:Cuplivo/core/providers/assistant_provider.dart';
import 'package:Cuplivo/core/providers/settings_provider.dart';
import 'package:Cuplivo/features/chat/widgets/chat_assistant_background.dart';
import 'package:Cuplivo/features/chat/widgets/chat_gradient_background.dart';
import 'package:Cuplivo/features/chat/widgets/frosted/chat_frosted_backdrop.dart';
import 'package:Cuplivo/features/chat/widgets/frosted/frosted_surface.dart';
import 'package:Cuplivo/features/home/widgets/chat_input_overlay_layout.dart';
import 'package:Cuplivo/theme/chat_bubble_style.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _style = ResolvedBubbleStyle(
  background: Color(0xA8FFFFFF),
  border: Color(0x24FFFFFF),
  text: Color(0xFF111111),
  borderWidth: 0.8,
  radius: 16,
  blurSigma: 12,
);

class _FakeAssistantProvider extends AssistantProvider {
  _FakeAssistantProvider(BusinessPreferences preferences, Assistant assistant)
    : _assistant = assistant,
      super(preferences: preferences);

  Assistant _assistant;

  @override
  Assistant get currentAssistant => _assistant;

  @override
  Assistant? getById(String id) => _assistant.id == id ? _assistant : null;

  void setAssistant(Assistant updated) {
    _assistant = updated;
    notifyListeners();
  }
}

Future<(_FakeAssistantProvider, SettingsProvider)> _providers(
  Assistant assistant,
) async {
  SharedPreferences.setMockInitialValues({});
  final preferences = BusinessPreferences.memoryForTests();
  final settings = SettingsProvider(preferences: preferences);
  await settings.loaded;
  return (_FakeAssistantProvider(preferences, assistant), settings);
}

Widget _app({
  required _FakeAssistantProvider assistants,
  required SettingsProvider settings,
  Widget backdrop = const ChatAssistantBackground(),
  required Widget child,
}) {
  return MultiProvider(
    providers: [
      ChangeNotifierProvider<AssistantProvider>.value(value: assistants),
      ChangeNotifierProvider<SettingsProvider>.value(value: settings),
    ],
    child: MaterialApp(
      home: ChatFrostedBackdrop(backdrop: backdrop, child: child),
    ),
  );
}

int _countLayers<T extends Layer>(WidgetTester tester) {
  var count = 0;
  void walk(Layer layer) {
    if (layer is T) count++;
    if (layer is ContainerLayer) {
      var child = layer.firstChild;
      while (child != null) {
        walk(child);
        child = child.nextSibling;
      }
    }
  }

  walk(tester.binding.renderViews.first.debugLayer!);
  return count;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() {
    debugFrostedForceLiveBackdropFilter = false;
    debugFrostedForceSnapshotFailure = false;
  });

  testWidgets(
    'gradient without an image uses live glass without capturing frames',
    (tester) async {
      tester.view.physicalSize = const Size(800, 1200);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final providers = await _providers(
        Assistant(
          id: 'gradient-assistant',
          name: 'Gradient',
          useGradientBackground: true,
        ),
      );
      final assistants = providers.$1;
      final settings = providers.$2;
      addTearDown(assistants.dispose);
      addTearDown(settings.dispose);

      await tester.pumpWidget(
        _app(
          assistants: assistants,
          settings: settings,
          child: Center(
            child: FrostedSurface(
              style: _style,
              borderRadius: BorderRadius.circular(16),
              child: const SizedBox(width: 200, height: 100),
            ),
          ),
        ),
      );
      final controller = tester
          .widget<ChatFrostedBackdropScope>(
            find.byType(ChatFrostedBackdropScope),
          )
          .controller;
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 100));
        expect(controller.mode, FrostedRenderMode.liveBackdropFilter);
        expect(controller.debugCaptureCount, 0);
      }
      expect(_countLayers<BackdropFilterLayer>(tester), greaterThan(0));

      assistants.setAssistant(
        assistants.currentAssistant.copyWith(useGradientBackground: false),
      );
      await tester.pumpAndSettle();
      expect(controller.mode, FrostedRenderMode.uniform);
      expect(_countLayers<BackdropFilterLayer>(tester), 0);
      expect(tester.binding.transientCallbackCount, 0);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('image snapshots resume after turning the gradient off', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(800, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final providers = await _providers(
      Assistant(
        id: 'gradient-assistant',
        name: 'Gradient',
        background: 'https://example.com/wallpaper.png',
      ),
    );
    final assistants = providers.$1;
    final settings = providers.$2;
    addTearDown(assistants.dispose);
    addTearDown(settings.dispose);

    await tester.pumpWidget(
      _app(
        assistants: assistants,
        settings: settings,
        // A solid backdrop keeps the remote wallpaper string active without
        // actually resolving NetworkImage in the test HTTP environment.
        backdrop: const ColoredBox(color: Color(0xFF4D5C92)),
        child: Center(
          child: FrostedSurface(
            style: _style,
            borderRadius: BorderRadius.circular(16),
            child: const SizedBox(width: 200, height: 100),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final controller = tester
        .widget<ChatFrostedBackdropScope>(find.byType(ChatFrostedBackdropScope))
        .controller;
    expect(controller.mode, FrostedRenderMode.cached);
    final captures = controller.debugCaptureCount;
    expect(captures, greaterThan(0));

    assistants.setAssistant(
      assistants.currentAssistant.copyWith(useGradientBackground: true),
    );
    await tester.pump();
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(controller.mode, FrostedRenderMode.liveBackdropFilter);
    expect(controller.debugCaptureCount, captures);

    assistants.setAssistant(
      assistants.currentAssistant.copyWith(useGradientBackground: false),
    );
    await tester.pumpAndSettle();
    expect(controller.mode, FrostedRenderMode.cached);
    expect(controller.debugCaptureCount, greaterThan(captures));
    expect(
      assistants.currentAssistant.background,
      'https://example.com/wallpaper.png',
    );
    await tester.pumpWidget(const SizedBox.shrink());
  });

  for (final animated in [false, true]) {
    testWidgets(
      'gradient rendering stays bounded during a 2000-message streaming chat: animated=$animated',
      (tester) async {
        tester.view.physicalSize = const Size(800, 1200);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final providers = await _providers(
          Assistant(
            id: 'gradient-assistant',
            name: 'Gradient',
            useGradientBackground: true,
            gradientBackgroundAnimated: animated,
          ),
        );
        final assistants = providers.$1;
        final settings = providers.$2;
        final tokens = ValueNotifier<int>(0);
        final scroll = ScrollController();
        addTearDown(assistants.dispose);
        addTearDown(settings.dispose);
        addTearDown(tokens.dispose);
        addTearDown(scroll.dispose);
        debugGradientPictureBuildCount = 0;
        debugGradientShaderBuildCount = 0;

        await tester.pumpWidget(
          _app(
            assistants: assistants,
            settings: settings,
            child: ValueListenableBuilder<int>(
              valueListenable: tokens,
              builder: (_, count, child) {
                return ChatInputOverlayLayout(
                  topInset: 80,
                  backgroundImageActive: true,
                  topBackground: const ChatAssistantBackground(
                    pinnedToBackdrop: true,
                  ),
                  bottomOverlay: const SizedBox(height: 60, width: 200),
                  content: ListView.builder(
                    controller: scroll,
                    reverse: true,
                    itemCount: 2000,
                    itemExtent: 80,
                    itemBuilder: (_, index) => FrostedSurface(
                      style: _style,
                      borderRadius: BorderRadius.circular(16),
                      child: Text(
                        index == 0 ? 'Streaming $count' : 'Message $index',
                        textDirection: TextDirection.ltr,
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        );
        await tester.pump();
        await tester.pump();
        final controller = tester
            .widget<ChatFrostedBackdropScope>(
              find.byType(ChatFrostedBackdropScope),
            )
            .controller;
        expect(
          controller.mode,
          animated
              ? FrostedRenderMode.liveBackdropFilter
              : FrostedRenderMode.cached,
        );
        final captures = controller.debugCaptureCount;
        final pictures = debugGradientPictureBuildCount;
        final shaders = debugGradientShaderBuildCount;
        if (!animated) expect(captures, greaterThan(0));

        for (var frame = 0; frame < 120; frame++) {
          tokens.value++;
          if (frame % 10 == 0) scroll.jumpTo(frame * 10.0);
          await tester.pump(const Duration(microseconds: 8333));
        }
        expect(debugGradientShaderBuildCount, shaders);
        expect(
          debugGradientPictureBuildCount - pictures,
          animated ? inInclusiveRange(28, 30) : 0,
        );
        expect(controller.debugCaptureCount, captures);

        if (!animated) {
          expect(_countLayers<BackdropFilterLayer>(tester), 0);
          final generation = controller.generation;
          assistants.setAssistant(
            assistants.currentAssistant.copyWith(
              gradientBackgroundOffsetY: 0.5,
            ),
          );
          await tester.pumpAndSettle();
          expect(controller.generation, greaterThan(generation));
          expect(controller.debugCaptureCount, greaterThan(captures));
          expect(controller.mode, FrostedRenderMode.cached);

          final previousFrameCaptures = controller.debugCaptureCount;
          assistants.setAssistant(
            assistants.currentAssistant.copyWith(gradientBackgroundPhase: 16),
          );
          await tester.pumpAndSettle();
          expect(
            controller.debugCaptureCount,
            greaterThan(previousFrameCaptures),
          );
          expect(controller.mode, FrostedRenderMode.cached);
        }
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }
}
