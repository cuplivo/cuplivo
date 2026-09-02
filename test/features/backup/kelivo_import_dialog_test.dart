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
const _kelivoUrl = 'https://kelivo-helper.netlify.app/#/compat';

Future<BackupReminderProvider> _createReminderProvider() async {
  final provider = BackupReminderProvider(
    preferences: businessPrefs,
    autoLoad: false,
  );
  await provider.load(startTimer: false);
  return provider;
}

Future<void> _pumpBackupPage(
  WidgetTester tester, {
  required SettingsProvider settings,
}) async {
  final chatService = ChatService();
  final coordinator = TrashRestoreCoordinator(
    preferences: businessPrefs,
    chatService: chatService,
  );
  final reminder = await _createReminderProvider();

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
  final reminder = await _createReminderProvider();

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

Future<void> _openMigrationChooser(
  WidgetTester tester,
  String optionLabel,
) async {
  final summary = find.text('Migrate Data');
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

void _expectAbove(WidgetTester tester, String upper, String lower) {
  final upperTop = tester.getTopLeft(find.text(upper).first).dy;
  final lowerTop = tester.getTopLeft(find.text(lower).first).dy;
  expect(upperTop, lessThan(lowerTop));
}

void _expectKelivoDialogShown(WidgetTester tester) {
  expect(find.text('Usage Tutorial'), findsOneWidget);
  expect(find.text(_kelivoUrl), findsOneWidget);
  expect(
    find.text(
      'Backups from newer versions of Kelivo can be converted to a '
      'Cuplivo-compatible backup via the Kelivo-helper website:',
    ),
    findsOneWidget,
  );
  expect(find.text('Open the Kelivo-helper website below.'), findsOneWidget);
  expect(
    find.text(
      'Select the backup file exported from the newer version of '
      'Kelivo and follow the instructions on the webpage.',
    ),
    findsOneWidget,
  );
  expect(find.text('Wait for the conversion to complete.'), findsOneWidget);
  expect(find.text('Download the converted backup file.'), findsOneWidget);
  expect(
    find.text(
      'Return to Cuplivo, tap “Import Backup File”, and select the '
      'converted file to complete the import.',
    ),
    findsOneWidget,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    businessPrefs = BusinessPreferences.memoryForTests();
    SharedPreferences.setMockInitialValues(const {});
    businessPrefs = BusinessPreferences.memoryForTests(const {});
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_urlLauncherChannel, null);
  });

  group('BackupPage Kelivo import entry', () {
    testWidgets('chooser lists sources in order', (tester) async {
      await tester.binding.setSurfaceSize(const Size(900, 1600));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      await _pumpBackupPage(
        tester,
        settings: SettingsProvider(preferences: businessPrefs),
      );

      final summary = find.text('Migrate Data');
      await tester.scrollUntilVisible(
        summary,
        120,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();
      await tester.tap(summary);
      await tester.pumpAndSettle();

      expect(find.text('Import from New Kelivo'), findsOneWidget);
      expect(find.text('Import from RikkaHub'), findsOneWidget);
      expect(find.text('Import from Cherry Studio'), findsOneWidget);
      expect(find.text('Import from Chatbox'), findsOneWidget);
      _expectAbove(tester, 'Import from New Kelivo', 'Import from RikkaHub');
      _expectAbove(tester, 'Import from RikkaHub', 'Import from Cherry Studio');
    });

    testWidgets('tapping the option opens the Kelivo import guide', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(const Size(900, 1600));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      await _pumpBackupPage(
        tester,
        settings: SettingsProvider(preferences: businessPrefs),
      );

      await _openMigrationChooser(tester, 'Import from New Kelivo');

      _expectKelivoDialogShown(tester);
    });

    testWidgets('tapping the website link launches the compat url', (
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

      await _pumpBackupPage(
        tester,
        settings: SettingsProvider(preferences: businessPrefs),
      );
      await _openMigrationChooser(tester, 'Import from New Kelivo');
      await tester.tap(find.text(_kelivoUrl));
      await tester.pumpAndSettle();

      expect(launchedUrl, _kelivoUrl);
    });

    testWidgets('uses the platform fallback when external launch fails', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(const Size(900, 1600));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      var launchAttempts = 0;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        _urlLauncherChannel,
        (call) async {
          if (call.method == 'launch') {
            launchAttempts++;
            return launchAttempts > 1;
          }
          fail('Unexpected url_launcher call: ${call.method}');
        },
      );

      await _pumpBackupPage(
        tester,
        settings: SettingsProvider(preferences: businessPrefs),
      );
      await _openMigrationChooser(tester, 'Import from New Kelivo');
      await tester.tap(find.text(_kelivoUrl));
      await tester.pumpAndSettle();

      expect(launchAttempts, 2);
    });

    testWidgets('remains scrollable in a short window and can be dismissed', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(const Size(420, 480));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      await _pumpBackupPage(
        tester,
        settings: SettingsProvider(preferences: businessPrefs),
      );
      await _openMigrationChooser(tester, 'Import from New Kelivo');

      expect(find.byType(SingleChildScrollView), findsOneWidget);
      expect(find.text('Usage Tutorial'), findsOneWidget);
      expect(tester.takeException(), isNull);

      await tester.tap(find.text('OK'));
      await tester.pumpAndSettle();
      expect(find.text('Usage Tutorial'), findsNothing);
    });
  });

  group('DesktopBackupPane Kelivo import entry', () {
    testWidgets('shows the entry and opens the Kelivo import guide', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(const Size(1100, 1300));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      await _pumpDesktopBackupPane(
        tester,
        settings: SettingsProvider(preferences: businessPrefs),
      );

      await _openMigrationChooser(tester, 'Import from New Kelivo');

      _expectKelivoDialogShown(tester);
    });
  });
}
