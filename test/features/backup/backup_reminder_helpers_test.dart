import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:Cuplivo/features/backup/widgets/backup_reminder_helpers.dart';
import 'package:Cuplivo/l10n/app_localizations.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('mobile time picker uses wheel selection', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    try {
      int? selectedMinutes;

      await tester.pumpWidget(
        MaterialApp(
          locale: const Locale('en'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Builder(
            builder: (context) {
              return Scaffold(
                body: Center(
                  child: TextButton(
                    onPressed: () async {
                      selectedMinutes = await showBackupReminderTimePicker(
                        context,
                        initialMinutes: 23 * 60 + 59,
                      );
                    },
                    child: const Text('open'),
                  ),
                ),
              );
            },
          ),
        ),
      );

      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      expect(find.text('Reminder Time'), findsWidgets);
      expect(find.byType(BottomSheet), findsOneWidget);
      expect(
        find.byKey(const ValueKey('backup-reminder-time-mobile-sheet')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('backup-reminder-time-mobile-actions')),
        findsOneWidget,
      );
      expect(find.byType(Divider), findsNothing);
      expect(find.byType(TextFormField), findsNothing);
      expect(find.byType(CupertinoPicker), findsNWidgets(2));
      _expectAllPickersLooping(tester);

      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      expect(selectedMinutes, 23 * 60 + 59);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('mobile time picker cancel returns null', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    try {
      int? selectedMinutes = -1;

      await tester.pumpWidget(
        MaterialApp(
          locale: const Locale('en'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Builder(
            builder: (context) {
              return Scaffold(
                body: Center(
                  child: TextButton(
                    onPressed: () async {
                      selectedMinutes = await showBackupReminderTimePicker(
                        context,
                        initialMinutes: 0,
                      );
                    },
                    child: const Text('open'),
                  ),
                ),
              );
            },
          ),
        ),
      );

      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();

      expect(selectedMinutes, isNull);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('desktop time picker uses wheel selection', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    try {
      int? selectedMinutes;

      await tester.pumpWidget(
        MaterialApp(
          locale: const Locale('en'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Builder(
            builder: (context) {
              return Scaffold(
                body: Center(
                  child: TextButton(
                    onPressed: () async {
                      selectedMinutes = await showBackupReminderTimePicker(
                        context,
                        initialMinutes: 8 * 60,
                      );
                    },
                    child: const Text('open'),
                  ),
                ),
              );
            },
          ),
        ),
      );

      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      expect(find.text('Reminder Time'), findsWidgets);
      expect(find.byType(TextFormField), findsNothing);
      expect(find.byType(CupertinoPicker), findsNWidgets(2));
      _expectAllPickersLooping(tester);

      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      expect(selectedMinutes, 8 * 60);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('custom days dialog can be cancelled without controller errors', (
    tester,
  ) async {
    int? selectedDays;

    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('en'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Builder(
          builder: (context) {
            return Scaffold(
              body: Center(
                child: TextButton(
                  onPressed: () async {
                    selectedDays = await showBackupReminderCustomDaysDialog(
                      context,
                      initialDays: 7,
                    );
                  },
                  child: const Text('open custom'),
                ),
              ),
            );
          },
        ),
      ),
    );

    await tester.tap(find.text('open custom'));
    await tester.pumpAndSettle();

    expect(find.text('Custom Frequency'), findsOneWidget);
    expect(find.byType(TextFormField), findsOneWidget);

    await tester.tap(find.text('Cancel'));
    await tester.pump();

    expect(tester.takeException(), isNull);

    await tester.pumpAndSettle();
    expect(selectedDays, isNull);
  });

  testWidgets('entry relative time follows its thresholds', (tester) async {
    Future<String> label(DateTime? value) async {
      await tester.pumpWidget(
        MaterialApp(
          locale: const Locale('en'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Builder(
            builder: (context) => Scaffold(
              body: Text(backupEntryRelativeTimeLabel(context, value)),
            ),
          ),
        ),
      );
      return (tester.widget<Text>(find.byType(Text))).data!;
    }

    expect(await label(null), 'Never');

    final now = DateTime.now();
    expect(await label(now.subtract(const Duration(seconds: 30))), 'Just now');
    expect(await label(now.subtract(const Duration(minutes: 5))), '5 min ago');
    expect(await label(now.subtract(const Duration(hours: 3))), '3 hr ago');
    expect(await label(now.subtract(const Duration(days: 2))), '2 days ago');
  });

  testWidgets('entry relative time falls back to short date after 7 days', (
    tester,
  ) async {
    final now = DateTime.now();
    final tenDaysAgo = now.subtract(const Duration(days: 10));

    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('en'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Builder(
          builder: (context) {
            final label = backupEntryRelativeTimeLabel(context, tenDaysAgo);
            return Scaffold(
              body: Column(
                children: [
                  Text(label),
                  Text(
                    MaterialLocalizations.of(
                      context,
                    ).formatShortMonthDay(tenDaysAgo),
                  ),
                ],
              ),
            );
          },
        ),
      ),
    );

    final label = tester.widget<Text>(find.byType(Text).first).data!;
    final shortDate = tester.widget<Text>(find.byType(Text).last).data!;
    expect(label, shortDate);
    expect(label.contains('ago'), isFalse);
  });

  testWidgets('entry relative time includes the year for cross-year dates', (
    tester,
  ) async {
    final oldDate = DateTime.now().subtract(const Duration(days: 400));

    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('en'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Builder(
          builder: (context) => Scaffold(
            body: Text(backupEntryRelativeTimeLabel(context, oldDate)),
          ),
        ),
      ),
    );

    final label = tester.widget<Text>(find.byType(Text)).data!;
    expect(label, contains(oldDate.year.toString()));
    expect(label.contains('ago'), isFalse);
  });
}

void _expectAllPickersLooping(WidgetTester tester) {
  final pickers = tester.widgetList<CupertinoPicker>(
    find.byType(CupertinoPicker),
  );
  for (final picker in pickers) {
    expect(picker.childDelegate, isA<ListWheelChildLoopingListDelegate>());
  }
}
