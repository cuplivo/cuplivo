import 'package:Cuplivo/features/chat/widgets/export_image_capture.dart';
import 'package:Cuplivo/features/chat/widgets/export_progress_overlay.dart';
import 'package:Cuplivo/l10n/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// The one card every export shows: what it says, and how much of it there is.
///
/// The stages name picture work, so a second export runs through them under a
/// label of its own — that override is the difference between a document and a
/// picture, and it is what this pins.
void main() {
  Future<void> pump(WidgetTester tester, ExportImageProgress progress) async {
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('en'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(body: ExportProgressContent(progress: progress)),
      ),
    );
  }

  testWidgets('a stage says what work it is', (tester) async {
    await pump(tester, const ExportImageProgress(ExportImageStage.preparing));
    expect(find.text('Preparing image…'), findsOneWidget);
  });

  testWidgets(
    'a label replaces the stage word for work that is not a picture',
    (tester) async {
      await pump(
        tester,
        const ExportImageProgress(
          ExportImageStage.preparing,
          label: 'Exporting…',
        ),
      );
      expect(find.text('Exporting…'), findsOneWidget);
      expect(find.text('Preparing image…'), findsNothing);
    },
  );

  testWidgets('a stage that counts says so, and the bar knows its share', (
    tester,
  ) async {
    await pump(
      tester,
      const ExportImageProgress(
        ExportImageStage.capturing,
        completed: 2,
        total: 5,
      ),
    );
    expect(find.text('Capturing image 2/5…'), findsOneWidget);
    final bar = tester.widget<LinearProgressIndicator>(
      find.byType(LinearProgressIndicator),
    );
    expect(bar.value, closeTo(0.4, 0.0001));
  });

  testWidgets('a stage with no size leaves the bar indeterminate', (
    tester,
  ) async {
    await pump(tester, const ExportImageProgress(ExportImageStage.saving));
    final bar = tester.widget<LinearProgressIndicator>(
      find.byType(LinearProgressIndicator),
    );
    expect(bar.value, isNull);
  });
}
