import '../../../support/business_test_harness.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:Cuplivo/core/providers/assistant_provider.dart';
import 'package:Cuplivo/core/providers/settings_provider.dart';
import 'package:Cuplivo/core/services/chat/chat_service.dart';
import 'package:Cuplivo/features/provider/pages/provider_detail_page.dart';
import 'package:Cuplivo/features/provider/widgets/provider_base_url_field.dart';
import 'package:Cuplivo/icons/lucide_adapter.dart';
import 'package:Cuplivo/l10n/app_localizations.dart';

/// The retired built-in key is a plain dynamic provider now, so the detail page
/// must give the user every way out of it: a delete button, an editable base URL
/// and the provider-kind row. Before the removal all three were withheld, which
/// is why a config on a dead host could not be repaired from the UI at all.
Widget _harness(SettingsProvider settings, String keyName) {
  return MultiProvider(
    providers: [
      ChangeNotifierProvider<SettingsProvider>.value(value: settings),
      ChangeNotifierProvider<ChatService>(create: (_) => ChatService()),
      ChangeNotifierProvider<AssistantProvider>(
        create: (_) =>
            AssistantProvider(preferences: createBusinessTestPreferences()),
      ),
    ],
    child: MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      locale: const Locale.fromSubtags(languageCode: 'zh', scriptCode: 'Hans'),
      home: ProviderDetailPage(keyName: keyName, displayName: keyName),
    ),
  );
}

Future<SettingsProvider> _settingsWith(String keyName) async {
  SharedPreferences.setMockInitialValues({});
  final settings = SettingsProvider(createBusinessTestPreferences());
  await settings.loaded;
  await settings.setProviderConfig(
    keyName,
    ProviderConfig.defaultsFor(keyName).copyWith(
      name: keyName,
      apiKey: 'user-key',
      baseUrl: 'https://api.psycheas.top/v1',
      models: const ['qwen-max'],
    ),
  );
  return settings;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'a persisted KelivoIN opens deletable, with an editable URL and a kind row',
    (tester) async {
      final l10n = await AppLocalizations.delegate.load(const Locale('zh'));
      tester.view.physicalSize = const Size(420, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      final settings = await _settingsWith('KelivoIN');
      await tester.pumpWidget(_harness(settings, 'KelivoIN'));
      await tester.pumpAndSettle();

      expect(find.byIcon(Lucide.Trash2), findsOneWidget);
      expect(
        find.text(l10n.providerDetailPageProviderTypeTitle),
        findsOneWidget,
      );

      final base = tester.widget<ProviderBaseUrlField>(
        find.byType(ProviderBaseUrlField),
      );
      expect(base.enabled, isTrue);
      // Not a built-in any more, so there is no remembered default to restore.
      expect(base.restoreDefault, isFalse);
    },
  );

  testWidgets('a built-in provider keeps the locked-down shape', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(420, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final settings = await _settingsWith('OpenAI');
    await tester.pumpWidget(_harness(settings, 'OpenAI'));
    await tester.pumpAndSettle();

    expect(find.byIcon(Lucide.Trash2), findsNothing);
    final base = tester.widget<ProviderBaseUrlField>(
      find.byType(ProviderBaseUrlField),
    );
    expect(base.restoreDefault, isTrue);
  });
}
