import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:Cuplivo/core/database/business_preferences.dart';

import 'package:Cuplivo/core/models/backup.dart';
import 'package:Cuplivo/core/providers/backup_provider.dart';
import 'package:Cuplivo/core/providers/backup_reminder_provider.dart';
import 'package:Cuplivo/core/providers/s3_backup_provider.dart';
import 'package:Cuplivo/core/providers/settings_provider.dart';
import 'package:Cuplivo/core/services/chat/chat_service.dart';
import 'package:Cuplivo/core/services/trash_restore_coordinator.dart';
import 'package:Cuplivo/desktop/setting/backup_pane.dart';
import 'package:Cuplivo/features/backup/pages/backup_page.dart';
import 'package:Cuplivo/features/backup/widgets/backup_hero_card.dart';
import 'package:Cuplivo/l10n/app_localizations.dart';

var businessPrefs = BusinessPreferences.memoryForTests();

Future<BackupReminderProvider> _createReminderProvider() async {
  final provider = BackupReminderProvider(
    preferences: businessPrefs,
    autoLoad: false,
  );
  await provider.load(startTimer: false);
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
    ],
    child: MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: BackupPage(trashRestoreCoordinator: coordinator),
    ),
  );
}

Widget _buildDesktopHarness({
  required SettingsProvider settings,
  required BackupReminderProvider reminder,
}) {
  final chatService = ChatService();

  return MultiProvider(
    providers: [
      Provider<BusinessPreferences>.value(value: businessPrefs),
      ChangeNotifierProvider<SettingsProvider>.value(value: settings),
      ChangeNotifierProvider<ChatService>.value(value: chatService),
      Provider(
        create: (_) => TrashRestoreCoordinator(
          preferences: businessPrefs,
          chatService: chatService,
        ),
      ),
      ChangeNotifierProvider<BackupReminderProvider>.value(value: reminder),
      ChangeNotifierProvider<BackupProvider>(
        create: (_) => BackupProvider(
          preferences: businessPrefs,
          chatService: chatService,
          trashRestoreCoordinator: TrashRestoreCoordinator(
            preferences: businessPrefs,
            chatService: chatService,
          ),
          initialConfig: settings.webDavConfig,
        ),
      ),
      ChangeNotifierProvider<S3BackupProvider>(
        create: (_) => S3BackupProvider(
          preferences: businessPrefs,
          chatService: chatService,
          trashRestoreCoordinator: TrashRestoreCoordinator(
            preferences: businessPrefs,
            chatService: chatService,
          ),
          initialConfig: settings.s3Config,
        ),
      ),
    ],
    child: MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: const Scaffold(body: DesktopBackupPane()),
    ),
  );
}

Future<void> _pumpBackupPage(
  WidgetTester tester, {
  required SettingsProvider settings,
}) async {
  final reminder = await _createReminderProvider();

  await tester.pumpWidget(
    _buildHarness(settings: settings, reminder: reminder),
  );
  await tester.pump();
}

Future<void> _pumpDesktopBackupPane(
  WidgetTester tester, {
  required SettingsProvider settings,
}) async {
  final reminder = await _createReminderProvider();

  await tester.pumpWidget(
    _buildDesktopHarness(settings: settings, reminder: reminder),
  );
  await tester.pump();
}

Future<void> _openSettingsPage(WidgetTester tester, String label) async {
  final target = find.text(label);
  await tester.scrollUntilVisible(
    target,
    120,
    scrollable: find.byType(Scrollable).first,
  );
  await tester.pumpAndSettle();
  await tester.tap(target.first);
  await tester.pumpAndSettle();
}

