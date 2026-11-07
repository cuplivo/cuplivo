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
  });
  tearDown(() => settings.dispose());

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

  Widget preview() {
    return host(
      const MarkdownExportPreview(
        source: _markdown,
        documentWidth: desktopExportLogicalWidth,
        emptyHint: 'Nothing to preview yet',
      ),
    );
  }

  testWidgets('the preview warms the diagram cache the export reads', (
    tester,
  ) async {
    MermaidImageCache.clear();
    addTearDown(MermaidImageCache.clear);
    addTearDown(() => debugDiagramExportViewFactory = null);
    debugDiagramExportViewFactory = (diagram) => MermaidViewHandle(
      widget: const SizedBox(),
      exportPng: () async => true,
      exportPngBytes: () async => base64Decode(_pixelPng),
    );

    await tester.pumpWidget(preview());
    // One frame to build, then the offscreen render the preview starts itself:
    // that render awaits an overlay frame and a bitmap, so give it several.
    await tester.pump();
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 200));
    }

    // The key the export will ask for, for this theme.
    final themeVars = buildThemeVarsFromColorScheme(
      Theme.of(hostKey.currentContext!).colorScheme,
    );
    final key = diagramImageCacheKey(
      _diagramCode,
      false,
      themeVars,
      isSvg: false,
    );
    expect(
      MermaidImageCache.get(key),
      isNotNull,
      reason: 'the preview must warm the cache, not wait for an export',
    );

    // With that cache warm the sheet draws the diagram rather than its code —
    // the picture the export produces.
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
    await tester.pumpWidget(preview());
    await tester.pumpAndSettle();

    expect(find.byType(Image), findsWidgets);
    final rendered = tester
        .widgetList<RichText>(find.byType(RichText))
        .map((text) => text.text.toPlainText())
        .join('\n');
    expect(rendered.contains('A-->B'), isFalse);
  });
}
