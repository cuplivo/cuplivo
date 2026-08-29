import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:Cuplivo/core/database/business_preferences.dart';

import 'package:Cuplivo/core/providers/auto_snapshot_provider.dart';
import 'package:Cuplivo/core/providers/backup_reminder_provider.dart';
import 'package:Cuplivo/core/providers/settings_provider.dart';
import 'package:Cuplivo/core/services/chat/chat_service.dart';
import 'package:Cuplivo/core/services/trash_restore_coordinator.dart';
import 'package:Cuplivo/features/backup/pages/backup_page.dart';
import 'package:Cuplivo/l10n/app_localizations.dart';

var businessPrefs = BusinessPreferences.memoryForTests();

Future<BackupReminderProvider> _createReminderProvider({
  bool enabled = false,
}) async {
  final provider = BackupReminderProvider(
    preferences: businessPrefs,
    autoLoad: false,
  );
  await provider.load(startTimer: false);
  if (enabled) {
    await provider.saveSchedule(
      enabled: true,
      intervalDays: 7,
      reminderMinutesOfDay: 8 * 60 + 30,
      now: DateTime(2026, 5, 5, 9),
    );
  }
  return provider;
}

Widget _buildHarness({
  required SettingsProvider settings,
  required BackupReminderProvider reminder,
}) {
  final chatService = ChatService();
  final coordinator = TrashRestoreCoordinator(
    preferences: businessPrefs,
    chatService: chatService,
  );
  return MultiProvider(
    providers: [
      Provider<BusinessPreferences>.value(value: businessPrefs),
      ChangeNotifierProvider<SettingsProvider>.value(value: settings),
      ChangeNotifierProvider<ChatService>.value(value: chatService),
      ChangeNotifierProvider<BackupReminderProvider>.value(value: reminder),
      ChangeNotifierProvider<AutoSnapshotProvider>(
        create: (_) => AutoSnapshotProvider(
          preferences: businessPrefs,
          chatService: chatService,
          autoLoad: false,
        ),
      ),
    ],
    child: MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: BackupPage(trashRestoreCoordinator: coordinator),
    ),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('BackupPage reminder settings', () {
    testWidgets('shows reminder switch while disabled', (tester) async {
      await tester.binding.setSurfaceSize(const Size(900, 2000));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      businessPrefs = BusinessPreferences.memoryForTests({});
      final settings = SettingsProvider(preferences: businessPrefs);
      final reminder = await _createReminderProvider();

      await tester.pumpWidget(
        _buildHarness(settings: settings, reminder: reminder),
      );
      await tester.pump();

      expect(find.text('Backup Reminder'), findsOneWidget);
      expect(find.text('Remind me to back up'), findsOneWidget);
      expect(find.text('Frequency'), findsNothing);
      expect(find.text('Backup Due'), findsNothing);
    });

    testWidgets('shows frequency and reminder status when enabled', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(const Size(900, 2000));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      businessPrefs = BusinessPreferences.memoryForTests({});
      final settings = SettingsProvider(preferences: businessPrefs);
      final reminder = await _createReminderProvider(enabled: true);

      await tester.pumpWidget(
        _buildHarness(settings: settings, reminder: reminder),
      );
      await tester.pump();

      expect(find.text('Backup Reminder'), findsOneWidget);
      expect(find.text('Frequency'), findsOneWidget);
      expect(find.text('Every week'), findsOneWidget);
      expect(find.text('Reminder Time'), findsOneWidget);
      expect(find.text('Backup Contents'), findsOneWidget);
    });

    testWidgets('adds a due row to the reminder card when overdue', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(const Size(900, 2000));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      businessPrefs = BusinessPreferences.memoryForTests({});
      final settings = SettingsProvider(preferences: businessPrefs);
      final reminder = await _createReminderProvider(enabled: true);
      // The schedule anchored on 2026-05-05 09:00 with 7-day interval places
      // the next reminder at 2026-05-12 08:30 — check that a due state only
      // ADDS a row (the hero card is never swapped).
      reminder.evaluateDue(DateTime(2026, 5, 15, 9));

      await tester.pumpWidget(
        _buildHarness(settings: settings, reminder: reminder),
      );
      await tester.pump();

      expect(find.text('Backup Due'), findsOneWidget);
      expect(find.text('Backup Now'), findsOneWidget);
      expect(find.text('No Backup Yet'), findsOneWidget);
    });

    testWidgets('entry-visibility switch toggles and persists the flag', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(const Size(900, 2000));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      businessPrefs = BusinessPreferences.memoryForTests({});
      final settings = SettingsProvider(preferences: businessPrefs);
      final reminder = await _createReminderProvider();

      await tester.pumpWidget(
        _buildHarness(settings: settings, reminder: reminder),
      );
      await tester.pump();

      expect(find.text('Always Show Backup Entry'), findsOneWidget);
      expect(reminder.entryAlwaysVisible, isTrue);

      await tester.tap(find.text('Always Show Backup Entry'));
      await tester.pump();

      expect(reminder.entryAlwaysVisible, isFalse);

      final reloaded = await _createReminderProvider();
      expect(reloaded.entryAlwaysVisible, isFalse);
    });
  });
}