void _expectAbove(WidgetTester tester, String upper, String lower) {
  final upperTop = tester.getTopLeft(find.text(upper).first).dy;
  final lowerTop = tester.getTopLeft(find.text(lower).first).dy;

  expect(upperTop, lessThan(lowerTop));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('BackupPage redesigned layout', () {
    setUp(() {
      SharedPreferences.setMockInitialValues({});
      businessPrefs = BusinessPreferences.memoryForTests(const {});
    });

    testWidgets('opens WebDAV config as a bottom sheet and saves config', (
      tester,
    ) async {
      final settings = SettingsProvider(preferences: businessPrefs);

      await _pumpBackupPage(tester, settings: settings);

      await _openSettingsPage(tester, 'WebDAV Backup');

      expect(find.byType(BottomSheet), findsOneWidget);
      expect(find.text('WebDAV Server Settings'), findsOneWidget);
      expect(find.text('WebDAV Server URL'), findsOneWidget);
      expect(find.text('User-Agent'), findsOneWidget);

      final fields = find.byType(TextField);
      await tester.enterText(fields.at(0), ' https://dav.example.com/root ');
      await tester.enterText(fields.at(4), ' KelivoTest/1.0 ');
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      expect(find.byType(BottomSheet), findsNothing);
      expect(settings.webDavConfig.url, 'https://dav.example.com/root');
      expect(settings.webDavConfig.userAgent, 'KelivoTest/1.0');
      // The restore card is gone — the channel card shows the only row pair.
      expect(find.text('Enabled'), findsOneWidget);
    });

    testWidgets('test connection validates the draft without persisting it', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(const Size(900, 1400));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final settings = SettingsProvider(preferences: businessPrefs);

      await _pumpBackupPage(tester, settings: settings);

      await _openSettingsPage(tester, 'WebDAV Backup');

      final fields = find.byType(TextField);
      await tester.enterText(fields.at(0), 'https://draft.example.com/dav');
      await tester.tap(find.text('Test'));
      await tester.pumpAndSettle();

      // Test runs against the typed draft, but must NOT write it back: only
      // 保存 commits. The stored config stays unchanged after the test.
      expect(settings.webDavConfig.url, isEmpty);
      expect(find.text('Test'), findsOneWidget);
    });

    testWidgets('hero, sections and rows are ordered correctly', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(const Size(900, 1800));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final settings = SettingsProvider(preferences: businessPrefs);

      await _pumpBackupPage(tester, settings: settings);

      // Hero headline + ONE row with all three lifecycle actions.
      expect(find.text('Backup Now'), findsOneWidget);
      expect(find.text('Incremental Backup'), findsOneWidget);
      expect(find.text('Restore from Backup'), findsOneWidget);
      expect(find.text('No Backup Yet'), findsOneWidget);
      // Sections in order; the old restore section and Kelivo export card
      // are gone (merged into the migration dialog / hero).
      expect(find.text('LAN Sync'), findsOneWidget);
      expect(find.text('Restore'), findsNothing);
      expect(find.text('Migrate Data'), findsOneWidget);
      expect(
        find.text('Move data between Cuplivo and other apps'),
        findsOneWidget,
      );
      expect(find.text('Backup Contents'), findsOneWidget);
      expect(find.text('Backup Reminder'), findsOneWidget);
      expect(find.text('Backup Channels'), findsOneWidget);
      // One entry only: the channel card (restore card was removed).
      expect(find.text('WebDAV Backup'), findsOneWidget);
      expect(find.text('S3 Backup'), findsOneWidget);
      _expectAbove(tester, 'Migrate Data', 'Backup Contents');
      _expectAbove(tester, 'Backup Contents', 'Backup Reminder');
      _expectAbove(tester, 'Backup Reminder', 'Backup Channels');
    });

    testWidgets('unconfigured channels are dimmed and route to config', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(const Size(900, 1800));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final settings = SettingsProvider(preferences: businessPrefs);

      await _pumpBackupPage(tester, settings: settings);

      // Channel card: both unconfigured.
      expect(find.text('Not configured'), findsNWidgets(2));
      expect(find.text('WebDAV Backup'), findsOneWidget);
      expect(find.text('S3 Backup'), findsOneWidget);
      // Tapping the S3 channel row opens the config sheet (the enable path).
      await _openSettingsPage(tester, 'S3 Backup');
      expect(find.byType(BottomSheet), findsOneWidget);
      expect(find.text('S3 Settings'), findsOneWidget);
    });

    testWidgets('configured channels show enabled status', (tester) async {
      await tester.binding.setSurfaceSize(const Size(900, 1800));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final settings = SettingsProvider(preferences: businessPrefs);
      await settings.setWebDavConfig(
        const WebDavConfig(url: 'https://dav.example.com'),
      );
      await settings.setS3Config(
        const S3Config(
          endpoint: 'https://s3.example.com',
          bucket: 'b',
          accessKeyId: 'ak',
          secretAccessKey: 'sk',
        ),
      );

      await _pumpBackupPage(tester, settings: settings);

      // Channel card rows only (restore card was removed).
      expect(find.text('Enabled'), findsNWidgets(2));
      expect(find.text('WebDAV Backup'), findsOneWidget);
      expect(find.text('S3 Backup'), findsOneWidget);
      expect(find.text('Restore'), findsNothing);
    });

    testWidgets('s3 config opens as a bottom sheet and saves config', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(const Size(900, 1400));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final settings = SettingsProvider(preferences: businessPrefs);

      await _pumpBackupPage(tester, settings: settings);

      await _openSettingsPage(tester, 'S3 Backup');

      expect(find.byType(BottomSheet), findsOneWidget);
      expect(find.text('S3 Settings'), findsOneWidget);
      expect(find.text('Endpoint'), findsOneWidget);

      final fields = find.byType(TextField);
      await tester.enterText(fields.first, ' https://s3.example.com ');
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      expect(find.byType(BottomSheet), findsNothing);
      expect(settings.s3Config.endpoint, 'https://s3.example.com');
      // Only the endpoint was saved — isConfigured also needs bucket + keys,
      // so the channel rows stay unconfigured.
      expect(find.text('Enabled'), findsNothing);
      expect(find.text('Not configured'), findsWidgets);
    });

    testWidgets('scope chips toggle and persist on both channels', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(const Size(900, 1800));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final settings = SettingsProvider(preferences: businessPrefs);

      await _pumpBackupPage(tester, settings: settings);

      await _openSettingsPage(tester, 'Skills');
      expect(settings.webDavConfig.content.skills, isFalse);
      expect(settings.s3Config.content.skills, isFalse);

      await _openSettingsPage(tester, 'Skills');
      expect(settings.webDavConfig.content.skills, isTrue);
      expect(settings.s3Config.content.skills, isTrue);
      expect(settings.webDavConfig.includeFiles, isTrue);
    });

    testWidgets('desktop shows hero plus ordered sections', (tester) async {
      await tester.binding.setSurfaceSize(const Size(1100, 1800));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final settings = SettingsProvider(preferences: businessPrefs);

      await _pumpDesktopBackupPane(tester, settings: settings);

      expect(find.text('Backup Now'), findsOneWidget);
      expect(find.text('Restore from Backup'), findsOneWidget);
      expect(tester.takeException(), isNull);
      expect(find.text('Restore'), findsNothing);
      expect(find.text('Migrate Data'), findsOneWidget);
      expect(find.text('Backup Contents'), findsOneWidget);
      expect(find.text('Backup Reminder'), findsOneWidget);
      expect(find.text('Backup Channels'), findsOneWidget);
      expect(find.text('WebDAV Backup'), findsOneWidget);
      expect(find.text('S3 Backup'), findsOneWidget);
      _expectAbove(tester, 'Migrate Data', 'Backup Contents');
      _expectAbove(tester, 'Backup Reminder', 'Backup Channels');
    });

    testWidgets('unconfigured segments route to the config dialog', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(const Size(900, 1400));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final settings = SettingsProvider(preferences: businessPrefs);

      await _pumpBackupPage(tester, settings: settings);

      // Tap the unconfigured WebDAV segment inside the hero picker.
      final hero = find.byType(BackupHeroCard);
      expect(hero, findsOneWidget);
      final segment = find.descendant(of: hero, matching: find.text('WebDAV'));
      await tester.tap(segment);
      await tester.pumpAndSettle();

      expect(find.byType(BottomSheet), findsOneWidget);
      expect(find.text('WebDAV Server Settings'), findsOneWidget);
    });

    testWidgets('migration row opens the flat export/import chooser', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(const Size(900, 1800));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final settings = SettingsProvider(preferences: businessPrefs);

      await _pumpBackupPage(tester, settings: settings);

      await _openSettingsPage(tester, 'Migrate Data');

      // Flat list: no group headers; export entry + four import entries.
      expect(find.text('Move out to'), findsNothing);
      expect(find.text('Move in from'), findsNothing);
      expect(find.text('Export Kelivo-Compatible Backup'), findsOneWidget);
      expect(find.text('Import from New Kelivo'), findsOneWidget);
      expect(find.text('Import from RikkaHub'), findsOneWidget);
      expect(find.text('Import from Cherry Studio'), findsOneWidget);
      expect(find.text('Import from Chatbox'), findsOneWidget);
      _expectAbove(
        tester,
        'Export Kelivo-Compatible Backup',
        'Import from New Kelivo',
      );

      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(find.text('Import from New Kelivo'), findsNothing);
    });

    testWidgets('desktop config dialog renders (Material shell regression)', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(const Size(1100, 1800));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final settings = SettingsProvider(preferences: businessPrefs);

      await _pumpDesktopBackupPane(tester, settings: settings);

      await _openSettingsPage(tester, 'WebDAV Backup');

      expect(find.text('WebDAV Server Settings'), findsOneWidget);
      expect(find.byType(TextField), findsWidgets);
      expect(tester.takeException(), isNull);
    });
  });
}
