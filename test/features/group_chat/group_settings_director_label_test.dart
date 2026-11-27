import 'package:Cuplivo/core/database/extension_entity_store.dart';
import 'package:Cuplivo/core/providers/assistant_provider.dart';
import 'package:Cuplivo/core/providers/group_chat_provider.dart';
import 'package:Cuplivo/core/providers/settings_provider.dart';
import 'package:Cuplivo/features/group_chat/widgets/group_settings_view.dart';
import 'package:Cuplivo/l10n/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import '../../support/business_test_harness.dart';

/// The director row names the director the way the page it opens does — by the
/// name its provider gives it — so the two cannot disagree about which model
/// is in charge.
void main() {
  Future<void> pumpSettings(
    WidgetTester tester,
    SettingsProvider settings,
  ) async {
    final database = createBusinessTestPreferencesWithDatabase();
    final groups = GroupChatProvider(
      store: ExtensionEntityStore(database.database),
    );
    await groups.loaded;
    final group = await groups.create(
      name: 'Reading club',
      memberIds: const [],
    );

    final assistants = AssistantProvider(
      preferences: createBusinessTestPreferences(),
    );
    await assistants.loaded;

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<GroupChatProvider>.value(value: groups),
          ChangeNotifierProvider<AssistantProvider>.value(value: assistants),
          ChangeNotifierProvider<SettingsProvider>.value(value: settings),
        ],
        child: MaterialApp(
          locale: const Locale('en'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(body: GroupSettingsView(groupId: group.id)),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('the director row shows the model name, not its id', (
    tester,
  ) async {
    final settings = SettingsProvider(createBusinessTestPreferences());
    addTearDown(settings.dispose);
    await settings.loaded;
    await settings.setProviderConfig(
      'DirectorProvider',
      ProviderConfig(
        id: 'DirectorProvider',
        enabled: true,
        name: 'DirectorProvider',
        apiKey: 'k',
        baseUrl: 'https://example.test/v1',
        providerType: ProviderKind.openai,
        modelOverrides: {
          'director-v3': {'name': 'Fast Judge'},
        },
      ),
    );
    await settings.setDirectorModel('DirectorProvider', 'director-v3');

    await pumpSettings(tester, settings);

    expect(find.text('Fast Judge'), findsOneWidget);
    expect(find.text('director-v3'), findsNothing);
  });

  testWidgets('a director the user did not name is shown by its id', (
    tester,
  ) async {
    final settings = SettingsProvider(createBusinessTestPreferences());
    addTearDown(settings.dispose);
    await settings.loaded;
    await settings.setDirectorModel('DirectorProvider', 'director-v3');

    await pumpSettings(tester, settings);

    expect(find.text('director-v3'), findsOneWidget);
  });

  testWidgets('a long director name is truncated, not overflowing', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(360, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final settings = SettingsProvider(createBusinessTestPreferences());
    addTearDown(settings.dispose);
    await settings.loaded;
    const longName = 'Fast Judge With A Very Long Display Name 01';
    await settings.setProviderConfig(
      'DirectorProvider',
      ProviderConfig(
        id: 'DirectorProvider',
        enabled: true,
        name: 'DirectorProvider',
        apiKey: 'k',
        baseUrl: 'https://example.test/v1',
        providerType: ProviderKind.openai,
        modelOverrides: {
          'director-v3': {'name': longName},
        },
      ),
    );
    await settings.setDirectorModel('DirectorProvider', 'director-v3');

    await pumpSettings(tester, settings);

    // The name is still the row's value — it is clipped, not dropped, and the
    // row does not overflow at a phone width.
    expect(find.text(longName), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('without a director the row says it follows the default', (
    tester,
  ) async {
    final settings = SettingsProvider(createBusinessTestPreferences());
    addTearDown(settings.dispose);
    await settings.loaded;

    await pumpSettings(tester, settings);

    expect(find.text('Follows default model'), findsOneWidget);
  });
}
