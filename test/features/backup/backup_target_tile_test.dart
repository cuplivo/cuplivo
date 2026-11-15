import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:Cuplivo/core/models/backup.dart';
import 'package:Cuplivo/core/providers/settings_provider.dart';
import 'package:Cuplivo/features/backup/widgets/backup_target_tile.dart';
import 'package:Cuplivo/l10n/app_localizations.dart';

import '../../support/business_test_harness.dart';

void main() {
  // IosCardPress reads the settings provider for its haptics, so the tile needs
  // the same host the backup page gives it.
  Future<Widget> host(
    Widget child, {
    TargetPlatform platform = TargetPlatform.iOS,
  }) async {
    final business = await createBusinessTestHarness();
    final settings = SettingsProvider(business.preferences);
    addTearDown(settings.dispose);
    await settings.loaded;
    return ChangeNotifierProvider.value(
      value: settings,
      child: MaterialApp(
        theme: ThemeData(platform: platform),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('en'),
        home: Scaffold(body: child),
      ),
    );
  }

  testWidgets('the row names the reader the next backup is written for', (
    tester,
  ) async {
    await tester.pumpWidget(
      await host(
        BackupTargetTile(
          target: BackupTarget.kelivoV1_3_4,
          onChanged: (_) async {},
        ),
      ),
    );

    expect(find.text('Backup target'), findsOneWidget);
    expect(find.text('Kelivo 1.3.4'), findsOneWidget);
  });

  testWidgets('choosing Kelivo reports it, and the picker states the cost', (
    tester,
  ) async {
    BackupTarget? picked;
    await tester.pumpWidget(
      await host(
        BackupTargetTile(
          target: BackupTarget.cuplivo,
          onChanged: (target) async => picked = target,
        ),
      ),
    );

    await tester.tap(find.byKey(const ValueKey('backup-target-picker')));
    await tester.pumpAndSettle();

    // The one place the trade is stated, in the user's terms rather than the
    // archive's.
    expect(
      find.text('Imports into Kelivo, but group chats are lost'),
      findsOneWidget,
    );

    await tester.tap(find.byKey(const ValueKey('backup-target-kelivoV1_3_4')));
    await tester.pumpAndSettle();

    expect(picked, BackupTarget.kelivoV1_3_4);
  });

  testWidgets('desktop opens the same choice as a dialog', (tester) async {
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.binding.setSurfaceSize(const Size(1100, 800));
    BackupTarget? picked;
    await tester.pumpWidget(
      await host(
        BackupTargetTile(
          desktop: true,
          target: BackupTarget.cuplivo,
          onChanged: (target) async => picked = target,
        ),
        platform: TargetPlatform.windows,
      ),
    );

    await tester.tap(find.byKey(const ValueKey('backup-target-picker')));
    await tester.pumpAndSettle();

    expect(find.byType(Dialog), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('backup-target-kelivoV1_3_4')));
    await tester.pumpAndSettle();

    expect(picked, BackupTarget.kelivoV1_3_4);
  });

  testWidgets('a disabled tile has no picker', (tester) async {
    await tester.pumpWidget(
      await host(
        const BackupTargetTile(target: BackupTarget.cuplivo, onChanged: null),
      ),
    );

    await tester.tap(find.byKey(const ValueKey('backup-target-picker')));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('backup-target-kelivoV1_3_4')),
      findsNothing,
    );
  });
}
