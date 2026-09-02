import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:Cuplivo/core/database/business_preferences.dart';
import 'package:Cuplivo/core/providers/settings_provider.dart';
import 'package:Cuplivo/features/backup/widgets/backup_migration_dialog.dart';
import 'package:Cuplivo/l10n/app_localizations.dart';

Future<List<bool>> _pumpDialog(WidgetTester tester) async {
  final calls = List<bool>.filled(5, false);
  await tester.pumpWidget(
    MultiProvider(
      providers: [
        ChangeNotifierProvider<SettingsProvider>.value(
          value: SettingsProvider(
            preferences: BusinessPreferences.memoryForTests({}),
          ),
        ),
      ],
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: Builder(
            builder: (context) => Center(
              child: TextButton(
                onPressed: () {
                  showBackupMigrationChooser(
                    context,
                    onExportKelivo: () => calls[0] = true,
                    onImportKelivo: () => calls[1] = true,
                    onImportRikkaHub: () => calls[2] = true,
                    onImportCherryStudio: () => calls[3] = true,
                    onImportChatbox: () => calls[4] = true,
                  );
                },
                child: const Text('open migrate'),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open migrate'));
  await tester.pumpAndSettle();
  return calls;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('renders flat list without group headers or tinted groups', (
    tester,
  ) async {
    await _pumpDialog(tester);

    expect(find.text('Migrate Data'), findsOneWidget);
    expect(find.text('Export Kelivo-Compatible Backup'), findsOneWidget);
    expect(find.text('Import from New Kelivo'), findsOneWidget);
    expect(find.text('Import from RikkaHub'), findsOneWidget);
    expect(find.text('Import from Cherry Studio'), findsOneWidget);
    expect(find.text('Import from Chatbox'), findsOneWidget);

    // Group headers are gone with the redesign.
    expect(find.text('Move out to'), findsNothing);
    expect(find.text('Move in from'), findsNothing);
  });

  testWidgets('export row fires its callback and dismisses the dialog', (
    tester,
  ) async {
    final calls = await _pumpDialog(tester);

    await tester.tap(find.text('Export Kelivo-Compatible Backup'));
    await tester.pumpAndSettle();

    expect(calls[0], isTrue);
    expect(find.text('Migrate Data'), findsNothing);
  });

  testWidgets('cancel dismisses without firing any callback', (tester) async {
    final calls = await _pumpDialog(tester);

    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    expect(calls, equals(List<bool>.filled(5, false)));
    expect(find.text('Migrate Data'), findsNothing);
  });
}
