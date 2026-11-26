// The group search sheet's member switch must show what the provider now holds:
// the roster it was opened with is a snapshot, and a controlled switch fed from
// that snapshot sends its stale value back, so a member's external search could
// be turned on and never off again from the panel.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:Cuplivo/core/providers/assistant_provider.dart';
import 'package:Cuplivo/core/providers/settings_provider.dart';
import 'package:Cuplivo/features/search/widgets/search_settings_sheet.dart';
import 'package:Cuplivo/l10n/app_localizations.dart';
import 'package:Cuplivo/shared/widgets/ios_switch.dart';

import '../../../support/business_test_harness.dart';

const _providerKey = 'openai';

class _Fixture {
  const _Fixture({required this.settings, required this.assistants});

  final SettingsProvider settings;
  final AssistantProvider assistants;
}

Future<_Fixture> _createFixture() async {
  final harness = await createBusinessTestHarness();
  final settings = SettingsProvider(harness.preferences);
  final assistants = AssistantProvider(preferences: harness.preferences);
  await Future.wait([settings.loaded, assistants.loaded]);

  await settings.setProviderConfig(
    _providerKey,
    ProviderConfig(
      id: _providerKey,
      enabled: true,
      name: _providerKey,
      apiKey: '',
      baseUrl: '',
      models: ['gpt-4o'],
    ),
  );
  await settings.setCurrentModel(_providerKey, 'gpt-4o');

  final a = await assistants.addAssistant(name: 'Alice');
  final b = await assistants.addAssistant(name: 'Bob');
  await assistants.updateAssistant(
    assistants
        .getById(a)!
        .copyWith(chatModelProvider: _providerKey, chatModelId: 'gpt-4o'),
  );
  await assistants.updateAssistant(
    assistants
        .getById(b)!
        .copyWith(chatModelProvider: _providerKey, chatModelId: 'gpt-4o'),
  );
  await assistants.setCurrentAssistant(a);
  return _Fixture(settings: settings, assistants: assistants);
}

Widget _app({required _Fixture fixture, required Widget home}) {
  return MultiProvider(
    providers: [
      ChangeNotifierProvider<SettingsProvider>.value(value: fixture.settings),
      ChangeNotifierProvider<AssistantProvider>.value(
        value: fixture.assistants,
      ),
    ],
    child: MaterialApp(
      locale: const Locale('en'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(body: home),
    ),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('group sheet external-search toggle reflects its own write', (
    tester,
  ) async {
    final fixture = await _createFixture();
    final alice = fixture.assistants.getById(
      fixture.assistants.currentAssistantId!,
    )!;
    final bob = fixture.assistants.assistants.firstWhere(
      (a) => a.id != alice.id,
    );

    await tester.pumpWidget(
      _app(
        fixture: fixture,
        home: Builder(
          builder: (context) => Center(
            child: FilledButton(
              onPressed: () => showSearchSettingsSheet(
                context,
                members: [alice, bob],
                initialAssistantId: alice.id,
              ),
              child: const Text('Open group search'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Open group search'));
    await tester.pumpAndSettle();

    // The external-search row is the one carrying the "Web Search" label.
    final externalRow = find.ancestor(
      of: find.text('Web Search'),
      matching: find.byType(Row),
    );
    final externalSwitch = find.descendant(
      of: externalRow.first,
      matching: find.byType(IosSwitch),
    );

    expect(
      tester.widget<IosSwitch>(externalSwitch).value,
      isFalse,
      reason: 'fixture starts with external search off for every member',
    );

    await tester.tap(externalSwitch);
    await tester.pumpAndSettle();

    // The write lands on the member...
    expect(
      fixture.assistants.getById(alice.id)!.searchEnabled,
      isTrue,
      reason: 'the tap writes the selected member',
    );

    // ...but the switch still renders the value captured when the sheet opened.
    expect(
      tester.widget<IosSwitch>(externalSwitch).value,
      isTrue,
      reason: 'the switch must show what the provider now holds',
    );
  });
}
