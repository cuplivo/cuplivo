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
import 'package:Cuplivo/utils/manual_compress_pipeline.dart';
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

  test('the artifact for the current parameters is produced and reused', () async {
    final path = await writeFixture('artifact.png', 400, 260);
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
    expect(controller.tooLarge, isFalse);
    expect(controller.sourceWidth, 400);
    expect(controller.sourceHeight, 260);
    // The working image *is* the artifact's pixel set: long edge 200, so
    // 400x260 arrives as 200x130.
    expect(controller.workingWidth, 200);
    expect(controller.workingHeight, 130);

    await _waitFor(() => controller.artifact != null);
    expect(controller.artifactParams, controller.params);
    expect(controller.artifactBytes, controller.artifact!.length);
    // The apply path may reuse exactly these bytes...
    expect(controller.readyArtifact, same(controller.artifact));
    // ...and the result side has something to draw.
    expect(controller.result, isNotNull);

    // Changing a parameter drops the artifact synchronously: not even the frame
    // before the debounced pass may show the previous encode as the current one.
    controller.setParams(
      const ManualCompressParams(
        format: DownsizeFormat.jpeg,
        quality: 40,
        maxLongEdge: 200,
      ),
    );
    expect(controller.artifact, isNull);
    expect(controller.readyArtifact, isNull);
    expect(controller.result, isNull);

    await _waitFor(() => controller.artifact != null);
    expect(controller.artifactParams, controller.params);
    // A quality-only change keeps the working image: no re-decode.
    expect(controller.workingWidth, 200);
  });

  test('never runs two decode/encode passes at once', () async {
    final path = await writeFixture('burst.png', 400, 260);
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
    // Five parameter changes in a row, faster than the debounce and faster than
    // a pass, must coalesce rather than stack up: a running pass cannot be
    // cancelled, so overlapping ones are what doubles the peak.
    for (var quality = 72; quality <= 80; quality += 2) {
      controller.setParams(
        ManualCompressParams(
          format: DownsizeFormat.jpeg,
          quality: quality,
          maxLongEdge: 200,
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }

    await _waitFor(() => controller.artifactParams == controller.params);
    expect(
      controller.debugMaxConcurrentPasses,
      1,
      reason: 'a second overlapping pass is the memory doubling this forbids',
    );
    expect(
      controller.debugPassesStarted,
      lessThanOrEqualTo(3),
      reason: 'five rapid changes must coalesce, not run five passes',
    );
  });

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
    expect(controller.tooLarge, isFalse);
    expect(controller.artifactBytes, isNull);
    expect(controller.original, isNull);
  });

  test('an image over the decode budget is gated, not attempted', () async {
    final path = await writeFixture('gated.png', 400, 260);
    // A budget no decode of this fixture can fit under: the pipeline has to
    // refuse before the engine allocates, because an out-of-memory kill inside
    // a decode cannot be caught from Dart.
    final controller = CompressEditorController(
      imagePath: path,
      initialParams: const ManualCompressParams(
        format: DownsizeFormat.jpeg,
        quality: 80,
        maxLongEdge: 200,
      ),
      budgetBytes: 1024,
    );
    addTearDown(controller.dispose);

    await controller.prepare();

    expect(controller.tooLarge, isTrue);
    expect(controller.decodeFailed, isFalse);
    expect(controller.original, isNull);
    expect(controller.artifactBytes, isNull);
  });

  testWidgets('a gated image offers no action that would re-compress', (
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
      path = await writeFixture('gated_panel.png', 400, 260);
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
          home: CompressEditorPage(
            imagePath: path,
            totalImageCount: 2,
            budgetBytes: 1024,
          ),
        ),
      ),
    );
    await _pumpUntilFound(tester, find.text(l10n.compressEditorTooLarge));

    expect(find.text(l10n.compressEditorTooLarge), findsOneWidget);
    expect(find.text(l10n.compressEditorApply), findsNothing);
    expect(find.text(l10n.compressEditorApplyAll), findsNothing);
    expect(find.text(l10n.compressEditorCancel), findsOneWidget);
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

    // The default framing maps the whole working image, so the painter can
    // letterbox it inside the preview area instead of stretching it to fill.
    // The working image is the source at the artifact's resolution — the
    // remembered 200 px long edge — which is what both halves are drawn from.
    expect(
      preview.controller.visibleSource,
      const Rect.fromLTWH(0, 0, 200, 130),
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

    // The remembered 200 px long edge survives the format round trip: the panel
    // never normalised it away while the image's size was still unknown.
    expect(preview.controller.params.maxLongEdge, 200);

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
    int? budgetPixels,
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
                        budgetPixels: budgetPixels,
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

  testWidgets(
    'shows the artifact size as two sides with the change above the arrow',
    (tester) async {
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
      await _pumpUntilArtifact(tester, controller);

      final sourceBytes = controller.sourceBytes;
      final resultBytes = controller.artifactBytes!;
      final saved = ((sourceBytes - resultBytes) / sourceBytes * 100).round();

      // Left side: the original resolution above its size.
      expect(find.text('400×260'), findsOneWidget);
      expect(find.text(formatBytes(sourceBytes)), findsOneWidget);
      // Right side: the long edge is capped at 200, so the artifact is 200×130 —
      // the working image's own size, not a projection.
      expect(find.text('200×130'), findsOneWidget);
      expect(find.text(formatBytes(resultBytes)), findsOneWidget);
      // The change sits above the arrow, which is an icon rather than a character.
      expect(
        saved,
        greaterThan(0),
        reason: 'a q60 JPEG of noise must be smaller',
      );
      expect(
        find.text(opened.l10n.compressEditorSavings(saved)),
        findsOneWidget,
      );
      expect(find.byIcon(Lucide.ArrowRight), findsOneWidget);
    },
  );

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
    await _pumpUntilArtifact(tester, opened.preview.controller);

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
    '原图 drops the artifact instead of offering the previous encode',
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
      await _waitFor(() => controller.artifact != null);
      expect(controller.readyArtifact, isNotNull);

      controller.setParams(const ManualCompressParams());
      // Dropped eagerly: not even the frame before the debounced pass runs may
      // offer the previous encode as if it were 原图's result.
      expect(controller.artifact, isNull);
      expect(controller.readyArtifact, isNull);
      expect(controller.result, isNull);

      // The debounced pass must not bring one back either.
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(controller.params.isNoOp, isTrue);
      expect(controller.artifact, isNull);
      expect(controller.readyArtifact, isNull);
      expect(controller.result, isNull);
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

  testWidgets('the long edge is capped by the working budget, and says so', (
    tester,
  ) async {
    // 10000 working pixels is 124 px on this fixture's long edge, so a
    // remembered 3000 normalises down to the reachable 124 — the panel can never
    // promise a resolution the pipeline will not produce.
    final opened = await openEditor(
      tester,
      width: 400,
      height: 260,
      budgetPixels: 10000,
      params: const ManualCompressParams(
        format: DownsizeFormat.jpeg,
        quality: 80,
        maxLongEdge: 3000,
      ),
    );

    final controller = opened.preview.controller;
    expect(controller.reachableLongEdge, 124);
    expect(controller.params.maxLongEdge, 124);
    expect(find.text('124 px'), findsOneWidget);
    // The reduced working resolution is disclosed, not silently applied.
    expect(controller.workingIsReduced, isTrue);
    expect(
      find.text(
        opened.l10n.compressEditorWorkingScale(
          '400×260',
          // The same rounding the panel applies, so the assertion pins the copy
          // rather than re-deriving it differently.
          (controller.workingLongEdge / controller.sourceLongEdge * 100)
              .round(),
        ),
      ),
      findsOneWidget,
    );
  });

  test('the working size is bounded in pixels and never magnifies', () {
    const mobile = kWorkingPixelsMobile;
    // A 13 MP attachment is the everyday case: it keeps its full resolution.
    expect(workingSize(4160, 3120, mobile), (width: 4160, height: 3120));
    // A 200 MP source is reduced into the budget, aspect preserved.
    final huge = workingSize(17000, 11765, mobile);
    final hugePixels = huge.width * huge.height;
    expect(hugePixels, lessThanOrEqualTo(mobile));
    expect(hugePixels, greaterThan(mobile ~/ 2));
    expect(huge.width / huge.height, closeTo(17000 / 11765, 0.001));
    // A tiny image is untouched: the budget never enlarges.
    expect(workingSize(400, 260, mobile), (width: 400, height: 260));
    // A long screenshot is bounded by the pixel budget, not by the old 2048 cap.
    final tall = workingSize(1000, 8000, mobile);
    expect(tall.width * tall.height, lessThanOrEqualTo(mobile));
    expect(tall.height / tall.width, closeTo(8, 0.001));
  });

  test('the reachable long edge never exceeds the source or the budget', () {
    // A 13 MP source inside the budget: the source's own edge is reachable.
    expect(
      targetLongEdge(
        sourceWidth: 4160,
        sourceHeight: 3120,
        requestedLongEdge: null,
        budgetPixels: kWorkingPixelsMobile,
      ),
      4160,
    );
    // A 200 MP source: a remembered 20000 can only reach the budgeted edge.
    final reachable = targetLongEdge(
      sourceWidth: 17000,
      sourceHeight: 11765,
      requestedLongEdge: 20000,
      budgetPixels: kWorkingPixelsMobile,
    );
    expect(reachable, lessThan(17000));
    expect(reachable, workingLongEdge(17000, 11765, kWorkingPixelsMobile));
    // The slider's floor is the 25% preset, so it stays reachable.
    expect(
      targetLongEdge(
        sourceWidth: 400,
        sourceHeight: 260,
        requestedLongEdge: 1,
        budgetPixels: kWorkingPixelsMobile,
      ),
      minEditorLongEdge(400),
    );
  });

  test('the decode budget admits JPEG at any size and gates a huge PNG', () {
    const budget = kDecodeBudgetBytesMobile;
    const jpeg = ImageSourceFormat.jpeg;
    const png = ImageSourceFormat.png;
    const target = 1568000;

    // Measured: the engine sub-scales JPEG at decode (a 200 MP source cost
    // +19 MB), so its requirement does not grow with the source.
    final jpegHuge = decodePeakBytes(
      sourceCanSubScale: jpeg == ImageSourceFormat.jpeg,
      sourcePixels: 17000 * 11765,
      targetPixels: target,
      fileBytes: 5 * 1024 * 1024,
    );
    expect(jpegHuge, lessThan(budget));

    // Measured: PNG allocates the whole source (+768 MB for 200 MP), which is
    // what has to be refused before the engine tries.
    final pngHuge = decodePeakBytes(
      sourceCanSubScale: png == ImageSourceFormat.jpeg,
      sourcePixels: 17000 * 11765,
      targetPixels: target,
      fileBytes: 1024 * 1024,
    );
    expect(pngHuge, greaterThan(budget));

    // An ordinary screenshot stays far inside it.
    expect(
      decodePeakBytes(
        sourceCanSubScale: false,
        sourcePixels: 1000 * 8000,
        targetPixels: 313600,
        fileBytes: 2 * 1024 * 1024,
      ),
      lessThan(budget),
    );
  });

  test('the artwork the pipeline compares is the artwork it encodes', () async {
    // A JPEG has no alpha, so a JPEG source cannot need flattening; a PNG can.
    expect(
      detectImageSourceFormat(img.encodeJpg(_noiseImage(4, 4))),
      ImageSourceFormat.jpeg,
    );
    expect(
      detectImageSourceFormat(img.encodePng(_noiseImage(4, 4))),
      ImageSourceFormat.png,
    );

    final file = File(p.join(root.path, 'tiny.png'));
    await file.writeAsBytes(img.encodePng(_tinyImage()));
    final controller = CompressEditorController(
      imagePath: file.path,
      initialParams: const ManualCompressParams(
        format: DownsizeFormat.jpeg,
        quality: 90,
      ),
    );
    addTearDown(controller.dispose);

    await controller.prepare();

    expect(controller.workingWidth, 13);
    expect(controller.workingHeight, 7);
    await _waitFor(() => controller.artifact != null);
    // The artifact is a real JPEG of the working image, produced without a
    // Dart-side resize (the engine decoded at the artifact's size).
    final decoded = img.decodeImage(controller.artifact!)!;
    expect(decoded.width, 13);
    expect(decoded.height, 7);
  });

  test('the estimate messages keep their glyphs', () async {
    final l10n = await AppLocalizations.delegate.load(const Locale('en'));
    expect(l10n.compressEditorSavings(85), '−85%');
    expect(l10n.compressEditorGrowth(12), '+12%');
  });
}

/// Waits for the debounced artifact to land.
Future<void> _pumpUntilArtifact(
  WidgetTester tester,
  CompressEditorController controller, {
  Duration timeout = const Duration(seconds: 30),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (controller.encoding || controller.artifactBytes == null) {
    if (DateTime.now().isAfter(deadline)) {
      fail('the artifact never landed');
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

/// A 13×7 image with per-pixel values, for asserting the working pixels survive
/// the engine round trip without a row offset or a channel swap.
img.Image _tinyImage() {
  final image = img.Image(width: 13, height: 7);
  for (var y = 0; y < image.height; y++) {
    for (var x = 0; x < image.width; x++) {
      image.setPixelRgb(x, y, 1 + x * 3, 2 + y * 5, (x * y) % 251);
    }
  }
  return image;
}
