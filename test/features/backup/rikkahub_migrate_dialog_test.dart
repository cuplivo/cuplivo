import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:Cuplivo/core/database/business_preferences.dart';

import 'package:Cuplivo/core/providers/backup_provider.dart';
import 'package:Cuplivo/core/providers/backup_reminder_provider.dart';
import 'package:Cuplivo/core/providers/s3_backup_provider.dart';
import 'package:Cuplivo/core/providers/settings_provider.dart';
import 'package:Cuplivo/core/services/chat/chat_service.dart';
import 'package:Cuplivo/core/services/trash_restore_coordinator.dart';
import 'package:Cuplivo/desktop/setting/backup_pane.dart';
import 'package:Cuplivo/features/backup/pages/backup_page.dart';
import 'package:Cuplivo/l10n/app_localizations.dart';

var businessPrefs = BusinessPreferences.memoryForTests();

const _urlLauncherChannel = MethodChannel('plugins.flutter.io/url_launcher');
const _migrateUrl = 'https://kelivo-helper.netlify.app/#/migrate';

Future<void> _pumpBackupPage(
  WidgetTester tester, {
  required SettingsProvider settings,
}) async {
  final chatService = ChatService();
  final coordinator = TrashRestoreCoordinator(
    preferences: businessPrefs,
    chatService: chatService,
  );
  final reminder = BackupReminderProvider(
    preferences: businessPrefs,
    autoLoad: false,
  );
  await reminder.load(startTimer: false);

  await tester.pumpWidget(
    MultiProvider(
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
    ),
  );
  await tester.pump();
}

Future<void> _pumpDesktopBackupPane(
  WidgetTester tester, {
  required SettingsProvider settings,
}) async {
  final chatService = ChatService();
  final reminder = BackupReminderProvider(
    preferences: businessPrefs,
    autoLoad: false,
  );
  await reminder.load(startTimer: false);

  await tester.pumpWidget(
    MultiProvider(
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
    ),
  );
  await tester.pump();
}

void _expectAbove(WidgetTester tester, String upper, String lower) {
  final upperTop = tester.getTopLeft(find.text(upper).first).dy;
  final lowerTop = tester.getTopLeft(find.text(lower).first).dy;
  expect(upperTop, lessThan(lowerTop));
}

void _expectMigrateDialogShown(WidgetTester tester) {
  expect(find.text('Usage Tutorial'), findsOneWidget);
  expect(find.text(_migrateUrl), findsOneWidget);
  expect(
    find.text('After opening the website, tap “Click to Select”.'),
    findsOneWidget,
  );
  expect(
    find.text('Find your RikkaHub backup and tap Confirm.'),
    findsOneWidget,
  );
  expect(find.textContaining('Wait about 15 seconds'), findsOneWidget);
  expect(
    find.textContaining('Return to Cuplivo, tap “Import Backup File”'),
    findsOneWidget,
  );
  expect(find.textContaining('join the Cuplivo QQ group'), findsOneWidget);
}

Future<void> _openMigrationChooser(
  WidgetTester tester,
  String optionLabel,
) async {
  final summary = find.text('Migrate from Other Apps');
  await tester.scrollUntilVisible(
    summary,
    120,
    scrollable: find.byType(Scrollable).first,
  );
  await tester.pumpAndSettle();
  await tester.tap(summary);
  await tester.pumpAndSettle();
  await tester.tap(find.text(optionLabel));
  await tester.pumpAndSettle();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    businessPrefs = BusinessPreferences.memoryForTests();
    SharedPreferences.setMockInitialValues({});
    businessPrefs = BusinessPreferences.memoryForTests(const {});
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_urlLauncherChannel, null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null);
  });

  group('BackupPage RikkaHub migration entry', () {
    testWidgets(
      'shows Import from RikkaHub between Backup File and Cherry Studio',
      (tester) async {
        await tester.binding.setSurfaceSize(const Size(900, 1600));
        addTearDown(() => tester.binding.setSurfaceSize(null));

        final settings = SettingsProvider(preferences: businessPrefs);
        await _pumpBackupPage(tester, settings: settings);

        final summary = find.text('Migrate from Other Apps');
        await tester.scrollUntilVisible(
          summary,
          120,
          scrollable: find.byType(Scrollable).first,
        );
        await tester.pumpAndSettle();
        await tester.tap(summary);
        await tester.pumpAndSettle();
        expect(find.text('Import from RikkaHub'), findsOneWidget);
        _expectAbove(
          tester,
          'Import from RikkaHub',
          'Import from Cherry Studio',
        );
      },
    );

    testWidgets('tapping the row opens the migration guide dialog', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(const Size(900, 1600));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final settings = SettingsProvider(preferences: businessPrefs);
      await _pumpBackupPage(tester, settings: settings);

      await _openMigrationChooser(tester, 'Import from RikkaHub');
      _expectMigrateDialogShown(tester);
    });

    testWidgets('tapping the website link launches the migration url', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(const Size(900, 1600));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      String? launchedUrl;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        _urlLauncherChannel,
        (call) async {
          if (call.method == 'launch') {
            launchedUrl =
                (call.arguments as Map<Object?, Object?>)['url'] as String?;
            return true;
          }
          fail('Unexpected url_launcher call: ${call.method}');
        },
      );

      final settings = SettingsProvider(preferences: businessPrefs);
      await _pumpBackupPage(tester, settings: settings);

      await _openMigrationChooser(tester, 'Import from RikkaHub');
      await tester.tap(find.text(_migrateUrl));
      await tester.pumpAndSettle();

      expect(launchedUrl, _migrateUrl);
    });

    testWidgets('close button dismisses the dialog', (tester) async {
      await tester.binding.setSurfaceSize(const Size(900, 1600));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final settings = SettingsProvider(preferences: businessPrefs);
      await _pumpBackupPage(tester, settings: settings);

      await _openMigrationChooser(tester, 'Import from RikkaHub');
      await tester.tap(find.text('OK'));
      await tester.pumpAndSettle();

      expect(find.text('Usage Tutorial'), findsNothing);
    });
  });

  group('DesktopBackupPane RikkaHub migration entry', () {
    testWidgets('shows the button and opens the migration guide dialog', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(const Size(1100, 1300));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final settings = SettingsProvider(preferences: businessPrefs);
      await _pumpDesktopBackupPane(tester, settings: settings);

      await _openMigrationChooser(tester, 'Import from RikkaHub');
      _expectMigrateDialogShown(tester);
    });
  });
}
