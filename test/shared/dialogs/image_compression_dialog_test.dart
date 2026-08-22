import 'package:Cuplivo/l10n/app_localizations.dart';
import 'package:Cuplivo/shared/dialogs/image_compression_dialog.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:syncfusion_flutter_sliders/sliders.dart';

void main() {
  testWidgets('image compression dialog uses overlay-free sliders on Windows', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    try {
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Builder(
            builder: (context) => TextButton(
              onPressed: () => ImageCompressionDialog.show(
                context,
                imagePath: 'missing-image.png',
                totalImageCount: 1,
                originalWidth: 2048,
                originalHeight: 1024,
                hasRealAlpha: true,
                onCompress: (_) async {},
              ),
              child: const Text('open'),
            ),
          ),
        ),
      );

      await tester.tap(find.text('open'));
      await tester.pump();

      expect(find.byType(Slider), findsNothing);
      expect(find.byType(SfSlider), findsNWidgets(2));

      final sliders = tester
          .widgetList<SfSlider>(find.byType(SfSlider))
          .toList();
      expect(sliders.first.onChanged, isNull);
      expect(sliders.first.stepSize, 1);
      expect(sliders.last.onChanged, isNotNull);
      expect(sliders.last.stepSize, 64);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });
}
