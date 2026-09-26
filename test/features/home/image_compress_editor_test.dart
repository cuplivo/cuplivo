import 'dart:io';
import 'dart:math' as math;

import 'package:Cuplivo/core/providers/settings_provider.dart';
import 'package:Cuplivo/features/home/widgets/image_compress/compress_editor.dart';
import 'package:Cuplivo/features/home/widgets/image_compress/compress_editor_controller.dart';
import 'package:Cuplivo/features/home/widgets/image_compress/compress_editor_preview.dart';
import 'package:Cuplivo/l10n/app_localizations.dart';
import 'package:Cuplivo/shared/widgets/segmented_tabs.dart';
import 'package:Cuplivo/utils/image_compressor.dart';
import 'package:downsize/downsize.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';

import '../../support/business_test_harness.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory root;

  setUp(() async {
    root = await Directory(
      p.join('.dart_tool', 'compress_editor_test'),
    ).create(recursive: true);
  });

  tearDown(() async {
    if (await root.exists()) await root.delete(recursive: true);
  });

  Future<String> writeFixture(String name, int width, int height) async {
    final file = File(p.join(root.path, name));
    await file.writeAsBytes(img.encodePng(_noiseImage(width, height)));
    return file.path;
  }

  test(
    'decodes once and tiles the visible region through the pipeline',
    () async {
      final path = await writeFixture('big.png', 400, 260);
      final sourceBytes = await File(path).length();
      final controller = CompressEditorController(
        imagePath: path,
        initialParams: const ManualCompressParams(
          format: DownsizeFormat.jpeg,
          quality: 70,
          maxLongEdge: 200,
        ),
      );
      addTearDown(controller.dispose);

      await controller.prepare();

      expect(controller.decodeFailed, isFalse);
      expect(controller.preparing, isFalse);
      expect(controller.sourceWidth, 400);
      expect(controller.sourceHeight, 260);
      expect(controller.previewWidth, 400);
      expect(controller.original, isNotNull);

      const visible = Rect.fromLTWH(0, 0, 400, 260);
      controller.updateViewport(
        visible: visible,
        viewport: const Size(400, 260),
      );
      await _waitFor(() => controller.tile != null);

      // The tile is the visible region carried through the same long-edge
      // reduction the artifact gets: 400 -> 200, so 260 -> 130.
      expect(controller.tileSource, visible);
      expect(controller.tile!.width, 200);
      expect(controller.tile!.height, 130);

      await _waitFor(
        () => !controller.estimating && controller.estimatedBytes != null,
      );
      expect(controller.estimatedBytes, greaterThan(0));
      expect(controller.estimatedBytes!, lessThan(sourceBytes));
    },
  );

  test('reports a decode failure instead of throwing', () async {
    final file = File(p.join(root.path, 'broken.png'));
    await file.writeAsBytes(List<int>.filled(128, 9));
    final controller = CompressEditorController(
      imagePath: file.path,
      initialParams: const ManualCompressParams(),
    );
    addTearDown(controller.dispose);

    await controller.prepare();

    expect(controller.decodeFailed, isTrue);
    expect(controller.original, isNull);
    expect(controller.estimatedBytes, isNull);
  });

  testWidgets('format control drives the panel and the apply action', (
    tester,
  ) async {
    late AppLocalizations l10n;
    late SettingsProvider settings;
    late String path;

    // A portrait window: its preview area's aspect ratio is nowhere near the
    // fixture's, which is what makes a stretched or cropped fit visible.
    tester.view.physicalSize = const Size(500, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    // Delegate loading, the drift-backed preference store and file writes are
    // real async work, so they run outside the widget test's fake-async zone.
    await tester.runAsync(() async {
      l10n = await AppLocalizations.delegate.load(const Locale('en'));
      final harness = await createBusinessTestHarness();
      settings = SettingsProvider(harness.preferences);
      await settings.loaded;
      await settings.setManualCompressParams(
        const ManualCompressParams(
          format: DownsizeFormat.jpeg,
          quality: 80,
          maxLongEdge: 200,
        ),
      );
      path = await writeFixture('panel.png', 400, 260);
    });

    await tester.pumpWidget(
      ChangeNotifierProvider<SettingsProvider>.value(
        value: settings,
        child: MaterialApp(
          localizationsDelegates: const [
            AppLocalizations.delegate,
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          supportedLocales: AppLocalizations.supportedLocales,
          home: Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: TextButton(
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute<CompressEditorResult>(
                      builder: (_) => CompressEditorPage(
                        imagePath: path,
                        totalImageCount: 1,
                      ),
                    ),
                  ),
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('open'));
    await tester.pump();
    // The page decodes the image in an isolate; give that real time to land.
    await _pumpUntilFound(tester, find.byType(CompressPreview));
    final preview = tester.widget<CompressPreview>(
      find.byType(CompressPreview),
    );

    // Fit state maps the whole image, so the painter letterboxes it inside
    // the preview area instead of stretching it to fill.
    expect(
      preview.controller.visibleSource,
      const Rect.fromLTWH(0, 0, 400, 260),
    );

    // JPEG is the remembered format, so the lossy control is offered.
    expect(find.text(l10n.compressEditorQualityLabel), findsOneWidget);
    expect(find.text(l10n.compressEditorLongEdgeLabel), findsOneWidget);
    // A single image offers no broadcast action.
    expect(find.text(l10n.compressEditorApplyAll), findsNothing);

    // PNG is lossless: the quality control disappears.
    await tester.tap(_formatTab(l10n.compressEditorFormatPng));
    await tester.pump();
    expect(find.text(l10n.compressEditorQualityLabel), findsNothing);
    expect(find.text(l10n.compressEditorLongEdgeLabel), findsOneWidget);

    // 原图 turns the primary action into a plain close.
    await tester.tap(_formatTab(l10n.compressEditorFormatOriginal));
    await tester.pump();
    expect(find.text(l10n.compressEditorQualityLabel), findsNothing);
    expect(find.text(l10n.compressEditorLongEdgeLabel), findsNothing);
    expect(find.text(l10n.compressEditorDone), findsOneWidget);
    expect(find.text(l10n.compressEditorApply), findsNothing);

    // Back to JPEG, then drag the divider handle off the centre.
    await tester.tap(_formatTab(l10n.compressEditorFormatJpeg));
    await tester.pump();
    final startDivider = preview.controller.divider;
    await tester.dragFrom(
      tester.getCenter(find.byType(CompressPreview)),
      const Offset(60, 0),
    );
    await tester.pump();
    expect(preview.controller.divider, greaterThan(startDivider));

    // Applying remembers the parameters for the next session.
    await tester.tap(find.text(l10n.compressEditorApply));
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    // Let the remembered-parameter write reach the preference store.
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    expect(find.text('open'), findsOneWidget);
    expect(settings.manualCompressParams.maxLongEdge, 200);
    expect(settings.manualCompressParams.format, DownsizeFormat.jpeg);
  });
}

Future<void> _waitFor(
  bool Function() condition, {
  Duration timeout = const Duration(seconds: 30),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('condition was not met before the timeout');
    }
    await Future<void>.delayed(const Duration(milliseconds: 40));
  }
}

/// The format tab labelled [label], scoped to the segmented control so the
/// preview's own format tag can never be mistaken for it.
Finder _formatTab(String label) {
  return find.descendant(
    of: find.byType(SegmentedTabs),
    matching: find.text(label),
  );
}

Future<void> _pumpUntilFound(
  WidgetTester tester,
  Finder finder, {
  Duration timeout = const Duration(seconds: 30),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (finder.evaluate().isEmpty) {
    if (DateTime.now().isAfter(deadline)) {
      fail(
        '${finder.describeMatch(Plurality.one)} did not appear before the timeout',
      );
    }
    // runAsync lets the page's isolate work and file reads actually finish.
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 40)),
    );
    await tester.pump();
  }
  // pump() without a duration never advances the fake clock, so the 300ms
  // route transition would sit unfinished and shift the rightmost format tab
  // past the test window's edge where tap() can no longer reach it.
  await tester.pump(const Duration(milliseconds: 400));
  await tester.pump();
}

img.Image _noiseImage(int width, int height) {
  final random = math.Random(20260926);
  final image = img.Image(width: width, height: height);
  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      image.setPixelRgb(
        x,
        y,
        random.nextInt(256),
        random.nextInt(256),
        random.nextInt(256),
      );
    }
  }
  return image;
}
