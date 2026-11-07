import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:Cuplivo/core/providers/settings_provider.dart';
import 'package:Cuplivo/features/chat/widgets/export_image_capture.dart';
import 'package:Cuplivo/features/markdown_export/models/markdown_export_input.dart';
import 'package:Cuplivo/features/markdown_export/models/markdown_export_mode.dart';
import 'package:Cuplivo/features/markdown_export/models/markdown_export_text_size.dart';
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

  late SettingsProvider settings;
  setUp(() async {
    settings = SettingsProvider(createBusinessTestPreferences());
    await settings.loaded;
  });
  tearDown(() => settings.dispose());

  Widget mobileLayout({
    required TextEditingController controller,
    required ValueChanged<MarkdownExportMode> onModeChanged,
    required VoidCallback? onExport,
  }) {
    return Scaffold(
      body: MarkdownExportMobileLayout(
        controller: controller,
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

  testWidgets('an empty source leaves the export action inert', (tester) async {
    final controller = TextEditingController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      _host(
        settings,
        mobileLayout(
          controller: controller,
          onModeChanged: (_) {},
          onExport: null,
        ),
      ),
    );
    await tester.pumpAndSettle();

    // The page hands the layout a null action while there is nothing to export;
    // tapping it must not start a capture.
    await tester.tap(find.text('Export image'));
    await tester.pump();
    expect(tester.takeException(), isNull);
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
  }) {
    return MarkdownExportDesktopLayout(
      controller: controller,
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
}
