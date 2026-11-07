// The sheet is drawn in the export's capture mode, where a diagram comes from
// the bitmap cache or falls back to its source. The export warms that cache
// before capturing; the preview has to do the same, or the screen shows source
// for a picture the file renders as a diagram.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:Cuplivo/core/providers/settings_provider.dart';
import 'package:Cuplivo/features/chat/widgets/export_image_capture.dart';
import 'package:Cuplivo/features/markdown_export/widgets/markdown_export_preview.dart';
import 'package:Cuplivo/l10n/app_localizations.dart';
import 'package:Cuplivo/shared/widgets/diagram_exporter.dart';
import 'package:Cuplivo/shared/widgets/mermaid_bridge.dart';
import 'package:Cuplivo/shared/widgets/mermaid_image_cache.dart';

import '../../support/business_test_harness.dart';

const _markdown = '''
# Diagram

```mermaid
graph TD; A-->B;
```

After the diagram.
''';

const _diagramCode = 'graph TD; A-->B;';

/// A one-pixel PNG: enough for the preview to have bytes to draw.
const _pixelPng =
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==';

void main() {
  late SettingsProvider settings;
  final hostKey = GlobalKey();

  setUp(() async {
    settings = SettingsProvider(createBusinessTestPreferences());
    await settings.loaded;
    debugDiagramExportViewFactory = null;
    MermaidImageCache.clear();
  });
  tearDown(() {
    settings.dispose();
    debugDiagramExportViewFactory = null;
    MermaidImageCache.clear();
  });

  Widget host(Widget child) {
    return ChangeNotifierProvider<SettingsProvider>.value(
      value: settings,
      child: MaterialApp(
        locale: const Locale('en'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: Builder(key: hostKey, builder: (_) => child),
        ),
      ),
    );
  }

  Widget preview({double textScale = 1}) {
    return host(
      MarkdownExportPreview(
        source: _markdown,
        documentWidth: desktopExportLogicalWidth,
        emptyHint: 'Nothing to preview yet',
        textScale: textScale,
      ),
    );
  }

  void installRenderer() {
    debugDiagramExportViewFactory = (diagram) => MermaidViewHandle(
      widget: const SizedBox(),
      exportPng: () async => true,
      exportPngBytes: () async => base64Decode(_pixelPng),
    );
  }

  /// Frames for the offscreen render the preview starts itself: it awaits an
  /// overlay, a bitmap and its own retry window.
  Future<void> settleWarm(WidgetTester tester) async {
    await tester.pump();
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 200));
    }
  }

  /// The key the export asks for, for the theme on screen.
  String cacheKey() {
    return diagramImageCacheKey(
      _diagramCode,
      false,
      buildThemeVarsFromColorScheme(
        Theme.of(hostKey.currentContext!).colorScheme,
      ),
      isSvg: false,
    );
  }

  String renderedText(WidgetTester tester) {
    return tester
        .widgetList<RichText>(find.byType(RichText))
        .map((text) => text.text.toPlainText())
        .join('\n');
  }

  testWidgets('the preview warms the cache and draws the diagram in place', (
    tester,
  ) async {
    installRenderer();

    await tester.pumpWidget(preview());
    await settleWarm(tester);

    expect(
      MermaidImageCache.get(cacheKey()),
      isNotNull,
      reason: 'the preview must warm the cache, not wait for an export',
    );
    // Drawn on the same tree: no second build of the page is needed to see it.
    expect(find.byType(Image), findsWidgets);
    expect(renderedText(tester).contains('A-->B'), isFalse);
  });

  testWidgets('a warm that filled nothing is retried by the next build', (
    tester,
  ) async {
    // A renderer that never yields a bitmap: the helper gives up without
    // saying so, which is the case that used to stick for good.
    debugDiagramExportViewFactory = (diagram) => null;

    await tester.pumpWidget(preview());
    await settleWarm(tester);
    expect(MermaidImageCache.get(cacheKey()), isNull);
    // The source is what the sheet honestly shows when there is no bitmap.
    expect(renderedText(tester).contains('A-->B'), isTrue);

    // Any later build — here a type-size change — tries once more.
    installRenderer();
    await tester.pumpWidget(preview(textScale: 1.1));
    await settleWarm(tester);

    expect(MermaidImageCache.get(cacheKey()), isNotNull);
    expect(find.byType(Image), findsWidgets);
    expect(renderedText(tester).contains('A-->B'), isFalse);
  });
}
