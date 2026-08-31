import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:Cuplivo/core/database/business_preferences.dart';
import 'package:Cuplivo/core/providers/settings_provider.dart';
import 'package:Cuplivo/features/assistant/widgets/proactive_care_datetime_picker.dart';
import 'package:Cuplivo/l10n/app_localizations.dart';
import 'package:Cuplivo/shared/widgets/snackbar.dart';

void main() {
  testWidgets('non-future selection shows feedback and keeps picker open', (
    tester,
  ) async {
    DateTime? result;
    final preferences = BusinessPreferences.memoryForTests();
    await tester.pumpWidget(
      ChangeNotifierProvider(
        create: (_) => SettingsProvider(preferences: preferences),
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () async {
                  result = await showProactiveCareDateTimePicker(
                    context,
                    initial: DateTime.now().add(const Duration(days: 1)),
                  );
                },
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    final now = DateTime.now();
    tester
        .widget<CupertinoDatePicker>(find.byType(CupertinoDatePicker))
        .onDateTimeChanged(DateTime(now.year, now.month, now.day));
    final wheels = tester.widgetList<CupertinoPicker>(
      find.byType(CupertinoPicker),
    );
    wheels.first.onSelectedItemChanged?.call(0);
    wheels.last.onSelectedItemChanged?.call(0);
    await tester.pump();

    final l10n = AppLocalizations.of(
      tester.element(find.byType(CupertinoDatePicker)),
    )!;
    await tester.tap(find.text(l10n.backupPageSave));
    await tester.pump();

    expect(result, isNull);
    expect(find.byType(CupertinoDatePicker), findsOneWidget);
    expect(
      AppSnackBarManager().activeToasts.first.notification.message,
      l10n.assistantEditProactiveCareTimeMustBeFuture,
    );

    await tester.pump(const Duration(seconds: 4));
    await tester.pump(const Duration(milliseconds: 400));
  });
}
