import 'package:Cuplivo/core/providers/backup_reminder_provider.dart';
import 'package:Cuplivo/core/providers/settings_provider.dart';
import 'package:Cuplivo/core/services/chat/chat_service.dart';
import 'package:Cuplivo/core/services/trash_restore_coordinator.dart';
import 'package:Cuplivo/features/backup/pages/backup_page.dart';
import 'package:Cuplivo/features/settings/pages/new/data_settings_page.dart';
import 'package:Cuplivo/l10n/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

Widget _buildHarness(Widget home) {
  final settings = SettingsProvider();
  addTearDown(settings.dispose);
  final chatService = ChatService();
  addTearDown(chatService.dispose);
  final coordinator = TrashRestoreCoordinator(chatService: chatService);
  final reminder = BackupReminderProvider(autoLoad: false);
  addTearDown(reminder.dispose);
  return MultiProvider(
    providers: [
      ChangeNotifierProvider<SettingsProvider>.value(value: settings),
      ChangeNotifierProvider<ChatService>.value(value: chatService),
      Provider<TrashRestoreCoordinator>.value(value: coordinator),
      ChangeNotifierProvider<BackupReminderProvider>.value(value: reminder),
    ],
    child: MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: home,
    ),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(const {});
  });

  testWidgets('autoOpenBackup eventually pushes BackupPage', (tester) async {
    await tester.binding.setSurfaceSize(const Size(800, 1400));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      _buildHarness(const DataSettingsPage(autoOpenBackup: true)),
    );
    await tester.pumpAndSettle();

    expect(find.byType(BackupPage), findsOneWidget);
  });

  testWidgets('plain DataSettingsPage renders the three rows without pushing', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(800, 1400));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(_buildHarness(const DataSettingsPage()));
    await tester.pumpAndSettle();

    final l10n = AppLocalizations.of(
      tester.element(find.byType(DataSettingsPage)),
    )!;
    expect(find.text(l10n.settingsPageBackup), findsOneWidget);
    expect(find.text(l10n.settingsPageChatStorage), findsOneWidget);
    expect(find.text(l10n.settingsPageStatistics), findsOneWidget);
    expect(find.byType(BackupPage), findsNothing);
  });
}
