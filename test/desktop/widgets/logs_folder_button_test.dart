import 'dart:io';

import 'package:Cuplivo/desktop/widgets/logs_folder_button.dart';
import 'package:Cuplivo/l10n/app_localizations.dart';
import 'package:Cuplivo/l10n/app_localizations_en.dart';
import 'package:Cuplivo/shared/widgets/snackbar.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final l10n = AppLocalizationsEn();

  setUp(() => AppSnackBarManager().dismissAll());
  tearDown(() => AppSnackBarManager().dismissAll());

  Widget harness(Future<void> Function() openFolder) {
    return MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: AppSnackBarOverlay(
        child: Scaffold(
          body: Center(child: LogsFolderButton(openFolder: openFolder)),
        ),
      ),
    );
  }

  testWidgets('tapping the button invokes the logs folder opener once', (
    tester,
  ) async {
    var calls = 0;
    await tester.pumpWidget(harness(() async => calls++));

    await tester.tap(find.byType(LogsFolderButton));
    await tester.pump();

    expect(calls, 1);
  });

  testWidgets('opener failure surfaces an error snackbar instead of silence', (
    tester,
  ) async {
    final error = ProcessException('explorer', const <String>[], 'boom', 1);
    await tester.pumpWidget(harness(() async => throw error));

    await tester.tap(find.byType(LogsFolderButton));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.text(l10n.logViewerOpenFolderFailed('$error')), findsOneWidget);

    // Drain the snackbar timer and exit animation so no ticker is left.
    await tester.pump(const Duration(seconds: 4));
    await tester.pump(const Duration(milliseconds: 400));
  });
}
