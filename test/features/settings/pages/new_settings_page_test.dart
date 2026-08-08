import 'package:Cuplivo/core/providers/assistant_provider.dart';
import 'package:Cuplivo/core/providers/backup_reminder_provider.dart';
import 'package:Cuplivo/core/providers/settings_provider.dart';
import 'package:Cuplivo/core/services/chat/chat_service.dart';
import 'package:Cuplivo/core/services/trash_restore_coordinator.dart';
import 'package:Cuplivo/desktop/desktop_settings_page.dart';
import 'package:Cuplivo/features/assistant/pages/assistant_settings_page.dart';
import 'package:Cuplivo/features/backup/pages/backup_page.dart';
import 'package:Cuplivo/features/settings/pages/new/appearance_settings_page.dart';
import 'package:Cuplivo/features/settings/pages/new/aux_model_settings_page.dart';
import 'package:Cuplivo/features/settings/pages/new/data_settings_page.dart';
import 'package:Cuplivo/features/settings/pages/new/new_settings_page.dart';
import 'package:Cuplivo/features/settings/pages/settings_page.dart';
import 'package:Cuplivo/l10n/app_localizations.dart';
import 'package:Cuplivo/shared/widgets/snackbar.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

Widget _buildHarness(Widget home) {
  final settings = SettingsProvider();
  addTearDown(settings.dispose);
  final assistantProvider = AssistantProvider();
  addTearDown(assistantProvider.dispose);
  return ChangeNotifierProvider<SettingsProvider>.value(
    value: settings,
    child: ChangeNotifierProvider<AssistantProvider>.value(
      value: assistantProvider,
      child: Directionality(
        textDirection: TextDirection.ltr,
        child: MediaQuery(
          data: const MediaQueryData(size: Size(800, 600)),
          child: MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            locale: const Locale('en'),
            home: AppSnackBarOverlay(child: home),
          ),
        ),
      ),
    ),
  );
}

Widget _buildBackupHarness(Widget home) {
  final settings = SettingsProvider();
  addTearDown(settings.dispose);
  final assistantProvider = AssistantProvider();
  addTearDown(assistantProvider.dispose);
  final chatService = ChatService();
  addTearDown(chatService.dispose);
  final coordinator = TrashRestoreCoordinator(chatService: chatService);
  final reminder = BackupReminderProvider(autoLoad: false);
  addTearDown(reminder.dispose);
  return MultiProvider(
    providers: [
      ChangeNotifierProvider<SettingsProvider>.value(value: settings),
      ChangeNotifierProvider<AssistantProvider>.value(value: assistantProvider),
      ChangeNotifierProvider<ChatService>.value(value: chatService),
      Provider<TrashRestoreCoordinator>.value(value: coordinator),
      ChangeNotifierProvider<BackupReminderProvider>.value(value: reminder),
    ],
    child: MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      locale: const Locale('en'),
      home: AppSnackBarOverlay(child: home),
    ),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(const {});
  });

  testWidgets('renders the 8 section headers and the legacy entry', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(800, 1400));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(_buildHarness(const NewSettingsPage()));
    await tester.pumpAndSettle();

    for (final header in [
      'Assistant',
      'Appearance & Behavior',
      'Providers',
      'Auxiliary Models',
      'SillyTavern Features',
      'More Tools',
      'Data',
      'Cuplivo',
    ]) {
      expect(find.text(header), findsWidgets);
    }
    expect(find.text('Legacy Settings'), findsOneWidget);
  });

  testWidgets('tapping the Assistant section pushes AssistantSettingsPage', (
    tester,
  ) async {
    await tester.pumpWidget(_buildHarness(const NewSettingsPage()));
    await tester.pumpAndSettle();

    await tester.scrollUntilVisible(
      find.text('Assistants and their defaults'),
      200,
    );
    await tester.tap(find.text('Assistants and their defaults'));
    await tester.pumpAndSettle();

    expect(find.byType(AssistantSettingsPage), findsOneWidget);
  });

  testWidgets('tapping the legacy entry opens the old SettingsPage', (
    tester,
  ) async {
    await tester.pumpWidget(_buildHarness(const NewSettingsPage()));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Legacy Settings'));
    await tester.pumpAndSettle();

    expect(find.byType(SettingsPage), findsOneWidget);
  });

  testWidgets('coming-soon rows show the coming-soon snackbar', (tester) async {
    await tester.pumpWidget(_buildHarness(const AuxModelSettingsPage()));
    await tester.pumpAndSettle();

    final l10n = AppLocalizations.of(
      tester.element(find.byType(AuxModelSettingsPage)),
    )!;
    await tester.tap(find.text('ASR Model'));
    await tester.pumpAndSettle();

    expect(find.text(l10n.newSettingsComingSoonMessage), findsOneWidget);

    // Let the auto-dismiss timer fire and the exit animation finish.
    await tester.pump(const Duration(seconds: 4));
    await tester.pumpAndSettle();
  });

  testWidgets(
    'LanguageRow on AppearanceSettingsPage opens the language sheet',
    (tester) async {
      await tester.pumpWidget(_buildHarness(const AppearanceSettingsPage()));
      await tester.pumpAndSettle();

      await tester.scrollUntilVisible(find.text('App Language'), 200);
      await tester.tap(find.text('App Language'));
      await tester.pumpAndSettle();

      // "System" also shows as the row detail (following system locale).
      expect(find.text('System'), findsNWidgets(2));
      expect(find.text('Simplified Chinese'), findsOneWidget);
      expect(find.text('Traditional Chinese'), findsOneWidget);
      expect(find.text('English'), findsOneWidget);

      // Close the sheet by tapping the modal barrier.
      await tester.tap(find.byType(ModalBarrier).first);
      await tester.pumpAndSettle();

      // The sheet options are gone; only the row detail remains.
      expect(find.text('Simplified Chinese'), findsNothing);
      expect(find.text('Traditional Chinese'), findsNothing);
      expect(find.text('English'), findsNothing);
      expect(find.text('System'), findsOneWidget);
    },
  );

  testWidgets(
    'initialTarget backup auto-opens DataSettingsPage and BackupPage',
    (tester) async {
      await tester.pumpWidget(
        _buildBackupHarness(
          const NewSettingsPage(initialTarget: NewSettingsTarget.backup),
        ),
      );
      await tester.pumpAndSettle();

      expect(
        find.byType(DataSettingsPage, skipOffstage: false),
        findsOneWidget,
      );
      expect(find.byType(BackupPage), findsOneWidget);
    },
  );

  testWidgets('legacy entry on desktop opens DesktopSettingsPage', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    try {
      await tester.pumpWidget(_buildHarness(const NewSettingsPage()));
      await tester.pumpAndSettle();

      final l10n = AppLocalizations.of(
        tester.element(find.byType(NewSettingsPage)),
      )!;
      await tester.tap(find.text(l10n.newSettingsLegacyEntry));
      await tester.pumpAndSettle();

      expect(find.byType(DesktopSettingsPage), findsOneWidget);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });
}
