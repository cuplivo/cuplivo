import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:Cuplivo/core/database/business_preferences.dart';
import 'package:Cuplivo/core/models/assistant.dart';
import 'package:Cuplivo/core/providers/assistant_provider.dart';
import 'package:Cuplivo/core/providers/settings_provider.dart';
import 'package:Cuplivo/features/chat/widgets/frosted/chat_frosted_backdrop.dart';
import 'package:Cuplivo/features/chat/widgets/frosted/frosted_surface.dart';
import 'package:Cuplivo/theme/chat_bubble_style.dart';

const _style = ResolvedBubbleStyle(
  background: Color(0xA8FFFFFF),
  border: Color(0x24FFFFFF),
  text: Color(0xFF111111),
  borderWidth: 0.8,
  radius: 16,
  blurSigma: 14,
);

class _FakeAssistantProvider extends AssistantProvider {
  _FakeAssistantProvider(BusinessPreferences preferences, String background)
    : _assistant = Assistant(
        id: 'frosted-assistant',
        name: 'Frosted',
        background: background,
      ),
      super(preferences: preferences);

  Assistant _assistant;

  @override
  Assistant get currentAssistant => _assistant;

  void setBackground(String background) {
    _assistant = _assistant.copyWith(background: background);
    notifyListeners();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() {
    debugFrostedForceLiveBackdropFilter = false;
    debugFrostedForceSnapshotFailure = false;
  });

  testWidgets('cached frosted surfaces keep live filter layers out on scroll', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(800, 1200);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);
    final providers = await _providers(
      background: 'https://example.com/wallpaper.png',
    );

    await tester.pumpWidget(
      _app(
        assistants: providers.$1,
        settings: providers.$2,
        child: ListView(
          children: [
            for (var i = 0; i < 8; i++)
              const Padding(
                padding: EdgeInsets.all(12),
                child: FrostedSurface(
                  style: _style,
                  borderRadius: BorderRadius.all(Radius.circular(16)),
                  child: SizedBox(height: 100, child: Text('card')),
                ),
              ),
          ],
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.byType(CompositedTransformFollower), findsWidgets);
    expect(_countLayers<BackdropFilterLayer>(tester), 0);

    tester.state<ScrollableState>(find.byType(Scrollable)).position.jumpTo(240);
    await tester.pump();

    expect(_countLayers<BackdropFilterLayer>(tester), 0);
  });

  testWidgets('no wallpaper uses tint-only frosted surface', (tester) async {
    final providers = await _providers(background: '');

    await tester.pumpWidget(
      _app(
        assistants: providers.$1,
        settings: providers.$2,
        child: const Center(
          child: FrostedSurface(
            style: _style,
            borderRadius: BorderRadius.all(Radius.circular(16)),
            child: SizedBox(width: 160, height: 64, child: Text('tint')),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.byType(BackdropFilter), findsNothing);
    expect(find.byType(CompositedTransformFollower), findsNothing);
    final box = tester.widget<DecoratedBox>(
      find
          .descendant(
            of: find.byType(FrostedSurface),
            matching: find.byType(DecoratedBox),
          )
          .first,
    );
    expect((box.decoration as BoxDecoration).color, _style.background);
  });

  testWidgets('capture failure shares one group and wallpaper removal tints', (
    tester,
  ) async {
    debugFrostedForceSnapshotFailure = true;
    final providers = await _providers(
      background: 'https://example.com/wallpaper.png',
    );

    await tester.pumpWidget(
      _app(
        assistants: providers.$1,
        settings: providers.$2,
        child: const Column(
          children: [
            FrostedSurface(
              style: _style,
              borderRadius: BorderRadius.all(Radius.circular(16)),
              child: SizedBox(height: 40, child: Text('one')),
            ),
            FrostedSurface(
              style: _style,
              borderRadius: BorderRadius.all(Radius.circular(16)),
              child: SizedBox(height: 40, child: Text('two')),
            ),
          ],
        ),
      ),
    );
    await tester.pump();
    await tester.pump();

    final filters = tester.renderObjectList<RenderBackdropFilter>(
      find.byType(BackdropFilter),
    );
    expect(filters, hasLength(2));
    expect(filters.first.backdropKey, isNotNull);
    expect(filters.first.backdropKey, same(filters.last.backdropKey));
    final controller = tester
        .widget<ChatFrostedBackdropScope>(find.byType(ChatFrostedBackdropScope))
        .controller;
    expect(controller.snapshotUnsupported, isTrue);

    providers.$1.setBackground('missing-local-wallpaper.png');
    await tester.pump();
    await tester.pump();

    expect(controller.mode, FrostedRenderMode.uniform);
    expect(find.byType(BackdropFilter), findsNothing);
  });

  testWidgets('changing sigma retires unused snapshot buckets', (tester) async {
    final providers = await _providers(
      background: 'https://example.com/wallpaper.png',
    );

    for (final sigma in <double>[8, 14, 22]) {
      await tester.pumpWidget(
        _app(
          assistants: providers.$1,
          settings: providers.$2,
          child: FrostedSurface(
            style: _styleWithSigma(sigma),
            borderRadius: BorderRadius.circular(16),
            child: const SizedBox(height: 40, child: Text('card')),
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
      expect(controller.debugAcquiredSigmaCount, 1);
      expect(controller.debugBucketCount, lessThanOrEqualTo(2));
    }

    final controller = tester
        .widget<ChatFrostedBackdropScope>(find.byType(ChatFrostedBackdropScope))
        .controller;
    await tester.pumpWidget(
      _app(
        assistants: providers.$1,
        settings: providers.$2,
        child: const SizedBox.shrink(),
      ),
    );
    await tester.pump();
    await tester.pump();
    expect(controller.debugAcquiredSigmaCount, 0);
    expect(controller.debugBucketCount, 0);
  });
}

ResolvedBubbleStyle _styleWithSigma(double sigma) => ResolvedBubbleStyle(
  background: _style.background,
  border: _style.border,
  text: _style.text,
  borderWidth: _style.borderWidth,
  radius: _style.radius,
  blurSigma: sigma,
);

Future<(_FakeAssistantProvider, SettingsProvider)> _providers({
  required String background,
}) async {
  SharedPreferences.setMockInitialValues({});
  final preferences = BusinessPreferences.memoryForTests();
  final settings = SettingsProvider(preferences: preferences);
  await settings.loaded;
  return (_FakeAssistantProvider(preferences, background), settings);
}

Widget _app({
  required _FakeAssistantProvider assistants,
  required SettingsProvider settings,
  required Widget child,
}) {
  return MultiProvider(
    providers: [
      ChangeNotifierProvider<AssistantProvider>.value(value: assistants),
      ChangeNotifierProvider<SettingsProvider>.value(value: settings),
    ],
    child: MaterialApp(
      home: ChatFrostedBackdrop(
        backdrop: const ColoredBox(color: Color(0xFF4D5C92)),
        child: child,
      ),
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
