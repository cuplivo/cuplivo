import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:Cuplivo/features/harness/pages/assistant/models/dsh_models_tab_body.dart';
import 'package:Cuplivo/features/harness/pages/assistant/models/dsh_provider_detail_page.dart';
import 'package:Cuplivo/features/harness/models/dsh_provider_settings.dart';
import 'package:Cuplivo/l10n/app_localizations.dart';

class _FakeSettingsGateway implements DshProviderSettingsGateway {
  _FakeSettingsGateway(this.entries);

  List<DshProviderEntry> entries;
  DshProviderEntry? savedEntry;
  String? credentialRef;
  String? credentialValue;

  @override
  Future<List<DshProviderEntry>> load() async =>
      List<DshProviderEntry>.of(entries);

  @override
  Future<DshProviderEntry> save(DshProviderDraft draft) async {
    final saved = DshProviderEntry(
      id: draft.providerId,
      displayName: draft.displayName,
      settingsNs: draft.settingsNs,
      settingsPath: draft.settingsPath,
      profile: draft.profile,
      declared: draft.isNew,
      credentialRef: draft.credentialRef,
      revision: 2,
    );
    savedEntry = saved;
    entries = <DshProviderEntry>[...entries, saved];
    return saved;
  }

  @override
  Future<void> delete(DshProviderEntry entry) async {
    entries = <DshProviderEntry>[
      for (final current in entries)
        if (current.id != entry.id) current,
    ];
  }

  @override
  Future<void> setCredential({
    required String ref,
    required String value,
  }) async {
    credentialRef = ref;
    credentialValue = value;
  }

  @override
  Future<void> clearCredential(String ref) async {}

  @override
  Future<List<DshDiscoveredModel>> discover({
    required DshProviderApi api,
    required String baseURL,
    required String apiKey,
    String? providerId,
  }) async => const <DshDiscoveredModel>[];
}

DshProviderEntry _entry({required String id, required String name}) {
  return DshProviderEntry(
    id: id,
    displayName: name,
    settingsNs: 'llm-pi-ai',
    settingsPath: <String>['providers', id],
    profile: const DshProviderProfile(
      api: DshProviderApi.anthropicMessages,
      baseURL: 'https://api.example.test',
    ),
    configured: true,
    credentialRef: '${id.toUpperCase()}_API_KEY',
    revision: 1,
  );
}

Widget _app(Widget child) {
  return MaterialApp(
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: Scaffold(body: child),
  );
}

void main() {
  testWidgets('the tab body lists providers with 自定义提供商 first', (tester) async {
    final gateway = _FakeSettingsGateway(<DshProviderEntry>[
      _entry(id: 'anthropic', name: 'Anthropic'),
      _entry(id: 'deepseek-official', name: 'DeepSeek'),
    ]);
    await tester.pumpWidget(
      _app(DshModelsTabBody(remoteId: 'remote-1', settings: gateway)),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('dsh-models-search')), findsOneWidget);
    expect(find.byKey(const Key('dsh-models-custom-provider')), findsOneWidget);
    expect(find.byKey(const Key('dsh-provider-row-anthropic')), findsOneWidget);
    expect(
      find.byKey(const Key('dsh-provider-row-deepseek-official')),
      findsOneWidget,
    );
    // 自定义提供商 card renders above the first provider row.
    final customY = tester
        .getTopLeft(find.byKey(const Key('dsh-models-custom-provider')))
        .dy;
    final firstProviderY = tester
        .getTopLeft(find.byKey(const Key('dsh-provider-row-anthropic')))
        .dy;
    expect(customY, lessThan(firstProviderY));

    await tester.enterText(find.byType(TextField).first, 'deep');
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('dsh-provider-row-anthropic')), findsNothing);
    expect(
      find.byKey(const Key('dsh-provider-row-deepseek-official')),
      findsOneWidget,
    );
  });

  testWidgets('a provider row opens the R11 detail form', (tester) async {
    final gateway = _FakeSettingsGateway(<DshProviderEntry>[
      _entry(id: 'anthropic', name: 'Anthropic'),
    ]);
    await tester.pumpWidget(
      _app(DshModelsTabBody(remoteId: 'remote-1', settings: gateway)),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('dsh-provider-row-anthropic')));
    await tester.pumpAndSettle();

    expect(find.text('Anthropic'), findsWidgets);
    expect(find.byKey(const Key('dsh-provider-detail-save')), findsOneWidget);
    expect(find.text('API key'), findsOneWidget);
    expect(find.text('Custom settings'), findsOneWidget);
    expect(find.text('Model catalog'), findsOneWidget);
  });

  testWidgets('without the settings seam the detail page is honest', (
    tester,
  ) async {
    await tester.pumpWidget(
      _app(const DshProviderDetailPage(remoteId: 'remote-1', entry: null)),
    );
    await tester.pumpAndSettle();

    expect(
      find.text('Provider settings aren’t available in this build'),
      findsOneWidget,
    );
    expect(find.byKey(const Key('dsh-provider-detail-save')), findsNothing);
  });

  testWidgets('creating a custom provider saves profile and credential', (
    tester,
  ) async {
    final gateway = _FakeSettingsGateway(const <DshProviderEntry>[]);
    await tester.pumpWidget(
      _app(
        DshProviderDetailPage(
          remoteId: 'remote-1',
          settings: gateway,
          createCustom: true,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('New custom provider'), findsWidgets);
    expect(find.text('Provider ID'), findsOneWidget);
    expect(find.text('API protocol'), findsOneWidget);

    Future<void> typeInto(String key, String value) => tester.enterText(
      find.descendant(
        of: find.byKey(Key(key)),
        matching: find.byType(EditableText),
      ),
      value,
    );
    await typeInto('dsh-provider-detail-id', 'my-gateway');
    await typeInto(
      'dsh-provider-detail-base-url',
      'https://gateway.example.test',
    );
    await typeInto('dsh-provider-detail-api-key', 'test-key');
    await tester.pump();

    final saveButton = find.byKey(const Key('dsh-provider-detail-save'));
    await tester.ensureVisible(saveButton);
    await tester.pumpAndSettle();
    await tester.tap(saveButton);
    await tester.pumpAndSettle();

    expect(gateway.savedEntry?.id, 'my-gateway');
    expect(gateway.savedEntry?.declared, isTrue);
    expect(gateway.savedEntry?.settingsNs, 'llm-pi-ai');
    expect(gateway.savedEntry?.settingsPath, <String>[
      'providers',
      'my-gateway',
    ]);
    expect(gateway.credentialRef, 'MY_GATEWAY_API_KEY');
    expect(gateway.credentialValue, 'test-key');
  });
}
