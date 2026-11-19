import 'package:flutter_test/flutter_test.dart';

import 'package:Cuplivo/features/harness/pages/assistant/models/dsh_provider_settings.dart';
import 'package:Cuplivo/features/harness/pages/assistant/models/dsh_provider_settings_controller.dart';

DshProviderEntry _entry({
  required String id,
  required String name,
  bool configured = false,
  int revision = 1,
}) {
  return DshProviderEntry(
    id: id,
    displayName: name,
    settingsNs: 'llm-pi-ai',
    settingsPath: <String>['providers', id],
    profile: const DshProviderProfile(
      api: DshProviderApi.openAiChatCompletions,
      baseURL: 'https://example.test',
    ),
    configured: configured,
    credentialRef: '${id.toUpperCase()}_API_KEY',
    revision: revision,
  );
}

DshProviderDraft _draft(DshProviderEntry entry) {
  return DshProviderDraft(
    providerId: entry.id,
    displayName: entry.displayName,
    settingsNs: entry.settingsNs,
    settingsPath: entry.settingsPath,
    profile: entry.profile,
    expectedRevision: entry.revision,
    credentialRef: entry.credentialRef,
  );
}

class _FakeSettingsGateway implements DshProviderSettingsGateway {
  _FakeSettingsGateway(this.entries);

  List<DshProviderEntry> entries;
  int loadCalls = 0;
  int saveCalls = 0;
  int deleteCalls = 0;
  String? savedCredentialRef;
  String? savedCredentialValue;
  DshProviderSettingsFailure? failSave;
  DshProviderEntry? savedEntry;

  @override
  Future<List<DshProviderEntry>> load() async {
    loadCalls += 1;
    return List<DshProviderEntry>.of(entries);
  }

  @override
  Future<DshProviderEntry> save(DshProviderDraft draft) async {
    saveCalls += 1;
    final failure = failSave;
    if (failure != null) {
      failSave = null;
      throw DshProviderSettingsException(failure);
    }
    final saved = DshProviderEntry(
      id: draft.providerId,
      displayName: draft.displayName,
      settingsNs: draft.settingsNs,
      settingsPath: draft.settingsPath,
      profile: draft.profile,
      declared: draft.isNew,
      configured: false,
      credentialRef: draft.credentialRef,
      revision: (draft.expectedRevision ?? 0) + 1,
    );
    savedEntry = saved;
    entries = <DshProviderEntry>[
      for (final entry in entries)
        if (entry.id != saved.id) entry,
      saved,
    ];
    return saved;
  }

  @override
  Future<void> delete(DshProviderEntry entry) async {
    deleteCalls += 1;
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
    savedCredentialRef = ref;
    savedCredentialValue = value;
    entries = <DshProviderEntry>[
      for (final entry in entries)
        if (entry.credentialRef == ref)
          entry.copyWith(configured: true)
        else
          entry,
    ];
  }

  @override
  Future<void> clearCredential(String ref) async {
    entries = <DshProviderEntry>[
      for (final entry in entries)
        if (entry.credentialRef == ref)
          entry.copyWith(configured: false)
        else
          entry,
    ];
  }

  @override
  Future<List<DshDiscoveredModel>> discover({
    required DshProviderApi api,
    required String baseURL,
    required String apiKey,
    String? providerId,
  }) async => const <DshDiscoveredModel>[
    DshDiscoveredModel(id: 'discovered-model'),
  ];
}

void main() {
  test('load sorts providers and exposes them as unmodifiable', () async {
    final gateway = _FakeSettingsGateway(<DshProviderEntry>[
      _entry(id: 'zeta', name: 'Zeta'),
      _entry(id: 'alpha', name: 'Alpha'),
    ]);
    final controller = DshProviderSettingsController(gateway: gateway);
    addTearDown(controller.dispose);

    await controller.load();

    expect(controller.hasLoaded, isTrue);
    expect(controller.entries!.map((entry) => entry.id), <String>[
      'alpha',
      'zeta',
    ]);
    expect(gateway.loadCalls, 1);
    expect(
      () => controller.entries!.add(_entry(id: 'x', name: 'X')),
      throwsA(isA<UnsupportedError>()),
    );
  });

  test('a conflict reloads the host state and reports the failure', () async {
    final gateway = _FakeSettingsGateway(<DshProviderEntry>[
      _entry(id: 'alpha', name: 'Alpha'),
    ]);
    final controller = DshProviderSettingsController(gateway: gateway);
    addTearDown(controller.dispose);
    await controller.load();
    gateway.failSave = DshProviderSettingsFailure.conflict;
    gateway.entries = <DshProviderEntry>[
      _entry(id: 'alpha', name: 'Alpha', revision: 7),
    ];

    final saved = await controller.save(_draft(controller.entries!.single));

    expect(saved, isNull);
    expect(controller.lastFailure, DshProviderSettingsFailure.conflict);
    expect(gateway.loadCalls, 2);
    expect(controller.entries!.single.revision, 7);
  });

  test('setCredential marks the matching provider configured', () async {
    final gateway = _FakeSettingsGateway(<DshProviderEntry>[
      _entry(id: 'alpha', name: 'Alpha'),
      _entry(id: 'beta', name: 'Beta'),
    ]);
    final controller = DshProviderSettingsController(gateway: gateway);
    addTearDown(controller.dispose);
    await controller.load();

    final ok = await controller.setCredential('ALPHA_API_KEY', 'secret');

    expect(ok, isTrue);
    expect(gateway.savedCredentialRef, 'ALPHA_API_KEY');
    expect(gateway.savedCredentialValue, 'secret');
    expect(controller.entries!.first.configured, isTrue);
    expect(controller.entries!.last.configured, isFalse);
  });

  test('delete removes a provider from the snapshot', () async {
    final gateway = _FakeSettingsGateway(<DshProviderEntry>[
      _entry(id: 'alpha', name: 'Alpha'),
      _entry(id: 'beta', name: 'Beta'),
    ]);
    final controller = DshProviderSettingsController(gateway: gateway);
    addTearDown(controller.dispose);
    await controller.load();

    final removed = await controller.delete(controller.entries!.first);

    expect(removed, isTrue);
    expect(gateway.deleteCalls, 1);
    expect(controller.entries!.map((entry) => entry.id), <String>['beta']);
  });
}
