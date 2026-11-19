import 'package:flutter_test/flutter_test.dart';

import 'package:Cuplivo/features/harness/pages/assistant/models/dsh_models_tab_body.dart';
import 'package:Cuplivo/features/harness/pages/assistant/models/dsh_provider_settings.dart';
import 'package:Cuplivo/features/harness/state/dsh_gateway.dart';

DshProviderEntry _entry({
  required String id,
  required String name,
  bool configured = false,
  String? error,
  int revision = 1,
}) {
  return DshProviderEntry(
    id: id,
    displayName: name,
    settingsNs: 'llm-pi-ai',
    settingsPath: <String>['providers', id],
    profile: const DshProviderProfile(
      api: DshProviderApi.openAiChatCompletions,
    ),
    configured: configured,
    credentialRef: '${id.toUpperCase()}_API_KEY',
    revision: revision,
    error: error,
  );
}

void main() {
  test('catalog rows are alphabetical and carry failure state', () {
    final rows = dshProviderListRows(
      catalogGroups: const <DshProviderGroup>[
        DshProviderGroup(
          id: 'zeta',
          title: 'Zeta',
          models: <DshModel>[
            DshModel(providerId: 'zeta', modelId: 'z-1', title: 'Z1'),
          ],
        ),
        DshProviderGroup(id: 'alpha', title: 'Alpha'),
        DshProviderGroup(
          id: 'broken',
          title: 'Broken',
          failureMessage: 'No credential',
        ),
      ],
    );

    expect(rows.map((row) => row.providerId), <String>[
      'alpha',
      'broken',
      'zeta',
    ]);
    expect(rows.first.enabled, isTrue);
    expect(rows[1].enabled, isFalse);
    expect(rows[1].diagnostic, 'No credential');
    expect(rows.last.modelCount, 1);
    expect(rows.last.group?.id, 'zeta');
    expect(rows.last.entry, isNull);
  });

  test('settings entries win over the catalog and require a credential', () {
    final rows = dshProviderListRows(
      settingsEntries: <DshProviderEntry>[
        _entry(id: 'anthropic', name: 'Anthropic', configured: true),
        _entry(id: 'openai', name: 'OpenAI', configured: false),
        _entry(
          id: 'broken',
          name: 'Broken',
          configured: true,
          error: 'bad base URL',
        ),
      ],
      catalogGroups: const <DshProviderGroup>[
        DshProviderGroup(id: 'catalog-only', title: 'Catalog only'),
      ],
    );

    expect(rows.map((row) => row.providerId), <String>[
      'anthropic',
      'broken',
      'openai',
    ]);
    expect(rows.first.enabled, isTrue);
    expect(rows[1].enabled, isFalse);
    expect(rows[1].diagnostic, 'bad base URL');
    expect(rows[2].enabled, isFalse);
    expect(rows.first.entry?.id, 'anthropic');
  });

  test('search matches display name and provider id', () {
    final entries = <DshProviderEntry>[
      _entry(id: 'deepseek-official', name: 'DeepSeek'),
      _entry(id: 'anthropic', name: 'Anthropic'),
    ];

    expect(
      dshProviderListRows(
        settingsEntries: entries,
        query: 'deep',
      ).map((row) => row.providerId),
      <String>['deepseek-official'],
    );
    expect(
      dshProviderListRows(
        settingsEntries: entries,
        query: 'ANTH',
      ).map((row) => row.providerId),
      <String>['anthropic'],
    );
    expect(
      dshProviderListRows(settingsEntries: entries, query: 'nothing'),
      isEmpty,
    );
  });
}
