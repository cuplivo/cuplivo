import 'dart:io';
import 'dart:math' as math;

import 'package:Cuplivo/core/providers/settings_provider.dart';
import 'package:Cuplivo/features/home/widgets/image_compress/compress_editor.dart';
import 'package:Cuplivo/features/home/widgets/image_compress/compress_editor_controller.dart';
import 'package:Cuplivo/features/home/widgets/image_compress/compress_editor_preview.dart';
import 'package:Cuplivo/icons/lucide_adapter.dart';
import 'package:Cuplivo/l10n/app_localizations.dart';
import 'package:Cuplivo/shared/utils/format_bytes.dart';
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

  /// Opens the editor on a [width]×[height] fixture with [params] remembered, in
  /// a portrait window whose preview area is nowhere near the image's aspect
  /// ratio, and waits for the decode to land.
  Future<
    ({
      AppLocalizations l10n,
      SettingsProvider settings,
      CompressPreview preview,
    })
  >
  openEditor(
    WidgetTester tester, {
    required int width,
    required int height,
    required ManualCompressParams params,
    int totalImageCount = 1,
    String fixture = 'editor.png',
  }) async {
    tester.view.physicalSize = const Size(500, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    late AppLocalizations l10n;
    late SettingsProvider settings;
    late String path;
    await tester.runAsync(() async {
      l10n = await AppLocalizations.delegate.load(const Locale('en'));
      final harness = await createBusinessTestHarness();
      settings = SettingsProvider(harness.preferences);
      await settings.loaded;
      await settings.setManualCompressParams(params);
      path = await writeFixture(fixture, width, height);
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
                        totalImageCount: totalImageCount,
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
    await _pumpUntilFound(tester, find.byType(CompressPreview));
    return (
      l10n: l10n,
      settings: settings,
      preview: tester.widget<CompressPreview>(find.byType(CompressPreview)),
    );
  }

  testWidgets('shows the estimate as two sides with the change above the arrow', (
    tester,
  ) async {
    final opened = await openEditor(
      tester,
      width: 400,
      height: 260,
      params: const ManualCompressParams(
        format: DownsizeFormat.jpeg,
        quality: 60,
        maxLongEdge: 200,
      ),
    );
    final controller = opened.preview.controller;
    await _pumpUntilEstimate(tester, controller);

    final sourceBytes = controller.sourceBytes!;
    final estimated = controller.estimatedBytes!;
    final saved = ((sourceBytes - estimated) / sourceBytes * 100).round();

    // Left side: the original resolution above its size.
    expect(find.text('400×260'), findsOneWidget);
    expect(find.text(formatBytes(sourceBytes)), findsOneWidget);
    // Right side: the long edge is capped at 200, so 400×260 becomes 200×130.
    expect(find.text('200×130'), findsOneWidget);
    expect(find.text(formatBytes(estimated)), findsOneWidget);
    // The change sits above the arrow, which is an icon rather than a character.
    expect(
      saved,
      greaterThan(0),
      reason: 'a q60 JPEG of noise must be smaller',
    );
    expect(find.text(opened.l10n.compressEditorSavings(saved)), findsOneWidget);
    expect(find.byIcon(Lucide.ArrowRight), findsOneWidget);
  });

  testWidgets('原图 shows one side and the note instead of an arrow', (
    tester,
  ) async {
    final opened = await openEditor(
      tester,
      width: 400,
      height: 260,
      params: const ManualCompressParams(
        format: DownsizeFormat.jpeg,
        quality: 60,
        maxLongEdge: 200,
      ),
    );
    await _pumpUntilEstimate(tester, opened.preview.controller);

    await tester.tap(_formatTab(opened.l10n.compressEditorFormatOriginal));
    await tester.pump();

    expect(find.text(opened.l10n.compressEditorNoReencode), findsOneWidget);
    expect(find.text('400×260'), findsOneWidget);
    expect(find.byIcon(Lucide.ArrowRight), findsNothing);
    expect(find.text(opened.l10n.compressEditorDone), findsOneWidget);
  });

  testWidgets('the long-edge preset readout is the value that gets applied', (
    tester,
  ) async {
    final opened = await openEditor(
      tester,
      width: 1000,
      height: 700,
      fixture: 'wide.png',
      params: const ManualCompressParams(
        format: DownsizeFormat.jpeg,
        quality: 80,
        maxLongEdge: 1000,
      ),
    );

    // 25% of 1000 is 250, which used to fall below the slider's flat 256 floor.
    await tester.tap(find.text(opened.l10n.compressEditorLongEdgeQuarter));
    await tester.pump();

    final applied = opened.preview.controller.params.maxLongEdge;
    expect(applied, 250);
    // The long-edge slider is built before the quality one.
    final sliders = tester.widgetList<Slider>(find.byType(Slider)).toList();
    expect(sliders.first.value, 250);
    expect(find.text('250 px'), findsOneWidget);
  });

  testWidgets('a decode failure offers no action that would re-compress', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(500, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    late AppLocalizations l10n;
    late SettingsProvider settings;
    late String path;
    await tester.runAsync(() async {
      l10n = await AppLocalizations.delegate.load(const Locale('en'));
      final harness = await createBusinessTestHarness();
      settings = SettingsProvider(harness.preferences);
      await settings.loaded;
      final broken = File(p.join(root.path, 'broken.png'));
      await broken.writeAsBytes(List<int>.filled(256, 7));
      path = broken.path;
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
          home: CompressEditorPage(imagePath: path, totalImageCount: 2),
        ),
      ),
    );
    await _pumpUntilFound(tester, find.text(l10n.compressEditorDecodeFailed));

    // The copy says the image cannot be re-compressed...
    expect(find.text(l10n.compressEditorDecodeFailed), findsOneWidget);
    // ...so no action may try: a failed apply drops the attachment from the
    // message and locks sending.
    expect(find.text(l10n.compressEditorApply), findsNothing);
    expect(find.text(l10n.compressEditorApplyAll), findsNothing);
    expect(find.text(l10n.compressEditorCancel), findsOneWidget);
  });

  testWidgets('原图 chosen in the editor is remembered', (tester) async {
    final opened = await openEditor(
      tester,
      width: 400,
      height: 260,
      params: const ManualCompressParams(
        format: DownsizeFormat.jpeg,
        quality: 80,
        maxLongEdge: 400,
      ),
    );

    await tester.tap(_formatTab(opened.l10n.compressEditorFormatOriginal));
    await tester.pump();
    await tester.tap(find.text(opened.l10n.compressEditorDone));
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );

    expect(
      opened.settings.manualCompressParams.isNoOp,
      isTrue,
      reason: '原图 must seed the next session like JPEG and PNG do',
    );
  });

  test(
    '原图 drops the comparison tile instead of showing the previous encode',
    () async {
      final path = await writeFixture('switch.png', 400, 260);
      final controller = CompressEditorController(
        imagePath: path,
        initialParams: const ManualCompressParams(
          format: DownsizeFormat.jpeg,
          quality: 60,
          maxLongEdge: 200,
        ),
      );
      addTearDown(controller.dispose);

      await controller.prepare();
      const visible = Rect.fromLTWH(0, 0, 400, 260);
      controller.updateViewport(
        visible: visible,
        viewport: const Size(400, 260),
      );
      await _waitFor(() => controller.tile != null);
      expect(controller.tileSource, visible);

      controller.setParams(const ManualCompressParams());
      // Dropped eagerly: not even the frame before the debounced encode runs may
      // show the previous encode as if it were 原图's result.
      expect(controller.tile, isNull);
      expect(controller.tileSource, isNull);

      // The debounced pass must not bring a tile back either.
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(controller.params.isNoOp, isTrue);
      expect(controller.tile, isNull);
      expect(controller.tileSource, isNull);
    },
  );

  testWidgets('a remembered long edge is normalised to this image', (
    tester,
  ) async {
    final opened = await openEditor(
      tester,
      width: 400,
      height: 260,
      params: const ManualCompressParams(
        format: DownsizeFormat.jpeg,
        quality: 80,
        maxLongEdge: 3000,
      ),
    );

    // 3000 was remembered from a larger image; on a 400 px long edge it can only
    // mean "do not downscale", so the panel shows 400 and applies 400.
    expect(opened.preview.controller.params.maxLongEdge, 400);
    final sliders = tester.widgetList<Slider>(find.byType(Slider)).toList();
    expect(sliders.first.value, 400);
    expect(find.text('400 px'), findsOneWidget);
  });

  test('the preview cache is bounded in both dimensions', () {
    // A 12 MP phone photo: the long-edge cap binds.
    expect(previewCacheSize(4032, 3024), (width: 2048, height: 1536));
    // A long screenshot: capped too, and far below the pixel budget.
    final tall = previewCacheSize(1080, 8000);
    expect(tall.height, 2048);
    expect(tall.width * tall.height, lessThan(1000 * 1000));
    // A square 9 MP image: the pixel budget binds before the long edge.
    final square = previewCacheSize(3000, 3000);
    expect(square.width * square.height, lessThanOrEqualTo(4 * 1000 * 1000));
    // Small images are untouched.
    expect(previewCacheSize(400, 260), (width: 400, height: 260));
  });

  test('the estimate messages keep their glyphs', () async {
    final l10n = await AppLocalizations.delegate.load(const Locale('en'));
    expect(l10n.compressEditorSavings(85), '−85%');
    expect(l10n.compressEditorGrowth(12), '+12%');
  });

  test('decodeForPreview hands back pixels at the right offsets', () {
    // The cache is rebuilt from `outcome.rgba.buffer`, so a view with a non-zero
    // offset would shift every pixel of the comparison.
    final source = img.Image(width: 13, height: 7);
    for (var y = 0; y < source.height; y++) {
      for (var x = 0; x < source.width; x++) {
        source.setPixelRgb(x, y, 1 + x * 3, 2 + y * 5, (x * y) % 251);
      }
    }

    final outcome = decodeForPreview(img.encodePng(source));
    final rebuilt = img.Image.fromBytes(
      width: outcome.width,
      height: outcome.height,
      bytes: outcome.rgba.buffer,
      numChannels: 4,
      order: img.ChannelOrder.rgba,
    );

    for (var y = 0; y < source.height; y++) {
      for (var x = 0; x < source.width; x++) {
        final expected = source.getPixel(x, y);
        final actual = rebuilt.getPixel(x, y);
        expect(
          [actual.r, actual.g, actual.b],
          [expected.r, expected.g, expected.b],
          reason: 'pixel ($x,$y) shifted',
        );
      }
    }
  });
}

/// Waits for the debounced size estimate to land.
Future<void> _pumpUntilEstimate(
  WidgetTester tester,
  CompressEditorController controller, {
  Duration timeout = const Duration(seconds: 30),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (controller.estimating || controller.estimatedBytes == null) {
    if (DateTime.now().isAfter(deadline)) {
      fail('the size estimate never landed');
    }
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 40)),
    );
    await tester.pump(const Duration(milliseconds: 40));
  }
  await tester.pump();
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
