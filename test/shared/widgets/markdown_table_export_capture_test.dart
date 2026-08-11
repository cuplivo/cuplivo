import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as image_lib;
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:Cuplivo/core/providers/settings_provider.dart';
import 'package:Cuplivo/l10n/app_localizations.dart';
import 'package:Cuplivo/shared/widgets/markdown_with_highlight.dart';

Widget _tableHarness(
  String text, {
  double width = 360,
  double textScale = 1.0,
}) {
  SharedPreferences.setMockInitialValues({});
  return ChangeNotifierProvider(
    create: (_) => SettingsProvider(),
    child: MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(
        body: Builder(
          builder: (context) {
            return Align(
              alignment: Alignment.topLeft,
              child: SizedBox(
                width: width,
                child: MediaQuery(
                  // Mirror the chat message list, which wraps every message
                  // in a chat-font-scaled MediaQuery.
                  data: MediaQuery.of(
                    context,
                  ).copyWith(textScaler: TextScaler.linear(textScale)),
                  child: MarkdownWithCodeHighlight(text: text),
                ),
              ),
            );
          },
        ),
      ),
    ),
  );
}

void _overrideMarkdownTablePlatform(TargetPlatform platform) {
  markdownTableTargetPlatformOverride = platform;
  addTearDown(() => markdownTableTargetPlatformOverride = null);
}

// The capture pipeline awaits `endOfFrame` (frame-driven), real 80ms settle
// delays, engine rasterization and isolate processing (`compute`). Inside a
// single runAsync the test binding only produces frames via pump, so pumps
// are interleaved until the capture completes.
Future<Uint8List?> _captureTableForTest(
  WidgetTester tester, {
  bool forceSlices = false,
}) {
  return tester.runAsync<Uint8List?>(() async {
    final bodyFinder = find.byKey(const ValueKey('markdown-table-body'));
    final context = tester.element(
      bodyFinder.evaluate().isNotEmpty
          ? bodyFinder
          : find.byKey(const ValueKey('markdown-table-body-desktop')),
    );
    final capture = captureTablePngBytesForTesting(
      context,
      forceSlices: forceSlices,
    );
    for (var i = 0; i < 16; i += 1) {
      await tester.pump();
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    return await capture;
  });
}

Finder _tableBodyFinder() {
  final mobile = find.byKey(const ValueKey('markdown-table-body'));
  if (mobile.evaluate().isNotEmpty) return mobile;
  return find.byKey(const ValueKey('markdown-table-body-desktop'));
}

bool _imagesEqualPixels(image_lib.Image a, image_lib.Image b) {
  if (a.width != b.width || a.height != b.height) return false;
  for (var y = 0; y < a.height; y += 1) {
    for (var x = 0; x < a.width; x += 1) {
      final pa = a.getPixel(x, y);
      final pb = b.getPixel(x, y);
      if (pa.r != pb.r || pa.g != pb.g || pa.b != pb.b || pa.a != pb.a) {
        return false;
      }
    }
  }
  return true;
}

void main() {
  testWidgets('table export image capture returns full-table bytes', (
    tester,
  ) async {
    _overrideMarkdownTablePlatform(TargetPlatform.android);
    await tester.pumpWidget(
      _tableHarness(
        '| Name | Value |\n| - | -: |\n| Alpha | 42 |\n| Beta | 7 |',
      ),
    );
    await tester.pump();

    final bytes = await _captureTableForTest(tester);
    expect(bytes, isNotNull);

    final image = image_lib.decodePng(bytes!);
    expect(image, isNotNull);
    final bodySize = tester.getSize(_tableBodyFinder());
    expect(image!.width, (bodySize.width * 3).ceil());
    expect(image.height, (bodySize.height * 3).ceil());
    expect(image.width, greaterThan(0));
    expect(image.height, greaterThan(0));
  });

  testWidgets(
    'table export image slice fallback matches the whole-table capture',
    (tester) async {
      _overrideMarkdownTablePlatform(TargetPlatform.android);
      await tester.pumpWidget(
        _tableHarness(
          '| Name | Value |\n| - | -: |\n| Alpha | 42 |\n| Beta | 7 |',
        ),
      );
      await tester.pump();

      final fullBytes = await _captureTableForTest(tester);
      final sliceBytes = await _captureTableForTest(tester, forceSlices: true);

      expect(fullBytes, isNotNull);
      expect(sliceBytes, isNotNull);

      final fullImage = image_lib.decodePng(fullBytes!);
      final sliceImage = image_lib.decodePng(sliceBytes!);
      expect(fullImage, isNotNull);
      expect(sliceImage, isNotNull);
      expect(fullImage!.width, sliceImage!.width);
      expect(fullImage.height, sliceImage.height);
      expect(_imagesEqualPixels(fullImage, sliceImage), isTrue);
    },
  );

  testWidgets(
    'table export image slice fallback matches a chat-scaled layout',
    (tester) async {
      // Desktop: cells render via SelectableText.rich, which inherits the
      // MediaQuery text scaler (bare RichText does not). A chat font scale
      // therefore changes the in-tree row heights, and the slice rebuild
      // must see the same scale or the stitch seams misalign.
      await tester.pumpWidget(
        _tableHarness(
          '| Name | Value |\n| - | -: |\n| Alpha | 42 |\n| Beta | 7 |',
          textScale: 1.5,
          width: 900,
        ),
      );
      await tester.pump();

      final fullBytes = await _captureTableForTest(tester);
      final sliceBytes = await _captureTableForTest(tester, forceSlices: true);

      expect(fullBytes, isNotNull);
      expect(sliceBytes, isNotNull);

      final fullImage = image_lib.decodePng(fullBytes!);
      final sliceImage = image_lib.decodePng(sliceBytes!);
      expect(fullImage, isNotNull);
      expect(sliceImage, isNotNull);
      expect(fullImage!.width, sliceImage!.width);
      expect(fullImage.height, sliceImage.height);
      expect(_imagesEqualPixels(fullImage, sliceImage), isTrue);
    },
  );

  testWidgets('table export image slice fallback captures a tall table', (
    tester,
  ) async {
    _overrideMarkdownTablePlatform(TargetPlatform.android);
    final rows = <String>[
      '| # | Label |',
      '| - | - |',
      for (var i = 0; i < 40; i += 1) '| $i | row-$i |',
    ].join('\n');
    await tester.pumpWidget(_tableHarness(rows));
    await tester.pump();

    final bytes = await _captureTableForTest(tester, forceSlices: true);
    expect(bytes, isNotNull);

    final image = image_lib.decodePng(bytes!);
    expect(image, isNotNull);
    final bodySize = tester.getSize(_tableBodyFinder());
    expect(image!.width, (bodySize.width * 3).ceil());
    expect(image.height, (bodySize.height * 3).ceil());
    expect(image.height, greaterThan(2000));
  });
}
