import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:Cuplivo/core/providers/settings_provider.dart';
import 'package:Cuplivo/features/chat/widgets/export_image_capture.dart';
import 'package:Cuplivo/features/markdown_export/models/markdown_export_input.dart';
import 'package:Cuplivo/features/markdown_export/models/markdown_export_mode.dart';
import 'package:Cuplivo/features/markdown_export/models/markdown_export_text_size.dart';
import 'package:Cuplivo/features/markdown_export/pages/markdown_export_page.dart';
import 'package:Cuplivo/features/markdown_export/services/markdown_export_image.dart';
import 'package:Cuplivo/features/markdown_export/widgets/markdown_export_actions.dart';
import 'package:Cuplivo/features/markdown_export/widgets/markdown_export_desktop_layout.dart';
import 'package:Cuplivo/features/markdown_export/widgets/markdown_export_document.dart';
import 'package:Cuplivo/features/markdown_export/widgets/markdown_export_mobile_layout.dart';
import 'package:Cuplivo/features/markdown_export/widgets/markdown_export_preview.dart';
import 'package:Cuplivo/l10n/app_localizations.dart';

import '../../support/business_test_harness.dart';
import '../../support/markdown_render_helpers.dart';

Widget _host(SettingsProvider settings, Widget home) {
  return ChangeNotifierProvider<SettingsProvider>.value(
    value: settings,
    child: MaterialApp(
      locale: const Locale('en'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: home,
    ),
  );
}

void main() {
  group('isMarkdownExportFile', () {
    test('accepts readable text however the name is cased', () {
      expect(isMarkdownExportFile('/a/notes.md'), isTrue);
      expect(isMarkdownExportFile('/a/NOTES.MARKDOWN'), isTrue);
      expect(isMarkdownExportFile(r'D:\notes.txt'), isTrue);
    });

    test('refuses everything else, including a decorated extension', () {
      expect(isMarkdownExportFile('/a/report.pdf'), isFalse);
      expect(isMarkdownExportFile('/a/notes.md.png'), isFalse);
      expect(isMarkdownExportFile('/a/notes'), isFalse);
    });
  });

  test('export width follows the platform, not the window', () {
    expect(exportRenderConfig(isDesktop: true), (width: 720, pixelRatio: 3));
    expect(exportRenderConfig(isDesktop: false), (width: 480, pixelRatio: 3));
    expect(desktopExportLogicalWidth, greaterThan(mobileExportLogicalWidth));
  });

  group('exportRatioWithinBudget', () {
    const budget = markdownExportMaxPixels;

    test('keeps the requested ratio while the sheet fits', () {
      // 720 × 3000 at 3× is 19.4 MP.
      expect(exportRatioWithinBudget(const Size(720, 3000), 3, budget), 3);
    });

    test('falls back to the largest whole ratio that fits', () {
      // 720 × 4000 at 3× is 25.9 MP, at 2× 11.5 MP.
      expect(exportRatioWithinBudget(const Size(720, 4000), 3, budget), 2);
      // 720 × 20000 at 2× is still 57.6 MP, at 1× 14.4 MP.
      expect(exportRatioWithinBudget(const Size(720, 20000), 3, budget), 1);
    });

    test('refuses only when even 1× cannot fit', () {
      expect(
        exportRatioWithinBudget(const Size(720, 60000), 3, budget),
        isNull,
      );
      // No budget means no ceiling, which is what the message path passes.
      expect(exportRatioWithinBudget(const Size(720, 60000), 3, null), 3);
    });
  });

  late SettingsProvider settings;
  setUp(() async {
    settings = SettingsProvider(createBusinessTestPreferences());
    await settings.loaded;
  });
  tearDown(() => settings.dispose());

  Widget mobileLayout({
    required TextEditingController controller,
    required ValueChanged<MarkdownExportMode> onModeChanged,
    required VoidCallback onExport,
    String? previewSource,
  }) {
    return Scaffold(
      body: MarkdownExportMobileLayout(
        controller: controller,
        previewSource: previewSource ?? controller.text,
        mode: MarkdownExportMode.edit,
        onModeChanged: onModeChanged,
        onImport: () {},
        onPaste: () {},
        onExport: onExport,
        busy: false,
        documentWidth: mobileExportLogicalWidth,
        textScale: 1,
      ),
    );
  }

  testWidgets('the mobile layout switches tabs and exports on demand', (
    tester,
  ) async {
    final controller = TextEditingController(text: '## 周会纪要');
    addTearDown(controller.dispose);
    MarkdownExportMode? asked;
    var exports = 0;
    await tester.pumpWidget(
      _host(
        settings,
        mobileLayout(
          controller: controller,
          onModeChanged: (mode) => asked = mode,
          onExport: () => exports++,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Import'), findsOneWidget);
    expect(find.text('Paste'), findsOneWidget);

    await tester.tap(find.text('Preview'));
    expect(asked, MarkdownExportMode.preview);

    await tester.tap(find.text('Export image'));
    await tester.pump();
    expect(exports, 1);
  });

  testWidgets('nothing to export leaves the primary action inert', (
    tester,
  ) async {
    final controller = TextEditingController();
    addTearDown(controller.dispose);
    var exports = 0;
    await tester.pumpWidget(
      _host(
        settings,
        Scaffold(
          body: Center(
            child: MarkdownExportSubmitButton(
              controller: controller,
              onTap: () => exports++,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // This is the rule itself, not a caller handing over a null: an empty (or
    // whitespace-only) source disables the pill, and tapping it does nothing.
    VoidCallback? pillAction() => tester
        .widget<MarkdownExportButton>(find.byType(MarkdownExportButton))
        .onTap;
    expect(pillAction(), isNull);
    await tester.tap(find.text('Export image'));
    await tester.pump();
    expect(exports, 0);

    controller.text = '   \n\t ';
    await tester.pump();
    expect(pillAction(), isNull);

    controller.text = '## 周会纪要';
    await tester.pump();
    expect(pillAction(), isNotNull);
    await tester.tap(find.text('Export image'));
    await tester.pump();
    expect(exports, 1);
  });

  testWidgets('the preview renders the document, not its source', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(
        settings,
        const Scaffold(
          body: MarkdownExportPreview(
            source: '## 周会纪要 · 11-07\n\n渲染抽成一个页面。',
            documentWidth: mobileExportLogicalWidth,
            emptyHint: 'Nothing to preview yet',
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(renderedParagraphsWith('周会纪要'), isNotEmpty);
    expect(find.textContaining('## '), findsNothing);
  });

  testWidgets('the preview says so when there is nothing yet', (tester) async {
    await tester.pumpWidget(
      _host(
        settings,
        const Scaffold(
          body: MarkdownExportPreview(
            source: '   ',
            documentWidth: mobileExportLogicalWidth,
            emptyHint: 'Nothing to preview yet',
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Nothing to preview yet'), findsOneWidget);
  });

  Widget desktopLayout({
    required TextEditingController controller,
    bool sourceCollapsed = false,
    VoidCallback? onToggleSource,
    VoidCallback? onExport,
    String? previewSource,
  }) {
    return MarkdownExportDesktopLayout(
      controller: controller,
      previewSource: previewSource ?? controller.text,
      onImport: () {},
      onPaste: () {},
      onTextSize: () {},
      textSizeAnchor: GlobalKey(),
      sourceCollapsed: sourceCollapsed,
      onToggleSource: onToggleSource ?? () {},
      onExport: onExport ?? () {},
      busy: false,
      documentWidth: desktopExportLogicalWidth,
      textScale: 1,
    );
  }

  testWidgets('the desktop layout keeps source and sheet side by side', (
    tester,
  ) async {
    final controller = TextEditingController(text: '## 周会纪要 · 11-07');
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      _host(settings, desktopLayout(controller: controller)),
    );
    await tester.pumpAndSettle();

    expect(find.text('Import'), findsOneWidget);
    expect(find.text('Text size'), findsOneWidget);
    expect(find.text('Export image'), findsOneWidget);
    expect(find.byType(TextField), findsOneWidget);
    // The right pane renders the same source the left pane holds.
    expect(renderedParagraphsWith('周会纪要'), isNotEmpty);
    // The bar sizes itself to its own actions. A fixed 36 px row once clipped
    // the bottom off every CJK label in the header.
    expect(
      tester.getSize(find.byType(MarkdownExportButton)).height,
      greaterThan(30),
    );
  });

  testWidgets('the source pane steps aside and the sheet takes the window', (
    tester,
  ) async {
    final controller = TextEditingController(text: '## 周会纪要 · 11-07');
    addTearDown(controller.dispose);
    var toggles = 0;
    await tester.pumpWidget(
      _host(
        settings,
        desktopLayout(
          controller: controller,
          sourceCollapsed: true,
          onToggleSource: () => toggles++,
        ),
      ),
    );
    await tester.pumpAndSettle();

    // Collapsed is the only state where the editor is gone but the sheet stays,
    // and the action has to say how to bring it back.
    expect(find.byType(TextField), findsNothing);
    expect(renderedParagraphsWith('周会纪要'), isNotEmpty);
    expect(find.text('Show source'), findsOneWidget);
    expect(find.text('Hide source'), findsNothing);
    // The sheet is wider than it was beside the editor.
    final collapsedWidth = tester
        .getSize(find.byType(MarkdownExportPreview))
        .width;
    expect(collapsedWidth, greaterThan(600));

    await tester.tap(find.text('Show source'));
    expect(toggles, 1);
  });

  testWidgets('an expanded source pane offers to collapse it', (tester) async {
    final controller = TextEditingController(text: '## 周会纪要');
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      _host(settings, desktopLayout(controller: controller)),
    );
    await tester.pumpAndSettle();

    expect(find.text('Hide source'), findsOneWidget);
    expect(find.text('Show source'), findsNothing);
  });

  testWidgets(
    'a narrow window wraps the header actions instead of cutting them',
    (tester) async {
      tester.view.physicalSize = const Size(420, 700);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final controller = TextEditingController();
      addTearDown(controller.dispose);

      await tester.pumpWidget(
        _host(settings, desktopLayout(controller: controller)),
      );
      await tester.pumpAndSettle();

      // Every action is still a full-size pill: the bar wraps rather than
      // squeezing, which is what used to clip the bottom off CJK labels.
      for (final label in [
        'Import',
        'Paste',
        'Text size',
        'Hide source',
        'Export image',
      ]) {
        expect(find.text(label), findsOneWidget);
      }
      expect(
        tester.getSize(find.byType(MarkdownExportButton)).height,
        greaterThan(30),
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('a larger type size grows the sheet, not the canvas', (
    tester,
  ) async {
    Future<Size> sheetSize(double textScale) async {
      await tester.pumpWidget(
        _host(
          settings,
          Scaffold(
            // The sheet is unbounded in height when captured; the test has to
            // give it the same freedom or the renderer fills the viewport.
            body: SingleChildScrollView(
              child: Align(
                alignment: Alignment.topLeft,
                child: MarkdownExportDocument(
                  source: '# Heading\n\n${'A sentence that wraps. ' * 24}',
                  width: 320,
                  textScale: textScale,
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      return tester.getSize(find.byType(MarkdownExportDocument));
    }

    final standard = await sheetSize(MarkdownExportTextSize.standard.scale);
    final large = await sheetSize(MarkdownExportTextSize.large.scale);

    expect(large.width, standard.width);
    expect(large.height, greaterThan(standard.height));
  });

  testWidgets('a caret move does not redraw the sheet, a burst redraws once', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1440, 900);
    addTearDown(tester.view.reset);
    try {
      await tester.pumpWidget(
        _host(settings, const Scaffold(body: MarkdownExportPage())),
      );
      await tester.pumpAndSettle();

      final controller = tester
          .widget<TextField>(find.byType(TextField))
          .controller!;
      controller.text = '## Weekly summary\n\n${'A sentence. ' * 40}';
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();
      final builds = MarkdownExportPreview.debugSheetBuilds;

      // Five caret moves. The text is identical every time, so the sheet must
      // not be built again: moving the cursor is not an edit.
      for (var i = 0; i < 5; i++) {
        controller.selection = TextSelection.collapsed(offset: i + 1);
        await tester.pump();
      }
      await tester.pump(const Duration(milliseconds: 400));
      expect(MarkdownExportPreview.debugSheetBuilds, builds);

      // A burst of keystrokes settles into exactly one redraw, after it stops.
      for (final text in ['a', 'ab', 'abc', 'abcd']) {
        controller.text = text;
        await tester.pump(const Duration(milliseconds: 20));
      }
      expect(MarkdownExportPreview.debugSheetBuilds, builds);
      await tester.pump(const Duration(milliseconds: 400));
      expect(MarkdownExportPreview.debugSheetBuilds, builds + 1);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });
}
