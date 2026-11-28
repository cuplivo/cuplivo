// A diagram is a picture the preview owns: it renders itself, shows a loading
// state while it works, and a failure card with actions when it cannot. The
// export has no renderer of its own, so a cold cache there is the same failure.
import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:Cuplivo/core/providers/settings_provider.dart';
import 'package:Cuplivo/features/chat/widgets/export_image_capture.dart';
import 'package:Cuplivo/features/markdown_export/widgets/markdown_export_document.dart';
import 'package:Cuplivo/features/markdown_export/widgets/markdown_export_preview.dart';
import 'package:Cuplivo/l10n/app_localizations.dart';
import 'package:Cuplivo/shared/markdown/diagram_code_blocks.dart';
import 'package:Cuplivo/shared/widgets/mermaid_image_cache.dart';

import '../../support/business_test_harness.dart';

const _markdown = '''
# Diagram

```mermaid
graph TD; A-->B;
```

After the diagram.
''';

/// A one-pixel PNG: enough for the preview to have bytes to draw.
const _pixelPng =
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==';

final _image = MermaidBitmapRenderResult.success(base64Decode(_pixelPng));

void main() {
  late SettingsProvider settings;

  setUp(() async {
    settings = SettingsProvider(createBusinessTestPreferences());
    await settings.loaded;
    debugMermaidBitmapRenderOverride = null;
    MermaidImageCache.clear();
  });
  tearDown(() {
    settings.dispose();
    debugMermaidBitmapRenderOverride = null;
    MermaidImageCache.clear();
  });

  Widget host(Widget child) {
    return ChangeNotifierProvider<SettingsProvider>.value(
      value: settings,
      child: MaterialApp(
        locale: const Locale('en'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(body: child),
      ),
    );
  }

  Widget preview({double textScale = 1}) {
    return host(
      MarkdownExportPreview(
        source: _markdown,
        maxDocumentWidth: desktopExportLogicalWidth,
        emptyHint: 'Nothing to preview yet',
        textScale: textScale,
      ),
    );
  }

  String renderedText(WidgetTester tester) {
    return tester
        .widgetList<RichText>(find.byType(RichText))
        .map((text) => text.text.toPlainText())
        .join('\n');
  }

  /// Lets the block's 220 ms settle timer fire and the render it starts finish.
  ///
  /// The frame that schedules the timer comes first: a tap that retries has
  /// only queued the rebuild, and a timed pump would start the timer after the
  /// clock already moved past it.
  Future<void> settleRender(WidgetTester tester) async {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 240));
    for (var i = 0; i < 4; i++) {
      await tester.pump();
    }
  }

  testWidgets('the preview shows the generating state, never the source', (
    tester,
  ) async {
    final pending = Completer<MermaidBitmapRenderResult>();
    debugMermaidBitmapRenderOverride = (_, __, ___) => pending.future;
    try {
      await tester.pumpWidget(preview());
      await tester.pump();

      // The first frame already says it is working; it does not fall back to
      // the diagram's source while the bitmap is on its way.
      expect(
        find.byKey(const ValueKey('mermaid-loading-body')),
        findsOneWidget,
      );
      expect(renderedText(tester).contains('A-->B'), isFalse);

      await tester.pump(const Duration(milliseconds: 240));
      pending.complete(_image);
      await tester.pump();
      await tester.pump();

      expect(find.byType(Image), findsWidgets);
      expect(renderedText(tester).contains('A-->B'), isFalse);
      expect(tester.takeException(), isNull);
    } finally {
      if (!pending.isCompleted) pending.complete(_image);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    }
  });

  testWidgets('a failed render offers retry and the source, and retry works', (
    tester,
  ) async {
    debugMermaidBitmapRenderOverride = (_, __, ___) async =>
        MermaidBitmapRenderResult.failed();

    await tester.pumpWidget(preview());
    await settleRender(tester);

    expect(find.byKey(const ValueKey('mermaid-error-body')), findsOneWidget);
    expect(renderedText(tester).contains('A-->B'), isFalse);
    expect(find.text('Retry'), findsOneWidget);
    expect(find.text('Copy source'), findsOneWidget);

    debugMermaidBitmapRenderOverride = (_, __, ___) async => _image;
    await tester.tap(find.text('Retry'));
    await settleRender(tester);

    expect(find.byKey(const ValueKey('mermaid-error-body')), findsNothing);
    expect(find.byType(Image), findsWidgets);
    expect(renderedText(tester).contains('A-->B'), isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a platform without a renderer shows the same card in preview', (
    tester,
  ) async {
    debugMermaidBitmapRenderOverride = (_, __, ___) async =>
        MermaidBitmapRenderResult.unsupported();

    await tester.pumpWidget(preview());
    await settleRender(tester);

    // The file cannot contain this diagram either, so the preview says so
    // instead of showing source the export would not carry.
    expect(find.byKey(const ValueKey('mermaid-error-body')), findsOneWidget);
    expect(renderedText(tester).contains('A-->B'), isFalse);
    expect(find.text('Copy source'), findsOneWidget);
    // Retrying cannot conjure a renderer.
    expect(find.text('Retry'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a capture with a cold cache paints the failure card, not code', (
    tester,
  ) async {
    await tester.pumpWidget(
      host(
        SingleChildScrollView(
          child: MarkdownExportDocument(
            source: _markdown,
            width: desktopExportLogicalWidth,
            capture: true,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('mermaid-error-body')), findsOneWidget);
    expect(renderedText(tester).contains('A-->B'), isFalse);
    // A picture cannot be retried from, so the card carries no actions.
    expect(find.text('Retry'), findsNothing);
    expect(find.text('Copy source'), findsNothing);
  });
}
